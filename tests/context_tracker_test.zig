const std = @import("std");
const context_tracker = @import("context_tracker");
const ContextTracker = context_tracker.ContextTracker;

test "ContextTracker generates narrative summary" {
    const allocator = std.testing.allocator;
    
    var tracker = ContextTracker.init(allocator);
    defer tracker.deinit();
    
    // Simulate reading a Zig file - should detect project type
    var args_map = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer args_map.deinit(allocator);
    try args_map.put(allocator, "path", std.json.Value{ .string = "src/main.zig" });
    const args = std.json.Value{ .object = args_map };
    
    try tracker.recordToolExecution("read_file", args, "const std = @import(\"std\");");
    
    // Project type should be detected
    try std.testing.expect(tracker.project_type != null);
    try std.testing.expectEqualStrings(tracker.project_type.?, "Zig");
    
    // Simulate searching for something
    try args_map.put(allocator, "pattern", std.json.Value{ .string = "config" });
    const grep_args = std.json.Value{ .object = args_map };
    try tracker.recordToolExecution("grep", grep_args, "Found 3 matches");
    
    // Should have discovery about looking for config
    try std.testing.expectEqual(tracker.discoveries.items.len, 1);
    try std.testing.expectEqualStrings(tracker.discoveries.items[0], "Looking for 'config'");
    
    // Generate summary
    tracker.round_count = 4; // Force summary generation
    const summary = try tracker.generateSummary();
    defer allocator.free(summary);
    
    // Summary should contain project type and discoveries
    try std.testing.expect(std.mem.indexOf(u8, summary, "Zig project") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Looking for 'config'") != null);
}
