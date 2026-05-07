const std = @import("std");
const theme = @import("../theme.zig");

pub const thinking_marker = "\x1fT";
pub const user_marker = "\x1fU";
pub const diff_box_marker = "\x1fD";
pub const shell_output_marker = "\x1fS";
pub const max_input = 16 * 1024;
pub const welcome_input_width: usize = 70;
pub const welcome_max_input_rows: usize = 5;
pub const prompt_max_input_rows: usize = 5;
pub const model_modal_padding: usize = 2;
pub const model_modal_vertical_padding: usize = 1;

/// Maximum number of full conversation turns to keep in context
pub const max_full_turns = 4;

/// Data structures for tracking read operations
pub const GrepMatch = struct {
    path: []u8,
    line: usize,
};

pub const ReadContinuation = struct {
    path: []u8,
    offset: usize,
};

pub const ConfirmDialog = struct {
    prompt: []u8,
    selected: usize, // 0 = No, 1 = Yes
    result: ?bool,
};

pub fn sanitizeAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (text) |byte| {
        switch (byte) {
            // C0 control characters (0-31) except tab which we convert to space
            0...8, 11...31 => try out.append(allocator, '?'),
            // DEL character
            127 => try out.append(allocator, '?'),
            // Tab to space
            9 => try out.append(allocator, ' '),
            // Everything else including UTF-8 continuation bytes (128-255)
            else => try out.append(allocator, byte),
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Sanitize text while preserving ANSI escape sequences (for diff output)
pub fn sanitizeAnsiAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        // Check for ANSI escape sequence: ESC [ ... m
        if (byte == '\x1b' and i + 1 < text.len and text[i + 1] == '[') {
            // Find the end of the ANSI sequence (ends with a letter)
            var j = i + 2;
            while (j < text.len and !std.ascii.isAlphabetic(text[j])) : (j += 1) {}
            if (j < text.len) {
                // Include the complete ANSI sequence
                try out.appendSlice(allocator, text[i .. j + 1]);
                i = j + 1;
                continue;
            }
        }
        switch (byte) {
            // C0 control characters (0-31) except tab which we convert to space
            0...8, 11...31 => try out.append(allocator, '?'),
            // DEL character
            127 => try out.append(allocator, '?'),
            // Tab to space
            9 => try out.append(allocator, ' '),
            // Everything else including UTF-8 continuation bytes (128-255)
            else => try out.append(allocator, byte),
        }
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

pub fn styleMarkdownLine(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    // Heading markers at start: color '#', '##', '###' in orange.
    var i: usize = 0;
    var hashes: usize = 0;
    while (i < line.len and line[i] == '#') : (i += 1) hashes += 1;
    if (hashes > 0 and hashes <= 3 and i < line.len and line[i] == ' ') {
        try out.appendSlice(allocator, theme.mocha.peach);
        try out.appendSlice(allocator, line[0..hashes]);
        try out.appendSlice(allocator, theme.reset);
        try out.appendSlice(allocator, theme.mocha.text);
        try out.append(allocator, ' ');
        i += 1; // consume the required space after heading marker
    } else {
        i = 0;
    }

    while (i < line.len) {
        // Inline code: `...` => green
        if (line[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, line, i + 1, '`')) |end| {
                try out.appendSlice(allocator, theme.mocha.green);
                try out.appendSlice(allocator, line[i .. end + 1]);
                try out.appendSlice(allocator, theme.reset);
                try out.appendSlice(allocator, theme.mocha.text);
                i = end + 1;
                continue;
            }
        }

        // Bold: **...** => bold + purple
        if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, line, i + 2, "**")) |end| {
                if (end > i + 2) {
                    try out.appendSlice(allocator, theme.bold);
                    try out.appendSlice(allocator, theme.mocha.mauve);
                    try out.appendSlice(allocator, line[i + 2 .. end]);
                    try out.appendSlice(allocator, theme.reset);
                    try out.appendSlice(allocator, theme.mocha.text);
                    i = end + 2;
                    continue;
                }
            }
        }

        try out.append(allocator, line[i]);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

pub fn sleepAfterInputError() void {
    std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
}

pub fn wrappedRows(line_len: usize, width: usize) usize {
    if (width == 0) return 1;
    if (line_len == 0) return 1;
    return (line_len + width - 1) / width;
}

pub fn promptRoomForInput(inner_cols: usize) usize {
    const border_cols: usize = 1;
    const input_left_padding: usize = 1;
    const input_right_padding: usize = 1;
    const input_prefix_cols = border_cols + input_left_padding;
    return if (inner_cols > input_prefix_cols + input_right_padding)
        inner_cols - input_prefix_cols - input_right_padding
    else
        0;
}

pub fn isWordSeparator(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\r', '\n', '.', ',', ';', ':', '/', '\\', '|', '-', '_', '+', '=', '(', ')', '[', ']', '{', '}', '<', '>', '"', '\'', '`' => true,
        else => false,
    };
}

pub fn rowContentCols(inner_cols: usize, is_user: bool, is_thinking: bool, is_diff: bool, is_shell: bool) usize {
    // User messages match input box width: border(1) + left padding(1) + right padding(1) = 3
    const reserved: usize = if (is_user) 3 else if (is_thinking or is_diff or is_shell) 2 else 2;
    return if (inner_cols > reserved) inner_cols - reserved else 1;
}

