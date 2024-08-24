const std = @import("std");
const Allocator = std.mem.Allocator;
const zgpu = @import("zgpu");
const ft = @import("mach-freetype");
const hb = @import("mach-harfbuzz");
const pack_atlas = @import("pack_atlas.zig");
const icu4x = @import("icu4zig");
const plutosvg = @import("plutosvg.zig");
const stb_image_write = @import("stb_image_write");
const stb_rect_pack = @import("stb_rect_pack");
const lunasvg = @import("lunasvg.zig");

/// Margin around each glyph in the atlas.
const MARGIN_PX = 1;

const font_size = 18;

const FontMapping = enum(usize) {
    Latin = 0,
    Arabic = 1,
    Emoji = 2,
    // Japanese = 2,
    // Korean = 3,
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
    pixel_mode: ft.PixelMode,
};

const GlyphMap = std.AutoHashMap(u32, GlyphInfo);

pub const Font = struct {
    ft_face: ft.Face,
    hb_face: hb.Face,
    hb_font: hb.Font,
    glyphs: GlyphMap,

    pub fn init(allocator: Allocator, ft_lib: *ft.Library, data: []const u8) !Font {
        const ft_face = try ft_lib.createFaceMemory(data, 0);
        const hb_face = hb.Face.fromFreetypeFace(ft_face);
        const hb_font = hb.Font.init(hb_face);
        return Font{
            .ft_face = ft_face,
            .hb_face = hb_face,
            .hb_font = hb_font,
            .glyphs = GlyphMap.init(allocator),
        };
    }
};

const latin = @embedFile("./assets/NotoSans-Regular.ttf");
const ar = @embedFile("./assets/NotoSansArabic-Regular.ttf");
const jp = @embedFile("./assets/NotoSansJP-Regular.ttf");
const kr = @embedFile("./assets/NotoSansKR-Regular.ttf");
const emoji = @embedFile("./assets/NotoColorEmoji-COLRv1.ttf");

/// Font encapsulates FreeType and HarfBuzz logic for shaping text. Generates font atlas texture in the `init()` method.
pub const FontLibrary = struct {
    allocator: Allocator,

    gctx: *zgpu.GraphicsContext,

    ft_lib: ft.Library,
    fonts: []Font,
    atlas_texture: zgpu.TextureHandle,
    atlas_size: u32,
    dpr: u32,

    pub fn init(allocator: Allocator, gctx: *zgpu.GraphicsContext, dpr: u32) !FontLibrary {
        var ft_lib = try ft.Library.init();
        const v = ft_lib.version();
        std.debug.print("FreeType version: {d}.{d}.{d}\n", .{ v.major, v.minor, v.patch });

        var fonts = try allocator.alloc(Font, 3);
        fonts[0] = try Font.init(allocator, &ft_lib, latin);
        fonts[1] = try Font.init(allocator, &ft_lib, ar);
        fonts[2] = try Font.init(allocator, &ft_lib, emoji);
        // fonts[2] = try Font.init(allocator, &ft_lib, jp);
        // fonts[3] = try Font.init(allocator, &ft_lib, kr);

        const hooks = plutosvg.c.plutosvg_ft_svg_hooks() orelse return error.PlutoSVG;
        try ft_lib.setProperty("ot-svg", "svg-hooks", hooks);

        for (fonts) |*font| {
            try font.ft_face.setPixelSizes(0, font_size * dpr);
            const hb_font_size: i32 = font_size * @as(i32, @intCast(dpr)) * 64;
            font.hb_font.setScale(hb_font_size, hb_font_size);
            font.glyphs = GlyphMap.init(allocator);
        }

        const font_atlas = try generateFontAtlas(allocator, fonts);
        defer allocator.free(font_atlas.bitmap);

        // Write the atlas to disk.
        _ = stb_image_write.c.stbi_write_png(
            "font_atlas.png",
            @intCast(font_atlas.size),
            @intCast(font_atlas.size),
            4,
            font_atlas.bitmap.ptr,
            @intCast(font_atlas.size * 4),
        );

        const atlas_texture = gctx.createTexture(.{
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .size = .{
                .width = font_atlas.size,
                .height = font_atlas.size,
                .depth_or_array_layers = 1,
            },
            .format = zgpu.imageInfoToTextureFormat(4, 1, false),
        });

        gctx.queue.writeTexture(
            .{ .texture = gctx.lookupResource(atlas_texture).? },
            .{ .bytes_per_row = font_atlas.size * 4, .rows_per_image = font_atlas.size },
            .{ .width = font_atlas.size, .height = font_atlas.size },
            u8,
            font_atlas.bitmap,
        );

        return FontLibrary{
            .allocator = allocator,
            .gctx = gctx,
            .ft_lib = ft_lib,
            .fonts = fonts,
            .atlas_texture = atlas_texture,
            .atlas_size = font_atlas.size,
            .dpr = dpr,
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
                // After shaping info.codepoint is a glyph index not unicode point.
                const glyph = self.fonts[fontId].glyphs.get(info.codepoint) orelse {
                    std.debug.print("No glyph for {d}\n", .{info.codepoint});
                    continue;
                };

                std.debug.print("{d} {d} {d}\n", .{ info.codepoint, @intFromEnum(range.script), @intFromEnum(glyph.pixel_mode) });

                try shapes.append(GlyphShape{
                    .x = cursor_x + (pos.x_offset >> 6) + glyph.bearing_x,
                    .y = cursor_y + (pos.y_offset >> 6) - glyph.bearing_y,
                    .glyph = glyph,
                });
                cursor_x += pos.x_advance >> 6;
                cursor_y += pos.y_advance >> 6;
            }
        }
        std.debug.print("\n", .{});
        return shapes.toOwnedSlice();
    }
};

