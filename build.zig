const std = @import("std");
const build_icu4zig = @import("icu4zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zig-test-layout",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // zgpu
    @import("zgpu").addLibraryPathsTo(exe);
    const zgpu = b.dependency("zgpu", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("zgpu", zgpu.module("root"));
    exe.linkLibrary(zgpu.artifact("zdawn"));

    // zglfw
    const zglfw = b.dependency("zglfw", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("zglfw", zglfw.module("root"));
    exe.linkLibrary(zglfw.artifact("glfw"));

    // zmath
    const zmath = b.dependency("zmath", .{
        .target = target,
        .optimize = optimize,
        .enable_cross_platform_determinism = false,
    });
    exe.root_module.addImport("zmath", zmath.module("root"));

    // mach-freetype
    const mach_freetype = b.dependency("mach_freetype", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("mach-freetype", mach_freetype.module("mach-freetype"));
    exe.root_module.addImport("mach-harfbuzz", mach_freetype.module("mach-harfbuzz"));

    // icu4zig
    const icu4zig = b.dependency("icu4zig", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("icu4zig", icu4zig.module("icu4zig"));

    const icu4x = icu4zig.builder.dependency("icu4x", .{
        .target = target,
        .optimize = optimize,
    });
    build_icu4zig.link(exe, icu4x);

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

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
