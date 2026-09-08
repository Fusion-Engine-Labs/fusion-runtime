const std = @import("std");

const zimp = @import("zimp");
const zcs = @import("zcs");

const activeCamera = @import("camera.zig").active;
const device_factory = @import("../graphics/device_factory.zig");
const TextureAsset = @import("../graphics/texture_asset.zig");
const asset_manager = @import("../assets/asset_manager.zig");
const SchemaRegistry = @import("schema_registry.zig");
const Material = @import("../graphics/material.zig");
const Project = @import("../project/project.zig");
const AssetManager = asset_manager.AssetManager;
const AssetError = asset_manager.AssetError;
const Mesh = @import("../graphics/mesh.zig");
const camera = @import("camera.zig");
const log = @import("../core/log.zig");

const SceneRuntimeInstance = @This();

const World = zcs.World;
const Registry = SchemaRegistry;

pub const RuntimeContext = struct {
    world: *World,
    registry: *const Registry,
    assets: *AssetManager,
};

allocator: std.mem.Allocator,
scene_id: zimp.SceneId,
scene_to_runtime: std.AutoHashMap(zimp.SceneEntityId, zcs.EntityID),
runtime_to_scene: std.AutoHashMap(zcs.EntityID, zimp.SceneEntityId),

pub fn init(allocator: std.mem.Allocator, scene_id: zimp.SceneId) SceneRuntimeInstance {
    return .{
        .allocator = allocator,
        .scene_id = scene_id,
        .scene_to_runtime = std.AutoHashMap(zimp.SceneEntityId, zcs.EntityID).init(allocator),
        .runtime_to_scene = std.AutoHashMap(zcs.EntityID, zimp.SceneEntityId).init(allocator),
    };
}

pub fn deinit(self: *SceneRuntimeInstance, world: *zcs.World) void {
    var entities = self.scene_to_runtime.valueIterator();
    while (entities.next()) |entity| {
        if (world.isAlive(entity.*)) {
            world.despawn(entity.*);
        }
    }
    self.scene_to_runtime.deinit();
    self.runtime_to_scene.deinit();
}

pub fn reset(self: *SceneRuntimeInstance, world: *zcs.World) void {
    var entities = self.scene_to_runtime.valueIterator();
    while (entities.next()) |entity| {
        if (world.isAlive(entity.*)) {
            world.despawn(entity.*);
        }
    }

    self.scene_to_runtime.clearRetainingCapacity();
    self.runtime_to_scene.clearRetainingCapacity();
}

pub fn resolve(self: *const SceneRuntimeInstance, id: zimp.SceneEntityId) !zcs.EntityID {
    return self.scene_to_runtime.get(id) orelse return error.SceneEntityNotFound;
}

pub fn spawnEntities(self: *SceneRuntimeInstance, context: RuntimeContext, scene: *const zimp.scene.SceneDocument) !void {
    for (scene.entities) |entity_data| {
        _ = try self.spawnEntity(context, entity_data);
    }
}

pub fn spawnEntity(
    self: *SceneRuntimeInstance,
    context: RuntimeContext,
    entity: zimp.scene.SceneEntity,
) !zcs.EntityID {
    const entity_id = try context.world.spawn();
    try self.scene_to_runtime.put(entity.id, entity_id);
    try self.runtime_to_scene.put(entity_id, entity.id);

    for (entity.components) |component_data| {
        try self.addComponent(
            context,
            entity_id,
            component_data,
        );
    }
    return entity_id;
}

pub fn addComponent(
    self: *SceneRuntimeInstance,
    context: RuntimeContext,
    entity: zcs.EntityID,
    component: zimp.scene.SceneComponent,
) !void {
    const codec = context.registry.get(component.type_id) orelse return error.UnknownComponent;
    try codec.attach(context.world, entity, self.allocator, component.asData());

    for (component.fields) |field| {
        try registerFieldAssetId(context.assets, codec.schema, field.number, field.value);
    }
}

pub fn despawnEntity(self: *SceneRuntimeInstance, context: RuntimeContext, id: zimp.SceneEntityId) !void {
    const entity = try self.resolve(id);
    _ = self.runtime_to_scene.remove(entity);
    _ = self.scene_to_runtime.remove(id);
    context.world.despawn(entity);
}

