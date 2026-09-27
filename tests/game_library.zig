const std = @import("std");
const fusion = @import("fusion_runtime");
const testing = std.testing;

test "actual sandbox DLL registers, edits, serializes, queries and updates the host world" {
    var library = try fusion.game_module.GameLibrary.open(@import("test_options").library_path);
    defer library.deinit();
    var schemas = fusion.scene_schema.SchemaRegistry.init(testing.allocator);
    defer schemas.deinit();
    var instance: fusion.World = undefined;
    try instance.init(testing.allocator, &schemas, .{ .components = &.{}, .update_schedule = .{} });
    defer instance.deinit();
    try library.bind(&instance);
    const codec = schemas.getByName("fusion.game.KeyboardMovement") orelse return error.MissingGameComponent;
    try testing.expectEqualStrings("Keyboard Movement", codec.schema.display_name);
    try testing.expectEqual(@as(?f32, 0), codec.schema.fields[0].editor.min);
    const world = &instance.world;
    const moving = try world.spawnWith(.{fusion.components.TransformComponent{}});
    const stationary = try world.spawnWith(.{fusion.components.TransformComponent{}});
    try codec.attachDefault(world, moving, testing.allocator);
    try codec.writeField(world, moving, testing.allocator, 1, .{ .f32 = 3 });
    try testing.expectError(error.ValueKindMismatch, codec.writeField(world, moving, testing.allocator, 1, .{ .bool = true }));
    try testing.expectError(error.UnknownFieldNumber, codec.writeField(world, moving, testing.allocator, 99, .{ .f32 = 3 }));
    var document = try codec.readDocument(world, moving, testing.allocator);
    defer document.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 3), document.fields[0].value.f32);
    try codec.detach(world, moving, testing.allocator);
    try codec.attach(world, moving, testing.allocator, document);
    var input: fusion.Input = .{};
    input.applyEvent(.{ .KeyPressed = .W });
    input.applyEvent(.{ .KeyPressed = .LeftShift });
    try world.setResource(fusion.Input, input);
    try world.setResource(fusion.DeltaTime, .{ .seconds = 0.25 });
    try fusion.game_module.fixedUpdate(world, &instance.command_buffer);
    try testing.expectApproxEqAbs(@as(f32, -1.5), world.getComponent(moving, fusion.components.TransformComponent).?.position.z, 0.0001);
    try testing.expectEqual(@as(f32, 0), world.getComponent(stationary, fusion.components.TransformComponent).?.position.z);
    // Inspector edits remain visible to the DLL on the next update.
    try codec.writeField(world, moving, testing.allocator, 1, .{ .f32 = 4 });
    try fusion.game_module.fixedUpdate(world, &instance.command_buffer);
    try testing.expectApproxEqAbs(@as(f32, -3.5), world.getComponent(moving, fusion.components.TransformComponent).?.position.z, 0.0001);
    try testing.expectError(error.GameRegistrationFailed, library.bind(&instance));
}
