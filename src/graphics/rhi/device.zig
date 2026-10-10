const zimp = @import("zimp");
const GraphicsPipeline = @import("graphics_pipeline.zig");
const render_state = @import("../render_state.zig");
const TextureView = @import("texture_view.zig");
const Texture = @import("texture.zig");
const Sampler = @import("sampler.zig");
const Buffer = @import("buffer.zig");
const Geometry = @import("geometry.zig");
const Framebuffer = @import("framebuffer.zig");

pub const RenderViewport = struct {
    width: u32 = 1,
    height: u32 = 1,

    pub fn aspect(self: RenderViewport) f32 {
        return @as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(@max(1, self.height)));
    }

    pub fn extent(self: RenderViewport) Framebuffer.Extent2D {
        return .{ .width = self.width, .height = self.height };
    }
};

pub const RenderTarget = union(enum) {
    swapchain: RenderViewport,
    framebuffer: *Framebuffer,

    pub fn viewport(self: RenderTarget) RenderViewport {
        return switch (self) {
            .swapchain => |value| value,
            .framebuffer => |value| .{ .width = value.extent.width, .height = value.extent.height },
        };
    }
};

pub const RenderPassInfo = struct {
    target: RenderTarget,
    color: ?render_state.ColorLoadOp = null,
    depth: ?render_state.DepthLoadOp = null,
};

const testing = @import("std").testing;

test "RenderViewport.aspect divides width by height" {
    const viewport = RenderViewport{ .width = 1920, .height = 1080 };
    try testing.expectApproxEqAbs(@as(f32, 1920.0 / 1080.0), viewport.aspect(), 1e-5);
}

test "RenderViewport.aspect guards against a zero height" {
    const viewport = RenderViewport{ .width = 100, .height = 0 };
    try testing.expectEqual(@as(f32, 100.0), viewport.aspect());
}

test "RenderTarget.viewport passes through swapchain dimensions" {
    const target = RenderTarget{ .swapchain = .{ .width = 640, .height = 480 } };
    const viewport = target.viewport();
    try testing.expectEqual(@as(u32, 640), viewport.width);
    try testing.expectEqual(@as(u32, 480), viewport.height);
}

test "RenderTarget.viewport reads dimensions from a framebuffer" {
    var framebuffer = Framebuffer{
        .handle = .{ .owner = undefined, .index = 0, .generation = 0 },
        .extent = .{ .width = 256, .height = 128 },
        .color_format = .rgba8,
        .depth_stencil_format = null,
    };
    const target = RenderTarget{ .framebuffer = &framebuffer };
    const viewport = target.viewport();
    try testing.expectEqual(@as(u32, 256), viewport.width);
    try testing.expectEqual(@as(u32, 128), viewport.height);
}

const Device = @This();
impl: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    deinit: *const fn (*anyopaque) void,
    bindRenderTarget: *const fn (*anyopaque, RenderTarget) void,
    beginRenderPass: *const fn (*anyopaque, RenderPassInfo) anyerror!void,
    endRenderPass: *const fn (*anyopaque) void,

    createFramebuffer: *const fn (*anyopaque, Framebuffer.FramebufferDesc) anyerror!Framebuffer,
    destroyFramebuffer: *const fn (*anyopaque, *Framebuffer) void,
    resizeFramebuffer: *const fn (*anyopaque, *Framebuffer, Framebuffer.Extent2D) anyerror!void,
    framebufferColorView: *const fn (*anyopaque, *const Framebuffer) TextureView,
    textureViewNativeId: *const fn (*anyopaque, TextureView) u32,

    createTexture: *const fn (*anyopaque, Texture.Desc) anyerror!Texture,
    destroyTexture: *const fn (*anyopaque, *Texture) void,
    createSampler: *const fn (*anyopaque, Sampler.Desc) anyerror!Sampler,
    destroySampler: *const fn (*anyopaque, *Sampler) void,
    bindTexture: *const fn (*anyopaque, TextureView, Sampler, u16) void,

    createBuffer: *const fn (*anyopaque, Buffer.Desc) anyerror!Buffer,
    updateBuffer: *const fn (*anyopaque, Buffer, usize, []const u8) anyerror!void,
    destroyBuffer: *const fn (*anyopaque, *Buffer) void,
    createGeometry: *const fn (*anyopaque, Geometry.Desc) anyerror!Geometry,
    destroyGeometry: *const fn (*anyopaque, *Geometry) void,
    drawIndexed: *const fn (*anyopaque, Geometry, u32, u32, i32) void,

    createGraphicsPipeline: *const fn (*anyopaque, GraphicsPipeline.GraphicsPipelineDesc) anyerror!GraphicsPipeline,
    destroyGraphicsPipeline: *const fn (*anyopaque, *GraphicsPipeline) void,
    bindGraphicsPipeline: *const fn (*anyopaque, GraphicsPipeline) void,
    /// Looks a uniform up by `zimp.nameHash` of its name.
    graphicsPipelineUniformLocation: *const fn (*anyopaque, GraphicsPipeline, u64) ?GraphicsPipeline.UniformLocation,
    setGraphicsPipelineUniform: *const fn (*anyopaque, GraphicsPipeline, GraphicsPipeline.UniformLocation, GraphicsPipeline.UniformValue) void,

    beginGpuTimer: *const fn (*anyopaque) void,
    endGpuTimer: *const fn (*anyopaque) void,
    pollGpuTime: *const fn (*anyopaque) ?f32,
};

