const std = @import("std");
const theme = @import("../theme.zig");
const terminal = @import("../terminal.zig");
const app_mod = @import("app.zig");
const utils = @import("utils.zig");
const components = @import("components.zig");

const App = app_mod.App;
const thinking_marker = utils.thinking_marker;
const user_marker = utils.user_marker;
const diff_box_marker = utils.diff_box_marker;
const shell_output_marker = utils.shell_output_marker;
const hidden_marker = utils.hidden_marker;
const toggle_marker = utils.toggle_marker;

/// Render the welcome screen
pub fn renderWelcome(self: *App) !void {
    var stdout_buf: [16384]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &stdout_buf);
    const stdout = &stdout_file.interface;
    defer stdout.flush() catch {};

    const size = terminal.size();
    if (size.rows < 20 or size.cols < 80) {
        try stdout.writeAll("\x1b[H\x1b[2J");
        try stdout.print("{s}{s}Terminal too small (need 20x80){s}\x1b[1;1H\x1b[?25h", .{ theme.mocha.mantle_bg, theme.mocha.text, theme.reset });
        return;
    }

    const rows = size.rows;
    const cols = size.cols;

    try stdout.print("\x1b[?25l{s}\x1b[H", .{theme.mocha.mantle_bg});

    // Split banner into lines
    var banner_lines = std.ArrayList([]const u8).empty;
    defer banner_lines.deinit(self.allocator);

    const minicode_banner = ""; // Empty banner
    var banner_it = std.mem.splitScalar(u8, minicode_banner, '\n');
    while (banner_it.next()) |line| {
        try banner_lines.append(self.allocator, line);
    }

    // Calculate layout
    const banner_height = banner_lines.items.len;
    const title_height = app_mod.welcome_title_lines.len;
    // Calculate input box height dynamically based on text wrapping
    const welcome_border_cols: usize = 1;
    const welcome_input_left_padding: usize = 1;
    const welcome_input_right_padding: usize = 1;
    const welcome_input_prefix_cols = welcome_border_cols + welcome_input_left_padding;
    const welcome_room_for_input: usize = if (utils.welcome_input_width > welcome_input_prefix_cols + welcome_input_right_padding)
        utils.welcome_input_width - welcome_input_prefix_cols - welcome_input_right_padding
    else
        0;
    const welcome_input_content_rows = welcomeInputRows(self, welcome_room_for_input);
    const input_box_height = 3 + welcome_input_content_rows; // content rows + spacer row + model row + bottom row
    const title_to_input_gap: usize = 3;
    const input_section_height = title_height + title_to_input_gap + input_box_height; // title + gap + input box
    const cool_stuff_height = 0;
    const gap_height = 0;
    const total_content_height = input_section_height + cool_stuff_height + gap_height + banner_height;

    // Calculate top margin to center everything (cache it for consistent redraws)
    const vertical_lift: usize = 5;
    const top_margin = if (self.welcome_top_margin) |cached| cached else blk: {
        const centered_top_margin = (rows - total_content_height) / 2;
        const calculated = if (centered_top_margin > vertical_lift)
            centered_top_margin - vertical_lift
        else
            0;
        self.welcome_top_margin = calculated;
        break :blk calculated;
    };

    // Print top margin
    var row: usize = 0;
    while (row < top_margin) : (row += 1) {
        try stdout.print("{s}\x1b[K\n", .{theme.mocha.mantle_bg});
    }

    // Calculate centered input box dimensions
    const input_width: usize = utils.welcome_input_width;
    const input_left_margin = (cols - input_width) / 2;

    // Print welcome title as one centered block (fixed left edge)
    var max_title_width: usize = 0;
    for (app_mod.welcome_title_lines) |line| {
        if (line.len > max_title_width) max_title_width = line.len;
    }
    const title_shift_right: usize = 5;
    const title_left_margin_base = if (max_title_width >= input_width)
        input_left_margin
    else
        input_left_margin + (input_width - max_title_width) / 2;
    const title_left_margin = title_left_margin_base + title_shift_right;
    for (app_mod.welcome_title_lines) |line| {
        try stdout.print("{s}", .{theme.mocha.mantle_bg});
        try stdout.splatByteAll(' ', title_left_margin);
        const display_line = if (line.len > cols) line[0..cols] else line;
        try stdout.print("{s}{s}{s}{s}\x1b[K{s}\n", .{ theme.mocha.subtext0, display_line, theme.reset, theme.mocha.mantle_bg, theme.reset });
    }
    var gap_line: usize = 0;
    while (gap_line < title_to_input_gap) : (gap_line += 1) {
        try stdout.print("{s}\x1b[K\n", .{theme.mocha.mantle_bg});
    }

    // Print input box - centered
    try printWelcomeInputArea(self, stdout, input_width, input_left_margin);

    // Gap before banner
    const remaining_rows = rows - (top_margin + input_section_height + cool_stuff_height + banner_height);
    var gap_row: usize = 0;
    while (gap_row < remaining_rows) : (gap_row += 1) {
        try stdout.print("{s}\x1b[K\n", .{theme.mocha.mantle_bg});
    }

    // Print banner at bottom
    for (banner_lines.items) |line| {
        try stdout.print("{s}", .{theme.mocha.mantle_bg});
        // Center the banner (or left-align if too wide)
        const banner_margin = if (line.len >= cols) 0 else (cols - line.len) / 2;
        try stdout.splatByteAll(' ', banner_margin);
        // Truncate line if it's too wide for terminal
        const display_line = if (line.len > cols) line[0..cols] else line;
        try stdout.print("{s}{s}{s}", .{ theme.mocha.lavender, display_line, theme.reset });
        try stdout.print("{s}\x1b[K\n", .{theme.mocha.mantle_bg});
    }

    if (self.show_model_modal) {
        try components.printModelModal(self, stdout, rows, cols);
        try stdout.writeAll("\x1b[?25l");
        return;
    }

    if (self.show_command_palette) {
        const command_palette_height: usize = 6;
        const palette_top = top_margin + app_mod.welcome_title_lines.len + title_to_input_gap + 1 - command_palette_height + 1;
        try components.printCommandPaletteAt(self, stdout, palette_top, input_left_margin + 1, input_width);
    }

    const cursor_row = if (welcome_room_for_input == 0) 0 else self.cursor_pos / welcome_room_for_input;
    const first_visible_row = firstVisibleWelcomeInputRow(self, welcome_room_for_input);
    const cursor_row_in_box = cursor_row - first_visible_row;
    const cursor_col_in_box = if (welcome_room_for_input == 0) 0 else self.cursor_pos % welcome_room_for_input;
    // Position cursor in the input box: 1-indexed row = top_margin + title + gap + cursor_row (no top border)
    const input_row = top_margin + app_mod.welcome_title_lines.len + title_to_input_gap + 1 + cursor_row_in_box;
    const cursor_col = input_left_margin + welcome_input_prefix_cols + cursor_col_in_box + 1;
    try stdout.print("\x1b[{d};{d}H\x1b[?25h", .{ input_row, cursor_col });
}

