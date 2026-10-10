const zimp = @import("zimp");
const std = @import("std");

const Geometry = @import("rhi/geometry.zig");
const Device = @import("rhi/device.zig");
const Buffer = @import("rhi/buffer.zig");
const math = @import("../core/math.zig");
const layout = @import("layout.zig");

pub const AttributeLocation = enum(u32) {
    Position = 0,
    Normal = 1,
    UV0 = 2,
    UV1 = 3,
    Tangent = 4,
    JointIndices = 5,
    JointWeights = 6,
};

const Mesh = @This();
allocator: std.mem.Allocator,
device: *Device,
material_ids: []zimp.AssetId,
/// One vertex array over buffers shared by every part.
geometry: Geometry,
buffers: []Buffer,
parts: []Part,

pub const Part = struct {
    /// `Mesh.geometry`; parts don't own it.
    geometry: Geometry,
    /// Added to the part-local indices when drawing.
    base_vertex: i32,
    transform: math.Mat4,
    /// Positions dequantize as `bounds_min + q * pos_scale`.
    bounds_min: [3]f32,
    bounds_max: [3]f32,
    pos_scale: [3]f32,
    submeshes: []Submesh,
    uv_min: [2]f32,
    uv_scale: [2]f32,
};

pub const Submesh = struct { material_index: u16, index_offset: u32, index_count: u32 };

/// Every stream and the index buffer of a cooked mesh, decoded into
/// upload-ready bytes. Built on a loader thread, so `upload` on the render
/// thread only creates GPU buffers.
pub const Decoded = struct {
    /// One allocation that `streams` and `indices` slice into.
    buffer: []align(4) u8,
    /// Empty for streams the mesh doesn't have.
    streams: std.EnumArray(zimp.MeshStream, []u8),
    indices: []align(4) u8,

    pub fn init(allocator: std.mem.Allocator, model: *const zimp.ZMesh) !Decoded {
        var offsets = std.EnumArray(zimp.MeshStream, usize).initFill(0);
        var total: usize = 0;
        for (std.enums.values(zimp.MeshStream)) |stream| {
            if (!model.hasStream(stream)) continue;
            offsets.set(stream, total);
            total = std.mem.alignForward(usize, total + model.decodedStreamSize(stream), 4);
        }
        const index_offset = total;
        total += model.decodedIndexSize();

        const buffer = try allocator.alignedAlloc(u8, .@"4", total);
        errdefer allocator.free(buffer);
        var streams = std.EnumArray(zimp.MeshStream, []u8).initFill(&.{});
        for (std.enums.values(zimp.MeshStream)) |stream| {
            if (!model.hasStream(stream)) continue;
            const bytes = buffer[offsets.get(stream)..][0..model.decodedStreamSize(stream)];
            try model.decodeStream(stream, bytes);
            streams.set(stream, bytes);
        }
        const indices: []align(4) u8 = @alignCast(buffer[index_offset..][0..model.decodedIndexSize()]);
        try model.decodeIndices(indices);
        return .{ .buffer = buffer, .streams = streams, .indices = indices };
    }

    pub fn deinit(self: *Decoded, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
        self.* = undefined;
    }
};

/// Uploads `decoded` (from `model`) to the GPU. The cooked bytes and the
/// decoded buffer can be freed afterwards.
pub fn upload(allocator: std.mem.Allocator, device: *Device, model: *const zimp.ZMesh, decoded: *const Decoded, material_ids: []zimp.AssetId) !Mesh {
    var buffers: std.ArrayList(Buffer) = .empty;
    errdefer {
        for (buffers.items) |*b| device.destroyBuffer(b);
        buffers.deinit(allocator);
    }
    var streams: std.ArrayList(Geometry.VertexStream) = .empty;
    defer streams.deinit(allocator);

    for (std.enums.values(zimp.MeshStream)) |stream| {
        if (!model.hasStream(stream)) continue;
        const bytes = decoded.streams.get(stream);
        const location: AttributeLocation, const data_type: layout.DataType, const normalized = switch (stream) {
            .positions => .{ .Position, .UShort4Norm, true },
            .normals => .{ .Normal, .Short2, true },
            .tangents => .{ .Tangent, .Byte4, true },
            .uv0 => .{ .UV0, .UShort2, true },
            .uv1 => .{ .UV1, .UShort2, true },
            .joints => .{ .JointIndices, if (model.jointFormat() == .u16) .UShort4 else .UByte4, false },
            .weights => .{ .JointWeights, .UByte4Norm, true },
        };
        try addStream(allocator, device, &buffers, &streams, bytes, location, data_type, normalized);
    }

    const index_bytes = decoded.indices;
    const index_buffer = try device.createBuffer(.{ .size = index_bytes.len, .usage = .{ .index = true }, .initial_data = index_bytes });
    buffers.append(allocator, index_buffer) catch |err| {
        var owned = index_buffer;
        device.destroyBuffer(&owned);
        return err;
    };
    const index_format: Geometry.IndexFormat = switch (model.indexFormat()) {
        .u16 => .u16,
        .u32 => .u32,
    };
    var geometry = try device.createGeometry(.{ .streams = streams.items, .index_buffer = index_buffer, .index_format = index_format, .index_count = model.indexCount() });
    errdefer device.destroyGeometry(&geometry);

    const parts = try allocator.alloc(Part, model.partCount());
    errdefer allocator.free(parts);
    var initialized: usize = 0;
    errdefer for (parts[0..initialized]) |part| allocator.free(part.submeshes);
    for (parts, 0..) |*part, i| {
        const source = model.part(i);
        const submeshes = try allocator.alloc(Submesh, source.submeshes.len);
        for (source.submeshes, submeshes) |src, *dst| {
            dst.* = .{ .material_index = src.material_index, .index_offset = src.index_offset, .index_count = src.index_count };
        }
        part.* = .{
            .geometry = geometry,
            .base_vertex = @intCast(source.base_vertex),
            .transform = mat4FromArray(source.transform),
            .bounds_min = source.aabb_min,
            .bounds_max = source.aabb_max,
            .pos_scale = .{
                source.aabb_max[0] - source.aabb_min[0],
                source.aabb_max[1] - source.aabb_min[1],
                source.aabb_max[2] - source.aabb_min[2],
            },
            .uv_min = source.uv0_min,
            .uv_scale = source.uv0_scale,
            .submeshes = submeshes,
        };
        initialized += 1;
    }

    return .{
        .allocator = allocator,
        .device = device,
        .material_ids = material_ids,
        .geometry = geometry,
        .buffers = try buffers.toOwnedSlice(allocator),
        .parts = parts,
    };
}

