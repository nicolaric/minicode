const std = @import("std");
const builtin = @import("builtin");
const ollama = @import("ollama.zig");
const syntax_highlight = @import("syntax_highlight.zig");

const testing = std.testing;

pub const ToolRequest = struct {
    tool: []const u8,
    args: std.json.Value,
};

pub fn requestFromToolCall(call: ollama.ToolCall) ToolRequest {
    return .{ .tool = call.name, .args = call.arguments };
}

const tool_log_file_name = "tool-calls.log";
const stream_log_file_name = "stream-failures.log";
const max_logged_tool_output: usize = 64 * 1024;

pub const ConfirmFn = *const fn (ctx: *anyopaque, prompt: []const u8) anyerror!bool;

pub const Confirm = struct {
    ctx: *anyopaque,
    callback: ConfirmFn,
};

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

fn appendJsonValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype) !void {
    var json_value = std.Io.Writer.Allocating.init(allocator);
    defer json_value.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .minified }, &json_value.writer);
    try out.appendSlice(allocator, json_value.written());
}

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

fn isKnownTool(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "read_file") or
        std.mem.eql(u8, tool_name, "write_file") or
        std.mem.eql(u8, tool_name, "list_files") or
        std.mem.eql(u8, tool_name, "run_shell") or
        std.mem.eql(u8, tool_name, "glob") or
        std.mem.eql(u8, tool_name, "grep") or
        std.mem.eql(u8, tool_name, "edit");
}

pub fn execute(allocator: std.mem.Allocator, req: ToolRequest, highlighter: ?*syntax_highlight.SyntaxHighlighter) ![]u8 {
    return executeWithConfirm(allocator, req, null, highlighter);
}

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

fn stringifyJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var json_writer = std.Io.Writer.Allocating.init(allocator);
    defer json_writer.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .minified }, &json_writer.writer);
    return allocator.dupe(u8, json_writer.written());
}

fn stringifyJsonString(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var json_writer = std.Io.Writer.Allocating.init(allocator);
    defer json_writer.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .minified }, &json_writer.writer);
    return allocator.dupe(u8, json_writer.written());
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

test "write_file creates a file" {
    const path = ".tmp-write-tool-test.txt";
    std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch {};

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try args.put(allocator, "path", .{ .string = path });
    try args.put(allocator, "content", .{ .string = "hello\n" });

    const result = try execute(allocator, .{ .tool = "write_file", .args = .{ .object = args } }, null);
    try testing.expect(std.mem.indexOf(u8, result, "Created") != null);

    const content = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(1024));
    try testing.expectEqualStrings("hello\n", content);
}

test "grep searches a single file path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try args.put(allocator, "path", .{ .string = "src/tui.zig" });
    try args.put(allocator, "pattern", .{ .string = "renderPrompt" });

    const result = try execute(allocator, .{ .tool = "grep", .args = .{ .object = args } }, null);
    try testing.expect(std.mem.indexOf(u8, result, "renderPrompt") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Found") != null);
}

test "grep supports regex operators" {
    const path = ".tmp-grep-regex-test.txt";
    std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch {};

    {
        var file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, path, .{});
        defer file.close(std.Options.debug_io);
        try std.Io.File.writeStreamingAll(file, std.Options.debug_io, "abc\naxc\nabbc\n");
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try args.put(allocator, "path", .{ .string = path });
    try args.put(allocator, "pattern", .{ .string = "^a.+c$" });

    const result = try execute(allocator, .{ .tool = "grep", .args = .{ .object = args } }, null);
    try testing.expect(std.mem.indexOf(u8, result, "Line: 1") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Line: 2") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Line: 3") != null);
}

test "grep supports case_insensitive arg" {
    const path = ".tmp-grep-case-test.txt";
    std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch {};

    {
        var file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, path, .{});
        defer file.close(std.Options.debug_io);
        try std.Io.File.writeStreamingAll(file, std.Options.debug_io, "RenderPrompt\n");
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try args.put(allocator, "path", .{ .string = path });
    try args.put(allocator, "pattern", .{ .string = "renderprompt" });
    try args.put(allocator, "case_sensitive", .{ .bool = false });

    const result = try execute(allocator, .{ .tool = "grep", .args = .{ .object = args } }, null);
    try testing.expect(std.mem.indexOf(u8, result, "Found 1 matches") != null);
}

test "grep returns ansi error for malformed regex" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try args.put(allocator, "pattern", .{ .string = "[abc" });

    const result = try execute(allocator, .{ .tool = "grep", .args = .{ .object = args } }, null);
    try testing.expect(std.mem.indexOf(u8, result, "\x1b[31mError: invalid regex pattern (unclosed character class)\x1b[0m") != null);
}

test "grep searches current directory by default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try args.put(allocator, "pattern", .{ .string = "renderPrompt" });

    const result = try execute(allocator, .{ .tool = "grep", .args = .{ .object = args } }, null);
    try testing.expect(std.mem.indexOf(u8, result, "renderPrompt") != null);
}

test "grep finds thinking title in tui by default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try args.put(allocator, "pattern", .{ .string = "Thinking" });

    const result = try execute(allocator, .{ .tool = "grep", .args = .{ .object = args } }, null);
    try testing.expect(std.mem.indexOf(u8, result, "src/tui.zig") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Thinking") != null);
}

test "grep include matches relative paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try args.put(allocator, "pattern", .{ .string = "thinking_marker" });
    try args.put(allocator, "include", .{ .string = "src/*.zig" });

    const result = try execute(allocator, .{ .tool = "grep", .args = .{ .object = args } }, null);
    try testing.expect(std.mem.indexOf(u8, result, "src/tui.zig") != null);
}

test "grep next tool call JSON-escapes path" {
    const path = ".tmp-grep-json-path-\"quote\\slash.txt";
    std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch {};

    {
        var file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, path, .{});
        defer file.close(std.Options.debug_io);
        try std.Io.File.writeStreamingAll(file, std.Options.debug_io, "before\nneedle\nafter\n");
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try args.put(allocator, "path", .{ .string = path });
    try args.put(allocator, "pattern", .{ .string = "needle" });
    try args.put(allocator, "context", .{ .integer = 1 });

    const result = try execute(allocator, .{ .tool = "grep", .args = .{ .object = args } }, null);
    try testing.expect(std.mem.indexOf(u8, result, "Context lines 1-3:") != null);

    const marker = "Next tool call:\n";
    const json_start = (std.mem.indexOf(u8, result, marker) orelse return error.TestUnexpectedResult) + marker.len;
    const json_end = json_start + (std.mem.indexOfScalar(u8, result[json_start..], '\n') orelse return error.TestUnexpectedResult);
    var parsed = (try parseToolRequest(allocator, result[json_start..json_end])) orelse return error.TestUnexpectedResult;
    defer parsed.deinit();

    try testing.expectEqualStrings("read_file", parsed.value.tool);
    try testing.expectEqualStrings(path, getStringArg(parsed.value.args, "path") orelse return error.TestUnexpectedResult);
}

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

test "glob supports recursive directory pattern" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try args.put(allocator, "pattern", .{ .string = "src/**/*" });

    const result = try execute(allocator, .{ .tool = "glob", .args = .{ .object = args } }, null);
    try testing.expect(std.mem.indexOf(u8, result, "src/tui.zig") != null);
}