/// Calculate welcome input rows needed
fn welcomeInputRows(self: *App, room_for_input: usize) usize {
    if (room_for_input == 0) return 1;
    const rows_for_text = utils.wrappedRows(self.input.items.len, room_for_input);
    const rows_for_cursor = self.cursor_pos / room_for_input + 1;
    return @min(@max(rows_for_text, rows_for_cursor), utils.welcome_max_input_rows);
}

/// Calculate first visible row for welcome input
fn firstVisibleWelcomeInputRow(self: *App, room_for_input: usize) usize {
    if (room_for_input == 0) return 0;
    const cursor_row = self.cursor_pos / room_for_input;
    if (cursor_row >= utils.welcome_max_input_rows) return cursor_row - utils.welcome_max_input_rows + 1;
    return 0;
}

/// Print the welcome screen input area
fn printWelcomeInputArea(self: *App, stdout: anytype, input_width: usize, left_margin: usize) !void {
    const border_cols: usize = 1;
    const input_left_padding: usize = 1;
    const input_right_padding: usize = 1;
    const input_prefix_cols = border_cols + input_left_padding;
    const room_for_input: usize = if (input_width > input_prefix_cols + input_right_padding)
        input_width - input_prefix_cols - input_right_padding
    else
        0;

    const content_rows = welcomeInputRows(self, room_for_input);
    const first_visible_row = firstVisibleWelcomeInputRow(self, room_for_input);

    var input_row: usize = 0;
    while (input_row < content_rows) : (input_row += 1) {
        const absolute_input_row = first_visible_row + input_row;
        const row_start = absolute_input_row * room_for_input;
        const visible_input = if (room_for_input == 0 or row_start >= self.input.items.len)
            ""
        else blk: {
            const row_end = @min(self.input.items.len, row_start + room_for_input);
            break :blk self.input.items[row_start..row_end];
        };

        try stdout.print("{s}", .{theme.mocha.mantle_bg});
        try stdout.splatByteAll(' ', left_margin);
        try stdout.print("{s}▌{s}", .{
            theme.mocha.lavender,
            theme.mocha.surface0_bg,
        });
        if (input_left_padding > 0) try stdout.splatByteAll(' ', input_left_padding);
        try renderInputLine(stdout, visible_input);
        // Reset background to input box color before filling remaining space
        try stdout.print("{s}", .{theme.mocha.surface0_bg});
        const max_used_cols = input_width;
        const used_cols = @min(max_used_cols, input_prefix_cols + visible_input.len);
        if (used_cols < max_used_cols) try stdout.splatByteAll(' ', max_used_cols - used_cols);
        try stdout.print("{s}\x1b[K{s}\n", .{ theme.mocha.mantle_bg, theme.reset });
    }

    // Extra empty row between input content and model row
    try stdout.print("{s}", .{theme.mocha.mantle_bg});
    try stdout.splatByteAll(' ', left_margin);
    try stdout.print("{s}▌{s}", .{
        theme.mocha.lavender,
        theme.mocha.surface0_bg,
    });
    if (border_cols < input_width) try stdout.splatByteAll(' ', input_width - border_cols);
    try stdout.print("{s}\x1b[K{s}\n", .{ theme.mocha.mantle_bg, theme.reset });

    // Bottom row of input box with build info
    try stdout.print("{s}", .{theme.mocha.mantle_bg});
    try stdout.splatByteAll(' ', left_margin);
    try stdout.print("{s}▌{s} ", .{
        theme.mocha.lavender,
        theme.mocha.surface0_bg,
    });
    const model_text = self.cfg.model;
    // Available width = input_width - border(1) - space after border(1) = input_width - 2
    const max_model_len = if (input_width > 2) input_width - 2 else 0;
    const prefix_len = 8; // "Build · " length
    const available_for_model = if (max_model_len > prefix_len) max_model_len - prefix_len else 0;
    const display_model = if (model_text.len > available_for_model) model_text[0..available_for_model] else model_text;
    try stdout.print("{s}Build{s} · {s}{s}", .{ theme.mocha.lavender, theme.mocha.subtext0, display_model, theme.mocha.surface0_bg });
    const total_content_len = prefix_len + display_model.len;
    const model_padding = if (total_content_len < max_model_len) max_model_len - total_content_len else 0;
    if (model_padding > 0) try stdout.splatByteAll(' ', model_padding);
    try stdout.print("{s}\x1b[K{s}\n", .{ theme.mocha.mantle_bg, theme.reset });
    // Extra bottom row with border inside input box
    try stdout.print("{s}", .{theme.mocha.mantle_bg});
    try stdout.splatByteAll(' ', left_margin);
    try stdout.print("{s}▌{s}", .{
        theme.mocha.lavender,
        theme.mocha.surface0_bg,
    });
    if (border_cols < input_width) try stdout.splatByteAll(' ', input_width - border_cols);
    try stdout.print("{s}\x1b[K{s}\n", .{ theme.mocha.mantle_bg, theme.reset });
}

