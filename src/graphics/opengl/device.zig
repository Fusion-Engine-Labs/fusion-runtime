const std = @import("std");

const ResourcePool = @import("../rhi/resource_pool.zig").ResourcePool;
const RhiGraphicsPipeline = @import("../rhi/graphics_pipeline.zig");
const OpenGLGraphicsPipeline = @import("graphics_pipeline.zig");
const ResourceHandle = @import("../rhi/resource_handle.zig");
const RhiFramebuffer = @import("../rhi/framebuffer.zig");
const TextureView = @import("../rhi/texture_view.zig");
const OpenGLFramebuffer = @import("framebuffer.zig");
const RhiGeometry = @import("../rhi/geometry.zig");
const RhiTexture = @import("../rhi/texture.zig");
const RhiSampler = @import("../rhi/sampler.zig");
const render_state = @import("render_state.zig");
const rhi_device = @import("../rhi/device.zig");
const diagnostics = @import("diagnostics.zig");
const RhiBuffer = @import("../rhi/buffer.zig");
const OpenGLGeometry = @import("geometry.zig");
const OpenGLTexture = @import("texture.zig");
const OpenGLSampler = @import("sampler.zig");
const OpenGLBuffer = @import("buffer.zig");
const gl = @import("../../c.zig").glad;

const OpenGLDevice = @This();
const query_count = 4;

allocator: std.mem.Allocator,
framebuffers: ResourcePool(OpenGLFramebuffer) = .{},
pipelines: ResourcePool(OpenGLGraphicsPipeline) = .{},
textures: ResourcePool(OpenGLTexture) = .{},
samplers: ResourcePool(OpenGLSampler) = .{},
buffers: ResourcePool(OpenGLBuffer) = .{},
geometries: ResourcePool(OpenGLGeometry) = .{},
next_pipeline_sort_key: u64 = 1,
state_cache: render_state.Cache = .{},
query_ids: [query_count]u32 = [_]u32{0} ** query_count,
query_pending: [query_count]bool = [_]bool{false} ** query_count,
active_query: ?usize = null,
queries_initialized: bool = false,

const vtable = rhi_device.VTable{
    .deinit = deinit,
    .beginRenderPass = beginRenderPass,
    .endRenderPass = endRenderPass,

    // framebuffer
    .bindRenderTarget = bindRenderTarget,
    .createFramebuffer = createFramebuffer,
    .destroyFramebuffer = destroyFramebuffer,
    .resizeFramebuffer = resizeFramebuffer,
    .framebufferColorView = framebufferColorView,
    .bindTexture = bindTexture,
    .textureViewNativeId = textureViewNativeId,
    .createTexture = createTexture,
    .destroyTexture = destroyTexture,
    .createSampler = createSampler,
    .destroySampler = destroySampler,
    .createBuffer = createBuffer,
    .updateBuffer = updateBuffer,
    .destroyBuffer = destroyBuffer,
    .createGeometry = createGeometry,
    .destroyGeometry = destroyGeometry,
    .drawIndexed = drawIndexed,
    .beginGpuTimer = beginGpuTimer,
    .endGpuTimer = endGpuTimer,
    .pollGpuTime = pollGpuTime,

    // graphics pipeline
    .createGraphicsPipeline = createGraphicsPipeline,
    .destroyGraphicsPipeline = destroyGraphicsPipeline,
    .bindGraphicsPipeline = bindGraphicsPipeline,
    .graphicsPipelineUniformLocation = graphicsPipelineUniformLocation,
    .setGraphicsPipelineUniform = setGraphicsPipelineUniform,
};

pub fn init(allocator: std.mem.Allocator) !rhi_device {
    const self = try allocator.create(OpenGLDevice);
    self.* = .{ .allocator = allocator };

    return .{ .impl = self, .vtable = &vtable };
}

fn deinit(impl: *anyopaque) void {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    inline for (.{ &self.geometries, &self.buffers, &self.samplers, &self.textures, &self.framebuffers, &self.pipelines }) |pool| {
        for (pool.slots.items) |*slot| {
            if (slot.resource) |*resource| {
                resource.deinit();
            }
        }
        pool.deinit(self.allocator);
    }

    if (self.queries_initialized) {
        gl.glDeleteQueries(query_count, &self.query_ids);
    }
    const allocator = self.allocator;
    allocator.destroy(self);
}

