const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zm = @import("zmath");
const TextRendering = @import("font.zig").TextRendering;
const utils = @import("utils.zig");

const GlyphStruct = struct {
    position: [2]f32,
    size: [2]f32,
    uv: [4]f32,
    color: [4]f32,
};

const wgsl_vs =
    \\ override screen_width: f32;
    \\ override screen_height: f32;
    \\
    \\ struct Glyph {
    \\     position: vec2f,
    \\     size: vec2f,
    \\     uv: vec4f,
    \\     color: vec4f,
    \\ };
    \\
    \\ struct UniformStorage {
    \\     glyphs: array<Glyph>,
    \\ };
    \\
    \\ @group(0) @binding(0) var<storage> data: UniformStorage;
    \\
    \\ struct VertexOut {
    \\     @builtin(position) position: vec4f,
    \\     @location(0) @interpolate(flat) instance: u32,
    \\     @location(1) uv: vec2f,
    \\ };
    \\
    \\ @vertex fn main(
    \\     @location(0) position: vec2f,
    \\     @builtin(instance_index) instance: u32,
    \\ ) -> VertexOut {
    \\     var output: VertexOut;
    \\     let r = data.glyphs[instance];
    \\     let vertex = mix(r.position, r.position + r.size, position);
    \\     let uv = mix(r.uv.xy, r.uv.xy + r.uv.zw, position);
    \\     let screen_size: vec2f = vec2f(screen_width, screen_height);
    \\     output.position = vec4f(vertex / screen_size * 2.0 - 1.0, 0.0, 1.0);
    \\     output.position.y *= -1.0;
    \\     output.instance = instance;
    \\     output.uv = uv;
    \\     return output;
    \\ }
;
const wgsl_fs =
    \\ struct Glyph {
    \\     position: vec2f,
    \\     size: vec2f,
    \\     uv: vec4f,
    \\     color: vec4f,
    \\ };
    \\
    \\ struct UniformStorage {
    \\     glyphs: array<Glyph>,
    \\ };
    \\
    \\ @group(0) @binding(0) var<storage> data: UniformStorage;
    \\ @group(0) @binding(1) var myTexture: texture_2d<f32>;
    \\ @group(0) @binding(2) var mySampler: sampler;
    \\
    \\ struct VertexOut {
    \\     @builtin(position) position: vec4f,
    \\     @location(0) @interpolate(flat) instance: u32,
    \\     @location(1) uv: vec2f,
    \\ };
    \\
    \\ @fragment fn main(input: VertexOut) -> @location(0) vec4f {
    \\     let r = data.glyphs[input.instance];
    \\     let a = textureSample(myTexture, mySampler, input.uv).r;
    \\     return vec4f(r.color.rgb, r.color.a * a);
    \\
    \\ }
;

