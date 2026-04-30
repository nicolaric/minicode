const std = @import("std");
const config = @import("config.zig");

pub const Config = config.Config;

pub const Role = enum { system, user, assistant, tool };

pub const Message = struct {
    role: Role,
    content: []const u8,
    thinking: ?[]const u8 = null,
    tool_calls: ?[]ToolCall = null,
    tool_name: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
};

pub const ToolCall = struct {
    id: ?[]u8 = null,
    name: []u8,
    arguments: std.json.Value,
};

pub const ChatResponse = struct {
    content: []u8,
    thinking: ?[]u8,
    tool_calls: ?[]ToolCall = null,
};

pub const StreamChunk = struct {
    content_delta: []const u8,
    thinking_delta: ?[]const u8,
    tool_calls: ?[]ToolCall = null,
    done: bool,
};

pub fn freeToolCalls(allocator: std.mem.Allocator, calls: []ToolCall) void {
    for (calls) |call| freeToolCall(allocator, call);
    allocator.free(calls);
}

pub fn freeToolCall(allocator: std.mem.Allocator, call: ToolCall) void {
    if (call.id) |id| allocator.free(id);
    allocator.free(call.name);
    freeJsonValue(allocator, call.arguments);
}

pub fn cloneToolCalls(allocator: std.mem.Allocator, calls: []const ToolCall) ![]ToolCall {
    const cloned = try allocator.alloc(ToolCall, calls.len);
    var cloned_count: usize = 0;
    errdefer {
        for (cloned[0..cloned_count]) |call| freeToolCall(allocator, call);
        allocator.free(cloned);
    }
    for (calls, 0..) |call, index| {
        cloned[index] = try cloneToolCall(allocator, call);
        cloned_count += 1;
    }
    return cloned;
}

fn cloneToolCall(allocator: std.mem.Allocator, call: ToolCall) !ToolCall {
    const id = if (call.id) |owned_id| try allocator.dupe(u8, owned_id) else null;
    errdefer if (id) |owned_id| allocator.free(owned_id);
    const name = try allocator.dupe(u8, call.name);
    errdefer allocator.free(name);
    const arguments = try cloneJsonValue(allocator, call.arguments);
    errdefer freeJsonValue(allocator, arguments);
    return .{ .id = id, .name = name, .arguments = arguments };
}

fn contentForApi(allocator: std.mem.Allocator, message: Message) ![]u8 {
    if (message.role == .assistant) {
        if (message.thinking) |thinking| {
            if (thinking.len > 0) {
                return std.fmt.allocPrint(allocator, "<thinking>{s}</thinking>\n\n{s}", .{ thinking, message.content });
            }
        }
    }
    return allocator.dupe(u8, message.content);
}

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
    const api_contents = try allocator.alloc([]u8, messages.len);
    defer allocator.free(api_contents);
    for (messages, 0..) |message, index| {
        api_contents[index] = try contentForApi(allocator, message);
        errdefer allocator.free(api_contents[index]);
        json_messages[index] = .{
            .role = roleName(message.role),
            .content = api_contents[index],
            .tool_calls = message.tool_calls,
            .tool_name = message.tool_name,
            .tool_call_id = message.tool_call_id,
        };
    }
    defer for (api_contents) |content| allocator.free(content);

    try writeChatRequest(&body.writer, cfg.model, false, json_messages);

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
    const tool_calls = try parseToolCalls(allocator, message_obj.object.get("tool_calls"));
    return .{
        .content = try allocator.dupe(u8, content.string),
        .thinking = if (thinking) |t| try allocator.dupe(u8, t.string) else null,
        .tool_calls = tool_calls,
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
    return chatStreamWithCurl(allocator, cfg, messages, ctx, callback, shouldCancel, "curl");
}

