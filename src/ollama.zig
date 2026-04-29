const std = @import("std");
const config = @import("config.zig");

pub const Role = enum { system, user, assistant, tool };

pub const Message = struct {
    role: Role,
    content: []const u8,
};

pub const ChatResponse = struct {
    content: []u8,
    thinking: ?[]u8,
};

pub const StreamChunk = struct {
    content_delta: []const u8,
    thinking_delta: ?[]const u8,
    done: bool,
};

fn roleName(role: Role) []const u8 {
    return switch (role) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };
}

/// Non-streaming chat - waits for full response
pub fn chat(allocator: std.mem.Allocator, cfg: config.Config, messages: []const Message) !ChatResponse {
    const uri_text = try std.fmt.allocPrint(allocator, "{s}/api/chat", .{cfg.base_url});
    defer allocator.free(uri_text);

    const uri = try std.Uri.parse(uri_text);

    var body = std.Io.Writer.Allocating.init(allocator);
    defer body.deinit();

    const json_messages = try allocator.alloc(JsonMessage, messages.len);
    defer allocator.free(json_messages);
    for (messages, 0..) |message, index| {
        json_messages[index] = .{ .role = roleName(message.role), .content = message.content };
    }

    try std.json.Stringify.value(.{
        .model = cfg.model,
        .stream = false,
        .messages = json_messages,
    }, .{}, &body.writer);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var response_body = std.Io.Writer.Allocating.init(allocator);
    defer response_body.deinit();

    const result = try client.fetch(.{
        .method = .POST,
        .location = .{ .uri = uri },
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .payload = body.written(),
        .response_writer = &response_body.writer,
    });

    if (result.status != .ok) {
        return error.OllamaError;
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_body.written(), .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const message_obj = root.get("message") orelse return error.InvalidOllamaResponse;
    const content = message_obj.object.get("content") orelse return error.InvalidOllamaResponse;
    const thinking = root.get("thinking");
    return .{
        .content = try allocator.dupe(u8, content.string),
        .thinking = if (thinking) |t| try allocator.dupe(u8, t.string) else null,
    };
}

/// Streaming chat - calls callback for each SSE chunk
/// Checks for cancellation via shouldCancel callback
pub fn chatStream(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    messages: []const Message,
    ctx: anytype,
    comptime callback: fn (@TypeOf(ctx), StreamChunk) anyerror!void,
    comptime shouldCancel: fn (@TypeOf(ctx)) anyerror!bool,
) !void {
    // Build JSON body
    var body_writer = std.Io.Writer.Allocating.init(allocator);
    defer body_writer.deinit();

    const json_messages = try allocator.alloc(JsonMessage, messages.len);
    defer allocator.free(json_messages);
    for (messages, 0..) |message, index| {
        json_messages[index] = .{ .role = roleName(message.role), .content = message.content };
    }

    try std.json.Stringify.value(.{
        .model = cfg.model,
        .stream = true,
        .messages = json_messages,
    }, .{}, &body_writer.writer);

    const body_bytes = body_writer.written();

    // Use curl subprocess to handle SSE streaming
    const curl_argv = [_][]const u8{
        "curl",
        "-s",
        "-N",
        "--max-time", "120",
        "-X", "POST",
        "-H", "Content-Type: application/json",
        "-d", body_bytes,
        try std.fmt.allocPrint(allocator, "{s}/api/chat", .{cfg.base_url}),
    };
    defer allocator.free(curl_argv[curl_argv.len - 1]);

    var child = try std.process.spawn(std.Options.debug_io, .{
        .argv = &curl_argv,
        .stdin = .ignore,
        .stdout = .pipe,
    });
    defer {
        if (child.id != null) _ = child.wait(std.Options.debug_io) catch {};
    }

    const stdout_file = child.stdout.?;
    const stdout_fd = stdout_file.handle;

    // Stream raw chunks and split records ourselves. Reader delimiter helpers can
    // buffer more aggressively than we want for live TUI updates.
    var read_buf: [1024]u8 = undefined;
    var pending = std.ArrayList(u8).empty;
    defer pending.deinit(allocator);

    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = stdout_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    while (true) {
        // Check cancellation via callback first
        if (try shouldCancel(ctx)) {
            child.kill(std.Options.debug_io);
            return error.Cancelled;
        }

        // Poll with 50ms timeout to allow checking cancellation
        const ready = std.posix.poll(&poll_fds, 50) catch 0;

        if (ready > 0) {
            // Check if curl stdout has data
            if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
                var vecs = [_][]u8{read_buf[0..]};
                const n = stdout_file.readStreaming(std.Options.debug_io, &vecs) catch break;
                if (n == 0) break;

                try pending.appendSlice(allocator, read_buf[0..n]);

                while (std.mem.indexOfScalar(u8, pending.items, '\n')) |newline_index| {
                    const done = try handleStreamLine(allocator, pending.items[0..newline_index], ctx, callback);

                    const rest_start = newline_index + 1;
                    if (rest_start < pending.items.len) {
                        std.mem.copyForwards(u8, pending.items[0 .. pending.items.len - rest_start], pending.items[rest_start..]);
                    }
                    pending.shrinkRetainingCapacity(pending.items.len - rest_start);

                    if (done) return;
                }
            }

            // Check for hangup/error on curl stdout
            if (poll_fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
                break;
            }
        }
    }

    if (pending.items.len > 0) {
        _ = try handleStreamLine(allocator, pending.items, ctx, callback);
    }
}

fn handleStreamLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    ctx: anytype,
    comptime callback: fn (@TypeOf(ctx), StreamChunk) anyerror!void,
) !bool {
    const trimmed_str = std.mem.trim(u8, line, " \r");
    if (trimmed_str.len == 0) return false;

    if (std.mem.eql(u8, trimmed_str, "[DONE]")) {
        try callback(ctx, .{ .content_delta = "", .thinking_delta = null, .done = true });
        return true;
    }

    if (trimmed_str.len < 2 or trimmed_str[0] != '{') return false;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed_str, .{}) catch return false;
    defer parsed.deinit();

    const root = parsed.value.object;
    const done_val = if (root.get("done")) |v| v.bool else false;

    const message_obj = root.get("message");
    const content_delta = if (message_obj) |m| blk: {
        const c = m.object.get("content");
        break :blk if (c) |cv| cv.string else "";
    } else "";

    const thinking_delta = if (message_obj) |m| blk: {
        const t = m.object.get("thinking");
        break :blk if (t) |tv| tv.string else null;
    } else null;

    try callback(ctx, .{
        .content_delta = content_delta,
        .thinking_delta = thinking_delta,
        .done = done_val,
    });

    return done_val;
}

const JsonMessage = struct {
    role: []const u8,
    content: []const u8,
};
