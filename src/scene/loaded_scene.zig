const zimp = @import("zimp");
const std = @import("std");
const zcs = @import("zcs");

const AssetManager = @import("../assets/asset_manager.zig").AssetManager;
const SceneRuntimeInstance = @import("runtime_instance.zig");
const SchemaRegistry = @import("schema_registry.zig");
const Project = @import("../project/project.zig");
const camera = @import("camera.zig");

const scene = zimp.scene;

const LoadedScene = @This();

const RuntimeContext = SceneRuntimeInstance.RuntimeContext;

instance: SceneRuntimeInstance,
document: scene.SceneDocument,
context: RuntimeContext,

pub fn init(allocator: std.mem.Allocator, document: scene.SceneDocument, registry: *SchemaRegistry, assets: *AssetManager, world: *zcs.World) !LoadedScene {
    return .{
        .instance = .init(allocator, document.scene_id),
        .document = document,
        .context = .{
            .world = world,
            .registry = registry,
            .assets = assets,
        },
    };
}

pub fn start(self: *LoadedScene) !void {
    try self.instance.spawnEntities(self.context, &self.document);
}

pub fn spawnEntity(self: *LoadedScene, entity: scene.SceneEntity) !zcs.EntityID {
    return self.instance.spawnEntity(self.context, entity);
}

pub fn removeEntity(self: *LoadedScene, id: zimp.SceneEntityId) !void {
    return self.instance.despawnEntity(self.context, id);
}

pub fn setActiveCamera(self: *LoadedScene, id: zimp.SceneEntityId) !void {
    const entity_id = try self.instance.resolve(id);
    try camera.setActive(self.context.world, entity_id);
}

pub fn clearActiveCamera(self: *LoadedScene) void {
    camera.clearActive(self.context.world);
}

pub fn addComponent(self: *LoadedScene, entity: *const scene.SceneEntity, component: scene.SceneComponent) !void {
    const entity_id = try self.instance.resolve(entity.id);
    return self.instance.addComponent(self.context, entity_id, component);
}

pub fn removeComponent(self: *LoadedScene, entity: *const scene.SceneEntity, component: zimp.ComponentTypeId) !void {
    const entity_id = try self.instance.resolve(entity.id);
    return self.instance.removeComponent(self.context, entity_id, component);
}

pub fn setField(self: *LoadedScene, entity: *const scene.SceneEntity, component: zimp.ComponentTypeId, number: u32, value: zimp.scene.Value) !void {
    const entity_id = try self.instance.resolve(entity.id);
    return self.instance.setField(self.context, entity_id, component, number, value);
}

pub fn addField(self: *LoadedScene, entity: *const scene.SceneEntity, component: zimp.ComponentTypeId, number: u32, value: zimp.scene.Value) !void {
    const entity_id = try self.instance.resolve(entity.id);
    return self.instance.addField(self.context, entity_id, component, number, value);
}

pub fn removeField(self: *LoadedScene, entity: *const scene.SceneEntity, component: zimp.ComponentTypeId, number: u32) !void {
    const entity_id = try self.instance.resolve(entity.id);
    return self.instance.removeField(self.context, entity_id, component, number);
}

pub fn deinit(self: *LoadedScene) void {
    self.instance.deinit(self.context.world);
    self.document.deinit();
}

pub fn reset(self: *LoadedScene) !void {
    self.instance.reset(self.context.world);
    try self.instance.spawnEntities(self.context, &self.document);
}

const testing = std.testing;

const TestSceneComponent = struct {
    value: i32 = 3,

    pub const schema_meta: zimp.scene.SchemaMeta = .{
        .id = "b2eb84d4-117b-4867-8c5b-133a20c80a90",
        .name = "LoadedSceneTestComponent",
        .version = 1,
        .fields = &.{.{ .name = "value", .number = 1 }},
    };
};

