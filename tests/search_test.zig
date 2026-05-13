const std = @import("std");
const tools = @import("tools");

test "grep treats escaped pipe as literal" {
    const path = ".tmp-grep-escaped-pipe-test.txt";
    std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path) catch {};

    {
        var file = try std.Io.Dir.cwd().createFile(std.Options.debug_io, path, .{});
        defer file.close(std.Options.debug_io);
        try std.Io.File.writeStreamingAll(file, std.Options.debug_io, "a|b\naxb\n");
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try tools.grepFiles(allocator, "a\\|b", path, null, true, null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Found 1 matches") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Line: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Line: 2") == null);
}
