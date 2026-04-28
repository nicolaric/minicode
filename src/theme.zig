const std = @import("std");

pub const reset = "\x1b[0m";
pub const bold = "\x1b[1m";

pub const mocha = struct {
    pub const text = "\x1b[38;2;205;214;244m";
    pub const subtext0 = "\x1b[38;2;166;173;200m";
    pub const surface0 = "\x1b[38;2;49;50;68m";
    pub const blue = "\x1b[38;2;137;180;250m";
    pub const lavender = "\x1b[38;2;180;190;254m";
    pub const mauve = "\x1b[38;2;203;166;247m";
    pub const peach = "\x1b[38;2;250;179;135m";
    pub const green = "\x1b[38;2;166;227;161m";
    pub const yellow = "\x1b[38;2;249;226;175m";
    pub const red = "\x1b[38;2;243;139;168m";
    pub const surface0_bg = "\x1b[48;2;49;50;68m";
    pub const crust_bg = "\x1b[48;2;17;17;27m";
    pub const base_bg = "\x1b[48;2;30;30;46m";
    pub const mantle_bg = "\x1b[48;2;36;36;54m";
};

/// VSCode scope to Catppuccin Mocha color mapping
pub const vscode_scope_mappings = struct {
    // Primary scopes
    pub const keyword = mocha.mauve;
    pub const string = mocha.peach;
    pub const comment = mocha.subtext0;
    pub const number = mocha.peach;
    pub const function = mocha.blue;
    pub const type_name = mocha.mauve;
    pub const operator = mocha.red;
    pub const punctuation = mocha.subtext0;
    pub const variable = mocha.text;
    pub const constant = mocha.peach;
    pub const entity = mocha.text;
    pub const attribute = mocha.yellow;
    pub const tag = mocha.mauve;
    pub const markup = mocha.blue;
    pub const regex = mocha.red;

    // More specific scopes that map to base scopes
    pub const keyword_control = mocha.mauve;
    pub const keyword_operator = mocha.red;
    pub const string_quoted = mocha.peach;
    pub const comment_block = mocha.subtext0;
    pub const comment_line = mocha.subtext0;
    pub const constant_numeric = mocha.peach;
    pub const constant_language = mocha.peach;
    pub const entity_name_function = mocha.blue;
    pub const entity_name_type = mocha.mauve;
    pub const support_type = mocha.mauve;
    pub const support_function = mocha.blue;
    pub const variable_parameter = mocha.text;
    pub const variable_language = mocha.mauve;
    pub const storage_type = mocha.mauve;
    pub const storage_modifier = mocha.mauve;
};

