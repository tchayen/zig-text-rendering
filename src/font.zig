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

const font_size = 18;

const FontMapping = enum(usize) {
    Latin = 0,
    Japanese = 1,
    Arabic = 2,
};

const RGBA = struct { r: u8, g: u8, b: u8, a: u8 };

const Range = struct {
    script: hb.Script, // Script used by the range.
    start: usize, // First byte index.
    end: usize, // Last byte index (inclusive).
    // color: RGBA, <- Styling will probably go here into the ranges.
    // font_size: i32,
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
    bearing_x: i32, // Offset from the left edge of the bitmap to where the glyph starts (in px).
    bearing_y: i32,
};

const GlyphMap = std.AutoHashMap(u32, GlyphInfo);

pub const Font = struct {
    ft_face: ft.Face,
    hb_face: hb.Face,
    hb_font: hb.Font,
    glyphs: GlyphMap,
};

const latin = @embedFile("./assets/NotoSans-Regular.ttf");
const jp = @embedFile("./assets/NotoSansJP-Regular.ttf");
// const kr = @embedFile("./assets/NotoSansKR-Regular.ttf");
const ar = @embedFile("./assets/NotoSansArabic-Regular.ttf");
// const emoji = @embedFile("./assets/NotoColorEmoji-Regular.ttf");
// const emoji_svg = @embedFile("./assets/NotoColorEmoji-SVG.otf");

