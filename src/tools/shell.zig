const std = @import("std");
const core = @import("core.zig");

const Confirm = core.Confirm;
const ShellStream = core.ShellStream;

/// Run shell command with confirmation
pub fn runShell(allocator: std.mem.Allocator, command: []const u8, confirmer: ?Confirm) ![]u8 {
    return runShellStreaming(allocator, command, confirmer, null);
}

/// Run shell command with optional streaming output
pub fn runShellStreaming(allocator: std.mem.Allocator, command: []const u8, confirmer: ?Confirm, streamer: ?ShellStream) ![]u8 {
    if (confirmer) |c| {
        if (!(try core.confirm(std.fmt.allocPrint(allocator, "Run: {s}", .{command}) catch return error.OutOfMemory, c))) {
            return std.fmt.allocPrint(allocator, "Command cancelled", .{});
        }
    }

    if (std.mem.trim(u8, command, " \t\r\n").len == 0) return std.fmt.allocPrint(allocator, "Error: empty command", .{});
    if (isInteractiveOrNestedMinicodeCommand(command)) {
        return std.fmt.allocPrint(allocator, "Error: interactive command blocked in run_shell: {s}. Use 'zig build' instead.", .{command});
    }

    // Always use bash like pi-mono for consistent behavior
    // This ensures PATH and other env vars are loaded the same way
    const shell: []const u8 = "/bin/bash";
    
    // Just redirect stdin from /dev/null to prevent TTY access
    // The setpgid call after spawn will handle process group isolation
    const modified_command = try std.fmt.allocPrint(allocator, 
        "{s} </dev/null 2>&1", .{command});
    defer allocator.free(modified_command);
    
    // Non-login shell: avoid brittle profile/rc loading side effects.
    const argv = [_][]const u8{ shell, "-c", modified_command };

    var env_map = try core.loadShellEnv(allocator, shell);
    defer env_map.deinit();

    // Make PATH robust across launch contexts (terminal-independent).
    try core.ensurePathHas(&env_map, allocator, "/opt/homebrew/bin");
    try core.ensurePathHas(&env_map, allocator, "/usr/local/bin");
    if (env_map.get("HOME")) |home| {
        const local_bin = try std.fmt.allocPrint(allocator, "{s}/.local/bin", .{home});
        defer allocator.free(local_bin);
        try core.ensurePathHas(&env_map, allocator, local_bin);
    }

    var child = std.process.spawn(std.Options.debug_io, .{
        .argv = &argv,
        .environ_map = &env_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        return std.fmt.allocPrint(allocator, "Error running command: {s}", .{@errorName(err)});
    };
    
    // Put child in its own process group to prevent TTY conflicts
    if (child.id) |pid| {
        _ = core.setpgid(pid, pid);
    }
    
    defer _ = child.wait(std.Options.debug_io) catch {};

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    // Use poll to read from both stdout and stderr with timeout for streaming
    const stdout_fd = if (child.stdout) |f| f.handle else -1;
    const stderr_fd = if (child.stderr) |f| f.handle else -1;

    var stdout_done = stdout_fd < 0;
    var stderr_done = stderr_fd < 0;

    while (!stdout_done or !stderr_done) {
        var poll_fds: [2]std.posix.pollfd = undefined;
        var poll_count: usize = 0;

        if (!stdout_done) {
            poll_fds[poll_count] = .{ .fd = stdout_fd, .events = std.posix.POLL.IN, .revents = 0 };
            poll_count += 1;
        }
        if (!stderr_done) {
            poll_fds[poll_count] = .{ .fd = stderr_fd, .events = std.posix.POLL.IN, .revents = 0 };
            poll_count += 1;
        }

        if (poll_count == 0) break;

        // Poll with 50ms timeout to allow streaming
        const ready = std.posix.poll(poll_fds[0..poll_count], 50) catch 0;

        if (ready > 0) {
            var idx: usize = 0;
            if (!stdout_done) {
                if (poll_fds[idx].revents & std.posix.POLL.IN != 0) {
                    var buf: [4096]u8 = undefined;
                    const n = std.posix.read(stdout_fd, &buf) catch 0;
                    if (n == 0) {
                        stdout_done = true;
                    } else {
                        try output.appendSlice(allocator, buf[0..n]);
                        // Stream output if callback provided
                        if (streamer) |s| {
                            s.callback(s.ctx, buf[0..n], false);
                        }
                    }
                } else if (poll_fds[idx].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
                    stdout_done = true;
                }
                idx += 1;
            }
            if (!stderr_done) {
                if (poll_fds[idx].revents & std.posix.POLL.IN != 0) {
                    var buf: [4096]u8 = undefined;
                    const n = std.posix.read(stderr_fd, &buf) catch 0;
                    if (n == 0) {
                        stderr_done = true;
                    } else {
                        if (output.items.len > 0) try output.append(allocator, '\n');
                        try output.appendSlice(allocator, buf[0..n]);
                        // Stream output if callback provided
                        if (streamer) |s| {
                            s.callback(s.ctx, buf[0..n], true);
                        }
                    }
                } else if (poll_fds[idx].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
                    stderr_done = true;
                }
            }
        }
    }

    return output.toOwnedSlice(allocator);
}

fn isInteractiveOrNestedMinicodeCommand(command: []const u8) bool {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len == 0) return false;

    var tokens = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");

    const first = tokens.next() orelse return false;
    const second = tokens.next();
    const third = tokens.next();

    if (std.mem.eql(u8, first, "zig") and
        second != null and std.mem.eql(u8, second.?, "build") and
        third != null and std.mem.eql(u8, third.?, "run"))
    {
        return true;
    }

    return isMinicodeToken(first);
}

fn isMinicodeToken(token: []const u8) bool {
    if (token.len == 0) return false;
    if (std.mem.eql(u8, token, "minicode")) return true;
    return std.mem.endsWith(u8, token, "/minicode");
}

// Shell tests

test "run_shell blocks zig build run" {
    var arena = std.heap.ArenaAllocator.init(core.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try runShell(allocator, "zig build run", null);
    try core.testing.expect(std.mem.indexOf(u8, result, "interactive command blocked in run_shell") != null);
    try core.testing.expect(std.mem.indexOf(u8, result, "Use 'zig build' instead.") != null);
}

test "run_shell blocks zig build run with extra args" {
    var arena = std.heap.ArenaAllocator.init(core.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try runShell(allocator, "zig build run -- foo", null);
    try core.testing.expect(std.mem.indexOf(u8, result, "interactive command blocked in run_shell") != null);
}

test "run_shell blocks nested minicode binary path" {
    var arena = std.heap.ArenaAllocator.init(core.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try runShell(allocator, "./zig-out/bin/minicode --help", null);
    try core.testing.expect(std.mem.indexOf(u8, result, "interactive command blocked in run_shell") != null);
}

test "run_shell blocks direct minicode token" {
    var arena = std.heap.ArenaAllocator.init(core.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try runShell(allocator, "minicode --help", null);
    try core.testing.expect(std.mem.indexOf(u8, result, "interactive command blocked in run_shell") != null);
}

test "run_shell allows safe non-interactive command" {
    var arena = std.heap.ArenaAllocator.init(core.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try runShell(allocator, "pwd", null);
    try core.testing.expect(std.mem.indexOf(u8, result, "interactive command blocked in run_shell") == null);
}

test "run_shell allows echoing minicode path as text" {
    var arena = std.heap.ArenaAllocator.init(core.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try runShell(allocator, "echo ./zig-out/bin/minicode", null);
    try core.testing.expect(std.mem.indexOf(u8, result, "interactive command blocked in run_shell") == null);
}
