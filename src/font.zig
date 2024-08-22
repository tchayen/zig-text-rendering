const std = @import("std");
const Allocator = std.mem.Allocator;
const zgpu = @import("zgpu");
const ft = @import("mach-freetype");
const hb = @import("mach-harfbuzz");
const pack_atlas = @import("pack_atlas.zig");
const icu4x = @import("icu4zig");

/// Device pixel ration.
pub const PIXELS = 1;

/// Margin around each glyph in the atlas.
const MARGIN_PX = 1;

const font_size = 15;

const FontMapping = enum(usize) {
    Latin = 0,
    Korean = 1,
    Japanese = 2,
    Arabic = 3,
};

const Range = struct {
    font: usize, // ID of the font (FontMapping).
    start: usize, // First byte index.
    end: usize, // Last byte index (inclusive).
};

pub const GlyphShape = struct {
    x: i32, // x position after shaping (in px).
    y: i32,
    glyph: GlyphInfo,
};

pub const GlyphInfo = struct {
    x: i32, // The x position in the atlas (in px).
    y: i32,
    width: i32, // Width of the glyph in the bitmap (in px).
    height: i32,
    bitmap_left: i32, // Offset from the left edge of the bitmap to where the glyph starts (in px).
    bitmap_top: i32,
};

pub const Font = struct {
    ft_face: ft.Face,
    hb_face: hb.Face,
    hb_font: hb.Font,
};

const GlyphMap = std.AutoHashMap(u32, GlyphInfo);

const latin = @embedFile("./assets/NotoSans-Regular.ttf");
const kr = @embedFile("./assets/NotoSansKR-Regular.ttf");
const jp = @embedFile("./assets/NotoSansJP-Regular.ttf");
const ar = @embedFile("./assets/NotoSansArabic-Regular.ttf");
const emoji = @embedFile("./assets/NotoColorEmoji-Regular.ttf");
const emoji_svg = @embedFile("./assets/NotoColorEmoji-SVG.otf");

