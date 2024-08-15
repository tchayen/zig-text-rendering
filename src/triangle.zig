const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zm = @import("zmath");
const utils = @import("utils.zig");

const wgsl_vs =
    \\ @group(0) @binding(0) var<uniform> object_to_clip: mat4x4<f32>;
    \\ struct VertexOut {
    \\     @builtin(position) position_clip: vec4<f32>,
    \\     @location(0) color: vec3<f32>,
    \\ }
    \\ @vertex fn main(
    \\     @location(0) position: vec3<f32>,
    \\     @location(1) color: vec3<f32>,
    \\ ) -> VertexOut {
    \\     var output: VertexOut;
    \\     output.position_clip = vec4(position, 1.0) * object_to_clip;
    \\     output.color = color;
    \\     return output;
    \\ }
;
const wgsl_fs =
    \\ @fragment fn main(
    \\     @location(0) color: vec3<f32>,
    \\ ) -> @location(0) vec4<f32> {
    \\     return vec4(color, 1.0);
    \\ }
;

const Vertex = struct {
    position: [3]f32,
    color: [3]f32,
};

pub const Triangle = struct {
    gctx: *zgpu.GraphicsContext,
    pipeline: zgpu.RenderPipelineHandle,
    bind_group: zgpu.BindGroupHandle,
    vertex_buffer: zgpu.BufferHandle,
    index_buffer: zgpu.BufferHandle,
    depth_texture: zgpu.TextureHandle,
    depth_texture_view: zgpu.TextureViewHandle,

    pub fn init(gctx: *zgpu.GraphicsContext) Triangle {
        const bind_group_layout = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .vertex = true }, .uniform, true, 0),
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
        }};

        const vertex_attributes = [_]wgpu.VertexAttribute{
            .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x3, .offset = @offsetOf(Vertex, "color"), .shader_location = 1 },
        };
        const vertex_buffers = [_]wgpu.VertexBufferLayout{.{
            .array_stride = @sizeOf(Vertex),
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

        const bind_group = gctx.createBindGroup(bind_group_layout, &.{
            .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(zm.Mat) },
        });

        const vertex_buffer = gctx.createBuffer(.{
            .usage = .{ .copy_dst = true, .vertex = true },
            .size = 3 * @sizeOf(Vertex),
        });
        const vertex_data = [_]Vertex{
            .{ .position = [3]f32{ 0.0, 0.5, 0.0 }, .color = [3]f32{ 1.0, 0.0, 0.0 } },
            .{ .position = [3]f32{ -0.5, -0.5, 0.0 }, .color = [3]f32{ 0.0, 1.0, 0.0 } },
            .{ .position = [3]f32{ 0.5, -0.5, 0.0 }, .color = [3]f32{ 0.0, 0.0, 1.0 } },
        };
        gctx.queue.writeBuffer(gctx.lookupResource(vertex_buffer).?, 0, Vertex, vertex_data[0..]);

        const index_buffer = gctx.createBuffer(.{
            .usage = .{ .copy_dst = true, .index = true },
            .size = 3 * @sizeOf(u32),
        });
        const index_data = [_]u32{ 0, 1, 2 };
        gctx.queue.writeBuffer(gctx.lookupResource(index_buffer).?, 0, u32, index_data[0..]);

        const depth = utils.createDepthTexture(gctx);

        return Triangle{
            .gctx = gctx,
            .pipeline = pipeline,
            .bind_group = bind_group,
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .depth_texture = depth.texture,
            .depth_texture_view = depth.view,
        };
    }

    pub fn deinit(self: *Triangle) void {
        self.gctx.releaseResource(self.bind_group);
        self.gctx.releaseResource(self.pipeline);
        self.gctx.releaseResource(self.vertex_buffer);
        self.gctx.releaseResource(self.index_buffer);
        self.gctx.releaseResource(self.depth_texture);
        self.gctx.releaseResource(self.depth_texture_view);
    }
};
