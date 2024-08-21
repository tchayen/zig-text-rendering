const std = @import("std");
const Allocator = std.mem.Allocator;
const zgpu = @import("zgpu");
const ft = @import("mach-freetype");
const hb = @import("mach-harfbuzz");
const pack_atlas = @import("pack_atlas.zig");

pub const GlyphShape = struct {
    x: i32,
    y: i32,
    glyph: GlyphInfo,
};

pub const GlyphInfo = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    bitmap_left: i32,
    bitmap_top: i32,
};

pub const Font = struct {
    ft_face: ft.Face,
    hb_face: hb.Face,
    hb_font: hb.Font,
};

const GlyphMap = std.AutoHashMap(u32, GlyphInfo);

pub const PIXELS = 1;
const font_size = 13;
const MARGIN_PX = 1;

const latin = @embedFile("./assets/NotoSans-Regular.ttf");
const kr = @embedFile("./assets/NotoSansKR-Regular.ttf");
const emoji = @embedFile("./assets/NotoColorEmoji-Regular.ttf");
const emoji_svg = @embedFile("./assets/NotoColorEmoji-SVG.otf");

/// Font encapsulates FreeType and HarfBuzz logic for shaping text. Generates font atlas texture in the `init()` method.
pub const TextRendering = struct {
    allocator: Allocator,
    gctx: *zgpu.GraphicsContext,
    ft_lib: ft.Library,
    fonts: [4]Font,
    atlas_texture: zgpu.TextureHandle,
    atlas_size: u32,
    glyph_map: GlyphMap,

    pub fn init(allocator: Allocator, gctx: *zgpu.GraphicsContext) !TextRendering {
        const ft_lib = try ft.Library.init();

        var fonts: [4]Font = undefined;
        fonts[0].ft_face = try ft_lib.createFaceMemory(latin, 0);
        fonts[0].hb_face = hb.Face.fromFreetypeFace(fonts[0].ft_face);
        fonts[0].hb_font = hb.Font.init(fonts[0].hb_face);

        fonts[1].ft_face = try ft_lib.createFaceMemory(kr, 0);
        fonts[1].hb_face = hb.Face.fromFreetypeFace(fonts[1].ft_face);
        fonts[1].hb_font = hb.Font.init(fonts[1].hb_face);

        fonts[2].ft_face = try ft_lib.createFaceMemory(emoji, 0);
        fonts[2].hb_face = hb.Face.fromFreetypeFace(fonts[2].ft_face);
        fonts[2].hb_font = hb.Font.init(fonts[2].hb_face);

        fonts[3].ft_face = try ft_lib.createFaceMemory(emoji_svg, 0);
        fonts[3].hb_face = hb.Face.fromFreetypeFace(fonts[3].ft_face);
        fonts[3].hb_font = hb.Font.init(fonts[3].hb_face);

        for (fonts) |font| {
            try font.ft_face.setPixelSizes(0, font_size * PIXELS);
            font.hb_font.setScale(font_size * 64, font_size * 64);
        }

        const font_atlas = try generateFontAtlas(allocator, fonts, gctx);

        for (fonts) |font| {
            try font.ft_face.setPixelSizes(0, font_size);
        }

        return .{
            .allocator = allocator,
            .gctx = gctx,
            .ft_lib = ft_lib,
            .fonts = fonts,
            .atlas_texture = font_atlas.atlas_texture,
            .atlas_size = font_atlas.atlas_size,
            .glyph_map = font_atlas.glyph_map,
        };
    }

    pub fn deinit(self: *TextRendering) void {
        for (self.fonts) |font| {
            font.hb_font.deinit();
            font.ft_face.deinit();
        }
        self.ft_lib.deinit();
        self.gctx.releaseResource(self.atlas_texture);
        self.glyph_map.deinit();
    }

    pub fn shape(self: *TextRendering, allocator: Allocator, value: []const u8) ![]GlyphShape {
        var buffer = hb.Buffer.init() orelse return error.OutOfMemory;
        defer buffer.deinit();

        var utf8 = (try std.unicode.Utf8View.init(value)).iterator();
        while (utf8.nextCodepointSlice()) |codepoint| {
            std.debug.print("{s}", .{codepoint});
        }
        std.debug.print("\n", .{});

        buffer.setDirection(hb.Direction.ltr);
        buffer.setScript(hb.Script.latin);
        buffer.setLanguage(hb.Language.fromString("en"));
        buffer.addUTF8(value, 0, null);

        self.fonts[0].hb_font.shape(buffer, null);

        const infos = buffer.getGlyphInfos();
        const positions = buffer.getGlyphPositions() orelse return error.OutOfMemory;

        const shapes = try allocator.alloc(GlyphShape, infos.len);
        var cursor_x: i32 = 0;
        for (positions, infos, 0..) |pos, info, i| {
            const glyph = self.glyph_map.get(info.codepoint) orelse continue;
            shapes[i] = .{
                .x = cursor_x + @divFloor(glyph.bitmap_left, PIXELS),
                .y = -@divFloor(glyph.bitmap_top, PIXELS),
                .glyph = glyph,
            };
            cursor_x += pos.x_advance >> 6;
        }
        return shapes;
    }
};

