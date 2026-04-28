const std = @import("std");
const ollama = @import("ollama.zig");
const theme = @import("theme.zig");
const terminal = @import("terminal.zig");
const tools = @import("tools.zig");
const agent = @import("agent.zig");
const config = @import("config.zig");
const syntax_highlight = @import("syntax_highlight.zig");

const thinking_marker = "\x1fT";
const user_marker = "\x1fU";
const max_input = 16 * 1024;

const App = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    messages: std.ArrayList(ollama.Message),
    lines: std.ArrayList([]u8),
    input: std.ArrayList(u8),
    cursor_pos: usize,
    scroll_offset: usize,
    inner_cols: usize,
    input_cleared: bool,
    is_busy: bool,
    loader_frame: usize,
    cancel_requested: bool,
    // Streaming accumulation
    stream_content: std.ArrayList(u8),
    stream_thinking: std.ArrayList(u8),
    stream_lines_start: usize,
    thinking_started: bool,
    // Syntax highlighter
    highlighter: ?*syntax_highlight.SyntaxHighlighter,

    fn init(allocator: std.mem.Allocator, cfg: config.Config) !App {
        const highlighter = try syntax_highlight.SyntaxHighlighter.create(allocator);
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .messages = .empty,
            .lines = .empty,
            .input = .empty,
            .cursor_pos = 0,
            .scroll_offset = 0,
            .inner_cols = 80,
            .input_cleared = false,
            .is_busy = false,
            .loader_frame = 0,
            .cancel_requested = false,
            .stream_content = .empty,
            .stream_thinking = .empty,
            .stream_lines_start = 0,
            .thinking_started = false,
            .highlighter = highlighter,
        };
    }

    fn deinit(self: *App) void {
        for (self.messages.items) |message| self.allocator.free(message.content);
        self.messages.deinit(self.allocator);
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
        self.input.deinit(self.allocator);
        self.stream_content.deinit(self.allocator);
        self.stream_thinking.deinit(self.allocator);
        if (self.highlighter) |h| h.destroy();
    }

    fn start(self: *App) !void {
        try self.messages.append(self.allocator, .{ .role = .system, .content = try self.allocator.dupe(u8, agent.system_prompt) });
        try self.render();
    }

    fn loop(self: *App) !void {
        var stdin_buf: [256]u8 = undefined;
        var stdin_file = std.Io.File.stdin().readerStreaming(std.Options.debug_io, &stdin_buf);
        const stdin = &stdin_file.interface;
        while (true) {
            var byte: [1]u8 = undefined;
            if (try stdin.readSliceShort(&byte) == 0) break;
            switch (byte[0]) {
                3 => { // Ctrl+C
                    if (self.input.items.len > 0 and !self.input_cleared) {
                        self.input.clearRetainingCapacity();
                        self.cursor_pos = 0;
                        self.input_cleared = true;
                        try self.render();
                    } else {
                        break;
                    }
                },
                23 => { // Ctrl+W - scroll up
                    self.scrollUp(self.getContentRows());
                    try self.render();
                },
                19 => { // Ctrl+S - scroll down
                    self.scrollDown(self.getContentRows());
                    try self.render();
                },
                '\r', '\n' => {
                    const trimmed = std.mem.trim(u8, self.input.items, " \t\r\n");
                    if (trimmed.len == 0) {
                        self.input.clearRetainingCapacity();
                        self.cursor_pos = 0;
                        self.input_cleared = false;
                        try self.render();
                        continue;
                    }
                    if (std.mem.eql(u8, trimmed, "/exit") or std.mem.eql(u8, trimmed, "/quit")) break;
                    const user_text = try self.allocator.dupe(u8, trimmed);
                    const safe_user_text = try sanitizeAlloc(self.allocator, user_text);
                    defer self.allocator.free(safe_user_text);
                    self.input.clearRetainingCapacity();
                    self.cursor_pos = 0;
                    self.scroll_offset = 0;
                    self.input_cleared = false;
                    self.is_busy = true;
                    try self.addUserBlock(safe_user_text);
                    try self.messages.append(self.allocator, .{ .role = .user, .content = user_text });
                    const stream_start = self.lines.items.len;
                    try self.render();
                    try self.completeTurn(stream_start);
                    self.is_busy = false;
                    try self.render();
                },
                127, 8 => {
                    if (self.cursor_pos > 0 and self.input.items.len > 0) {
                        _ = self.input.orderedRemove(self.cursor_pos - 1);
                        self.cursor_pos -= 1;
                    }
                    try self.render();
                },
                27 => {
                    // Check if we're streaming - if so, request cancellation
                    if (self.is_busy) {
                        self.cancel_requested = true;
                        try self.render();
                        continue;
                    }
                    // Escape sequence - read next byte with short timeout
                    var seq: [1]u8 = undefined;
                    const n = stdin.readSliceShort(&seq) catch 0;
                    if (n == 0) {
                        // Standalone Escape key - could clear input or do nothing
                        continue;
                    }
                    if (seq[0] == '[') {
                        var seq2: [1]u8 = undefined;
                        const n2 = stdin.readSliceShort(&seq2) catch 0;
                        if (n2 == 0) continue;
                        switch (seq2[0]) {
                            'A' => { // Up arrow / alternate-scroll wheel up
                                self.scrollUp(3);
                                try self.render();
                            },
                            'B' => { // Down arrow / alternate-scroll wheel down
                                self.scrollDown(3);
                                try self.render();
                            },
                            'D' => { // Left arrow
                                if (self.cursor_pos > 0) self.cursor_pos -= 1;
                                try self.render();
                            },
                            'C' => { // Right arrow
                                if (self.cursor_pos < self.input.items.len) self.cursor_pos += 1;
                                try self.render();
                            },
                            '<' => {
                                if (try self.handleSgrMouse(stdin)) try self.render();
                            },
                            '1' => {
                                if (try self.handleModifiedArrow(stdin)) try self.render();
                            },
                            '5' => {
                                // Page Up
                                var tilde: [1]u8 = undefined;
                                const nt = stdin.readSliceShort(&tilde) catch 0;
                                if (nt > 0 and tilde[0] == '~') {
                                    self.scrollUp(self.getContentRows());
                                    try self.render();
                                }
                            },
                            '6' => {
                                // Page Down
                                var tilde: [1]u8 = undefined;
                                const nt = stdin.readSliceShort(&tilde) catch 0;
                                if (nt > 0 and tilde[0] == '~') {
                                    self.scrollDown(self.getContentRows());
                                    try self.render();
                                }
                            },
                            '3' => {
                                // Delete key (ESC[3~)
                                var tilde: [1]u8 = undefined;
                                const nt = stdin.readSliceShort(&tilde) catch 0;
                                if (nt > 0 and tilde[0] == '~') {
                                    if (self.cursor_pos < self.input.items.len) {
                                        _ = self.input.orderedRemove(self.cursor_pos);
                                    }
                                    try self.render();
                                }
                            },
                            else => {},
                        }
                    } else switch (seq[0]) {
                        'b' => { // Option+Left in many terminals
                            self.moveCursorWordLeft();
                            try self.render();
                        },
                        'f' => { // Option+Right in many terminals
                            self.moveCursorWordRight();
                            try self.render();
                        },
                        127, 8 => { // Option+Delete / Option+Backspace
                            self.deleteWordLeft();
                            try self.render();
                        },
                        else => {},
                    }
                },
                else => |ch| {
                    if (ch >= 32 and ch != 127 and self.input.items.len < max_input) {
                        try self.input.insert(self.allocator, self.cursor_pos, ch);
                        self.cursor_pos += 1;
                        try self.render();
                    }
                },
            }
        }
    }

    fn moveCursorWordLeft(self: *App) void {
        while (self.cursor_pos > 0 and isWordSeparator(self.input.items[self.cursor_pos - 1])) {
            self.cursor_pos -= 1;
        }
        while (self.cursor_pos > 0 and !isWordSeparator(self.input.items[self.cursor_pos - 1])) {
            self.cursor_pos -= 1;
        }
    }

    fn moveCursorWordRight(self: *App) void {
        while (self.cursor_pos < self.input.items.len and isWordSeparator(self.input.items[self.cursor_pos])) {
            self.cursor_pos += 1;
        }
        while (self.cursor_pos < self.input.items.len and !isWordSeparator(self.input.items[self.cursor_pos])) {
            self.cursor_pos += 1;
        }
    }

    fn deleteWordLeft(self: *App) void {
        const end = self.cursor_pos;
        self.moveCursorWordLeft();
        const delete_start = self.cursor_pos;
        if (delete_start == end) return;
        self.input.replaceRange(self.allocator, delete_start, end - delete_start, "") catch return;
    }

    fn isWordSeparator(byte: u8) bool {
        return switch (byte) {
            ' ', '\t', '\r', '\n', '.', ',', ';', ':', '/', '\\', '|', '-', '_', '+', '=', '(', ')', '[', ']', '{', '}', '<', '>', '"', '\'', '`' => true,
            else => false,
        };
    }

    fn handleModifiedArrow(self: *App, stdin: anytype) !bool {
        var seq: [4]u8 = undefined;
        var len: usize = 0;
        while (len < seq.len) : (len += 1) {
            var byte: [1]u8 = undefined;
            const n = stdin.readSliceShort(&byte) catch 0;
            if (n == 0) return false;
            seq[len] = byte[0];
            if (byte[0] == 'D' or byte[0] == 'C') break;
        }
        if (len != 2 or seq[0] != ';' or seq[1] != '3') return false;
        if (seq[2] == 'D') {
            self.moveCursorWordLeft();
            return true;
        }
        if (seq[2] == 'C') {
            self.moveCursorWordRight();
            return true;
        }
        return false;
    }

    fn scrollUp(self: *App, lines: usize) void {
        if (self.scroll_offset > lines) {
            self.scroll_offset -= lines;
        } else {
            self.scroll_offset = 0;
        }
    }

    fn scrollDown(self: *App, lines: usize) void {
        const max_scroll = self.getMaxScroll();
        if (self.scroll_offset < max_scroll) {
            self.scroll_offset += lines;
            if (self.scroll_offset > max_scroll) self.scroll_offset = max_scroll;
        }
    }

    fn handleSgrMouse(self: *App, stdin: anytype) !bool {
        var buf: [32]u8 = undefined;
        var len: usize = 0;
        while (len < buf.len) : (len += 1) {
            var byte: [1]u8 = undefined;
            const n = stdin.readSliceShort(&byte) catch 0;
            if (n == 0) return false;
            buf[len] = byte[0];
            if (byte[0] == 'M' or byte[0] == 'm') break;
        }
        if (len == buf.len) return false;

        const final = buf[len];
        if (final != 'M') return false;

        var parts = std.mem.splitScalar(u8, buf[0..len], ';');
        const button_text = parts.next() orelse return false;
        const button = std.fmt.parseUnsigned(usize, button_text, 10) catch return false;
        const wheel = button & 0b11;
        const scroll_lines: usize = 3;

        if ((button & 64) == 0) return false;
        if (wheel == 0) {
            self.scrollUp(scroll_lines);
            return true;
        }
        if (wheel == 1) {
            self.scrollDown(scroll_lines);
            return true;
        }
        return false;
    }

    fn completeTurn(self: *App, initial_stream_start: usize) !void {
        var stream_start = initial_stream_start;

        // Add spacing between user message and response
        try self.addLine("", .{});
        stream_start = self.lines.items.len;

        while (true) {
            self.stream_content.clearRetainingCapacity();
            self.stream_thinking.clearRetainingCapacity();
            self.thinking_started = false;
            self.cancel_requested = false;
            self.stream_lines_start = stream_start;

            ollama.chatStream(self.allocator, self.cfg, self.messages.items, self, streamingCallback, shouldCancelCallback) catch |err| {
                if (err == error.Cancelled) {
                    // Add partial response if any content was received
                    if (self.stream_content.items.len > 0) {
                        const partial_content = try self.allocator.dupe(u8, self.stream_content.items);
                        try self.messages.append(self.allocator, .{ .role = .assistant, .content = partial_content });
                        try self.addAssistantBlock(partial_content);
                        try self.addLine("", .{});
                        try self.addLine("(response cancelled)", .{});
                    } else {
                        try self.addLine("(cancelled)", .{});
                    }
                    return;
                }
                return err;
            };

            self.cancel_requested = false;

            if (self.stream_content.items.len == 0 and self.stream_thinking.items.len == 0) {
                try self.addLine("(no response)", .{});
                return;
            }
            
            // If only thinking was received, use thinking as content
            if (self.stream_content.items.len == 0 and self.stream_thinking.items.len > 0) {
                try self.stream_content.appendSlice(self.allocator, self.stream_thinking.items);
            }

            const final_content = try self.allocator.dupe(u8, self.stream_content.items);

            try self.messages.append(self.allocator, .{ .role = .assistant, .content = final_content });

            // Check for tool request - handle case where there's text before the JSON
            var maybe_tool: ?std.json.Parsed(tools.ToolRequest) = null;

            // Try to parse as-is first
            if (try tools.parseToolRequest(self.allocator, final_content)) |parsed| {
                maybe_tool = parsed;
            } else if (containsToolJson(final_content)) {
                // Extract just the JSON part
                if (extractToolJson(self.allocator, final_content)) |json_part| {
                    defer self.allocator.free(json_part);
                    if (try tools.parseToolRequest(self.allocator, json_part)) |parsed| {
                        maybe_tool = parsed;
                    }
                }
            }

            if (maybe_tool) |*parsed| {
                defer parsed.deinit();
                const safe_tool = try sanitizeAlloc(self.allocator, parsed.value.tool);
                defer self.allocator.free(safe_tool);

                const pending_summary = try self.formatToolDisplay(safe_tool, parsed.value.args);
                defer self.allocator.free(pending_summary);
                try self.addLine("{s}", .{pending_summary});
                try self.render();

                const result = tools.executeWithConfirm(self.allocator, parsed.value, .{
                    .ctx = self,
                    .callback = confirmCallback,
                }) catch |err| try std.fmt.allocPrint(self.allocator, "Tool error: {s}", .{@errorName(err)});
                defer self.allocator.free(result);

                // Show concise summary in UI
                const summary = try self.formatToolResultSummary(safe_tool, parsed.value.args, result);
                defer self.allocator.free(summary);
                self.removeLineAt(self.lines.items.len - 1);
                try self.addLine("{s}", .{summary});

                // Send full result to agent
                const tool_message = try std.fmt.allocPrint(self.allocator, "Result from tool `{s}`. Use this result to continue; do not repeat the same tool call unless you need a different offset, limit, path, or pattern.\n{s}", .{ parsed.value.tool, result });
                try self.messages.append(self.allocator, .{ .role = .user, .content = tool_message });
                try self.render();
                // Update stream_start so next iteration doesn't clear previous content
                stream_start = self.lines.items.len;
                continue;
            }

            return;
        }

    }

    fn shouldCancelCallback(self: *App) bool {
        return self.cancel_requested;
    }

    fn streamingCallback(self: *App, chunk: ollama.StreamChunk) !void {
        // Check if cancel was requested
        if (self.cancel_requested) {
            return error.Cancelled;
        }

        if (chunk.content_delta.len > 0) {
            // Deduplication: check if this is truly new content
            // Some models send full content instead of deltas
            const existing = self.stream_content.items;
            const new_content = chunk.content_delta;
            if (existing.len == 0) {
                // First chunk - append all
                try self.stream_content.appendSlice(self.allocator, new_content);
            } else if (new_content.len > existing.len and std.mem.startsWith(u8, new_content, existing)) {
                // New content is existing + suffix - only append the suffix
                const suffix = new_content[existing.len..];
                try self.stream_content.appendSlice(self.allocator, suffix);
            } else if (!std.mem.eql(u8, existing[existing.len - @min(existing.len, new_content.len)..], new_content)) {
                // Truly new content that doesn't overlap with existing - append it
                try self.stream_content.appendSlice(self.allocator, new_content);
            }
            // If content matches end of existing, it's a duplicate - skip it
        }

        if (chunk.thinking_delta) |td| {
            self.thinking_started = true;
            try self.stream_thinking.appendSlice(self.allocator, td);
        }

        if (chunk.content_delta.len > 0 or (chunk.thinking_delta != null and chunk.thinking_delta.?.len > 0)) {
            try self.refreshStreamingLines();
            // Auto-scroll to bottom during streaming to show latest content
            self.scroll_offset = self.getMaxScroll();
            try self.render();
        }
    }

    fn refreshStreamingLines(self: *App) !void {
        // Clear previous streaming lines
        while (self.lines.items.len > self.stream_lines_start) {
            const removed = self.lines.pop().?;
            self.allocator.free(removed);
        }

        if (self.stream_thinking.items.len > 0) {
            try self.addThinkingBlock(self.stream_thinking.items);
        }

        if (self.stream_content.items.len > 0) {
            if (try tools.parseToolRequest(self.allocator, self.stream_content.items)) |*parsed| {
                // Valid tool JSON - hide it (will be processed at end of turn)
                parsed.deinit();
            } else if (containsToolJson(self.stream_content.items)) {
                // Content contains tool JSON somewhere (possibly with text before it)
                // Hide everything - the tool will be extracted and executed at end of turn
            } else {
                // No tool JSON in content - display as normal text
                if (self.stream_thinking.items.len > 0) {
                    try self.addLine("", .{});
                }
                try self.addAssistantBlock(self.stream_content.items);
            }
        }
    }

    fn confirmCallback(ctx: *anyopaque, _: []const u8) anyerror!bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.input.clearRetainingCapacity();
        try self.renderPrompt("confirm y/N");

        var stdin_buf: [256]u8 = undefined;
        var stdin_file = std.Io.File.stdin().readerStreaming(std.Options.debug_io, &stdin_buf);
        const stdin = &stdin_file.interface;
        while (true) {
            var byte: [1]u8 = undefined;
            if (try stdin.readSliceShort(&byte) == 0) return false;
            switch (byte[0]) {
                'y', 'Y' => return true,
                'n', 'N', '\r', '\n', 27, 3 => return false,
                else => {},
            }
        }
    }

    fn formatToolDisplay(self: *App, tool_name: []const u8, args: std.json.Value) ![]u8 {
        // Extract the main argument based on tool type
        var arg: ?[]const u8 = null;
        if (args == .object) {
            if (std.mem.eql(u8, tool_name, "read_file") or
                std.mem.eql(u8, tool_name, "write_file") or
                std.mem.eql(u8, tool_name, "list_files") or
                std.mem.eql(u8, tool_name, "edit")) {
                if (args.object.get("path")) |p| {
                    if (p == .string) arg = p.string;
                }
            } else if (std.mem.eql(u8, tool_name, "glob")) {
                if (args.object.get("pattern")) |p| {
                    if (p == .string) arg = p.string;
                }
            } else if (std.mem.eql(u8, tool_name, "grep")) {
                if (args.object.get("pattern")) |p| {
                    if (p == .string) arg = p.string;
                }
            } else if (std.mem.eql(u8, tool_name, "run_shell")) {
                if (args.object.get("command")) |c| {
                    if (c == .string) arg = c.string;
                }
            }
        }
        
        if (arg) |a| {
            const safe_arg = try sanitizeAlloc(self.allocator, a);
            defer self.allocator.free(safe_arg);
            // Truncate long arguments
            const display_arg = if (safe_arg.len > 50) safe_arg[0..50] else safe_arg;
            if (std.mem.eql(u8, tool_name, "run_shell")) {
                return std.fmt.allocPrint(self.allocator, "{s} {s} {s} ... [confirm y/N]", .{ toolMarker(tool_name), toolVerb(tool_name), display_arg });
            }
            return std.fmt.allocPrint(self.allocator, "{s} {s} {s} ...", .{ toolMarker(tool_name), toolVerb(tool_name), display_arg });
        } else {
            return std.fmt.allocPrint(self.allocator, "{s} {s} ...", .{ toolMarker(tool_name), toolVerb(tool_name) });
        }
    }

    fn formatToolResultSummary(self: *App, tool_name: []const u8, args: std.json.Value, result: []const u8) ![]u8 {
        // Extract main argument
        var main_arg: ?[]const u8 = null;
        var offset_arg: ?usize = null;
        var limit_arg: ?usize = null;
        if (args == .object) {
            if (args.object.get("path")) |p| {
                if (p == .string) main_arg = p.string;
            }
            if (args.object.get("pattern")) |p| {
                if (p == .string) main_arg = p.string;
            }
            if (args.object.get("command")) |c| {
                if (c == .string) main_arg = c.string;
            }
            if (args.object.get("offset")) |o| {
                if (o == .integer) offset_arg = @intCast(o.integer);
            }
            if (args.object.get("limit")) |l| {
                if (l == .integer) limit_arg = @intCast(l.integer);
            }
        }

        // Build summary based on tool type
        if (std.mem.eql(u8, tool_name, "read_file")) {
            const path = main_arg orelse "unknown";
            const off = offset_arg orelse 1;
            const lim = @min(limit_arg orelse 100, 100);
            return std.fmt.allocPrint(self.allocator, "→ Read {s} [offset={d}, limit={d}]", .{ path, off, lim });
        } else if (std.mem.eql(u8, tool_name, "write_file")) {
            const path = main_arg orelse "unknown";
            const is_new = std.mem.indexOf(u8, result, "new file") != null;
            if (is_new) {
                return std.fmt.allocPrint(self.allocator, "→ Write {s} [new]", .{path});
            } else {
                return std.fmt.allocPrint(self.allocator, "→ Write {s}", .{path});
            }
        } else if (std.mem.eql(u8, tool_name, "list_files")) {
            const path = main_arg orelse ".";
            // Count lines in result
            var line_count: usize = 0;
            for (result) |c| {
                if (c == '\n') line_count += 1;
            }
            return std.fmt.allocPrint(self.allocator, "→ List {s}/ [{d} files]", .{ path, line_count });
        } else if (std.mem.eql(u8, tool_name, "run_shell")) {
            const cmd = main_arg orelse "unknown";
            const display_cmd = if (cmd.len > 30) cmd[0..30] else cmd;
            return std.fmt.allocPrint(self.allocator, "→ Run \"{s}\"", .{display_cmd});
        } else if (std.mem.eql(u8, tool_name, "glob")) {
            const pattern = main_arg orelse "unknown";
            const display_pattern = if (pattern.len > 25) pattern[0..25] else pattern;
            // Count lines
            var line_count: usize = 0;
            for (result) |c| {
                if (c == '\n') line_count += 1;
            }
            return std.fmt.allocPrint(self.allocator, "→ Glob \"{s}\" [{d} matches]", .{ display_pattern, line_count });
        } else if (std.mem.eql(u8, tool_name, "grep")) {
            const pattern = main_arg orelse "unknown";
            const display_pattern = if (pattern.len > 20) pattern[0..20] else pattern;
            // Count matches from "Found X matches" in result
            var match_count: usize = 0;
            if (std.mem.startsWith(u8, result, "Found ")) {
                var i: usize = 6;
                while (i < result.len and result[i] >= '0' and result[i] <= '9') : (i += 1) {
                    match_count = match_count * 10 + (result[i] - '0');
                }
            }
            if (match_count == 0) {
                return std.fmt.allocPrint(self.allocator, "* Grep \"{s}\" [no matches]", .{display_pattern});
            } else {
                return std.fmt.allocPrint(self.allocator, "* Grep \"{s}\" [{d} matches]", .{ display_pattern, match_count });
            }
        } else if (std.mem.eql(u8, tool_name, "edit")) {
            const path = main_arg orelse "unknown";
            return std.fmt.allocPrint(self.allocator, "→ Edit {s}", .{path});
        } else {
            return std.fmt.allocPrint(self.allocator, "→ {s} [done]", .{tool_name});
        }
    }

    fn toolVerb(tool_name: []const u8) []const u8 {
        if (std.mem.eql(u8, tool_name, "read_file")) return "Read";
        if (std.mem.eql(u8, tool_name, "write_file")) return "Write";
        if (std.mem.eql(u8, tool_name, "list_files")) return "List";
        if (std.mem.eql(u8, tool_name, "run_shell")) return "Run";
        if (std.mem.eql(u8, tool_name, "glob")) return "Glob";
        if (std.mem.eql(u8, tool_name, "grep")) return "Grep";
        if (std.mem.eql(u8, tool_name, "edit")) return "Edit";
        return tool_name;
    }

    fn toolMarker(tool_name: []const u8) []const u8 {
        if (std.mem.eql(u8, tool_name, "grep")) return "*";
        return "→";
    }

    fn containsToolJson(text: []const u8) bool {
        // Check if text contains a tool JSON anywhere (even with text before it)
        if (std.mem.indexOf(u8, text, "\"tool\"") != null and
            std.mem.indexOf(u8, text, "\"") != null) {
            // Look for {"tool" pattern
            var i: usize = 0;
            while (i < text.len) : (i += 1) {
                if (text[i] == '{') {
                    // Check if this looks like a tool object
                    const remaining = text[i..];
                    if (remaining.len > 8 and
                        std.mem.startsWith(u8, remaining, "{\"tool\"") or
                        std.mem.startsWith(u8, remaining, "{\n\"tool\"") or
                        std.mem.startsWith(u8, remaining, "{ \"tool\"")) {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    fn extractToolJson(allocator: std.mem.Allocator, text: []const u8) ?[]u8 {
        // Find and extract the JSON object containing "tool"
        if (std.mem.indexOf(u8, text, "\"tool\"") == null) return null;

        // Find the start of the JSON object
        var json_start: usize = 0;
        while (json_start < text.len) : (json_start += 1) {
            if (text[json_start] == '{') {
                const remaining = text[json_start..];
                // Check if this looks like a tool object
                if (remaining.len > 8) {
                    if (std.mem.startsWith(u8, remaining, "{\"tool\"") or
                        std.mem.startsWith(u8, remaining, "{\n\"tool\"") or
                        std.mem.startsWith(u8, remaining, "{ \"tool\"")) {
                        break;
                    }
                }
            }
        }

        if (json_start >= text.len) return null;

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

    fn detectCodeLanguage(_: *App, label: []const u8, content: []const u8) ?[]const u8 {
        // Check if label suggests code (e.g., file paths)
        if (std.mem.indexOf(u8, label, ".")) |_| {
            // Label contains a dot, likely a file path
            const ext = std.fs.path.extension(label);
            if (ext.len > 1) {
                const lang = ext[1..]; // Remove leading dot
                // Normalize common extensions
                if (std.ascii.eqlIgnoreCase(lang, "zig")) return "zig";
                if (std.ascii.eqlIgnoreCase(lang, "rs")) return "rust";
                if (std.ascii.eqlIgnoreCase(lang, "py")) return "python";
                if (std.ascii.eqlIgnoreCase(lang, "js")) return "javascript";
                if (std.ascii.eqlIgnoreCase(lang, "ts")) return "typescript";
                if (std.ascii.eqlIgnoreCase(lang, "go")) return "go";
                if (std.ascii.eqlIgnoreCase(lang, "c")) return "c";
                if (std.ascii.eqlIgnoreCase(lang, "cpp") or std.ascii.eqlIgnoreCase(lang, "cc") or std.ascii.eqlIgnoreCase(lang, "cxx")) return "cpp";
                if (std.ascii.eqlIgnoreCase(lang, "h") or std.ascii.eqlIgnoreCase(lang, "hpp")) return "c";
                if (std.ascii.eqlIgnoreCase(lang, "rb")) return "ruby";
                if (std.ascii.eqlIgnoreCase(lang, "sh") or std.ascii.eqlIgnoreCase(lang, "bash")) return "bash";
                if (std.ascii.eqlIgnoreCase(lang, "md")) return "markdown";
                if (std.ascii.eqlIgnoreCase(lang, "json")) return "json";
                if (std.ascii.eqlIgnoreCase(lang, "yaml") or std.ascii.eqlIgnoreCase(lang, "yml")) return "yaml";
                if (std.ascii.eqlIgnoreCase(lang, "toml")) return "toml";
                if (std.ascii.eqlIgnoreCase(lang, "xml")) return "xml";
                if (std.ascii.eqlIgnoreCase(lang, "html")) return "html";
                if (std.ascii.eqlIgnoreCase(lang, "css")) return "css";
                if (std.ascii.eqlIgnoreCase(lang, "sql")) return "sql";
                if (std.ascii.eqlIgnoreCase(lang, "lua")) return "lua";
                if (std.ascii.eqlIgnoreCase(lang, "nim")) return "nim";
                if (std.ascii.eqlIgnoreCase(lang, "java")) return "java";
                if (std.ascii.eqlIgnoreCase(lang, "kt") or std.ascii.eqlIgnoreCase(lang, "kts")) return "kotlin";
                if (std.ascii.eqlIgnoreCase(lang, "swift")) return "swift";
                if (std.ascii.eqlIgnoreCase(lang, "scala")) return "scala";
                if (std.ascii.eqlIgnoreCase(lang, "hs")) return "haskell";
                if (std.ascii.eqlIgnoreCase(lang, "ex") or std.ascii.eqlIgnoreCase(lang, "exs")) return "elixir";
                if (std.ascii.eqlIgnoreCase(lang, "erl")) return "erlang";
                if (std.ascii.eqlIgnoreCase(lang, "ml") or std.ascii.eqlIgnoreCase(lang, "mli")) return "ocaml";
            }
        }

        // Check if content looks like code (has code-like patterns)
        if (content.len > 0 and content.len < 50 * 1024) {
            // Check for common code patterns
            const code_indicators = .{
                "fn ", "func ", "def ", "class ", "struct ", "enum ",
                "const ", "let ", "var ", "pub ", "import ",
                "return ", "if ", "else ", "for ", "while ",
                "->", "=>", "::", "++", "--", "==", "!=",
                "/*", "*/", "//", "///",
            };
            inline for (code_indicators) |indicator| {
                if (std.mem.indexOf(u8, content, indicator)) |_| {
                    // Try to detect specific language from shebang
                    if (content.len > 2 and content[0] == '#' and content[1] == '!') {
                        if (std.mem.indexOf(u8, content, "python")) return "python";
                        if (std.mem.indexOf(u8, content, "bash") or std.mem.indexOf(u8, content, "/sh")) return "bash";
                        if (std.mem.indexOf(u8, content, "ruby")) return "ruby";
                        if (std.mem.indexOf(u8, content, "node")) return "javascript";
                        if (std.mem.indexOf(u8, content, "perl")) return "perl";
                    }
                    // Could not detect specific language, but looks like code
                    return "plaintext";
                }
            }
        }

        return null;
    }

    fn addBlock(self: *App, label: []const u8, text: []const u8) !void {
        // Detect language from label (filename or explicit language)
        const lang = if (self.highlighter != null)
            syntax_highlight.SyntaxHighlighter.detectLanguage(label, text)
        else
            null;

        if (lang) |language| {
            // Use syntax highlighting
            const highlighted = self.highlighter.?.highlightLines(language, text) catch |err| blk: {
                // Fall back to plain text on error
                var lines = std.ArrayList([]u8).empty;
                var it = std.mem.splitScalar(u8, text, '\n');
                while (it.next()) |line| {
                    try lines.append(try self.allocator.dupe(u8, line));
                }
                break :blk lines.toOwnedSlice(self.allocator) catch return err;
            };
            defer {
                for (highlighted) |line| self.allocator.free(line);
                self.allocator.free(highlighted);
            }

            // Add label line
            try self.addLine("{s}:", .{label});

            // Add highlighted lines
            for (highlighted) |line| {
                // Don't sanitize highlighted content - it already contains ANSI codes
                try self.addLine("  {s}", .{line});
            }
        } else {
            // Plain text without highlighting
            var it = std.mem.splitScalar(u8, text, '\n');
            var first = true;
            while (it.next()) |line| {
                const safe_line = try sanitizeAlloc(self.allocator, line);
                defer self.allocator.free(safe_line);
                if (first) {
                    try self.addLine("{s}: {s}", .{ label, safe_line });
                    first = false;
                } else {
                    try self.addLine("  {s}", .{safe_line});
                }
            }
        }
    }

    fn addThinkingBlock(self: *App, text: []const u8) !void {
        var it = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        var in_code_block = false;
        var code_lang: ?[]const u8 = null;
        var code_buffer: std.ArrayList(u8) = .empty;
        defer code_buffer.deinit(self.allocator);

        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "```")) {
                if (!in_code_block) {
                    in_code_block = true;
                    const lang = std.mem.trim(u8, line[3..], " \t");
                    if (lang.len > 0) code_lang = lang;
                } else {
                    in_code_block = false;
                    try self.addThinkingCodeBlock(code_lang orelse "text", code_buffer.items, &first);
                    code_buffer.clearRetainingCapacity();
                    code_lang = null;
                }
                continue;
            }

            if (in_code_block) {
                if (code_buffer.items.len > 0) try code_buffer.append(self.allocator, '\n');
                try code_buffer.appendSlice(self.allocator, line);
                continue;
            }

            const safe_line = try sanitizeAlloc(self.allocator, line);
            defer self.allocator.free(safe_line);
            if (first) {
                try self.addLine(thinking_marker ++ "Thinking: {s}", .{safe_line});
                first = false;
            } else {
                try self.addLine(thinking_marker ++ "{s}", .{safe_line});
            }
        }

        if (in_code_block and code_buffer.items.len > 0) {
            try self.addThinkingCodeBlock(code_lang orelse "text", code_buffer.items, &first);
        }
    }

    fn addThinkingCodeBlock(self: *App, lang: []const u8, code: []const u8, first: *bool) !void {
        _ = lang;

        if (first.*) {
            try self.addLine(thinking_marker ++ "Thinking:", .{});
            first.* = false;
        }

        var it = std.mem.splitScalar(u8, code, '\n');
        while (it.next()) |line| {
            const safe_line = try sanitizeAlloc(self.allocator, line);
            defer self.allocator.free(safe_line);
            try self.addLine(thinking_marker ++ "{s}", .{safe_line});
        }
    }

    fn addUserBlock(self: *App, text: []const u8) !void {
        // Add initial spacing so first message isn't flush against top
        if (self.lines.items.len == 0) {
            try self.addLine("", .{});
        }
        try self.addLine(user_marker, .{});
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            const safe_line = try sanitizeAlloc(self.allocator, line);
            defer self.allocator.free(safe_line);
            try self.addLine(user_marker ++ "{s}", .{safe_line});
        }
        try self.addLine(user_marker, .{});
    }

    fn addAssistantBlock(self: *App, text: []const u8) !void {
        // Parse markdown-style code blocks and apply syntax highlighting
        var lines = std.mem.splitScalar(u8, text, '\n');
        var in_code_block = false;
        var code_lang: ?[]const u8 = null;
        var code_buffer: std.ArrayList(u8) = .empty;
        defer code_buffer.deinit(self.allocator);

        while (lines.next()) |line| {
            // Check for code block start/end
            if (std.mem.startsWith(u8, line, "```")) {
                if (!in_code_block) {
                    // Start of code block - extract language
                    in_code_block = true;
                    const after_backticks = line[3..];
                    const lang = std.mem.trim(u8, after_backticks, " \t");
                    if (lang.len > 0) {
                        code_lang = lang;
                    }
                } else {
                    // End of code block - render highlighted code
                    in_code_block = false;
                    if (code_buffer.items.len > 0 and self.highlighter != null) {
                        const lang = code_lang orelse "text";
                        const highlighted = self.highlighter.?.highlightLines(lang, code_buffer.items) catch |err| blk: {
                            // Fall back to plain text
                            var plain_lines = std.ArrayList([]u8).empty;
                            var it = std.mem.splitScalar(u8, code_buffer.items, '\n');
                            while (it.next()) |l| {
                                try plain_lines.append(self.allocator, try self.allocator.dupe(u8, l));
                            }
                            break :blk plain_lines.toOwnedSlice(self.allocator) catch return err;
                        };
                        defer {
                            for (highlighted) |hl| self.allocator.free(hl);
                            self.allocator.free(highlighted);
                        }

                        for (highlighted) |hl_line| {
                            // Don't sanitize highlighted content - it already contains ANSI codes
                            try self.addLine("{s}", .{hl_line});
                        }
                    } else if (code_buffer.items.len > 0) {
                        // No highlighter - plain text
                        var it = std.mem.splitScalar(u8, code_buffer.items, '\n');
                        while (it.next()) |l| {
                            const safe = try sanitizeAlloc(self.allocator, l);
                            defer self.allocator.free(safe);
                            try self.addLine("{s}", .{safe});
                        }
                    }
                    code_buffer.clearRetainingCapacity();
                    code_lang = null;
                }
            } else if (in_code_block) {
                // Collect code block content
                if (code_buffer.items.len > 0) {
                    try code_buffer.append(self.allocator, '\n');
                }
                try code_buffer.appendSlice(self.allocator, line);
            } else {
                // Regular text line
                const safe_line = try sanitizeAlloc(self.allocator, line);
                defer self.allocator.free(safe_line);
                try self.addLine("{s}", .{safe_line});
            }
        }

        // Handle unclosed code block
        if (in_code_block and code_buffer.items.len > 0) {
            const lang = code_lang orelse "text";
            if (self.highlighter) |h| {
                const highlighted = h.highlightLines(lang, code_buffer.items) catch |err| blk: {
                    var plain_lines = std.ArrayList([]u8).empty;
                    var it = std.mem.splitScalar(u8, code_buffer.items, '\n');
                    while (it.next()) |l| {
                        try plain_lines.append(self.allocator, try self.allocator.dupe(u8, l));
                    }
                    break :blk plain_lines.toOwnedSlice(self.allocator) catch return err;
                };
                defer {
                    for (highlighted) |hl| self.allocator.free(hl);
                    self.allocator.free(highlighted);
                }

                for (highlighted) |hl_line| {
                    // Don't sanitize highlighted content - it already contains ANSI codes
                    try self.addLine("{s}", .{hl_line});
                }
            } else {
                var it = std.mem.splitScalar(u8, code_buffer.items, '\n');
                while (it.next()) |l| {
                    const safe = try sanitizeAlloc(self.allocator, l);
                    defer self.allocator.free(safe);
                    try self.addLine("{s}", .{safe});
                }
            }
        }
    }

    fn removeLineAt(self: *App, index: usize) void {
        if (index >= self.lines.items.len) return;
        const removed = self.lines.orderedRemove(index);
        self.allocator.free(removed);
    }

    fn addLine(self: *App, comptime fmt: []const u8, args: anytype) !void {
        try self.lines.append(self.allocator, try std.fmt.allocPrint(self.allocator, fmt, args));
    }

    fn render(self: *App) !void {
        try self.renderPrompt("message");
    }

    fn renderPrompt(self: *App, prompt: []const u8) !void {
        var stdout_buf: [8192]u8 = undefined;
        var stdout_file = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &stdout_buf);
        const stdout = &stdout_file.interface;
        defer stdout.flush() catch {};
        const size = terminal.size();
        if (size.rows < 7 or size.cols < 20) {
            try stdout.writeAll("\x1b[H\x1b[2J");
            try stdout.print("{s}{s}Terminal too small{s}\x1b[1;1H\x1b[?25h", .{ theme.mocha.mantle_bg, theme.mocha.text, theme.reset });
            return;
        }

        const rows = size.rows;
        const cols = size.cols;
        const left_margin: usize = 2;
        // Reserve space for the scrollbar plus row prefixes like "│ ", so
        // conversation text never renders underneath the scrollbar overlay.
        const right_margin: usize = 4;
        const inner_cols: usize = @max(4, @as(usize, cols) - left_margin - right_margin);
        self.inner_cols = inner_cols;
        const input_rows: usize = 8;
        const input_inner_cols = inner_cols;
        const content_rows: usize = rows - input_rows;

        try stdout.print("\x1b[?25l{s}\x1b[H\x1b[2J", .{theme.mocha.mantle_bg});

        const wrapped_count = self.countWrappedRows(inner_cols);
        const max_scroll = if (wrapped_count > content_rows) wrapped_count - content_rows else 0;
        const first_row_to_show = @min(self.scroll_offset, max_scroll);

        const printed_rows = try self.printConversation(stdout, inner_cols, left_margin, first_row_to_show, content_rows);
        var filled = printed_rows;
        while (filled < content_rows) : (filled += 1) {
            try stdout.print("{s}", .{theme.mocha.mantle_bg});
            try self.writeMargin(stdout, left_margin);
            try stdout.splatByteAll(' ', inner_cols);
            try stdout.print("\x1b[K{s}\n", .{theme.reset});
        }

        try self.printScrollbar(stdout, @as(usize, cols), content_rows, wrapped_count, first_row_to_show, max_scroll);

        const cursor_col = try self.printInputArea(stdout, prompt, input_inner_cols, left_margin);
        try stdout.print("{s}", .{theme.reset});

        const input_row = rows - 2;
        try stdout.print("\x1b[{d};{d}H\x1b[?25h", .{ input_row, cursor_col });
    }

    fn printConversation(self: *App, stdout: anytype, inner_cols: usize, left_margin: usize, start_row: usize, max_rows: usize) !usize {
        var skipped: usize = 0;
        var printed: usize = 0;
        for (self.lines.items) |line| {
            const is_thinking = std.mem.startsWith(u8, line, thinking_marker);
            const display_line = if (is_thinking) line[thinking_marker.len..] else line;

            // Detect user message at conversation level (like thinking)
            const is_user_message = !is_thinking and std.mem.startsWith(u8, display_line, user_marker);
            const user_content = if (is_user_message) display_line[user_marker.len..] else display_line;

            const effective_line = if (is_user_message) user_content else display_line;
            const row_cols = rowContentCols(inner_cols, is_user_message, is_thinking);
            const line_rows = wrappedRows(effective_line.len, row_cols);

            if (skipped + line_rows <= start_row) {
                skipped += line_rows;
                continue;
            }

            if (effective_line.len == 0) {
                if (printed < max_rows and skipped >= start_row) {
                    if (is_user_message) {
                        try self.printUserRowWithMargin(stdout, "", left_margin, true);
                    } else if (is_thinking) {
                        try self.printThinkingRowWithMargin(stdout, "", left_margin);
                    } else {
                        try self.printRowWithMargin(stdout, "", left_margin);
                    }
                    printed += 1;
                }
                if (printed >= max_rows) break;
                skipped += line_rows;
                continue;
            }

            var offset: usize = 0;
            var local_row: usize = 0;
            while (offset < effective_line.len and printed < max_rows) : (local_row += 1) {
                if (skipped + local_row < start_row) {
                    offset += @min(row_cols, effective_line.len - offset);
                    continue;
                }
                const chunk_len = @min(row_cols, effective_line.len - offset);
                const chunk = effective_line[offset .. offset + chunk_len];
                if (is_user_message) {
                    // First row of user message gets border, continuation rows don't
                    try self.printUserRowWithMargin(stdout, chunk, left_margin, local_row == 0);
                } else if (is_thinking) {
                    try self.printThinkingRowWithMargin(stdout, chunk, left_margin);
                } else {
                    try self.printRowWithMargin(stdout, chunk, left_margin);
                }
                offset += chunk_len;
                printed += 1;
            }

            if (printed >= max_rows) break;
            skipped += line_rows;
        }
        return printed;
    }

    fn printScrollbar(self: *App, stdout: anytype, cols: usize, content_rows: usize, total_rows: usize, first_row: usize, max_scroll: usize) !void {
        _ = self;
        if (cols < 2 or content_rows == 0 or total_rows <= content_rows) return;

        const scrollbar_col = cols - 1;
        const thumb_height = @max(1, (content_rows * content_rows) / total_rows);
        const max_thumb_start = content_rows - thumb_height;
        const thumb_start = if (max_scroll == 0) 0 else (first_row * max_thumb_start) / max_scroll;
        const thumb_end = thumb_start + thumb_height;

        var row: usize = 0;
        while (row < content_rows) : (row += 1) {
            const is_thumb = row >= thumb_start and row < thumb_end;
            const glyph = if (is_thumb) "█" else "│";
            const color = if (is_thumb) theme.mocha.subtext0 else theme.mocha.surface0;
            try stdout.print("\x1b[{d};{d}H{s}{s}{s}", .{ row + 1, scrollbar_col, color, glyph, theme.reset });
        }
    }

    fn countWrappedRows(self: *App, inner_cols: usize) usize {
        var total: usize = 0;
        for (self.lines.items) |line| {
            const is_thinking = std.mem.startsWith(u8, line, thinking_marker);
            const is_user = !is_thinking and std.mem.startsWith(u8, line, user_marker);
            const display = if (is_thinking) line[thinking_marker.len..] else if (is_user) line[user_marker.len..] else line;
            total += wrappedRows(display.len, rowContentCols(inner_cols, is_user, is_thinking));
        }
        return total;
    }

    fn rowContentCols(inner_cols: usize, is_user: bool, is_thinking: bool) usize {
        const reserved: usize = if (is_user or is_thinking) 2 else 2;
        return if (inner_cols > reserved) inner_cols - reserved else 1;
    }

    fn getContentRows(_: *App) usize {
        const size = terminal.size();
        if (size.rows < 7) return 1;
        const rows = size.rows;
        const input_rows: usize = 5;
        return rows - input_rows;
    }

    fn getMaxScroll(self: *App) usize {
        const content_rows = self.getContentRows();
        const total = self.countWrappedRows(self.inner_cols);
        return if (total > content_rows) total - content_rows else 0;
    }

    fn printSeparator(self: *App, stdout: anytype, inner_cols: usize, left_margin: usize) !void {
        try stdout.print("{s}", .{theme.mocha.base_bg});
        try self.writeMargin(stdout, left_margin);
        try stdout.splatByteAll(' ', inner_cols);
        try stdout.print("\x1b[K\n", .{});
    }

    fn printInputArea(self: *App, stdout: anytype, prompt: []const u8, inner_cols: usize, left_margin: usize) !usize {
        const safe_prompt = try sanitizeAlloc(self.allocator, prompt);
        defer self.allocator.free(safe_prompt);
        const safe_model = try sanitizeAlloc(self.allocator, self.cfg.model);
        defer self.allocator.free(safe_model);

        const border = "│";
        const border_cols: usize = 1;
        const input_right_padding: usize = 1;
        const input_prefix_cols = border_cols + 1;
        const room_for_input: usize = if (inner_cols > input_prefix_cols + input_right_padding)
            inner_cols - input_prefix_cols - input_right_padding
        else
            0;

        // Determine visible window of input that includes the cursor
        const window_start = if (room_for_input == 0)
            self.cursor_pos
        else if (self.cursor_pos >= room_for_input)
            self.cursor_pos - room_for_input + 1
        else
            0;
        const visible_len = if (room_for_input == 0) 0 else @min(room_for_input, self.input.items.len - window_start);
        const visible_input = self.input.items[window_start .. window_start + visible_len];
        const cursor_in_visible = if (room_for_input == 0) 0 else self.cursor_pos - window_start;

        try stdout.print("{s}", .{theme.mocha.mantle_bg});
        try self.writeMargin(stdout, left_margin);
        try stdout.print("{s}{s}{s} {s}", .{
            theme.mocha.base_bg,
            theme.mocha.lavender,
            border,
            theme.mocha.text,
        });
        if (border_cols + 1 < inner_cols) try stdout.splatByteAll(' ', inner_cols - border_cols - 1);
        try stdout.print("\x1b[K{s}\n", .{theme.reset});

        // Keep the input row dedicated to editable text so cursor math stays tied to input only.
        try stdout.print("{s}", .{theme.mocha.mantle_bg});
        try self.writeMargin(stdout, left_margin);
        try stdout.print("{s}{s}{s} {s}{s}", .{
            theme.mocha.base_bg,
            theme.mocha.lavender,
            border,
            theme.mocha.text,
            visible_input,
        });
        const used_cols = @min(inner_cols, input_prefix_cols + visible_input.len);
        if (used_cols < inner_cols) try stdout.splatByteAll(' ', inner_cols - used_cols);
        try stdout.print("\x1b[K{s}\n", .{theme.reset});

        // Bottom padding inside the input box so glyph descenders are not visually clipped.
        try stdout.print("{s}", .{theme.mocha.mantle_bg});
        try self.writeMargin(stdout, left_margin);
        try stdout.print("{s}{s}{s} {s}", .{
            theme.mocha.base_bg,
            theme.mocha.lavender,
            border,
            theme.mocha.text,
        });
        if (border_cols + 1 < inner_cols) try stdout.splatByteAll(' ', inner_cols - border_cols - 1);
        try stdout.print("\x1b[K{s}\n", .{theme.reset});

        try self.printPendingLoader(stdout, inner_cols, left_margin);

        // Small space below input box
        try stdout.print("{s}", .{theme.mocha.mantle_bg});
        try self.writeMargin(stdout, left_margin);
        try stdout.splatByteAll(' ', inner_cols);
        try stdout.print("\x1b[K{s}\n", .{theme.reset});

        return left_margin + border_cols + 1 + cursor_in_visible + 1;
    }

    fn printPendingLoader(self: *App, stdout: anytype, inner_cols: usize, left_margin: usize) !void {
        try stdout.print("{s}", .{theme.mocha.mantle_bg});
        try self.writeMargin(stdout, left_margin);
        if (self.is_busy) {
            const width: usize = 5;
            const cycle = width * 2 - 2;
            const phase = self.loader_frame % cycle;
            const active = if (phase < width) phase else cycle - phase;

            var i: usize = 0;
            while (i < width) : (i += 1) {
                if (i == active) {
                    try stdout.print("{s}█", .{theme.mocha.lavender});
                } else {
                    try stdout.print("{s}▪", .{theme.mocha.surface0});
                }
            }
            self.loader_frame += 1;
            if (width < inner_cols) try stdout.splatByteAll(' ', inner_cols - width);
        } else {
            self.loader_frame = 0;
            try stdout.splatByteAll(' ', inner_cols);
        }
        try stdout.print("\x1b[K{s}\n", .{theme.reset});
    }

    fn printUserRowWithMargin(self: *App, stdout: anytype, text: []const u8, left_margin: usize, is_first_row: bool) !void {
        _ = self;
        // Start with mantle background for margin area
        try stdout.print("{s}", .{theme.mocha.mantle_bg});
        // Write left margin spaces
        try stdout.splatByteAll(' ', left_margin);
        // Then surface0 background for user message content
        if (is_first_row) {
            try stdout.print("{s}│{s} {s}", .{ theme.mocha.surface0_bg, theme.mocha.text, text });
        } else {
            // Continuation row - same surface0 background, space indent, no border
            try stdout.print("{s} {s}", .{ theme.mocha.surface0_bg, text });
        }
        // Fill rest of line with surface0 background
        try stdout.print("\x1b[K{s}\n", .{theme.reset});
    }

    fn printThinkingRowWithMargin(self: *App, stdout: anytype, text: []const u8, left_margin: usize) !void {
        try self.writeMargin(stdout, left_margin);
        try stdout.print("{s}{s}│{s} {s}\x1b[K\n", .{ theme.mocha.mantle_bg, theme.mocha.surface0, theme.mocha.subtext0, text });
    }

    fn printRowWithMargin(_: *App, stdout: anytype, text: []const u8, left_margin: usize) !void {
        // Write left margin spaces
        var i: usize = 0;
        while (i < left_margin) : (i += 1) {
            try stdout.writeAll(" ");
        }

        // Thinking block lines - render all thinking text in gray.
        if (std.mem.startsWith(u8, text, thinking_marker)) {
            try stdout.print("{s}{s}{s}\x1b[K\n", .{ theme.mocha.mantle_bg, theme.mocha.subtext0, text[thinking_marker.len..] });
            return;
        }

        // User messages are handled separately in printConversation
        if (std.mem.startsWith(u8, text, user_marker)) {
            try stdout.print("{s}{s}\x1b[K\n", .{ theme.mocha.text, text[user_marker.len..] });
            return;
        }

        // Thinking placeholder.
        if (text.len >= 6 and std.mem.eql(u8, text[0..6], "  │ thi")) {
            try stdout.print("{s}{s}│{s}{s}\x1b[K\n", .{ theme.mocha.base_bg, theme.mocha.subtext0, theme.mocha.subtext0, "thinking…" });
            return;
        }
        // Code blocks have "  ─" prefix - render with subtle styling
        if (text.len >= 3 and std.mem.eql(u8, text[0..3], "  ─")) {
            try stdout.print("{s}{s} {s}\x1b[K\n", .{ theme.mocha.base_bg, theme.mocha.subtext0, text[2..] });
            return;
        }
        try stdout.print("{s}{s}  {s}\x1b[K\n", .{ theme.mocha.mantle_bg, theme.mocha.text, text });
    }

    fn writeMargin(self: *App, stdout: anytype, left_margin: usize) !void {
        _ = self;
        try stdout.splatByteAll(' ', left_margin);
    }
};

fn sanitizeAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (text) |byte| {
        switch (byte) {
            0...8, 11...31, 127...159 => try out.append(allocator, '?'),
            9 => try out.append(allocator, ' '),
            else => try out.append(allocator, byte),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn wrappedRows(line_len: usize, width: usize) usize {
    if (width == 0) return 1;
    if (line_len == 0) return 1;
    return (line_len + width - 1) / width;
}

pub fn run(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var term = try terminal.Terminal.enter();
    defer term.leave();

    var app = try App.init(allocator, cfg);
    defer app.deinit();

    try app.start();
    try app.loop();
}
