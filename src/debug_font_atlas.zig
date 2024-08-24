const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const wgsl_vs =
    \\ struct VertexOut {
    \\     @builtin(position) position: vec4f,
    \\     @location(0) uv: vec2f,
    \\ };
    \\
    \\ @vertex
    \\ fn main(@location(0) position: vec2f, @location(1) uv: vec2f) -> VertexOut {
    \\     var output: VertexOut;
    \\     output.position = vec4f(position, 0.0, 1.0);
    \\     output.uv = uv;
    \\     return output;
    \\ }
;

const wgsl_fs =
    \\ @group(0) @binding(0) var myTexture: texture_2d<f32>;
    \\ @group(0) @binding(1) var mySampler: sampler;
    \\
    \\ @fragment
    \\ fn main(@builtin(position) position: vec4f, @location(0) uv: vec2f) -> @location(0) vec4f {
    \\     let color = textureSample(myTexture, mySampler, uv).rgba;
    \\     return color;
    \\ }
;

/// Displays font atlas in the top right corner (stretching to [0,1]^2 in the clip space).
pub const DebugFontAtlas = struct {
    gctx: *zgpu.GraphicsContext,
    pipeline: zgpu.RenderPipelineHandle,
    bind_group: zgpu.BindGroupHandle,
    vertex_buffer: zgpu.BufferHandle,
    uv_buffer: zgpu.BufferHandle,
    depth_texture: zgpu.TextureHandle,
    depth_texture_view: zgpu.TextureViewHandle,

    atlas_texture_view: zgpu.TextureViewHandle,
    sampler: zgpu.SamplerHandle,

    pub fn init(gctx: *zgpu.GraphicsContext, atlas_texture: zgpu.TextureHandle) DebugFontAtlas {
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
            .{ .format = .float32x2, .offset = 0, .shader_location = 1 },
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
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .linear,
            .max_anisotropy = 1,
        });

        const atlas_texture_view = gctx.createTextureView(atlas_texture, .{});

        const bind_group = gctx.createBindGroup(bind_group_layout, &.{
            .{ .binding = 0, .texture_view_handle = atlas_texture_view },
            .{ .binding = 1, .sampler_handle = sampler },
        });

        const vertex_buffer = gctx.createBuffer(.{
            .usage = .{ .copy_dst = true, .vertex = true },
            .size = 12 * @sizeOf(f32),
        });

        const vertex_data = [_]f32{ 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 1, 1 };
        gctx.queue.writeBuffer(gctx.lookupResource(vertex_buffer).?, 0, f32, vertex_data[0..]);

        const uv_buffer = gctx.createBuffer(.{
            .usage = .{ .copy_dst = true, .vertex = true },
            .size = 12 * @sizeOf(f32),
        });

        const uv_data = [_]f32{ 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 1, 1 };
        gctx.queue.writeBuffer(gctx.lookupResource(uv_buffer).?, 0, f32, uv_data[0..]);

        const depth_texture = gctx.createTexture(.{
            .usage = .{ .render_attachment = true },
            .dimension = .tdim_2d,
            .size = .{
                .width = gctx.swapchain_descriptor.width,
                .height = gctx.swapchain_descriptor.height,
                .depth_or_array_layers = 1,
            },
            .format = .depth32_float,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        const depth_view = gctx.createTextureView(depth_texture, .{});

        return DebugFontAtlas{
            .gctx = gctx,
            .pipeline = pipeline,
            .bind_group = bind_group,
            .vertex_buffer = vertex_buffer,
            .uv_buffer = uv_buffer,
            .depth_texture = depth_texture,
            .depth_texture_view = depth_view,
            .atlas_texture_view = atlas_texture_view,
            .sampler = sampler,
        };
    }

    pub fn deinit(self: *DebugFontAtlas) void {
        self.gctx.releaseResource(self.bind_group);
        self.gctx.releaseResource(self.pipeline);
        self.gctx.releaseResource(self.vertex_buffer);
        self.gctx.releaseResource(self.depth_texture);
        self.gctx.releaseResource(self.depth_texture_view);
        self.gctx.releaseResource(self.sampler);
    }
};
