const std = @import("std");
const core = @import("core.zig");
const syntax_highlight = @import("../syntax_highlight.zig");
const diff = @import("diff.zig");

const Confirm = core.Confirm;
const max_read_lines = core.max_read_lines;

/// Read file contents with optional offset and limit
pub fn readFile(allocator: std.mem.Allocator, path: []const u8, offset: ?usize, limit: ?usize) ![]u8 {
    const full_path = core.resolveInsideCwd(allocator, path) catch |err| {
        return switch (err) {
            error.PathOutsideCwd => std.fmt.allocPrint(allocator, "Error: Path must be relative and within current directory", .{}),
            else => std.fmt.allocPrint(allocator, "Error resolving path: {s}", .{@errorName(err)}),
        };
    };
    defer allocator.free(full_path);

    const content = core.readFileAbsolute(allocator, full_path) catch |err| {
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
pub fn writeFile(allocator: std.mem.Allocator, path: []const u8, content: []const u8, confirmer: ?Confirm, highlighter: ?*syntax_highlight.SyntaxHighlighter) ![]u8 {
    const full_path = core.resolveInsideCwd(allocator, path) catch |err| {
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
            if (!(try core.confirm(std.fmt.allocPrint(allocator, "Overwrite {s}?", .{path}) catch return error.OutOfMemory, c))) {
                return std.fmt.allocPrint(allocator, "Write cancelled", .{});
            }
        }
        // Read old content for diff
        old_content = core.readFileAbsolute(allocator, full_path) catch null;
    }

    var file = std.Io.Dir.createFileAbsolute(std.Options.debug_io, full_path, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "Error creating file: {s}", .{@errorName(err)});
    };
    defer file.close(std.Options.debug_io);

    std.Io.File.writeStreamingAll(file, std.Options.debug_io, content) catch |err| {
        return std.fmt.allocPrint(allocator, "Error writing file: {s}", .{@errorName(err)});
    };

    if (old_content) |old| {
        const diff_text = try diff.diffAlloc(allocator, old, content, path, highlighter);
        defer allocator.free(diff_text);
        return std.fmt.allocPrint(allocator, "Updated {s}\n{s}", .{ path, diff_text });
    } else {
        return std.fmt.allocPrint(allocator, "Created {s} [new file]", .{path});
    }
}

/// List directory contents
pub fn listFiles(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const full_path = core.resolveInsideCwd(allocator, path) catch |err| {
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

/// Edit a file by replacing oldString with newString
pub fn editFile(allocator: std.mem.Allocator, path: []const u8, old_string: []const u8, new_string: []const u8, highlighter: ?*syntax_highlight.SyntaxHighlighter) ![]u8 {
    const full_path = core.resolveInsideCwd(allocator, path) catch |err| {
        return switch (err) {
            error.PathOutsideCwd => std.fmt.allocPrint(allocator, "Error: Path must be relative and within current directory", .{}),
            else => std.fmt.allocPrint(allocator, "Error resolving path: {s}", .{@errorName(err)}),
        };
    };
    defer allocator.free(full_path);

    const content = core.readFileAbsolute(allocator, full_path) catch |err| {
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

    const diff_text = try diff.diffAlloc(allocator, content, new_content, path, highlighter);
    defer allocator.free(diff_text);
    return std.fmt.allocPrint(allocator, "Edited {s}\n{s}", .{ path, diff_text });
}

// Edit helper functions

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

// File operations tests

test "write_file creates a file" {
    const path = ".tmp-write-tool-test.txt";
    std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch {};

    var arena = std.heap.ArenaAllocator.init(core.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try args.put(allocator, "path", .{ .string = path });
    try args.put(allocator, "content", .{ .string = "hello\n" });

    const result = try writeFile(allocator, path, "hello\n", null, null);
    try core.testing.expect(std.mem.indexOf(u8, result, "Created") != null);

    const content = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(1024));
    try core.testing.expectEqualStrings("hello\n", content);
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

    var arena = std.heap.ArenaAllocator.init(core.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try editFile(allocator, path, "beta", "gamma", null);
    try core.testing.expect(std.mem.indexOf(u8, result, "Edited") != null);

    const content = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(1024));
    try core.testing.expectEqualStrings("alpha\ngamma\n", content);
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

    var arena = std.heap.ArenaAllocator.init(core.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try editFile(allocator, path, "\t<title>Old</title>", "  <title>New</title>", null);
    try core.testing.expect(std.mem.indexOf(u8, result, "Edited") != null);

    const content = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(1024));
    try core.testing.expectEqualStrings("<html>\n    <title>New</title>\n</html>\n", content);
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

    var arena = std.heap.ArenaAllocator.init(core.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try editFile(allocator, path, "\t<title>Same</title>", "<title>New</title>", null);
    try core.testing.expect(std.mem.indexOf(u8, result, "ambiguous") != null);
}
