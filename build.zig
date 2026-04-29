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
}
