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

    // ANSI color codes
    const red_bg = "\x1b[48;2;69;40;48m"; // Dark red background (like in screenshot)
    const green_bg = "\x1b[48;2;40;69;48m"; // Dark green background (like in screenshot)
    const dim_text = "\x1b[38;5;245m"; // Dim gray for context lines
    const normal_text = "\x1b[0m"; // Reset

    // Calculate column width based on terminal size for centered split
    // Account for TUI margins: left_margin=2, right_margin=3, plus scrollbar=1
    const term_width: usize = blk: {
        var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const err = std.posix.system.ioctl(std.Io.File.stdout().handle, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        break :blk if (std.posix.errno(err) == .SUCCESS and ws.col > 20) ws.col else 80;
    };
    // TUI uses: inner_cols = cols - left_margin - right_margin = cols - 5
    // Plus we need to account for the box border (2 chars: "▌ ")
    const available_width = term_width - 5 - 2; // TUI margins minus box prefix
    // Total per side: line_num(4) + spaces(2) + content + gap(5)
    // Each side content width = (available_width - gap - line_num - spaces) / 2
    const left_content_width = (available_width - 11) / 2;

    // Render side-by-side diff with compact context hunks.
    var previous_rendered = false;
    for (diff_lines.items, 0..) |dl, index| {
        if (!render_lines[index]) {
            if (previous_rendered) {
                try result.appendSlice(allocator, "      ...                                           ...\n");
                previous_rendered = false;
            }
            continue;
        }
        previous_rendered = true;

        const is_change = dl.old_line == null or dl.new_line == null or
            (dl.old_idx != null and dl.new_idx != null and
                !std.mem.eql(u8, old_lines.items[dl.old_idx.?], new_lines.items[dl.new_idx.?]));

        // Old side (left) - line number (4) + 2 spaces = 6 chars, content truncated to left_content_width
        if (dl.old_line) |ln| {
            const color = if (is_change) red_bg else dim_text;
            const idx = dl.old_idx.?;
            
            // Use highlighted text if available and index is valid, otherwise plain text
            // Note: highlighted arrays may have different length due to trailing newline handling
            const display_text = if (highlighted_old) |hl| (if (idx < hl.len) hl[idx] else old_lines.items[idx]) else old_lines.items[idx];
            const text_len = stripAnsiLen(display_text);

            if (text_len > left_content_width) {
                const truncated = try truncateAnsiText(allocator, display_text, left_content_width);
                defer allocator.free(truncated);
                try result.print(allocator, "{s}{d: >4}  {s}…{s}{s}", .{ color, ln, truncated, color, normal_text });
            } else {
                try result.print(allocator, "{s}{d: >4}  {s}", .{ color, ln, display_text });
                try result.appendSlice(allocator, color); // Re-apply background color after potential resets in display_text
                const padding = left_content_width - text_len;
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
            const idx = dl.new_idx.?;
            
            // Use highlighted text if available and index is valid, otherwise plain text
            // Note: highlighted arrays may have different length due to trailing newline handling
            const display_text = if (highlighted_new) |hl| (if (idx < hl.len) hl[idx] else new_lines.items[idx]) else new_lines.items[idx];
            const text_len = stripAnsiLen(display_text);

            if (text_len > left_content_width) {
                const truncated = try truncateAnsiText(allocator, display_text, left_content_width);
                defer allocator.free(truncated);
                try result.print(allocator, "{s}{d: >4}  {s}…{s}\n", .{ color, ln, truncated, normal_text });
            } else {
                try result.print(allocator, "{s}{d: >4}  {s}{s}\n", .{ color, ln, display_text, normal_text });
            }
        } else {
            // Empty on new side
            try result.print(allocator, "{s: >4}  {s}\n", .{ " ", normal_text });
        }
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