/// Render only the welcome input box (avoids flickering logo/title)
pub fn renderWelcomeInput(self: *App) !void {
    var stdout_buf: [16384]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &stdout_buf);
    const stdout = &stdout_file.interface;
    defer stdout.flush() catch {};

    const size = terminal.size();
    const rows = size.rows;
    const cols = size.cols;

    // Use cached top_margin from first render for consistent positioning
    const top_margin = self.welcome_top_margin orelse 0;
    const title_height = app_mod.welcome_title_lines.len;
    const welcome_border_cols: usize = 1;
    const welcome_input_left_padding: usize = 1;
    const welcome_input_right_padding: usize = 1;
    const welcome_input_prefix_cols = welcome_border_cols + welcome_input_left_padding;
    const welcome_room_for_input: usize = if (utils.welcome_input_width > welcome_input_prefix_cols + welcome_input_right_padding)
        utils.welcome_input_width - welcome_input_prefix_cols - welcome_input_right_padding
    else
        0;
    const welcome_input_content_rows = welcomeInputRows(self, welcome_room_for_input);
    const input_box_height = 3 + welcome_input_content_rows; // content rows + spacer row + model row + bottom row
    const title_to_input_gap: usize = 3;

    const input_width: usize = utils.welcome_input_width;
    const input_left_margin = (cols - input_width) / 2;

    // Calculate the row where the input box starts (1-indexed for ANSI cursor positioning)
    const input_box_start_row = top_margin + title_height + title_to_input_gap;

    // Clear old input box and command palette area by overwriting with spaces
    const command_palette_height: usize = 5; // title + 3 commands + help
    var clear_row: usize = 0;
    while (clear_row < input_box_height + command_palette_height) : (clear_row += 1) {
        const row = input_box_start_row + clear_row + 1; // +1 because ANSI is 1-indexed
        try stdout.print("\x1b[{d};1H{s}\x1b[K", .{ row, theme.mocha.mantle_bg });
    }

    // Move cursor to input box start and redraw
    try stdout.print("\x1b[{d};1H", .{input_box_start_row + 1});

    // Redraw input box
    try printWelcomeInputArea(self, stdout, input_width, input_left_margin);

    if (self.show_model_modal) {
        try components.printModelModal(self, stdout, rows, cols);
        try stdout.writeAll("\x1b[?25l");
        return;
    }

    if (self.show_command_palette) {
        const palette_top = input_box_start_row - command_palette_height + 1;
        try components.printCommandPaletteAt(self, stdout, palette_top, input_left_margin + 1, input_width);
    }

    // Reposition cursor
    const cursor_row = if (welcome_room_for_input == 0) 0 else self.cursor_pos / welcome_room_for_input;
    const first_visible_row = firstVisibleWelcomeInputRow(self, welcome_room_for_input);
    const cursor_row_in_box = cursor_row - first_visible_row;
    const cursor_col_in_box = if (welcome_room_for_input == 0) 0 else self.cursor_pos % welcome_room_for_input;
    const final_cursor_row = top_margin + app_mod.welcome_title_lines.len + title_to_input_gap + 1 + cursor_row_in_box;
    const cursor_col = input_left_margin + welcome_input_prefix_cols + cursor_col_in_box + 1;
    try stdout.print("\x1b[{d};{d}H\x1b[?25h", .{ final_cursor_row, cursor_col });
}

