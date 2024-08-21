const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zm = @import("zmath");
const TextRendering = @import("font.zig").TextRendering;
const PIXELS = @import("font.zig").PIXELS;
const utils = @import("utils.zig");

const wgsl_vs =
    \\ struct VertexIn {
    \\     @location(0) position: vec2f,
    \\     @location(1) uv: vec2f,
    \\ };
    \\
    \\ struct VertexOut {
    \\     @builtin(position) position: vec4f,
    \\     @location(1) uv: vec2f,
    \\ };
    \\
    \\ @vertex fn main(in: VertexIn) -> VertexOut {
    \\     var out: VertexOut;
    \\     out.position = vec4f(in.position, 0.0, 1.0);
    \\     out.uv = in.uv;
    \\     return out;
    \\ }
;
const wgsl_fs =
    \\ struct VertexOut {
    \\     @builtin(position) position: vec4f,
    \\     @location(1) uv: vec2f,
    \\ };
    \\
    \\ @group(0) @binding(0) var t: texture_2d<f32>;
    \\ @group(0) @binding(1) var s: sampler;
    \\
    \\ @fragment fn main(in: VertexOut) -> @location(0) vec4f {
    \\     let a = textureSample(t, s, in.uv).r;
    \\     return vec4f(vec3f(1), a);
    \\ }
;

const Command = struct {
    position: [2]f32,
    text: []const u8,
};

