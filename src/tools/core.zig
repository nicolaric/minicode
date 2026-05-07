const std = @import("std");
const builtin = @import("builtin");
const ollama = @import("../ollama.zig");

pub extern "c" fn setpgid(pid: std.posix.pid_t, pgid: std.posix.pid_t) c_int;
pub extern "c" fn getpgrp() std.posix.pid_t;
pub extern "c" fn setsid() std.posix.pid_t;

pub const testing = std.testing;

// Log file constants
pub const tool_log_file_name = "tool-calls.log";
pub const stream_log_file_name = "stream-failures.log";
pub const max_logged_tool_output: usize = 64 * 1024;

// Read/grep limits
pub const max_read_lines: usize = 100;
pub const max_grep_matches: usize = 20;

/// Request to execute a tool
pub const ToolRequest = struct {
    tool: []const u8,
    args: std.json.Value,
};

/// Confirmation callback type
pub const ConfirmFn = *const fn (ctx: *anyopaque, prompt: []const u8) anyerror!bool;

/// Confirmation handler
pub const Confirm = struct {
    ctx: *anyopaque,
    callback: ConfirmFn,
};

/// Streaming callback for shell command output
pub const ShellStreamFn = *const fn (ctx: *anyopaque, output: []const u8, is_stderr: bool) void;

/// Shell stream handler
pub const ShellStream = struct {
    ctx: *anyopaque,
    callback: ShellStreamFn,
};

/// Create a ToolRequest from an Ollama ToolCall
pub fn requestFromToolCall(call: ollama.ToolCall) ToolRequest {
    return .{ .tool = call.name, .args = call.arguments };
}

/// Parse a tool request from JSON text
pub fn parseToolRequest(allocator: std.mem.Allocator, text: []const u8) !?std.json.Parsed(ToolRequest) {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (trimmed[0] == '<') {
        if (try xmlToolToJson(allocator, trimmed)) |json| {
            defer allocator.free(json);
            return parseToolRequest(allocator, json);
        }
        return null;
    }

    if (trimmed[0] != '{') return null;

    const parsed = std.json.parseFromSlice(ToolRequest, allocator, trimmed, .{ .ignore_unknown_fields = true }) catch return parseFlatToolRequest(allocator, trimmed);
    if (parsed.value.tool.len == 0) {
        parsed.deinit();
        return parseFlatToolRequest(allocator, trimmed);
    }
    return parsed;
}

/// Parse flat tool request format (tool and args at same level)
fn parseFlatToolRequest(allocator: std.mem.Allocator, text: []const u8) !?std.json.Parsed(ToolRequest) {
    var parsed_value = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return null;
    defer parsed_value.deinit();

    const object = switch (parsed_value.value) {
        .object => |object| object,
        else => return null,
    };

    const tool_value = object.get("tool") orelse return null;
    const tool_name = switch (tool_value) {
        .string => |name| name,
        else => return null,
    };
    if (tool_name.len == 0) return null;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"tool\":");
    try appendJsonValue(allocator, &out, tool_name);
    try out.appendSlice(allocator, ",\"args\":{");

    var first = true;
    var it = object.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "tool")) continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        try appendJsonValue(allocator, &out, entry.key_ptr.*);
        try out.append(allocator, ':');
        try appendJsonValue(allocator, &out, entry.value_ptr.*);
    }

    try out.appendSlice(allocator, "}}");
    return std.json.parseFromSlice(ToolRequest, allocator, out.items, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
}

/// Append a JSON value to a string
fn appendJsonValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype) !void {
    var json_value = std.Io.Writer.Allocating.init(allocator);
    defer json_value.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .minified }, &json_value.writer);
    try out.appendSlice(allocator, json_value.written());
}

