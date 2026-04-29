const std = @import("std");

const testing = std.testing;

pub const ToolRequest = struct {
    tool: []const u8,
    args: std.json.Value,
};

pub const ConfirmFn = *const fn (ctx: *anyopaque, prompt: []const u8) anyerror!bool;

pub const Confirm = struct {
    ctx: *anyopaque,
    callback: ConfirmFn,
};

pub fn parseToolRequest(allocator: std.mem.Allocator, text: []const u8) !?std.json.Parsed(ToolRequest) {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return null;

    const parsed = std.json.parseFromSlice(ToolRequest, allocator, trimmed, .{ .ignore_unknown_fields = true }) catch return null;
    if (parsed.value.tool.len == 0) {
        parsed.deinit();
        return null;
    }
    return parsed;
}

pub fn execute(allocator: std.mem.Allocator, req: ToolRequest) ![]u8 {
    return executeWithConfirm(allocator, req, null);
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

    const result = try execute(allocator, .{ .tool = "write_file", .args = .{ .object = args } });
    try testing.expect(std.mem.indexOf(u8, result, "Created") != null);

    const content = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(1024));
    try testing.expectEqualStrings("hello\n", content);
}

pub fn executeWithConfirm(allocator: std.mem.Allocator, req: ToolRequest, confirmer: ?Confirm) ![]u8 {
    if (std.mem.eql(u8, req.tool, "read_file")) return readFile(allocator, getStringArg(req.args, "path") orelse return error.InvalidToolArgs, getUsizeArg(req.args, "offset"), getUsizeArg(req.args, "limit"));
    if (std.mem.eql(u8, req.tool, "write_file")) return writeFile(
        allocator,
        getStringArg(req.args, "path") orelse return error.InvalidToolArgs,
        getStringArg(req.args, "content") orelse return error.InvalidToolArgs,
        confirmer,
    );
    if (std.mem.eql(u8, req.tool, "list_files")) return listFiles(allocator, getStringArg(req.args, "path") orelse ".");
    if (std.mem.eql(u8, req.tool, "run_shell")) return runShell(allocator, getStringArg(req.args, "command") orelse return error.InvalidToolArgs, confirmer);
    if (std.mem.eql(u8, req.tool, "glob")) return globFiles(allocator, getStringArg(req.args, "pattern") orelse return error.InvalidToolArgs, getStringArg(req.args, "path"));
    if (std.mem.eql(u8, req.tool, "grep")) return grepFiles(allocator, getStringArg(req.args, "pattern") orelse return error.InvalidToolArgs, getStringArg(req.args, "path"), getStringArg(req.args, "include"));
    if (std.mem.eql(u8, req.tool, "edit")) return editFile(allocator, getStringArg(req.args, "path") orelse return error.InvalidToolArgs, getStringArg(req.args, "oldString") orelse return error.InvalidToolArgs, getStringArg(req.args, "newString") orelse return error.InvalidToolArgs);
    return std.fmt.allocPrint(allocator, "Unknown tool: {s}", .{req.tool});
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

const max_read_lines: usize = 100;
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
    _ = limit;
    const line_limit = max_read_lines;

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

    return std.fmt.allocPrint(allocator, "File: {s}\nRead line range: {d}-{d}\nTo continue after this range, call read_file with offset={d}.\nTo inspect a grep match at line N, call read_file with offset=N or offset=max(1, N-20). Do not drop digits from line numbers.\n{s}", .{ path, offset orelse 1, end_line, end_line + 1, body });
}

