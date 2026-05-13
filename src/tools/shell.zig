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

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    var child = std.process.spawn(io, .{
        .argv = &argv,
        .environ_map = &env_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |err| {
        return std.fmt.allocPrint(allocator, "Error running command: {s}", .{@errorName(err)});
    };
    
    // Put child in its own process group to prevent TTY conflicts
    if (child.id) |pid| {
        _ = core.setpgid(pid, pid);
    }
    
    defer _ = child.wait(io) catch {};

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    // Stderr is redirected into stdout in modified_command, so one pipe is enough.
    if (child.stdout) |stdout_file| {
        while (!(try readPipeChunk(allocator, io, stdout_file, &output, streamer))) {}
    }

    return output.toOwnedSlice(allocator);
}

fn readPipeChunk(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, output: *std.ArrayList(u8), streamer: ?ShellStream) !bool {
    var buf: [4096]u8 = undefined;
    var vecs = [_][]u8{buf[0..]};
    const n = file.readStreaming(io, &vecs) catch |err| switch (err) {
        error.EndOfStream => return true,
        else => return true,
    };
    if (n == 0) return true;
    try output.appendSlice(allocator, buf[0..n]);
    if (streamer) |s| s.callback(s.ctx, buf[0..n], false);
    return false;
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
