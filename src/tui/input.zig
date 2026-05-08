const std = @import("std");
const terminal = @import("../terminal.zig");
const app_mod = @import("app.zig");

const App = app_mod.App;

fn commandFilter(self: *App) []const u8 {
    const trimmed = std.mem.trim(u8, self.input.items, " \t\r\n");
    return if (trimmed.len > 0 and trimmed[0] == '/') trimmed else "/";
}

fn commandMatches(command: []const u8, filter: []const u8) bool {
    return filter.len <= 1 or (filter.len <= command.len and std.mem.startsWith(u8, command, filter));
}

fn matchingCommandCount(self: *App) usize {
    const filter = commandFilter(self);
    var visible: usize = 0;
    for (app_mod.command_palette_commands) |command| {
        if (commandMatches(command, filter)) visible += 1;
    }
    return visible;
}

fn nthMatchingCommandIndex(self: *App, selected: usize) ?usize {
    const filter = commandFilter(self);
    var visible: usize = 0;
    for (app_mod.command_palette_commands, 0..) |command, idx| {
        if (!commandMatches(command, filter)) continue;
        if (visible == selected) return idx;
        visible += 1;
    }
    return null;
}

/// Handle model modal key input
pub fn handleModelModalKey(self: *App, stdin: anytype, ch: u8) !bool {
    switch (ch) {
        3, 'q' => {
            self.closeModelModal();
            try self.render();
            return true;
        },
        '\r', '\n' => {
            self.closeModelModal();
            try self.render();
            return true;
        },
        else => {},
    }

    const count = if (self.model_names) |names| names.len else 0;
    if (ch == 27) {
        var seq: [1]u8 = undefined;
        const n = stdin.readSliceShort(&seq) catch 0;
        if (n == 0) {
            self.closeModelModal();
            try self.render();
            return true;
        }
        if (seq[0] != '[') return true;

        var seq2: [1]u8 = undefined;
        const n2 = stdin.readSliceShort(&seq2) catch 0;
        if (n2 == 0) return true;
        switch (seq2[0]) {
            'A' => {
                if (self.model_selected > 0) self.model_selected -= 1;
            },
            'B' => {
                if (self.model_selected + 1 < count) self.model_selected += 1;
            },
            else => {},
        }
        try self.render();
        return true;
    }

    switch (ch) {
        'k' => {
            if (self.model_selected > 0) self.model_selected -= 1;
        },
        'j' => {
            if (self.model_selected + 1 < count) self.model_selected += 1;
        },
        else => return true,
    }
    try self.render();
    return true;
}

/// Handle escape sequences while busy (streaming)
pub fn handleBusyEscapeSequence(self: *App) !bool {
    const seq0 = try self.readPendingByte();
    if (seq0 == null) {
        self.cancel_requested = true;
        return true;
    }

    // Treat bare ESC or Alt+Esc as stream cancellation. Arrow/function-key
    // escape sequences still start with '[' and continue below.
    if (seq0.? == 27) {
        self.cancel_requested = true;
        return true;
    }

    if (seq0.? == '[') {
        const seq1 = try self.readPendingByte();
        if (seq1 == null) {
            self.cancel_requested = true;
            return true;
        }

        switch (seq1.?) {
            'A' => {
                self.scrollUp(3);
                return true;
            },
            'B' => {
                self.scrollDown(3);
                return true;
            },
            'D' => {
                if (self.cursor_pos > 0) self.cursor_pos -= 1;
                return true;
            },
            'C' => {
                if (self.cursor_pos < self.input.items.len) self.cursor_pos += 1;
                return true;
            },
            'H' => {
                self.cursor_pos = 0;
                return true;
            },
            'F' => {
                self.cursor_pos = self.input.items.len;
                return true;
            },
            '<' => return try handleBusySgrMouse(self),
            '5' => {
                const maybe_tilde = try self.readPendingByte();
                if (maybe_tilde != null and maybe_tilde.? == '~') {
                    self.scrollUp(self.getContentRows());
                    return true;
                }
                return false;
            },
            '6' => {
                const maybe_tilde = try self.readPendingByte();
                if (maybe_tilde != null and maybe_tilde.? == '~') {
                    self.scrollDown(self.getContentRows());
                    return true;
                }
                return false;
            },
            '3' => {
                const maybe_tilde = try self.readPendingByte();
                if (maybe_tilde != null and maybe_tilde.? == '~') {
                    if (self.cursor_pos < self.input.items.len) {
                        _ = self.input.orderedRemove(self.cursor_pos);
                    }
                    return true;
                }
                return false;
            },
            '1', '7' => {
                const maybe_tilde = try self.readPendingByte();
                if (maybe_tilde != null and maybe_tilde.? == '~') {
                    self.cursor_pos = 0;
                    return true;
                }
                return false;
            },
            '4', '8' => {
                const maybe_tilde = try self.readPendingByte();
                if (maybe_tilde != null and maybe_tilde.? == '~') {
                    self.cursor_pos = self.input.items.len;
                    return true;
                }
                return false;
            },
            else => return false,
        }
    }

    switch (seq0.?) {
        'b' => {
            self.moveCursorWordLeft();
            return true;
        },
        'f' => {
            self.moveCursorWordRight();
            return true;
        },
        127, 8 => {
            self.deleteWordLeft();
            return true;
        },
        else => return false,
    }
}

fn handleBusySgrMouse(self: *App) !bool {
    var buf: [32]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) : (len += 1) {
        const maybe_byte = try self.readPendingByte();
        if (maybe_byte == null) return false;
        buf[len] = maybe_byte.?;
        if (buf[len] == 'M' or buf[len] == 'm') break;
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

/// Handle modified arrow keys (Alt+arrow)
pub fn handleModifiedArrow(self: *App, stdin: anytype) !bool {
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

/// Handle SGR mouse events (scroll wheel)
pub fn handleSgrMouse(self: *App, stdin: anytype) !bool {
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

/// Handle command palette key input
pub fn handleCommandPaletteKey(self: *App, stdin: anytype, ch: u8) !bool {
    const count = matchingCommandCount(self);

    if (ch == 27) {
        var seq: [1]u8 = undefined;
        const n = stdin.readSliceShort(&seq) catch 0;
        if (n == 0) {
            self.closeCommandPalette();
            try self.render();
            return true;
        }
        if (seq[0] != '[') return true;

        var seq2: [1]u8 = undefined;
        const n2 = stdin.readSliceShort(&seq2) catch 0;
        if (n2 == 0) return true;
        switch (seq2[0]) {
            'A' => {
                if (self.command_selected > 0) self.command_selected -= 1;
            },
            'B' => {
                if (self.command_selected + 1 < count) self.command_selected += 1;
            },
            else => {},
        }
        try self.render();
        return true;
    }

    switch (ch) {
        3, 27 => {
            self.closeCommandPalette();
            try self.render();
            return true;
        },
        '\r', '\n' => {
            const idx = nthMatchingCommandIndex(self, self.command_selected) orelse {
                self.closeCommandPalette();
                return false;
            };
            const command = app_mod.command_palette_commands[idx];
            self.closeCommandPalette();
            self.input.clearRetainingCapacity();
            self.cursor_pos = 0;
            self.input_cleared = false;
            if (std.mem.eql(u8, command, "/exit")) {
                return error.Exit;
            } else if (std.mem.eql(u8, command, "/model")) {
                try self.openModelModal();
            } else if (std.mem.eql(u8, command, "/new")) {
                try self.resetConversation();
            }
            try self.render();
            return true;
        },
        else => {
            self.command_selected = 0;
            return false;
        },
    }
    try self.render();
    return true;
}