test "glob excludes .gitignore matches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try args.put(allocator, "pattern", .{ .string = ".gitignore" });

    const result = try execute(allocator, .{ .tool = "glob", .args = .{ .object = args } }, null);
    try testing.expect(std.mem.indexOf(u8, result, ".gitignore") == null);
}

test "glob recursive excludes ignored directories" {
    const base_dir = ".tmp-glob-excluded-dirs";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, base_dir) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, base_dir) catch {};

    try std.Io.Dir.cwd().makePath(std.Options.debug_io, base_dir ++ std.fs.path.sep_str ++ "ok");
    try std.Io.Dir.cwd().makePath(std.Options.debug_io, base_dir ++ std.fs.path.sep_str ++ ".git");
    try std.Io.Dir.cwd().makePath(std.Options.debug_io, base_dir ++ std.fs.path.sep_str ++ ".zig-cache");
    try std.Io.Dir.cwd().makePath(std.Options.debug_io, base_dir ++ std.fs.path.sep_str ++ "zig-pkg");
    try std.Io.Dir.cwd().makePath(std.Options.debug_io, base_dir ++ std.fs.path.sep_str ++ "zig-out");

    {
        var file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, base_dir ++ std.fs.path.sep_str ++ "ok" ++ std.fs.path.sep_str ++ "keep.zig", .{});
        defer file.close(std.Options.debug_io);
    }
    {
        var file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, base_dir ++ std.fs.path.sep_str ++ ".git" ++ std.fs.path.sep_str ++ "skip.zig", .{});
        defer file.close(std.Options.debug_io);
    }
    {
        var file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, base_dir ++ std.fs.path.sep_str ++ ".zig-cache" ++ std.fs.path.sep_str ++ "skip.zig", .{});
        defer file.close(std.Options.debug_io);
    }
    {
        var file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, base_dir ++ std.fs.path.sep_str ++ "zig-pkg" ++ std.fs.path.sep_str ++ "skip.zig", .{});
        defer file.close(std.Options.debug_io);
    }
    {
        var file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, base_dir ++ std.fs.path.sep_str ++ "zig-out" ++ std.fs.path.sep_str ++ "skip.zig", .{});
        defer file.close(std.Options.debug_io);
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try args.put(allocator, "pattern", .{ .string = "**/*.zig" });
    try args.put(allocator, "path", .{ .string = base_dir });

    const result = try execute(allocator, .{ .tool = "glob", .args = .{ .object = args } }, null);
    try testing.expect(std.mem.indexOf(u8, result, "keep.zig") != null);
    try testing.expect(std.mem.indexOf(u8, result, ".git") == null);
    try testing.expect(std.mem.indexOf(u8, result, ".zig-cache") == null);
    try testing.expect(std.mem.indexOf(u8, result, "zig-pkg") == null);
    try testing.expect(std.mem.indexOf(u8, result, "zig-out") == null);
}

test "edit exact replacement still works" {
    const path = ".tmp-edit-exact-test.txt";
    std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch {};

    {
        var file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, path, .{});
        defer file.close(std.Options.debug_io);
        try std.Io.File.writeStreamingAll(file, std.Options.debug_io, "alpha\nbeta\n");
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try editFile(allocator, path, "beta", "gamma", null);
    try testing.expect(std.mem.indexOf(u8, result, "Edited") != null);

    const content = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(1024));
    try testing.expectEqualStrings("alpha\ngamma\n", content);
}

test "edit whitespace-tolerant single-line replacement preserves indentation" {
    const path = ".tmp-edit-whitespace-test.html";
    std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch {};

    {
        var file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, path, .{});
        defer file.close(std.Options.debug_io);
        try std.Io.File.writeStreamingAll(file, std.Options.debug_io, "<html>\n    <title>Old</title>   \n</html>\n");
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try editFile(allocator, path, "\t<title>Old</title>", "  <title>New</title>", null);
    try testing.expect(std.mem.indexOf(u8, result, "Edited") != null);

    const content = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(1024));
    try testing.expectEqualStrings("<html>\n    <title>New</title>\n</html>\n", content);
}

test "edit ambiguous whitespace-tolerant matches return an error" {
    const path = ".tmp-edit-ambiguous-test.html";
    std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch {};

    {
        var file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, path, .{});
        defer file.close(std.Options.debug_io);
        try std.Io.File.writeStreamingAll(file, std.Options.debug_io, "  <title>Same</title>\n    <title>Same</title>\n");
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try editFile(allocator, path, "\t<title>Same</title>", "<title>New</title>", null);
    try testing.expect(std.mem.indexOf(u8, result, "ambiguous") != null);
}

pub fn executeWithConfirm(allocator: std.mem.Allocator, req: ToolRequest, confirmer: ?Confirm, highlighter: ?*syntax_highlight.SyntaxHighlighter) ![]u8 {
    if (std.mem.eql(u8, req.tool, "read_file")) return readFile(allocator, getStringArg(req.args, "path") orelse return error.InvalidToolArgs, getUsizeArg(req.args, "offset"), getUsizeArg(req.args, "limit"));
    if (std.mem.eql(u8, req.tool, "write_file")) return writeFile(
        allocator,
        getStringArg(req.args, "path") orelse return error.InvalidToolArgs,
        getStringArg(req.args, "content") orelse return error.InvalidToolArgs,
        confirmer,
        highlighter,
    );
    if (std.mem.eql(u8, req.tool, "list_files")) return listFiles(allocator, getStringArg(req.args, "path") orelse ".");
    if (std.mem.eql(u8, req.tool, "run_shell")) return runShell(allocator, getStringArg(req.args, "command") orelse return error.InvalidToolArgs, confirmer);
    if (std.mem.eql(u8, req.tool, "glob")) return globFiles(allocator, getStringArg(req.args, "pattern") orelse return error.InvalidToolArgs, getStringArg(req.args, "path"));
    if (std.mem.eql(u8, req.tool, "grep")) return grepFiles(
        allocator,
        getStringArg(req.args, "pattern") orelse return error.InvalidToolArgs,
        getStringArg(req.args, "path"),
        getStringArg(req.args, "include"),
        getBoolArg(req.args, "case_sensitive") orelse false,
        getUsizeArg(req.args, "context"),
    );
    if (std.mem.eql(u8, req.tool, "edit")) return editFile(allocator, getStringArg(req.args, "path") orelse return error.InvalidToolArgs, getStringArg(req.args, "oldString") orelse return error.InvalidToolArgs, getStringArg(req.args, "newString") orelse return error.InvalidToolArgs, highlighter);
    return std.fmt.allocPrint(allocator, "Error: Unknown tool: {s}", .{req.tool});
}

fn getStringArg(args: std.json.Value, name: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const value = args.object.get(name) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getUsizeArg(args: std.json.Value, name: []const u8) ?usize {
    if (args != .object) return null;
    const value = args.object.get(name) orelse return null;
    return switch (value) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .string => |s| std.fmt.parseUnsigned(usize, s, 10) catch null,
        else => null,
    };
}

