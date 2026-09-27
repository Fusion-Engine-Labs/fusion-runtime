const std = @import("std");

const components = @import("../ecs/components.zig");
const math = @import("../core/math.zig");
const ecs = @import("../ecs/world.zig");
const zcs = @import("zcs");

const Mat4 = math.Mat4;

pub const ActiveCamera = components.ActiveCamera;

const expectApproxEq = std.testing.expectApproxEqAbs;
const tolerance: f32 = 1e-4;

pub fn setActive(world: *zcs.World, entity: ecs.EntityID) !void {
    if (world.getComponent(entity, components.TransformComponent) == null or
        world.getComponent(entity, components.CameraComponent) == null)
    {
        return error.InvalidCamera;
    }
    if (selected(world)) |previous| {
        try world.removeComponent(previous, ActiveCamera);
    }
    try world.addComponent(entity, ActiveCamera, .{});
}

pub fn active(world: *zcs.World) ?ecs.EntityID {
    const entity = selected(world) orelse return null;
    if (world.getComponent(entity, components.TransformComponent) == null or
        world.getComponent(entity, components.CameraComponent) == null)
    {
        return null;
    }
    return entity;
}

pub fn clearActive(world: *zcs.World) void {
    const entity = selected(world) orelse return;
    world.removeComponent(entity, ActiveCamera) catch unreachable;
}

fn selected(world: *zcs.World) ?ecs.EntityID {
    var cameras = world.query(.{ .with = &.{ActiveCamera} });
    const row = cameras.each() orelse return null;
    std.debug.assert(cameras.each() == null);
    return row.entity();
}

test "camera projection uses the render-view aspect" {
    const camera = components.CameraComponent{};
    const projection = camera.projectionMatrix(2.0);
    const expected = Mat4.createPerspective(std.math.pi / 4.0, 2.0, 0.1, 1000.0);

    for (0..4) |row| {
        for (0..4) |col| {
            try expectApproxEq(projection.fields[row][col], expected.fields[row][col], tolerance);
        }
    }
}

test "active camera is marked on its entity" {
    var world = zcs.World.init(std.testing.allocator);
    defer world.deinit();
    var schemas = @import("schema_registry.zig").init(std.testing.allocator);
    defer schemas.deinit();
    try ecs.registerEngineComponents(&world, &schemas);

    const first = try world.spawnWith(.{
        components.TransformComponent{},
        components.CameraComponent{},
    });
    const second = try world.spawnWith(.{
        components.TransformComponent{},
        components.CameraComponent{},
    });

    try setActive(&world, first);
    try std.testing.expectEqual(first, active(&world).?);
    try std.testing.expect(world.hasComponent(first, ActiveCamera));

    try setActive(&world, second);
    try std.testing.expectEqual(second, active(&world).?);
    try std.testing.expect(!world.hasComponent(first, ActiveCamera));
    try std.testing.expect(world.hasComponent(second, ActiveCamera));

    clearActive(&world);
    try std.testing.expect(active(&world) == null);
    try std.testing.expect(!world.hasComponent(second, ActiveCamera));
}

test "active camera must have camera and transform components" {
    var world = zcs.World.init(std.testing.allocator);
    defer world.deinit();
    var schemas = @import("schema_registry.zig").init(std.testing.allocator);
    defer schemas.deinit();
    try ecs.registerEngineComponents(&world, &schemas);

    const entity = try world.spawn();
    try std.testing.expectError(error.InvalidCamera, setActive(&world, entity));
}
