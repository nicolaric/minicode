const std = @import("std");
const ollama = @import("../ollama.zig");
const theme = @import("../theme.zig");
const terminal = @import("../terminal.zig");
const tools = @import("../tools.zig");
const agent = @import("../agent.zig");
const config = @import("../config.zig");
const syntax_highlight = @import("../syntax_highlight.zig");

const utils = @import("utils.zig");
const input_mod = @import("input.zig");
const render_mod = @import("render.zig");
const components = @import("components.zig");
const context_tracker = @import("../context_tracker.zig");

const thinking_marker = utils.thinking_marker;
const user_marker = utils.user_marker;
const diff_box_marker = utils.diff_box_marker;
const shell_output_marker = utils.shell_output_marker;
const GrepMatch = utils.GrepMatch;
const ReadContinuation = utils.ReadContinuation;
const ConfirmDialog = utils.ConfirmDialog;

// Welcome screen title
pub const welcome_title_lines = [_][]const u8{
    "███    ███ ██ ███    ██ ██  ██████  ██████  ██████  ███████ ",
    "████  ████ ██ ████   ██ ██ ██      ██    ██ ██   ██ ██      ",
    "██ ████ ██ ██ ██ ██  ██ ██ ██      ██    ██ ██   ██ █████   ",
    "██  ██  ██ ██ ██  ██ ██ ██ ██      ██    ██ ██   ██ ██      ",
    "██      ██ ██ ██   ████ ██  ██████  ██████  ██████  ███████ ",
};

// Empty banner (can be customized)
const minicode_banner = "";