fn getBoolArg(args: std.json.Value, name: []const u8) ?bool {
    if (args != .object) return null;
    const value = args.object.get(name) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn confirm(prompt: []const u8, confirmer: ?Confirm) !bool {
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

fn resolveInsideCwd(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return error.PathOutsideCwd;

    const cwd = try std.process.currentPathAlloc(std.Options.debug_io, allocator);
    defer allocator.free(cwd);

    if (hasParentTraversal(path)) return error.PathOutsideCwd;

    return try std.fs.path.join(allocator, &.{ cwd, path });
}

fn hasParentTraversal(path: []const u8) bool {
    var it = std.fs.path.componentIterator(path);
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp.name, "..")) return true;
    }
    return false;
}

pub const max_read_lines: usize = 300;
const max_grep_matches: usize = 20;

/// Read file contents with optional offset and limit
fn readFile(allocator: std.mem.Allocator, path: []const u8, offset: ?usize, limit: ?usize) ![]u8 {
    const full_path = resolveInsideCwd(allocator, path) catch |err| {
        return switch (err) {
            error.PathOutsideCwd => std.fmt.allocPrint(allocator, "Error: Path must be relative and within current directory", .{}),
            else => std.fmt.allocPrint(allocator, "Error resolving path: {s}", .{@errorName(err)}),
        };
    };
    defer allocator.free(full_path);

    const content = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, full_path, allocator, .limited(1024 * 1024)) catch |err| {
        return std.fmt.allocPrint(allocator, "Error reading file: {s}", .{@errorName(err)});
    };
    const line_limit = @min(limit orelse max_read_lines, max_read_lines);

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var line_number: usize = 1;
    var returned: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| : (line_number += 1) {
        if (line_number < (offset orelse 1)) continue;
        if (returned >= line_limit) break;

        try result.print(allocator, "{d}: {s}\n", .{ line_number, line });
        returned += 1;
    }

    if (returned == 0 and (offset orelse 1) > line_number) {
        allocator.free(content);
        return std.fmt.allocPrint(allocator, "[offset line {d} exceeds file length {d}]", .{ offset orelse 1, line_number - 1 });
    }

    const end_line = if (returned > 0) (offset orelse 1) + returned - 1 else (offset orelse 1);
    const body = try result.toOwnedSlice(allocator);
    defer allocator.free(body);
    allocator.free(content);

    return std.fmt.allocPrint(allocator, "File: {s}\nRead line range: {d}-{d}\nTo continue after this range, call read_file with offset={d}.\nTo inspect a grep match at line N, call read_file with offset=N exactly. Do not shorten, round, or drop digits from line numbers.\n{s}", .{ path, offset orelse 1, end_line, end_line + 1, body });
}

/// Write file with confirmation for existing files
fn writeFile(allocator: std.mem.Allocator, path: []const u8, content: []const u8, confirmer: ?Confirm, highlighter: ?*syntax_highlight.SyntaxHighlighter) ![]u8 {
    const full_path = resolveInsideCwd(allocator, path) catch |err| {
        return switch (err) {
            error.PathOutsideCwd => std.fmt.allocPrint(allocator, "Error: Path must be relative and within current directory", .{}),
            else => std.fmt.allocPrint(allocator, "Error resolving path: {s}", .{@errorName(err)}),
        };
    };
    defer allocator.free(full_path);

    const exists = exists: {
        _ = std.Io.Dir.openFileAbsolute(std.Options.debug_io, full_path, .{}) catch |err| {
            if (err == error.FileNotFound) break :exists false;
            return std.fmt.allocPrint(allocator, "Error checking file: {s}", .{@errorName(err)});
        };
        break :exists true;
    };

    var old_content: ?[]u8 = null;
    defer if (old_content) |o| allocator.free(o);

    if (exists) {
        if (confirmer) |c| {
            if (!(try confirm(std.fmt.allocPrint(allocator, "Overwrite {s}?", .{path}) catch return error.OutOfMemory, c))) {
                return std.fmt.allocPrint(allocator, "Write cancelled", .{});
            }
        }
        // Read old content for diff
        old_content = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, full_path, allocator, .limited(1024 * 1024)) catch null;
    }

    var file = std.Io.Dir.createFileAbsolute(std.Options.debug_io, full_path, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "Error creating file: {s}", .{@errorName(err)});
    };
    defer file.close(std.Options.debug_io);

    std.Io.File.writeStreamingAll(file, std.Options.debug_io, content) catch |err| {
        return std.fmt.allocPrint(allocator, "Error writing file: {s}", .{@errorName(err)});
    };

    if (old_content) |old| {
        const diff_text = try diffAlloc(allocator, old, content, path, highlighter);
        defer allocator.free(diff_text);
        return std.fmt.allocPrint(allocator, "Updated {s}\n{s}", .{ path, diff_text });
    } else {
        return std.fmt.allocPrint(allocator, "Created {s} [new file]", .{path});
    }
}

/// List directory contents
fn listFiles(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const full_path = resolveInsideCwd(allocator, path) catch |err| {
        return switch (err) {
            error.PathOutsideCwd => std.fmt.allocPrint(allocator, "Error: Path must be relative and within current directory", .{}),
            else => std.fmt.allocPrint(allocator, "Error resolving path: {s}", .{@errorName(err)}),
        };
    };
    defer allocator.free(full_path);

    var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, full_path, .{ .iterate = true }) catch |err| {
        return std.fmt.allocPrint(allocator, "Error opening directory: {s}", .{@errorName(err)});
    };
    defer dir.close(std.Options.debug_io);

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var it = dir.iterate();
    while (try it.next(std.Options.debug_io)) |entry| {
        try result.append(allocator, if (entry.kind == .directory) 'd' else ' ');
        try result.append(allocator, ' ');
        try result.appendSlice(allocator, entry.name);
        try result.append(allocator, '\n');
    }

    return result.toOwnedSlice(allocator);
}