const test_scene_id = zimp.SceneId.parseComptime("a972b5bb-4fe8-4fec-96b5-a8ee2752e95a");
const test_project_id = zimp.ProjectId.parseComptime("4a813d51-24df-4e16-944b-2c9092b45944");
const test_entity_id = zimp.SceneEntityId.parseComptime("bbb640d3-0fdf-4863-a1b8-26c7c2b1c6eb");
const added_entity_id = zimp.SceneEntityId.parseComptime("1e2ab6cd-a441-4129-b735-c4d674fdb2fd");
const test_component_id = zimp.ComponentTypeId.parseComptime(TestSceneComponent.schema_meta.id);

test "LoadedScene keeps runtime entities and components synchronized through its mutation operations" {
    var fields = [_]scene.SceneField{.{ .number = 1, .value = .{ .i32 = 5 } }};
    var components = [_]scene.SceneComponent{.{ .type_id = test_component_id, .fields = &fields }};
    var entities = [_]scene.SceneEntity{.{
        .id = test_entity_id,
        .name = "entity",
        .components = &components,
        .prefab = .{},
    }};
    const document: scene.SceneDocument = .{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .format = "fusion.scene",
        .version = 1,
        .scene_id = test_scene_id,
        .project_id = test_project_id,
        .name = "loaded-scene-test",
        .entities = &entities,
    };

    var world = zcs.World.init(testing.allocator);
    defer world.deinit();
    _ = try world.registerType(TestSceneComponent, .{ .schema_hash = 0 });
    var registry = SchemaRegistry.init(testing.allocator);
    defer registry.deinit();
    try registry.register(TestSceneComponent);
    var assets: AssetManager = undefined;
    var loaded = try LoadedScene.init(testing.allocator, document, &registry, &assets, &world);
    defer loaded.deinit();

    try loaded.start();
    const entity = try loaded.instance.resolve(test_entity_id);
    try testing.expectEqual(@as(i32, 5), world.getComponent(entity, TestSceneComponent).?.value);

    const document_entity = &loaded.document.entities[0];
    try loaded.setField(document_entity, test_component_id, 1, .{ .i32 = 8 });
    try testing.expectEqual(@as(i32, 8), world.getComponent(entity, TestSceneComponent).?.value);
    try loaded.addField(document_entity, test_component_id, 1, .{ .i32 = 13 });
    try testing.expectEqual(@as(i32, 13), world.getComponent(entity, TestSceneComponent).?.value);
    try loaded.removeField(document_entity, test_component_id, 1);
    try testing.expectEqual(@as(i32, 3), world.getComponent(entity, TestSceneComponent).?.value);

    try loaded.removeComponent(document_entity, test_component_id);
    try testing.expect(world.getComponent(entity, TestSceneComponent) == null);
    try loaded.addComponent(document_entity, components[0]);
    try testing.expectEqual(@as(i32, 5), world.getComponent(entity, TestSceneComponent).?.value);

    const added_entity: scene.SceneEntity = .{
        .id = added_entity_id,
        .name = "added",
        .components = &.{},
        .prefab = .{},
    };
    const added_runtime = try loaded.spawnEntity(added_entity);
    try testing.expect(world.isAlive(added_runtime));
    try loaded.removeEntity(added_entity_id);
    try testing.expect(!world.isAlive(added_runtime));

    try loaded.reset();
    const reset_entity = try loaded.instance.resolve(test_entity_id);
    try testing.expect(world.isAlive(reset_entity));
    try testing.expectEqual(@as(i32, 5), world.getComponent(reset_entity, TestSceneComponent).?.value);
}

test "loadDefaultScene rejects projects without a configured default scene" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var project = Project{
        .manifest = .{ .project_id = .zero },
        .root_dir = try std.Io.Dir.openDir(tmp.dir, std.testing.io, ".", .{}),
    };
    defer project.root_dir.close(std.testing.io);

    try std.testing.expectError(
        error.DefaultSceneNotFound,
        project.loadDefaultScene(std.testing.allocator, std.testing.io),
    );
}
