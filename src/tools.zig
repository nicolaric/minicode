const std = @import("std");

// Re-export all public types and functions from submodules
pub const core = @import("tools/core.zig");
pub const file_ops = @import("tools/file_ops.zig");
pub const search = @import("tools/search.zig");
pub const shell = @import("tools/shell.zig");
pub const diff = @import("tools/diff.zig");

// Core types and constants
pub const ToolRequest = core.ToolRequest;
pub const ConfirmFn = core.ConfirmFn;
pub const Confirm = core.Confirm;
pub const ShellStreamFn = core.ShellStreamFn;
pub const ShellStream = core.ShellStream;
pub const RegexError = search.RegexError;

// Constants
pub const max_read_lines = core.max_read_lines;
pub const max_grep_matches = core.max_grep_matches;
pub const max_logged_tool_output = core.max_logged_tool_output;

// Tool request parsing
pub const requestFromToolCall = core.requestFromToolCall;
pub const parseToolRequest = core.parseToolRequest;

// Tool execution
pub fn execute(allocator: std.mem.Allocator, req: ToolRequest, highlighter: ?*@import("syntax_highlight.zig").SyntaxHighlighter) ![]u8 {
    return executeWithConfirm(allocator, req, null, highlighter);
}

pub fn executeWithConfirm(allocator: std.mem.Allocator, req: ToolRequest, confirmer: ?Confirm, highlighter: ?*@import("syntax_highlight.zig").SyntaxHighlighter) ![]u8 {
    return executeWithStreaming(allocator, req, confirmer, highlighter, null);
}

pub fn executeWithStreaming(allocator: std.mem.Allocator, req: ToolRequest, confirmer: ?Confirm, highlighter: ?*@import("syntax_highlight.zig").SyntaxHighlighter, streamer: ?ShellStream) ![]u8 {
    if (std.mem.eql(u8, req.tool, "read_file")) return file_ops.readFile(allocator, core.getStringArg(req.args, "path") orelse return error.InvalidToolArgs, core.getUsizeArg(req.args, "offset"), core.getUsizeArg(req.args, "limit"));
    if (std.mem.eql(u8, req.tool, "write_file")) return file_ops.writeFile(
        allocator,
        core.getStringArg(req.args, "path") orelse return error.InvalidToolArgs,
        core.getStringArg(req.args, "content") orelse return error.InvalidToolArgs,
        confirmer,
        highlighter,
    );
    if (std.mem.eql(u8, req.tool, "list_files")) return file_ops.listFiles(allocator, core.getStringArg(req.args, "path") orelse ".");
    if (std.mem.eql(u8, req.tool, "run_shell")) return shell.runShellStreaming(allocator, core.getStringArg(req.args, "command") orelse return error.InvalidToolArgs, confirmer, streamer);
    if (std.mem.eql(u8, req.tool, "glob")) return search.globFiles(allocator, core.getStringArg(req.args, "pattern") orelse return error.InvalidToolArgs, core.getStringArg(req.args, "path"));
    if (std.mem.eql(u8, req.tool, "grep")) return search.grepFiles(
        allocator,
        core.getStringArg(req.args, "pattern") orelse return error.InvalidToolArgs,
        core.getStringArg(req.args, "path"),
        core.getStringArg(req.args, "include"),
        core.getBoolArg(req.args, "case_sensitive") orelse false,
        core.getUsizeArg(req.args, "context"),
    );
    if (std.mem.eql(u8, req.tool, "edit")) return file_ops.editFile(allocator, core.getStringArg(req.args, "path") orelse return error.InvalidToolArgs, core.getStringArg(req.args, "oldString") orelse return error.InvalidToolArgs, core.getStringArg(req.args, "newString") orelse return error.InvalidToolArgs, highlighter);
    return std.fmt.allocPrint(allocator, "Error: Unknown tool: {s}", .{req.tool});
}

// Logging functions
pub const logToolCall = core.logToolCall;
pub const logInvalidToolJson = core.logInvalidToolJson;
pub const logStreamFailure = core.logStreamFailure;

// Argument extraction helpers
pub const getStringArg = core.getStringArg;
pub const getUsizeArg = core.getUsizeArg;
pub const getBoolArg = core.getBoolArg;

// Utility functions
pub const confirm = core.confirm;
pub const resolveInsideCwd = core.resolveInsideCwd;
pub const hasParentTraversal = core.hasParentTraversal;
pub const relativeDisplayPath = core.relativeDisplayPath;
pub const stringifyJsonValue = core.stringifyJsonValue;
pub const stringifyJsonString = core.stringifyJsonString;

// File operations (for direct use)
pub const readFile = file_ops.readFile;
pub const writeFile = file_ops.writeFile;
pub const listFiles = file_ops.listFiles;
pub const editFile = file_ops.editFile;

// Search operations (for direct use)
pub const globFiles = search.globFiles;
pub const grepFiles = search.grepFiles;
pub const regexErrorAnsi = search.regexErrorAnsi;
pub const regexErrorName = search.regexErrorName;

// Shell operations (for direct use)
pub const runShell = shell.runShell;
pub const runShellStreaming = shell.runShellStreaming;

// Diff operations (for direct use)
pub const diffAlloc = diff.diffAlloc;