/// Render the main prompt/chat view
pub fn renderPrompt(self: *App, prompt: []const u8) !void {
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
    const right_margin: usize = 3;
    const inner_cols: usize = @max(4, @as(usize, cols) - left_margin - right_margin);
    self.inner_cols = inner_cols;
    const input_inner_cols = inner_cols;
    const prompt_room_for_input = utils.promptRoomForInput(input_inner_cols);
    const max_prompt_rows = @min(utils.prompt_max_input_rows, rows - 5);
    const input_content_rows = promptInputRows(self, prompt_room_for_input, max_prompt_rows);

    // Calculate confirmation box height if active
    const confirm_box_height: usize = if (self.confirm_dialog != null) 4 else 0;
    // input_rows: margin + input box rows + extra box row + loader + confirm dialog
    const input_rows: usize = 5 + input_content_rows + confirm_box_height;
    const content_rows: usize = rows - input_rows;

    try stdout.print("\x1b[?25l{s}\x1b[H", .{theme.mocha.mantle_bg});

    const top_margin: usize = 2;
    // Print top margin blank rows
    var margin_row: usize = 0;
    while (margin_row < top_margin) : (margin_row += 1) {
        try stdout.print("{s}", .{theme.mocha.mantle_bg});
        try writeMargin(stdout, left_margin);
        try stdout.splatByteAll(' ', inner_cols);
        try stdout.print("\x1b[K{s}\n", .{theme.reset});
    }

    const content_rows_with_margin = content_rows - top_margin;
    const wrapped_count = countWrappedRows(self, inner_cols);
    const max_scroll = if (wrapped_count > content_rows_with_margin) wrapped_count - content_rows_with_margin else 0;
    const first_row_to_show = @min(self.scroll_offset, max_scroll);

    const printed_rows = try printConversation(self, stdout, inner_cols, left_margin, first_row_to_show, content_rows_with_margin);
    var filled = top_margin + printed_rows;
    while (filled < content_rows) : (filled += 1) {
        try stdout.print("{s}", .{theme.mocha.mantle_bg});
        try writeMargin(stdout, left_margin);
        try stdout.splatByteAll(' ', inner_cols);
        try stdout.print("\x1b[K{s}\n", .{theme.reset});
    }

    // One row margin above input box
    try stdout.print("{s}", .{theme.mocha.mantle_bg});
    try stdout.splatByteAll(' ', cols);
    try stdout.print("\x1b[K{s}\n", .{theme.reset});

    try printScrollbar(stdout, @as(usize, cols), content_rows_with_margin, wrapped_count, first_row_to_show, max_scroll, top_margin + 1);
    try stdout.print("\x1b[{d};1H", .{content_rows + 2});

    // Render confirmation dialog if active (above input box)
    if (self.confirm_dialog) |dialog| {
        try components.printConfirmDialog(self, stdout, dialog, input_inner_cols, left_margin);
    }

    const cursor_col = try printInputArea(self, stdout, prompt, input_inner_cols, left_margin, max_prompt_rows);
    try stdout.print("{s}", .{theme.reset});

    if (self.show_model_modal) {
        try components.printModelModal(self, stdout, rows, cols);
        try stdout.writeAll("\x1b[?25l");
        return;
    }

    if (self.show_command_palette) {
        const command_palette_height = app_mod.command_palette_commands.len + 1;
        const palette_top = @max(@as(usize, 1), rows - command_palette_height - 2);
        try components.printCommandPaletteAt(self, stdout, palette_top, left_margin + 1, input_inner_cols);
    }

    const cursor_row = if (prompt_room_for_input == 0) 0 else self.cursor_pos / prompt_room_for_input;
    const first_visible_row = firstVisiblePromptInputRow(self, prompt_room_for_input, max_prompt_rows);
    const cursor_row_in_box = cursor_row - first_visible_row;
    const input_row = content_rows + 2 + cursor_row_in_box + if (self.confirm_dialog != null) @as(usize, 4) else 0;
    try stdout.print("\x1b[{d};{d}H\x1b[?25h", .{ input_row, cursor_col });
}

