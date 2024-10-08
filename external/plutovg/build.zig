const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "plutovg",
        .target = target,
        .optimize = optimize,
    });

    lib.linkLibC();
    lib.defineCMacro("PLUTOVG_BUILD_STATIC", "1");
    lib.addIncludePath(b.path("include"));
    lib.addIncludePath(b.path("source"));
    lib.addIncludePath(b.path("stb"));
    lib.addCSourceFiles(.{ .files = &sources, .flags = &.{} });

    b.installArtifact(lib);
}

const sources = [_][]const u8{
    "source/plutovg-blend.c",
    "source/plutovg-canvas.c",
    "source/plutovg-font.c",
    "source/plutovg-ft-math.c",
    "source/plutovg-ft-raster.c",
    "source/plutovg-ft-stroker.c",
    "source/plutovg-matrix.c",
    "source/plutovg-paint.c",
    "source/plutovg-path.c",
    "source/plutovg-rasterize.c",
    "source/plutovg-surface.c",
};