/// Run shell command with confirmation
fn runShell(allocator: std.mem.Allocator, command: []const u8, confirmer: ?Confirm) ![]u8 {
    if (confirmer) |c| {
        if (!(try confirm(std.fmt.allocPrint(allocator, "Run: {s}", .{command}) catch return error.OutOfMemory, c))) {
            return std.fmt.allocPrint(allocator, "Command cancelled", .{});
        }
    }

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    var it = std.mem.splitScalar(u8, command, ' ');
    while (it.next()) |arg| {
        if (arg.len > 0) try argv.append(allocator, arg);
    }

    if (argv.items.len == 0) return std.fmt.allocPrint(allocator, "Error: empty command", .{});

    var child = std.process.spawn(std.Options.debug_io, .{
        .argv = argv.items,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        return std.fmt.allocPrint(allocator, "Error running command: {s}", .{@errorName(err)});
    };
    defer _ = child.wait(std.Options.debug_io) catch {};

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    // Read stdout
    if (child.stdout) |stdout_file| {
        var buf: [4096]u8 = undefined;
        while (true) {
            var vecs = [_][]u8{buf[0..]};
            const n = stdout_file.readStreaming(std.Options.debug_io, &vecs) catch break;
            if (n == 0) break;
            try output.appendSlice(allocator, buf[0..n]);
        }
    }

    // Read stderr
    if (child.stderr) |stderr_file| {
        var buf: [4096]u8 = undefined;
        while (true) {
            var vecs = [_][]u8{buf[0..]};
            const n = stderr_file.readStreaming(std.Options.debug_io, &vecs) catch break;
            if (n == 0) break;
            if (output.items.len > 0) try output.append(allocator, '\n');
            try output.appendSlice(allocator, buf[0..n]);
        }
    }

    return output.toOwnedSlice(allocator);
}

/// Find files matching a glob pattern (e.g., "**/*.zig" or "src/**/*.zig")
fn globFiles(allocator: std.mem.Allocator, pattern: []const u8, search_path: ?[]const u8) ![]u8 {
    // Validate pattern doesn't escape cwd
    if (hasParentTraversal(pattern)) return std.fmt.allocPrint(allocator, "Error: Pattern cannot contain ..", .{});

    // If pattern starts with **, search from cwd; otherwise search from search_path or cwd
    const base_path = search_path orelse ".";
    if (hasParentTraversal(base_path)) return std.fmt.allocPrint(allocator, "Error: Search path cannot contain ..", .{});
    if (pathContainsExcludedGlobDir(base_path)) return allocator.dupe(u8, "");

    const full_base = resolveInsideCwd(allocator, base_path) catch |err| {
        return switch (err) {
            error.PathOutsideCwd => std.fmt.allocPrint(allocator, "Error: Path must be relative and within current directory", .{}),
            else => std.fmt.allocPrint(allocator, "Error resolving path: {s}", .{@errorName(err)}),
        };
    };
    defer allocator.free(full_base);

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    // Common recursive directory form: src/**/* means all files below src/.
    if (std.mem.endsWith(u8, pattern, "/**/*")) {
        const recursive_base = pattern[0 .. pattern.len - "/**/*".len];
        if (hasParentTraversal(recursive_base)) return std.fmt.allocPrint(allocator, "Error: Pattern cannot contain ..", .{});
        const full_recursive_base = resolveInsideCwd(allocator, recursive_base) catch |err| {
            return switch (err) {
                error.PathOutsideCwd => std.fmt.allocPrint(allocator, "Error: Path must be relative and within current directory", .{}),
                else => std.fmt.allocPrint(allocator, "Error resolving path: {s}", .{@errorName(err)}),
            };
        };
        defer allocator.free(full_recursive_base);
        try globRecursive(allocator, full_recursive_base, "*", &result);
        return result.toOwnedSlice(allocator);
    }

    // Check if pattern starts with ** (recursive search from base)
    const is_recursive = std.mem.startsWith(u8, pattern, "**/");
    const file_pattern = if (is_recursive) pattern[3..] else pattern;

    if (is_recursive) {
        try globRecursive(allocator, full_base, file_pattern, &result);
    } else {
        // Non-recursive: just list files in base directory and filter
        var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, full_base, .{ .iterate = true }) catch |err| {
            return std.fmt.allocPrint(allocator, "Error opening directory: {s}", .{@errorName(err)});
        };
        defer dir.close(std.Options.debug_io);

        var it = dir.iterate();
        while (try it.next(std.Options.debug_io)) |entry| {
            if (entry.kind == .directory) continue;
            if (std.mem.eql(u8, entry.name, ".gitignore")) continue;
            if (!globMatch(entry.name, file_pattern)) continue;
            const rel_path = try std.fs.path.join(allocator, &.{ base_path, entry.name });
            defer allocator.free(rel_path);
            try result.appendSlice(allocator, rel_path);
            try result.append(allocator, '\n');
        }
    }

    return result.toOwnedSlice(allocator);
}

fn globRecursive(allocator: std.mem.Allocator, dir_path: []const u8, pattern: []const u8, results: *std.ArrayList(u8)) !void {
    var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(std.Options.debug_io);

    var it = dir.iterate();
    while (try it.next(std.Options.debug_io)) |entry| {
        if (entry.kind == .directory) {
            // Skip hidden directories and common build/cache directories
            if (entry.name[0] == '.' or
                std.mem.eql(u8, entry.name, "zig-cache") or
                std.mem.eql(u8, entry.name, "zig-out") or
                std.mem.eql(u8, entry.name, "node_modules") or
                std.mem.eql(u8, entry.name, ".zig-cache") or
                std.mem.eql(u8, entry.name, "zig-pkg") or
                std.mem.eql(u8, entry.name, ".git")) continue;

            const sub_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            defer allocator.free(sub_path);
            try globRecursive(allocator, sub_path, pattern, results);
        } else if (entry.kind == .file) {
            if (std.mem.eql(u8, entry.name, ".gitignore")) continue;
            if (!globMatch(entry.name, pattern)) continue;
            const rel_path = try relativeDisplayPath(allocator, dir_path);
            defer allocator.free(rel_path);
            if (rel_path.len > 0) {
                try results.appendSlice(allocator, rel_path);
                try results.append(allocator, std.fs.path.sep);
            }
            try results.appendSlice(allocator, entry.name);
            try results.append(allocator, '\n');
        }
    }
}

fn isExcludedGlobDirName(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, "zig-pkg") or
        std.mem.eql(u8, name, "zig-out");
}

fn pathContainsExcludedGlobDir(path: []const u8) bool {
    var it = std.fs.path.componentIterator(path);
    while (it.next()) |component| {
        if (isExcludedGlobDirName(component.name)) return true;
    }
    return false;
}

/// Match a filename against a glob pattern (supports * and ? wildcards only)
fn globMatch(filename: []const u8, pattern: []const u8) bool {
    var f: usize = 0;
    var p: usize = 0;

    while (p < pattern.len) {
        if (f >= filename.len) {
            // Pattern has more chars but filename is done
            // Only match if remaining pattern chars are *
            while (p < pattern.len and pattern[p] == '*') p += 1;
            return p == pattern.len;
        }

        switch (pattern[p]) {
            '*' => {
                // Try to match the rest of the pattern against remaining filename
                var f2 = f;
                while (f2 <= filename.len) : (f2 += 1) {
                    if (globMatch(filename[f2..], pattern[p + 1 ..])) return true;
                }
                return false;
            },
            '?' => {
                // Match any single char
                f += 1;
                p += 1;
            },
            else => {
                if (filename[f] != pattern[p]) return false;
                f += 1;
                p += 1;
            },
        }
    }

    return f == filename.len;
}

fn includeGlobMatches(filename: []const u8, rel_path: []const u8, pattern: []const u8) bool {
    if (globMatch(filename, pattern) or globMatch(rel_path, pattern)) return true;
    if (std.mem.startsWith(u8, rel_path, "./")) {
        return globMatch(rel_path[2..], pattern);
    }
    return false;
}

const RegexError = error{
    EmptyPattern,
    PatternTooLong,
    UnclosedClass,
    BadEscape,
    InvalidQuantifierPlacement,
};

fn regexErrorName(err: RegexError) []const u8 {
    return switch (err) {
        error.EmptyPattern => "empty pattern",
        error.PatternTooLong => "pattern too long (max 100 chars)",
        error.UnclosedClass => "unclosed character class",
        error.BadEscape => "bad escape sequence",
        error.InvalidQuantifierPlacement => "invalid quantifier placement",
    };
}

