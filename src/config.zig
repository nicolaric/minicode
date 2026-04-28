const std = @import("std");

pub const default_base_url = "http://127.0.0.1:11434";
pub const default_model = "qwen3.6:27b-coding-nvfp4";

pub const Config = struct {
    base_url: []const u8,
    model: []const u8,
    syntax_highlighting: bool,
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

pub fn load() Config {
    const syntax_env = getEnvVar("NIC_SYNTAX_HIGHLIGHTING") orelse "true";
    const syntax_highlighting = std.ascii.eqlIgnoreCase(syntax_env, "true") or std.ascii.eqlIgnoreCase(syntax_env, "1") or std.ascii.eqlIgnoreCase(syntax_env, "yes");
    return .{
        .base_url = getEnvVar("OLLAMA_BASE_URL") orelse default_base_url,
        .model = getEnvVar("OLLAMA_MODEL") orelse default_model,
        .syntax_highlighting = syntax_highlighting,
    };
}