pub fn removeComponent(
    self: *SceneRuntimeInstance,
    context: RuntimeContext,
    entity: zcs.EntityID,
    component: zimp.ComponentTypeId,
) !void {
    const codec = context.registry.get(component) orelse return error.UnknownComponent;
    try codec.detach(context.world, entity, self.allocator);
}

pub fn setField(
    self: *SceneRuntimeInstance,
    context: RuntimeContext,
    entity: zcs.EntityID,
    component: zimp.ComponentTypeId,
    number: u32,
    value: zimp.scene.Value,
) !void {
    const codec = context.registry.get(component) orelse return error.UnknownComponent;
    try registerFieldAssetId(context.assets, codec.schema, number, value);
    try codec.writeField(context.world, entity, self.allocator, number, value);
}

pub fn addField(
    self: *SceneRuntimeInstance,
    context: RuntimeContext,
    entity: zcs.EntityID,
    component: zimp.ComponentTypeId,
    number: u32,
    value: zimp.scene.Value,
) !void {
    return self.setField(
        context,
        entity,
        component,
        number,
        value,
    );
}

pub fn removeField(
    self: *SceneRuntimeInstance,
    context: RuntimeContext,
    entity: zcs.EntityID,
    component: zimp.ComponentTypeId,
    number: u32,
) !void {
    const codec = context.registry.get(component) orelse return error.UnknownComponent;
    for (codec.schema.fields) |field| {
        if (field.number == number) {
            return codec.writeField(context.world, entity, self.allocator, number, field.default_value);
        }
    }
    return error.UnknownFieldNumber;
}

fn registerAssetId(assets: *AssetManager, kind: zimp.AssetKind, id: zimp.AssetId) !void {
    if (id.isZero()) {
        return error.AssetIdZero;
    }

    const result = switch (kind) {
        .mesh => assets.registerId(Mesh, id),
        .texture => assets.registerId(TextureAsset, id),
        .shader_stage => assets.registerId(zimp.ZShader, id),
        .material => assets.registerId(Material, id),
    };

    _ = result catch |err| {
        log.err("scene references unavailable {s} asset {f}: {s}", .{ @tagName(kind), id, @errorName(err) });
        return err;
    };
}

fn registerFieldAssetId(assets: *AssetManager, schema: zimp.scene.ComponentSchema, number: u32, value: zimp.scene.Value) !void {
    const schema_field = for (schema.fields) |field| {
        if (field.number == number) break field;
    } else return;

    const asset_kind = switch (schema_field.kind) {
        .asset_ref => |kind| kind,
        else => return,
    };
    const asset_id = switch (value) {
        .asset_ref => |id| id,
        else => return,
    };
    try registerAssetId(assets, asset_kind, asset_id);
}

const testing = std.testing;

const ReferenceComponent = struct {
    target: zimp.SceneEntityId = zimp.SceneEntityId.zero,

    pub const schema_meta: zimp.scene.SchemaMeta = .{
        .id = "e7332d7d-e00c-44d4-8f1e-d5b992ab6ee9",
        .name = "RuntimeInstanceReferenceComponent",
        .version = 1,
        .fields = &.{.{ .name = "target", .number = 1 }},
    };
};

const RemainingAssetReferences = struct {
    texture: zimp.AssetId = zimp.AssetId.zero,
    shader: zimp.AssetId = zimp.AssetId.zero,
    material: zimp.AssetId = zimp.AssetId.zero,

    pub const schema_meta: zimp.scene.SchemaMeta = .{
        .id = "8076d802-d3f0-482f-823b-e0b317c9b65f",
        .name = "RuntimeInstanceRemainingAssetReferences",
        .version = 1,
        .fields = &.{
            .{ .name = "texture", .number = 1, .kind_override = .{ .asset_ref = .texture }, .default_override = .{ .asset_ref = zimp.AssetId.zero } },
            .{ .name = "shader", .number = 2, .kind_override = .{ .asset_ref = .shader_stage }, .default_override = .{ .asset_ref = zimp.AssetId.zero } },
            .{ .name = "material", .number = 3, .kind_override = .{ .asset_ref = .material }, .default_override = .{ .asset_ref = zimp.AssetId.zero } },
        },
    };
};