pub fn readUsizeArg(args: std.json.Value, name: []const u8) ?usize {
    if (args != .object) return null;
    const value = args.object.get(name) orelse return null;
    return switch (value) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .string => |s| std.fmt.parseUnsigned(usize, s, 10) catch null,
        else => null,
    };
}

pub fn trimCurrentDirPrefix(path: []const u8) []const u8 {
    var trimmed = path;
    while (std.mem.startsWith(u8, trimmed, "./")) trimmed = trimmed[2..];
    return trimmed;
}

pub fn sameToolPath(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, trimCurrentDirPrefix(a), trimCurrentDirPrefix(b));
}

pub fn isShortenedOffset(offset: usize, full_offset: usize) bool {
    var divisor: usize = 10;
    var tmp = offset;
    while (tmp >= 10) : (tmp /= 10) divisor *= 10;
    if (full_offset % divisor == offset) return true;
    return offset >= 100 and full_offset % 100 == offset % 100;
}

pub fn containsToolJson(text: []const u8) bool {
    // Check if text contains a tool JSON anywhere (even with text before it)
    if (std.mem.indexOf(u8, text, "\"tool\"") != null and
        std.mem.indexOf(u8, text, "\"") != null)
    {
        // Look for {"tool" pattern
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '{') {
                // Check if this looks like a tool object
                const remaining = text[i..];
                if (remaining.len > 8 and
                    std.mem.startsWith(u8, remaining, "{\"tool\"") or
                    std.mem.startsWith(u8, remaining, "{\n\"tool\"") or
                    std.mem.startsWith(u8, remaining, "{ \"tool\""))
                {
                    return true;
                }
            }
        }
    }
    return false;
}

pub fn toolJsonStart(text: []const u8) ?usize {
    if (std.mem.indexOf(u8, text, "\"tool\"") == null) return null;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] != '{') continue;
        const remaining = text[index..];
        if (remaining.len > 8 and
            (std.mem.startsWith(u8, remaining, "{\"tool\"") or
                std.mem.startsWith(u8, remaining, "{\n\"tool\"") or
                std.mem.startsWith(u8, remaining, "{ \"tool\"")))
        {
            return index;
        }
    }
    return null;
}

pub fn textBeforeToolJson(text: []const u8) ?[]const u8 {
    const json_start = toolJsonStart(text) orelse return null;
    return text[0..json_start];
}

pub fn containsToolAttempt(text: []const u8) bool {
    if (containsToolJson(text)) return true;
    if (std.mem.indexOfScalar(u8, text, '{') == null) return false;
    return containsQuotedKnownTool(text);
}

pub fn containsQuotedKnownTool(text: []const u8) bool {
    const known = [_][]const u8{
        "read_file",
        "write_file",
        "list_files",
        "run_shell",
        "glob",
        "grep",
        "edit",
    };
    for (known) |tool_name| {
        if (std.mem.indexOf(u8, text, tool_name)) |_| return true;
    }
    return false;
}

pub fn extractToolJson(allocator: std.mem.Allocator, text: []const u8) ?[]u8 {
    // Find and extract the JSON object containing "tool"
    if (std.mem.indexOf(u8, text, "\"tool\"") == null) return null;

    const json_start = toolJsonStart(text) orelse return null;

    // Find the matching closing brace
    var brace_depth: usize = 0;
    var in_string = false;
    var json_end: usize = json_start;

    while (json_end < text.len) : (json_end += 1) {
        const c = text[json_end];
        if (c == '"' and (json_end == 0 or text[json_end - 1] != '\\')) {
            in_string = !in_string;
        } else if (!in_string) {
            if (c == '{') {
                brace_depth += 1;
            } else if (c == '}') {
                brace_depth -= 1;
                if (brace_depth == 0) {
                    json_end += 1;
                    break;
                }
            }
        }
    }

    if (brace_depth != 0) return null;

    return allocator.dupe(u8, text[json_start..json_end]) catch null;
}

pub fn toolVerb(tool_name: []const u8) []const u8 {
    if (std.mem.eql(u8, tool_name, "read_file")) return "Read";
    if (std.mem.eql(u8, tool_name, "write_file")) return "Write";
    if (std.mem.eql(u8, tool_name, "list_files")) return "List";
    if (std.mem.eql(u8, tool_name, "run_shell")) return "Run";
    if (std.mem.eql(u8, tool_name, "glob")) return "Glob";
    if (std.mem.eql(u8, tool_name, "grep")) return "Grep";
    if (std.mem.eql(u8, tool_name, "edit")) return "Edit";
    return tool_name;
}

pub fn toolMarker(tool_name: []const u8) []const u8 {
    if (std.mem.eql(u8, tool_name, "grep")) return "*";
    return "→";
}

/// Calculate visible length of a string, excluding ANSI escape sequences
pub fn stripAnsiLen(text: []const u8) usize {
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
pub fn truncateAnsiText(allocator: std.mem.Allocator, text: []const u8, max_len: usize) ![]u8 {
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
