const std = @import("std");
const core = @import("core.zig");
const syntax_highlight = @import("../syntax_highlight.zig");

/// Compute a side-by-side diff between old and new content
pub fn diffAlloc(allocator: std.mem.Allocator, old_content: []const u8, new_content: []const u8, path: []const u8, highlighter: ?*syntax_highlight.SyntaxHighlighter) ![]u8 {
    var old_lines = std.ArrayList([]const u8).empty;
    defer old_lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, old_content, '\n');
    while (it.next()) |line| try old_lines.append(allocator, line);

    var new_lines = std.ArrayList([]const u8).empty;
    defer new_lines.deinit(allocator);
    it = std.mem.splitScalar(u8, new_content, '\n');
    while (it.next()) |line| try new_lines.append(allocator, line);

    // Detect language and highlight if possible
    const lang = if (highlighter) |_| syntax_highlight.SyntaxHighlighter.detectLanguage(path, new_content) else null;

    var highlighted_old: ?[]const []u8 = null;
    var highlighted_new: ?[]const []u8 = null;

    if (highlighter) |h| {
        if (lang) |language| {
            highlighted_old = h.highlightLines(language, old_content) catch null;
            highlighted_new = h.highlightLines(language, new_content) catch null;
        }
    }

    defer {
        if (highlighted_old) |lines| {
            for (lines) |line| allocator.free(line);
            allocator.free(lines);
        }
        if (highlighted_new) |lines| {
            for (lines) |line| allocator.free(line);
            allocator.free(lines);
        }
    }

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

    const diff_context_lines: usize = 3;

    var render_lines = try allocator.alloc(bool, diff_lines.items.len);
    defer allocator.free(render_lines);
    @memset(render_lines, false);

    for (diff_lines.items, 0..) |dl, index| {
        const is_change = dl.old_line == null or dl.new_line == null or
            (dl.old_idx != null and dl.new_idx != null and
                !std.mem.eql(u8, old_lines.items[dl.old_idx.?], new_lines.items[dl.new_idx.?]));
        if (!is_change) continue;

        const start = if (index > diff_context_lines) index - diff_context_lines else 0;
        const end = @min(diff_lines.items.len, index + diff_context_lines + 1);
        for (render_lines[start..end]) |*should_render| should_render.* = true;
    }

    const panel_bg = "\x1b[48;2;49;50;68m";
    const panel_alt_bg = "\x1b[48;2;69;71;90m";
    const line_number_bg = "\x1b[48;2;49;50;68m";
    const added_bg = "\x1b[48;2;40;69;48m";
    const removed_bg = "\x1b[48;2;69;40;48m";
    const text = "\x1b[38;2;205;214;244m";
    const muted = "\x1b[38;2;127;132;156m";
    const line_number = "\x1b[38;2;166;173;200m";
    const added = "\x1b[38;2;166;227;161m";
    const removed = "\x1b[38;2;243;139;168m";
    const badge = "\x1b[38;2;137;180;250m";
    const normal_text = "\x1b[0m";

    const term_width: usize = blk: {
        var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const err = std.posix.system.ioctl(std.Io.File.stdout().handle, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        break :blk if (std.posix.errno(err) == .SUCCESS and ws.col > 20) ws.col else 80;
    };
    const available_width = if (term_width > 7) term_width - 7 else 40;

    var additions: usize = 0;
    var deletions: usize = 0;
    var max_old_line: usize = 0;
    var max_new_line: usize = 0;
    for (diff_lines.items) |dl| {
        if (dl.old_line) |ln| max_old_line = @max(max_old_line, ln);
        if (dl.new_line) |ln| max_new_line = @max(max_new_line, ln);
        if (dl.old_line == null) additions += 1 else if (dl.new_line == null) deletions += 1 else if (dl.old_idx != null and dl.new_idx != null and !std.mem.eql(u8, old_lines.items[dl.old_idx.?], new_lines.items[dl.new_idx.?])) {
            additions += 1;
            deletions += 1;
        }
    }

    const line_digits = @max(@as(usize, 2), @max(decimalDigits(max_old_line), decimalDigits(max_new_line)));
    const gutter_width = line_digits * 2 + 4; // old, new, sign, and spacing.
    const content_width = if (available_width > gutter_width + 2) available_width - gutter_width - 2 else 20;

    try result.print(allocator, "{s} {s}{s}{s}", .{ panel_bg, text, path, normal_text });
    const path_len = stripAnsiLen(path);
    const stats = try std.fmt.allocPrint(allocator, "+{d} -{d}", .{ additions, deletions });
    defer allocator.free(stats);
    const stats_len = stats.len;
    if (available_width > path_len + stats_len + 3) {
        try result.appendSlice(allocator, panel_bg);
        try result.appendNTimes(allocator, ' ', available_width - path_len - stats_len - 3);
        try result.print(allocator, " {s}{s}{s}", .{ added, stats, normal_text });
    }
    try result.append(allocator, '\n');

    // Render a compact Hunk-style stack: rail, two line-number columns, sign, content.
    var previous_rendered = false;
    for (diff_lines.items, 0..) |dl, index| {
        if (!render_lines[index]) {
            if (previous_rendered) {
                try result.print(allocator, "{s}{s}▌{s}{s} ··· unchanged lines ···", .{ panel_alt_bg, muted, badge, panel_alt_bg });
                const collapsed_len = 25;
                if (available_width > collapsed_len) try result.appendNTimes(allocator, ' ', available_width - collapsed_len);
                try result.appendSlice(allocator, normal_text);
                try result.append(allocator, '\n');
                previous_rendered = false;
            }
            continue;
        }

        if (!previous_rendered) {
            var old_start: usize = 0;
            var new_start: usize = 0;
            var old_count: usize = 0;
            var new_count: usize = 0;
            var scan = index;
            while (scan < diff_lines.items.len and render_lines[scan]) : (scan += 1) {
                const scan_line = diff_lines.items[scan];
                if (scan_line.old_line) |ln| {
                    if (old_start == 0) old_start = ln;
                    old_count += 1;
                }
                if (scan_line.new_line) |ln| {
                    if (new_start == 0) new_start = ln;
                    new_count += 1;
                }
            }
            try result.print(allocator, "{s}{s}▌{s}{s} @@ -{d},{d} +{d},{d} @@", .{ panel_alt_bg, muted, badge, panel_alt_bg, old_start, old_count, new_start, new_count });
            const header_len = 7 + decimalDigits(old_start) + decimalDigits(old_count) + decimalDigits(new_start) + decimalDigits(new_count) + 7;
            if (available_width > header_len) try result.appendNTimes(allocator, ' ', available_width - header_len);
            try result.appendSlice(allocator, normal_text);
            try result.append(allocator, '\n');
        }
        previous_rendered = true;

        const is_change = dl.old_line == null or dl.new_line == null or
            (dl.old_idx != null and dl.new_idx != null and
                !std.mem.eql(u8, old_lines.items[dl.old_idx.?], new_lines.items[dl.new_idx.?]));

        if (is_change and dl.old_line != null and dl.new_line != null) {
            const old_idx_for_row = dl.old_idx.?;
            const new_idx_for_row = dl.new_idx.?;
            const old_text = old_lines.items[old_idx_for_row];
            const new_text = new_lines.items[new_idx_for_row];
            try appendStackDiffRow(allocator, &result, dl.old_line, null, '-', old_text, line_digits, content_width, removed_bg, removed, removed, removed, line_number_bg, text, normal_text);
            try appendStackDiffRow(allocator, &result, null, dl.new_line, '+', new_text, line_digits, content_width, added_bg, added, added, added, line_number_bg, text, normal_text);
            continue;
        }

        const kind_bg = if (!is_change) panel_bg else if (dl.old_line == null) added_bg else removed_bg;
        const rail_color = if (!is_change) muted else if (dl.old_line == null) added else removed;
        const number_color = if (!is_change) line_number else if (dl.old_line == null) added else removed;
        const sign_color = if (dl.old_line == null) added else if (dl.new_line == null) removed else muted;
        const sign: u8 = if (dl.old_line == null) '+' else if (dl.new_line == null) '-' else ' ';
        const source_idx = if (dl.new_idx) |idx| idx else dl.old_idx.?;
        const source_lines = if (dl.new_idx != null) new_lines.items else old_lines.items;
        const display_text = source_lines[source_idx];
        try appendStackDiffRow(allocator, &result, dl.old_line, dl.new_line, sign, display_text, line_digits, content_width, kind_bg, rail_color, number_color, sign_color, line_number_bg, text, normal_text);
    }

    return result.toOwnedSlice(allocator);
}

