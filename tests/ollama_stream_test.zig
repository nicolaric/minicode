const std = @import("std");
const ollama = @import("ollama");

const TestState = struct {
    callbacks: usize = 0,
    done_callbacks: usize = 0,
    content: std.ArrayList(u8) = .empty,
    tool_call_chunks: usize = 0,

    fn deinit(self: *TestState, allocator: std.mem.Allocator) void {
        self.content.deinit(allocator);
    }
};

fn streamCallback(state: *TestState, chunk: ollama.StreamChunk) !void {
    state.callbacks += 1;
    if (chunk.done) state.done_callbacks += 1;
    if (chunk.content_delta.len > 0) {
        try state.content.appendSlice(std.testing.allocator, chunk.content_delta);
    }
    if (chunk.tool_calls) |calls| {
        state.tool_call_chunks += 1;
        ollama.freeToolCalls(std.testing.allocator, calls);
    }
}

fn neverCancel(_: *TestState) !bool {
    return false;
}

fn makeFakeCurl(script: []const u8) !struct { tmp: std.testing.TmpDir, path: []u8 } {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "curl",
        .data = script,
        .flags = .{ .permissions = .executable_file },
    });

    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/curl", .{tmp.sub_path});
    errdefer std.testing.allocator.free(path);
    return .{ .tmp = tmp, .path = path };
}

fn runChatStream(fake_curl_path: []const u8, state: *TestState) !void {
    const cfg = ollama.Config{ .base_url = "http://example.invalid", .model = "test-model" };
    const messages = [_]ollama.Message{.{ .role = .user, .content = "hello" }};
    try ollama.chatStreamWithCurl(
        std.testing.allocator,
        cfg,
        &messages,
        state,
        streamCallback,
        neverCancel,
        fake_curl_path,
        .off,
    );
}

fn monotonicNanos() u64 {
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts))) {
        .SUCCESS => return @intCast(@as(i128, ts.sec) * std.time.ns_per_s + ts.nsec),
        else => return 0,
    }
}

test "chatStream returns EmptyStreamResponse for empty curl stdout" {
    var fake = try makeFakeCurl(
        \\#!/bin/sh
        \\exit 0
        \\
    );
    defer fake.tmp.cleanup();
    defer std.testing.allocator.free(fake.path);

    var state = TestState{};
    defer state.deinit(std.testing.allocator);

    try std.testing.expectError(error.EmptyStreamResponse, runChatStream(fake.path, &state));
    try std.testing.expectEqual(@as(usize, 0), state.callbacks);
}

test "chatStream returns OllamaStreamFailed for failed empty curl stdout" {
    var fake = try makeFakeCurl(
        \\#!/bin/sh
        \\exit 22
        \\
    );
    defer fake.tmp.cleanup();
    defer std.testing.allocator.free(fake.path);

    var state = TestState{};
    defer state.deinit(std.testing.allocator);

    try std.testing.expectError(error.OllamaStreamFailed, runChatStream(fake.path, &state));
    try std.testing.expectEqual(@as(usize, 0), state.callbacks);
}

test "chatStream returns OllamaStreamIncomplete when stream has no done marker" {
    var fake = try makeFakeCurl(
        \\#!/bin/sh
        \\printf '%s\n' '{"message":{"content":"hello"},"done":false}'
        \\exit 0
        \\
    );
    defer fake.tmp.cleanup();
    defer std.testing.allocator.free(fake.path);

    var state = TestState{};
    defer state.deinit(std.testing.allocator);

    try std.testing.expectError(error.OllamaStreamIncomplete, runChatStream(fake.path, &state));
    try std.testing.expectEqual(@as(usize, 1), state.callbacks);
    try std.testing.expectEqualStrings("hello", state.content.items);
}

test "chatStream succeeds and invokes callback for normal done stream" {
    var fake = try makeFakeCurl(
        \\#!/bin/sh
        \\printf '%s\n' '{"message":{"content":"hello"},"done":false}' '{"message":{"content":""},"done":true}'
        \\exit 0
        \\
    );
    defer fake.tmp.cleanup();
    defer std.testing.allocator.free(fake.path);

    var state = TestState{};
    defer state.deinit(std.testing.allocator);

    try runChatStream(fake.path, &state);
    try std.testing.expectEqual(@as(usize, 2), state.callbacks);
    try std.testing.expectEqual(@as(usize, 1), state.done_callbacks);
    try std.testing.expectEqualStrings("hello", state.content.items);
}

test "chatStream returns promptly after done stream" {
    var fake = try makeFakeCurl(
        \\#!/bin/sh
        \\printf '%s\n' '{"message":{"content":""},"done":true}'
        \\sleep 5
        \\exit 0
        \\
    );
    defer fake.tmp.cleanup();
    defer std.testing.allocator.free(fake.path);

    var state = TestState{};
    defer state.deinit(std.testing.allocator);

    const start = monotonicNanos();
    try runChatStream(fake.path, &state);
    const elapsed = monotonicNanos() - start;

    try std.testing.expect(elapsed < 1 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(usize, 1), state.done_callbacks);
}

test "chatStream tolerates partial string tool arguments while streaming" {
    var fake = try makeFakeCurl(
        \\#!/bin/sh
        \\printf '%s\n' '{"message":{"tool_calls":[{"id":"call-1","function":{"name":"read_file","arguments":"{\"path\":"}}]},"done":false}' '{"message":{"content":""},"done":true}'
        \\exit 0
        \\
    );
    defer fake.tmp.cleanup();
    defer std.testing.allocator.free(fake.path);

    var state = TestState{};
    defer state.deinit(std.testing.allocator);

    try runChatStream(fake.path, &state);
    try std.testing.expectEqual(@as(usize, 1), state.tool_call_chunks);
    try std.testing.expectEqual(@as(usize, 1), state.done_callbacks);
}
