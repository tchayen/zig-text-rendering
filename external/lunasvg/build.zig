const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "lunasvg",
        .target = target,
        .optimize = optimize,
    });

    lib.defineCMacro("LUNASVG_BUILD_STATIC", "");
    lib.installHeader(
        b.path("include/lunasvg.h"),
        "lunasvg-unconfigured.h",
    );
    const w = b.addWriteFiles();
    lib.installHeader(
        w.add("lunasvg.h", ("#define LUNASVG_BUILD_STATIC\n" ++
            "#include \"lunasvg-unconfigured.h\"\n")),
        "lunasvg.h",
    );

    const plutovg = b.dependency("plutovg", .{
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibrary(plutovg.artifact("plutovg"));

    lib.addCSourceFiles(.{
        .root = b.path("."),
        .files = &lunasvg_files,
    });

    lib.addIncludePath(b.path("include"));
    lib.addIncludePath(b.path("../plutovg/include"));

    lib.linkLibCpp();
    b.installArtifact(lib);
}

const lunasvg_files = [_][]const u8{
    "source/graphics.cpp",
    "source/lunasvg.cpp",
    "source/resource.cpp",
    "source/svgelement.cpp",
    "source/svggeometryelement.cpp",
    "source/svglayoutstate.cpp",
    "source/svgpaintelement.cpp",
    "source/svgparser.cpp",
    "source/svgproperty.cpp",
    "source/svgrenderstate.cpp",
};
