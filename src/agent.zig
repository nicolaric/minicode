const std = @import("std");
const config = @import("config.zig");
const ollama = @import("ollama.zig");
const tools = @import("tools.zig");

pub const system_prompt =
    \\You are a coding assistant.
    \\When you need information, use a tool by outputting ONLY valid JSON.
    \\DO NOT output thinking or explanations when using tools.
    \\CORRECT: {"tool":"read_file","args":{"path":"src/main.zig"}}
    \\WRONG: Let me check the file... {"tool":"read_file"...}
    \\NAVIGATION RULES: 1) For files under 500 lines, read with no offset to get the whole file at once. 2) For large files, use grep FIRST to find line numbers, then read around that line. 3) If you must scan without grep, read offset=1 first, then offset=101, 201, etc. 4) NEVER use offset=10, 11, 12 repeatedly.
    \\Do not use run_shell for file navigation, line counts, grep, cat, find, or ls. Use read_file, grep, glob, and list_files instead.
    \\Tools:
    \\  read_file(path, offset?, limit?) - read 100 numbered file lines; offset defaults to line 1
    \\  write_file(path, content) - write file (shows numbered diff if overwriting)
    \\  list_files(path) - list directory contents
    \\  run_shell(command) - run non-file shell commands only; requires confirmation
    \\  glob(pattern, path?) - find files by pattern (e.g., "**/*.zig")
    \\  grep(pattern, path?, include?, case_sensitive?) - search file contents with line numbers; case-insensitive by default; supports basic regex
    \\  edit(path, oldString, newString) - replace text in file and show numbered diff (requires unique match)
    \\All file paths must be relative to the current working directory.
    \\For large files, use offset and limit to read specific line ranges.
    \\When grep reports a match at line N, inspect it with read_file offset=N or offset=max(1, N-20). Never shorten line numbers such as 774 to 70.
    ;

pub fn run(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var stdout_buf: [8192]u8 = undefined;
        var stdout_file = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &stdout_buf);
        const stdout = &stdout_file.interface;
        defer stdout.flush() catch {};
    const stdin = std.Io.File.stdin().deprecatedReader();

    var messages = std.ArrayList(ollama.Message).empty;
    defer {
        for (messages.items) |message| allocator.free(message.content);
        messages.deinit(allocator);
    }

    try messages.append(allocator, .{ .role = .system, .content = try allocator.dupe(u8, system_prompt) });

    try stdout.print("zig-agent using {s} at {s}\nType /exit to quit.\n\n", .{ cfg.model, cfg.base_url });

    var input_buf: [16 * 1024]u8 = undefined;
    while (true) {
        try stdout.print("> ", .{});
        const input = try stdin.readUntilDelimiterOrEof(&input_buf, '\n') orelse break;
        const trimmed = std.mem.trim(u8, input, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "/exit") or std.mem.eql(u8, trimmed, "/quit")) break;

        try messages.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, trimmed) });
        try completeTurn(allocator, cfg, &messages);
    }
}

fn completeTurn(allocator: std.mem.Allocator, cfg: config.Config, messages: *std.ArrayList(ollama.Message)) !void {
    var stdout_buf: [8192]u8 = undefined;
        var stdout_file = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &stdout_buf);
        const stdout = &stdout_file.interface;
        defer stdout.flush() catch {};

    while (true) {
        const response = try ollama.chat(allocator, cfg, messages.items);
        try messages.append(allocator, .{ .role = .assistant, .content = response });

        var maybe_tool = try tools.parseToolRequest(allocator, response);
        if (maybe_tool) |*parsed| {
            defer parsed.deinit();
            const result = tools.execute(allocator, parsed.value) catch |err| try std.fmt.allocPrint(allocator, "Tool error: {s}", .{@errorName(err)});
            defer allocator.free(result);

            try stdout.print("\n[tool:{s}]\n{s}\n\n", .{ parsed.value.tool, result });
            const tool_message = try std.fmt.allocPrint(allocator, "Result from tool `{s}`. Use this result to continue; do not repeat the same tool call unless you need a different offset, limit, path, or pattern.\n{s}", .{ parsed.value.tool, result });
            try messages.append(allocator, .{ .role = .user, .content = tool_message });
            continue;
        }

        try stdout.print("\n{s}\n\n", .{response});
        return;
    }
}
