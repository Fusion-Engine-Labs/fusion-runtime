const zimp = @import("zimp");
const std = @import("std");

const math = @import("../core/math.zig");

const Material = @import("material.zig");
const Mesh = @import("mesh.zig");

pub const DrawItem = struct {
    part: *const Mesh.Part,
    submesh: *const Mesh.Submesh,

    material_id: zimp.AssetId,
    material: *const Material,

    model: math.Mat4,
    depth_key: f32,

    phase: zimp.AlphaMode,
    pipeline_key: u64,

    pub fn lessThan(_: void, a: DrawItem, b: DrawItem) bool {
        if (a.phase != b.phase) {
            return @backingInt(a.phase) < @backingInt(b.phase);
        }

        return switch (a.phase) {
            .solid, .alpha_test => lessOpaqueLike(a, b),
            .alpha_blend => lessTransparentLike(a, b),
        };
    }
};

fn lessOpaqueLike(a: DrawItem, b: DrawItem) bool {
    if (a.pipeline_key != b.pipeline_key) {
        return a.pipeline_key < b.pipeline_key;
    }

    if (!zimp.AssetId.eql(
        a.material_id,
        b.material_id,
    )) {
        return assetIdLessThan(
            a.material_id,
            b.material_id,
        );
    }

    return a.depth_key < b.depth_key;
}

fn lessTransparentLike(a: DrawItem, b: DrawItem) bool {
    if (a.depth_key != b.depth_key) {
        return a.depth_key > b.depth_key;
    }

    if (a.pipeline_key != b.pipeline_key) {
        return a.pipeline_key < b.pipeline_key;
    }

    return assetIdLessThan(
        a.material_id,
        b.material_id,
    );
}

fn assetIdLessThan(
    a: zimp.AssetId,
    b: zimp.AssetId,
) bool {
    return std.mem.readInt(u128, &a.uuid.bytes, .big) <
        std.mem.readInt(u128, &b.uuid.bytes, .big);
}

fn drawItem(phase: zimp.AlphaMode, depth_key: f32, material_id: zimp.AssetId, pipeline_key: u64) DrawItem {
    return .{
        .part = undefined,
        .submesh = undefined,
        .material_id = material_id,
        .material = undefined,
        .model = undefined,
        .depth_key = depth_key,
        .phase = phase,
        .pipeline_key = pipeline_key,
    };
}

const pipeline_a: u64 = 1;
const pipeline_b: u64 = 2;

const material_a = zimp.AssetId.parseComptime("11111111-1111-4111-8111-111111111111");
const material_b = zimp.AssetId.parseComptime("22222222-2222-4222-8222-222222222222");

test "draw items sort render phases before their per-phase keys" {
    var items = [_]DrawItem{
        drawItem(.alpha_blend, 10, material_b, pipeline_b),
        drawItem(.solid, 3, material_b, pipeline_b),
        drawItem(.alpha_test, 2, material_a, pipeline_a),
    };

    std.mem.sort(DrawItem, &items, {}, DrawItem.lessThan);

    try std.testing.expectEqual(zimp.AlphaMode.solid, items[0].phase);
    try std.testing.expectEqual(zimp.AlphaMode.alpha_test, items[1].phase);
    try std.testing.expectEqual(zimp.AlphaMode.alpha_blend, items[2].phase);
}

test "opaque draw items batch by pipeline then material then front-to-back depth" {
    var items = [_]DrawItem{
        drawItem(.solid, 5, material_a, pipeline_a),
        drawItem(.solid, 3, material_b, pipeline_a),
        drawItem(.solid, 1, material_a, pipeline_a),
        drawItem(.solid, 2, material_a, pipeline_b),
    };

    std.mem.sort(DrawItem, &items, {}, DrawItem.lessThan);

    try std.testing.expect(items[0].pipeline_key == pipeline_a);
    try std.testing.expect(items[0].material_id.eql(material_a));
    try std.testing.expectEqual(@as(f32, 1), items[0].depth_key);
    try std.testing.expectEqual(@as(f32, 5), items[1].depth_key);
    try std.testing.expect(items[2].material_id.eql(material_b));
    try std.testing.expect(items[3].pipeline_key == pipeline_b);
}

test "transparent draw items sort back-to-front before batching ties" {
    var items = [_]DrawItem{
        drawItem(.alpha_blend, 2, material_b, pipeline_b),
        drawItem(.alpha_blend, 8, material_b, pipeline_b),
        drawItem(.alpha_blend, 8, material_a, pipeline_b),
        drawItem(.alpha_blend, 8, material_a, pipeline_a),
    };

    std.mem.sort(DrawItem, &items, {}, DrawItem.lessThan);

    try std.testing.expectEqual(@as(f32, 8), items[0].depth_key);
    try std.testing.expect(items[0].pipeline_key == pipeline_a);
    try std.testing.expect(items[1].pipeline_key == pipeline_b);
    try std.testing.expect(items[1].material_id.eql(material_a));
    try std.testing.expectEqual(@as(f32, 2), items[3].depth_key);
}

test "asset id ordering stays byte-lexicographic over the uuid" {
    const low = zimp.AssetId.parseComptime("00000000-0000-4000-8000-000000000001");
    const high = zimp.AssetId.parseComptime("ff000000-0000-4000-8000-000000000000");

    try std.testing.expect(assetIdLessThan(low, high));
    try std.testing.expect(!assetIdLessThan(high, low));
    try std.testing.expect(!assetIdLessThan(low, low));
    try std.testing.expectEqual(
        std.mem.order(u8, &low.uuid.bytes, &high.uuid.bytes) == .lt,
        assetIdLessThan(low, high),
    );
}

test "pipeline ordering uses the backend-neutral pipeline sort key" {
    try std.testing.expect(pipeline_a < pipeline_b);
    try std.testing.expect(!(pipeline_b < pipeline_a));
}
