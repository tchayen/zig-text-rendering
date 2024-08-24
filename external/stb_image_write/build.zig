const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const module = b.addModule("stb_image_write", .{
        .root_source_file = b.path("stb_image_write.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addCSourceFiles(.{ .files = &[_][]const u8{"source/stb_image_write.c"} });
    module.addIncludePath(b.path("include"));
}
