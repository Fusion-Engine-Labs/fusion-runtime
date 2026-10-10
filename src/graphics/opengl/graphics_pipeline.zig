const std = @import("std");
const zimp = @import("zimp");
/// Active uniform locations keyed by `zimp.nameHash` of the uniform name.
const Map = std.AutoHashMapUnmanaged(u64, u32);

const rhi = @import("../rhi/graphics_pipeline.zig");
const render_state = @import("render_state.zig");
const log = @import("../../core/log.zig");
const c = @import("../../c.zig");
const gl = c.glad;

pub const GraphicsPipelineError = error{
    UnsupportedShaderCode,
    TooManyShaderSourceParts,
    VertexShaderCreationFailed,
    FragmentShaderCreationFailed,
    VertexShaderCompilationFailed,
    FragmentShaderCompilationFailed,
    ProgramCreationFailed,
    ProgramLinkingFailed,
    UniformNameHashCollision,
    OpenGLError,
    OutOfMemory,
};

const GraphicsPipeline = @This();

id: u32,
allocator: std.mem.Allocator,
uniforms: Map,
fixed_state: @import("../render_state.zig").FixedState,

pub fn init(allocator: std.mem.Allocator, desc: rhi.GraphicsPipelineDesc) GraphicsPipelineError!GraphicsPipeline {
    const vs_src = switch (desc.vertex) {
        .glsl => |source| source,
        .spirv => return GraphicsPipelineError.UnsupportedShaderCode,
    };
    const fs_src = switch (desc.fragment) {
        .glsl => |source| source,
        .spirv => return GraphicsPipelineError.UnsupportedShaderCode,
    };

    const vs = try compileShader(.vertex, vs_src);
    defer gl.glDeleteShader(vs);

    const fs = try compileShader(.fragment, fs_src);
    defer gl.glDeleteShader(fs);

    const program = gl.glCreateProgram();
    if (program == 0) {
        return GraphicsPipelineError.ProgramCreationFailed;
    }
    errdefer gl.glDeleteProgram(program);

    gl.glAttachShader(program, vs);
    gl.glAttachShader(program, fs);
    gl.glLinkProgram(program);

    var link_success: i32 = 0;
    gl.glGetProgramiv(program, gl.GL_LINK_STATUS, &link_success);
    if (link_success == 0) {
        var info_log: InfoLog = .{};
        log.err("graphics pipeline program linking failed: {s}", .{info_log.fetch(program, gl.glGetProgramInfoLog)});
        return GraphicsPipelineError.ProgramLinkingFailed;
    }

    return .{
        .id = program,
        .allocator = allocator,
        .uniforms = try getUniformLocations(program, allocator),
        .fixed_state = desc.fixed_state,
    };
}

const InfoLog = struct {
    buffer: [512]u8 = @splat(0),

    fn fetch(self: *InfoLog, object: u32, comptime getter: anytype) []const u8 {
        var len: c_int = 0;
        getter(object, self.buffer.len, &len, @ptrCast(&self.buffer));
        return self.buffer[0..@intCast(@min(@max(len, 0), self.buffer.len))];
    }
};

const max_source_parts = 64;

fn compileShader(comptime stage: enum { vertex, fragment }, parts: []const []const u8) GraphicsPipelineError!u32 {
    if (parts.len > max_source_parts) return GraphicsPipelineError.TooManyShaderSourceParts;
    var part_ptrs: [max_source_parts][*c]const u8 = undefined;
    var part_lens: [max_source_parts]c_int = undefined;
    for (parts, part_ptrs[0..parts.len], part_lens[0..parts.len]) |part, *ptr, *len| {
        ptr.* = @ptrCast(part.ptr);
        len.* = std.math.cast(c_int, part.len) orelse return GraphicsPipelineError.UnsupportedShaderCode;
    }

    const shader_type = switch (stage) {
        .vertex => gl.GL_VERTEX_SHADER,
        .fragment => gl.GL_FRAGMENT_SHADER,
    };
    const shader = gl.glCreateShader(shader_type);
    if (shader == 0) return switch (stage) {
        .vertex => GraphicsPipelineError.VertexShaderCreationFailed,
        .fragment => GraphicsPipelineError.FragmentShaderCreationFailed,
    };
    errdefer gl.glDeleteShader(shader);

    gl.glShaderSource(shader, @intCast(parts.len), &part_ptrs, &part_lens);
    gl.glCompileShader(shader);

    var success: i32 = 0;
    gl.glGetShaderiv(shader, gl.GL_COMPILE_STATUS, &success);
    if (success == 0) {
        var info_log: InfoLog = .{};
        log.err("{s} shader compilation failed: {s}", .{ @tagName(stage), info_log.fetch(shader, gl.glGetShaderInfoLog) });
        return switch (stage) {
            .vertex => GraphicsPipelineError.VertexShaderCompilationFailed,
            .fragment => GraphicsPipelineError.FragmentShaderCompilationFailed,
        };
    }

    return shader;
}