/// Print the conversation content
pub fn printConversation(self: *App, stdout: anytype, inner_cols: usize, left_margin: usize, start_row: usize, max_rows: usize) !usize {
    var skipped: usize = 0;
    var printed: usize = 0;
    for (self.lines.items) |line| {
        const is_thinking = std.mem.startsWith(u8, line, thinking_marker);
        const is_diff = !is_thinking and std.mem.startsWith(u8, line, diff_box_marker);
        const is_shell = !is_thinking and !is_diff and std.mem.startsWith(u8, line, shell_output_marker);
        const is_hidden = !is_thinking and !is_diff and !is_shell and std.mem.startsWith(u8, line, hidden_marker);
        const is_toggle = !is_thinking and !is_diff and !is_shell and !is_hidden and std.mem.startsWith(u8, line, toggle_marker);

        if (is_hidden) continue;

        const display_line = if (is_thinking) line[thinking_marker.len..] else if (is_shell) line[shell_output_marker.len..] else if (is_toggle) line[toggle_marker.len..] else line;
        const display_without_marker = if (is_diff) display_line[diff_box_marker.len..] else display_line;

        const is_user_message = !is_diff and !is_thinking and !is_shell and !is_hidden and !is_toggle and std.mem.startsWith(u8, display_without_marker, user_marker);
        const user_content = if (is_user_message) display_without_marker[user_marker.len..] else display_without_marker;

        const effective_line = if (is_user_message) user_content else display_without_marker;
        const row_cols = utils.rowContentCols(inner_cols, is_user_message, is_thinking, is_diff or is_toggle, is_shell);
        const line_rows = if (is_diff or is_toggle) 1 else utils.wrappedRows(effective_line.len, row_cols);

        if (skipped + line_rows <= start_row) {
            skipped += line_rows;
            continue;
        }

        if (effective_line.len == 0) {
            if (printed < max_rows and skipped >= start_row) {
                if (is_user_message) {
                    try printUserRowWithMargin(stdout, "", left_margin, inner_cols, true);
                } else if (is_diff) {
                    try printDiffBoxRowWithMargin(stdout, "", left_margin, inner_cols);
                } else if (is_thinking) {
                    try printThinkingRowWithMargin(self, stdout, "", left_margin);
                } else if (is_shell) {
                    try printShellRowWithMargin(stdout, "", left_margin, inner_cols);
                } else if (is_toggle) {
                    try printDiffBoxRowWithMargin(stdout, "", left_margin, inner_cols);
                } else {
                    try printRowWithMargin(stdout, "", left_margin);
                }
                printed += 1;
            }
            if (printed >= max_rows) break;
            skipped += line_rows;
            continue;
        }

        // Diff and toggle lines contain ANSI codes, print as-is without wrapping
        if (is_diff or is_toggle) {
            if (skipped < start_row) {
                skipped += 1;
                continue;
            }
            if (printed < max_rows) {
                try printDiffBoxRowWithMargin(stdout, effective_line, left_margin, inner_cols);
                printed += 1;
            }
            skipped += 1;
            if (printed >= max_rows) break;
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
                try printUserRowWithMargin(stdout, chunk, left_margin, inner_cols, local_row == 0);
            } else if (is_thinking) {
                try printThinkingRowWithMargin(self, stdout, chunk, left_margin);
            } else if (is_shell) {
                try printShellRowWithMargin(stdout, chunk, left_margin, inner_cols);
            } else {
                try printRowWithMargin(stdout, chunk, left_margin);
            }
            offset += chunk_len;
            printed += 1;
        }

        if (printed >= max_rows) break;
        skipped += line_rows;
    }
    return printed;
}

/// Print the scrollbar on the right side
fn printScrollbar(stdout: anytype, cols: usize, content_rows: usize, total_rows: usize, first_row: usize, max_scroll: usize, start_row: usize) !void {
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
        try stdout.print("\x1b[{d};{d}H{s}{s}{s}", .{ start_row + row, scrollbar_col, color, glyph, theme.reset });
    }
}

