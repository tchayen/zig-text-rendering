const std = @import("std");
const math = std.math;
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zm = @import("zmath");

const utils = @import("utils.zig");
const font = @import("font.zig");
const DebugFontAtlas = @import("debug_font_atlas.zig").DebugFontAtlas;
const Printer = @import("printer.zig").Printer;
const Triangle = @import("triangle.zig").Triangle;

const content_dir = @import("build_options").content_dir;
const window_title = "zig text rendering";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    try zglfw.init();
    defer zglfw.terminate();

    // Change current working directory to where the executable is located.
    {
        var buffer: [1024]u8 = undefined;
        const path = std.fs.selfExeDirPath(buffer[0..]) catch ".";
        std.posix.chdir(path) catch {};
    }

    zglfw.windowHintTyped(.client_api, .no_api);

    const window = try zglfw.Window.create(1600, 1000, window_title, null);
    defer window.destroy();
    window.setSizeLimits(400, 400, -1, -1);

    const gctx = try zgpu.GraphicsContext.create(
        allocator,
        .{
            .window = window,
            .fn_getTime = @ptrCast(&zglfw.getTime),
            .fn_getFramebufferSize = @ptrCast(&zglfw.Window.getFramebufferSize),
            .fn_getWin32Window = @ptrCast(&zglfw.getWin32Window),
            .fn_getX11Display = @ptrCast(&zglfw.getX11Display),
            .fn_getX11Window = @ptrCast(&zglfw.getX11Window),
            .fn_getWaylandDisplay = @ptrCast(&zglfw.getWaylandDisplay),
            .fn_getWaylandSurface = @ptrCast(&zglfw.getWaylandWindow),
            .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
        },
        .{},
    );
    defer gctx.destroy(allocator);

    var triangle = Triangle.init(gctx);
    defer triangle.deinit();

    var text_rendering = try font.TextRendering.init(allocator, gctx);
    defer text_rendering.deinit();

    var printer = try Printer.init(allocator, gctx, &text_rendering);
    defer printer.deinit();

    var debug_font_atlas = DebugFontAtlas.init(gctx, text_rendering.atlas_texture);
    defer debug_font_atlas.deinit();

    // try printer.text("This text is now tiny, readable and does not really resemble the original font (hinting!)", 200, 200);
    try printer.text("Test", 200, 200);
    try printer.text("नमस्ते", 200, 225);
    try printer.text("\u{928}\u{92e}\u{938}\u{94d}\u{924}\u{947}", 200, 225);
    try printer.text("привіт", 200, 250);
    // try printer.text("This text", 200, 275);
    try draw(gctx, &triangle, &debug_font_atlas, &printer);

    while (!window.shouldClose() and window.getKey(.escape) != .press) {
        zglfw.pollEvents();
    }
}

fn draw(
    gctx: *zgpu.GraphicsContext,
    triangle: *Triangle,
    debug_font_atlas: *DebugFontAtlas,
    printer: *Printer,
) !void {
    const fb_width = gctx.swapchain_descriptor.width;
    const fb_height = gctx.swapchain_descriptor.height;
    const t: f32 = @floatCast(gctx.stats.time);

    const cam_world_to_view = zm.lookAtLh(
        zm.f32x4(3.0, 3.0, -3.0, 1.0),
        zm.f32x4(0.0, 0.0, 0.0, 1.0),
        zm.f32x4(0.0, 1.0, 0.0, 0.0),
    );
    const cam_view_to_clip = zm.perspectiveFovLh(
        0.25 * math.pi,
        @as(f32, @floatFromInt(fb_width)) / @as(f32, @floatFromInt(fb_height)),
        0.01,
        200.0,
    );
    const cam_world_to_clip = zm.mul(cam_world_to_view, cam_view_to_clip);

    const back_buffer_view = gctx.swapchain.getCurrentTextureView();
    defer back_buffer_view.release();

    const commands = commands: {
        const encoder = gctx.device.createCommandEncoder(null);
        defer encoder.release();

        pass: {
            const vb_info = gctx.lookupResourceInfo(triangle.vertex_buffer) orelse break :pass;
            const ib_info = gctx.lookupResourceInfo(triangle.index_buffer) orelse break :pass;
            const pipeline = gctx.lookupResource(triangle.pipeline) orelse break :pass;
            const bind_group = gctx.lookupResource(triangle.bind_group) orelse break :pass;
            const depth_view = gctx.lookupResource(triangle.depth_texture_view) orelse break :pass;

            const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                .view = back_buffer_view,
                .load_op = .clear,
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
            pass.setIndexBuffer(ib_info.gpuobj.?, .uint32, 0, ib_info.size);

            pass.setBlendConstant(.{ .r = 0, .g = 0, .b = 0, .a = 0 });

            pass.setPipeline(pipeline);

            // Draw triangle 1.
            {
                const object_to_world = zm.mul(zm.rotationY(t), zm.translation(-1.0, 0.0, 0.0));
                const object_to_clip = zm.mul(object_to_world, cam_world_to_clip);

                const mem = gctx.uniformsAllocate(zm.Mat, 1);
                mem.slice[0] = zm.transpose(object_to_clip);

                pass.setBindGroup(0, bind_group, &.{mem.offset});
                pass.drawIndexed(3, 1, 0, 0, 0);
            }

            // Draw triangle 2.
            {
                const object_to_world = zm.mul(zm.rotationY(0.75 * t), zm.translation(1.0, 0.0, 0.0));
                const object_to_clip = zm.mul(object_to_world, cam_world_to_clip);

                const mem = gctx.uniformsAllocate(zm.Mat, 1);
                mem.slice[0] = zm.transpose(object_to_clip);

                pass.setBindGroup(0, bind_group, &.{mem.offset});
                pass.drawIndexed(3, 1, 0, 0, 0);
            }
        }

        debug_font_atlas: {
            const vb_info = gctx.lookupResourceInfo(debug_font_atlas.vertex_buffer) orelse break :debug_font_atlas;
            const ub_info = gctx.lookupResourceInfo(debug_font_atlas.uv_buffer) orelse break :debug_font_atlas;
            const pipeline = gctx.lookupResource(debug_font_atlas.pipeline) orelse break :debug_font_atlas;
            const bind_group = gctx.lookupResource(debug_font_atlas.bind_group) orelse break :debug_font_atlas;
            const depth_view = gctx.lookupResource(debug_font_atlas.depth_texture_view) orelse break :debug_font_atlas;

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
            pass.setVertexBuffer(1, ub_info.gpuobj.?, 0, ub_info.size);
            pass.setPipeline(pipeline);
            pass.setBindGroup(0, bind_group, null);
            pass.draw(6, 1, 0, 0);
        }

        try printer.draw(back_buffer_view, encoder);

        break :commands encoder.finish(null);
    };
    defer commands.release();

    gctx.submit(&.{commands});

    if (gctx.present() == .swap_chain_resized) {
        // Release old depth texture.
        gctx.releaseResource(triangle.depth_texture_view);
        gctx.destroyResource(triangle.depth_texture);

        // Create a new depth texture to match the new window size.
        const depth = utils.createDepthTexture(gctx);
        triangle.depth_texture = depth.texture;
        triangle.depth_texture_view = depth.view;
    }
}
