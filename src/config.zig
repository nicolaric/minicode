const std = @import("std");

pub const default_base_url = "http://127.0.0.1:11434";
pub const default_model = "qwen3.6:27b-coding-nvfp4";

pub const Config = struct {
    base_url: []const u8,
    model: []const u8,
    model_explicit: bool = false,
};

pub const Loaded = struct {
    config: Config,
    owned_base_url: ?[]u8 = null,
    owned_model: ?[]u8 = null,

    pub fn deinit(self: *Loaded, allocator: std.mem.Allocator) void {
        if (self.owned_base_url) |value| allocator.free(value);
        if (self.owned_model) |value| allocator.free(value);
    }
};

fn getEnvVar(name: []const u8) ?[]const u8 {
    // Iterate through environ to find the variable
    var i: usize = 0;
    while (std.c.environ[i]) |ptr| : (i += 1) {
        const env_str = std.mem.sliceTo(ptr, 0);
        if (std.mem.startsWith(u8, env_str, name)) {
            if (env_str.len > name.len and env_str[name.len] == '=') {
                return env_str[name.len + 1..];
            }
        }
    }
    return null;
}

pub fn hasEnvVar(name: []const u8) bool {
    return getEnvVar(name) != null;
}

pub fn load(allocator: std.mem.Allocator) !Loaded {
    var loaded = Loaded{ .config = .{
        .base_url = default_base_url,
        .model = default_model,
        .model_explicit = false,
    } };
    errdefer loaded.deinit(allocator);

    if (try loadFileConfig(allocator)) |file_config| {
        loaded = file_config;
    }

    if (getEnvVar("OLLAMA_BASE_URL")) |base_url| {
        if (loaded.owned_base_url) |value| {
            allocator.free(value);
            loaded.owned_base_url = null;
        }
        loaded.config.base_url = base_url;
    }
    if (getEnvVar("OLLAMA_MODEL")) |model| {
        if (loaded.owned_model) |value| {
            allocator.free(value);
            loaded.owned_model = null;
        }
        loaded.config.model = model;
        loaded.config.model_explicit = true;
    }

    return loaded;
}

fn loadFileConfig(allocator: std.mem.Allocator) !?Loaded {
    const paths = try configPaths(allocator);
    defer {
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }

    for (paths) |path| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => continue,
        };
        defer allocator.free(bytes);
        return try parseFileConfig(allocator, bytes);
    }
    return null;
}

fn configPaths(allocator: std.mem.Allocator) ![][]u8 {
    const base = if (getEnvVar("XDG_CONFIG_HOME")) |xdg|
        try allocator.dupe(u8, xdg)
    else blk: {
        const home = getEnvVar("HOME") orelse return try allocator.alloc([]u8, 0);
        break :blk try std.fs.path.join(allocator, &.{ home, ".config" });
    };
    defer allocator.free(base);

    const paths = try allocator.alloc([]u8, 1);
    errdefer allocator.free(paths);
    paths[0] = try std.fs.path.join(allocator, &.{ base, "minicode", "config.json" });
    return paths;
}

fn parseFileConfig(allocator: std.mem.Allocator, bytes: []const u8) !Loaded {
    var loaded = Loaded{ .config = .{
        .base_url = default_base_url,
        .model = default_model,
        .model_explicit = false,
    } };
    errdefer loaded.deinit(allocator);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return loaded;

    const root = parsed.value.object;
    if (jsonString(root.get("base_url") orelse root.get("ollama_base_url"))) |value| {
        loaded.owned_base_url = try allocator.dupe(u8, value);
        loaded.config.base_url = loaded.owned_base_url.?;
    }
    if (jsonString(root.get("model") orelse root.get("default_model") orelse root.get("ollama_model"))) |value| {
        loaded.owned_model = try allocator.dupe(u8, value);
        loaded.config.model = loaded.owned_model.?;
        loaded.config.model_explicit = true;
    }

    return loaded;
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const actual = value orelse return null;
    if (actual != .string or actual.string.len == 0) return null;
    return actual.string;
}
