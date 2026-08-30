const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lc86K_mod = b.createModule(.{
        .root_source_file = b.path("lc86K.zig"),
        .target = target,
        .optimize = optimize,
    });

    const decode_mod = b.createModule(.{
        .root_source_file = b.path("decode.zig"),
        .target = target,
        .optimize = optimize,
    });
    decode_mod.addImport("lc86K", lc86K_mod);

    const debug_mod = b.createModule(.{
        .root_source_file = b.path("debug.zig"),
        .target = target,
        .optimize = optimize,
    });
    debug_mod.addImport("lc86K", lc86K_mod);

    decode_mod.addImport("debug", debug_mod);

    const main_mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("lc86K", lc86K_mod);
    main_mod.addImport("decode", decode_mod);
    main_mod.addImport("debug", debug_mod);

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });

    const raylib = raylib_dep.module("raylib");
    const raylib_artifact = raylib_dep.artifact("raylib");

    main_mod.addImport("raylib", raylib);

    const exe = b.addExecutable(.{
        .name = "lc86K",
        .root_module = main_mod,
    });
    exe.root_module.linkLibrary(raylib_artifact);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("lc86K", lc86K_mod);
    test_mod.addImport("decode", decode_mod);

    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&run_tests.step);
}
