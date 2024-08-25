const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "plutosvg",
        .target = target,
        .optimize = optimize,
    });

    lib.linkLibC();
    lib.defineCMacro("PLUTOSVG_HAS_FREETYPE", "1");
    lib.defineCMacro("PLUTOVG_BUILD_STATIC", "1");
    lib.addIncludePath(b.path("include"));
    lib.addIncludePath(b.path("../plutovg/include"));
    lib.addIncludePath(b.path("../freetype/include"));
    // lib.addIncludePath(b.path("../stb"));
    lib.addCSourceFiles(.{ .files = &sources, .flags = &.{} });
    // lib.installHeadersDirectory(b.path("source"), "plutosvg", .{});

    const plutovg = b.dependency("plutovg", .{
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibrary(plutovg.artifact("plutovg"));

    b.installArtifact(lib);
}

const sources = [_][]const u8{
    "source/plutosvg.c",
};