/// Map a VSCode scope string to the appropriate Catppuccin color.
/// Falls back to mocha.text for unknown scopes.
pub fn scopeToColor(scope: []const u8) []const u8 {
    // Check for exact matches first by comparing against known scopes
    // Use a simple if-else chain since we can't easily iterate over struct fields at comptime
    if (std.mem.eql(u8, scope, "keyword")) return vscode_scope_mappings.keyword;
    if (std.mem.eql(u8, scope, "string")) return vscode_scope_mappings.string;
    if (std.mem.eql(u8, scope, "comment")) return vscode_scope_mappings.comment;
    if (std.mem.eql(u8, scope, "number")) return vscode_scope_mappings.number;
    if (std.mem.eql(u8, scope, "function")) return vscode_scope_mappings.function;
    if (std.mem.eql(u8, scope, "type_name")) return vscode_scope_mappings.type_name;
    if (std.mem.eql(u8, scope, "operator")) return vscode_scope_mappings.operator;
    if (std.mem.eql(u8, scope, "punctuation")) return vscode_scope_mappings.punctuation;
    if (std.mem.eql(u8, scope, "variable")) return vscode_scope_mappings.variable;
    if (std.mem.eql(u8, scope, "constant")) return vscode_scope_mappings.constant;
    if (std.mem.eql(u8, scope, "entity")) return vscode_scope_mappings.entity;
    if (std.mem.eql(u8, scope, "attribute")) return vscode_scope_mappings.attribute;
    if (std.mem.eql(u8, scope, "tag")) return vscode_scope_mappings.tag;
    if (std.mem.eql(u8, scope, "markup")) return vscode_scope_mappings.markup;
    if (std.mem.eql(u8, scope, "regex")) return vscode_scope_mappings.regex;
    if (std.mem.eql(u8, scope, "keyword_control")) return vscode_scope_mappings.keyword_control;
    if (std.mem.eql(u8, scope, "keyword_operator")) return vscode_scope_mappings.keyword_operator;
    if (std.mem.eql(u8, scope, "string_quoted")) return vscode_scope_mappings.string_quoted;
    if (std.mem.eql(u8, scope, "comment_block")) return vscode_scope_mappings.comment_block;
    if (std.mem.eql(u8, scope, "comment_line")) return vscode_scope_mappings.comment_line;
    if (std.mem.eql(u8, scope, "constant_numeric")) return vscode_scope_mappings.constant_numeric;
    if (std.mem.eql(u8, scope, "constant_language")) return vscode_scope_mappings.constant_language;
    if (std.mem.eql(u8, scope, "entity_name_function")) return vscode_scope_mappings.entity_name_function;
    if (std.mem.eql(u8, scope, "entity_name_type")) return vscode_scope_mappings.entity_name_type;
    if (std.mem.eql(u8, scope, "support_type")) return vscode_scope_mappings.support_type;
    if (std.mem.eql(u8, scope, "support_function")) return vscode_scope_mappings.support_function;
    if (std.mem.eql(u8, scope, "variable_parameter")) return vscode_scope_mappings.variable_parameter;
    if (std.mem.eql(u8, scope, "variable_language")) return vscode_scope_mappings.variable_language;
    if (std.mem.eql(u8, scope, "storage_type")) return vscode_scope_mappings.storage_type;
    if (std.mem.eql(u8, scope, "storage_modifier")) return vscode_scope_mappings.storage_modifier;

    // Check for prefix matches (hierarchical scopes)
    if (std.mem.startsWith(u8, scope, "keyword.control.") or std.mem.eql(u8, scope, "keyword.control")) {
        return vscode_scope_mappings.keyword_control;
    }
    if (std.mem.startsWith(u8, scope, "keyword.operator.") or std.mem.eql(u8, scope, "keyword.operator")) {
        return vscode_scope_mappings.keyword_operator;
    }
    if (std.mem.startsWith(u8, scope, "string.") or std.mem.eql(u8, scope, "string")) {
        return vscode_scope_mappings.string_quoted;
    }
    if (std.mem.startsWith(u8, scope, "comment.")) {
        return vscode_scope_mappings.comment_block;
    }
    if (std.mem.eql(u8, scope, "comment")) {
        return vscode_scope_mappings.comment_line;
    }
    if (std.mem.startsWith(u8, scope, "constant.numeric.") or std.mem.eql(u8, scope, "constant.numeric")) {
        return vscode_scope_mappings.constant_numeric;
    }
    if (std.mem.startsWith(u8, scope, "constant.language.") or std.mem.eql(u8, scope, "constant.language")) {
        return vscode_scope_mappings.constant_language;
    }
    if (std.mem.startsWith(u8, scope, "entity.name.function.") or std.mem.eql(u8, scope, "entity.name.function")) {
        return vscode_scope_mappings.entity_name_function;
    }
    if (std.mem.startsWith(u8, scope, "entity.name.type.") or std.mem.eql(u8, scope, "entity.name.type")) {
        return vscode_scope_mappings.entity_name_type;
    }
    if (std.mem.startsWith(u8, scope, "support.type.") or std.mem.eql(u8, scope, "support.type")) {
        return vscode_scope_mappings.support_type;
    }
    if (std.mem.startsWith(u8, scope, "support.function.") or std.mem.eql(u8, scope, "support.function")) {
        return vscode_scope_mappings.support_function;
    }
    if (std.mem.startsWith(u8, scope, "variable.parameter.") or std.mem.eql(u8, scope, "variable.parameter")) {
        return vscode_scope_mappings.variable_parameter;
    }
    if (std.mem.startsWith(u8, scope, "variable.language.") or std.mem.eql(u8, scope, "variable.language")) {
        return vscode_scope_mappings.variable_language;
    }
    if (std.mem.startsWith(u8, scope, "storage.type.") or std.mem.eql(u8, scope, "storage.type")) {
        return vscode_scope_mappings.storage_type;
    }
    if (std.mem.startsWith(u8, scope, "storage.modifier.") or std.mem.eql(u8, scope, "storage.modifier")) {
        return vscode_scope_mappings.storage_modifier;
    }

    // Default fallback
    return mocha.text;
}