/// Convert XML tool call to JSON format
fn xmlToolToJson(allocator: std.mem.Allocator, text: []const u8) !?[]u8 {
    if (text.len < 3 or text[0] != '<') return null;
    const end = std.mem.indexOfScalar(u8, text, '>') orelse return null;
    const tag = std.mem.trim(u8, text[1..end], " \t\r\n/");
    if (tag.len == 0) return null;

    var parts = std.mem.splitScalar(u8, tag, ' ');
    const tool_name = parts.next() orelse return null;
    if (!isKnownTool(tool_name)) return null;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "{{\"tool\":\"{s}\",\"args\":{{", .{tool_name});

    var first = true;
    var cursor = tool_name.len;
    while (cursor < tag.len) {
        while (cursor < tag.len and std.ascii.isWhitespace(tag[cursor])) cursor += 1;
        if (cursor >= tag.len) break;

        const key_start = cursor;
        while (cursor < tag.len and tag[cursor] != '=' and !std.ascii.isWhitespace(tag[cursor])) cursor += 1;
        const key = tag[key_start..cursor];
        while (cursor < tag.len and std.ascii.isWhitespace(tag[cursor])) cursor += 1;
        if (cursor >= tag.len or tag[cursor] != '=') break;
        cursor += 1;
        while (cursor < tag.len and std.ascii.isWhitespace(tag[cursor])) cursor += 1;
        if (cursor >= tag.len or tag[cursor] != '"') break;
        cursor += 1;
        const value_start = cursor;
        while (cursor < tag.len and tag[cursor] != '"') cursor += 1;
        if (cursor >= tag.len) break;
        const value = tag[value_start..cursor];
        cursor += 1;

        if (!first) try out.append(allocator, ',');
        first = false;
        try out.print(allocator, "\"{s}\":", .{key});
        var json_value = std.Io.Writer.Allocating.init(allocator);
        defer json_value.deinit();
        try std.json.Stringify.value(value, .{ .whitespace = .minified }, &json_value.writer);
        try out.appendSlice(allocator, json_value.written());
    }

    try out.appendSlice(allocator, "}}");
    return try out.toOwnedSlice(allocator);
}

/// Check if a tool name is known
fn isKnownTool(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "read_file") or
        std.mem.eql(u8, tool_name, "write_file") or
        std.mem.eql(u8, tool_name, "list_files") or
        std.mem.eql(u8, tool_name, "run_shell") or
        std.mem.eql(u8, tool_name, "glob") or
        std.mem.eql(u8, tool_name, "grep") or
        std.mem.eql(u8, tool_name, "edit");
}

// Argument extraction helpers

pub fn getStringArg(args: std.json.Value, name: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const value = args.object.get(name) orelse return null;
    if (value != .string) return null;
    return value.string;
}

pub fn getUsizeArg(args: std.json.Value, name: []const u8) ?usize {
    if (args != .object) return null;
    const value = args.object.get(name) orelse return null;
    return switch (value) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .string => |s| std.fmt.parseUnsigned(usize, s, 10) catch null,
        else => null,
    };
}

pub fn getBoolArg(args: std.json.Value, name: []const u8) ?bool {
    if (args != .object) return null;
    const value = args.object.get(name) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

// Confirmation helper

pub fn confirm(prompt: []const u8, confirmer: ?Confirm) !bool {
    if (confirmer) |handler| return handler.callback(handler.ctx, prompt);

    var stdout_buf: [8192]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &stdout_buf);
    const stdout = &stdout_file.interface;
    defer stdout.flush() catch {};
    var stdin_buf: [256]u8 = undefined;
    var stdin_file = std.Io.File.stdin().readerStreaming(std.Options.debug_io, &stdin_buf);
    const stdin = &stdin_file.interface;
    try stdout.print("{s} [y/N]: ", .{prompt});

    const line = (stdin.takeDelimiter('\n') catch return false) orelse return false;
    const answer = std.mem.trim(u8, line, " \t\r\n");
    return std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes");
}

// Path resolution

pub fn resolveInsideCwd(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return error.PathOutsideCwd;

    const cwd = try std.process.currentPathAlloc(std.Options.debug_io, allocator);
    defer allocator.free(cwd);

    if (hasParentTraversal(path)) return error.PathOutsideCwd;

    return try std.fs.path.join(allocator, &.{ cwd, path });
}

pub fn hasParentTraversal(path: []const u8) bool {
    var it = std.fs.path.componentIterator(path);
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp.name, "..")) return true;
    }
    return false;
}

/// Read a file using an absolute path
pub fn readFileAbsolute(allocator: std.mem.Allocator, absolute_path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(std.Options.debug_io, absolute_path, .{});
    defer file.close(std.Options.debug_io);
    const stat = try file.stat(std.Options.debug_io);
    const size = @min(stat.size, 1024 * 1024); // 1MB limit
    
    var buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    
    // Read file content using readStreaming with single buffer
    const bufs = [_][]u8{buf};
    const bytes_read = try file.readStreaming(std.Options.debug_io, &bufs);
    
    if (bytes_read < size) {
        buf = try allocator.realloc(buf, bytes_read);
    }
    return buf;
}

