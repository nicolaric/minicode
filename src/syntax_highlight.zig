const std = @import("std");
const theme = @import("theme.zig");
const syntax = @import("syntax");

const max_file_size = 100 * 1024; // 100KB - skip highlighting larger files
const max_cached_languages = 10;

/// Maximum length for a single highlighted line (prevents runaway allocations)
const max_highlighted_line_len = 10 * 1024;

/// Syntax highlighting manager that wraps flow-syntax.
/// Provides a simple API for highlighting code content with Catppuccin colors.
pub const SyntaxHighlighter = struct {
    allocator: std.mem.Allocator,
    query_cache: *syntax.QueryCache,
    language_cache: std.StringHashMapUnmanaged(*CachedSyntax),
    io: std.Io,

    const CachedSyntax = struct {
        syntax: *syntax,
    };

    /// Initialize a new SyntaxHighlighter
    pub fn create(allocator: std.mem.Allocator) !*SyntaxHighlighter {
        const self = try allocator.create(SyntaxHighlighter);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .query_cache = try syntax.QueryCache.create(std.Options.debug_io, allocator, .{}),
            .language_cache = .{},
            .io = std.Options.debug_io,
        };

        return self;
    }

    /// Clean up the SyntaxHighlighter and all cached resources
    pub fn destroy(self: *SyntaxHighlighter) void {
        var iter = self.language_cache.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.syntax.destroy();
            self.allocator.free(entry.key_ptr.*);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.language_cache.deinit(self.allocator);
        self.query_cache.deinit();
        self.allocator.destroy(self);
    }

    /// Get or create a syntax instance for the given language
    fn getSyntax(self: *SyntaxHighlighter, lang_name: []const u8) !*syntax {
        // Check cache first
        if (self.language_cache.get(lang_name)) |cached| {
            return cached.syntax;
        }

        // Evict first entry if cache is full
        if (self.language_cache.count() >= max_cached_languages) {
            var iter = self.language_cache.iterator();
            if (iter.next()) |entry| {
                const key_to_remove = entry.key_ptr.*;
                entry.value_ptr.*.syntax.destroy();
                self.allocator.destroy(entry.value_ptr.*);
                _ = self.language_cache.remove(key_to_remove);
                self.allocator.free(key_to_remove);
            }
        }

        // Create new syntax instance
        const file_type = syntax.FileType.get_by_name_static(lang_name) orelse {
            return error.LanguageNotSupported;
        };

        const syn = try syntax.create(file_type, self.allocator, self.query_cache);
        errdefer syn.destroy();

        // Cache it
        const lang_name_copy = try self.allocator.dupe(u8, lang_name);
        errdefer self.allocator.free(lang_name_copy);

        const cached = try self.allocator.create(CachedSyntax);
        cached.* = .{
            .syntax = syn,
        };

        try self.language_cache.put(self.allocator, lang_name_copy, cached);
        return syn;
    }

    /// Detect language from file extension or content heuristics
    /// Returns null if language cannot be detected
    pub fn detectLanguage(file_hint: ?[]const u8, content: []const u8) ?[]const u8 {
        // First try file hint (path or explicit language name)
        if (file_hint) |hint| {
            // Check if it's a direct language name
            if (syntax.FileType.get_by_name_static(hint)) |_| {
                return hint;
            }

            // Try to detect from file path
            if (syntax.FileType.guess_static(hint, content)) |ft| {
                return ft.name;
            }
        }

        // Try content-based detection
        if (syntax.FileType.guess_static(null, content)) |ft| {
            return ft.name;
        }

        return null;
    }

    /// Highlight a single line of code, returning ANSI-escaped string.
    /// The output uses Catppuccin Mocha colors based on VSCode scopes.
    /// Returns plain text on error.
    pub fn highlightLine(self: *SyntaxHighlighter, lang_name: []const u8, content: []const u8) ![]u8 {
        if (content.len > max_file_size or content.len == 0) {
            return self.allocator.dupe(u8, content);
        }

        const syn = self.getSyntax(lang_name) catch {
            return self.allocator.dupe(u8, content);
        };

        try syn.refresh_full(content);
        return self.highlightLineContent(syn, content, 0);
    }

    /// Highlight multiple lines of code.
    /// Returns a list of highlighted lines, each with ANSI escapes.
    pub fn highlightLines(self: *SyntaxHighlighter, lang_name: []const u8, content: []const u8) ![]const []u8 {
        if (content.len > max_file_size) {
            // Return plain lines for large files
            var lines: std.ArrayList([]u8) = .empty;
            errdefer {
                for (lines.items) |line| self.allocator.free(line);
                lines.deinit(self.allocator);
            }
            var it = std.mem.splitScalar(u8, content, '\n');
            while (it.next()) |line| {
                try lines.append(self.allocator, try self.allocator.dupe(u8, line));
            }
            return lines.toOwnedSlice(self.allocator);
        }

        const syn = self.getSyntax(lang_name) catch {
            // Fall back to plain text
            var lines: std.ArrayList([]u8) = .empty;
            errdefer {
                for (lines.items) |line| self.allocator.free(line);
                lines.deinit(self.allocator);
            }
            var it = std.mem.splitScalar(u8, content, '\n');
            while (it.next()) |line| {
                try lines.append(self.allocator, try self.allocator.dupe(u8, line));
            }
            return lines.toOwnedSlice(self.allocator);
        };

        try syn.refresh_full(content);

        // Build the full highlighted content with ANSI codes
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);

        // Define state for the render callback
        const State = struct {
            result: *std.ArrayList(u8),
            content: []const u8,
            allocator: std.mem.Allocator,
            last_end: usize = 0,
            
            fn callback(ctx: *@This(), range: syntax.Range, scope: []const u8, _id: u32, _capture_idx: usize, _node: *const syntax.Node) error{Stop}!void {
                _ = _id;
                _ = _capture_idx;
                _ = _node;
                
                // Tree-sitter queries can produce overlapping captures. Render each
                // byte once so broader captures do not duplicate highlighted text.
                if (range.end_byte <= ctx.last_end) return;

                const start = @max(ctx.last_end, range.start_byte);

                // Add plain text before this highlight
                if (ctx.last_end < start) {
                    ctx.result.appendSlice(ctx.allocator, ctx.content[ctx.last_end..start]) catch return error.Stop;
                }
                
                // Get color for this scope
                const color = theme.scopeToColor(scope);
                if (color.len > 0) {
                    ctx.result.appendSlice(ctx.allocator, color) catch return error.Stop;
                }
                
                // Add highlighted text
                ctx.result.appendSlice(ctx.allocator, ctx.content[start..range.end_byte]) catch return error.Stop;
                
                // Reset color
                if (color.len > 0) {
                    ctx.result.appendSlice(ctx.allocator, theme.reset) catch return error.Stop;
                }
                
                ctx.last_end = range.end_byte;
            }
        };

        var state = State{
            .result = &result,
            .content = content,
            .allocator = self.allocator,
        };

        // Render highlights for full content
        syn.render(&state, State.callback, null) catch {
            // On error, return plain lines
            var lines: std.ArrayList([]u8) = .empty;
            errdefer {
                for (lines.items) |line| self.allocator.free(line);
                lines.deinit(self.allocator);
            }
            var it = std.mem.splitScalar(u8, content, '\n');
            while (it.next()) |line| {
                try lines.append(self.allocator, try self.allocator.dupe(u8, line));
            }
            return lines.toOwnedSlice(self.allocator);
        };

        // Add remaining plain text
        if (state.last_end < content.len) {
            try result.appendSlice(self.allocator, content[state.last_end..]);
        }

        // Split the highlighted result into lines
        var lines: std.ArrayList([]u8) = .empty;
        errdefer {
            for (lines.items) |line| self.allocator.free(line);
            lines.deinit(self.allocator);
        }

        const highlighted_content = try result.toOwnedSlice(self.allocator);
        defer self.allocator.free(highlighted_content);

        var line_start: usize = 0;
        while (line_start <= highlighted_content.len) {
            // Find the newline in the highlighted content
            // Newlines don't have ANSI codes, so we can just scan for \n
            const newline_pos = std.mem.indexOfScalar(u8, highlighted_content[line_start..], '\n');
            
            if (newline_pos) |pos| {
                const line_end = line_start + pos;
                // Include the line content (without the newline)
                const line_content = highlighted_content[line_start..line_end];
                try lines.append(self.allocator, try self.allocator.dupe(u8, line_content));
                // Move past the newline
                line_start = line_end + 1;
            } else {
                // Last line (or no newlines)
                if (line_start < highlighted_content.len) {
                    const line_content = highlighted_content[line_start..];
                    try lines.append(self.allocator, try self.allocator.dupe(u8, line_content));
                } else if (lines.items.len == 0 or content.len == 0) {
                    // Empty content case - add empty line
                    try lines.append(self.allocator, try self.allocator.dupe(u8, ""));
                }
                break;
            }
        }

        return lines.toOwnedSlice(self.allocator);
    }
};
