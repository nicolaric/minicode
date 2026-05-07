const std = @import("std");
const theme = @import("../theme.zig");
const app_mod = @import("app.zig");
const utils = @import("utils.zig");

const App = app_mod.App;

/// Print the confirmation dialog
pub fn printConfirmDialog(_: *App, stdout: anytype, dialog: utils.ConfirmDialog, inner_cols: usize, left_margin: usize) !void {
    const button_width = 12;
    const gap: usize = 4;
    const total_buttons_width = button_width * 2 + gap;
    const prompt_max_width = inner_cols - 4;

    // Truncate prompt if needed
    const display_prompt = if (dialog.prompt.len > prompt_max_width)
        dialog.prompt[0..prompt_max_width]
    else
        dialog.prompt;

    // Center calculations
    const prompt_padding = (inner_cols - display_prompt.len) / 2;
    const buttons_start = left_margin + (inner_cols - total_buttons_width) / 2;

    // Top border - lavender left border like command execution card
    try stdout.print("{s}", .{theme.mocha.mantle_bg});
    try stdout.splatByteAll(' ', left_margin);
    try stdout.print("{s}+{s}", .{ theme.mocha.lavender, theme.mocha.surface0 });
    try stdout.splatByteAll('-', inner_cols - 2);
    try stdout.print("+{s}\x1b[K\n", .{theme.reset});

    // Prompt row - lavender left border
    try stdout.print("{s}", .{theme.mocha.mantle_bg});
    try stdout.splatByteAll(' ', left_margin);
    try stdout.print("{s}+{s}", .{ theme.mocha.lavender, theme.mocha.surface0_bg });
    try stdout.splatByteAll(' ', prompt_padding - 1);
    try stdout.print("{s}{s}", .{ theme.mocha.text, display_prompt });
    const remaining = inner_cols - 2 - prompt_padding - display_prompt.len;
    try stdout.splatByteAll(' ', remaining);
    try stdout.print("{s}|{s}\x1b[K\n", .{ theme.mocha.surface0, theme.reset });

    // Buttons row - lavender left border
    try stdout.print("{s}", .{theme.mocha.mantle_bg});
    try stdout.splatByteAll(' ', left_margin);
    try stdout.print("{s}+{s}", .{ theme.mocha.lavender, theme.reset });

    // Padding before buttons
    const button_row_padding = buttons_start - left_margin - 1;
    try stdout.splatByteAll(' ', button_row_padding);

    // No button
    if (dialog.selected == 0) {
        try stdout.print("{s}<  No  >{s}", .{ theme.mocha.lavender_bg, theme.reset });
    } else {
        try stdout.print("{s}<  No  >{s}", .{ theme.mocha.surface0, theme.mocha.text });
    }

    // Gap between buttons
    try stdout.splatByteAll(' ', gap);

    // Yes button
    if (dialog.selected == 1) {
        try stdout.print("{s}< Yes  >{s}", .{ theme.mocha.lavender_bg, theme.reset });
    } else {
        try stdout.print("{s}< Yes  >{s}", .{ theme.mocha.surface0, theme.mocha.text });
    }

    // Fill to right edge
    const after_buttons = buttons_start + total_buttons_width;
    const right_fill = left_margin + inner_cols - 1 - after_buttons;
    try stdout.splatByteAll(' ', right_fill);
    try stdout.print("{s}|{s}\x1b[K\n", .{ theme.mocha.surface0, theme.reset });

    // Bottom border - lavender left border
    try stdout.print("{s}", .{theme.mocha.mantle_bg});
    try stdout.splatByteAll(' ', left_margin);
    try stdout.print("{s}+{s}", .{ theme.mocha.lavender, theme.mocha.surface0 });
    try stdout.splatByteAll('-', inner_cols - 2);
    try stdout.print("+{s}\x1b[K\n", .{theme.reset});
}