/// Write file with confirmation for existing files
fn writeFile(allocator: std.mem.Allocator, path: []const u8, content: []const u8, confirmer: ?Confirm) ![]u8 {
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
        const diff_text = try diffAlloc(allocator, old, content);
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

    const full_base = resolveInsideCwd(allocator, base_path) catch |err| {
        return switch (err) {
            error.PathOutsideCwd => std.fmt.allocPrint(allocator, "Error: Path must be relative and within current directory", .{}),
            else => std.fmt.allocPrint(allocator, "Error resolving path: {s}", .{@errorName(err)}),
        };
    };
    defer allocator.free(full_base);

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

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
                std.mem.eql(u8, entry.name, ".git")) continue;

            const sub_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            defer allocator.free(sub_path);
            try globRecursive(allocator, sub_path, pattern, results);
        } else if (entry.kind == .file) {
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

/// Search file contents for a substring pattern
fn grepFiles(allocator: std.mem.Allocator, pattern: []const u8, search_path: ?[]const u8, include_pattern: ?[]const u8) ![]u8 {
    if (pattern.len == 0) return std.fmt.allocPrint(allocator, "Error: empty pattern", .{});

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

    if (std.Io.Dir.openFileAbsolute(std.Options.debug_io, full_path, .{})) |file| {
        file.close(std.Options.debug_io);
        const filename = std.fs.path.basename(full_path);
        if (!isBinaryFile(filename) and if (include_pattern) |inc| globMatch(filename, inc) else true) {
            files_searched += 1;
            try searchInFile(allocator, full_path, pattern, &results, &match_count);
        }
    } else |err| switch (err) {
        error.IsDir => try grepRecursive(allocator, full_path, pattern, include_pattern, &results, &match_count, &files_searched),
        else => return std.fmt.allocPrint(allocator, "Error opening path: {s}", .{@errorName(err)}),
    }

    if (match_count == 0) {
        return std.fmt.allocPrint(allocator, "No matches for '{s}' in {d} files searched", .{ pattern, files_searched });
    }
    const capped = if (match_count >= max_grep_matches) " (showing first 20)" else "";
    return std.fmt.allocPrint(allocator, "Found {d} matches in {d} files{s}:\n{s}", .{ match_count, files_searched, capped, results.items });
}

fn grepRecursive(allocator: std.mem.Allocator, dir_path: []const u8, pattern: []const u8, include_pattern: ?[]const u8, results: *std.ArrayList(u8), match_count: *usize, files_searched: *usize) !void {
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
            try grepRecursive(allocator, entry_path, pattern, include_pattern, results, match_count, files_searched);
        } else if (entry.kind == .file) {
            if (!isBinaryFile(entry.name) and if (include_pattern) |inc| globMatch(entry.name, inc) else true) {
                files_searched.* += 1;
                try searchInFile(allocator, entry_path, pattern, results, match_count);
            }
        }
    }
}

fn isBinaryFile(filename: []const u8) bool {
    const binary_exts = [_][]const u8{
        ".exe", ".dll", ".so", ".dylib", ".bin",
        ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".ico",
        ".mp3", ".mp4", ".avi", ".mov", ".wav",
        ".zip", ".tar", ".gz", ".bz2", ".7z", ".rar",
        ".o", ".obj", ".a", ".lib", ".pdb",
    };
    const lower = std.fs.path.extension(filename);
    for (binary_exts) |ext| {
        if (std.mem.eql(u8, lower, ext)) return true;
    }
    return false;
}

fn searchInFile(allocator: std.mem.Allocator, file_path: []const u8, pattern: []const u8, results: *std.ArrayList(u8), match_count: *usize) !void {
    if (match_count.* >= max_grep_matches) return;

    const content = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, file_path, allocator, .limited(1024 * 1024)) catch return;
    defer allocator.free(content);

    const display_path = try relativeDisplayPath(allocator, file_path);
    defer allocator.free(display_path);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var line_num: usize = 1;
    while (line_iter.next()) |line| : (line_num += 1) {
        if (match_count.* >= max_grep_matches) return;

        // Simple substring search with alternation support (a|b|c)
        if (lineMatchesPattern(line, pattern)) {
            const read_offset = if (line_num > 20) line_num - 20 else 1;
            const display_line = if (line.len > 200) line[0..200] else line;
            try results.print(allocator, "{s}:{d}: {s}\n  read around: read_file path={s} offset={d} limit=100\n", .{ display_path, line_num, display_line, display_path, read_offset });
            match_count.* += 1;
        }
    }
}