const MeshRenderComponent = @import("../ecs/components.zig").MeshRenderComponent;
const TransformComponent = @import("../ecs/components.zig").TransformComponent;
const CameraComponent = @import("../ecs/components.zig").CameraComponent;
const ActiveCameraComponent = @import("../ecs/components.zig").ActiveCamera;
const ActiveCamera = @import("../ecs/components.zig").ActiveCamera;
const TestInstance = SceneRuntimeInstance;
const test_scene_id = zimp.SceneId.parseComptime("5a1efdc5-7a08-48a0-a59f-f1bbd932a7b7");
const test_project_id = zimp.ProjectId.parseComptime("6f3279dd-695b-4bb1-a32b-ef9ac03b3260");
const test_source_id = zimp.SceneEntityId.parseComptime("a15b53f9-9d76-4b24-9cb6-e53a52fe982c");
const test_target_id = zimp.SceneEntityId.parseComptime("c97b9b6a-2478-414c-806d-b4eb96bef32b");
const reference_component_id = zimp.ComponentTypeId.parseComptime(ReferenceComponent.schema_meta.id);
const unknown_component_id = zimp.ComponentTypeId.parseComptime("d7a5e9f2-3a2d-4e0d-9aea-99657986a84c");
const mesh_component_id = zimp.ComponentTypeId.parseComptime(MeshRenderComponent.schema_meta.id);
const transform_component_id = zimp.ComponentTypeId.parseComptime(TransformComponent.schema_meta.id);
const camera_component_id = zimp.ComponentTypeId.parseComptime(CameraComponent.schema_meta.id);
const active_camera_component_id = zimp.ComponentTypeId.parseComptime(ActiveCameraComponent.schema_meta.id);
const remaining_asset_component_id = zimp.ComponentTypeId.parseComptime(RemainingAssetReferences.schema_meta.id);
const test_mesh_id = zimp.AssetId.parseComptime("8d522c0b-45e6-4e54-8c04-5f1bf913d1be");
const test_material_id = zimp.AssetId.parseComptime("7e6d1a1f-209f-4945-a2f5-283c895803cf");
const test_texture_id = zimp.AssetId.parseComptime("f443d495-a80f-4a1c-ad87-6fe35159d17d");
const test_shader_id = zimp.AssetId.parseComptime("c7daab84-6540-4980-a9a4-ca7fb4dbd64c");
const missing_asset_id = zimp.AssetId.parseComptime("da396a84-d7d9-45f4-8f6a-2b118f88bd46");

fn initTestWorld() !zcs.World {
    var world = zcs.World.init(testing.allocator);
    errdefer world.deinit();
    inline for (.{ ReferenceComponent, RemainingAssetReferences, MeshRenderComponent, TransformComponent, CameraComponent, ActiveCamera }) |Component| {
        _ = try world.registerType(Component, .{ .schema_hash = 0 });
    }
    return world;
}

fn testContext(world: *World, registry: *const Registry, assets: *AssetManager) RuntimeContext {
    return .{
        .world = world,
        .registry = registry,
        .assets = assets,
    };
}

fn testDocument(entities: []zimp.scene.SceneEntity) zimp.scene.SceneDocument {
    return .{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .format = "fusion.scene",
        .version = 1,
        .scene_id = test_scene_id,
        .project_id = test_project_id,
        .name = "runtime-instance-test",
        .entities = entities,
    };
}

