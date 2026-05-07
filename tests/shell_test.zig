const std = @import("std");
const tools = @import("tools");

fn makeShellArgs(allocator: std.mem.Allocator, command: []const u8) !std.json.Value {
    var map = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try map.put(allocator, "command", .{ .string = try allocator.dupe(u8, command) });
    return .{ .object = map };
}

test "run_shell executes simple command without TTY" {
    const allocator = std.testing.allocator;
    
    // Test a simple echo command
    const args = try makeShellArgs(allocator, "echo hello world");
    
    const result = try tools.executeWithConfirm(allocator, .{
        .tool = "run_shell",
        .args = args,
    }, null, null);
    defer allocator.free(result);
    
    try std.testing.expect(std.mem.indexOf(u8, result, "hello world") != null);
}

test "run_shell blocks interactive commands" {
    const allocator = std.testing.allocator;
    
    // Test that zig build run is blocked
    const args = try makeShellArgs(allocator, "zig build run");
    
    const result = try tools.executeWithConfirm(allocator, .{
        .tool = "run_shell",
        .args = args,
    }, null, null);
    defer allocator.free(result);
    
    try std.testing.expect(std.mem.indexOf(u8, result, "interactive command blocked") != null);
}

test "run_shell captures stdout correctly" {
    const allocator = std.testing.allocator;
    
    // Test multi-line output
    const args = try makeShellArgs(allocator, "echo line1 && echo line2");
    
    const result = try tools.executeWithConfirm(allocator, .{
        .tool = "run_shell",
        .args = args,
    }, null, null);
    defer allocator.free(result);
    
    try std.testing.expect(std.mem.indexOf(u8, result, "line1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "line2") != null);
}

test "run_shell handles command not found" {
    const allocator = std.testing.allocator;
    
    // Test error handling for non-existent command
    const args = try makeShellArgs(allocator, "this_command_does_not_exist_12345");
    
    const result = try tools.executeWithConfirm(allocator, .{
        .tool = "run_shell",
        .args = args,
    }, null, null);
    defer allocator.free(result);
    
    // Should return an error message
    try std.testing.expect(std.mem.indexOf(u8, result, "Error") != null or 
                           std.mem.indexOf(u8, result, "not found") != null);
}