const FontMapping = enum(usize) {
    Latin = 0,
    Korean = 1,
    Emoji = 2,
};

fn codepointToFont(codepoint: u64) ?usize {
    return switch (codepoint) {
        0x0020...0x007F,
        0x00A0...0x00FF,
        0x0100...0x017F,
        0x0180...0x024F,
        0x0900...0x097F,
        0x0400...0x04FF,
        => @intFromEnum(FontMapping.Latin),
        0x1100...0x11FF => @intFromEnum(FontMapping.Korean),
        0x1F600...0x1F64F => @intFromEnum(FontMapping.Emoji),
        else => null,
    };
}

fn generateFontAtlas(allocator: Allocator, fonts: [4]Font, gctx: *zgpu.GraphicsContext) !struct {
    glyph_map: GlyphMap,
    atlas_texture: zgpu.TextureHandle,
    atlas_size: u32,
} {
    const ranges = [_][2]u32{
        [_]u32{ 0x0020, 0x007F }, // Basic Latin
        [_]u32{ 0x00A0, 0x00FF }, // Latin-1 Supplement
        [_]u32{ 0x0100, 0x017F }, // Latin Extended-A
        [_]u32{ 0x0180, 0x024F }, // Latin Extended-B
        // Bug: cyrillic will be incorrectly displayed unless hangul jamo range is declared first.
        // [_]u32{ 0x1100, 0x11FF }, // Hangul Jamo
        [_]u32{ 0x0400, 0x04FF }, // Cyrillic
        // [_]u32{ 0x0900, 0x097F }, // Devanagari
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
            const fontId = codepointToFont(codepoint) orelse return error.MissingRange;
            try fonts[fontId].ft_face.loadChar(@intCast(codepoint), .{ .render = true });
            const bitmap = fonts[fontId].ft_face.glyph().bitmap();
            sizes[i] = .{
                @intCast(bitmap.width() + MARGIN_PX * 2),
                @intCast(bitmap.rows() + MARGIN_PX * 2),
            };
            i += 1;
        }
    }

    const packing = try pack_atlas.pack(allocator, sizes, 1.1);
    defer allocator.free(packing.positions);

    i = 0;
    for (ranges) |range| {
        for (range[0]..range[1]) |codepoint| {
            const fontId = codepointToFont(codepoint) orelse return error.MissingRange;
            const char_index = fonts[fontId].ft_face.getCharIndex(@intCast(codepoint)) orelse return error.InvalidCodepoint;
            try fonts[fontId].ft_face.loadGlyph(char_index, .{});
            const ft_glyph = fonts[fontId].ft_face.glyph();

            try map.put(@intCast(char_index), .{
                .x = packing.positions[i][0],
                .y = packing.positions[i][1],
                .width = sizes[i][0],
                .height = sizes[i][1],
                .bitmap_left = ft_glyph.bitmapLeft() - MARGIN_PX,
                .bitmap_top = ft_glyph.bitmapTop() - MARGIN_PX,
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
            const packing_x: usize = @intCast(position[0]);
            const packing_y: usize = @intCast(position[1]);

            const fontId = codepointToFont(codepoint) orelse return error.MissingRange;
            try fonts[fontId].ft_face.loadChar(@intCast(codepoint), .{ .render = true });
            const glyph_bitmap = fonts[fontId].ft_face.glyph().bitmap();

            switch (glyph_bitmap.pixelMode()) {
                .gray => {
                    // Gray bitmap.
                    for (0..glyph_bitmap.rows()) |y| {
                        for (0..glyph_bitmap.width()) |x| {
                            const index = (packing_y + y + MARGIN_PX) * packing.size + packing_x + x + MARGIN_PX;
                            const value = glyph_bitmap.buffer().?[y * glyph_bitmap.width() + x];
                            bitmap[index] = value;
                        }
                    }
                },
                else => {
                    std.debug.print("Unsupported pixel mode {}\n", .{glyph_bitmap.pixelMode()});
                },
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