fn createFramebuffer(impl: *anyopaque, desc: RhiFramebuffer.FramebufferDesc) anyerror!RhiFramebuffer {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    const extent = desc.extent.normalized();
    var resource = try OpenGLFramebuffer.init(.{
        .extent = extent,
        .color_format = desc.color_format,
        .depth_stencil_format = desc.depth_stencil_format,
    });
    errdefer resource.deinit();

    const allocation = try self.framebuffers.insert(self.allocator, resource);
    return .{
        .handle = self.makeHandle(allocation),
        .extent = extent,
        .color_format = desc.color_format,
        .depth_stencil_format = desc.depth_stencil_format,
    };
}

fn destroyFramebuffer(impl: *anyopaque, target: *RhiFramebuffer) void {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    var resource = self.remove(&self.framebuffers, target.handle, "framebuffer");
    resource.deinit();
    target.* = undefined;
}

fn resizeFramebuffer(impl: *anyopaque, target: *RhiFramebuffer, extent: RhiFramebuffer.Extent2D) anyerror!void {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    const normalized = extent.normalized();
    try self.resolveFramebuffer(target.*).resize(normalized.width, normalized.height);
    target.extent = normalized;
}

fn beginRenderPass(impl: *anyopaque, info: rhi_device.RenderPassInfo) anyerror!void {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    self.bindTarget(info.target);
    render_state.begin(&self.state_cache, .{ .color = info.color, .depth = info.depth });
    if (!diagnostics.checkError("beginning render pass")) {
        return error.OpenGLError;
    }
}

fn bindRenderTarget(impl: *anyopaque, target: rhi_device.RenderTarget) void {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    self.bindTarget(target);
}

fn bindTarget(self: *OpenGLDevice, target: rhi_device.RenderTarget) void {
    switch (target) {
        .swapchain => |viewport| OpenGLFramebuffer.bindDefault(viewport.width, viewport.height),
        .framebuffer => |framebuffer_target| self.resolveFramebuffer(framebuffer_target.*).bind(),
    }
}

fn endRenderPass(_: *anyopaque) void {}

fn framebufferColorView(_: *anyopaque, target: *const RhiFramebuffer) TextureView {
    return TextureView.fromFramebuffer(target.*);
}

fn bindTexture(impl: *anyopaque, view: TextureView, sampler: RhiSampler, unit: u16) void {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    gl.glActiveTexture(@intCast(gl.GL_TEXTURE0 + @as(c_int, @intCast(unit))));
    gl.glBindTexture(gl.GL_TEXTURE_2D, self.textureId(view));
    gl.glBindSampler(unit, self.resolveSampler(sampler).id);
    _ = diagnostics.checkError("binding texture and sampler");
}

fn textureViewNativeId(impl: *anyopaque, view: TextureView) u32 {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    return self.textureId(view);
}

fn createTexture(impl: *anyopaque, desc: RhiTexture.Desc) anyerror!RhiTexture {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    var resource = try OpenGLTexture.init(desc);
    errdefer resource.deinit();

    const a = try self.textures.insert(self.allocator, resource);
    return .{
        .handle = self.makeHandle(a),
        .extent = desc.extent,
        .format = desc.format,
        .mip_count = @intCast(desc.mips.len),
    };
}
fn destroyTexture(impl: *anyopaque, texture: *RhiTexture) void {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    var r = self.remove(&self.textures, texture.handle, "texture");
    r.deinit();
    texture.* = undefined;
}

fn createSampler(impl: *anyopaque, desc: RhiSampler.Desc) anyerror!RhiSampler {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    var r = try OpenGLSampler.init(desc);
    errdefer r.deinit();

    const a = try self.samplers.insert(self.allocator, r);
    return .{
        .handle = self.makeHandle(a),
    };
}

fn destroySampler(impl: *anyopaque, sampler: *RhiSampler) void {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    var r = self.remove(&self.samplers, sampler.handle, "sampler");
    r.deinit();
    sampler.* = undefined;
}