/// Count total wrapped rows for scrollbar calculation
fn countWrappedRows(self: *App, inner_cols: usize) usize {
    var total: usize = 0;
    for (self.lines.items) |line| {
        const is_thinking = std.mem.startsWith(u8, line, thinking_marker);
        const is_user = !is_thinking and std.mem.startsWith(u8, line, user_marker);
        const is_diff = !is_thinking and std.mem.startsWith(u8, line, diff_box_marker);
        const is_shell = !is_thinking and !is_user and !is_diff and std.mem.startsWith(u8, line, shell_output_marker);
        const is_hidden = !is_thinking and !is_user and !is_diff and !is_shell and std.mem.startsWith(u8, line, hidden_marker);
        const is_toggle = !is_thinking and !is_user and !is_diff and !is_shell and !is_hidden and std.mem.startsWith(u8, line, toggle_marker);

        if (is_hidden) continue;

        const display = if (is_thinking) line[thinking_marker.len..] else if (is_diff) line[diff_box_marker.len..] else if (is_user) line[user_marker.len..] else if (is_shell) line[shell_output_marker.len..] else if (is_toggle) line[toggle_marker.len..] else line;
        if (is_diff or is_toggle) {
            total += 1;
        } else {
            total += utils.wrappedRows(display.len, utils.rowContentCols(inner_cols, is_user, is_thinking, is_diff or is_toggle, is_shell));
        }
    }
    return total;
}

/// Get the number of content rows (excluding input area)
pub fn getContentRows(self: *App) usize {
    const size = terminal.size();
    if (size.rows < 7) return 1;
    const rows = size.rows;
    const input_inner_cols = if (self.inner_cols > 1) self.inner_cols - 1 else self.inner_cols;
    const max_prompt_rows = @min(utils.prompt_max_input_rows, rows - 5);
    const input_rows: usize = 4 + promptInputRows(self, utils.promptRoomForInput(input_inner_cols), max_prompt_rows);
    return rows - input_rows;
}

/// Get maximum scroll position
pub fn getMaxScroll(self: *App) usize {
    const content_rows = getContentRows(self);
    const total = countWrappedRows(self, self.inner_cols);
    return if (total > content_rows) total - content_rows else 0;
}

/// Calculate prompt input rows needed
fn promptInputRows(self: *App, room_for_input: usize, max_rows: usize) usize {
    if (room_for_input == 0) return 1;
    const rows_for_text = utils.wrappedRows(self.input.items.len, room_for_input);
    const rows_for_cursor = self.cursor_pos / room_for_input + 1;
    return @min(@max(rows_for_text, rows_for_cursor), max_rows);
}

/// Calculate first visible row for prompt input
fn firstVisiblePromptInputRow(self: *App, room_for_input: usize, max_rows: usize) usize {
    if (room_for_input == 0) return 0;
    const cursor_row = self.cursor_pos / room_for_input;
    if (cursor_row >= max_rows) return cursor_row - max_rows + 1;
    return 0;
}

/// Render an input line, highlighting "[pasted X lines]" with yellow background and dark text
fn renderInputLine(stdout: anytype, input: []const u8) !void {
    const prefix = "[pasted ";
    const ph_start = std.mem.indexOf(u8, input, prefix);
    if (ph_start == null) {
        try stdout.print("{s}{s}{s}", .{ theme.mocha.surface0_bg, theme.mocha.text, input });
        return;
    }
    const s = ph_start.?;
    const rest = input[s + prefix.len ..];
    const close_bracket = std.mem.indexOfScalar(u8, rest, ']');
    if (close_bracket == null) {
        try stdout.print("{s}{s}{s}", .{ theme.mocha.surface0_bg, theme.mocha.text, input });
        return;
    }
    const cb = close_bracket.?;
    const placeholder_end = s + prefix.len + cb + 1;
    // Text before placeholder with input box background
    if (s > 0) try stdout.print("{s}{s}{s}", .{ theme.mocha.surface0_bg, theme.mocha.text, input[0..s] });
    // Placeholder with yellow background and dark text (only the placeholder part)
    try stdout.print("{s}{s}{s}", .{ theme.mocha.yellow_bg, theme.mocha.surface0, input[s..placeholder_end] });
    // Text after placeholder - restore input box background and normal text color
    if (placeholder_end < input.len) try stdout.print("{s}{s}{s}", .{ theme.mocha.surface0_bg, theme.mocha.text, input[placeholder_end..] });
}

