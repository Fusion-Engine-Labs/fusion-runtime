const zimp = @import("zimp");
const std = @import("std");

const GraphicsPipeline = @import("rhi/graphics_pipeline.zig");
const TextureView = @import("rhi/texture_view.zig");
const Sampler = @import("rhi/sampler.zig");
const Device = @import("rhi/device.zig");

const Material = @This();

pipeline: GraphicsPipeline,
device: *Device,
/// Owns the cooked file bytes that `source` views into.
cooked: zimp.runtime.Asset,
source: zimp.Zamat,
texture_bindings: []TextureBinding,
/// Material params and per-slot uniforms, resolved once in `init`; the values
/// never change, so `bindResources` only uploads them.
uniform_bindings: []UniformBinding,
allocator: std.mem.Allocator,

pub const TextureBinding = struct {
    unit: u16,
    view: TextureView,
    sampler: Sampler,
    /// `zimp.nameHash` of the sampler uniform.
    name_hash: u64,
    uv_set: u32,
    uv_offset: [2]f32,
    uv_scale: [2]f32,
    uv_rotation: f32,
    normal_scale: f32,
    occlusion_strength: f32,
    /// Resolved once in `init`; `bindResources` runs per draw batch and should
    /// not pay for a uniform name lookup there.
    location: ?GraphicsPipeline.UniformLocation = null,

    fn uvTransform(self: TextureBinding) [3][3]f32 {
        const c = @cos(self.uv_rotation);
        const s = @sin(self.uv_rotation);
        const sx = self.uv_scale[0];
        const sy = self.uv_scale[1];

        // offset + rotation * (scale * uv)
        return .{
            .{ c * sx, s * sx, 0 },
            .{ -s * sy, c * sy, 0 },
            .{ self.uv_offset[0], self.uv_offset[1], 1 },
        };
    }
};

pub const UniformBinding = struct {
    location: GraphicsPipeline.UniformLocation,
    value: GraphicsPipeline.UniformValue,
};

/// Takes ownership of `cooked`, which must hold a material view.
pub fn init(
    allocator: std.mem.Allocator,
    cooked: zimp.runtime.Asset,
    pipeline: GraphicsPipeline,
    texture_bindings: []TextureBinding,
    device: *Device,
) !Material {
    const source = cooked.view.material;

    var uniforms: std.ArrayList(UniformBinding) = .empty;
    errdefer uniforms.deinit(allocator);

    for (texture_bindings) |*binding| {
        binding.location = device.graphicsPipelineUniformLocationByHash(pipeline, binding.name_hash);

        if (device.graphicsPipelineUniformLocationByHash(pipeline, zimp.nameHashAppend(binding.name_hash, "_uv_set"))) |location| {
            try uniforms.append(allocator, .{ .location = location, .value = .{ .int = @intCast(binding.uv_set) } });
        }
        if (device.graphicsPipelineUniformLocationByHash(pipeline, zimp.nameHashAppend(binding.name_hash, "_uv_transform"))) |location| {
            try uniforms.append(allocator, .{ .location = location, .value = .{ .mat3 = binding.uvTransform() } });
        }
        if (binding.name_hash == normal_map_hash) {
            if (device.graphicsPipelineUniformLocation(pipeline, "u_normal_scale")) |location| {
                try uniforms.append(allocator, .{ .location = location, .value = .{ .float = binding.normal_scale } });
            }
        }
        if (binding.name_hash == ao_map_hash) {
            if (device.graphicsPipelineUniformLocation(pipeline, "u_occlusion_strength")) |location| {
                try uniforms.append(allocator, .{ .location = location, .value = .{ .float = binding.occlusion_strength } });
            }
        }
    }

    // After the slot uniforms, so an explicit param wins, as before.
    for (0..source.params.len) |i| {
        const param = source.param(i);
        const location = device.graphicsPipelineUniformLocationByHash(pipeline, param.name_hash) orelse continue;
        try uniforms.append(allocator, .{ .location = location, .value = switch (param.value) {
            .float => |v| .{ .float = v },
            .vec2 => |v| .{ .vec2 = v },
            .vec3 => |v| .{ .vec3 = v },
            .vec4 => |v| .{ .vec4 = v },
            .int => |v| .{ .int = v },
            .bool => |v| .{ .int = @intFromBool(v) },
        } });
    }

    if (source.render_state.alpha_mode == .alpha_test) {
        if (device.graphicsPipelineUniformLocation(pipeline, "u_alpha_cutoff")) |location| {
            try uniforms.append(allocator, .{ .location = location, .value = .{ .float = source.render_state.alpha_cutoff } });
        }
    }

    return .{
        .pipeline = pipeline,
        .device = device,
        .cooked = cooked,
        .source = source,
        .texture_bindings = texture_bindings,
        .uniform_bindings = try uniforms.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

const normal_map_hash = zimp.nameHash("u_normal_map");
const ao_map_hash = zimp.nameHash("u_ao_map");

pub fn bindResources(self: *const Material) void {
    for (self.texture_bindings) |*binding| {
        self.device.bindTexture(binding.view, binding.sampler, binding.unit);
        if (binding.location) |location| {
            self.device.setGraphicsPipelineUniform(self.pipeline, location, .{ .int = @intCast(binding.unit) });
        }
    }

    for (self.uniform_bindings) |binding| {
        self.device.setGraphicsPipelineUniform(self.pipeline, binding.location, binding.value);
    }
}

pub fn deinit(self: *Material) void {
    self.allocator.free(self.uniform_bindings);
    self.allocator.free(self.texture_bindings);
    self.cooked.deinit(self.allocator);
}
