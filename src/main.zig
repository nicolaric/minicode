const std = @import("std");
const config = @import("config.zig");
const tui = @import("tui.zig");

var app_threaded_io: std.Io.Threaded = undefined;

pub const std_options_debug_threaded_io: ?*std.Io.Threaded = &app_threaded_io;

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    app_threaded_io = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer app_threaded_io.deinit();

    var loaded_config = try config.load(allocator);
    defer loaded_config.deinit(allocator);
    try tui.run(allocator, loaded_config.config);
}
