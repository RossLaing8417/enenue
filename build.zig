const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "enenue",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    addDependencies(b, exe, target, optimize);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    addDependencies(b, exe_unit_tests, target, optimize);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    const check_exe = b.addExecutable(.{
        .name = exe.name,
        .root_source_file = exe.root_module.root_source_file,
        .target = target,
        .optimize = optimize,
    });
    addDependencies(b, check_exe, target, optimize);
    const check_step = b.step("check", "Syntax check");
    check_step.dependOn(&check_exe.step);
}

fn addDependencies(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const zap = b.dependency("zap", .{
        .target = target,
        .optimize = optimize,
    });
    artifact.root_module.addImport("zap", zap.module("zap"));
    const ziglua = b.dependency("ziglua", .{
        .target = target,
        .optimize = optimize,
        .lang = .luajit,
    });
    artifact.root_module.addImport("ziglua", ziglua.module("ziglua"));
}
