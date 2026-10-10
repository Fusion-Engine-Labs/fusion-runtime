const zimp = @import("zimp");

const ResourceHandle = @import("resource_handle.zig");

pub const Filter = enum {
    nearest,
    linear,
};

pub const MipFilter = enum {
    none,
    nearest,
    linear,
};

pub const AddressMode = enum {
    repeat,
    clamp_to_edge,
    mirrored_repeat,
};

pub const Desc = struct {
    min_filter: Filter = .linear,
    mag_filter: Filter = .linear,
    mip_filter: MipFilter = .linear,
    address_u: AddressMode = .repeat,
    address_v: AddressMode = .repeat,
    max_anisotropy: f32 = 8,

    pub fn fromSamplerDesc(sampler: zimp.SamplerDesc) Desc {
        return .{
            .min_filter = convert(Filter, sampler.min_filter),
            .mag_filter = convert(Filter, sampler.mag_filter),
            .mip_filter = convert(MipFilter, sampler.mip_filter),
            .address_u = convert(AddressMode, sampler.wrap_s),
            .address_v = convert(AddressMode, sampler.wrap_t),
            .max_anisotropy = sampler.max_anisotropy,
        };
    }

    fn convert(comptime T: type, value: anytype) T {
        return switch (value) {
            inline else => |tag| @field(T, @tagName(tag)),
        };
    }
};

const Sampler = @This();
handle: ResourceHandle,
