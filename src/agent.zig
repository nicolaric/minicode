const std = @import("std");
const config = @import("config.zig");
const ollama = @import("ollama.zig");
const tools = @import("tools.zig");

pub const system_prompt =
    \\You are a coding assistant.
    \\PRIMARY GOAL: EDIT THE CODE. When the user asks for a change, your ONLY job is to modify the code. DO NOT analyze. DO NOT explain. DO NOT "understand fully." Just locate and edit.
    \\MAXIMUM 2 READ_FILE CALLS before you MUST use edit or write_file. No exceptions.
    \\When you need information, use the provided tools.
    \\DO NOT output thinking or explanations when using tools.
    \\DO NOT keep reading files "to be sure" or "to understand better." If you know where the change goes, EDIT IMMEDIATELY.
    \\If structured tool calling is unavailable, fall back to outputting ONLY valid JSON.
    \\JSON FALLBACK FORMAT: {"tool":"TOOL_NAME","args":{"param1":"value1","param2":"value2"}}
    \\All tool parameters MUST be inside the "args" object, NOT at the top level.
    \\CORRECT: {"tool":"read_file","args":{"path":"src/main.zig"}}
    \\CORRECT: {"tool":"grep","args":{"pattern":"foo","path":"src"}}
    \\WRONG: {"tool":"grep","pattern":"foo","path":"src"}
    \\WRONG: Let me check the file... {"tool":"read_file"...}
    \\NAVIGATION RULES: 1) Use grep to find line numbers. 2) Read ONCE at the grep line with limit 60. 3) Immediately use edit. 4) NEVER read more than twice before editing. 5) NEVER use offset=10, 11, 12 repeatedly. 6) If read_file fails, fix it once then EDIT.
    \\EDITING RULES: Locate the function. Read ±30 lines. EDIT IMMEDIATELY. Do not read "just a bit more." Do not verify by reading again. Just edit.
    \\STOP ANALYZING. START EDITING.
    \\Do not use run_shell for file navigation, line counts, grep, cat, find, or ls. Use read_file, grep, glob, and list_files instead.
    \\Tools:
    \\  read_file(path, offset?, limit?) - read 300 numbered file lines; offset defaults to line 1
    \\  write_file(path, content) - write file (shows numbered diff if overwriting)
    \\  list_files(path) - list directory contents
    \\  run_shell(command) - run non-file shell commands only; requires confirmation
    \\  glob(pattern, path?) - find files by pattern (e.g., "**/*.zig")
    \\  grep(pattern, path?, include?, case_sensitive?) - search file contents with line numbers; case-insensitive by default; supports basic regex
    \\  edit(path, oldString, newString) - replace text in file and show numbered diff (requires unique match)
    \\All file paths must be relative to the current working directory.
    \\For large files, use offset and limit to read specific line ranges.
    \\When grep reports a match at line N, inspect it with read_file offset=N exactly. Never shorten, round, or drop digits from line numbers: 1680 means offset=1680, NOT 168, 160, or 180.
    ;

pub fn run(allocator: std.mem.Allocator, cfg: config.Config) !void {
    var stdout_buf: [8192]u8 = undefined;
        var stdout_file = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &stdout_buf);
        const stdout = &stdout_file.interface;
        defer stdout.flush() catch {};
    const stdin = std.Io.File.stdin().deprecatedReader();

    var messages = std.ArrayList(ollama.Message).empty;
    defer {
        for (messages.items) |message| {
            allocator.free(message.content);
            if (message.thinking) |thinking| allocator.free(thinking);
            if (message.tool_calls) |tool_calls| ollama.freeToolCalls(allocator, tool_calls);
            if (message.tool_name) |tool_name| allocator.free(tool_name);
            if (message.tool_call_id) |tool_call_id| allocator.free(tool_call_id);
        }
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
        try messages.append(allocator, .{ .role = .assistant, .content = response.content, .thinking = response.thinking, .tool_calls = response.tool_calls });

        if (response.tool_calls) |tool_calls| {
            for (tool_calls) |call| {
                const request = tools.requestFromToolCall(call);
                const result = tools.execute(allocator, request, null) catch |err| try std.fmt.allocPrint(allocator, "Tool error: {s}", .{@errorName(err)});
                defer allocator.free(result);
                tools.logToolCall(allocator, request, result);

                try stdout.print("\n[tool:{s}]\n{s}\n\n", .{ request.tool, result });
                const tool_message = try std.fmt.allocPrint(allocator, "Result from tool `{s}`. Use this result to continue; do not repeat the same tool call unless you need a different offset, limit, path, or pattern.\n{s}", .{ request.tool, result });
                errdefer allocator.free(tool_message);
                try messages.append(allocator, .{
                    .role = .tool,
                    .content = tool_message,
                    .tool_name = try allocator.dupe(u8, request.tool),
                    .tool_call_id = if (call.id) |id| try allocator.dupe(u8, id) else null,
                });
            }
            continue;
        }

        var maybe_tool = try tools.parseToolRequest(allocator, response.content);
        if (maybe_tool) |*parsed| {
            defer parsed.deinit();
            const result = tools.execute(allocator, parsed.value, null) catch |err| try std.fmt.allocPrint(allocator, "Tool error: {s}", .{@errorName(err)});
            defer allocator.free(result);
            tools.logToolCall(allocator, parsed.value, result);

            try stdout.print("\n[tool:{s}]\n{s}\n\n", .{ parsed.value.tool, result });
            const tool_message = try std.fmt.allocPrint(allocator, "Result from tool `{s}`. Use this result to continue; do not repeat the same tool call unless you need a different offset, limit, path, or pattern.\n{s}", .{ parsed.value.tool, result });
            try messages.append(allocator, .{ .role = .user, .content = tool_message });
            continue;
        }

        try stdout.print("\n{s}\n\n", .{response.content});
        return;
    }
}