fn createBuffer(impl: *anyopaque, desc: RhiBuffer.Desc) anyerror!RhiBuffer {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    var r = try OpenGLBuffer.init(desc);
    errdefer r.deinit();

    const a = try self.buffers.insert(self.allocator, r);
    return .{
        .handle = self.makeHandle(a),
        .size = desc.size,
        .usage = desc.usage,
    };
}

fn updateBuffer(impl: *anyopaque, buffer: RhiBuffer, offset: usize, data: []const u8) anyerror!void {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    try self.resolveBuffer(buffer).update(offset, data);
}

fn destroyBuffer(impl: *anyopaque, buffer: *RhiBuffer) void {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    var r = self.remove(&self.buffers, buffer.handle, "buffer");
    r.deinit();
    buffer.* = undefined;
}

fn createGeometry(impl: *anyopaque, desc: RhiGeometry.Desc) anyerror!RhiGeometry {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    var streams: std.ArrayList(OpenGLGeometry.Stream) = .empty;
    defer streams.deinit(self.allocator);

    for (desc.streams) |stream| {
        try streams.append(self.allocator, .{ .buffer_id = self.resolveBuffer(stream.buffer).id, .attribute = stream.attribute });
    }

    var r = try OpenGLGeometry.init(streams.items, self.resolveBuffer(desc.index_buffer).id, desc.index_format, desc.index_count);
    // Geometry initialization binds its VAO while configuring attributes, then
    // leaves VAO 0 bound.  Keep the bind-elision cache in sync with GL.
    self.state_cache.bound_vao = 0;
    errdefer r.deinit();

    const a = try self.geometries.insert(self.allocator, r);
    return .{
        .handle = self.makeHandle(a),
        .index_format = desc.index_format,
        .index_count = desc.index_count,
    };
}

fn destroyGeometry(impl: *anyopaque, geometry: *RhiGeometry) void {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    var r = self.remove(&self.geometries, geometry.handle, "geometry");
    const was_bound = self.state_cache.bound_vao == r.id;
    r.deinit();
    if (was_bound) self.state_cache.bound_vao = 0;
    geometry.* = undefined;
}

fn drawIndexed(impl: *anyopaque, geometry: RhiGeometry, first: u32, count: u32, base_vertex: i32) void {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    self.resolveGeometry(geometry).draw(&self.state_cache.bound_vao, first, count, base_vertex);
    _ = diagnostics.checkError("drawing indexed geometry");
}

fn createGraphicsPipeline(impl: *anyopaque, desc: RhiGraphicsPipeline.GraphicsPipelineDesc) anyerror!RhiGraphicsPipeline {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    var resource = try OpenGLGraphicsPipeline.init(self.allocator, desc);
    errdefer resource.deinit();

    const allocation = try self.pipelines.insert(self.allocator, resource);
    const sort_key = self.next_pipeline_sort_key;
    self.next_pipeline_sort_key = nextSortKey(sort_key);
    return .{
        .handle = self.makeHandle(allocation),
        .sort_key = sort_key,
    };
}

fn destroyGraphicsPipeline(impl: *anyopaque, pipeline: *RhiGraphicsPipeline) void {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    var resource = self.remove(&self.pipelines, pipeline.handle, "graphics pipeline");
    resource.deinit();
    pipeline.* = undefined;
}

fn bindGraphicsPipeline(impl: *anyopaque, pipeline: RhiGraphicsPipeline) void {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    self.resolvePipeline(pipeline).bind(&self.state_cache);
}

fn graphicsPipelineUniformLocation(impl: *anyopaque, pipeline: RhiGraphicsPipeline, name_hash: u64) ?RhiGraphicsPipeline.UniformLocation {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    return self.resolvePipeline(pipeline).uniformLocationByHash(name_hash);
}

fn setGraphicsPipelineUniform(impl: *anyopaque, pipeline: RhiGraphicsPipeline, location: RhiGraphicsPipeline.UniformLocation, value: RhiGraphicsPipeline.UniformValue) void {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    self.resolvePipeline(pipeline).setUniformFromLocation(location, value);
    _ = diagnostics.checkError("setting graphics pipeline uniform");
}

fn resolveFramebuffer(self: *OpenGLDevice, handle: RhiFramebuffer) *OpenGLFramebuffer {
    return self.resolve(&self.framebuffers, handle.handle, "framebuffer");
}

