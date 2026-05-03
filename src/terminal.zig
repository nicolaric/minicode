const std = @import("std");

extern "c" fn getpgrp() std.posix.pid_t;
extern "c" fn tcgetpgrp(fd: std.posix.fd_t) std.posix.pid_t;
extern "c" fn tcsetpgrp(fd: std.posix.fd_t, pgrp: std.posix.pid_t) c_int;

pub const Size = struct {
    rows: u16,
    cols: u16,
};

pub const Terminal = struct {
    stdin_fd: std.posix.fd_t,
    original: std.posix.termios,
    original_pgrp: ?std.posix.pid_t,

    pub fn enter() !Terminal {
        const stdin_fd = std.Io.File.stdin().handle;
        const original = try std.posix.tcgetattr(stdin_fd);
        const original_pgrp = claimForeground(stdin_fd);

        var raw = original;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        // Disable XON/XOFF flow control so Ctrl+S/Ctrl+Q can be used
        raw.iflag.IXON = false;
        raw.cc[@intFromEnum(std.c.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.c.V.TIME)] = 1;
        try std.posix.tcsetattr(stdin_fd, .FLUSH, raw);
        errdefer std.posix.tcsetattr(stdin_fd, .FLUSH, original) catch {};

        try std.Io.File.writeStreamingAll(std.Io.File.stdout(), std.Options.debug_io, "\x1b[?1049h\x1b[?1007h\x1b[?25l\x1b[2J\x1b[H");

        return .{ .stdin_fd = stdin_fd, .original = original, .original_pgrp = original_pgrp };
    }

    pub fn leave(self: *Terminal) void {
        std.posix.tcsetattr(self.stdin_fd, .FLUSH, self.original) catch {};
        std.Io.File.writeStreamingAll(std.Io.File.stdout(), std.Options.debug_io, "\x1b[0m\x1b[?1007l\x1b[?25h\x1b[?1049l") catch {};
        if (self.original_pgrp) |pgrp| restoreForeground(self.stdin_fd, pgrp);
    }
};

fn claimForeground(stdin_fd: std.posix.fd_t) ?std.posix.pid_t {
    const original_pgrp = tcgetpgrp(stdin_fd);
    if (original_pgrp == -1) return null;
    const own_pgrp = getpgrp();
    if (original_pgrp == own_pgrp) return original_pgrp;

    withTtouIgnored(struct {
        fn setForeground(fd: std.posix.fd_t, pgrp: std.posix.pid_t) void {
            _ = tcsetpgrp(fd, pgrp);
        }
    }.setForeground, stdin_fd, own_pgrp);

    return original_pgrp;
}

fn restoreForeground(stdin_fd: std.posix.fd_t, pgrp: std.posix.pid_t) void {
    const current_pgrp = tcgetpgrp(stdin_fd);
    if (current_pgrp == -1 or current_pgrp == pgrp) return;
    withTtouIgnored(struct {
        fn setForeground(fd: std.posix.fd_t, foreground_pgrp: std.posix.pid_t) void {
            _ = tcsetpgrp(fd, foreground_pgrp);
        }
    }.setForeground, stdin_fd, pgrp);
}

fn withTtouIgnored(comptime callback: fn (std.posix.fd_t, std.posix.pid_t) void, fd: std.posix.fd_t, pgrp: std.posix.pid_t) void {
    var old_ttou: std.posix.Sigaction = undefined;
    const ignore_ttou: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TTOU, &ignore_ttou, &old_ttou);
    defer std.posix.sigaction(.TTOU, &old_ttou, null);
    callback(fd, pgrp);
}

pub fn size() Size {
    var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const err = std.posix.system.ioctl(std.Io.File.stdin().handle, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (std.posix.errno(err) == .SUCCESS and ws.row > 0 and ws.col > 0) return .{ .rows = ws.row, .cols = ws.col };
    return .{ .rows = 25, .cols = 80 };
}
