const std = @import("std");
const config = @import("config.zig");
const ollama = @import("ollama.zig");
const tools = @import("tools.zig");

pub const system_prompt =
    \\You are an expert coding assistant. You help users by reading files, executing
    \\commands, editing code, and writing new files.
    \\
    \\Be concise in your responses.
    \\Show file paths clearly when working with files.
    \\
    \\All paths must be relative to the working directory.
    ;

/// Tool descriptions for the model - passed via tool result messages when needed
pub const tool_descriptions =
    \\Tools you can use:
    \\- read_file(path, offset?, limit?): Read file lines. offset starts at 1, limit defaults to 300.
    \\- write_file(path, content): Write or create a file.
    \\- edit(path, oldString, newString): Replace unique text in a file.
    \\- run_shell(command): Execute a shell command (requires confirmation).
    \\- glob(pattern, path?): Find files matching a glob pattern.
    \\- grep(pattern, path?, include?): Search file contents with regex.
    \\- list_files(path?): List directory contents.
    \\
    \\Output tool calls as JSON: {"tool":"TOOL_NAME","args":{"param":"value"}}
    ;

pub fn systemPromptAlloc(allocator: std.mem.Allocator) ![]u8 {
    const agents = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, "AGENTS.md", allocator, .limited(128 * 1024)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ system_prompt, tool_descriptions }),
        else => return err,
    };
    defer allocator.free(agents);

    return std.fmt.allocPrint(allocator,
        \\{s}
        \\
        \\{s}
        \\
        \\WORKSPACE INSTRUCTIONS FROM AGENTS.md:
        \\{s}
    , .{ system_prompt, tool_descriptions, agents });
}

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

    try messages.append(allocator, .{ .role = .system, .content = try systemPromptAlloc(allocator) });

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
    const thinking_level = cfg.thinking_level;
    var stdout_buf: [8192]u8 = undefined;
        var stdout_file = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &stdout_buf);
        const stdout = &stdout_file.interface;
        defer stdout.flush() catch {};

    while (true) {
        const response = try ollama.chat(allocator, cfg, messages.items, thinking_level);
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
                const tool_name = try allocator.dupe(u8, request.tool);
                const tool_call_id = if (call.id) |id| try allocator.dupe(u8, id) else null;
                try messages.append(allocator, .{
                    .role = .tool,
                    .content = tool_message,
                    .tool_name = tool_name,
                    .tool_call_id = tool_call_id,
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
