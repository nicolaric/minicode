const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add flow-syntax dependency
    const flow_syntax_dep = b.dependency("flow_syntax", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "minicode",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add syntax module from flow-syntax
    // The syntax module internally includes the syntax_bin_queries via anonymous import
    exe.root_module.addImport("syntax", flow_syntax_dep.module("syntax"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run minicode");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/ollama_stream_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("ollama", b.createModule(.{
        .root_source_file = b.path("src/ollama.zig"),
        .target = target,
        .optimize = optimize,
    }));

    const run_unit_tests = b.addRunArtifact(unit_tests);
    
    // Shell execution tests
    const shell_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/shell_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    
    // Create tools module with all required imports
    const tools_module = b.createModule(.{
        .root_source_file = b.path("src/tools.zig"),
        .target = target,
        .optimize = optimize,
    });
    tools_module.addImport("syntax", flow_syntax_dep.module("syntax"));
    
    shell_tests.root_module.addImport("tools", tools_module);
    shell_tests.root_module.addImport("ollama", b.createModule(.{
        .root_source_file = b.path("src/ollama.zig"),
        .target = target,
        .optimize = optimize,
    }));
    shell_tests.root_module.addImport("syntax", flow_syntax_dep.module("syntax"));

    const run_shell_tests = b.addRunArtifact(shell_tests);
    
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_shell_tests.step);
    
    const shell_test_step = b.step("test-shell", "Run shell execution tests only");
    shell_test_step.dependOn(&run_shell_tests.step);
}
