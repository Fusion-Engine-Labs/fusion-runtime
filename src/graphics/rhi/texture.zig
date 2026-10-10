const ResourceHandle = @import("resource_handle.zig");

pub const Format = enum {
    r8_unorm,
    rg8_unorm,
    rgba8_unorm,
    rgba8_srgb,
    rgb16_float,
    rgba16_float,
    rgb9e5_ufloat,
    bc1_unorm,
    bc1_srgb,
    bc3_unorm,
    bc3_srgb,
    bc4_unorm,
    bc5_unorm,
    bc6h_ufloat,
    bc7_unorm,
    bc7_srgb,
    depth24_stencil8,
    depth32_float,
};

pub const Extent3D = struct {
    width: u32,
    height: u32,
    depth: u32 = 1,
};

pub const Usage = packed struct(u8) {
    sampled: bool = false,
    color_attachment: bool = false,
    depth_stencil_attachment: bool = false,
    transfer_dst: bool = false,
    _padding: u4 = 0,
};

pub const MipData = struct {
    extent: Extent3D,
    bytes: []const u8,
};

pub const Desc = struct {
    extent: Extent3D,
    format: Format,
    usage: Usage,
    mips: []const MipData,
};

const Texture = @This();
handle: ResourceHandle,
extent: Extent3D,
format: Format,
mip_count: u32,