pub fn relativeDisplayPath(allocator: std.mem.Allocator, file_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.Options.debug_io, allocator);
    defer allocator.free(cwd);

    if (std.mem.eql(u8, file_path, cwd)) return allocator.dupe(u8, ".");
    if (std.mem.startsWith(u8, file_path, cwd) and file_path.len > cwd.len and file_path[cwd.len] == std.fs.path.sep) {
        return allocator.dupe(u8, file_path[cwd.len + 1 ..]);
    }
    return allocator.dupe(u8, file_path);
}

// Environment helpers

pub fn getEnvVar(name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.c.environ[i]) |ptr| : (i += 1) {
        const env_str = std.mem.sliceTo(ptr, 0);
        if (std.mem.startsWith(u8, env_str, name) and env_str.len > name.len and env_str[name.len] == '=') {
            return env_str[name.len + 1 ..];
        }
    }
    return null;
}

pub fn loadShellEnv(allocator: std.mem.Allocator, shell: []const u8) !std.process.Environ.Map {
    _ = shell;
    var env_map = std.process.Environ.Map.init(allocator);
    errdefer env_map.deinit();

    // First, load current process environment (like pi-mono's process.env)
    var i: usize = 0;
    while (std.c.environ[i]) |ptr| : (i += 1) {
        const env_str = std.mem.sliceTo(ptr, 0);
        if (std.mem.indexOfScalar(u8, env_str, '=')) |equals| {
            if (equals > 0) {
                const key = env_str[0..equals];
                const value = env_str[equals + 1 ..];
                try env_map.put(key, value);
            }
        }
    }

    return env_map;
}

pub fn ensurePathHas(env_map: *std.process.Environ.Map, allocator: std.mem.Allocator, dir: []const u8) !void {
    const current = env_map.get("PATH") orelse "";
    if (current.len != 0) {
        var it = std.mem.splitScalar(u8, current, ':');
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry, dir)) return;
        }
    }

    const updated = if (current.len == 0)
        try std.fmt.allocPrint(allocator, "{s}", .{dir})
    else
        try std.fmt.allocPrint(allocator, "{s}:{s}", .{ current, dir });
    defer allocator.free(updated);
    try env_map.put("PATH", updated);
}

// Logging functions

pub fn logToolCall(allocator: std.mem.Allocator, req: ToolRequest, result: []const u8) void {
    const args_json = stringifyJsonValue(allocator, req.args) catch return;
    defer allocator.free(args_json);
    logToolEvent(allocator, "tool_call", req.tool, args_json, result);
}

pub fn logInvalidToolJson(allocator: std.mem.Allocator, raw_text: []const u8, error_message: []const u8) void {
    const snippet_len = @min(raw_text.len, max_logged_tool_output);
    logToolEvent(allocator, "invalid_tool_json", "parse", raw_text[0..snippet_len], error_message);
}

pub fn logStreamFailure(
    allocator: std.mem.Allocator,
    err_name: []const u8,
    model: []const u8,
    base_url: []const u8,
    had_tool_result: bool,
    stream_content_len: usize,
    stream_thinking_len: usize,
    stream_tool_calls_len: usize,
) void {
    const log_dir = toolLogDir(allocator) catch return;
    defer allocator.free(log_dir);
    std.Io.Dir.cwd().createDirPath(std.Options.debug_io, log_dir) catch return;

    const log_path = std.fs.path.join(allocator, &.{ log_dir, stream_log_file_name }) catch return;
    defer allocator.free(log_path);

    var file = std.Io.Dir.openFileAbsolute(std.Options.debug_io, log_path, .{ .mode = .read_write }) catch |open_err| switch (open_err) {
        error.FileNotFound => std.Io.Dir.createFileAbsolute(std.Options.debug_io, log_path, .{ .read = true, .truncate = false }) catch return,
        else => return,
    };
    defer file.close(std.Options.debug_io);

    var entry = std.ArrayList(u8).empty;
    defer entry.deinit(allocator);
    const now_ms = currentTimeMs();
    entry.print(allocator, "--- stream_failure time_ms={d}\nerror={s}\nmodel={s}\nbase_url={s}\nhad_tool_result={any}\nstream_content_len={d}\nstream_thinking_len={d}\nstream_tool_calls_len={d}\n\n", .{
        now_ms,
        err_name,
        model,
        base_url,
        had_tool_result,
        stream_content_len,
        stream_thinking_len,
        stream_tool_calls_len,
    }) catch return;

    const stat = file.stat(std.Options.debug_io) catch return;
    file.writePositionalAll(std.Options.debug_io, entry.items, stat.size) catch return;
}