pub fn chatStreamWithCurl(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    messages: []const Message,
    ctx: anytype,
    comptime callback: fn (@TypeOf(ctx), StreamChunk) anyerror!void,
    comptime shouldCancel: fn (@TypeOf(ctx)) anyerror!bool,
    curl_executable: []const u8,
) !void {
    // Build JSON body
    var body_writer = std.Io.Writer.Allocating.init(allocator);
    defer body_writer.deinit();

    const json_messages = try allocator.alloc(JsonMessage, messages.len);
    defer allocator.free(json_messages);
    const api_contents = try allocator.alloc([]u8, messages.len);
    defer allocator.free(api_contents);
    for (messages, 0..) |message, index| {
        api_contents[index] = try contentForApi(allocator, message);
        errdefer allocator.free(api_contents[index]);
        json_messages[index] = .{
            .role = roleName(message.role),
            .content = api_contents[index],
            .tool_calls = message.tool_calls,
            .tool_name = message.tool_name,
            .tool_call_id = message.tool_call_id,
        };
    }
    defer for (api_contents) |content| allocator.free(content);

    try writeChatRequest(&body_writer.writer, cfg.model, true, json_messages);

    const body_bytes = body_writer.written();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Use curl subprocess to handle SSE streaming
    const curl_argv = [_][]const u8{
        curl_executable,
        "-s",
        "-N",
        "--max-time", "120",
        "-X", "POST",
        "-H", "Content-Type: application/json",
        "-d", body_bytes,
        try std.fmt.allocPrint(allocator, "{s}/api/chat", .{cfg.base_url}),
    };
    defer allocator.free(curl_argv[curl_argv.len - 1]);

    var child = try std.process.spawn(io, .{
        .argv = &curl_argv,
        .stdin = .ignore,
        .stdout = .pipe,
    });
    defer if (child.id != null) child.kill(io);

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
    var saw_stream_event = false;
    var saw_done_event = false;

    while (true) {
        // Check cancellation via callback first
        if (try shouldCancel(ctx)) {
            child.kill(io);
            return error.Cancelled;
        }

        // Poll with 50ms timeout to allow checking cancellation
        const ready = std.posix.poll(&poll_fds, 50) catch 0;

        if (ready > 0) {
            // Check if curl stdout has data
            if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
                var vecs = [_][]u8{read_buf[0..]};
                const n = stdout_file.readStreaming(io, &vecs) catch break;
                if (n == 0) break;

                try pending.appendSlice(allocator, read_buf[0..n]);

                while (std.mem.indexOfScalar(u8, pending.items, '\n')) |newline_index| {
                    const trimmed = std.mem.trim(u8, pending.items[0..newline_index], " \r\t");
                    if (trimmed.len > 0 and (trimmed[0] == '{' or std.mem.eql(u8, trimmed, "[DONE]"))) {
                        saw_stream_event = true;
                    }
                    const done = try handleStreamLine(allocator, pending.items[0..newline_index], ctx, callback);

                    const rest_start = newline_index + 1;
                    if (rest_start < pending.items.len) {
                        std.mem.copyForwards(u8, pending.items[0 .. pending.items.len - rest_start], pending.items[rest_start..]);
                    }
                    pending.shrinkRetainingCapacity(pending.items.len - rest_start);

                    if (done) {
                        saw_done_event = true;
                        child.kill(io);
                        return;
                    }
                }
            }

            // Check for hangup/error on curl stdout
            if (poll_fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
                break;
            }
        }
    }

    if (pending.items.len > 0) {
        const trimmed = std.mem.trim(u8, pending.items, " \r\t");
        if (trimmed.len > 0 and (trimmed[0] == '{' or std.mem.eql(u8, trimmed, "[DONE]"))) {
            saw_stream_event = true;
        }
        if (try handleStreamLine(allocator, pending.items, ctx, callback)) {
            saw_done_event = true;
        }
    }

    if (saw_done_event) return;

    const term = if (child.id != null) try child.wait(io) else null;
    if (term) |exit_term| switch (exit_term) {
        .exited => |code| if (code != 0) return error.OllamaStreamFailed,
        else => return error.OllamaStreamFailed,
    };
    if (!saw_stream_event) return error.EmptyStreamResponse;
    if (!saw_done_event) {
        return error.OllamaStreamIncomplete;
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

    const tool_calls = try parseToolCalls(allocator, if (message_obj) |m| m.object.get("tool_calls") else null);
    errdefer if (tool_calls) |calls| freeToolCalls(allocator, calls);

    try callback(ctx, .{
        .content_delta = content_delta,
        .thinking_delta = thinking_delta,
        .tool_calls = tool_calls,
        .done = done_val,
    });

    return done_val;
}

const JsonMessage = struct {
    role: []const u8,
    content: []const u8,
    tool_calls: ?[]ToolCall = null,
    tool_name: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
};

fn writeChatRequest(writer: anytype, model: []const u8, stream: bool, messages: []const JsonMessage) !void {
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(model, .{}, writer);
    try writer.writeAll(",\"stream\":");
    try std.json.Stringify.value(stream, .{}, writer);
    try writer.writeAll(",\"messages\":");
    try writer.writeAll("[");
    for (messages, 0..) |message, index| {
        if (index > 0) try writer.writeAll(",");
        try writeJsonMessage(writer, message);
    }
    try writer.writeAll("]");
    try writer.writeAll(",\"tools\":");
    try writer.writeAll(tool_schemas_json);
    try writer.writeAll("}");
}

fn writeJsonMessage(writer: anytype, message: JsonMessage) !void {
    try writer.writeAll("{\"role\":");
    try std.json.Stringify.value(message.role, .{}, writer);
    try writer.writeAll(",\"content\":");
    try std.json.Stringify.value(message.content, .{}, writer);
    if (message.tool_calls) |tool_calls| {
        try writer.writeAll(",\"tool_calls\":[");
        for (tool_calls, 0..) |call, index| {
            if (index > 0) try writer.writeAll(",");
            try writeJsonToolCall(writer, call);
        }
        try writer.writeAll("]");
    }
    if (message.tool_name) |tool_name| {
        try writer.writeAll(",\"name\":");
        try std.json.Stringify.value(tool_name, .{}, writer);
    }
    if (message.tool_call_id) |tool_call_id| {
        try writer.writeAll(",\"tool_call_id\":");
        try std.json.Stringify.value(tool_call_id, .{}, writer);
    }
    try writer.writeAll("}");
}