pub fn deinit(self: *Device) void {
    self.vtable.deinit(self.impl);
    self.* = undefined;
}
pub fn createFramebuffer(self: *Device, width: u32, height: u32) anyerror!Framebuffer {
    return self.createFramebufferDesc(.{ .extent = .{ .width = width, .height = height } });
}
pub fn createFramebufferDesc(self: *Device, desc: Framebuffer.FramebufferDesc) anyerror!Framebuffer {
    return self.vtable.createFramebuffer(self.impl, desc);
}
pub fn destroyFramebuffer(self: *Device, value: *Framebuffer) void {
    self.vtable.destroyFramebuffer(self.impl, value);
}
pub fn resizeFramebuffer(self: *Device, value: *Framebuffer, extent: Framebuffer.Extent2D) anyerror!void {
    return self.vtable.resizeFramebuffer(self.impl, value, extent);
}
pub fn beginRenderPass(self: *Device, info: RenderPassInfo) anyerror!void {
    return self.vtable.beginRenderPass(self.impl, info);
}
pub fn bindRenderTarget(self: *Device, target: RenderTarget) void {
    self.vtable.bindRenderTarget(self.impl, target);
}
pub fn endRenderPass(self: *Device) void {
    self.vtable.endRenderPass(self.impl);
}
pub fn framebufferColorView(self: *Device, value: *const Framebuffer) TextureView {
    return self.vtable.framebufferColorView(self.impl, value);
}
pub fn textureViewNativeId(self: *Device, view: TextureView) u32 {
    return self.vtable.textureViewNativeId(self.impl, view);
}

pub fn createTexture(self: *Device, desc: Texture.Desc) anyerror!Texture {
    return self.vtable.createTexture(self.impl, desc);
}
pub fn destroyTexture(self: *Device, value: *Texture) void {
    self.vtable.destroyTexture(self.impl, value);
}
pub fn textureView(_: *Device, value: Texture) TextureView {
    return TextureView.fromTexture(value);
}
pub fn createSampler(self: *Device, desc: Sampler.Desc) anyerror!Sampler {
    return self.vtable.createSampler(self.impl, desc);
}
pub fn destroySampler(self: *Device, value: *Sampler) void {
    self.vtable.destroySampler(self.impl, value);
}
pub fn bindTexture(self: *Device, view: TextureView, sampler: Sampler, unit: u16) void {
    self.vtable.bindTexture(self.impl, view, sampler, unit);
}

pub fn createBuffer(self: *Device, desc: Buffer.Desc) anyerror!Buffer {
    return self.vtable.createBuffer(self.impl, desc);
}
pub fn updateBuffer(self: *Device, value: Buffer, offset: usize, data: []const u8) anyerror!void {
    return self.vtable.updateBuffer(self.impl, value, offset, data);
}
pub fn destroyBuffer(self: *Device, value: *Buffer) void {
    self.vtable.destroyBuffer(self.impl, value);
}
pub fn createGeometry(self: *Device, desc: Geometry.Desc) anyerror!Geometry {
    return self.vtable.createGeometry(self.impl, desc);
}
pub fn destroyGeometry(self: *Device, value: *Geometry) void {
    self.vtable.destroyGeometry(self.impl, value);
}
/// `base_vertex` is added to every index before fetching vertices.
pub fn drawIndexed(self: *Device, geometry: Geometry, first_index: u32, index_count: u32, base_vertex: i32) void {
    self.vtable.drawIndexed(self.impl, geometry, first_index, index_count, base_vertex);
}

pub fn createGraphicsPipeline(self: *Device, desc: GraphicsPipeline.GraphicsPipelineDesc) anyerror!GraphicsPipeline {
    return self.vtable.createGraphicsPipeline(self.impl, desc);
}
pub fn destroyGraphicsPipeline(self: *Device, value: *GraphicsPipeline) void {
    self.vtable.destroyGraphicsPipeline(self.impl, value);
}
pub fn bindGraphicsPipeline(self: *Device, value: GraphicsPipeline) void {
    self.vtable.bindGraphicsPipeline(self.impl, value);
}
pub fn graphicsPipelineUniformLocation(self: *Device, value: GraphicsPipeline, name: []const u8) ?GraphicsPipeline.UniformLocation {
    return self.graphicsPipelineUniformLocationByHash(value, zimp.nameHash(name));
}
/// `name_hash` is `zimp.nameHash` of the uniform name, as cooked materials store it.
pub fn graphicsPipelineUniformLocationByHash(self: *Device, value: GraphicsPipeline, name_hash: u64) ?GraphicsPipeline.UniformLocation {
    return self.vtable.graphicsPipelineUniformLocation(self.impl, value, name_hash);
}
pub fn setGraphicsPipelineUniform(self: *Device, pipeline: GraphicsPipeline, location: GraphicsPipeline.UniformLocation, value: GraphicsPipeline.UniformValue) void {
    self.vtable.setGraphicsPipelineUniform(self.impl, pipeline, location, value);
}
pub fn setGraphicsPipelineUniformByName(self: *Device, pipeline: GraphicsPipeline, name: []const u8, value: GraphicsPipeline.UniformValue) void {
    const location = self.graphicsPipelineUniformLocation(pipeline, name) orelse return;
    self.setGraphicsPipelineUniform(pipeline, location, value);
}

pub fn beginGpuTimer(self: *Device) void {
    self.vtable.beginGpuTimer(self.impl);
}
pub fn endGpuTimer(self: *Device) void {
    self.vtable.endGpuTimer(self.impl);
}
pub fn pollGpuTime(self: *Device) ?f32 {
    return self.vtable.pollGpuTime(self.impl);
}