fn logToolEvent(allocator: std.mem.Allocator, event: []const u8, tool_name: []const u8, args_text: []const u8, result: []const u8) void {
    const log_dir = toolLogDir(allocator) catch return;
    defer allocator.free(log_dir);
    std.Io.Dir.cwd().createDirPath(std.Options.debug_io, log_dir) catch return;

    const log_path = std.fs.path.join(allocator, &.{ log_dir, tool_log_file_name }) catch return;
    defer allocator.free(log_path);

    var file = std.Io.Dir.openFileAbsolute(std.Options.debug_io, log_path, .{ .mode = .read_write }) catch |open_err| switch (open_err) {
        error.FileNotFound => std.Io.Dir.createFileAbsolute(std.Options.debug_io, log_path, .{ .read = true, .truncate = false }) catch return,
        else => return,
    };
    defer file.close(std.Options.debug_io);

    var entry = std.ArrayList(u8).empty;
    defer entry.deinit(allocator);
    const now_ms = currentTimeMs();
    entry.print(allocator, "--- {s} time_ms={d} tool={s}\nargs=", .{ event, now_ms, tool_name }) catch return;
    entry.appendSlice(allocator, args_text) catch return;
    const status = if (std.mem.startsWith(u8, result, "Error:") or std.mem.startsWith(u8, result, "Tool error:") or std.mem.indexOf(u8, result, "\x1b[31mError:") != null) "error" else "ok";
    const output_len = @min(result.len, max_logged_tool_output);
    entry.print(allocator, "\nstatus={s} result_len={d}\noutput_truncated={any}\noutput<<MINICODE_TOOL_OUTPUT\n{s}\nMINICODE_TOOL_OUTPUT\n\n", .{
        status,
        result.len,
        result.len > max_logged_tool_output,
        result[0..output_len],
    }) catch return;

    const stat = file.stat(std.Options.debug_io) catch return;
    file.writePositionalAll(std.Options.debug_io, entry.items, stat.size) catch return;
}

fn toolLogDir(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .macos) {
        const home = try getEnvOwned(allocator, "HOME");
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, "Library", "Logs", "minicode" });
    }

    if (getEnvOwned(allocator, "XDG_STATE_HOME")) |state_home| {
        defer allocator.free(state_home);
        return std.fs.path.join(allocator, &.{ state_home, "minicode", "logs" });
    } else |_| {}

    const home = try getEnvOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".local", "state", "minicode", "logs" });
}

fn getEnvOwned(allocator: std.mem.Allocator, comptime name: [:0]const u8) ![]u8 {
    const value = std.c.getenv(name.ptr) orelse return error.MissingEnvironmentVariable;
    return allocator.dupe(u8, std.mem.span(value));
}

fn currentTimeMs() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) == 0) {
        return @as(i128, ts.sec) * 1000 + @divTrunc(@as(i128, ts.nsec), 1_000_000);
    }
    return 0;
}

// JSON helpers

pub fn stringifyJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var json_writer = std.Io.Writer.Allocating.init(allocator);
    defer json_writer.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .minified }, &json_writer.writer);
    return allocator.dupe(u8, json_writer.written());
}

pub fn stringifyJsonString(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var json_writer = std.Io.Writer.Allocating.init(allocator);
    defer json_writer.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .minified }, &json_writer.writer);
    return allocator.dupe(u8, json_writer.written());
}

// Tests for core functionality

test "parseToolRequest accepts flat tool arguments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parsed = (try parseToolRequest(allocator, "{\"tool\":\"grep\",\"pattern\":\"needle\",\"path\":\"src\"}")) orelse return error.TestUnexpectedResult;
    defer parsed.deinit();

    try testing.expectEqualStrings("grep", parsed.value.tool);
    try testing.expectEqualStrings("needle", getStringArg(parsed.value.args, "pattern") orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings("src", getStringArg(parsed.value.args, "path") orelse return error.TestUnexpectedResult);
}

test "parseToolRequest keeps nested args behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parsed = (try parseToolRequest(allocator, "{\"tool\":\"grep\",\"args\":{\"pattern\":\"needle\",\"path\":\"src\"}}")) orelse return error.TestUnexpectedResult;
    defer parsed.deinit();

    try testing.expectEqualStrings("grep", parsed.value.tool);
    try testing.expectEqualStrings("needle", getStringArg(parsed.value.args, "pattern") orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings("src", getStringArg(parsed.value.args, "path") orelse return error.TestUnexpectedResult);
}
