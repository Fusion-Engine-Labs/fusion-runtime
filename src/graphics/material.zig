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

    try appendUnsetDefaults(allocator, &uniforms, device.graphicsPipelineUniformDefaults(pipeline));

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

/// Uniforms the renderer sets itself for every pipeline or draw. Keep in
/// sync with `Renderer.renderQueue`.
const renderer_uniforms = [_]u64{
    zimp.nameHash("u_model"),
    zimp.nameHash("u_normal_matrix"),
    zimp.nameHash("u_view"),
    zimp.nameHash("u_projection"),
    zimp.nameHash("u_camera_pos"),
    zimp.nameHash("u_uv0_min"),
    zimp.nameHash("u_uv0_scale"),
    zimp.nameHash("u_pos_min"),
    zimp.nameHash("u_pos_scale"),
};

/// Uniforms are per-program state, so a param this material leaves out would
/// keep whatever the previous material drawn with the same shader set, and
/// the material would look different depending on draw order. Adds a binding
/// that restores the shader's own initial value for each such param.
fn appendUnsetDefaults(
    allocator: std.mem.Allocator,
    uniforms: *std.ArrayList(UniformBinding),
    defaults: []const GraphicsPipeline.UniformDefault,
) !void {
    const material_count = uniforms.items.len;
    next: for (defaults) |default| {
        for (renderer_uniforms) |hash| {
            if (hash == default.name_hash) continue :next;
        }
        for (uniforms.items[0..material_count]) |binding| {
            if (binding.location.slot == default.location.slot) continue :next;
        }
        try uniforms.append(allocator, .{ .location = default.location, .value = default.value });
    }
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

const testing = std.testing;

fn testDefault(name: []const u8, slot: u32, value: GraphicsPipeline.UniformValue) GraphicsPipeline.UniformDefault {
    return .{ .name_hash = zimp.nameHash(name), .location = .{ .slot = slot }, .value = value };
}

test "params a material leaves out are reset to the shader's initial values" {
    var uniforms: std.ArrayList(UniformBinding) = .empty;
    defer uniforms.deinit(testing.allocator);
    // The material sets only its base color (slot 3).
    try uniforms.append(testing.allocator, .{ .location = .{ .slot = 3 }, .value = .{ .vec4 = .{ 1, 0, 0, 1 } } });

    const defaults = [_]GraphicsPipeline.UniformDefault{
        testDefault("u_base_color", 3, .{ .vec4 = .{ 0, 0, 0, 0 } }),
        testDefault("u_emissive", 5, .{ .vec3 = .{ 0, 0, 0 } }),
        testDefault("u_roughness", 6, .{ .float = 0 }),
        testDefault("u_model", 0, .{ .mat4 = @splat(@splat(0)) }),
        testDefault("u_camera_pos", 9, .{ .vec3 = .{ 0, 0, 0 } }),
    };
    try appendUnsetDefaults(testing.allocator, &uniforms, &defaults);

    // The material's own value stays, unset params get the shader defaults,
    // and the renderer's per-draw uniforms are left alone.
    try testing.expectEqual(@as(usize, 3), uniforms.items.len);
    try testing.expectEqual([4]f32{ 1, 0, 0, 1 }, uniforms.items[0].value.vec4);
    try testing.expectEqual(@as(u32, 5), uniforms.items[1].location.slot);
    try testing.expectEqual([3]f32{ 0, 0, 0 }, uniforms.items[1].value.vec3);
    try testing.expectEqual(@as(u32, 6), uniforms.items[2].location.slot);
}