fn textureId(self: *OpenGLDevice, view: TextureView) u32 {
    return switch (view.source) {
        .texture => |handle| self.resolve(&self.textures, handle, "texture").id,
        .framebuffer_color => |handle| self.resolveFramebuffer(.{ .handle = handle, .extent = undefined, .color_format = undefined, .depth_stencil_format = undefined }).colorTextureId(),
    };
}

fn resolvePipeline(self: *OpenGLDevice, handle: RhiGraphicsPipeline) *OpenGLGraphicsPipeline {
    return self.resolve(&self.pipelines, handle.handle, "graphics pipeline");
}

fn makeHandle(self: *OpenGLDevice, allocation: anytype) ResourceHandle {
    return .{ .owner = self, .index = allocation.index, .generation = allocation.generation };
}

fn resolve(self: *OpenGLDevice, pool: anytype, resource_handle: ResourceHandle, comptime kind: []const u8) @TypeOf(pool.get(0, 0).?) {
    if (!resource_handle.belongsTo(@as(*const anyopaque, @ptrCast(self)))) @panic("foreign " ++ kind ++ " handle");
    return pool.get(resource_handle.index, resource_handle.generation) orelse @panic("stale " ++ kind ++ " handle");
}

fn remove(self: *OpenGLDevice, pool: anytype, resource_handle: ResourceHandle, comptime kind: []const u8) @TypeOf(pool.remove(0, 0).?) {
    if (!resource_handle.belongsTo(@as(*const anyopaque, @ptrCast(self)))) @panic("foreign " ++ kind ++ " handle");
    return pool.remove(resource_handle.index, resource_handle.generation) orelse @panic("stale " ++ kind ++ " handle");
}

fn resolveSampler(self: *OpenGLDevice, sampler: RhiSampler) *OpenGLSampler {
    return self.resolve(&self.samplers, sampler.handle, "sampler");
}

fn resolveBuffer(self: *OpenGLDevice, buffer: RhiBuffer) *OpenGLBuffer {
    return self.resolve(&self.buffers, buffer.handle, "buffer");
}

fn resolveGeometry(self: *OpenGLDevice, geometry: RhiGeometry) *OpenGLGeometry {
    return self.resolve(&self.geometries, geometry.handle, "geometry");
}

fn beginGpuTimer(impl: *anyopaque) void {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    if (!self.queries_initialized) {
        gl.glGenQueries(query_count, &self.query_ids);
        self.queries_initialized = true;
        _ = diagnostics.checkError("creating GPU timer queries");
    }

    if (self.active_query != null) {
        return;
    }

    for (self.query_pending, 0..) |pending, i| if (!pending) {
        gl.glBeginQuery(gl.GL_TIME_ELAPSED, self.query_ids[i]);
        if (!diagnostics.checkError("beginning GPU timer query")) {
            return;
        }
        self.active_query = i;
        return;
    };
}

fn endGpuTimer(impl: *anyopaque) void {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    const i = self.active_query orelse return;
    gl.glEndQuery(gl.GL_TIME_ELAPSED);
    if (!diagnostics.checkError("ending GPU timer query")) {
        self.active_query = null;
        return;
    }
    self.query_pending[i] = true;
    self.active_query = null;
}

fn pollGpuTime(impl: *anyopaque) ?f32 {
    const self: *OpenGLDevice = @ptrCast(@alignCast(impl));
    if (!self.queries_initialized) {
        return null;
    }

    for (&self.query_pending, 0..) |*pending, i| {
        if (!pending.*) {
            continue;
        }

        var available: c_int = 0;
        gl.glGetQueryObjectiv(self.query_ids[i], gl.GL_QUERY_RESULT_AVAILABLE, &available);
        if (available == 0) {
            continue;
        }

        var ns: u64 = 0;
        gl.glGetQueryObjectui64v(self.query_ids[i], gl.GL_QUERY_RESULT, &ns);
        pending.* = false;
        return @as(f32, @floatFromInt(ns)) / std.time.ns_per_ms;
    }
    return null;
}

fn nextSortKey(current: u64) u64 {
    const next = current +% 1;
    return if (next == 0) 1 else next;
}

test "pipeline sort keys never use zero" {
    try std.testing.expectEqual(@as(u64, 1), nextSortKey(std.math.maxInt(u64)));
}
