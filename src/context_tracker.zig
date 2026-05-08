const std = @import("std");

/// Tracks conversation context and generates periodic summaries
/// to help the agent maintain awareness during long sessions.
pub const ContextTracker = struct {
    round_count: usize,
    project_type: ?[]const u8,
    build_system: ?[]const u8,
    discoveries: std.ArrayList([]const u8),
    current_intent: ?[]const u8,
    allocator: std.mem.Allocator,

    /// Previous summary text for dedup
    last_summary: ?[]u8,

    pub const max_rounds_before_summary = 4;

    pub fn init(allocator: std.mem.Allocator) ContextTracker {
        return .{
            .round_count = 0,
            .project_type = null,
            .build_system = null,
            .discoveries = .empty,
            .current_intent = null,
            .allocator = allocator,
            .last_summary = null,
        };
    }

    pub fn deinit(self: *ContextTracker) void {
        for (self.discoveries.items) |d| self.allocator.free(d);
        self.discoveries.deinit(self.allocator);
        if (self.project_type) |v| self.allocator.free(v);
        if (self.build_system) |v| self.allocator.free(v);
        if (self.current_intent) |v| self.allocator.free(v);
        if (self.last_summary) |v| self.allocator.free(v);
    }

    pub fn reset(self: *ContextTracker) void {
        self.round_count = 0;
        for (self.discoveries.items) |d| self.allocator.free(d);
        self.discoveries.clearRetainingCapacity();
        if (self.project_type) |v| { self.allocator.free(v); self.project_type = null; }
        if (self.build_system) |v| { self.allocator.free(v); self.build_system = null; }
        if (self.current_intent) |v| { self.allocator.free(v); self.current_intent = null; }
        if (self.last_summary) |v| { self.allocator.free(v); self.last_summary = null; }
    }

    /// Record a tool execution to extract project context (not tool results)
    pub fn recordToolExecution(self: *ContextTracker, tool_name: []const u8, args: std.json.Value, result: []const u8) !void {
        self.round_count += 1;

        // Extract path and infer project type
        if (args == .object) {
            if (args.object.get("path")) |path_val| {
                if (path_val == .string) {
                    const path = path_val.string;
                    try self.inferProjectTypeAndBuildSystem(path);
                }
            }
        }

        // Record grep patterns as "looking for X" discoveries
        if (std.mem.eql(u8, tool_name, "grep") and !std.mem.startsWith(u8, result, "Error")) {
            if (args == .object) {
                if (args.object.get("pattern")) |p| {
                    if (p == .string and p.string.len > 0) {
                        const discovery = try std.fmt.allocPrint(
                            self.allocator, 
                            "Looking for '{s}'", 
                            .{p.string}
                        );
                        try self.addDiscovery(discovery);
                    }
                }
            }
        }

        // Record file modifications as "working on X"
        if (std.mem.eql(u8, tool_name, "edit") or std.mem.eql(u8, tool_name, "write_file")) {
            if (args == .object) {
                if (args.object.get("path")) |path_val| {
                    if (path_val == .string) {
                        const basename = std.fs.path.basename(path_val.string);
                        const discovery = try std.fmt.allocPrint(
                            self.allocator, 
                            "Working on file: {s}", 
                            .{basename}
                        );
                        try self.addDiscovery(discovery);
                    }
                }
            }
        }
    }

    /// Infer project type and build system from file paths
    fn inferProjectTypeAndBuildSystem(self: *ContextTracker, path: []const u8) !void {
        // Project type detection
        if (self.project_type == null) {
            const lang: ?[]const u8 = if (std.mem.endsWith(u8, path, ".zig"))
                "Zig"
            else if (std.mem.endsWith(u8, path, ".rs"))
                "Rust"
            else if (std.mem.endsWith(u8, path, ".py"))
                "Python"
            else if (std.mem.endsWith(u8, path, ".js") or std.mem.endsWith(u8, path, ".ts"))
                "TypeScript/JavaScript"
            else if (std.mem.endsWith(u8, path, ".go"))
                "Go"
            else if (std.mem.endsWith(u8, path, ".c") or std.mem.endsWith(u8, path, ".h"))
                "C"
            else if (std.mem.endsWith(u8, path, ".cpp") or std.mem.endsWith(u8, path, ".hpp"))
                "C++"
            else if (std.mem.endsWith(u8, path, ".java"))
                "Java"
            else if (std.mem.endsWith(u8, path, ".rb"))
                "Ruby"
            else if (std.mem.endsWith(u8, path, ".html"))
                "HTML"
            else if (std.mem.endsWith(u8, path, ".css"))
                "CSS"
            else if (std.mem.endsWith(u8, path, ".md"))
                "Markdown"
            else
                null;

            if (lang) |l| {
                self.project_type = try self.allocator.dupe(u8, l);
            }
        }

        // Build system detection
        if (self.build_system == null) {
            const bs: ?[]const u8 = if (std.mem.endsWith(u8, path, "build.zig"))
                "zig build"
            else if (std.mem.endsWith(u8, path, "Cargo.toml"))
                "cargo build"
            else if (std.mem.endsWith(u8, path, "package.json"))
                "npm/yarn"
            else if (std.mem.endsWith(u8, path, "go.mod"))
                "go build"
            else if (std.mem.endsWith(u8, path, "Makefile"))
                "make"
            else if (std.mem.endsWith(u8, path, "CMakeLists.txt"))
                "cmake"
            else if (std.mem.endsWith(u8, path, "requirements.txt") or std.mem.endsWith(u8, path, "pyproject.toml"))
                "pip/poetry"
            else
                null;

            if (bs) |b| {
                self.build_system = try self.allocator.dupe(u8, b);
            }
        }
    }

    fn addDiscovery(self: *ContextTracker, discovery: []const u8) !void {
        // Avoid duplicate discoveries
        for (self.discoveries.items) |existing| {
            if (std.mem.eql(u8, existing, discovery)) {
                self.allocator.free(discovery);
                return;
            }
        }
        try self.discoveries.append(self.allocator, discovery);
    }

    /// Check if it's time to generate a summary
    pub fn shouldGenerateSummary(self: *const ContextTracker) bool {
        return self.round_count > 0 and self.round_count % max_rounds_before_summary == 0;
    }

    pub fn generateSummary(self: *ContextTracker) !?[]u8 {
        var lines: std.ArrayList(u8) = .empty;
        defer lines.deinit(self.allocator);

        // Project info
        if (self.project_type) |pt| {
            try lines.appendSlice(self.allocator, pt);
            try lines.appendSlice(self.allocator, " project");
            if (self.build_system) |bs| {
                try lines.appendSlice(self.allocator, " (");
                try lines.appendSlice(self.allocator, bs);
                try lines.appendSlice(self.allocator, ")");
            }
            try lines.appendSlice(self.allocator, "\n");
        }

        // Current discoveries
        for (self.discoveries.items) |d| {
            try lines.appendSlice(self.allocator, d);
            try lines.appendSlice(self.allocator, "\n");
        }

        // Current intent (if not already in discoveries)
        if (self.current_intent) |intent| {
            var already_reported = false;
            for (self.discoveries.items) |d| {
                if (std.mem.eql(u8, d, intent)) { already_reported = true; break; }
            }
            if (!already_reported) {
                try lines.appendSlice(self.allocator, intent);
                try lines.appendSlice(self.allocator, "\n");
            }
        }

        const result = try lines.toOwnedSlice(self.allocator);

        // Skip if unchanged from last time
        if (self.last_summary) |prev| {
            if (std.mem.eql(u8, prev, result)) {
                self.allocator.free(result);
                return null;
            }
        }

        // Replace stored summary
        if (self.last_summary) |prev| self.allocator.free(prev);
        self.last_summary = try self.allocator.dupe(u8, result);
        return result;
    }

    /// Record thinking content to extract intent
    pub fn recordThinking(self: *ContextTracker, thinking: []const u8) void {
        self.round_count += 1;
        
        // Extract key intent phrases from thinking
        // Look for patterns like "I need to", "Looking for", "Trying to"
        const intent_phrases = [_][]const u8{
            "I need to ",
            "Looking for ",
            "Searching for ",
            "Trying to ",
            "Want to ",
            "Should ",
            "Need to find ",
            "Let me ",
        };
        
        for (intent_phrases) |phrase| {
            if (std.mem.indexOf(u8, thinking, phrase)) |idx| {
                const start = idx + phrase.len;
                const end = std.mem.indexOfAny(u8, thinking[start..], ".\n") orelse 
                           std.mem.indexOf(u8, thinking[start..], " and ") orelse
                           (thinking.len - start);
                
                if (end > 0 and end < 200) {
                    const intent = std.fmt.allocPrint(
                        self.allocator,
                        "Looking to {s}",
                        .{thinking[start .. start + end]}
                    ) catch return;
                    
                    // Update current intent
                    if (self.current_intent) |old| {
                        self.allocator.free(old);
                    }
                    self.current_intent = intent;
                    
                    // Also add as discovery
                    self.addDiscovery(intent) catch return;
                }
                break;
            }
        }
    }
};