/// Font encapsulates FreeType and HarfBuzz logic for shaping text. Generates font atlas texture in the `init()` method.
pub const FontLibrary = struct {
    allocator: Allocator,
    gctx: *zgpu.GraphicsContext,
    ft_lib: ft.Library,
    fonts: [4]Font,
    atlas_texture: zgpu.TextureHandle,
    atlas_size: u32,
    glyphs: GlyphMap,

    pub fn init(allocator: Allocator, gctx: *zgpu.GraphicsContext) !FontLibrary {
        const ft_lib = try ft.Library.init();

        var fonts: [4]Font = undefined;
        fonts[0].ft_face = try ft_lib.createFaceMemory(latin, 0);
        fonts[0].hb_face = hb.Face.fromFreetypeFace(fonts[0].ft_face);
        fonts[0].hb_font = hb.Font.init(fonts[0].hb_face);

        fonts[1].ft_face = try ft_lib.createFaceMemory(kr, 0);
        fonts[1].hb_face = hb.Face.fromFreetypeFace(fonts[1].ft_face);
        fonts[1].hb_font = hb.Font.init(fonts[1].hb_face);

        fonts[2].ft_face = try ft_lib.createFaceMemory(jp, 0);
        fonts[2].hb_face = hb.Face.fromFreetypeFace(fonts[2].ft_face);
        fonts[2].hb_font = hb.Font.init(fonts[2].hb_face);

        fonts[3].ft_face = try ft_lib.createFaceMemory(ar, 0);
        fonts[3].hb_face = hb.Face.fromFreetypeFace(fonts[3].ft_face);
        fonts[3].hb_font = hb.Font.init(fonts[3].hb_face);

        for (fonts) |font| {
            try font.ft_face.setPixelSizes(0, font_size * PIXELS);
            font.hb_font.setScale(font_size * 64, font_size * 64);
        }

        const font_atlas = try generateFontAtlas(allocator, fonts);
        defer allocator.free(font_atlas.bitmap);

        const atlas_texture = gctx.createTexture(.{
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .size = .{
                .width = font_atlas.size,
                .height = font_atlas.size,
                .depth_or_array_layers = 1,
            },
            .format = zgpu.imageInfoToTextureFormat(1, 1, false),
        });

        gctx.queue.writeTexture(
            .{ .texture = gctx.lookupResource(atlas_texture).? },
            .{ .bytes_per_row = font_atlas.size, .rows_per_image = font_atlas.size },
            .{ .width = font_atlas.size, .height = font_atlas.size },
            u8,
            font_atlas.bitmap,
        );

        for (fonts) |font| {
            try font.ft_face.setPixelSizes(0, font_size);
        }

        return .{
            .allocator = allocator,
            .gctx = gctx,
            .ft_lib = ft_lib,
            .fonts = fonts,
            .atlas_texture = atlas_texture,
            .atlas_size = font_atlas.size,
            .glyphs = font_atlas.glyphs,
        };
    }

    pub fn deinit(self: *FontLibrary) void {
        for (self.fonts) |font| {
            font.hb_font.deinit();
            font.ft_face.deinit();
        }
        self.ft_lib.deinit();
        self.gctx.releaseResource(self.atlas_texture);
        self.glyphs.deinit();
    }

    pub fn shape(self: *FontLibrary, allocator: Allocator, value: []const u8, max_width: i32) ![]GlyphShape {
        _ = max_width; // autofix
        const ranges = try getRanges(allocator, value);
        defer allocator.free(ranges);

        var shapes = std.ArrayList(GlyphShape).init(allocator);
        var cursor_x: i32 = 0;
        var cursor_y: i32 = 0;

        const segments = try segment(allocator, value);
        defer allocator.free(segments);

        for (segments) |s| {
            std.debug.print("{d} ", .{s});
        }
        std.debug.print("\n", .{});

        for (ranges) |range| {
            var buffer = hb.Buffer.init() orelse return error.OutOfMemory;
            defer buffer.deinit();

            buffer.guessSegmentProps();
            buffer.addUTF8(value[range.start .. range.end + 1], 0, null);

            self.fonts[range.font].hb_font.shape(buffer, null);

            const infos = buffer.getGlyphInfos();
            const positions = buffer.getGlyphPositions() orelse return error.OutOfMemory;

            for (positions, infos) |pos, info| {
                // After shaping it is glyph index not unicode point.
                const glyph = self.glyphs.get(info.codepoint) orelse continue;

                try shapes.append(.{
                    .x = cursor_x + @divFloor(glyph.bitmap_left, PIXELS),
                    .y = cursor_y - @divFloor(glyph.bitmap_top, PIXELS),
                    .glyph = glyph,
                });
                cursor_x += pos.x_advance >> 6;
                cursor_y += pos.y_advance >> 6;

                std.debug.print("{d} {d}, ", .{ info.codepoint, info.cluster });
            }
        }
        std.debug.print("\n", .{});

        return shapes.toOwnedSlice();
    }
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
        0x1100...0x11FF,
        0xAC00...0xD7A3,
        => @intFromEnum(FontMapping.Korean),
        0x3000...0x303F,
        0x3041...0x3096,
        0x30A0...0x30FF,
        => @intFromEnum(FontMapping.Japanese),
        0x0600...0x06FF,
        => @intFromEnum(FontMapping.Arabic),
        else => null,
    };
}