pub const App = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    owned_model: ?[]u8,
    messages: std.ArrayList(ollama.Message),
    lines: std.ArrayList([]u8),
    input: std.ArrayList(u8),
    cursor_pos: usize,
    paste_buffer: std.ArrayList(u8),
    pasting: bool,
    last_paste_content: ?[]u8,
    scroll_offset: usize,
    inner_cols: usize,
    input_cleared: bool,
    is_busy: bool,
    loader_frame: usize,
    cancel_requested: bool,
    // Streaming accumulation
    stream_content: std.ArrayList(u8),
    stream_thinking: std.ArrayList(u8),
    stream_tool_calls: std.ArrayList(ollama.ToolCall),
    stream_lines_start: usize,
    thinking_started: bool,
    read_requests: std.ArrayList([]u8),
    grep_matches: std.ArrayList(GrepMatch),
    read_continuations: std.ArrayList(ReadContinuation),
    // Syntax highlighter
    highlighter: ?*syntax_highlight.SyntaxHighlighter,
    // Welcome screen state
    show_welcome: bool,
    welcome_rendered: bool,
    show_model_modal: bool,
    model_names: ?[][]u8,
    model_error: ?[]u8,
    model_selected: usize,
    // Command palette state
    show_command_palette: bool,
    command_selected: usize,
    // Confirmation dialog state
    confirm_dialog: ?ConfirmDialog,
    // Shell command streaming state
    shell_stream_content: std.ArrayList(u8),
    shell_stream_lines_start: usize,
    is_shell_streaming: bool,
    // Model preloading state
    preload_thread: ?std.Thread,
    preload_complete: std.atomic.Value(bool),
    is_preloading: bool,
    // Welcome screen cached layout
    welcome_top_margin: ?usize,
    // Context tracking for long conversations
    tracker: context_tracker.ContextTracker,
    // Request timing
    request_start_time: ?i64,
    last_request_duration: ?f64,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !App {
        const highlighter = try syntax_highlight.SyntaxHighlighter.create(allocator);
        errdefer highlighter.destroy();

        var effective_cfg = cfg;
        var owned_model: ?[]u8 = null;
        if (!cfg.model_explicit) {
            if (ollama.listModels(allocator, cfg)) |models| {
                defer ollama.freeModels(allocator, models);
                if (models.len > 0) {
                    owned_model = try allocator.dupe(u8, models[0]);
                    effective_cfg.model = owned_model.?;
                }
            } else |_| {}
        }
        errdefer if (owned_model) |model| allocator.free(model);

        var tracker = context_tracker.ContextTracker.init(allocator);
        errdefer tracker.deinit();

        return .{
            .allocator = allocator,
            .cfg = effective_cfg,
            .owned_model = owned_model,
            .messages = .empty,
            .lines = .empty,
            .input = .empty,
            .paste_buffer = .empty,
            .pasting = false,
            .last_paste_content = null,
            .cursor_pos = 0,
            .scroll_offset = 0,
            .inner_cols = 80,
            .input_cleared = false,
            .is_busy = false,
            .loader_frame = 0,
            .cancel_requested = false,
            .stream_content = .empty,
            .stream_thinking = .empty,
            .stream_tool_calls = .empty,
            .stream_lines_start = 0,
            .thinking_started = false,
            .read_requests = .empty,
            .grep_matches = .empty,
            .read_continuations = .empty,
            .highlighter = highlighter,
            .show_welcome = true,
            .welcome_rendered = false,
            .show_model_modal = false,
            .model_names = null,
            .model_error = null,
            .model_selected = 0,
            .show_command_palette = false,
            .command_selected = 0,
            .confirm_dialog = null,
            .shell_stream_content = .empty,
            .shell_stream_lines_start = 0,
            .is_shell_streaming = false,
            .preload_thread = null,
            .preload_complete = std.atomic.Value(bool).init(false),
            .is_preloading = false,
            .welcome_top_margin = null,
            .tracker = tracker,
            .request_start_time = null,
            .last_request_duration = null,
        };
    }

    pub fn deinit(self: *App) void {
        self.clearMessages();
        self.messages.deinit(self.allocator);
        self.clearLines();
        self.lines.deinit(self.allocator);
        self.input.deinit(self.allocator);
        self.paste_buffer.deinit(self.allocator);
        if (self.last_paste_content) |content| self.allocator.free(content);
        if (self.owned_model) |model| self.allocator.free(model);
        self.stream_content.deinit(self.allocator);
        self.stream_thinking.deinit(self.allocator);
        self.clearStreamToolCalls();
        self.stream_tool_calls.deinit(self.allocator);
        self.clearReadRequests();
        self.read_requests.deinit(self.allocator);
        self.clearGrepMatches();
        self.grep_matches.deinit(self.allocator);
        self.clearReadContinuations();
        self.read_continuations.deinit(self.allocator);
        self.clearModelModalData();
        if (self.highlighter) |h| h.destroy();
        if (self.confirm_dialog) |*dialog| {
            self.allocator.free(dialog.prompt);
        }
        self.shell_stream_content.deinit(self.allocator);
        if (self.preload_thread) |thread| {
            thread.join();
            self.preload_thread = null;
        }
        self.tracker.deinit();
    }

    const PreloadContext = struct {
        allocator: std.mem.Allocator,
        cfg: config.Config,
        complete: *std.atomic.Value(bool),
    };

    fn preloadThreadFn(ctx: PreloadContext) void {
        ollama.preloadModel(ctx.allocator, ctx.cfg) catch {};
        ctx.complete.store(true, .monotonic);
    }

    pub fn start(self: *App) !void {
        try self.addSystemPrompt();
        self.is_preloading = true;
        try self.render();
        const ctx = PreloadContext{
            .allocator = self.allocator,
            .cfg = self.cfg,
            .complete = &self.preload_complete,
        };
        self.preload_thread = try std.Thread.spawn(.{}, preloadThreadFn, .{ctx});
    }

    pub fn loop(self: *App) !void {
        var stdin_buf: [256]u8 = undefined;
        var stdin_file = std.Io.File.stdin().readerStreaming(std.Options.debug_io, &stdin_buf);
        const stdin = &stdin_file.interface;
        while (true) {
            var byte: [1]u8 = undefined;
            const read_len = stdin.readSliceShort(&byte) catch {
                terminal.ensureForeground(std.posix.STDIN_FILENO);
                utils.sleepAfterInputError();
                continue;
            };
            if (read_len == 0) {
                // Check if preloading is complete
                if (self.preload_thread != null and self.preload_complete.load(.monotonic)) {
                    self.preload_thread.?.join();
                    self.preload_thread = null;
                    self.is_preloading = false;
                    try self.render();
                }
                continue;
            }
            if (self.show_model_modal and try input_mod.handleModelModalKey(self, stdin, byte[0])) continue;
            if (self.show_command_palette and try input_mod.handleCommandPaletteKey(self, stdin, byte[0])) continue;
            switch (byte[0]) {
                3 => { // Ctrl+C - exit the app (cancel streaming if active)
                    if (self.is_busy) {
                        self.cancel_requested = true;
                        try self.render();
                        continue;
                    }
                    break;
                },
                21 => { // Ctrl+U - scroll up (half page)
                    self.scrollUp(self.getContentRows() / 2);
                    try self.render();
                },
                4 => { // Ctrl+D - scroll down (half page)
                    self.scrollDown(self.getContentRows() / 2);
                    try self.render();
                },
                '/' => {
                    if (self.is_busy) continue;
                    const trimmed = std.mem.trim(u8, self.input.items, " \t\r\n");
                    if (trimmed.len == 0) {
                        self.show_command_palette = true;
                        self.command_selected = 0;
                        try self.render();
                        continue;
                      }
                },
                '\r', '\n' => {
                    if (self.pasting) {
                        // During paste, capture newlines as part of the pasted content
                        try self.paste_buffer.append(self.allocator, byte[0]);
                        continue;
                    }
                    if (self.is_busy) {
                        // While streaming we keep the draft input intact.
                        continue;
                    }
                    const trimmed = std.mem.trim(u8, self.input.items, " \t\r\n");
                    if (trimmed.len == 0) {
                        self.input.clearRetainingCapacity();
                        self.cursor_pos = 0;
                        self.input_cleared = false;
                        try self.render();
                        continue;
                    }
                    if (std.mem.eql(u8, trimmed, "/exit") or std.mem.eql(u8, trimmed, "/quit")) {
                        // Exit cleanly
                        return;
                    }
                    if (std.mem.eql(u8, trimmed, "/new")) {
                        try self.resetConversation();
                        try self.render();
                        continue;
                    }
                    if (std.mem.eql(u8, trimmed, "/model")) {
                        try self.openModelModal();
                        try self.render();
                        continue;
                    }

                    // Wait for preloading to complete if still in progress
                    if (self.is_preloading) {
                        if (self.preload_thread) |thread| {
                            thread.join();
                            self.preload_thread = null;
                        }
                        self.is_preloading = false;
                    }

                    // Switch from welcome screen to normal view on first message
                    const is_first_message = self.show_welcome;
                    self.show_welcome = false;

                    // Replace "[pasted X lines]" placeholder with actual content
                    const user_text = if (self.last_paste_content) |paste_content| blk: {
                        // Check if input contains the paste placeholder
                        const placeholder_start = std.mem.indexOf(u8, trimmed, "[pasted ");
                        if (placeholder_start) |ph_start| {
                            const placeholder_end = std.mem.indexOf(u8, trimmed[ph_start..], "]");
                            if (placeholder_end) |end| {
                                const total_len = ph_start + (trimmed.len - (ph_start + end + 1)) + paste_content.len;
                                var result = try self.allocator.alloc(u8, total_len);
                                // Copy text before placeholder
                                @memcpy(result[0..ph_start], trimmed[0..ph_start]);
                                // Copy actual paste content
                                @memcpy(result[ph_start..ph_start + paste_content.len], paste_content);
                                // Copy text after placeholder
                                const after_placeholder = ph_start + end + 1;
                                @memcpy(result[ph_start + paste_content.len..], trimmed[after_placeholder..]);
                                break :blk result;
                            }
                        }
                        break :blk try self.allocator.dupe(u8, trimmed);
                    } else try self.allocator.dupe(u8, trimmed);
                    const safe_user_text = try utils.sanitizeAlloc(self.allocator, user_text);
                    defer self.allocator.free(safe_user_text);
                    self.input.clearRetainingCapacity();
                    self.cursor_pos = 0;
                    self.scroll_offset = 0;
                    self.input_cleared = false;
                    self.is_busy = true;
                    var ts: std.c.timespec = undefined;
                    if (std.c.clock_gettime(.REALTIME, &ts) == 0) {
                        self.request_start_time = @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
                    }

                    // Only add spacing if not first message
                    if (!is_first_message and self.lines.items.len > 0) {
                        try self.addLine("", .{});
                    }

                    try self.addUserBlock(safe_user_text);
                    try self.messages.append(self.allocator, .{ .role = .user, .content = user_text });
                    // Clean up paste content after sending
                    if (self.last_paste_content) |content| {
                        self.allocator.free(content);
                        self.last_paste_content = null;
                    }
                    const stream_start = self.lines.items.len;
                    try self.render();
                    completeTurn(self, stream_start) catch |err| {
                        try self.addLine("Error during turn: {s}", .{@errorName(err)});
                    };
                    self.is_busy = false;
                    if (self.request_start_time) |start_time| {
                        var end_ts: std.c.timespec = undefined;
                        if (std.c.clock_gettime(.REALTIME, &end_ts) == 0) {
                            const end_time = @as(i64, end_ts.sec) * 1000 + @divTrunc(@as(i64, end_ts.nsec), 1_000_000);
                            self.last_request_duration = @as(f64, @floatFromInt(end_time - start_time)) / 1000.0;
                        }
                    }
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
                                if (try input_mod.handleSgrMouse(self, stdin)) try self.render();
                            },
                            '1' => {
                                if (try input_mod.handleModifiedArrow(self, stdin)) try self.render();
                            },
                                '2' => {
                                var seq3: [1]u8 = undefined;
                                const n3 = stdin.readSliceShort(&seq3) catch 0;
                                if (n3 == 0) continue;
                                if (seq3[0] == '0') {
                                    // Could be ESC[200~ (start paste) or ESC[201~ (end paste)
                                    var seq4: [1]u8 = undefined;
                                    const n4 = stdin.readSliceShort(&seq4) catch 0;
                                    if (n4 == 0) continue;
                                    var tilde: [1]u8 = undefined;
                                    const nt = stdin.readSliceShort(&tilde) catch 0;
                                    if (nt == 0 or tilde[0] != '~') continue;
                                    if (seq4[0] == '0') {
                                        // ESC[200~ - Start bracketed paste
                                        self.pasting = true;
                                        self.paste_buffer.clearRetainingCapacity();
                                        continue;
                                    } else if (seq4[0] == '1') {
                                        // ESC[201~ - End bracketed paste
                                        self.pasting = false;
                                        // Store the actual pasted content for later use
                                        if (self.last_paste_content) |content| self.allocator.free(content);
                                        self.last_paste_content = self.allocator.dupe(u8, self.paste_buffer.items) catch null;
                                        const line_count = std.mem.count(u8, self.paste_buffer.items, "\n");
                                        const total_lines = if (self.paste_buffer.items.len > 0) line_count + 1 else 0;
                                        const replacement = std.fmt.allocPrint(self.allocator, "[pasted {d} lines]", .{total_lines}) catch continue;
                                        defer self.allocator.free(replacement);
                                        _ = self.input.insertSlice(self.allocator, self.cursor_pos, replacement) catch continue;
                                        self.cursor_pos += replacement.len;
                                        self.paste_buffer.clearRetainingCapacity();
                                        try self.render();
                                        continue;
                                    }
                                }
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
                    if (self.pasting) {
                        // During paste, capture all characters including newlines (10) and CR (13)
                        try self.paste_buffer.append(self.allocator, ch);
                        continue;
                    } else if (ch >= 32 and ch != 127) {
                        if (self.input.items.len < utils.max_input) {
                            try self.input.insert(self.allocator, self.cursor_pos, ch);
                            self.cursor_pos += 1;
                            try self.render();
                        }
                    }
                },
            }
        }
    }

    pub fn render(self: *App) !void {
        if (self.show_welcome) {
            if (self.welcome_rendered) {
                try render_mod.renderWelcomeInput(self);
            } else {
                try render_mod.renderWelcome(self);
                self.welcome_rendered = true;
            }
        } else {
            try render_mod.renderPrompt(self, "");
        }
    }

    // These are public wrappers for internal methods that are used across modules

    pub fn moveCursorWordLeft(self: *App) void {
        while (self.cursor_pos > 0 and utils.isWordSeparator(self.input.items[self.cursor_pos - 1])) {
            self.cursor_pos -= 1;
        }
        while (self.cursor_pos > 0 and !utils.isWordSeparator(self.input.items[self.cursor_pos - 1])) {
            self.cursor_pos -= 1;
        }
    }

    pub fn moveCursorWordRight(self: *App) void {
        while (self.cursor_pos < self.input.items.len and utils.isWordSeparator(self.input.items[self.cursor_pos])) {
            self.cursor_pos += 1;
        }
        while (self.cursor_pos < self.input.items.len and !utils.isWordSeparator(self.input.items[self.cursor_pos])) {
            self.cursor_pos += 1;
        }
    }

    pub fn deleteWordLeft(self: *App) void {
        const end = self.cursor_pos;
        self.moveCursorWordLeft();
        const delete_start = self.cursor_pos;
        if (delete_start == end) return;
        self.input.replaceRange(self.allocator, delete_start, end - delete_start, "") catch return;
    }

    pub fn scrollUp(self: *App, lines: usize) void {
        if (self.scroll_offset > lines) {
            self.scroll_offset -= lines;
        } else {
            self.scroll_offset = 0;
        }
    }

    pub fn scrollDown(self: *App, lines: usize) void {
        const max_scroll = self.getMaxScroll();
        if (self.scroll_offset < max_scroll) {
            self.scroll_offset += lines;
            if (self.scroll_offset > max_scroll) self.scroll_offset = max_scroll;
        }
    }

    pub fn getContentRows(self: *App) usize {
        return render_mod.getContentRows(self);
    }

    pub fn getMaxScroll(self: *App) usize {
        return render_mod.getMaxScroll(self);
    }

    pub fn clearModelModalData(self: *App) void {
        if (self.model_names) |names| {
            ollama.freeModels(self.allocator, names);
            self.model_names = null;
        }
        if (self.model_error) |message| {
            self.allocator.free(message);
            self.model_error = null;
        }
        self.model_selected = 0;
    }

    pub fn openModelModal(self: *App) !void {
        self.clearModelModalData();
        self.show_model_modal = true;
        self.model_names = ollama.listModels(self.allocator, self.cfg) catch |err| blk: {
            self.model_error = try std.fmt.allocPrint(self.allocator, "Could not load Ollama models: {s}", .{@errorName(err)});
            break :blk null;
        };
    }

    pub fn closeModelModal(self: *App) void {
        self.show_model_modal = false;
    }

    pub fn closeCommandPalette(self: *App) void {
        self.show_command_palette = false;
     }

    fn addSystemPrompt(self: *App) !void {
        try self.messages.append(self.allocator, .{ .role = .system, .content = try self.allocator.dupe(u8, agent.system_prompt) });
    }

    pub fn clearMessages(self: *App) void {
        for (self.messages.items) |message| {
            self.allocator.free(message.content);
            if (message.thinking) |thinking| self.allocator.free(thinking);
            if (message.tool_calls) |tool_calls| ollama.freeToolCalls(self.allocator, tool_calls);
            if (message.tool_name) |tool_name| self.allocator.free(tool_name);
            if (message.tool_call_id) |tool_call_id| self.allocator.free(tool_call_id);
        }
        self.messages.clearRetainingCapacity();
    }

    pub fn clearLines(self: *App) void {
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.clearRetainingCapacity();
    }

    pub fn resetConversation(self: *App) !void {
        self.clearMessages();
        try self.addSystemPrompt();
        self.clearLines();
        self.input.clearRetainingCapacity();
        self.cursor_pos = 0;
        self.scroll_offset = 0;
        self.input_cleared = false;
        self.is_busy = false;
        self.cancel_requested = false;
        self.stream_content.clearRetainingCapacity();
        self.stream_thinking.clearRetainingCapacity();
        self.clearStreamToolCalls();
        self.stream_lines_start = 0;
        self.thinking_started = false;
        self.clearReadRequests();
        self.clearGrepMatches();
        self.clearReadContinuations();
        self.show_welcome = true;
        self.welcome_rendered = false;
        self.tracker.reset();
    }

    pub fn clearReadRequests(self: *App) void {
        for (self.read_requests.items) |key| self.allocator.free(key);
        self.read_requests.clearRetainingCapacity();
    }

    pub fn clearStreamToolCalls(self: *App) void {
        for (self.stream_tool_calls.items) |call| ollama.freeToolCall(self.allocator, call);
        self.stream_tool_calls.clearRetainingCapacity();
    }

    pub fn clearGrepMatches(self: *App) void {
        for (self.grep_matches.items) |match| self.allocator.free(match.path);
        self.grep_matches.clearRetainingCapacity();
    }

    pub fn clearReadContinuations(self: *App) void {
        for (self.read_continuations.items) |continuation| self.allocator.free(continuation.path);
        self.read_continuations.clearRetainingCapacity();
    }

    pub fn addLine(self: *App, comptime fmt: []const u8, args: anytype) !void {
        try self.lines.append(self.allocator, try std.fmt.allocPrint(self.allocator, fmt, args));
    }

    pub fn removeLineAt(self: *App, index: usize) void {
        if (index >= self.lines.items.len) return;
        const removed = self.lines.orderedRemove(index);
        self.allocator.free(removed);
    }

    // Content block addition methods

    pub fn addUserBlock(self: *App, text: []const u8) !void {
        // Add initial spacing so first message isn't flush against top
        if (self.lines.items.len == 0) {
            try self.addLine("", .{});
        }
        try self.addLine(user_marker, .{});
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            const safe_line = try utils.sanitizeAlloc(self.allocator, line);
            defer self.allocator.free(safe_line);
            try self.addLine(user_marker ++ "{s}", .{safe_line});
        }
        try self.addLine(user_marker, .{});
    }

    pub fn addAssistantBlock(self: *App, text: []const u8) !void {
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
                            const safe = try utils.sanitizeAlloc(self.allocator, l);
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
                const safe_line = try utils.sanitizeAlloc(self.allocator, line);
                defer self.allocator.free(safe_line);
                const styled_line = try utils.styleMarkdownLine(self.allocator, safe_line);
                defer self.allocator.free(styled_line);
                try self.addLine("{s}", .{styled_line});
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
                    const safe = try utils.sanitizeAlloc(self.allocator, l);
                    defer self.allocator.free(safe);
                    try self.addLine("{s}", .{safe});
                }
            }
        }
    }

    pub fn addThinkingBlock(self: *App, text: []const u8) !void {
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

            const safe_line = try utils.sanitizeAlloc(self.allocator, line);
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
            const safe_line = try utils.sanitizeAlloc(self.allocator, line);
            defer self.allocator.free(safe_line);
            try self.addLine(thinking_marker ++ "{s}", .{safe_line});
        }
    }

    pub fn addToolResultDetails(self: *App, path: []const u8, result: []const u8) !void {
        _ = path;

        // Spacer before diff box
        try self.addLine("", .{});
        try self.addLine(diff_box_marker, .{});

        var it = std.mem.splitScalar(u8, result, '\n');
        var first_line = true;
        var status_shown = false;
        while (it.next()) |line| {
            // Show the first status line with an arrow icon inside the diff box
            if (first_line) {
                first_line = false;
                if (std.mem.startsWith(u8, line, "Edited ") or
                    std.mem.startsWith(u8, line, "Updated ") or
                    std.mem.startsWith(u8, line, "Created ")) {
                    // Show status with left arrow icon, change "Edited" to "Edit"
                    var action: []const u8 = "Create";
                    var rest_start: usize = 8;
                    if (std.mem.startsWith(u8, line, "Edited ")) {
                        action = "Edit";
                        rest_start = 6;
                    } else if (std.mem.startsWith(u8, line, "Updated ")) {
                        action = "Update";
                        rest_start = 8;
                    }
                    const rest = if (line.len > rest_start) line[rest_start..] else "";
                    try self.addLine(diff_box_marker ++ "{s}← {s}{s}{s}", .{ theme.mocha.subtext0, action, rest, theme.reset });
                    status_shown = true;
                    continue;
                }
            }
            
            // Skip empty lines
            if (line.len == 0) continue;
            
            // Add separator line after status before first diff content
            if (status_shown) {
                try self.addLine(diff_box_marker, .{});
                status_shown = false;
            }
            
            // Diff output already contains ANSI color codes - don't sanitize them
            // Just ensure no harmful control characters
            const safe_line = try utils.sanitizeAnsiAlloc(self.allocator, line);
            defer self.allocator.free(safe_line);
            try self.addLine(diff_box_marker ++ "{s}", .{safe_line});
        }
        try self.addLine(diff_box_marker, .{});
    }

    pub fn addShellResultDetails(self: *App, args: std.json.Value, result: []const u8, failed: bool) !void {
        const command = if (args == .object) blk: {
            const value = args.object.get("command") orelse break :blk "unknown";
            break :blk if (value == .string) value.string else "unknown";
        } else "unknown";
        const safe_command = try utils.sanitizeAlloc(self.allocator, command);
        defer self.allocator.free(safe_command);

        // Spacer before terminal output box
        try self.addLine("", .{});
        try self.addLine(diff_box_marker, .{});
        try self.addLine(diff_box_marker ++ "{s}$ {s}", .{ theme.mocha.blue, safe_command });
        try self.addLine(diff_box_marker, .{});

        if (result.len == 0) {
            try self.addLine(diff_box_marker ++ "{s}(no output)", .{theme.mocha.subtext0});
        } else {
            var it = std.mem.splitScalar(u8, result, '\n');
            while (it.next()) |line| {
                const safe_line = try utils.sanitizeAnsiAlloc(self.allocator, line);
                defer self.allocator.free(safe_line);
                if (failed) {
                    try self.addLine(diff_box_marker ++ "{s}{s}", .{ theme.mocha.red, safe_line });
                } else {
                    try self.addLine(diff_box_marker ++ "{s}", .{safe_line});
                }
            }
        }
        try self.addLine(diff_box_marker, .{});
    }

    pub fn addToolError(self: *App, result: []const u8) !void {
        var it = std.mem.splitScalar(u8, result, '\n');
        while (it.next()) |line| {
            const safe_line = try utils.sanitizeAlloc(self.allocator, line);
            defer self.allocator.free(safe_line);
            try self.addLine("  {s}{s}{s}", .{ theme.mocha.red, safe_line, theme.reset });
        }
    }

    pub fn addShellOutputBlock(self: *App, content: []const u8) !void {
        // Split content into lines and add them
        var it = std.mem.splitScalar(u8, content, '\n');
        var first = true;
        while (it.next()) |line| {
            if (first) {
                first = false;
            }
            // Use a marker to identify shell output lines
            const marked_line = try std.fmt.allocPrint(self.allocator, "\x1fS{s}", .{line});
            try self.lines.append(self.allocator, marked_line);
        }
    }

    // Tool formatting methods

    pub fn formatToolDisplay(self: *App, tool_name: []const u8, args: std.json.Value) ![]u8 {
        // Extract the main argument based on tool type
        var arg: ?[]const u8 = null;
        if (args == .object) {
            if (std.mem.eql(u8, tool_name, "read_file") or
                std.mem.eql(u8, tool_name, "write_file") or
                std.mem.eql(u8, tool_name, "list_files") or
                std.mem.eql(u8, tool_name, "edit"))
            {
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
            const safe_arg = try utils.sanitizeAlloc(self.allocator, a);
            defer self.allocator.free(safe_arg);
            // Truncate long arguments
            const display_arg = if (safe_arg.len > 50) safe_arg[0..50] else safe_arg;
            if (std.mem.eql(u8, tool_name, "edit")) {
                return std.fmt.allocPrint(self.allocator, "→ Prepare editing {s} ...", .{display_arg});
            }
            if (std.mem.eql(u8, tool_name, "write_file")) {
                return std.fmt.allocPrint(self.allocator, "→ Prepare writing {s} ... [confirm y/N if overwriting]", .{display_arg});
            }
            if (std.mem.eql(u8, tool_name, "run_shell")) {
                return std.fmt.allocPrint(self.allocator, "{s} {s} {s} ... [confirm y/N]", .{ utils.toolMarker(tool_name), utils.toolVerb(tool_name), display_arg });
            }
            return std.fmt.allocPrint(self.allocator, "{s} {s} {s} ...", .{ utils.toolMarker(tool_name), utils.toolVerb(tool_name), display_arg });
        } else {
            return std.fmt.allocPrint(self.allocator, "{s} {s} ...", .{ utils.toolMarker(tool_name), utils.toolVerb(tool_name) });
        }
    }

    pub fn formatToolResultSummary(self: *App, tool_name: []const u8, args: std.json.Value, result: []const u8) ![]u8 {
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
            if (std.mem.startsWith(u8, result, "Error:")) {
                return std.fmt.allocPrint(self.allocator, "→ Write {s} [failed]", .{path});
            }
            if (std.mem.indexOf(u8, result, "cancelled") != null) {
                return std.fmt.allocPrint(self.allocator, "→ Write {s} [cancelled]", .{path});
            }
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
            if (std.mem.startsWith(u8, result, "Error")) {
                return std.fmt.allocPrint(self.allocator, "* Grep \"{s}\" [failed]", .{display_pattern});
            }
            // Count matches from "Found X matches" in result
            var match_count: usize = 0;
            if (std.mem.startsWith(u8, result, "Found ")) {
                var i: usize = 6;
                while (i < result.len and result[i] >= '0' and result[i] <= '9') : (i += 1) {
                    match_count = match_count * 10 + (result[i] - '0');
                }
            }
            if (match_count == 0) {
                var files_searched: usize = 0;
                if (std.mem.indexOf(u8, result, " in ")) |match_start| {
                    var i = match_start + 4;
                    while (i < result.len and result[i] >= '0' and result[i] <= '9') : (i += 1) {
                        files_searched = files_searched * 10 + (result[i] - '0');
                    }
                }
                if (files_searched > 0) {
                    return std.fmt.allocPrint(self.allocator, "* Grep \"{s}\" [no matches, {d} files]", .{ display_pattern, files_searched });
                }
                return std.fmt.allocPrint(self.allocator, "* Grep \"{s}\" [no matches]", .{display_pattern});
            } else {
                return std.fmt.allocPrint(self.allocator, "* Grep \"{s}\" [{d} matches]", .{ display_pattern, match_count });
            }
        } else if (std.mem.eql(u8, tool_name, "edit")) {
            const path = main_arg orelse "unknown";
            if (std.mem.startsWith(u8, result, "Error:")) {
                return std.fmt.allocPrint(self.allocator, "→ Edit {s} [failed]", .{path});
            }
            return std.fmt.allocPrint(self.allocator, "→ Edit {s}", .{path});
        } else {
            return std.fmt.allocPrint(self.allocator, "→ {s} [done]", .{tool_name});
        }
    }

    // Read operation tracking

    pub fn repeatedReadError(self: *App, request: tools.ToolRequest) !?[]u8 {
        if (!std.mem.eql(u8, request.tool, "read_file")) return null;
        if (request.args != .object) return null;

        const path_value = request.args.object.get("path") orelse return null;
        if (path_value != .string) return null;
        const path = path_value.string;

        const offset = utils.readUsizeArg(request.args, "offset") orelse 1;
        const line_limit = @min(utils.readUsizeArg(request.args, "limit") orelse tools.max_read_lines, tools.max_read_lines);

        if (!self.isReadContinuation(path, offset)) {
            if (self.truncatedGrepOffset(path, offset)) |full_offset| {
                return try std.fmt.allocPrint(
                    self.allocator,
                    "Error: read_file offset={d} looks like a shortened/truncated form of the recent grep match at {s}:{d}. Call read_file with the exact full offset={d}; do not drop leading digits, shorten, or round grep line numbers.",
                    .{ offset, path, full_offset, full_offset },
                );
            }
        }

        const key = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ path, offset });
        errdefer self.allocator.free(key);
        for (self.read_requests.items) |seen| {
            if (std.mem.eql(u8, seen, key)) {
                self.allocator.free(key);
                return try std.fmt.allocPrint(
                    self.allocator,
                    "Error: Already read {s} at offset={d} in this turn. If grep showed a line like 1680, use offset=1680 EXACTLY; do not shorten it to 168/160/180. Otherwise continue after this range with offset={d}.",
                    .{ path, offset, offset + line_limit },
                );
            }
        }
        try self.read_requests.append(self.allocator, key);
        try self.recordReadContinuation(path, offset + line_limit);
        return null;
    }

    pub fn recordGrepResults(self: *App, request: tools.ToolRequest, result: []const u8) !void {
        if (!std.mem.eql(u8, request.tool, "grep")) return;
        if (std.mem.startsWith(u8, result, "Error:") or std.mem.startsWith(u8, result, "Tool error:")) return;

        var current_path: ?[]const u8 = null;
        var it = std.mem.splitScalar(u8, result, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "File: ")) {
                current_path = line[6..];
            } else if (std.mem.startsWith(u8, line, "Line: ")) {
                const path = current_path orelse continue;
                const line_num = std.fmt.parseUnsigned(usize, std.mem.trim(u8, line[6..], " \t\r"), 10) catch continue;
                const match_path = try self.allocator.dupe(u8, path);
                errdefer self.allocator.free(match_path);
                try self.grep_matches.append(self.allocator, .{ .path = match_path, .line = line_num });
            }
        }
    }

    pub fn truncatedGrepOffset(self: *App, path: []const u8, offset: usize) ?usize {
        if (offset < 10) return null;
        for (self.grep_matches.items) |match| {
            if (!utils.sameToolPath(match.path, path)) continue;
            if (offset >= match.line or offset == match.line) continue;
            if (utils.isShortenedOffset(offset, match.line)) return match.line;
        }
        return null;
    }

    pub fn isReadContinuation(self: *App, path: []const u8, offset: usize) bool {
        for (self.read_continuations.items) |continuation| {
            if (continuation.offset == offset and utils.sameToolPath(continuation.path, path)) return true;
        }
        return false;
    }

    pub fn recordReadContinuation(self: *App, path: []const u8, offset: usize) !void {
        if (self.isReadContinuation(path, offset)) return;
        const continuation_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(continuation_path);
        try self.read_continuations.append(self.allocator, .{ .path = continuation_path, .offset = offset });
    }

    // Callback functions (need to be public for external access)

    pub fn shouldCancelCallback(self: *App) !bool {
        try self.processPendingInputWhileBusy();
        if (self.is_busy) try self.render();
        return self.cancel_requested;
    }

    pub fn processPendingInputWhileBusy(self: *App) !void {
        var needs_render = false;

        while (true) {
            const next = try self.readPendingByte();
            if (next == null) break;
            const ch = next.?;

            switch (ch) {
                3 => { // Ctrl+C
                    self.cancel_requested = true;
                    needs_render = true;
                },
                21 => { // Ctrl+U - scroll up (half page)
                    self.scrollUp(self.getContentRows() / 2);
                    needs_render = true;
                },
                4 => { // Ctrl+D - scroll down (half page)
                    self.scrollDown(self.getContentRows() / 2);
                    needs_render = true;
                },
                '\r', '\n' => {
                    // No-op while busy: keep editing, do not submit.
                },
                1 => { // Ctrl+A
                    self.cursor_pos = 0;
                    needs_render = true;
                },
                5 => { // Ctrl+E
                    self.cursor_pos = self.input.items.len;
                    needs_render = true;
                },
                127, 8 => {
                    if (self.cursor_pos > 0 and self.input.items.len > 0) {
                        _ = self.input.orderedRemove(self.cursor_pos - 1);
                        self.cursor_pos -= 1;
                        needs_render = true;
                    }
                },
                27 => {
                    if (try input_mod.handleBusyEscapeSequence(self)) needs_render = true;
                },
                else => {
                    if (ch >= 32 and ch != 127 and self.input.items.len < utils.max_input) {
                        try self.input.insert(self.allocator, self.cursor_pos, ch);
                        self.cursor_pos += 1;
                        needs_render = true;
                    }
                },
            }
        }

        if (needs_render) try self.render();
    }

    fn followStreamingIfAtBottom(self: *App, previous_max_scroll: usize) void {
        if (self.scroll_offset >= previous_max_scroll) {
            self.scroll_offset = self.getMaxScroll();
        }
    }

    pub fn readPendingByte(self: *App) !?u8 {
        _ = self;
        var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, 0) catch 0;
        if (ready <= 0 or (fds[0].revents & std.posix.POLL.IN) == 0) return null;

        var byte: [1]u8 = undefined;
        const n = std.posix.read(std.posix.STDIN_FILENO, &byte) catch return null;
        if (n == 0) return null;
        return byte[0];
    }

    /// Prune context to keep only last 4 full turns + tool results from older messages.
    /// Removes thinking and truncates assistant content from older turns to save tokens.
    pub fn pruneContext(self: *App) void {
        if (self.messages.items.len <= 1) return; // Just system message, nothing to prune

        // Find the cutoff point: start of messages to keep fully intact (last 4 assistant turns)
        var assistant_count: usize = 0;
        var cutoff_idx: usize = self.messages.items.len;

        var i: usize = self.messages.items.len;
        while (i > 0) : (i -= 1) {
            if (self.messages.items[i - 1].role == .assistant) {
                assistant_count += 1;
                if (assistant_count == utils.max_full_turns) {
                    cutoff_idx = i - 1;
                    break;
                }
            }
        }

        // If we have more than cutoff, prune older messages
        if (cutoff_idx <= 1) return; // Nothing older to prune (keep system at 0)

        // Process messages between system (index 0) and cutoff
        for (self.messages.items[1..cutoff_idx]) |*msg| {
            switch (msg.role) {
                .assistant => {
                    // Remove thinking completely from older turns
                    if (msg.thinking) |t| {
                        self.allocator.free(t);
                        msg.thinking = null;
                    }
                    // Truncate content if no tool calls
                    if (msg.tool_calls == null or msg.tool_calls.?.len == 0) {
                        if (msg.content.len > 0) {
                            self.allocator.free(msg.content);
                            msg.content = self.allocator.dupe(u8, "[Earlier response]") catch msg.content;
                        }
                    }
                },
                .user => {
                    // Keep user messages but truncate if very long
                    if (msg.content.len > 1000) {
                        const truncated = std.fmt.allocPrint(self.allocator, "{s}... [truncated]", .{msg.content[0..500]}) catch continue;
                        self.allocator.free(msg.content);
                        msg.content = truncated;
                    }
                },
                .tool => {
                    // KEEP tool results intact - contain file contents
                    // But free tool_call_id to save memory
                    if (msg.tool_call_id) |id| {
                        self.allocator.free(id);
                        msg.tool_call_id = null;
                    }
                },
                .system => {},
            }
        }
    }

    // Streaming callbacks

    pub fn streamingCallback(self: *App, chunk: ollama.StreamChunk) !void {
        // Check if cancel was requested
        if (self.cancel_requested) {
            return error.Cancelled;
        }

        if (chunk.content_delta.len > 0) {
            const delta = chunk.content_delta;

            // Deduplication: check if this is truly new content
            // Some models send full content instead of deltas
            const existing = self.stream_content.items;
            const new_content = delta;
            if (existing.len == 0) {
                // First chunk - append all
                try self.stream_content.appendSlice(self.allocator, new_content);
            } else if (new_content.len > existing.len and std.mem.startsWith(u8, new_content, existing)) {
                // New content is existing + suffix - only append the suffix
                const suffix = new_content[existing.len..];
                try self.stream_content.appendSlice(self.allocator, suffix);
            } else if (!std.mem.eql(u8, existing[existing.len - @min(existing.len, new_content.len) ..], new_content)) {
                // Truly new content that doesn't overlap with existing - append it
                try self.stream_content.appendSlice(self.allocator, new_content);
            }
            // If content matches end of existing, it's a duplicate - skip it
        }

        if (chunk.thinking_delta) |td| {
            self.thinking_started = true;
            try self.stream_thinking.appendSlice(self.allocator, td);
            // Track thinking as a round (only on first thinking chunk to avoid overcounting)
            if (self.stream_thinking.items.len == td.len) {
                self.tracker.recordThinking(td);
            }
        }

        if (chunk.tool_calls) |calls| {
            var owned_calls: ?[]ollama.ToolCall = calls;
            errdefer if (owned_calls) |pending_calls| ollama.freeToolCalls(self.allocator, pending_calls);
            try self.stream_tool_calls.appendSlice(self.allocator, calls);
            owned_calls = null;
            self.allocator.free(calls);
        }

        if (chunk.content_delta.len > 0 or (chunk.thinking_delta != null and chunk.thinking_delta.?.len > 0) or chunk.tool_calls != null) {
            const previous_max_scroll = self.getMaxScroll();
            try self.refreshStreamingLines();
            self.followStreamingIfAtBottom(previous_max_scroll);
            try self.render();
        }
    }

    pub fn refreshStreamingLines(self: *App) !void {
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
            } else if (utils.containsToolAttempt(self.stream_content.items)) {
                if (utils.textBeforeToolJson(self.stream_content.items)) |text_before_tool| {
                    if (std.mem.trim(u8, text_before_tool, " \t\r\n").len > 0) {
                        if (self.stream_thinking.items.len > 0) {
                            try self.addLine("", .{});
                        }
                        try self.addAssistantBlock(std.mem.trim(u8, text_before_tool, " \t\r\n"));
                    }
                }
            } else {
                // No tool JSON in content - display as normal text
                if (self.stream_thinking.items.len > 0) {
                    try self.addLine("", .{});
                }
                try self.addAssistantBlock(self.stream_content.items);
            }
        }
    }

    // Handle confirmation dialog - returns true to confirm, false to cancel
    // This is called via callback from the tools module
    pub fn handleConfirm(self: *App, prompt: []const u8) anyerror!bool {
        _ = self;
        _ = prompt;

        // Simple approach: always confirm for now to avoid stdin conflicts
        // The proper fix requires restructuring to handle confirmation in the main loop
        return true;
    }

    // Handle shell streaming output
    // This is called via callback from the tools module
    pub fn handleShellStream(self: *App, output: []const u8, is_stderr: bool) void {
        _ = is_stderr;

        // Append to streaming content
        self.shell_stream_content.appendSlice(self.allocator, output) catch return;

        // Update the display
        const previous_max_scroll = self.getMaxScroll();
        self.refreshShellStreamingLines() catch return;
        self.followStreamingIfAtBottom(previous_max_scroll);
        self.render() catch return;
    }

    pub fn refreshShellStreamingLines(self: *App) !void {
        // Clear previous streaming lines
        while (self.lines.items.len > self.shell_stream_lines_start) {
            const removed = self.lines.pop().?;
            self.allocator.free(removed);
        }

        // Display shell output
        if (self.shell_stream_content.items.len > 0) {
            try self.addShellOutputBlock(self.shell_stream_content.items);
        }
    }

    // Complete turn logic (conversation loop)

    pub fn completeTurn(self: *App, initial_stream_start: usize) !void {
        var stream_start = initial_stream_start;
        var thinking_only_retries: usize = 0;
        var post_tool_empty_retry_used = false;
        var had_tool_result = false;
        self.clearReadRequests();
        self.clearGrepMatches();
        self.clearReadContinuations();

        // Add spacing between user message and response
        try self.addLine("", .{});
        stream_start = self.lines.items.len;

        while (true) {
            self.stream_content.clearRetainingCapacity();
            self.stream_thinking.clearRetainingCapacity();
            self.clearStreamToolCalls();
            self.thinking_started = false;
            self.cancel_requested = false;
            self.stream_lines_start = stream_start;

            ollama.chatStream(self.allocator, self.cfg, self.messages.items, self, streamingCallbackWrapper, shouldCancelCallbackWrapper) catch |err| {
                if (err == error.Cancelled) {
                    // Add partial response if any content was received
                    if (self.stream_content.items.len > 0 or self.stream_thinking.items.len > 0 or self.stream_tool_calls.items.len > 0) {
                        const partial_content = try self.allocator.dupe(u8, self.stream_content.items);
                        const partial_thinking = if (self.stream_thinking.items.len > 0)
                            try self.allocator.dupe(u8, self.stream_thinking.items)
                        else
                            null;
                        const partial_tool_calls = if (self.stream_tool_calls.items.len > 0)
                            try ollama.cloneToolCalls(self.allocator, self.stream_tool_calls.items)
                        else
                            null;
                        try self.messages.append(self.allocator, .{ .role = .assistant, .content = partial_content, .thinking = partial_thinking, .tool_calls = partial_tool_calls });
                        try self.addAssistantBlock(partial_content);
                        try self.addLine("", .{});
                        try self.addLine("(response cancelled)", .{});
                    } else {
                        try self.addLine("(cancelled)", .{});
                    }
                    return;
                }

                tools.logStreamFailure(
                    self.allocator,
                    @errorName(err),
                    self.cfg.model,
                    self.cfg.base_url,
                    had_tool_result,
                    self.stream_content.items.len,
                    self.stream_thinking.items.len,
                    self.stream_tool_calls.items.len,
                );

                if (had_tool_result and !post_tool_empty_retry_used) {
                    post_tool_empty_retry_used = true;
                    const recovery = try std.fmt.allocPrint(self.allocator, "Tool result received, but stream failed ({s}). Continue the task from the latest tool result. If you need another tool, output only valid tool JSON.", .{@errorName(err)});
                    try self.messages.append(self.allocator, .{ .role = .user, .content = recovery });
                    stream_start = self.lines.items.len;
                    continue;
                }

                try self.addLine("(stream error: {s})", .{@errorName(err)});
                return;
            };

            self.cancel_requested = false;

            if (self.stream_content.items.len == 0 and self.stream_thinking.items.len == 0 and self.stream_tool_calls.items.len == 0) {
                if (had_tool_result and !post_tool_empty_retry_used) {
                    post_tool_empty_retry_used = true;
                    const recovery = try self.allocator.dupe(u8, "Tool result received. Continue the task. If no matches were found, broaden the search and proceed.");
                    try self.messages.append(self.allocator, .{ .role = .user, .content = recovery });
                    stream_start = self.lines.items.len;
                    continue;
                }
                try self.addLine("(no response)", .{});
                return;
            }

            if (self.stream_content.items.len == 0 and self.stream_thinking.items.len > 0 and self.stream_tool_calls.items.len == 0) {
                if (thinking_only_retries >= 2) {
                    try self.addLine("(no response)", .{});
                    return;
                }
                thinking_only_retries += 1;

                const thinking_only_content = try self.allocator.dupe(u8, "");
                const thinking_only_thinking = try self.allocator.dupe(u8, self.stream_thinking.items);
                try self.messages.append(self.allocator, .{ .role = .assistant, .content = thinking_only_content, .thinking = thinking_only_thinking });

                const continue_message = try self.allocator.dupe(u8, "Continue. If you need a tool, output only the tool JSON. Otherwise answer normally.");
                try self.messages.append(self.allocator, .{ .role = .user, .content = continue_message });
                stream_start = self.lines.items.len;
                continue;
            }

            const final_content = try self.allocator.dupe(u8, self.stream_content.items);
            const final_thinking = if (self.stream_thinking.items.len > 0)
                try self.allocator.dupe(u8, self.stream_thinking.items)
            else
                null;

            const final_tool_calls = if (self.stream_tool_calls.items.len > 0)
                try ollama.cloneToolCalls(self.allocator, self.stream_tool_calls.items)
            else
                null;

            try self.messages.append(self.allocator, .{ .role = .assistant, .content = final_content, .thinking = final_thinking, .tool_calls = final_tool_calls });

            if (self.stream_tool_calls.items.len > 0) {
                for (self.stream_tool_calls.items) |call| {
                    const request = tools.requestFromToolCall(call);
                    const safe_tool = try utils.sanitizeAlloc(self.allocator, request.tool);
                    defer self.allocator.free(safe_tool);

                    const pending_summary = try self.formatToolDisplay(safe_tool, request.args);
                    defer self.allocator.free(pending_summary);
                    try self.addLine("", .{});
                    try self.addLine("{s}", .{pending_summary});
                    try self.render();

                    var tool_failed = false;

                    // Use streaming for shell commands, regular execution for others
                    const result = if (try self.repeatedReadError(request)) |read_error| blk: {
                        tool_failed = true;
                        break :blk read_error;
                    } else if (try self.generateContextSummaryIfNeeded()) |summary| blk: {
                        break :blk summary;
                    } else if (std.mem.eql(u8, safe_tool, "run_shell")) blk: {
                        // Set up shell streaming
                        self.is_shell_streaming = true;
                        self.shell_stream_lines_start = self.lines.items.len;
                        self.shell_stream_content.clearRetainingCapacity();

                        const stream_result = tools.executeWithStreaming(self.allocator, request, .{
                            .ctx = self,
                            .callback = confirmCallbackWrapper,
                        }, self.highlighter, .{
                            .ctx = self,
                            .callback = shellStreamCallbackWrapper,
                        }) catch |err| {
                            tool_failed = true;
                            break :blk try std.fmt.allocPrint(self.allocator, "Tool error: {s}", .{@errorName(err)});
                        };

                        self.is_shell_streaming = false;
                        break :blk stream_result;
                    } else blk: {
                        break :blk tools.executeWithConfirm(self.allocator, request, .{
                            .ctx = self,
                            .callback = confirmCallbackWrapper,
                        }, self.highlighter) catch |err| {
                            tool_failed = true;
                            break :blk try std.fmt.allocPrint(self.allocator, "Tool error: {s}", .{@errorName(err)});
                        };
                    };
                    defer self.allocator.free(result);
                    tools.logToolCall(self.allocator, request, result);
                    try self.recordGrepResults(request, result);
                    try self.tracker.recordToolExecution(safe_tool, request.args, result);
                    if (std.mem.startsWith(u8, result, "Error:") or std.mem.startsWith(u8, result, "Tool error:")) {
                        tool_failed = true;
                    }

                    const summary = try self.formatToolResultSummary(safe_tool, request.args, result);
                    defer self.allocator.free(summary);
                    self.removeLineAt(self.lines.items.len - 1);
                    try self.addLine("{s}", .{summary});
                    if (std.mem.eql(u8, safe_tool, "run_shell")) {
                        try self.addShellResultDetails(request.args, result, tool_failed);
                    } else if (tool_failed) try self.addToolError(result);
                    if (std.mem.eql(u8, safe_tool, "edit") or std.mem.eql(u8, safe_tool, "write_file")) {
                        const path = if (request.args == .object) blk: {
                            const p = request.args.object.get("path") orelse break :blk "unknown";
                            break :blk if (p == .string) p.string else "unknown";
                        } else "unknown";
                        try self.addToolResultDetails(path, result);
                    }
                    try self.addLine("", .{});

                    const tool_message = try std.fmt.allocPrint(self.allocator, "Result from tool `{s}`. Use this result to continue; do not repeat the same tool call unless you need a different offset, limit, path, or pattern.\n{s}", .{ request.tool, result });
                    errdefer self.allocator.free(tool_message);
                    try self.messages.append(self.allocator, .{
                        .role = .tool,
                        .content = tool_message,
                        .tool_name = try self.allocator.dupe(u8, request.tool),
                        .tool_call_id = if (call.id) |id| try self.allocator.dupe(u8, id) else null,
                    });
                    had_tool_result = true;
                    try self.render();
                }
                stream_start = self.lines.items.len;
                continue;
            }

            // Check for tool request - handle case where there's text before the JSON
            var maybe_tool: ?std.json.Parsed(tools.ToolRequest) = null;
            var extracted_json: ?[]u8 = null;
            defer if (extracted_json) |json| self.allocator.free(json);

            // Try to parse as-is first
            if (try tools.parseToolRequest(self.allocator, final_content)) |parsed| {
                maybe_tool = parsed;
            } else if (utils.containsToolJson(final_content)) {
                // Extract just the JSON part
                if (utils.extractToolJson(self.allocator, final_content)) |json_part| {
                    extracted_json = json_part;
                    if (try tools.parseToolRequest(self.allocator, json_part)) |parsed| {
                        maybe_tool = parsed;
                    }
                }
            }

            if (maybe_tool) |*parsed| {
                defer parsed.deinit();
                if (utils.textBeforeToolJson(final_content)) |text_before_tool| {
                    if (std.mem.trim(u8, text_before_tool, " \t\r\n").len > 0) {
                        try self.addAssistantBlock(std.mem.trim(u8, text_before_tool, " \t\r\n"));
                    }
                }
                const safe_tool = try utils.sanitizeAlloc(self.allocator, parsed.value.tool);
                defer self.allocator.free(safe_tool);

                const pending_summary = try self.formatToolDisplay(safe_tool, parsed.value.args);
                defer self.allocator.free(pending_summary);
                try self.addLine("", .{});
                try self.addLine("{s}", .{pending_summary});
                try self.render();

                var tool_failed = false;
                const result = if (try self.repeatedReadError(parsed.value)) |read_error| blk: {
                    tool_failed = true;
                    break :blk read_error;
                } else if (try self.generateContextSummaryIfNeeded()) |summary| blk: {
                    break :blk summary;
                } else tools.executeWithConfirm(self.allocator, parsed.value, .{
                    .ctx = self,
                    .callback = confirmCallbackWrapper,
                }, self.highlighter) catch |err| blk: {
                    tool_failed = true;
                    break :blk try std.fmt.allocPrint(self.allocator, "Tool error: {s}", .{@errorName(err)});
                };
                defer self.allocator.free(result);
                tools.logToolCall(self.allocator, parsed.value, result);
                try self.recordGrepResults(parsed.value, result);
                try self.tracker.recordToolExecution(safe_tool, parsed.value.args, result);
                if (std.mem.startsWith(u8, result, "Error:") or std.mem.startsWith(u8, result, "Tool error:")) {
                    tool_failed = true;
                }

                // Show concise summary in UI
                const summary = try self.formatToolResultSummary(safe_tool, parsed.value.args, result);
                defer self.allocator.free(summary);
                self.removeLineAt(self.lines.items.len - 1);
                try self.addLine("{s}", .{summary});
                if (std.mem.eql(u8, safe_tool, "run_shell")) {
                    try self.addShellResultDetails(parsed.value.args, result, tool_failed);
                } else if (tool_failed) {
                    try self.addToolError(result);
                }
                if (std.mem.eql(u8, safe_tool, "edit") or std.mem.eql(u8, safe_tool, "write_file")) {
                    const path = if (parsed.value.args == .object) blk: {
                        const p = parsed.value.args.object.get("path") orelse break :blk "unknown";
                        break :blk if (p == .string) p.string else "unknown";
                    } else "unknown";
                    try self.addToolResultDetails(path, result);
                }
                try self.addLine("", .{});

                // Send full result to agent
                const tool_message = try std.fmt.allocPrint(self.allocator, "Result from tool `{s}`. Use this result to continue; do not repeat the same tool call unless you need a different offset, limit, path, or pattern.\n{s}", .{ parsed.value.tool, result });
                try self.messages.append(self.allocator, .{ .role = .user, .content = tool_message });
                had_tool_result = true;
                try self.render();
                // Update stream_start so next iteration doesn't clear previous content
                stream_start = self.lines.items.len;
                continue;
            }

            if (utils.containsToolAttempt(final_content)) {
                const error_message = "Error: Invalid tool JSON. Expected {\"tool\":\"TOOL_NAME\",\"args\":{...}}";
                tools.logInvalidToolJson(self.allocator, final_content, error_message);
                try self.addLine("", .{});
                try self.addToolError(error_message);
                try self.addLine("", .{});
                const retry_message = try self.allocator.dupe(u8, error_message);
                try self.messages.append(self.allocator, .{ .role = .user, .content = retry_message });
                try self.render();
                stream_start = self.lines.items.len;
                continue;
            }

            // Prune context to keep last 4 full turns + tool results from older turns
            self.pruneContext();

            return;
        }
    }

    /// Generate context summary if enough rounds have passed.
    /// Returns the summary message if generated, null otherwise.
    fn generateContextSummaryIfNeeded(self: *App) !?[]u8 {
        if (!self.tracker.shouldGenerateSummary()) {
            return null;
        }

        const summary = try self.tracker.generateSummary();
        errdefer self.allocator.free(summary);

        // Add to UI
        try self.addLine("", .{});
        try self.addLine("{s}", .{summary});
        try self.addLine("", .{});

        return summary;
    }
};

// Callback functions passed to ollama.chatStream - these need the correct type signature
// where the first parameter matches the ctx type (*App)

pub fn streamingCallbackWrapper(ctx: *App, chunk: ollama.StreamChunk) !void {
    return ctx.streamingCallback(chunk);
}

pub fn shouldCancelCallbackWrapper(ctx: *App) !bool {
    return ctx.shouldCancelCallback();
}

// Tool callbacks - these are the functions passed to tools.executeWithConfirm and tools.executeWithStreaming

pub fn confirmCallbackWrapper(ctx: *anyopaque, prompt: []const u8) anyerror!bool {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.handleConfirm(prompt);
}

pub fn shellStreamCallbackWrapper(ctx: *anyopaque, output: []const u8, is_stderr: bool) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.handleShellStream(output, is_stderr);
}