/// Printer prints text on the screen.
pub const Printer = struct {
    gctx: *zgpu.GraphicsContext,
    allocator: std.mem.Allocator,
    text_rendering: *TextRendering,

    pipeline: zgpu.RenderPipelineHandle,
    bind_group: zgpu.BindGroupHandle,
    vertex_buffer: zgpu.BufferHandle,
    storage_buffer: zgpu.BufferHandle,
    depth_texture: zgpu.TextureHandle,
    depth_texture_view: zgpu.TextureViewHandle,

    glyph_count: u32,
    storage_array: []GlyphStruct,

    pub fn init(allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext, text_rendering: *TextRendering) !Printer {
        const bind_group_layout = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .read_only_storage, true, 0),
            zgpu.textureEntry(1, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.samplerEntry(2, .{ .fragment = true }, .filtering),
        });
        defer gctx.releaseResource(bind_group_layout);

        const pipeline_layout = gctx.createPipelineLayout(&.{bind_group_layout});
        defer gctx.releaseResource(pipeline_layout);

        const vs_module = zgpu.createWgslShaderModule(gctx.device, wgsl_vs, "vs");
        defer vs_module.release();

        const fs_module = zgpu.createWgslShaderModule(gctx.device, wgsl_fs, "fs");
        defer fs_module.release();

        const color_targets = [_]wgpu.ColorTargetState{.{
            .format = zgpu.GraphicsContext.swapchain_format,
            .blend = &.{
                .alpha = .{
                    .src_factor = .src_alpha,
                    .dst_factor = .one_minus_src_alpha,
                },
                .color = .{
                    .src_factor = .src_alpha,
                    .dst_factor = .one_minus_src_alpha,
                },
            },
        }};

        const vertex_attributes = [_]wgpu.VertexAttribute{
            .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
        };
        const vertex_buffers = [_]wgpu.VertexBufferLayout{.{
            .array_stride = 2 * @sizeOf(f32),
            .attribute_count = vertex_attributes.len,
            .attributes = &vertex_attributes,
        }};

        const pipeline_descriptor = wgpu.RenderPipelineDescriptor{
            .vertex = wgpu.VertexState{
                .module = vs_module,
                .entry_point = "main",
                .buffer_count = vertex_buffers.len,
                .buffers = &vertex_buffers,
                .constant_count = 2,
                .constants = &.{
                    .{
                        .key = "screen_width",
                        .value = @as(f32, @floatFromInt(gctx.swapchain_descriptor.width)),
                    },
                    .{
                        .key = "screen_height",
                        .value = @as(f32, @floatFromInt(gctx.swapchain_descriptor.height)),
                    },
                },
            },
            .primitive = wgpu.PrimitiveState{
                .front_face = .ccw,
                .cull_mode = .none,
                .topology = .triangle_list,
            },
            .depth_stencil = &wgpu.DepthStencilState{
                .format = .depth32_float,
                .depth_write_enabled = true,
                .depth_compare = .less,
            },
            .fragment = &wgpu.FragmentState{
                .module = fs_module,
                .entry_point = "main",
                .target_count = color_targets.len,
                .targets = &color_targets,
            },
        };
        const pipeline = gctx.createRenderPipeline(pipeline_layout, pipeline_descriptor);

        const sampler = gctx.createSampler(.{
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .mipmap_filter = .nearest,
            .max_anisotropy = 1,
        });

        const atlas_texture_view = gctx.createTextureView(text_rendering.atlas_texture, .{});

        const storage_buffer = gctx.createBuffer(.{
            .usage = .{ .storage = true, .copy_dst = true },
            .size = 1000 * @sizeOf(GlyphStruct),
        });

        const bind_group = gctx.createBindGroup(bind_group_layout, &.{
            .{ .binding = 0, .buffer_handle = storage_buffer, .size = 1000 * @sizeOf(GlyphStruct) },
            .{ .binding = 1, .texture_view_handle = atlas_texture_view },
            .{ .binding = 2, .sampler_handle = sampler },
        });

        const vertex_buffer = gctx.createBuffer(.{
            .usage = .{ .copy_dst = true, .vertex = true },
            .size = 12 * @sizeOf(f32),
        });
        const vertex_data = [_]f32{ 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 1, 1 };
        gctx.queue.writeBuffer(gctx.lookupResource(vertex_buffer).?, 0, f32, vertex_data[0..]);

        const depth = utils.createDepthTexture(gctx);

        const storage_array = try allocator.alloc(GlyphStruct, 1000);

        return Printer{
            .gctx = gctx,
            .allocator = allocator,
            .text_rendering = text_rendering,

            .pipeline = pipeline,
            .bind_group = bind_group,
            .vertex_buffer = vertex_buffer,
            .storage_buffer = storage_buffer,
            .depth_texture = depth.texture,
            .depth_texture_view = depth.view,

            .storage_array = storage_array,
            .glyph_count = 0,
        };
    }

    pub fn text(self: *Printer, value: []const u8, x: f32, y: f32) !void {
        const positions = try self.text_rendering.shape(self.allocator, value);
        defer self.allocator.free(positions);

        const MARGIN = 1.0;

        for (value, positions) |char, position| {
            const v = self.text_rendering.glyph_map.get(char) orelse continue;
            const atlas_size: f32 = @floatFromInt(self.text_rendering.atlas_size);
            self.storage_array[self.glyph_count] = .{
                .position = [_]f32{ x + position[0], y + position[1] },
                .size = [_]f32{ v.size[0] - 2, v.size[1] - 2 },
                .uv = [_]f32{
                    (v.position[0] + MARGIN) / atlas_size,
                    (v.position[1] + MARGIN) / atlas_size,
                    (v.size[0] - 2 * MARGIN) / atlas_size,
                    (v.size[1] - 2 * MARGIN) / atlas_size,
                },
                .color = [_]f32{ 1, 1, 1, 1 },
            };
            self.glyph_count += 1;
        }
    }

    pub fn begin_frame(self: *Printer) void {
        self.glyph_count = 0;
    }

    pub fn end_frame(self: *Printer) void {
        @memset(self.storage_array[self.glyph_count..], .{
            .position = [_]f32{ 0, 0 },
            .size = [_]f32{ 0, 0 },
            .uv = [_]f32{ 0, 0, 0, 0 },
            .color = [_]f32{ 0, 0, 0, 0 },
        });
        self.gctx.queue.writeBuffer(
            self.gctx.lookupResource(self.storage_buffer).?,
            0,
            GlyphStruct,
            self.storage_array[0..self.glyph_count],
        );
    }

    pub fn deinit(self: *Printer) void {
        self.gctx.releaseResource(self.bind_group);
        self.gctx.releaseResource(self.pipeline);
        self.gctx.releaseResource(self.vertex_buffer);
        self.gctx.releaseResource(self.storage_buffer);
        self.gctx.releaseResource(self.depth_texture);
        self.gctx.releaseResource(self.depth_texture_view);

        self.allocator.free(self.storage_array);
    }
};