fn lineMatchesPattern(line: []const u8, pattern: []const u8) bool {
    // Check for alternation pattern (a|b|c)
    if (std.mem.indexOfScalar(u8, pattern, '|')) |_| {
        var alternatives = std.mem.splitScalar(u8, pattern, '|');
        while (alternatives.next()) |raw_alt| {
            const alt = std.mem.trim(u8, raw_alt, " \t");
            if (alt.len == 0) continue;
            if (std.mem.indexOf(u8, line, alt)) |_| return true;
        }
        return false;
    }
    // Simple substring search
    return std.mem.indexOf(u8, line, pattern) != null;
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
fn editFile(allocator: std.mem.Allocator, path: []const u8, old_string: []const u8, new_string: []const u8) ![]u8 {
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
    if (match_count == 0) return std.fmt.allocPrint(allocator, "Error: oldString not found in {s}", .{path});
    if (match_count > 1) return std.fmt.allocPrint(allocator, "Error: oldString matches {d} locations, must be unique", .{match_count});

    const new_content = try std.mem.replaceOwned(u8, allocator, content, old_string, new_string);
    defer allocator.free(new_content);

    var file = std.Io.Dir.createFileAbsolute(std.Options.debug_io, full_path, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "Error creating file: {s}", .{@errorName(err)});
    };
    defer file.close(std.Options.debug_io);

    std.Io.File.writeStreamingAll(file, std.Options.debug_io, new_content) catch |err| {
        return std.fmt.allocPrint(allocator, "Error writing file: {s}", .{@errorName(err)});
    };

    const diff_text = try diffAlloc(allocator, content, new_content);
    defer allocator.free(diff_text);
    return std.fmt.allocPrint(allocator, "Edited {s}\n{s}", .{ path, diff_text });
}

/// Compute a simple line-based diff between old and new content
fn diffAlloc(allocator: std.mem.Allocator, old_content: []const u8, new_content: []const u8) ![]u8 {
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

    try result.appendSlice(allocator, "--- old\n+++ new\n");

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
            try result.print(allocator, "  {d}|{d}: {s}\n", .{ old_idx + 1, new_idx + 1, old_lines.items[old_idx] });
            old_idx += 1;
            new_idx += 1;
            lcs_idx += 1;
        } else if (lcs_idx < lcs.len and old_idx < old_lines.items.len and std.mem.eql(u8, old_lines.items[old_idx], lcs[lcs_idx])) {
            // Line added
            try result.print(allocator, "+ {d}: {s}\n", .{ new_idx + 1, new_lines.items[new_idx] });
            new_idx += 1;
        } else if (lcs_idx < lcs.len and new_idx < new_lines.items.len and std.mem.eql(u8, new_lines.items[new_idx], lcs[lcs_idx])) {
            // Line removed
            try result.print(allocator, "- {d}: {s}\n", .{ old_idx + 1, old_lines.items[old_idx] });
            old_idx += 1;
        } else if (old_idx < old_lines.items.len and new_idx < new_lines.items.len) {
            // Changed line (replace)
            try result.print(allocator, "- {d}: {s}\n", .{ old_idx + 1, old_lines.items[old_idx] });
            try result.print(allocator, "+ {d}: {s}\n", .{ new_idx + 1, new_lines.items[new_idx] });
            old_idx += 1;
            new_idx += 1;
        } else if (old_idx < old_lines.items.len) {
            try result.print(allocator, "- {d}: {s}\n", .{ old_idx + 1, old_lines.items[old_idx] });
            old_idx += 1;
        } else if (new_idx < new_lines.items.len) {
            try result.print(allocator, "+ {d}: {s}\n", .{ new_idx + 1, new_lines.items[new_idx] });
            new_idx += 1;
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