pub fn deinit(self: *GraphicsPipeline) void {
    self.uniforms.deinit(self.allocator);
    gl.glDeleteProgram(self.id);
    self.id = 0;
}

/// Keys by name hash because cooked materials store only hashes. Two active
/// uniforms with the same hash would make lookups ambiguous, so they fail the
/// pipeline instead.
fn getUniformLocations(program: u32, allocator: std.mem.Allocator) GraphicsPipelineError!Map {
    var count: i32 = 0;
    gl.glGetProgramiv(program, gl.GL_ACTIVE_UNIFORMS, &count);

    const uniform_count: u32 = @intCast(count);
    var map: Map = .empty;
    errdefer map.deinit(allocator);
    try map.ensureTotalCapacity(allocator, uniform_count);

    // Full names: a truncated name would hash differently, or make two
    // uniforms look like a collision.
    var max_length: i32 = 0;
    gl.glGetProgramiv(program, gl.GL_ACTIVE_UNIFORM_MAX_LENGTH, &max_length);
    const name_buf = try allocator.alloc(u8, @intCast(@max(max_length, 1)));
    defer allocator.free(name_buf);

    for (0..uniform_count) |i| {
        var length: i32 = 0;
        var size: i32 = 0;
        var ty: u32 = 0;
        gl.glGetActiveUniform(program, @intCast(i), @intCast(name_buf.len), &length, &size, &ty, @ptrCast(name_buf.ptr));
        const name_slice = name_buf[0..@intCast(length)];
        name_buf[@intCast(length)] = 0;
        const location = gl.glGetUniformLocation(program, @ptrCast(name_buf.ptr));
        // Built-ins and block members have no location.
        if (location < 0) continue;
        const entry = map.getOrPutAssumeCapacity(zimp.nameHash(name_slice));
        if (entry.found_existing) {
            log.err("graphics pipeline uniform '{s}' has the same name hash as another uniform", .{name_slice});
            return GraphicsPipelineError.UniformNameHashCollision;
        }
        entry.value_ptr.* = @intCast(location);
    }

    return map;
}

pub fn uniformLocation(self: *const GraphicsPipeline, name: []const u8) ?rhi.UniformLocation {
    return self.uniformLocationByHash(zimp.nameHash(name));
}

pub fn uniformLocationByHash(self: *const GraphicsPipeline, name_hash: u64) ?rhi.UniformLocation {
    return .{ .slot = self.uniforms.get(name_hash) orelse return null };
}

pub fn setUniformFromLocation(_: *const GraphicsPipeline, location: rhi.UniformLocation, value: rhi.UniformValue) void {
    const slot: i32 = @intCast(location.slot);
    switch (value) {
        .float => |v| gl.glUniform1f(slot, v),
        .int => |v| gl.glUniform1i(slot, v),
        .vec2 => |v| gl.glUniform2f(slot, v[0], v[1]),
        .vec3 => |v| gl.glUniform3f(slot, v[0], v[1], v[2]),
        .vec4 => |v| gl.glUniform4f(slot, v[0], v[1], v[2], v[3]),
        .mat3 => |v| gl.glUniformMatrix3fv(slot, 1, gl.GL_FALSE, @ptrCast(&v)),
        .mat4 => |v| gl.glUniformMatrix4fv(slot, 1, gl.GL_FALSE, @ptrCast(&v)),
    }
}

pub fn bind(self: *const GraphicsPipeline, cache: *render_state.Cache) void {
    gl.glUseProgram(self.id);
    render_state.apply(cache, self.fixed_state);
}