/// Print the input area box
fn printInputArea(self: *App, stdout: anytype, prompt: []const u8, inner_cols: usize, left_margin: usize, max_input_rows: usize) !usize {
    const border_cols: usize = 1;
    const input_left_padding: usize = 1;
    const input_prefix_cols = border_cols + input_left_padding;
    const room_for_input = utils.promptRoomForInput(inner_cols);
    const content_rows = promptInputRows(self, room_for_input, max_input_rows);
    const first_visible_row = firstVisiblePromptInputRow(self, room_for_input, max_input_rows);

    // Top border - lavender left border, dark background
    try stdout.print("{s}", .{theme.mocha.mantle_bg});
    try writeMargin(stdout, left_margin);
    try stdout.print("{s}▌{s}", .{
        theme.mocha.lavender,
        theme.mocha.surface0_bg,
    });
    const prompt_text = std.mem.trim(u8, prompt, " \t\r\n");
    if (prompt_text.len > 0) {
        const available = if (inner_cols > border_cols + 2) inner_cols - border_cols - 2 else 0;
        const shown = prompt_text[0..@min(prompt_text.len, available)];
        try stdout.print(" {s}{s}{s}", .{ theme.mocha.subtext0, shown, theme.mocha.surface0_bg });
        const used = border_cols + 1 + shown.len;
        if (used < inner_cols) try stdout.splatByteAll(' ', inner_cols - used);
    } else {
        if (border_cols < inner_cols) try stdout.splatByteAll(' ', inner_cols - border_cols);
    }
    try stdout.print("{s}\x1b[K{s}\n", .{ theme.mocha.mantle_bg, theme.reset });

    var input_row: usize = 0;
    while (input_row < content_rows) : (input_row += 1) {
        const absolute_input_row = first_visible_row + input_row;
        const row_start = absolute_input_row * room_for_input;
        const visible_input = if (room_for_input == 0 or row_start >= self.input.items.len)
            ""
        else blk: {
            const row_end = @min(self.input.items.len, row_start + room_for_input);
            break :blk self.input.items[row_start..row_end];
        };

        try stdout.print("{s}", .{theme.mocha.mantle_bg});
        try writeMargin(stdout, left_margin);
        try stdout.print("{s}▌{s}", .{
            theme.mocha.lavender,
            theme.mocha.surface0_bg,
        });
        if (input_left_padding > 0) try stdout.splatByteAll(' ', input_left_padding);
        try renderInputLine(stdout, visible_input);
        // Reset background to input box color before filling remaining space
        try stdout.print("{s}", .{theme.mocha.surface0_bg});
        const used_cols = input_prefix_cols + visible_input.len;
        if (used_cols < inner_cols) try stdout.splatByteAll(' ', inner_cols - used_cols);
        try stdout.print("{s}\x1b[K{s}\n", .{ theme.mocha.mantle_bg, theme.reset });
    }

    // Extra empty row inside the input box
    try stdout.print("{s}", .{theme.mocha.mantle_bg});
    try writeMargin(stdout, left_margin);
    try stdout.print("{s}▌{s}", .{
        theme.mocha.lavender,
        theme.mocha.surface0_bg,
    });
    if (border_cols < inner_cols) try stdout.splatByteAll(' ', inner_cols - border_cols);
    try stdout.print("{s}\x1b[K{s}\n", .{ theme.mocha.mantle_bg, theme.reset });

    // Bottom row of input box with build info
    try stdout.print("{s}", .{theme.mocha.mantle_bg});
    try writeMargin(stdout, left_margin);
    try stdout.print("{s}▌{s} ", .{
        theme.mocha.lavender,
        theme.mocha.surface0_bg,
    });
    const model_text = self.cfg.model;
    const max_model_len = if (inner_cols > border_cols + input_left_padding + 2) inner_cols - border_cols - input_left_padding - 2 else 0;
    const prefix_len = 8; // "Build · " length
    const available_for_model = if (max_model_len > prefix_len) max_model_len - prefix_len else 0;
    const display_model = if (model_text.len > available_for_model) model_text[0..available_for_model] else model_text;
    try stdout.print("{s}Build{s} · {s}{s}", .{ theme.mocha.lavender, theme.mocha.subtext0, display_model, theme.mocha.surface0_bg });
    const total_content_len = prefix_len + display_model.len;
    const model_padding = if (total_content_len < max_model_len) max_model_len - total_content_len else 0;
    if (model_padding > 0) try stdout.splatByteAll(' ', model_padding);
    try stdout.print("{s}\x1b[K{s}\n", .{ theme.mocha.mantle_bg, theme.reset });

    // Loader row (outside input box, below border)
    try printPendingLoader(self, stdout, inner_cols, left_margin);

    const cursor_col_in_box = if (room_for_input == 0) 0 else self.cursor_pos % room_for_input;
    return left_margin + border_cols + input_left_padding + cursor_col_in_box + 1;
}