fn addStream(
    allocator: std.mem.Allocator,
    device: *Device,
    buffers: *std.ArrayList(Buffer),
    streams: *std.ArrayList(Geometry.VertexStream),
    bytes: []const u8,
    location: AttributeLocation,
    data_type: layout.DataType,
    normalized: bool,
) !void {
    const buffer = try device.createBuffer(.{ .size = bytes.len, .usage = .{ .vertex = true }, .initial_data = bytes });
    var buffer_owned = true;
    errdefer if (buffer_owned) {
        var owned = buffer;
        device.destroyBuffer(&owned);
    };

    try buffers.append(allocator, buffer);
    buffer_owned = false;
    try streams.append(
        allocator,
        .{ .buffer = buffer, .attribute = .{ .location = @intFromEnum(location), .data_type = data_type, .normalized = normalized } },
    );
}

pub fn materialIdForSlot(self: *const Mesh, slot: u16) ?zimp.AssetId {
    const i: usize = @intCast(slot);
    return if (i < self.material_ids.len) self.material_ids[i] else null;
}

pub fn deinit(self: *Mesh) void {
    for (self.parts) |part| self.allocator.free(part.submeshes);
    self.allocator.free(self.parts);
    self.device.destroyGeometry(&self.geometry);
    for (self.buffers) |*buffer| self.device.destroyBuffer(buffer);
    self.allocator.free(self.buffers);
    self.allocator.free(self.material_ids);
}

fn mat4FromArray(v: [16]f32) math.Mat4 {
    return .{ .fields = .{ .{ v[0], v[1], v[2], v[3] }, .{ v[4], v[5], v[6], v[7] }, .{ v[8], v[9], v[10], v[11] }, .{ v[12], v[13], v[14], v[15] } } };
}

test "mat4 conversion preserves translation" {
    const m = mat4FromArray(.{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 2, 3, 4, 1 });
    const p = math.Vec3.zero.transformPosition(m);
    try std.testing.expectEqual(@as(f32, 2), p.x);
}

test "Decoded holds each present stream and the indices, decoded" {
    const allocator = std.testing.allocator;
    var buf: [4096]u8 align(16) = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try zimp.formats.zmesh.writeTestZmeshFile(&writer);
    const model = try zimp.formats.zmesh.view(buf[0..writer.end]);

    var decoded = try Decoded.init(allocator, &model);
    defer decoded.deinit(allocator);

    for (std.enums.values(zimp.MeshStream)) |stream| {
        const bytes = decoded.streams.get(stream);
        if (!model.hasStream(stream)) {
            try std.testing.expectEqual(@as(usize, 0), bytes.len);
            continue;
        }
        const expected = try allocator.alloc(u8, model.decodedStreamSize(stream));
        defer allocator.free(expected);
        try model.decodeStream(stream, expected);
        try std.testing.expectEqualSlices(u8, expected, bytes);
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(bytes.ptr) % 4);
    }
    const expected_indices = try allocator.alignedAlloc(u8, .@"4", model.decodedIndexSize());
    defer allocator.free(expected_indices);
    try model.decodeIndices(expected_indices);
    try std.testing.expectEqualSlices(u8, expected_indices, decoded.indices);
}
