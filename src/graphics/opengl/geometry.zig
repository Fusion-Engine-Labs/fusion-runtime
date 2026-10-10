const std = @import("std");

const Geometry = @import("../rhi/geometry.zig");
const layout = @import("../layout.zig");
const gl = @import("../../c.zig").glad;

const OpenGLGeometry = @This();
id: u32,
index_format: Geometry.IndexFormat,
index_count: u32,

pub const Stream = struct {
    buffer_id: u32,
    attribute: layout.StreamAttribute,
};

pub fn init(streams: []const Stream, index_buffer_id: u32, format: Geometry.IndexFormat, count: u32) !OpenGLGeometry {
    var id: u32 = 0;
    gl.glGenVertexArrays(1, &id);
    if (id == 0) {
        return error.GeometryCreationFailed;
    }

    gl.glBindVertexArray(id);
    for (streams) |stream| {
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, stream.buffer_id);
        const a = stream.attribute;
        const dt = a.data_type;
        gl.glEnableVertexAttribArray(a.location);
        if (dt.isIntegerType()) {
            gl.glVertexAttribIPointer(
                a.location,
                @intCast(dt.componentCount()),
                glType(dt),
                @intCast(dt.size()),
                null,
            );
        } else {
            gl.glVertexAttribPointer(
                a.location,
                @intCast(dt.componentCount()),
                glType(dt),
                if (a.normalized) gl.GL_TRUE else gl.GL_FALSE,
                @intCast(dt.size()),
                null,
            );
        }
    }

    gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, index_buffer_id);
    gl.glBindVertexArray(0);
    return .{ .id = id, .index_format = format, .index_count = count };
}

pub fn draw(self: OpenGLGeometry, bound_vao: *u32, first: u32, count: u32, base_vertex: i32) void {
    std.debug.assert(first + count <= self.index_count);
    const size: usize = if (self.index_format == .u16) 2 else 4;

    if (bound_vao.* != self.id) {
        gl.glBindVertexArray(self.id);
        bound_vao.* = self.id;
    }
    gl.glDrawElementsBaseVertex(
        gl.GL_TRIANGLES,
        @intCast(count),
        if (self.index_format == .u16) gl.GL_UNSIGNED_SHORT else gl.GL_UNSIGNED_INT,
        if (first == 0) null else @ptrFromInt(@as(usize, first) * size),
        base_vertex,
    );
}

pub fn deinit(self: *OpenGLGeometry) void {
    gl.glDeleteVertexArrays(1, &self.id);
    self.id = 0;
}

fn glType(dt: layout.DataType) u32 {
    return switch (dt) {
        .Float, .Float2, .Float3, .Float4, .Mat3, .Mat4 => gl.GL_FLOAT,
        .Int, .Int2, .Int3, .Int4 => gl.GL_INT,
        .Bool => gl.GL_BOOL,
        .Short2 => gl.GL_SHORT,
        .UShort2, .UShort4, .UShort4Norm => gl.GL_UNSIGNED_SHORT,
        .Byte4 => gl.GL_BYTE,
        .UByte4, .UByte4Norm => gl.GL_UNSIGNED_BYTE,
        .Half4 => gl.GL_HALF_FLOAT,
    };
}