fn testProjectWithAssets(tmp: *testing.TmpDir) !Project {
    try tmp.dir.createDirPath(testing.io, ".fusion/cooked");
    var manifest = try zimp.manifest.model.testManifest(testing.allocator, &.{
        .{ .id = "7e6d1a1f-209f-4945-a2f5-283c895803cf", .kind = .material, .source_path = "materials/test.mat", .cooked_path = "test.zamat" },
        .{ .id = "8d522c0b-45e6-4e54-8c04-5f1bf913d1be", .source_path = "meshes/test.glb", .cooked_path = "test.zmesh" },
        .{ .id = "c7daab84-6540-4980-a9a4-ca7fb4dbd64c", .kind = .shader_stage, .source_path = "shaders/test.vert", .cooked_path = "test.zshdr" },
        .{ .id = "f443d495-a80f-4a1c-ad87-6fe35159d17d", .kind = .texture, .source_path = "textures/test.png", .cooked_path = "test.ztex" },
    });
    defer manifest.deinit();
    try zimp.manifest.codec.writeToDir(testing.allocator, testing.io, tmp.dir, ".fusion/assets.zmanifest", &manifest);

    return .{
        .manifest = .{ .project_id = .zero },
        .root_dir = try std.Io.Dir.openDir(tmp.dir, testing.io, ".", .{}),
    };
}

test "SceneRuntimeInstance preserves scene entity references and resolves them through the instance" {
    var fields = [_]zimp.scene.SceneField{.{ .number = 1, .value = .{ .entity_ref = test_target_id } }};
    var components = [_]zimp.scene.SceneComponent{.{ .type_id = reference_component_id, .fields = &fields }};
    var entities = [_]zimp.scene.SceneEntity{
        .{ .id = test_source_id, .name = "source", .components = &components, .prefab = .{} },
        .{ .id = test_target_id, .name = "target", .components = &.{}, .prefab = .{} },
    };
    var scene = testDocument(&entities);
    defer scene.deinit();

    var world = try initTestWorld();
    defer world.deinit();
    var registry = SchemaRegistry.init(testing.allocator);
    defer registry.deinit();
    try registry.register(ReferenceComponent);
    var instance = TestInstance.init(testing.allocator, test_scene_id);
    defer instance.deinit(&world);

    var assets: AssetManager = undefined;
    try instance.spawnEntities(testContext(&world, &registry, &assets), &scene);

    const source = try instance.resolve(test_source_id);
    const target = try instance.resolve(test_target_id);
    try testing.expect(world.isAlive(source));
    try testing.expect(world.isAlive(target));
    try testing.expect(instance.runtime_to_scene.get(source).?.eql(test_source_id));
    try testing.expect(instance.runtime_to_scene.get(target).?.eql(test_target_id));
    try testing.expect((world.getComponent(source, ReferenceComponent).?).target.eql(test_target_id));

    // Covers an entity that was removed before instance teardown; the source
    // remains for deinit to despawn.
    world.despawn(target);
}

test "SceneRuntimeInstance resolves only instantiated scene entities" {
    var world = try initTestWorld();
    defer world.deinit();
    var instance = TestInstance.init(testing.allocator, test_scene_id);
    defer instance.deinit(&world);

    try testing.expectError(error.SceneEntityNotFound, instance.resolve(test_source_id));
}

test "SceneRuntimeInstance adds fields and restores defaults when fields are removed" {
    var components = [_]zimp.scene.SceneComponent{.{ .type_id = reference_component_id, .fields = &.{} }};
    var entities = [_]zimp.scene.SceneEntity{.{ .id = test_source_id, .name = "source", .components = &components, .prefab = .{} }};
    var scene = testDocument(&entities);
    defer scene.deinit();
    var world = try initTestWorld();
    defer world.deinit();
    var registry = SchemaRegistry.init(testing.allocator);
    defer registry.deinit();
    try registry.register(ReferenceComponent);
    var instance = TestInstance.init(testing.allocator, test_scene_id);
    defer instance.deinit(&world);
    var assets: AssetManager = undefined;

    try instance.spawnEntities(testContext(&world, &registry, &assets), &scene);
    const entity = try instance.resolve(test_source_id);

    try instance.addField(testContext(&world, &registry, &assets), entity, reference_component_id, 1, .{ .entity_ref = test_target_id });
    try testing.expect((world.getComponent(entity, ReferenceComponent).?).target.eql(test_target_id));

    try instance.removeField(testContext(&world, &registry, &assets), entity, reference_component_id, 1);
    try testing.expect((world.getComponent(entity, ReferenceComponent).?).target.eql(zimp.SceneEntityId.zero));
    try testing.expectError(error.UnknownFieldNumber, instance.removeField(testContext(&world, &registry, &assets), entity, reference_component_id, 2));
}

