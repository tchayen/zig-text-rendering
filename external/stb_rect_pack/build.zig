const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const module = b.addModule("stb_rect_pack", .{
        .root_source_file = b.path("stb_rect_pack.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addCSourceFiles(.{ .files = &[_][]const u8{"source/stb_rect_pack.c"} });
    module.addIncludePath(b.path("include"));
}