/// Printer prints text on the screen.
pub const Printer = struct {
    gctx: *zgpu.GraphicsContext,
    allocator: std.mem.Allocator,
    text_rendering: *TextRendering,

    pipeline: zgpu.RenderPipelineHandle,
    bind_group: zgpu.BindGroupHandle,
    depth_texture: zgpu.TextureHandle,
    depth_texture_view: zgpu.TextureViewHandle,

    command_count: u32,
    commands: []Command,

    pub fn init(
        allocator: std.mem.Allocator,
        gctx: *zgpu.GraphicsContext,
        text_rendering: *TextRendering,
    ) !Printer {
        const bind_group_layout = gctx.createBindGroupLayout(&.{
            zgpu.textureEntry(0, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.samplerEntry(1, .{ .fragment = true }, .filtering),
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
                    .operation = .add,
                    .src_factor = .one,
                    .dst_factor = .one_minus_src_alpha,
                },
                .color = .{
                    .operation = .add,
                    .src_factor = .src_alpha,
                    .dst_factor = .one_minus_src_alpha,
                },
            },
        }};

        const vertex_attributes = [_]wgpu.VertexAttribute{
            .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x2, .offset = 2 * @sizeOf(f32), .shader_location = 1 },
        };
        const vertex_buffers = [_]wgpu.VertexBufferLayout{.{
            .array_stride = 4 * @sizeOf(f32),
            .attribute_count = vertex_attributes.len,
            .attributes = &vertex_attributes,
        }};

        const pipeline_descriptor = wgpu.RenderPipelineDescriptor{
            .vertex = wgpu.VertexState{
                .module = vs_module,
                .entry_point = "main",
                .buffer_count = vertex_buffers.len,
                .buffers = &vertex_buffers,
            },
            .primitive = wgpu.PrimitiveState{
                .front_face = .ccw,
                .cull_mode = .none,
                .topology = .triangle_list,
            },
            .depth_stencil = &wgpu.DepthStencilState{
                .format = .depth32_float,
                .depth_write_enabled = false,
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
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .max_anisotropy = 1,
        });
        const atlas_texture_view = gctx.createTextureView(text_rendering.atlas_texture, .{});

        const bind_group = gctx.createBindGroup(bind_group_layout, &.{
            .{ .binding = 0, .texture_view_handle = atlas_texture_view },
            .{ .binding = 1, .sampler_handle = sampler },
        });

        const depth = utils.createDepthTexture(gctx);

        const commands = try allocator.alloc(Command, 1024);
        @memset(commands, .{ .position = .{ 0, 0 }, .text = "" });

        return Printer{
            .gctx = gctx,
            .allocator = allocator,
            .text_rendering = text_rendering,

            .pipeline = pipeline,
            .bind_group = bind_group,
            .depth_texture = depth.texture,
            .depth_texture_view = depth.view,

            .command_count = 0,
            .commands = commands,
        };
    }

    pub fn text(self: *Printer, value: []const u8, x: f32, y: f32) !void {
        self.commands[self.command_count] = .{ .position = .{ x, y }, .text = value };
        self.command_count += 1;
    }

    pub fn draw(
        self: *Printer,
        back_buffer_view: zgpu.wgpu.TextureView,
        encoder: zgpu.wgpu.CommandEncoder,
    ) !void {
        var glyphs: u32 = 0;
        for (0..self.command_count) |i| {
            glyphs += @intCast(self.commands[i].text.len);
        }

        const vertex_buffer = self.gctx.createBuffer(.{
            .usage = .{ .copy_dst = true, .vertex = true },
            .size = glyphs * 2 * 12 * @sizeOf(f32),
        });
        defer self.gctx.releaseResource(vertex_buffer);

        const vertex_data = try self.allocator.alloc(f32, glyphs * 2 * 12);
        defer self.allocator.free(vertex_data);

        const atlas_size: f32 = @floatFromInt(self.text_rendering.atlas_size);

        var i: u32 = 0;
        for (0..self.command_count) |c| {
            const value = self.commands[c];
            const glyph_infos = try self.text_rendering.shape(
                self.allocator,
                value.text,
                300, //std.math.maxInt(i32),
            );
            defer self.allocator.free(glyph_infos);

            for (glyph_infos) |info| {
                const p_x: f32 = @floatFromInt(info.glyph.x);
                const p_y: f32 = @floatFromInt(info.glyph.y);
                const s_x: f32 = @floatFromInt(info.glyph.width);
                const s_y: f32 = @floatFromInt(info.glyph.height);

                const x = (value.position[0] + @as(f32, @floatFromInt(info.x))) / 1600 * 2 - 1;
                const y = -((value.position[1] + @as(f32, @floatFromInt(info.y))) / 1000 * 2 - 1);
                const w: f32 = s_x / 1600 * 2 / PIXELS;
                const h: f32 = s_y / 1000 * 2 / PIXELS;

                // 0
                vertex_data[i + 0] = x;
                vertex_data[i + 1] = y - h;
                vertex_data[i + 2] = p_x / atlas_size;
                vertex_data[i + 3] = (p_y + s_y) / atlas_size;

                // 1
                vertex_data[i + 4] = x + w;
                vertex_data[i + 5] = y - h;
                vertex_data[i + 6] = (p_x + s_x) / atlas_size;
                vertex_data[i + 7] = (p_y + s_y) / atlas_size;

                // 2
                vertex_data[i + 8] = x;
                vertex_data[i + 9] = y;
                vertex_data[i + 10] = p_x / atlas_size;
                vertex_data[i + 11] = p_y / atlas_size;

                // 3
                vertex_data[i + 12] = x + w;
                vertex_data[i + 13] = y - h;
                vertex_data[i + 14] = (p_x + s_x) / atlas_size;
                vertex_data[i + 15] = (p_y + s_y) / atlas_size;

                // 4
                vertex_data[i + 16] = x + w;
                vertex_data[i + 17] = y;
                vertex_data[i + 18] = (p_x + s_x) / atlas_size;
                vertex_data[i + 19] = p_y / atlas_size;

                // 5
                vertex_data[i + 20] = x;
                vertex_data[i + 21] = y;
                vertex_data[i + 22] = p_x / atlas_size;
                vertex_data[i + 23] = p_y / atlas_size;

                i += 24;
            }
        }

        self.gctx.queue.writeBuffer(self.gctx.lookupResource(vertex_buffer).?, 0, f32, vertex_data[0..]);

        const vb_info = self.gctx.lookupResourceInfo(vertex_buffer) orelse return;
        const pipeline = self.gctx.lookupResource(self.pipeline) orelse return;
        const bind_group = self.gctx.lookupResource(self.bind_group) orelse return;
        const depth_view = self.gctx.lookupResource(self.depth_texture_view) orelse return;

        const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
            .view = back_buffer_view,
            .load_op = .load,
            .store_op = .store,
        }};
        const depth_attachment = wgpu.RenderPassDepthStencilAttachment{
            .view = depth_view,
            .depth_load_op = .clear,
            .depth_store_op = .store,
            .depth_clear_value = 1.0,
        };
        const render_pass_info = wgpu.RenderPassDescriptor{
            .color_attachment_count = color_attachments.len,
            .color_attachments = &color_attachments,
            .depth_stencil_attachment = &depth_attachment,
        };
        const pass = encoder.beginRenderPass(render_pass_info);
        defer {
            pass.end();
            pass.release();
        }

        pass.setVertexBuffer(0, vb_info.gpuobj.?, 0, vb_info.size);
        pass.setPipeline(pipeline);
        pass.setBindGroup(0, bind_group, &.{});
        pass.draw(glyphs * 6, 1, 0, 0);

        @memset(self.commands, .{ .position = .{ 0, 0 }, .text = "" });
        self.command_count = 0;
    }

    pub fn deinit(self: *Printer) void {
        self.allocator.free(self.commands);
        self.gctx.releaseResource(self.bind_group);
        self.gctx.releaseResource(self.pipeline);
        self.gctx.releaseResource(self.depth_texture);
        self.gctx.releaseResource(self.depth_texture_view);
    }
};
