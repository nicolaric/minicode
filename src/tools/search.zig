const std = @import("std");
const core = @import("core.zig");

const max_grep_matches = core.max_grep_matches;

// Regex types and errors

pub const RegexError = error{
    EmptyPattern,
    PatternTooLong,
    UnclosedClass,
    BadEscape,
    InvalidQuantifierPlacement,
};

pub fn regexErrorName(err: RegexError) []const u8 {
    return switch (err) {
        error.EmptyPattern => "empty pattern",
        error.PatternTooLong => "pattern too long (max 100 chars)",
        error.UnclosedClass => "unclosed character class",
        error.BadEscape => "bad escape sequence",
        error.InvalidQuantifierPlacement => "invalid quantifier placement",
    };
}

pub fn regexErrorAnsi(allocator: std.mem.Allocator, err: RegexError) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[31mError: invalid regex pattern ({s})\x1b[0m", .{regexErrorName(err)});
}

fn isRegexMeta(ch: u8) bool {
    return ch == '.' or ch == '*' or ch == '+' or ch == '?' or ch == '[' or ch == ']' or ch == '^' or ch == '$' or ch == '\\' or ch == '|';
}

fn hasRegexMetacharacters(pattern: []const u8) bool {
    for (pattern) |ch| {
        if (isRegexMeta(ch)) return true;
    }
    return false;
}

// Glob functionality

/// Find files matching a glob pattern (e.g., "**/*.zig" or "src/**/*.zig")
pub fn globFiles(allocator: std.mem.Allocator, pattern: []const u8, search_path: ?[]const u8) ![]u8 {
    // Validate pattern doesn't escape cwd
    if (core.hasParentTraversal(pattern)) return std.fmt.allocPrint(allocator, "Error: Pattern cannot contain ..", .{});

    // If pattern starts with **, search from cwd; otherwise search from search_path or cwd
    const base_path = search_path orelse ".";
    if (core.hasParentTraversal(base_path)) return std.fmt.allocPrint(allocator, "Error: Search path cannot contain ..", .{});
    if (pathContainsExcludedGlobDir(base_path)) return allocator.dupe(u8, "");

    const full_base = core.resolveInsideCwd(allocator, base_path) catch |err| {
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
        if (core.hasParentTraversal(recursive_base)) return std.fmt.allocPrint(allocator, "Error: Pattern cannot contain ..", .{});
        const full_recursive_base = core.resolveInsideCwd(allocator, recursive_base) catch |err| {
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
            const rel_path = try core.relativeDisplayPath(allocator, dir_path);
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

// Grep functionality

/// Search file contents for a substring pattern
pub fn grepFiles(allocator: std.mem.Allocator, pattern: []const u8, search_path: ?[]const u8, include_pattern: ?[]const u8, case_sensitive: bool, context: ?usize) ![]u8 {
    if (pattern.len == 0) return regexErrorAnsi(allocator, error.EmptyPattern);
    if (pattern.len > 100) return regexErrorAnsi(allocator, error.PatternTooLong);

    _ = validateRegexPattern(pattern) catch |err| {
        if (@TypeOf(err) == RegexError) {
            return regexErrorAnsi(allocator, err);
        }
        return err;
    };

    const search_dir = if (search_path) |p| p else ".";
    if (core.hasParentTraversal(search_dir)) return std.fmt.allocPrint(allocator, "Error: Search path cannot contain ..", .{});

    const full_path = core.resolveInsideCwd(allocator, search_dir) catch |err| {
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
            const rel_path = try core.relativeDisplayPath(allocator, full_path);
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
                const rel_path = try core.relativeDisplayPath(allocator, entry_path);
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

    const content = core.readFileAbsolute(allocator, file_path) catch return;
    defer allocator.free(content);

    const display_path = try core.relativeDisplayPath(allocator, file_path);
    defer allocator.free(display_path);
    const display_path_json = try core.stringifyJsonString(allocator, display_path);
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

    // Handle unescaped alternation (|) by trying each alternative.
    var alt_start: usize = 0;
    var pos: usize = 0;
    var in_class = false;
    while (true) {
        const at_alt_end = pos >= pat.len or (pat[pos] == '|' and !in_class);
        if (!at_alt_end) {
            if (pat[pos] == '\\') {
                pos += if (pos + 1 < pat.len) 2 else 1;
                continue;
            }
            if (pat[pos] == '[') in_class = true;
            if (pat[pos] == ']') in_class = false;
            pos += 1;
            continue;
        }

        const alt = pat[alt_start..pos];
        if (anchored_start) {
            if (regexMatchFrom(line, 0, alt, 0, case_sensitive)) return true;
        } else {
            var start: usize = 0;
            while (start <= line.len) : (start += 1) {
                if (regexMatchFrom(line, start, alt, 0, case_sensitive)) return true;
            }
        }

        if (pos >= pat.len) break;
        pos += 1;
        alt_start = pos;
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
        if (p + 1 >= pattern.len) return false;
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

// Search tests

test "grep searches a single file path" {
    var arena = std.heap.ArenaAllocator.init(core.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try grepFiles(allocator, "renderPrompt", "src/tui.zig", null, true, null);
    try core.testing.expect(std.mem.indexOf(u8, result, "renderPrompt") != null);
    try core.testing.expect(std.mem.indexOf(u8, result, "Found") != null);
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

    var arena = std.heap.ArenaAllocator.init(core.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try grepFiles(allocator, "^a.+c$", path, null, true, null);
    try core.testing.expect(std.mem.indexOf(u8, result, "Line: 1") != null);
    try core.testing.expect(std.mem.indexOf(u8, result, "Line: 2") != null);
    try core.testing.expect(std.mem.indexOf(u8, result, "Line: 3") != null);
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

    var arena = std.heap.ArenaAllocator.init(core.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try grepFiles(allocator, "renderprompt", path, null, false, null);
    try core.testing.expect(std.mem.indexOf(u8, result, "Found 1 matches") != null);
}

test "grep returns ansi error for malformed regex" {
    var arena = std.heap.ArenaAllocator.init(core.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try grepFiles(allocator, "[abc", null, null, true, null);
    try core.testing.expect(std.mem.indexOf(u8, result, "\x1b[31mError: invalid regex pattern (unclosed character class)\x1b[0m") != null);
}

test "grep treats escaped pipe as literal" {
    const path = ".tmp-grep-escaped-pipe-test.txt";
    std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch {};

    {
        var file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, path, .{});
        defer file.close(std.Options.debug_io);
        try std.Io.File.writeStreamingAll(file, std.Options.debug_io, "a|b\naxb\n");
    }

    var arena = std.heap.ArenaAllocator.init(core.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try grepFiles(allocator, "a\\|b", path, null, true, null);
    try core.testing.expect(std.mem.indexOf(u8, result, "Found 1 matches") != null);
    try core.testing.expect(std.mem.indexOf(u8, result, "Line: 1") != null);
    try core.testing.expect(std.mem.indexOf(u8, result, "Line: 2") == null);
}

test "grep searches current directory by default" {
    var arena = std.heap.ArenaAllocator.init(core.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try grepFiles(allocator, "renderPrompt", null, null, true, null);
    try core.testing.expect(std.mem.indexOf(u8, result, "renderPrompt") != null);
}

test "grep finds thinking title in tui by default" {
    var arena = std.heap.ArenaAllocator.init(core.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try grepFiles(allocator, "Thinking", null, null, true, null);
    try core.testing.expect(std.mem.indexOf(u8, result, "src/tui.zig") != null);
    try core.testing.expect(std.mem.indexOf(u8, result, "Thinking") != null);
}

test "grep include matches relative paths" {
    var arena = std.heap.ArenaAllocator.init(core.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try grepFiles(allocator, "thinking_marker", null, "src/*.zig", true, null);
    try core.testing.expect(std.mem.indexOf(u8, result, "src/tui.zig") != null);
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

    var arena = std.heap.ArenaAllocator.init(core.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try grepFiles(allocator, "needle", path, null, true, 1);
    try core.testing.expect(std.mem.indexOf(u8, result, "Context lines 1-3:") != null);

    const marker = "Next tool call:\n";
    const json_start = (std.mem.indexOf(u8, result, marker) orelse return error.TestUnexpectedResult) + marker.len;
    const json_end = json_start + (std.mem.indexOfScalar(u8, result[json_start..], '\n') orelse return error.TestUnexpectedResult);
    var parsed = (try core.parseToolRequest(allocator, result[json_start..json_end])) orelse return error.TestUnexpectedResult;
    defer parsed.deinit();

    try core.testing.expectEqualStrings("read_file", parsed.value.tool);
    try core.testing.expectEqualStrings(path, core.getStringArg(parsed.value.args, "path") orelse return error.TestUnexpectedResult);
}

test "grep supports alternation with pipe operator" {
    var arena = std.heap.ArenaAllocator.init(core.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try grepFiles(allocator, "input|Input", "src/tui.zig", null, true, null);
    // Should find matches for either "input" or "Input"
    try core.testing.expect(std.mem.indexOf(u8, result, "Found") != null);
    try core.testing.expect(std.mem.indexOf(u8, result, "matches") != null);
}

test "glob supports recursive directory pattern" {
    var arena = std.heap.ArenaAllocator.init(core.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try globFiles(allocator, "src/**/*", null);
    try core.testing.expect(std.mem.indexOf(u8, result, "src/tui.zig") != null);
}

test "glob excludes .gitignore matches" {
    var arena = std.heap.ArenaAllocator.init(core.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try globFiles(allocator, ".gitignore", null);
    try core.testing.expect(std.mem.indexOf(u8, result, ".gitignore") == null);
}

test "glob recursive excludes ignored directories" {
    const base_dir = ".tmp-glob-excluded-dirs";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, base_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, base_dir) catch {};

    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, base_dir ++ std.fs.path.sep_str ++ "ok");
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, base_dir ++ std.fs.path.sep_str ++ ".git");
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, base_dir ++ std.fs.path.sep_str ++ ".zig-cache");
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, base_dir ++ std.fs.path.sep_str ++ "zig-pkg");
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, base_dir ++ std.fs.path.sep_str ++ "zig-out");

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

    var arena = std.heap.ArenaAllocator.init(core.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try globFiles(allocator, "**/*.zig", base_dir);
    try core.testing.expect(std.mem.indexOf(u8, result, "keep.zig") != null);
    try core.testing.expect(std.mem.indexOf(u8, result, ".git") == null);
    try core.testing.expect(std.mem.indexOf(u8, result, ".zig-cache") == null);
    try core.testing.expect(std.mem.indexOf(u8, result, "zig-pkg") == null);
    try core.testing.expect(std.mem.indexOf(u8, result, "zig-out") == null);
}