test "SceneRuntimeInstance instantiates an empty document" {
    var scene = testDocument(&.{});
    defer scene.deinit();
    var world = try initTestWorld();
    defer world.deinit();
    var registry = SchemaRegistry.init(testing.allocator);
    defer registry.deinit();
    var instance = TestInstance.init(testing.allocator, test_scene_id);
    defer instance.deinit(&world);

    var assets: AssetManager = undefined;
    try instance.spawnEntities(testContext(&world, &registry, &assets), &scene);
    try testing.expectError(error.SceneEntityNotFound, instance.resolve(test_source_id));
}

test "SceneRuntimeInstance reports an unregistered component type" {
    var components = [_]zimp.scene.SceneComponent{.{ .type_id = unknown_component_id, .fields = &.{} }};
    var entities = [_]zimp.scene.SceneEntity{.{ .id = test_source_id, .name = "source", .components = &components, .prefab = .{} }};
    var scene = testDocument(&entities);
    defer scene.deinit();
    var world = try initTestWorld();
    defer world.deinit();
    var registry = SchemaRegistry.init(testing.allocator);
    defer registry.deinit();
    var instance = TestInstance.init(testing.allocator, test_scene_id);
    defer instance.deinit(&world);

    var assets: AssetManager = undefined;
    try testing.expectError(error.UnknownComponent, instance.spawnEntities(testContext(&world, &registry, &assets), &scene));
    const source = try instance.resolve(test_source_id);
    try testing.expect(world.isAlive(source));
}

test "SceneRuntimeInstance applies the document active camera" {
    var components = [_]zimp.scene.SceneComponent{
        .{ .type_id = transform_component_id, .fields = &.{} },
        .{ .type_id = camera_component_id, .fields = &.{} },
        .{ .type_id = active_camera_component_id, .fields = &.{} },
    };
    var entities = [_]zimp.scene.SceneEntity{.{ .id = test_source_id, .name = "camera", .components = &components, .prefab = .{} }};
    var scene = testDocument(&entities);
    defer scene.deinit();
    var world = try initTestWorld();
    defer world.deinit();
    var registry = SchemaRegistry.init(testing.allocator);
    defer registry.deinit();
    try registry.register(TransformComponent);
    try registry.register(CameraComponent);
    try registry.register(ActiveCameraComponent);
    var instance = TestInstance.init(testing.allocator, test_scene_id);
    defer instance.deinit(&world);
    var assets: AssetManager = undefined;

    try instance.spawnEntities(testContext(&world, &registry, &assets), &scene);
    try testing.expectEqual(try instance.resolve(test_source_id), activeCamera(&world).?);
}

test "SceneRuntimeInstance registers asset references without loading them" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var project = try testProjectWithAssets(&tmp);
    defer project.root_dir.close(testing.io);
    var device = try device_factory.init(testing.allocator, .opengl);
    defer device.deinit();
    var assets = try AssetManager.init(testing.allocator, testing.io, &project, &device);
    defer assets.deinit();

    var fields = [_]zimp.scene.SceneField{
        .{ .number = 1, .value = .{ .asset_ref = test_mesh_id } },
    };
    var remaining_fields = [_]zimp.scene.SceneField{
        .{ .number = 1, .value = .{ .asset_ref = test_texture_id } },
        .{ .number = 2, .value = .{ .asset_ref = test_shader_id } },
        .{ .number = 3, .value = .{ .asset_ref = test_material_id } },
    };
    var components = [_]zimp.scene.SceneComponent{
        .{ .type_id = mesh_component_id, .fields = &fields },
        .{ .type_id = remaining_asset_component_id, .fields = &remaining_fields },
    };
    var entities = [_]zimp.scene.SceneEntity{.{ .id = test_source_id, .name = "renderable", .components = &components, .prefab = .{} }};
    var scene = testDocument(&entities);
    defer scene.deinit();
    var world = try initTestWorld();
    defer world.deinit();
    var registry = SchemaRegistry.init(testing.allocator);
    defer registry.deinit();
    try registry.register(MeshRenderComponent);
    try registry.register(RemainingAssetReferences);
    var instance = TestInstance.init(testing.allocator, test_scene_id);
    defer instance.deinit(&world);

    try instance.spawnEntities(testContext(&world, &registry, &assets), &scene);

    try testing.expect(assets.assets.contains(test_mesh_id));
    try testing.expect(assets.assets.contains(test_material_id));
    try testing.expect(assets.assets.contains(test_texture_id));
    try testing.expect(assets.assets.contains(test_shader_id));
    const entity = try instance.resolve(test_source_id);
    const component = world.getComponent(entity, MeshRenderComponent).?;
    try testing.expect(component.mesh.eql(test_mesh_id));
    const remaining = world.getComponent(entity, RemainingAssetReferences).?;
    try testing.expect(remaining.texture.eql(test_texture_id));
    try testing.expect(remaining.shader.eql(test_shader_id));
    try testing.expect(remaining.material.eql(test_material_id));
}