fn regexErrorAnsi(allocator: std.mem.Allocator, err: RegexError) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[31mError: invalid regex pattern ({s})\x1b[0m", .{regexErrorName(err)});
}

fn isRegexMeta(ch: u8) bool {
    return ch == '.' or ch == '*' or ch == '+' or ch == '?' or ch == '[' or ch == ']' or ch == '^' or ch == '$' or ch == '\\';
}

fn hasRegexMetacharacters(pattern: []const u8) bool {
    for (pattern) |ch| {
        if (isRegexMeta(ch)) return true;
    }
    return false;
}

/// Search file contents for a substring pattern
fn grepFiles(allocator: std.mem.Allocator, pattern: []const u8, search_path: ?[]const u8, include_pattern: ?[]const u8, case_sensitive: bool, context: ?usize) ![]u8 {
    if (pattern.len == 0) return regexErrorAnsi(allocator, error.EmptyPattern);
    if (pattern.len > 100) return regexErrorAnsi(allocator, error.PatternTooLong);

    _ = validateRegexPattern(pattern) catch |err| {
        if (@TypeOf(err) == RegexError) {
            return regexErrorAnsi(allocator, err);
        }
        return err;
    };

    const search_dir = if (search_path) |p| p else ".";
    if (hasParentTraversal(search_dir)) return std.fmt.allocPrint(allocator, "Error: Search path cannot contain ..", .{});

    const full_path = resolveInsideCwd(allocator, search_dir) catch |err| {
        return switch (err) {
            error.PathOutsideCwd => std.fmt.allocPrint(allocator, "Error: Path must be relative and within current directory", .{}),
            else => std.fmt.allocPrint(allocator, "Error resolving path: {s}", .{@errorName(err)}),
        };
    };
    defer allocator.free(full_path);

    var results = std.ArrayList(u8).empty;
    defer results.deinit(allocator);
    var match_count: usize = 0;
    var files_searched: usize = 0;

    if (std.Io.Dir.openDirAbsolute(std.Options.debug_io, full_path, .{ .iterate = true })) |dir| {
        var mutable_dir = dir;
        mutable_dir.close(std.Options.debug_io);
        try grepRecursive(allocator, full_path, pattern, include_pattern, case_sensitive, context, &results, &match_count, &files_searched);
    } else |_| if (std.Io.Dir.openFileAbsolute(std.Options.debug_io, full_path, .{})) |file| {
        file.close(std.Options.debug_io);
        const filename = std.fs.path.basename(full_path);
        const include_matches = if (include_pattern) |inc| blk: {
            const rel_path = try relativeDisplayPath(allocator, full_path);
            defer allocator.free(rel_path);
            break :blk includeGlobMatches(filename, rel_path, inc);
        } else true;
        if (!isBinaryFile(filename) and include_matches) {
            files_searched += 1;
            try searchInFile(allocator, full_path, pattern, case_sensitive, context, &results, &match_count);
        }
    } else |err| switch (err) {
        else => return std.fmt.allocPrint(allocator, "Error opening path: {s}", .{@errorName(err)}),
    }

    if (match_count == 0) {
        return std.fmt.allocPrint(allocator, "No matches for '{s}' in {d} files searched", .{ pattern, files_searched });
    }
    const capped = if (match_count >= max_grep_matches) " (showing first 20)" else "";
    return std.fmt.allocPrint(allocator, "Found {d} matches in {d} files{s}:\n{s}", .{ match_count, files_searched, capped, results.items });
}

fn grepRecursive(allocator: std.mem.Allocator, dir_path: []const u8, pattern: []const u8, include_pattern: ?[]const u8, case_sensitive: bool, context: ?usize, results: *std.ArrayList(u8), match_count: *usize, files_searched: *usize) !void {
    if (match_count.* >= max_grep_matches) return;

    var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(std.Options.debug_io);

    var it = dir.iterate();
    while (try it.next(std.Options.debug_io)) |entry| {
        if (match_count.* >= max_grep_matches) return;

        const entry_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(entry_path);

        if (entry.kind == .directory) {
            if (entry.name[0] == '.' or
                std.mem.eql(u8, entry.name, "zig-cache") or
                std.mem.eql(u8, entry.name, "zig-out") or
                std.mem.eql(u8, entry.name, "node_modules") or
                std.mem.eql(u8, entry.name, ".git")) continue;
            try grepRecursive(allocator, entry_path, pattern, include_pattern, case_sensitive, context, results, match_count, files_searched);
        } else if (entry.kind == .file) {
            const include_matches = if (include_pattern) |inc| blk: {
                const rel_path = try relativeDisplayPath(allocator, entry_path);
                defer allocator.free(rel_path);
                break :blk includeGlobMatches(entry.name, rel_path, inc);
            } else true;
            if (!isBinaryFile(entry.name) and include_matches) {
                files_searched.* += 1;
                try searchInFile(allocator, entry_path, pattern, case_sensitive, context, results, match_count);
            }
        }
    }
}

fn isBinaryFile(filename: []const u8) bool {
    const binary_exts = [_][]const u8{
        ".exe", ".dll", ".so",   ".dylib", ".bin",
        ".png", ".jpg", ".jpeg", ".gif",   ".bmp",
        ".ico", ".mp3", ".mp4",  ".avi",   ".mov",
        ".wav", ".zip", ".tar",  ".gz",    ".bz2",
        ".7z",  ".rar", ".o",    ".obj",   ".a",
        ".lib", ".pdb",
    };
    const lower = std.fs.path.extension(filename);
    for (binary_exts) |ext| {
        if (std.mem.eql(u8, lower, ext)) return true;
    }
    return false;
}

fn searchInFile(allocator: std.mem.Allocator, file_path: []const u8, pattern: []const u8, case_sensitive: bool, context: ?usize, results: *std.ArrayList(u8), match_count: *usize) !void {
    if (match_count.* >= max_grep_matches) return;

    const content = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, file_path, allocator, .limited(1024 * 1024)) catch return;
    defer allocator.free(content);

    const display_path = try relativeDisplayPath(allocator, file_path);
    defer allocator.free(display_path);
    const display_path_json = try stringifyJsonString(allocator, display_path);
    defer allocator.free(display_path_json);

    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| try lines.append(allocator, line);

    var matches = std.ArrayList(usize).empty;
    defer matches.deinit(allocator);
    for (lines.items, 0..) |line, idx| {
        if (matches.items.len >= max_grep_matches) break;
        if (lineMatchesPattern(line, pattern, case_sensitive)) try matches.append(allocator, idx + 1);
    }

    const context_lines = @min(context orelse if (matches.items.len <= 3) @as(usize, 20) else @as(usize, 0), @as(usize, 50));
    for (matches.items) |line_num| {
        if (match_count.* >= max_grep_matches) return;
        const line = lines.items[line_num - 1];
        const display_line = if (line.len > 200) line[0..200] else line;
        try results.print(allocator,
            \\Match {d}
            \\File: {s}
            \\Line: {d}
            \\Text: {s}
        , .{ match_count.* + 1, display_path, line_num, display_line });

        if (context_lines > 0) {
            const start = if (line_num > context_lines) line_num - context_lines else 1;
            const end = @min(lines.items.len, line_num + context_lines);
            try results.print(allocator, "Context lines {d}-{d}:\n", .{ start, end });
            var current = start;
            while (current <= end) : (current += 1) {
                const prefix: u8 = if (current == line_num) '>' else ' ';
                const context_line = lines.items[current - 1];
                const display_context_line = if (context_line.len > 200) context_line[0..200] else context_line;
                try results.print(allocator, "{c} {d}: {s}\n", .{ prefix, current, display_context_line });
            }
        }
        try results.print(allocator,
            \\Next tool call:
            \\{{"tool":"read_file","args":{{"path":{s},"offset":{d},"limit":300}}}}
            \\
        , .{ display_path_json, line_num });
        try results.append(allocator, '\n');
        match_count.* += 1;
    }
}