/// Print the pending/loading indicator
fn printPendingLoader(self: *App, stdout: anytype, inner_cols: usize, left_margin: usize) !void {
    try stdout.print("{s}", .{theme.mocha.mantle_bg});
    try writeMargin(stdout, left_margin);
    if (self.is_busy or self.is_preloading) {
        const width: usize = 5;
        const cycle = width * 2 - 2;
        const phase = self.loader_frame % cycle;
        const active = if (phase < width) phase else cycle - phase;

        var i: usize = 0;
        while (i < width) : (i += 1) {
            if (i == active) {
                try stdout.print("{s}■", .{theme.mocha.lavender});
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

/// Print a user message row with margin
fn printUserRowWithMargin(stdout: anytype, text: []const u8, left_margin: usize, inner_cols: usize, is_first_row: bool) !void {
    _ = is_first_row;
    // Start with mantle background for margin area
    try stdout.print("{s}", .{theme.mocha.mantle_bg});
    // Write left margin spaces
    try stdout.splatByteAll(' ', left_margin);
    // Calculate available width: border(1) + space(1) + content + right border(1)
    const prefix_width = 2; // "▌ "
    const right_border_width = 1; // lighter column on right
    const content_width = if (inner_cols > prefix_width + right_border_width) inner_cols - prefix_width - right_border_width else 0;
    // User row matches input style: lavender left border + surface background + text
    const display_text = if (text.len > content_width) text[0..content_width] else text;
    try stdout.print("{s}▌{s} {s}{s}", .{ theme.mocha.lavender, theme.mocha.surface0_bg, theme.mocha.text, display_text });
    // Fill remaining content space
    if (display_text.len < content_width) {
        try stdout.splatByteAll(' ', content_width - display_text.len);
    }
    // Lighter right border column
    try stdout.print("{s} {s}\n", .{ theme.mocha.surface1_bg, theme.reset });
}

/// Print a diff box row with margin
fn printDiffBoxRowWithMargin(stdout: anytype, text: []const u8, left_margin: usize, inner_cols: usize) !void {
    try stdout.print("{s}", .{theme.mocha.mantle_bg});
    try stdout.splatByteAll(' ', left_margin);
    // Don't set text color - diff already contains ANSI codes for syntax highlighting
    // Calculate available width: border(1) + space(1) + content + right border(1)
    const prefix_width = 2; // "▌ "
    const right_border_width = 1; // lighter column on right
    const content_width = if (inner_cols > prefix_width + right_border_width) inner_cols - prefix_width - right_border_width else 0;

    // Truncate text to fit (accounting for ANSI codes)
    const visible_len = utils.stripAnsiLen(text);
    const display_text = if (visible_len > content_width) blk: {
        const truncated = try utils.truncateAnsiText(std.heap.c_allocator, text, content_width);
        break :blk truncated;
    } else text;
    defer if (visible_len > content_width) std.heap.c_allocator.free(display_text);

    try stdout.print("{s}▌{s} {s}", .{ theme.mocha.surface0, theme.mocha.surface0_bg, display_text });

    // Fill remaining content space
    const display_visible_len = utils.stripAnsiLen(display_text);
    if (display_visible_len < content_width) {
        try stdout.splatByteAll(' ', content_width - display_visible_len);
    }

    // Lighter right border column
    try stdout.print("{s} {s}\n", .{ theme.mocha.surface1_bg, theme.reset });
}

/// Print a thinking block row with margin
fn printThinkingRowWithMargin(self: *App, stdout: anytype, text: []const u8, left_margin: usize) !void {
    _ = self;
    try writeMargin(stdout, left_margin);
    if (std.mem.startsWith(u8, text, "Thinking:")) {
        const prefix = "Thinking:";
        const suffix = text[prefix.len..];
        try stdout.print("{s}{s} {s}\x1b[3m{s}\x1b[23m{s}{s}\x1b[K{s}\n", .{
            theme.mocha.mantle_bg,
            theme.mocha.surface0,
            theme.mocha.mauve,
            prefix,
            theme.mocha.subtext0,
            suffix,
            theme.reset,
        });
    } else {
        try stdout.print("{s}{s} {s} {s}\x1b[K{s}\n", .{ theme.mocha.mantle_bg, theme.mocha.surface0, theme.mocha.subtext0, text, theme.reset });
    }
}

/// Print a shell output row with margin
fn printShellRowWithMargin(stdout: anytype, text: []const u8, left_margin: usize, inner_cols: usize) !void {
    // Shell output - use same tone as output block (not user-message lavender)
    try stdout.print("{s}", .{theme.mocha.mantle_bg});
    try stdout.splatByteAll(' ', left_margin);
    // Calculate available width: border(1) + space(1) + content + right border(1)
    const prefix_width = 2; // "▌ "
    const right_border_width = 1; // lighter column on right
    const content_width = if (inner_cols > prefix_width + right_border_width) inner_cols - prefix_width - right_border_width else 0;

    // Truncate or pad text to fit
    const display_text = if (text.len > content_width) text[0..content_width] else text;
    try stdout.print("{s}▌{s} {s}{s}", .{ theme.mocha.surface0, theme.mocha.surface0_bg, theme.mocha.text, display_text });

    // Fill remaining content space
    if (display_text.len < content_width) {
        try stdout.splatByteAll(' ', content_width - display_text.len);
    }

    // Lighter right border column
    try stdout.print("{s} {s}\n", .{ theme.mocha.surface1_bg, theme.reset });
}

/// Print a regular row with margin
fn printRowWithMargin(stdout: anytype, text: []const u8, left_margin: usize) !void {
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

/// Write margin spaces
fn writeMargin(stdout: anytype, left_margin: usize) !void {
    try stdout.splatByteAll(' ', left_margin);
}