test "SceneRuntimeInstance registers asset references written through setField and addField" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var project = try testProjectWithAssets(&tmp);
    defer project.root_dir.close(testing.io);
    var device = try device_factory.init(testing.allocator, .opengl);
    defer device.deinit();
    var assets = try AssetManager.init(testing.allocator, testing.io, &project, &device);
    defer assets.deinit();

    var components = [_]zimp.scene.SceneComponent{
        .{ .type_id = mesh_component_id, .fields = &.{} },
        .{ .type_id = remaining_asset_component_id, .fields = &.{} },
    };
    var entities = [_]zimp.scene.SceneEntity{.{ .id = test_source_id, .name = "renderable", .components = &components, .prefab = .{} }};
    var scene = testDocument(&entities);
    defer scene.deinit();
    var world = try initTestWorld();
    defer world.deinit();
    var registry = SchemaRegistry.init(testing.allocator);
    defer registry.deinit();
    try registry.register(MeshRenderComponent);
    try registry.register(RemainingAssetReferences);
    var instance = TestInstance.init(testing.allocator, test_scene_id);
    defer instance.deinit(&world);

    try instance.spawnEntities(testContext(&world, &registry, &assets), &scene);
    const entity = try instance.resolve(test_source_id);
    try instance.setField(testContext(&world, &registry, &assets), entity, mesh_component_id, 1, .{ .asset_ref = test_mesh_id });
    try instance.addField(testContext(&world, &registry, &assets), entity, remaining_asset_component_id, 1, .{ .asset_ref = test_texture_id });

    try testing.expect(assets.assets.contains(test_mesh_id));
    try testing.expect(assets.assets.contains(test_texture_id));
    try testing.expect((world.getComponent(entity, MeshRenderComponent).?).mesh.eql(test_mesh_id));
    try testing.expect((world.getComponent(entity, RemainingAssetReferences).?).texture.eql(test_texture_id));
}

test "SceneRuntimeInstance fails when an asset reference is absent from the manifest" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var project = try testProjectWithAssets(&tmp);
    defer project.root_dir.close(testing.io);
    var device = try device_factory.init(testing.allocator, .opengl);
    defer device.deinit();
    var assets = try AssetManager.init(testing.allocator, testing.io, &project, &device);
    defer assets.deinit();

    var fields = [_]zimp.scene.SceneField{.{ .number = 1, .value = .{ .asset_ref = missing_asset_id } }};
    var components = [_]zimp.scene.SceneComponent{.{ .type_id = mesh_component_id, .fields = &fields }};
    var entities = [_]zimp.scene.SceneEntity{.{ .id = test_source_id, .name = "missing-asset", .components = &components, .prefab = .{} }};
    var scene = testDocument(&entities);
    defer scene.deinit();
    var world = try initTestWorld();
    defer world.deinit();
    var registry = SchemaRegistry.init(testing.allocator);
    defer registry.deinit();
    try registry.register(MeshRenderComponent);
    var instance = TestInstance.init(testing.allocator, test_scene_id);
    defer instance.deinit(&world);

    try testing.expectError(error.AssetNotFound, instance.spawnEntities(testContext(&world, &registry, &assets), &scene));
}