fn lineMatchesPattern(line: []const u8, pattern: []const u8, case_sensitive: bool) bool {
    if (!hasRegexMetacharacters(pattern)) {
        return containsLiteral(line, pattern, case_sensitive);
    }
    return regexMatchLine(line, pattern, case_sensitive);
}

fn containsLiteral(line: []const u8, needle: []const u8, case_sensitive: bool) bool {
    if (case_sensitive) return std.mem.indexOf(u8, line, needle) != null;
    if (needle.len > line.len) return false;
    if (needle.len == 0) return true;

    var i: usize = 0;
    while (i + needle.len <= line.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(line[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

fn validateRegexPattern(pattern: []const u8) RegexError!void {
    var i: usize = 0;
    var in_class = false;
    var class_has_char = false;
    var atom_allowed = false;

    while (i < pattern.len) : (i += 1) {
        const ch = pattern[i];
        if (in_class) {
            if (ch == '\\') {
                if (i + 1 >= pattern.len) return error.BadEscape;
                i += 1;
                class_has_char = true;
                continue;
            }
            if (ch == ']') {
                if (!class_has_char) return error.UnclosedClass;
                in_class = false;
                atom_allowed = true;
                continue;
            }
            class_has_char = true;
            continue;
        }

        switch (ch) {
            '\\' => {
                if (i + 1 >= pattern.len) return error.BadEscape;
                const esc = pattern[i + 1];
                if (esc != '|' and esc != '.' and esc != '[' and esc != ']' and esc != '*' and esc != '+' and esc != '?' and esc != '^' and esc != '$' and esc != '\\') {
                    return error.BadEscape;
                }
                i += 1;
                atom_allowed = true;
            },
            '[' => {
                in_class = true;
                class_has_char = false;
                if (i + 1 < pattern.len and pattern[i + 1] == '^') i += 1;
            },
            '*', '+', '?' => {
                if (!atom_allowed) return error.InvalidQuantifierPlacement;
                atom_allowed = false;
            },
            '^', '$', '.', '|' => atom_allowed = true,
            else => atom_allowed = true,
        }
    }
    if (in_class) return error.UnclosedClass;
}

fn regexMatchLine(line: []const u8, pattern: []const u8, case_sensitive: bool) bool {
    const anchored_start = pattern.len > 0 and pattern[0] == '^';
    const pat = if (anchored_start) pattern[1..] else pattern;
    if (anchored_start) {
        return regexMatchFrom(line, 0, pat, 0, case_sensitive);
    }

    var start: usize = 0;
    while (start <= line.len) : (start += 1) {
        if (regexMatchFrom(line, start, pat, 0, case_sensitive)) return true;
    }
    return false;
}

fn charsEqual(a: u8, b: u8, case_sensitive: bool) bool {
    if (case_sensitive) return a == b;
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

fn atomMatches(line: []const u8, i: usize, pattern: []const u8, p: usize, atom_end: *usize, case_sensitive: bool) bool {
    if (i >= line.len) return false;
    if (p >= pattern.len) return false;

    if (pattern[p] == '.') {
        atom_end.* = p + 1;
        return true;
    }
    if (pattern[p] == '\\') {
        atom_end.* = p + 2;
        return charsEqual(line[i], pattern[p + 1], case_sensitive);
    }
    if (pattern[p] == '[') {
        var j = p + 1;
        var negated = false;
        if (j < pattern.len and pattern[j] == '^') {
            negated = true;
            j += 1;
        }

        var matched = false;
        while (j < pattern.len and pattern[j] != ']') {
            var left = pattern[j];
            if (left == '\\' and j + 1 < pattern.len) {
                left = pattern[j + 1];
                j += 1;
            }

            if (j + 2 < pattern.len and pattern[j + 1] == '-' and pattern[j + 2] != ']') {
                var right = pattern[j + 2];
                if (right == '\\' and j + 3 < pattern.len) {
                    right = pattern[j + 3];
                    j += 1;
                }
                const c = if (case_sensitive) line[i] else std.ascii.toLower(line[i]);
                const l = if (case_sensitive) left else std.ascii.toLower(left);
                const r = if (case_sensitive) right else std.ascii.toLower(right);
                if (c >= l and c <= r) matched = true;
                j += 3;
                continue;
            }

            if (charsEqual(line[i], left, case_sensitive)) matched = true;
            j += 1;
        }

        atom_end.* = j + 1;
        return if (negated) !matched else matched;
    }

    atom_end.* = p + 1;
    return charsEqual(line[i], pattern[p], case_sensitive);
}

fn regexMatchFrom(line: []const u8, i: usize, pattern: []const u8, p: usize, case_sensitive: bool) bool {
    if (p == pattern.len) return true;
    if (pattern[p] == '$' and p + 1 == pattern.len) return i == line.len;

    var atom_end: usize = p;
    const can_match_one = atomMatches(line, i, pattern, p, &atom_end, case_sensitive);

    const has_quantifier = atom_end < pattern.len and (pattern[atom_end] == '*' or pattern[atom_end] == '+' or pattern[atom_end] == '?');
    if (!has_quantifier) {
        if (!can_match_one) return false;
        return regexMatchFrom(line, i + 1, pattern, atom_end, case_sensitive);
    }

    const q = pattern[atom_end];
    const next_p = atom_end + 1;

    switch (q) {
        '*' => {
            var max_i = i;
            while (max_i < line.len) {
                var ae: usize = p;
                if (!atomMatches(line, max_i, pattern, p, &ae, case_sensitive)) break;
                max_i += 1;
            }
            var k = max_i;
            while (true) {
                if (regexMatchFrom(line, k, pattern, next_p, case_sensitive)) return true;
                if (k == i) break;
                k -= 1;
            }
            return false;
        },
        '+' => {
            if (!can_match_one) return false;
            var max_i = i + 1;
            while (max_i < line.len) {
                var ae: usize = p;
                if (!atomMatches(line, max_i, pattern, p, &ae, case_sensitive)) break;
                max_i += 1;
            }
            var k = max_i;
            while (true) {
                if (regexMatchFrom(line, k, pattern, next_p, case_sensitive)) return true;
                if (k == i + 1) break;
                k -= 1;
            }
            return false;
        },
        '?' => {
            if (can_match_one and regexMatchFrom(line, i + 1, pattern, next_p, case_sensitive)) return true;
            return regexMatchFrom(line, i, pattern, next_p, case_sensitive);
        },
        else => unreachable,
    }
}

fn relativeDisplayPath(allocator: std.mem.Allocator, file_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.Options.debug_io, allocator);
    defer allocator.free(cwd);

    if (std.mem.eql(u8, file_path, cwd)) return allocator.dupe(u8, ".");
    if (std.mem.startsWith(u8, file_path, cwd) and file_path.len > cwd.len and file_path[cwd.len] == std.fs.path.sep) {
        return allocator.dupe(u8, file_path[cwd.len + 1 ..]);
    }
    return allocator.dupe(u8, file_path);
}

/// Edit a file by replacing oldString with newString
fn editFile(allocator: std.mem.Allocator, path: []const u8, old_string: []const u8, new_string: []const u8, highlighter: ?*syntax_highlight.SyntaxHighlighter) ![]u8 {
    const full_path = resolveInsideCwd(allocator, path) catch |err| {
        return switch (err) {
            error.PathOutsideCwd => std.fmt.allocPrint(allocator, "Error: Path must be relative and within current directory", .{}),
            else => std.fmt.allocPrint(allocator, "Error resolving path: {s}", .{@errorName(err)}),
        };
    };
    defer allocator.free(full_path);

    const content = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, full_path, allocator, .limited(1024 * 1024)) catch |err| {
        return std.fmt.allocPrint(allocator, "Error reading file: {s}", .{@errorName(err)});
    };
    defer allocator.free(content);

    const match_count = std.mem.count(u8, content, old_string);
    if (match_count > 1) return std.fmt.allocPrint(allocator, "Error: oldString matches {d} locations, must be unique", .{match_count});
    if (match_count == 0 and !isSingleLine(old_string)) return oldStringNotFoundError(allocator, path, content, old_string);

    const new_content = if (match_count == 1)
        try std.mem.replaceOwned(u8, allocator, content, old_string, new_string)
    else
        try whitespaceTolerantSingleLineEdit(allocator, path, content, old_string, new_string);
    defer allocator.free(new_content);

    var file = std.Io.Dir.createFileAbsolute(std.Options.debug_io, full_path, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "Error creating file: {s}", .{@errorName(err)});
    };
    defer file.close(std.Options.debug_io);

    std.Io.File.writeStreamingAll(file, std.Options.debug_io, new_content) catch |err| {
        return std.fmt.allocPrint(allocator, "Error writing file: {s}", .{@errorName(err)});
    };

    const diff_text = try diffAlloc(allocator, content, new_content, path, highlighter);
    defer allocator.free(diff_text);
    return std.fmt.allocPrint(allocator, "Edited {s}\n{s}", .{ path, diff_text });
}

fn isSingleLine(text: []const u8) bool {
    return std.mem.indexOfAny(u8, text, "\r\n") == null;
}

fn whitespaceTolerantSingleLineEdit(allocator: std.mem.Allocator, path: []const u8, content: []const u8, old_string: []const u8, new_string: []const u8) ![]u8 {
    const trimmed_old = std.mem.trim(u8, old_string, " \t\r\n");
    const trimmed_new = std.mem.trim(u8, new_string, " \t\r\n");

    var matches = std.ArrayList(LineMatch).empty;
    defer matches.deinit(allocator);

    var it = lineIterator(content);
    while (it.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line.text, " \t\r\n"), trimmed_old)) {
            try matches.append(allocator, line);
        }
    }

    if (matches.items.len == 0) return oldStringNotFoundError(allocator, path, content, old_string);
    if (matches.items.len > 1) return ambiguousWhitespaceEditError(allocator, matches.items);

    const match = matches.items[0];
    const trimmed_line = std.mem.trim(u8, match.text, " \t\r\n");
    const trim_start = @intFromPtr(trimmed_line.ptr) - @intFromPtr(match.text.ptr);

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, content[0..match.start]);
    try result.appendSlice(allocator, match.text[0..trim_start]);
    try result.appendSlice(allocator, trimmed_new);
    try result.appendSlice(allocator, match.newline);
    try result.appendSlice(allocator, content[match.end..]);
    return result.toOwnedSlice(allocator);
}