/// Font encapsulates FreeType and HarfBuzz logic for shaping text. Generates font atlas texture in the `init()` method.
pub const FontLibrary = struct {
    allocator: Allocator,
    gctx: *zgpu.GraphicsContext,
    ft_lib: ft.Library,
    fonts: []Font,
    atlas_texture: zgpu.TextureHandle,
    atlas_size: u32,

    pub fn init(allocator: Allocator, gctx: *zgpu.GraphicsContext) !FontLibrary {
        const ft_lib = try ft.Library.init();

        var fonts = try allocator.alloc(Font, 3);
        fonts[0].ft_face = try ft_lib.createFaceMemory(latin, 0);
        fonts[0].hb_face = hb.Face.fromFreetypeFace(fonts[0].ft_face);
        fonts[0].hb_font = hb.Font.init(fonts[0].hb_face);

        fonts[1].ft_face = try ft_lib.createFaceMemory(jp, 0);
        fonts[1].hb_face = hb.Face.fromFreetypeFace(fonts[1].ft_face);
        fonts[1].hb_font = hb.Font.init(fonts[1].hb_face);

        fonts[2].ft_face = try ft_lib.createFaceMemory(ar, 0);
        fonts[2].hb_face = hb.Face.fromFreetypeFace(fonts[2].ft_face);
        fonts[2].hb_font = hb.Font.init(fonts[2].hb_face);

        for (fonts) |*font| {
            try font.ft_face.setPixelSizes(0, font_size * PIXELS);
            font.hb_font.setScale(font_size * 64, font_size * 64);
            font.glyphs = GlyphMap.init(allocator);
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

        return FontLibrary{
            .allocator = allocator,
            .gctx = gctx,
            .ft_lib = ft_lib,
            .fonts = fonts,
            .atlas_texture = atlas_texture,
            .atlas_size = font_atlas.size,
        };
    }

    pub fn deinit(self: *FontLibrary) void {
        for (self.fonts) |*font| {
            font.hb_font.deinit();
            font.ft_face.deinit();
            font.glyphs.deinit();
        }
        self.allocator.free(self.fonts);
        self.ft_lib.deinit();
        self.gctx.releaseResource(self.atlas_texture);
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

            // buffer.guessSegmentProps();
            // buffer.setLanguage(hb.Language.fromString("hi"));
            buffer.setDirection(scriptToDirection(range.script));
            buffer.setScript(range.script);

            buffer.addUTF8(value[range.start .. range.end + 1], 0, null);

            const fontId = scriptToFont(range.script) orelse {
                std.debug.print("No font for script {d}\n", .{@intFromEnum(range.script)});
                continue;
            };

            self.fonts[fontId].hb_font.shape(buffer, null);

            const infos = buffer.getGlyphInfos();
            const positions = buffer.getGlyphPositions() orelse return error.OutOfMemory;

            for (positions, infos) |pos, info| {
                // After shaping it is a glyph index not unicode point.
                const glyph = self.fonts[fontId].glyphs.get(info.codepoint) orelse {
                    std.debug.print("No glyph for {d}\n", .{info.codepoint});
                    continue;
                };

                try shapes.append(GlyphShape{
                    .x = cursor_x + (pos.x_offset >> 6) + glyph.bearing_x,
                    .y = cursor_y + (pos.y_offset >> 6) - glyph.bearing_y,
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

fn codepointToScript(codepoint: u64) hb.Script {
    return switch (codepoint) {
        0x0020...0x007F => hb.Script.latin,
        0x00A0...0x00FF => hb.Script.latin,
        0x0100...0x017F => hb.Script.latin,
        0x0180...0x024F => hb.Script.latin,
        0x0900...0x097F => hb.Script.devanagari,
        0x0600...0x06FF => hb.Script.arabic,
        0x3041...0x3096 => hb.Script.hiragana,
        0x30A0...0x30FF => hb.Script.katakana,
        else => hb.Script.common,
    };
}

fn scriptToFont(script: hb.Script) ?usize {
    return switch (script) {
        hb.Script.latin => @intFromEnum(FontMapping.Latin),
        hb.Script.devanagari => @intFromEnum(FontMapping.Latin),
        hb.Script.hiragana => @intFromEnum(FontMapping.Japanese),
        hb.Script.katakana => @intFromEnum(FontMapping.Japanese),
        hb.Script.arabic => @intFromEnum(FontMapping.Arabic),
        else => null,
    };
}

fn scriptToDirection(script: hb.Script) hb.Direction {
    return switch (script) {
        hb.Script.arabic => hb.Direction.rtl,
        else => hb.Direction.ltr,
    };
}

/// Generate font atlas texture from the input fonts.
fn generateFontAtlas(allocator: Allocator, fonts: []Font) !struct { size: u32, bitmap: []u8 } {
    const start = std.time.nanoTimestamp();
    var all_characters_len: u64 = 0;
    for (fonts) |f| {
        all_characters_len += f.ft_face.numGlyphs();
    }

    std.debug.print("Total characters: {d}\n", .{all_characters_len});

    const sizes = try allocator.alloc([2]i32, all_characters_len);
    defer allocator.free(sizes);

    // Iterate over ranges.
    var i: u32 = 0;
    for (fonts) |f| {
        for (0..f.ft_face.numGlyphs()) |j| {
            try f.ft_face.loadGlyph(@intCast(j), .{});
            const ft_glyph = f.ft_face.glyph();
            const ft_bitmap = ft_glyph.bitmap();
            sizes[i] = .{
                @intCast(ft_bitmap.width() + MARGIN_PX * 2),
                @intCast(ft_bitmap.rows() + MARGIN_PX * 2),
            };
            i += 1;
        }
    }

    const packing = try pack_atlas.pack(allocator, sizes, 1.1);
    defer allocator.free(packing.positions);

    std.debug.print("Atlas size: {d}x{d}px\n", .{ packing.size, packing.size });

    const bitmap = try allocator.alloc(u8, @intCast(packing.size * packing.size));
    @memset(bitmap, 0); // Clear the bitmap.

    // Once positions are known, we can generate the glyphs mapping and bitmap.
    i = 0;
    for (fonts) |*f| {
        for (0..f.ft_face.numGlyphs()) |j| {
            try f.ft_face.loadGlyph(@intCast(j), .{ .render = true });
            const ft_glyph = f.ft_face.glyph();
            try f.glyphs.put(@intCast(j), GlyphInfo{
                .x = packing.positions[i][0],
                .y = packing.positions[i][1],
                .width = sizes[i][0],
                .height = sizes[i][1],
                .bearing_x = ft_glyph.bitmapLeft() - MARGIN_PX,
                .bearing_y = ft_glyph.bitmapTop() - MARGIN_PX,
            });

            const position = packing.positions[i];
            const packing_x: usize = @intCast(position[0]);
            const packing_y: usize = @intCast(position[1]);
            const ft_bitmap = ft_glyph.bitmap();
            switch (ft_bitmap.pixelMode()) {
                .gray => {
                    for (0..ft_bitmap.rows()) |y| {
                        for (0..ft_bitmap.width()) |x| {
                            const index = (packing_y + y + MARGIN_PX) * packing.size + packing_x + x + MARGIN_PX;
                            const buffer = ft_bitmap.buffer() orelse continue;
                            const value = buffer[y * ft_bitmap.width() + x];
                            bitmap[index] = value;
                        }
                    }
                },
                else => unreachable,
            }
            i += 1;
        }
    }

    const end = std.time.nanoTimestamp();
    std.debug.print("Bitmap generation took {d}ms\n", .{@divTrunc(end - start, 1_000_000)});

    return .{ .size = packing.size, .bitmap = bitmap };
}

/// Split the input string into list of ranges with the same script.
fn getRanges(allocator: Allocator, value: []const u8) ![]Range {
    var ranges = std.ArrayList(Range).init(allocator);
    var utf8 = try std.unicode.Utf8View.init(value);
    var iterator = utf8.iterator();

    var current_range: ?Range = null;
    var byte_index: usize = 0;

    while (iterator.nextCodepointSlice()) |slice| {
        const codepoint = try std.unicode.utf8Decode(slice);
        const script = codepointToScript(codepoint);

        if (current_range) |*range| {
            if (range.script == script) {
                range.end = byte_index + slice.len - 1;
            } else {
                try ranges.append(range.*);
                current_range = Range{
                    .script = script,
                    .start = byte_index,
                    .end = byte_index + slice.len - 1,
                };
            }
        } else {
            current_range = Range{
                .script = script,
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
