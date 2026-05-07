const std = @import("std");
const terminal = @import("terminal.zig");
const config = @import("config.zig");

// Import submodules
const app_mod = @import("tui/app.zig");

// Re-export public types and functions
pub const App = app_mod.App;
pub const welcome_title_lines = app_mod.welcome_title_lines;

/// Main entry point for the TUI
pub fn run(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var term = try terminal.Terminal.enter();
    defer term.leave();

    var app = try App.init(allocator, cfg);
    defer app.deinit();

    try app.start();
    try app.loop();
}