/// Calculate visible length of a string, excluding ANSI escape sequences
fn stripAnsiLen(text: []const u8) usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\x1b' and i + 1 < text.len and text[i + 1] == '[') {
            // Skip ANSI escape sequence
            i += 2;
            while (i < text.len and !std.ascii.isAlphabetic(text[i])) : (i += 1) {}
            if (i < text.len) i += 1; // Skip the final letter
        } else {
            len += 1;
            i += 1;
        }
    }
    return len;
}

/// Truncate text to a maximum visible length while preserving ANSI escape sequences
fn truncateAnsiText(allocator: std.mem.Allocator, text: []const u8, max_len: usize) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var visible_len: usize = 0;
    var i: usize = 0;
    while (i < text.len and visible_len < max_len) {
        if (text[i] == '\x1b' and i + 1 < text.len and text[i + 1] == '[') {
            // Copy ANSI escape sequence
            try result.append(allocator, text[i]);
            i += 1;
            try result.append(allocator, text[i]);
            i += 1;
            while (i < text.len and !std.ascii.isAlphabetic(text[i])) {
                try result.append(allocator, text[i]);
                i += 1;
            }
            if (i < text.len) {
                try result.append(allocator, text[i]);
                i += 1;
            }
        } else {
            try result.append(allocator, text[i]);
            visible_len += 1;
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

fn decimalDigits(value: usize) usize {
    var digits: usize = 1;
    var remaining = value;
    while (remaining >= 10) : (digits += 1) remaining /= 10;
    return digits;
}

fn appendLineNumber(allocator: std.mem.Allocator, result: *std.ArrayList(u8), line: ?usize, width: usize) !void {
    if (line) |ln| {
        try result.print(allocator, "{d: >[1]}", .{ ln, width });
    } else {
        try result.appendNTimes(allocator, ' ', width);
    }
}

fn appendStackDiffRow(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    old_line: ?usize,
    new_line: ?usize,
    sign: u8,
    display_text: []const u8,
    line_digits: usize,
    content_width: usize,
    row_bg: []const u8,
    rail_color: []const u8,
    number_color: []const u8,
    sign_color: []const u8,
    line_number_bg: []const u8,
    text_color: []const u8,
    reset: []const u8,
) !void {
    const was_truncated = stripAnsiLen(display_text) > content_width;
    const row_text = if (was_truncated) blk: {
        const truncated = try truncateAnsiText(allocator, display_text, content_width - 1);
        break :blk truncated;
    } else display_text;
    defer if (was_truncated) allocator.free(row_text);

    try result.print(allocator, "{s}{s}▌{s}{s}", .{ row_bg, rail_color, number_color, line_number_bg });
    try appendLineNumber(allocator, result, old_line, line_digits);
    try result.append(allocator, ' ');
    try appendLineNumber(allocator, result, new_line, line_digits);
    try result.print(allocator, " {s}{c} {s}{s}", .{ sign_color, sign, row_bg, text_color });
    try result.appendSlice(allocator, row_text);
    if (stripAnsiLen(row_text) < content_width) {
        try result.appendSlice(allocator, row_bg);
        try result.appendNTimes(allocator, ' ', content_width - stripAnsiLen(row_text));
    }
    try result.appendSlice(allocator, reset);
    try result.append(allocator, '\n');
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