/// Generate font atlas texture from the input fonts.
fn generateFontAtlas(allocator: Allocator, fonts: [4]Font) !struct { glyphs: GlyphMap, size: u32, bitmap: []u8 } {
    const ranges = [_][2]u32{
        [_]u32{ 0x0020, 0x007F }, // Basic Latin
        [_]u32{ 0x00A0, 0x00FF }, // Latin-1 Supplement
        [_]u32{ 0x0100, 0x017F }, // Latin Extended-A
        [_]u32{ 0x0180, 0x024F }, // Latin Extended-B
        [_]u32{ 0x1100, 0x11FF }, // Hangul Jamo
        [_]u32{ 0xAC00, 0xD7A3 }, // Hangul Syllables
        [_]u32{ 0x0400, 0x04FF }, // Cyrillic
        [_]u32{ 0x0900, 0x097F }, // Devanagari
        [_]u32{ 0x3000, 0x303F }, // CJK Symbols and Punctuation
        [_]u32{ 0x3041, 0x3096 }, // Hiragana
        [_]u32{ 0x30A0, 0x30FF }, // Katakana
        // [_]u32{ 0x0600, 0x06FF }, // Arabic
    };

    var all_characters_len: u64 = 0;
    for (ranges) |range| {
        all_characters_len += range[1] - range[0];
    }

    const sizes = try allocator.alloc([2]i32, all_characters_len);
    defer allocator.free(sizes);

    var glyphs = GlyphMap.init(allocator);

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

    std.debug.print("Atlas size: {d}\n", .{packing.size});

    i = 0;
    for (ranges) |range| {
        for (range[0]..range[1]) |codepoint| {
            const fontId = codepointToFont(codepoint) orelse return error.MissingRange;
            const char_index = fonts[fontId].ft_face.getCharIndex(@intCast(codepoint)) orelse {
                std.debug.print("Failed to get char index for codepoint {d}\n", .{codepoint});
                continue;
            };
            try fonts[fontId].ft_face.loadGlyph(char_index, .{});
            const ft_glyph = fonts[fontId].ft_face.glyph();

            try glyphs.put(@intCast(char_index), .{
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

    // Print all bitmaps.
    const start = std.time.nanoTimestamp();
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
    const end = std.time.nanoTimestamp();
    std.debug.print("Bitmap generation took {d}ms\n", .{@divTrunc(end - start, 1_000_000)});

    return .{
        .glyphs = glyphs,
        .size = packing.size,
        .bitmap = bitmap,
    };
}

/// Split the input string into list of ranges with the same font face.
fn getRanges(allocator: Allocator, value: []const u8) ![]Range {
    var ranges = std.ArrayList(Range).init(allocator);
    var utf8 = try std.unicode.Utf8View.init(value);
    var iterator = utf8.iterator();

    var current_range: ?Range = null;
    var byte_index: usize = 0;

    while (iterator.nextCodepointSlice()) |slice| {
        const codepoint = try std.unicode.utf8Decode(slice);
        const fontId = codepointToFont(codepoint) orelse return error.MissingRange;

        if (current_range) |*range| {
            if (range.font == fontId) {
                range.end = byte_index + slice.len - 1;
            } else {
                try ranges.append(range.*);
                current_range = Range{
                    .font = fontId,
                    .start = byte_index,
                    .end = byte_index + slice.len - 1,
                };
            }
        } else {
            current_range = Range{
                .font = fontId,
                .start = byte_index,
                .end = byte_index + slice.len - 1,
            };
        }
        byte_index += slice.len;
    }

    if (current_range) |range| {
        try ranges.append(range);
    }

    return ranges.toOwnedSlice();
}

/// Segment text into words using ICU4X. Returns a slice of indices where words start or end.
pub fn segment(allocator: Allocator, value: []const u8) ![]u32 {
    const data_provider = icu4x.DataProvider.init();
    defer data_provider.deinit();

    const segmenter = icu4x.WordSegmenter.init(data_provider);
    defer segmenter.deinit();

    var iterator = segmenter.segment(.{ .utf8 = value });
    defer iterator.deinit();

    var segments = std.ArrayList(u32).init(allocator);
    while (iterator.next()) |s| {
        try segments.append(@intCast(s));
    }
    return segments.toOwnedSlice();
}
