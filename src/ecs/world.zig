const zimp = @import("zimp");
const zcs = @import("zcs");
const std = @import("std");

const deriveCodec = @import("../scene/derive_schema.zig").deriveCodec;
const AssetManager = @import("../assets/asset_manager.zig").AssetManager;
const SceneRuntimeInstance = @import("../scene/runtime_instance.zig");
const SchemaRegistry = @import("../scene/schema_registry.zig");
const LoadedScene = @import("../scene/loaded_scene.zig");
const components = @import("components.zig");
const Game = @import("../core/game.zig");

pub const EntityID = zcs.EntityID;

const WorldInstance = @This();

world: zcs.World,
schemas: *SchemaRegistry,
command_buffer: zcs.CommandBuffer,
active_scene: ?LoadedScene = null,

pub fn init(self: *WorldInstance, allocator: std.mem.Allocator, schemas: *SchemaRegistry, comptime game: Game) !void {
    var world = zcs.World.init(allocator);
    errdefer world.deinit();

    try registerEngineComponents(&world, schemas);
    try registerGameComponenets(
        &world,
        schemas,
        game.components,
    );

    self.* = .{
        .world = world,
        .schemas = schemas,
        .command_buffer = undefined,
    };
    self.command_buffer = zcs.CommandBuffer.init(&self.world);
}

pub fn deinit(self: *WorldInstance) void {
    if (self.active_scene) |*scene| {
        scene.deinit();
        self.active_scene = null;
    }
    self.command_buffer.deinit();
    self.world.deinit();
}

pub fn startScene(
    self: *WorldInstance,
    allocator: std.mem.Allocator,
    assets: *AssetManager,
    document: zimp.scene.SceneDocument,
) !void {
    var owned_document = document;
    if (self.active_scene) |*scene| {
        if (!scene.document.scene_id.eql(owned_document.scene_id)) {
            scene.deinit();
            self.active_scene = null;
        } else {
            owned_document.deinit();
            return;
        }
    }

    var scene = try LoadedScene.init(
        allocator,
        owned_document,
        self.schemas,
        assets,
        &self.world,
    );
    errdefer scene.deinit();
    try scene.start();

    self.active_scene = scene;
}

pub fn resetActiveScene(self: *WorldInstance) !void {
    if (self.active_scene) |*scene| {
        try scene.reset();
    }
}

pub fn activeSceneDocument(self: *const WorldInstance) ?*const LoadedScene {
    if (self.active_scene) |*scene| {
        return scene;
    }
    return null;
}

pub fn setResource(self: *WorldInstance, comptime Resource: type, value: Resource) !void {
    try self.world.setResource(Resource, value);
}

pub fn getResource(self: *WorldInstance, comptime Resource: type) *Resource {
    return self.world.getResource(Resource);
}

pub fn registerEngineComponents(world: *zcs.World, schemas: *SchemaRegistry) !void {
    const engine_components = &.{
        components.TransformComponent,
        components.MeshRenderComponent,
        components.CameraComponent,
        components.ActiveCamera,
    };
    inline for (engine_components) |Component| {
        _ = try registerComponent(world, Component, "fusion.runtime." ++ @typeName(Component));
    }
    try schemas.registerComponents(engine_components);
}

pub fn registerGameComponenets(world: *zcs.World, schemas: *SchemaRegistry, comptime component_types: []const type) !void {
    inline for (component_types) |Component| {
        const name = if (@hasDecl(Component, "schema_meta"))
            Component.schema_meta.name
        else
            @typeName(Component);
        _ = try registerComponent(world, Component, name);
    }
    try schemas.registerComponents(component_types);
}

fn registerComponent(world: *zcs.World, comptime T: type, name: []const u8) !zcs.ComponentId {
    const codec = comptime deriveCodec(T);
    const schema_hash = zimp.scene.descriptor.schemaHash(&.{codec.schema});
    return world.registerType(T, .{ .name = name, .schema_hash = schema_hash });
}

const testing = std.testing;

const TestGameComponent = struct {
    charge: i32 = 0,

    pub const schema_meta = zimp.scene.SchemaMeta{
        .id = "12341234-1234-4234-8234-123412341234",
        .name = "test.game.component",
        .display_name = "Test Game Component",
        .version = 1,
        .fields = &.{.{ .name = "charge", .number = 1 }},
    };
};

const empty_game: Game = .{ .components = &.{}, .update_schedule = .{} };
const game_with_component: Game = .{ .components = &.{TestGameComponent}, .update_schedule = .{} };

test "init registers engine components and schemas" {
    var schemas = SchemaRegistry.init(testing.allocator);
    defer schemas.deinit();

    var instance: WorldInstance = undefined;
    try instance.init(testing.allocator, &schemas, empty_game);
    defer instance.deinit();

    try testing.expect(schemas.getByName("fusion.runtime.transform") != null);
    try testing.expect(schemas.getByName("fusion.runtime.mesh.render") != null);
    try testing.expect(schemas.getByName("fusion.runtime.camera") != null);
    try testing.expect(schemas.getByName("fusion.runtime.active_camera") != null);
    try testing.expect(instance.active_scene == null);
}

test "init also registers game-specific components" {
    var schemas = SchemaRegistry.init(testing.allocator);
    defer schemas.deinit();

    var instance: WorldInstance = undefined;
    try instance.init(testing.allocator, &schemas, game_with_component);
    defer instance.deinit();

    const codec = schemas.getByName("test.game.component").?;
    try testing.expectEqual(@as(usize, 1), codec.schema.fields.len);
}

test "setResource and getResource round-trip a value" {
    var schemas = SchemaRegistry.init(testing.allocator);
    defer schemas.deinit();

    var instance: WorldInstance = undefined;
    try instance.init(testing.allocator, &schemas, empty_game);
    defer instance.deinit();

    const Score = struct { value: i32 };
    try instance.setResource(Score, .{ .value = 42 });
    try testing.expectEqual(@as(i32, 42), instance.getResource(Score).value);

    instance.getResource(Score).value = 7;
    try testing.expectEqual(@as(i32, 7), instance.getResource(Score).value);
}

test "resetActiveScene is a no-op without an active scene" {
    var schemas = SchemaRegistry.init(testing.allocator);
    defer schemas.deinit();

    var instance: WorldInstance = undefined;
    try instance.init(testing.allocator, &schemas, empty_game);
    defer instance.deinit();

    try instance.resetActiveScene();
}
