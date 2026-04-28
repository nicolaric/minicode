const std = @import("std");

pub const Size = struct {
    rows: u16,
    cols: u16,
};

pub const Terminal = struct {
    stdin_fd: std.posix.fd_t,
    original: std.posix.termios,

    pub fn enter() !Terminal {
        const stdin_fd = std.Io.File.stdin().handle;
        const original = try std.posix.tcgetattr(stdin_fd);

        var raw = original;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        // Disable XON/XOFF flow control so Ctrl+S/Ctrl+Q can be used
        raw.iflag.IXON = false;
        try std.posix.tcsetattr(stdin_fd, .FLUSH, raw);
        errdefer std.posix.tcsetattr(stdin_fd, .FLUSH, original) catch {};

        try std.Io.File.writeStreamingAll(std.Io.File.stdout(), std.Options.debug_io, "\x1b[?1049h\x1b[?1007h\x1b[?25l\x1b[2J\x1b[H");

        return .{ .stdin_fd = stdin_fd, .original = original };
    }

    pub fn leave(self: *Terminal) void {
        std.posix.tcsetattr(self.stdin_fd, .FLUSH, self.original) catch {};
        std.Io.File.writeStreamingAll(std.Io.File.stdout(), std.Options.debug_io, "\x1b[0m\x1b[?1007l\x1b[?25h\x1b[?1049l") catch {};
    }
};

pub fn size() Size {
    var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const err = std.posix.system.ioctl(std.Io.File.stdin().handle, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (std.posix.errno(err) == .SUCCESS and ws.row > 0 and ws.col > 0) return .{ .rows = ws.row, .cols = ws.col };
    return .{ .rows = 25, .cols = 80 };
}