const LineMatch = struct {
    number: usize,
    start: usize,
    end: usize,
    text: []const u8,
    newline: []const u8,
};

const LineIterator = struct {
    content: []const u8,
    index: usize = 0,
    number: usize = 1,

    fn next(self: *LineIterator) ?LineMatch {
        if (self.index >= self.content.len) return null;

        const start = self.index;
        var line_end = start;
        while (line_end < self.content.len and self.content[line_end] != '\n') line_end += 1;

        var text_end = line_end;
        if (text_end > start and self.content[text_end - 1] == '\r') text_end -= 1;

        const newline_end = if (line_end < self.content.len) line_end + 1 else line_end;
        const line = LineMatch{
            .number = self.number,
            .start = start,
            .end = newline_end,
            .text = self.content[start..text_end],
            .newline = self.content[text_end..newline_end],
        };

        self.index = newline_end;
        self.number += 1;
        return line;
    }
};

fn lineIterator(content: []const u8) LineIterator {
    return .{ .content = content };
}

fn ambiguousWhitespaceEditError(allocator: std.mem.Allocator, matches: []const LineMatch) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, "Error: oldString whitespace-normalized match is ambiguous at lines: ");
    for (matches, 0..) |match, i| {
        if (i > 0) try result.appendSlice(allocator, ", ");
        try result.print(allocator, "{d}", .{match.number});
    }
    return result.toOwnedSlice(allocator);
}

fn oldStringNotFoundError(allocator: std.mem.Allocator, path: []const u8, content: []const u8, old_string: []const u8) ![]u8 {
    const token = usefulToken(old_string) orelse return std.fmt.allocPrint(allocator, "Error: oldString not found in {s}", .{path});

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try result.print(allocator, "Error: oldString not found in {s}", .{path});

    var shown: usize = 0;
    var it = lineIterator(content);
    while (it.next()) |line| {
        if (containsIgnoreCase(line.text, token)) {
            if (shown == 0) try result.print(allocator, "\nNearby candidates containing '{s}':", .{token});
            const trimmed = std.mem.trim(u8, line.text, " \t\r\n");
            const display = trimmed[0..@min(trimmed.len, 120)];
            try result.print(allocator, "\n  line {d}: {s}", .{ line.number, display });
            shown += 1;
            if (shown == 5) break;
        }
    }

    return result.toOwnedSlice(allocator);
}