fn codepointToScript(codepoint: u64) hb.Script {
    return switch (codepoint) {
        0x0020...0x007F, 0x00A0...0x00FF, 0x0100...0x017F, 0x0180...0x024F => hb.Script.latin,
        0x0400...0x04FF => hb.Script.cyrillic,
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
        hb.Script.cyrillic => @intFromEnum(FontMapping.Latin),
        hb.Script.devanagari => @intFromEnum(FontMapping.Latin),
        hb.Script.arabic => @intFromEnum(FontMapping.Arabic),
        hb.Script.common => @intFromEnum(FontMapping.Emoji),
        // hb.Script.hiragana => @intFromEnum(FontMapping.Japanese),
        // hb.Script.katakana => @intFromEnum(FontMapping.Japanese),
        // hb.Script.hangul => @intFromEnum(FontMapping.Korean),
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
        const count = f.ft_face.numGlyphs();
        std.debug.print("{s} ({d})\n", .{ f.ft_face.familyName() orelse "Unknown", count });
        all_characters_len += count;
    }

    std.debug.print("Total characters: {d}\n", .{all_characters_len});

    const sizes = try allocator.alloc([2]i32, all_characters_len);
    defer allocator.free(sizes);

    // Iterate over ranges.
    var i: u32 = 0;
    for (fonts) |f| {
        for (0..f.ft_face.numGlyphs()) |j| {
            // For regular font it's not necessary to render the glyph to get size but for OT SVG it is.
            try f.ft_face.loadGlyph(@intCast(j), .{
                .render = true,
                .color = f.ft_face.hasColor(),
            });
            const ft_glyph = f.ft_face.glyph();
            const ft_bitmap = ft_glyph.bitmap();
            const w = ft_bitmap.width();
            const h = ft_bitmap.rows();

            sizes[i] = if (w == 0 or h == 0) .{ 0, 0 } else .{
                @intCast(w + MARGIN_PX * 2),
                @intCast(h + MARGIN_PX * 2),
            };
            i += 1;
        }
    }

    const packing = try pack_atlas.pack(allocator, sizes, 1.1);
    defer allocator.free(packing.positions);

    std.debug.print("Atlas size: {d}x{d}px\n", .{ packing.size, packing.size });

    const bitmap = try allocator.alloc(u8, @intCast(packing.size * packing.size * 4));
    @memset(bitmap, 0); // Clear the bitmap.

    // Once positions are known, we can generate the glyphs mapping and bitmap.
    i = 0;
    for (fonts) |*f| {
        for (0..f.ft_face.numGlyphs()) |j| {
            try f.ft_face.loadGlyph(@intCast(j), .{
                .render = true,
                .color = f.ft_face.hasColor(),
            });
            const ft_glyph = f.ft_face.glyph();

            const position = packing.positions[i];
            const packing_x: usize = @intCast(position[0]);
            const packing_y: usize = @intCast(position[1]);
            const ft_bitmap = ft_glyph.bitmap();

            const h = ft_bitmap.rows();
            const w = ft_bitmap.width();

            switch (ft_bitmap.pixelMode()) {
                .gray => {
                    for (0..h) |y| {
                        for (0..w) |x| {
                            const buffer = ft_bitmap.buffer() orelse continue; // Why is it crashing if I take this out of the loop?
                            const src_index = y * w + x;
                            const dst_index = ((packing_y + y + MARGIN_PX) * packing.size + packing_x + x + MARGIN_PX) * 4;

                            bitmap[dst_index + 0] = 255;
                            bitmap[dst_index + 1] = 255;
                            bitmap[dst_index + 2] = 255;
                            bitmap[dst_index + 3] = buffer[src_index];
                        }
                    }
                },
                .bgra => {
                    for (0..h) |y| {
                        for (0..w) |x| {
                            const buffer = ft_bitmap.buffer() orelse continue;
                            const src_index = (y * w + x) * 4;
                            const dst_index = ((packing_y + y + MARGIN_PX) * packing.size + packing_x + x + MARGIN_PX) * 4;

                            bitmap[dst_index + 0] = buffer[src_index + 2];
                            bitmap[dst_index + 1] = buffer[src_index + 1];
                            bitmap[dst_index + 2] = buffer[src_index + 0];
                            bitmap[dst_index + 3] = buffer[src_index + 3];
                        }
                    }
                },
                else => {
                    std.debug.print("Unsupported pixel mode: {d}\n", .{@intFromEnum(ft_bitmap.pixelMode())});
                },
            }

            try f.glyphs.put(@intCast(j), GlyphInfo{
                .x = packing.positions[i][0],
                .y = packing.positions[i][1],
                .width = sizes[i][0],
                .height = sizes[i][1],
                .bearing_x = ft_glyph.bitmapLeft() - MARGIN_PX,
                .bearing_y = ft_glyph.bitmapTop() - MARGIN_PX,
                .pixel_mode = ft_bitmap.pixelMode(),
            });

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
        std.debug.print("{X}\n", .{codepoint});

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
    std.debug.print("\n", .{});

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

fn packWithStb() void {
    const context: stb_rect_pack.c.stbrp_context = .{
        .width = 4096,
    };
    stb_rect_pack.c.stbrp_init_target(&context);
}
