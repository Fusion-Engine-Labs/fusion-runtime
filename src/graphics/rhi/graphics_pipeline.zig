const ResourceHandle = @import("resource_handle.zig");
const render_state = @import("../render_state.zig");

pub const ShaderCode = union(enum) {
    /// Source pieces compiled as one concatenated string.
    glsl: []const []const u8,
    spirv: []const u32,
};

pub const GraphicsPipelineDesc = struct {
    vertex: ShaderCode,
    fragment: ShaderCode,
    fixed_state: render_state.FixedState,
};

pub const UniformLocation = struct {
    slot: u32,
};

pub const UniformValue = union(enum) {
    float: f32,
    int: i32,
    vec2: [2]f32,
    vec3: [3]f32,
    vec4: [4]f32,
    mat3: [3][3]f32,
    mat4: [4][4]f32,
};

/// A uniform's value right after the program was linked: its initializer in
/// the shader source, or zero.
pub const UniformDefault = struct {
    /// `zimp.nameHash` of the uniform name.
    name_hash: u64,
    location: UniformLocation,
    value: UniformValue,
};

const GraphicsPipeline = @This();

handle: ResourceHandle,
sort_key: u64,