fn writeJsonToolCall(writer: anytype, call: ToolCall) !void {
    try writer.writeAll("{");
    if (call.id) |id| {
        try writer.writeAll("\"id\":");
        try std.json.Stringify.value(id, .{}, writer);
        try writer.writeAll(",");
    }
    try writer.writeAll("\"type\":\"function\",\"function\":{\"name\":");
    try std.json.Stringify.value(call.name, .{}, writer);
    try writer.writeAll(",\"arguments\":");
    try std.json.Stringify.value(call.arguments, .{}, writer);
    try writer.writeAll("}}");
}

fn parseToolCalls(allocator: std.mem.Allocator, maybe_value: ?std.json.Value) !?[]ToolCall {
    const value = maybe_value orelse return null;
    if (value != .array or value.array.items.len == 0) return null;

    var calls = std.ArrayList(ToolCall).empty;
    errdefer {
        for (calls.items) |call| freeToolCall(allocator, call);
        calls.deinit(allocator);
    }

    for (value.array.items) |item| {
        if (item != .object) continue;
        const function_value = item.object.get("function") orelse continue;
        if (function_value != .object) continue;
        const name_value = function_value.object.get("name") orelse continue;
        if (name_value != .string or name_value.string.len == 0) continue;

        var arguments = if (function_value.object.get("arguments")) |arguments_value|
            try parseArguments(allocator, arguments_value)
        else
            std.json.Value{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
        errdefer freeJsonValue(allocator, arguments);
        const id_value = item.object.get("id");
        const id = if (id_value) |idv| if (idv == .string) try allocator.dupe(u8, idv.string) else null else null;
        errdefer if (id) |owned_id| allocator.free(owned_id);
        const name = try allocator.dupe(u8, name_value.string);
        errdefer allocator.free(name);
        try calls.append(allocator, .{ .id = id, .name = name, .arguments = arguments });
        arguments = .null;
    }

    if (calls.items.len == 0) return null;
    return try calls.toOwnedSlice(allocator);
}

fn parseArguments(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    if (value == .string) {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, value.string, .{}) catch {
            return cloneJsonValue(allocator, value);
        };
        defer parsed.deinit();
        return cloneJsonValue(allocator, parsed.value);
    }
    return cloneJsonValue(allocator, value);
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |array| blk: {
            var out = std.json.Array.init(allocator);
            errdefer {
                for (out.items) |item| freeJsonValue(allocator, item);
                out.deinit();
            }
            for (array.items) |item| {
                const cloned_item = try cloneJsonValue(allocator, item);
                errdefer freeJsonValue(allocator, cloned_item);
                try out.append(cloned_item);
            }
            break :blk .{ .array = out };
        },
        .object => |object| blk: {
            var out = try std.json.ObjectMap.init(allocator, &.{}, &.{});
            errdefer {
                var cleanup = out.iterator();
                while (cleanup.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    freeJsonValue(allocator, entry.value_ptr.*);
                }
                out.deinit(allocator);
            }
            var it = object.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key);
                const cloned_value = try cloneJsonValue(allocator, entry.value_ptr.*);
                errdefer freeJsonValue(allocator, cloned_value);
                try out.put(allocator, key, cloned_value);
            }
            break :blk .{ .object = out };
        },
    };
}

fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .number_string => |s| allocator.free(s),
        .string => |s| allocator.free(s),
        .array => |array| {
            var owned_array = array;
            for (array.items) |item| freeJsonValue(allocator, item);
            owned_array.deinit();
        },
        .object => |object| {
            var owned_object = object;
            var it = owned_object.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            owned_object.deinit(allocator);
        },
        else => {},
    }
}

const tool_schemas_json =
    \\[{"type":"function","function":{"name":"read_file","description":"Read numbered lines from a file.","parameters":{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}},"required":["path"]}}},{"type":"function","function":{"name":"write_file","description":"Write content to a file.","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}},{"type":"function","function":{"name":"list_files","description":"List directory contents.","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":[]}}},{"type":"function","function":{"name":"run_shell","description":"Run a non-file shell command.","parameters":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}},{"type":"function","function":{"name":"glob","description":"Find files by glob pattern.","parameters":{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"}},"required":["pattern"]}}},{"type":"function","function":{"name":"grep","description":"Search file contents with line numbers.","parameters":{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"include":{"type":"string"},"case_sensitive":{"type":"boolean"},"context":{"type":"integer"}},"required":["pattern"]}}},{"type":"function","function":{"name":"edit","description":"Replace text in a file.","parameters":{"type":"object","properties":{"path":{"type":"string"},"oldString":{"type":"string"},"newString":{"type":"string"}},"required":["path","oldString","newString"]}}}]
;