fn usefulToken(text: []const u8) ?[]const u8 {
    var start: ?usize = null;
    for (text, 0..) |c, i| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
            if (start == null) start = i;
        } else if (start) |s| {
            if (i - s >= 2) return text[s..i];
            start = null;
        }
    }
    if (start) |s| {
        if (text.len - s >= 2) return text[s..];
    }
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Compute a side-by-side diff between old and new content
fn diffAlloc(allocator: std.mem.Allocator, old_content: []const u8, new_content: []const u8, path: []const u8, highlighter: ?*syntax_highlight.SyntaxHighlighter) ![]u8 {
    _ = path;
    _ = highlighter;
    var old_lines = std.ArrayList([]const u8).empty;
    defer old_lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, old_content, '\n');
    while (it.next()) |line| try old_lines.append(allocator, line);

    var new_lines = std.ArrayList([]const u8).empty;
    defer new_lines.deinit(allocator);
    it = std.mem.splitScalar(u8, new_content, '\n');
    while (it.next()) |line| try new_lines.append(allocator, line);

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    const LineDiff = struct {
        old_line: ?usize,
        new_line: ?usize,
        old_idx: ?usize,
        new_idx: ?usize,
    };

    var diff_lines = std.ArrayList(LineDiff).empty;
    defer diff_lines.deinit(allocator);

    // Compute diff using LCS
    const lcs = try computeLcs(allocator, old_lines.items, new_lines.items);
    defer allocator.free(lcs);

    var old_idx: usize = 0;
    var new_idx: usize = 0;
    var lcs_idx: usize = 0;

    while (old_idx < old_lines.items.len or new_idx < new_lines.items.len) {
        if (lcs_idx < lcs.len and old_idx < old_lines.items.len and new_idx < new_lines.items.len and
            std.mem.eql(u8, old_lines.items[old_idx], new_lines.items[new_idx]) and std.mem.eql(u8, old_lines.items[old_idx], lcs[lcs_idx]))
        {
            // Unchanged line
            try diff_lines.append(allocator, .{
                .old_line = old_idx + 1,
                .new_line = new_idx + 1,
                .old_idx = old_idx,
                .new_idx = new_idx,
            });
            old_idx += 1;
            new_idx += 1;
            lcs_idx += 1;
        } else if (lcs_idx < lcs.len and old_idx < old_lines.items.len and std.mem.eql(u8, old_lines.items[old_idx], lcs[lcs_idx])) {
            // Line added in new
            try diff_lines.append(allocator, .{
                .old_line = null,
                .new_line = new_idx + 1,
                .old_idx = null,
                .new_idx = new_idx,
            });
            new_idx += 1;
        } else if (lcs_idx < lcs.len and new_idx < new_lines.items.len and std.mem.eql(u8, new_lines.items[new_idx], lcs[lcs_idx])) {
            // Line removed from old
            try diff_lines.append(allocator, .{
                .old_line = old_idx + 1,
                .new_line = null,
                .old_idx = old_idx,
                .new_idx = null,
            });
            old_idx += 1;
        } else if (old_idx < old_lines.items.len and new_idx < new_lines.items.len) {
            // Changed line
            try diff_lines.append(allocator, .{
                .old_line = old_idx + 1,
                .new_line = new_idx + 1,
                .old_idx = old_idx,
                .new_idx = new_idx,
            });
            old_idx += 1;
            new_idx += 1;
        } else if (old_idx < old_lines.items.len) {
            // Line removed
            try diff_lines.append(allocator, .{
                .old_line = old_idx + 1,
                .new_line = null,
                .old_idx = old_idx,
                .new_idx = null,
            });
            old_idx += 1;
        } else if (new_idx < new_lines.items.len) {
            // Line added
            try diff_lines.append(allocator, .{
                .old_line = null,
                .new_line = new_idx + 1,
                .old_idx = null,
                .new_idx = new_idx,
            });
            new_idx += 1;
        }
    }

    if (diff_lines.items.len == 0) {
        return try allocator.dupe(u8, "(no changes)");
    }

    // ANSI color codes
    const red_bg = "\x1b[48;2;69;40;48m"; // Dark red background (like in screenshot)
    const green_bg = "\x1b[48;2;40;69;48m"; // Dark green background (like in screenshot)
    const dim_text = "\x1b[38;5;245m"; // Dim gray for context lines
    const normal_text = "\x1b[0m"; // Reset

    // Fixed column positions for alignment
    const left_content_width = 45; // Max width for left side content

    // Render side-by-side diff
    for (diff_lines.items) |dl| {
        const is_change = dl.old_line == null or dl.new_line == null or
            (dl.old_idx != null and dl.new_idx != null and
                !std.mem.eql(u8, old_lines.items[dl.old_idx.?], new_lines.items[dl.new_idx.?]));

        // Old side (left) - line number (4) + 2 spaces = 6 chars, content truncated to left_content_width
        if (dl.old_line) |ln| {
            const color = if (is_change) red_bg else dim_text;

            // Use plain text for diff (syntax highlighting is complex with diff backgrounds)
            const plain_text = old_lines.items[dl.old_idx.?];

            if (plain_text.len > left_content_width) {
                try result.print(allocator, "{s}{d: >4}  {s}…{s}", .{ color, ln, plain_text[0..left_content_width], normal_text });
            } else {
                const padding = left_content_width - plain_text.len;
                try result.print(allocator, "{s}{d: >4}  {s}", .{ color, ln, plain_text });
                try result.appendNTimes(allocator, ' ', padding);
                try result.appendSlice(allocator, normal_text);
            }
        } else {
            // Empty on old side - fill with spaces to maintain alignment
            try result.appendNTimes(allocator, ' ', 6 + left_content_width);
        }

        // Gap between sides
        try result.appendSlice(allocator, "    ");

        // New side (right) - always starts at same column
        if (dl.new_line) |ln| {
            const color = if (is_change) green_bg else dim_text;

            // Use plain text for diff (syntax highlighting is complex with diff backgrounds)
            const plain_text = new_lines.items[dl.new_idx.?];

            if (plain_text.len > left_content_width) {
                try result.print(allocator, "{s}{d: >4}  {s}…{s}\n", .{ color, ln, plain_text[0..left_content_width], normal_text });
            } else {
                try result.print(allocator, "{s}{d: >4}  {s}{s}\n", .{ color, ln, plain_text, normal_text });
            }
        } else {
            // Empty on new side
            try result.print(allocator, "{s: >4}  {s}\n", .{ " ", normal_text });
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Compute longest common subsequence using dynamic programming
fn computeLcs(allocator: std.mem.Allocator, a: []const []const u8, b: []const []const u8) ![]const []const u8 {
    if (a.len == 0 or b.len == 0) return &[_][]const u8{};

    var dp = try allocator.alloc([]usize, a.len + 1);
    defer allocator.free(dp);
    for (dp) |*row| {
        row.* = try allocator.alloc(usize, b.len + 1);
        @memset(row.*, 0);
    }
    defer for (dp) |row| allocator.free(row);

    for (1..a.len + 1) |i| {
        for (1..b.len + 1) |j| {
            if (std.mem.eql(u8, a[i - 1], b[j - 1])) {
                dp[i][j] = dp[i - 1][j - 1] + 1;
            } else {
                dp[i][j] = @max(dp[i - 1][j], dp[i][j - 1]);
            }
        }
    }

    // Backtrack to find LCS
    var lcs = std.ArrayList([]const u8).empty;
    defer lcs.deinit(allocator);

    var i = a.len;
    var j = b.len;
    while (i > 0 and j > 0) {
        if (std.mem.eql(u8, a[i - 1], b[j - 1])) {
            try lcs.append(allocator, a[i - 1]);
            i -= 1;
            j -= 1;
        } else if (dp[i - 1][j] > dp[i][j - 1]) {
            i -= 1;
        } else {
            j -= 1;
        }
    }

    // Reverse LCS
    std.mem.reverse([]const u8, lcs.items);
    return lcs.toOwnedSlice(allocator);
}