/// Print the model selection modal
pub fn printModelModal(self: *App, stdout: anytype, rows: usize, cols: usize) !void {
    if (rows < 8 or cols < 24) return;

    const width: usize = @min(if (cols > 72) 64 else cols - 4, cols - 2);
    const height: usize = @min(if (rows > 18) 14 else rows - 4, rows - 2);
    const left = (cols - width) / 2 + 1;
    const top = (rows - height) / 2 + 1;
    const inner_width = width;
    const text_width = inner_width - 4;
    const content_top = top + utils.model_modal_vertical_padding;
    const help_row = top + height - utils.model_modal_vertical_padding - 1;
    const list_rows = if (height > utils.model_modal_vertical_padding * 2 + 3) height - utils.model_modal_vertical_padding * 2 - 3 else 1;

    try printModalBackdrop(stdout, rows, cols);
    try printModalPanel(stdout, top, left, width, height);
    try printModalText(stdout, content_top, left, width, "Ollama Models", theme.mocha.mauve, false);
    try printModalText(stdout, content_top + 1, left, width, "", theme.mocha.text, false);

    if (self.model_error) |message| {
        try printModalText(stdout, content_top + 2, left, width, message[0..@min(message.len, text_width)], theme.mocha.red, false);
        var row: usize = 1;
        while (row < list_rows) : (row += 1) {
            try printModalText(stdout, content_top + 2 + row, left, width, "", theme.mocha.text, false);
        }
    } else if (self.model_names) |names| {
        if (names.len == 0) {
            try printModalText(stdout, content_top + 2, left, width, "No local models found", theme.mocha.subtext0, false);
            var row: usize = 1;
            while (row < list_rows) : (row += 1) {
                try printModalText(stdout, content_top + 2 + row, left, width, "", theme.mocha.text, false);
            }
        } else {
            const first_visible = if (self.model_selected >= list_rows) self.model_selected - list_rows + 1 else 0;
            var row: usize = 0;
            while (row < list_rows) : (row += 1) {
                const index = first_visible + row;
                if (index < names.len) {
                    const selected = index == self.model_selected;
                    const active = std.mem.eql(u8, names[index], self.cfg.model);
                    const model_color = if (active) theme.mocha.blue else if (selected) theme.mocha.text else theme.mocha.subtext0;
                    try printModalText(stdout, content_top + 2 + row, left, width, names[index][0..@min(names[index].len, text_width - 2)], model_color, selected);
                } else {
                    try printModalText(stdout, content_top + 2 + row, left, width, "", theme.mocha.text, false);
                }
            }
        }
    } else {
        try printModalText(stdout, content_top + 2, left, width, "Loading...", theme.mocha.subtext0, false);
        var row: usize = 1;
        while (row < list_rows) : (row += 1) {
            try printModalText(stdout, content_top + 2 + row, left, width, "", theme.mocha.text, false);
        }
    }

    try printModalText(stdout, help_row, left, width, "arrows/j/k move, Enter/Esc/q closes", theme.mocha.surface0, false);
}

/// Print modal backdrop (dims the background)
fn printModalBackdrop(stdout: anytype, rows: usize, cols: usize) !void {
    var row: usize = 1;
    while (row <= rows) : (row += 1) {
        try stdout.print("\x1b[{d};1H{s}", .{ row, theme.mocha.crust_bg });
        try stdout.splatByteAll(' ', cols);
    }
}

/// Print modal panel (the box)
fn printModalPanel(stdout: anytype, top: usize, left: usize, width: usize, height: usize) !void {
    var row: usize = 0;
    while (row < height) : (row += 1) {
        try stdout.print("\x1b[{d};1H{s}", .{ top + row, theme.mocha.crust_bg });
        if (left > 1) try stdout.splatByteAll(' ', left - 1);
        try stdout.print("{s}", .{theme.mocha.mantle_bg});
        try stdout.splatByteAll(' ', width);
        try stdout.print("{s}\x1b[K{s}", .{ theme.mocha.crust_bg, theme.reset });
    }
}

/// Print modal text line
fn printModalText(stdout: anytype, row: usize, left: usize, width: usize, text: []const u8, color: []const u8, selected: bool) !void {
    const inner_width = width;
    const prefix = if (selected) "> " else "  ";
    const available = inner_width - utils.model_modal_padding * 2 - prefix.len;
    const visible = text[0..@min(text.len, available)];
    const used = utils.model_modal_padding + prefix.len + visible.len;

    try stdout.print("\x1b[{d};1H{s}", .{ row, theme.mocha.crust_bg });
    if (left > 1) try stdout.splatByteAll(' ', left - 1);
    try stdout.print("{s}", .{theme.mocha.mantle_bg});
    try stdout.splatByteAll(' ', utils.model_modal_padding);
    try stdout.print("{s}{s}{s}", .{ prefix, color, visible });
    if (used < inner_width) try stdout.splatByteAll(' ', inner_width - used);
    try stdout.print("{s}\x1b[K{s}", .{ theme.mocha.crust_bg, theme.reset });
}


/// Print the command palette dropup (above input area)
pub fn printCommandPalette(self: *App, stdout: anytype, rows: usize, cols: usize) !void {
    const commands = [_][]const u8{
        "/new",
        "/model",
        "/exit",
    };
    const count = commands.len;
    const palette_height = count + 2; // title + items + help

    // Position: above the input area, at the bottom of the screen
    const top = @max(@as(usize, 1), rows - palette_height - 1);
    const width: usize = @min(40, cols - 2);
    const left = (cols - width) / 2 + 1;

    // Draw the palette box
    var row: usize = 0;
    while (row < palette_height) : (row += 1) {
        try stdout.print("\x1b[{d};1H{s}", .{ top + row, theme.mocha.crust_bg });
        if (left > 1) try stdout.splatByteAll(' ', left - 1);
        try stdout.print("{s}", .{theme.mocha.mantle_bg});
        try stdout.splatByteAll(' ', width);
        try stdout.print("{s}\x1b[K{s}", .{ theme.mocha.crust_bg, theme.reset });
      }

    // Title
    try printModalText(stdout, top, left, width, "Commands", theme.mocha.mauve, false);

    // Command items
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        const cmd = commands[idx];
        const selected = idx == self.command_selected;
        const color = if (selected) theme.mocha.text else theme.mocha.subtext0;
        const label = try std.fmt.allocPrint(std.heap.page_allocator, "{s} - {s}", .{ cmd[0], cmd[1] });
        defer _ = std.heap.page_allocator.free(label);
        try printModalText(stdout, top + 1 + idx, left, width, label, color, selected);
      }

    // Help text
    try printModalText(stdout, top + count + 1, left, width, "arrows/j/k move, Enter select, Esc/q close", theme.mocha.surface0, false);
}
