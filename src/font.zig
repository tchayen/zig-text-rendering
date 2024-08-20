const std = @import("std");
const zgpu = @import("zgpu");
const ft = @import("mach-freetype");
const hb = @import("mach-harfbuzz");
const pack_atlas = @import("pack_atlas.zig");

pub const Bitmap = struct {
    width: u32,
    height: u32,
};

pub const FontAtlas = struct {
    bitmap: Bitmap,
    positions: [][]f32,
};

// In pixels.
pub const GlyphRendering = struct {
    position: [2]u32,
    size: [2]u32,
};

const HARFBUZZ_FACTOR = 64.0;

const GlyphMap = std.AutoHashMap(u32, GlyphRendering);

const latin = @embedFile("./assets/NotoSans-Regular.ttf");
const jp = @embedFile("./assets/NotoSansJP-Regular.ttf");
const kr = @embedFile("./assets/NotoSansKR-Regular.ttf");
const emoji = @embedFile("./assets/NotoColorEmoji-Regular.ttf");

/// Font encapsulates FreeType and HarfBuzz logic for shaping text. Generates font atlas texture in the `init()` method. Initialize it with a font file binary data.
pub const TextRendering = struct {
    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    ft_lib: ft.Library,
    ft_face: ft.Face,
    hb_font: hb.Font,
    atlas_texture: zgpu.TextureHandle,
    atlas_size: u32,
    glyph_map: GlyphMap,

    pub fn init(allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext) !TextRendering {
        const ft_lib = try ft.Library.init();
        const ft_face = try ft_lib.createFaceMemory(latin, 0);
        _ = try ft_lib.createFaceMemory(jp, 0);
        _ = try ft_lib.createFaceMemory(kr, 0);
        const hb_face = hb.Face.fromFreetypeFace(ft_face);
        const hb_font = hb.Font.init(hb_face);

        const font_size = 13.0;
        const font_size_frac: i32 = @intFromFloat(font_size * HARFBUZZ_FACTOR);

        try ft_face.setPixelSizes(0, @intFromFloat(font_size));

        hb_font.setScale(font_size_frac, font_size_frac);

        const font_atlas = try generateFontAtlas(allocator, ft_face, gctx);
        return .{
            .allocator = allocator,
            .gctx = gctx,
            .ft_lib = ft_lib,
            .ft_face = ft_face,
            .hb_font = hb_font,
            .atlas_texture = font_atlas.atlas_texture,
            .atlas_size = font_atlas.atlas_size,
            .glyph_map = font_atlas.glyph_map,
        };
    }

    pub fn deinit(self: *TextRendering) void {
        self.hb_font.deinit();
        self.ft_face.deinit();
        self.ft_lib.deinit();
        self.gctx.releaseResource(self.atlas_texture);
        self.glyph_map.deinit();
    }

    pub fn shape(self: *TextRendering, allocator: std.mem.Allocator, value: []const u8) ![][2]f32 {
        var buffer = hb.Buffer.init() orelse return error.OutOfMemory;
        defer buffer.deinit();

        const return_positions = try allocator.alloc([2]f32, value.len);

        buffer.setDirection(hb.Direction.ltr);
        buffer.setScript(hb.Script.latin);
        buffer.setLanguage(hb.Language.fromString("en"));
        buffer.addUTF8(value, 0, null);

        self.hb_font.shape(buffer, null);

        const infos = buffer.getGlyphInfos();
        const positions = buffer.getGlyphPositions() orelse return error.OutOfMemory;

        var cursor_x: i32 = 0;
        for (positions, infos, 0..) |*pos, info, i| {
            const glyph_index = info.codepoint;
            try self.ft_face.loadGlyph(glyph_index, .{});
            const glyph = self.ft_face.glyph();
            const advance_x = pos.x_advance;

            return_positions[i] = .{
                @floatFromInt(cursor_x + glyph.bitmapLeft()),
                -@as(f32, @floatFromInt(glyph.bitmapTop())),
            };

            std.debug.print("{d} {d}", .{ info.codepoint, info.cluster });

            cursor_x += advance_x >> 6;
        }

        std.debug.print("\n", .{});

        return return_positions;
    }
};

fn generateFontAtlas(allocator: std.mem.Allocator, ft_face: ft.Face, gctx: *zgpu.GraphicsContext) !struct {
    glyph_map: GlyphMap,
    atlas_texture: zgpu.TextureHandle,
    atlas_size: u32,
} {
    const ranges = [_][2]u32{
        [_]u32{ 0x0020, 0x007F }, // Basic Latin
        [_]u32{ 0x0900, 0x097F }, // Devanagari
        [_]u32{ 0x0400, 0x04FF }, // Cyrillic
    };

    var all_characters_len: u64 = 0;
    for (ranges) |range| {
        all_characters_len += range[1] - range[0];
    }

    const sizes = try allocator.alloc([2]u32, all_characters_len);
    defer allocator.free(sizes);

    // Generate a hash map character -> position and size.
    var map = GlyphMap.init(allocator);

    // Iterate over ranges.
    var i: u32 = 0;
    for (ranges) |range| {
        for (range[0]..range[1]) |codepoint| {
            try ft_face.loadChar(@intCast(codepoint), .{ .render = true });
            const bitmap = ft_face.glyph().bitmap();
            sizes[i] = .{
                bitmap.width(),
                bitmap.rows(),
            };
            i += 1;
        }
    }

    const packing = try pack_atlas.pack(allocator, sizes, 1.1);
    defer allocator.free(packing.positions);

    i = 0;
    for (ranges) |range| {
        for (range[0]..range[1]) |codepoint| {
            try map.put(@intCast(codepoint), .{
                .position = packing.positions[i],
                .size = sizes[i],
            });
            i += 1;
        }
    }

    const bitmap = try allocator.alloc(u8, packing.size * packing.size);
    @memset(bitmap, 0); // Clear the bitmap to 0.
    defer allocator.free(bitmap);

    // Print all bitmaps.
    i = 0;
    for (ranges) |range| {
        for (range[0]..range[1]) |codepoint| {
            const position = packing.positions[i];

            try ft_face.loadChar(@intCast(codepoint), .{ .render = true });
            const glyph_bitmap = ft_face.glyph().bitmap();

            switch (glyph_bitmap.pixelMode()) {
                .gray => {
                    // Gray bitmap.
                    for (0..glyph_bitmap.rows()) |y| {
                        for (0..glyph_bitmap.width()) |x| {
                            const index = (position[1] + y) * packing.size + position[0] + x;
                            const value = glyph_bitmap.buffer().?[y * glyph_bitmap.width() + x];
                            bitmap[index] = value;
                        }
                    }
                },
                else => unreachable,
            }

            i += 1;
        }
    }

    const atlas_texture = gctx.createTexture(.{
        .usage = .{ .texture_binding = true, .copy_dst = true },
        .size = .{
            .width = packing.size,
            .height = packing.size,
            .depth_or_array_layers = 1,
        },
        .format = zgpu.imageInfoToTextureFormat(1, 1, false),
    });

    gctx.queue.writeTexture(
        .{ .texture = gctx.lookupResource(atlas_texture).? },
        .{ .bytes_per_row = packing.size, .rows_per_image = packing.size },
        .{ .width = packing.size, .height = packing.size },
        u8,
        bitmap,
    );

    return .{
        .glyph_map = map,
        .atlas_texture = atlas_texture,
        .atlas_size = packing.size,
    };
}
