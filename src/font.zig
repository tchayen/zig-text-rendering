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

// Unit??
pub const GlyphRendering = struct {
    position: [2]f32,
    size: [2]f32,
};

const HARFBUZZ_FACTOR = 64.0;

const GlyphMap = std.AutoHashMap(u8, GlyphRendering);

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

    pub fn init(allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext, data: []u8) !TextRendering {
        const ft_lib = try ft.Library.init();
        const ft_face = try ft_lib.createFaceMemory(data, 0);
        const hb_face = hb.Face.fromFreetypeFace(ft_face);
        const hb_font = hb.Font.init(hb_face);

        const font_size = 20.0;
        const font_size_frac: i32 = @intFromFloat(font_size * HARFBUZZ_FACTOR);

        try ft_face.setPixelSizes(0, @intFromFloat(font_size));

        hb_font.setScale(font_size_frac, font_size_frac);
        hb_font.setPTEM(font_size);

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

        buffer.addUTF8(value, 0, null);
        buffer.setDirection(hb.Direction.ltr);
        buffer.setScript(hb.Script.latin);
        buffer.setLanguage(hb.Language.fromString("en"));

        self.hb_font.shape(buffer, null);

        const infos = buffer.getGlyphInfos();
        const positions = buffer.getGlyphPositions() orelse return error.OutOfMemory;

        var cursor_x: f32 = 0;
        var cursor_y: f32 = 0;
        for (positions, infos, 0..) |*pos, info, i| {
            const glyph_index = info.codepoint;
            try self.ft_face.loadGlyph(glyph_index, .{ .render = false });
            const glyph = self.ft_face.glyph();
            const metrics = glyph.metrics();

            const offset_x = @as(f32, @floatFromInt(pos.x_offset)) + @as(f32, @floatFromInt(metrics.horiBearingX));
            const offset_y = @as(f32, @floatFromInt(pos.y_offset)) - @as(f32, @floatFromInt(metrics.horiBearingY));
            const advance_x = @as(f32, @floatFromInt(pos.x_advance));
            const advance_y = @as(f32, @floatFromInt(pos.y_advance));

            return_positions[i] = .{
                (cursor_x + offset_x) / HARFBUZZ_FACTOR,
                (cursor_y + offset_y) / HARFBUZZ_FACTOR,
            };

            cursor_x += advance_x;
            cursor_y += advance_y;
        }

        return return_positions;
    }
};

fn generateFontAtlas(allocator: std.mem.Allocator, ft_face: ft.Face, gctx: *zgpu.GraphicsContext) !struct {
    glyph_map: GlyphMap,
    atlas_texture: zgpu.TextureHandle,
    atlas_size: u32,
} {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()_+-=[]{};':\",./<>?\\|`~";
    const sizes = try allocator.alloc([2]f32, alphabet.len);
    defer allocator.free(sizes);

    const MARGIN = 1.0;

    // Load all alphabet characters.
    for (0..alphabet.len) |i| {
        const char = alphabet[i];
        try ft_face.loadChar(char, .{ .render = true });
        const bitmap = ft_face.glyph().bitmap();
        sizes[i] = .{
            @as(f32, @floatFromInt(bitmap.width())) + MARGIN * 2,
            @as(f32, @floatFromInt(bitmap.rows())) + MARGIN * 2,
        };
    }

    const packing = try pack_atlas.pack(allocator, sizes, 1.1);
    defer allocator.free(packing.positions);

    // Generate a hash map character -> position and size.
    var map = GlyphMap.init(allocator);

    for (packing.positions, 0..) |position, i| {
        const char = alphabet[i];
        try map.put(char, .{ .position = position, .size = sizes[i] });
    }

    const bitmap = try allocator.alloc(u8, packing.size * packing.size);
    @memset(bitmap, 32); // Clear the bitmap to 0.
    defer allocator.free(bitmap);

    // Print all bitmaps.
    for (0..alphabet.len) |i| {
        const char = alphabet[i];
        const position = packing.positions[i];

        try ft_face.loadChar(char, .{ .render = true });
        const glyph_bitmap = ft_face.glyph().bitmap();

        // Go in a loop and copy glyph_bitmap to bitmap in correct position.
        var y: usize = 0;
        while (y < glyph_bitmap.rows()) : (y += 1) {
            var x: usize = 0;
            while (x < glyph_bitmap.width()) : (x += 1) {
                const src = y * glyph_bitmap.width() + x;
                const dst = (@as(u32, @intFromFloat(@round(position[1]))) + y + 1) * packing.size +
                    @as(u32, @intFromFloat(@round(position[0]))) + x + 1;
                bitmap[dst] = glyph_bitmap.buffer().?[src];
            }
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
