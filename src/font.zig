const std = @import("std");
const Allocator = std.mem.Allocator;
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

pub const GlyphShape = struct {
    char_index: u32,
    x: i32,
    y: i32,
    atlas_x: i32,
    atlas_y: i32,
    width: i32,
    height: i32,
};

const GlyphMap = std.AutoHashMap(u32, GlyphShape);

const latin = @embedFile("./assets/NotoSans-Regular.ttf");
// const jp = @embedFile("./assets/NotoSansJP-Regular.ttf");
// const kr = @embedFile("./assets/NotoSansKR-Regular.ttf");
// const emoji = @embedFile("./assets/NotoColorEmoji-Regular.ttf");

/// Font encapsulates FreeType and HarfBuzz logic for shaping text. Generates font atlas texture in the `init()` method. Initialize it with a font file binary data.
pub const TextRendering = struct {
    allocator: Allocator,
    gctx: *zgpu.GraphicsContext,
    ft_lib: ft.Library,
    ft_face: ft.Face,
    hb_font: hb.Font,
    atlas_texture: zgpu.TextureHandle,
    atlas_size: u32,
    glyph_map: GlyphMap,

    pub fn init(allocator: Allocator, gctx: *zgpu.GraphicsContext) !TextRendering {
        const ft_lib = try ft.Library.init();
        const ft_face = try ft_lib.createFaceMemory(latin, 0);
        // _ = try ft_lib.createFaceMemory(jp, 0);
        // _ = try ft_lib.createFaceMemory(kr, 0);
        const hb_face = hb.Face.fromFreetypeFace(ft_face);
        const hb_font = hb.Font.init(hb_face);

        const font_size = 13;
        try ft_face.setPixelSizes(0, font_size);
        hb_font.setScale(font_size * 64, font_size * 64);

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

    pub fn shape(self: *TextRendering, allocator: Allocator, value: []const u8) ![]GlyphShape {
        var buffer = hb.Buffer.init() orelse return error.OutOfMemory;
        defer buffer.deinit();

        buffer.setDirection(hb.Direction.ltr);
        buffer.setScript(hb.Script.latin);
        buffer.setLanguage(hb.Language.fromString("en"));
        buffer.addUTF8(value, 0, null);

        self.hb_font.shape(buffer, null);

        const infos = buffer.getGlyphInfos();
        const positions = buffer.getGlyphPositions() orelse return error.OutOfMemory;

        const shapes = try allocator.alloc(GlyphShape, infos.len);

        var cursor_x: i32 = 0;
        for (positions, infos, 0..) |pos, info, i| {
            try self.ft_face.loadGlyph(info.codepoint, .{});
            const ft_glyph = self.ft_face.glyph();
            const glyph = self.glyph_map.get(info.codepoint) orelse return error.InvalidCodepoint;

            const x = cursor_x + ft_glyph.bitmapLeft();
            const y = -ft_glyph.bitmapTop();

            shapes[i] = .{
                .char_index = info.codepoint,
                .x = x,
                .y = y,
                .atlas_x = glyph.atlas_x,
                .atlas_y = glyph.atlas_y,
                .width = glyph.width,
                .height = glyph.height,
            };

            cursor_x += pos.x_advance >> 6;
        }

        return shapes;
    }
};

fn generateFontAtlas(allocator: Allocator, ft_face: ft.Face, gctx: *zgpu.GraphicsContext) !struct {
    glyph_map: GlyphMap,
    atlas_texture: zgpu.TextureHandle,
    atlas_size: u32,
} {
    const ranges = [_][2]u32{
        [_]u32{ 0x0020, 0x007F }, // Basic Latin
        [_]u32{ 0x00A0, 0x00FF }, // Latin-1 Supplement
        [_]u32{ 0x0100, 0x017F }, // Latin Extended-A
        [_]u32{ 0x0180, 0x024F }, // Latin Extended-B
        [_]u32{ 0x0900, 0x097F }, // Devanagari
        [_]u32{ 0x0400, 0x04FF }, // Cyrillic
    };

    var all_characters_len: u64 = 0;
    for (ranges) |range| {
        all_characters_len += range[1] - range[0];
    }

    const sizes = try allocator.alloc([2]i32, all_characters_len);
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
                @intCast(bitmap.width()),
                @intCast(bitmap.rows()),
            };
            i += 1;
        }
    }

    const packing = try pack_atlas.pack(allocator, sizes, 1.1);
    defer allocator.free(packing.positions);

    i = 0;
    for (ranges) |range| {
        for (range[0]..range[1]) |codepoint| {
            const char_index = ft_face.getCharIndex(@intCast(codepoint)) orelse return error.InvalidCodepoint;
            try map.put(@intCast(char_index), .{
                .char_index = @intCast(char_index),
                .x = 0,
                .y = 0,
                .atlas_x = packing.positions[i][0],
                .atlas_y = packing.positions[i][1],
                .width = sizes[i][0],
                .height = sizes[i][1],
            });
            i += 1;
        }
    }

    const bitmap = try allocator.alloc(u8, @intCast(packing.size * packing.size));
    @memset(bitmap, 0); // Clear the bitmap.
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
                            const index = (@as(u32, @intCast(position[1])) + y) * packing.size + @as(u32, @intCast(position[0])) + x;
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
