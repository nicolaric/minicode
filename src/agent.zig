const std = @import("std");
const config = @import("config.zig");
const ollama = @import("ollama.zig");
const tools = @import("tools.zig");

pub const system_prompt =
    \\You are a coding assistant with LIMITED TOKENS. Be EXTREMELY concise.
    \\RULE 1: If you can answer or act immediately, DO IT NOW. No preamble, no plan.
    \\RULE 2: Use MAXIMUM 2 read_file calls, then YOU MUST EDIT. No exceptions.
    \\RULE 3: DO NOT explain your plan. DO NOT "understand" the code. Just edit.
    \\RULE 4: NO thinking tags. NO explanations. ONLY tool calls or code.
    \\RULE 5: When using tools, output ONLY the JSON. No text before or after.
    \\RULE 6: DO NOT verify your edit by reading the file again. Just continue.
    \\RULE 7: If the user asks a simple question, answer in 1 sentence max.
    \\RULE 8: Token budget: 500 for thinking, then you MUST act.
    \\
    \\JSON FORMAT: {"tool":"TOOL_NAME","args":{"param1":"value1"}}
    \\CORRECT: {"tool":"read_file","args":{"path":"src/main.zig"}}
    \\WRONG: Let me check the file... {"tool":"read_file"...}
    \\WRONG: {"tool":"grep","pattern":"foo","path":"src"}
    \\
    \\NAVIGATION: 1) grep to find line. 2) read ONCE at that offset (limit 60). 3) edit IMMEDIATELY.
    \\NEVER read "just a bit more." NEVER verify by reading again. Just edit.
    \\
    \\CONTEXT: Only last 4 conversation turns are kept in full. If you need to reference earlier file contents, use read_file again.
    \\
    \\Tools:
    \\  read_file(path, offset?, limit?) - read file lines
    \\  write_file(path, content) - write file
    \\  list_files(path) - list directory
    \\  run_shell(command) - run shell command (requires confirmation)
    \\  glob(pattern, path?) - find files
    \\  grep(pattern, path?, include?) - search files
    \\  edit(path, oldString, newString) - replace text
    \\
    \\All paths relative to working directory. When grep shows line N, use offset=N exactly.
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
                if (std.mem.eql(u8, request.tool, "edit")) {
                    try stdout.print("Patching file...\n\n", .{});
                    try messages.append(allocator, .{ .role = .assistant, .content = "Patching file...", .thinking = null, .tool_calls = null });
                }
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
            if (std.mem.eql(u8, parsed.value.tool, "edit")) {
                try stdout.print("Patching file...\n\n", .{});
                try messages.append(allocator, .{ .role = .assistant, .content = "Patching file...", .thinking = null, .tool_calls = null });
            }
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
