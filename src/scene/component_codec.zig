const std = @import("std");

const zimp = @import("zimp");
const zcs = @import("zcs");

const SceneComponentData = zimp.scene.SceneComponentData;
const ComponentSchema = zimp.scene.ComponentSchema;
const Value = zimp.scene.Value;

pub const CodecError = error{
    ComponentMissing,
    UnknownFieldNumber,
    ValueKindMismatch,
};

pub const ComponentCodec = struct {
    schema: ComponentSchema,
    impl: union(enum) {
        static: VTable,
        dynamic: *const @import("dynamic_component.zig"),
    },

    pub const VTable = struct {
        attachDefault: *const fn (*zcs.World, zcs.EntityID, std.mem.Allocator) anyerror!void,
        attach: *const fn (*zcs.World, zcs.EntityID, std.mem.Allocator, SceneComponentData) anyerror!void,
        detach: *const fn (*zcs.World, zcs.EntityID, std.mem.Allocator) anyerror!void,

        readDocument: *const fn (*zcs.World, zcs.EntityID, std.mem.Allocator) anyerror!SceneComponentData,
        writeField: *const fn (*zcs.World, zcs.EntityID, std.mem.Allocator, u32, Value) anyerror!void,
    };

    pub fn attachDefault(self: ComponentCodec, world: *zcs.World, entity: zcs.EntityID, allocator: std.mem.Allocator) !void {
        return switch (self.impl) {
            .static => |v| v.attachDefault(world, entity, allocator),
            .dynamic => |d| d.attachDefault(world, entity),
        };
    }
    pub fn attach(self: ComponentCodec, world: *zcs.World, entity: zcs.EntityID, allocator: std.mem.Allocator, data: SceneComponentData) !void {
        return switch (self.impl) {
            .static => |v| v.attach(world, entity, allocator, data),
            .dynamic => |d| d.attach(world, entity, data),
        };
    }
    pub fn detach(self: ComponentCodec, world: *zcs.World, entity: zcs.EntityID, allocator: std.mem.Allocator) !void {
        return switch (self.impl) {
            .static => |v| v.detach(world, entity, allocator),
            .dynamic => |d| d.detach(world, entity),
        };
    }
    pub fn readDocument(self: ComponentCodec, world: *zcs.World, entity: zcs.EntityID, allocator: std.mem.Allocator) !SceneComponentData {
        return switch (self.impl) {
            .static => |v| v.readDocument(world, entity, allocator),
            .dynamic => |d| d.readDocument(world, entity, allocator),
        };
    }
    pub fn writeField(self: ComponentCodec, world: *zcs.World, entity: zcs.EntityID, allocator: std.mem.Allocator, number: u32, value: Value) !void {
        return switch (self.impl) {
            .static => |v| v.writeField(world, entity, allocator, number, value),
            .dynamic => |d| d.writeField(world, entity, number, value),
        };
    }
};

const testing = std.testing;

const TestState = struct {
    attached_defaults: u32 = 0,
    attached: u32 = 0,
    detached: u32 = 0,
    read_documents: u32 = 0,
    written_fields: u32 = 0,
    last_entity: zcs.EntityID = zcs.EntityID.nil,
    last_component: zimp.id.types.ComponentTypeId = zimp.id.types.ComponentTypeId.zero,
    last_value: Value = .{ .none = {} },
};

const test_component_id = zimp.id.types.ComponentTypeId.parseComptime("12345678-9abc-4def-8012-3456789abcde");

fn testSchema() ComponentSchema {
    return .{
        .id = test_component_id,
        .name = "TestComponent",
        .display_name = "Test Component",
        .version = 1,
        .fields = &.{.{
            .number = 1,
            .name = "enabled",
            .display_name = "Enabled",
            .kind = .bool,
            .default_value = .{ .bool = false },
            .editor = .{},
        }},
    };
}

fn attachDefault(world: *zcs.World, entity: zcs.EntityID, _: std.mem.Allocator) !void {
    const state = world.getResource(TestState);
    state.attached_defaults += 1;
    state.last_entity = entity;
}

fn attach(world: *zcs.World, entity: zcs.EntityID, _: std.mem.Allocator, data: SceneComponentData) !void {
    const state = world.getResource(TestState);
    state.attached += 1;
    state.last_entity = entity;
    state.last_component = data.component;
}

fn detach(world: *zcs.World, entity: zcs.EntityID, _: std.mem.Allocator) !void {
    const state = world.getResource(TestState);
    state.detached += 1;
    state.last_entity = entity;
}

fn readDocument(world: *zcs.World, entity: zcs.EntityID, allocator: std.mem.Allocator) !SceneComponentData {
    const state = world.getResource(TestState);
    state.read_documents += 1;
    state.last_entity = entity;

    const fields = try allocator.alloc(zimp.scene.value.SceneField, 1);
    fields[0] = .{ .number = 1, .value = .{ .bool = true } };
    return .{
        .component = test_component_id,
        .fields = fields,
    };
}

fn writeField(world: *zcs.World, entity: zcs.EntityID, _: std.mem.Allocator, _: u32, value: Value) !void {
    const state = world.getResource(TestState);
    state.written_fields += 1;
    state.last_entity = entity;
    state.last_value = value;
}

test "ComponentCodec stores schema and dispatches callbacks" {
    const codec = ComponentCodec{
        .schema = testSchema(),
        .impl = .{ .static = .{
            .attachDefault = attachDefault,
            .attach = attach,
            .detach = detach,
            .readDocument = readDocument,
            .writeField = writeField,
        } },
    };

    try testing.expect(codec.schema.id.eql(test_component_id));
    try testing.expectEqualStrings("TestComponent", codec.schema.name);
    try testing.expectEqual(@as(usize, 1), codec.schema.fields.len);

    var world = zcs.World.init(testing.allocator);
    defer world.deinit();
    try world.setResource(TestState, .{});
    const state = world.getResource(TestState);
    const entity: zcs.EntityID = .{ .index = 7, .generation = 2 };
    try codec.attachDefault(&world, entity, testing.allocator);
    try testing.expectEqual(@as(u32, 1), state.attached_defaults);
    try testing.expect(state.last_entity.eql(entity));

    const data = SceneComponentData{
        .component = test_component_id,
        .fields = &.{},
    };
    try codec.attach(&world, entity, testing.allocator, data);
    try testing.expectEqual(@as(u32, 1), state.attached);
    try testing.expect(state.last_component.eql(test_component_id));

    try codec.writeField(&world, entity, testing.allocator, 1, .{ .i32 = -4 });
    try testing.expectEqual(@as(u32, 1), state.written_fields);
    try testing.expectEqual(Value{ .i32 = -4 }, state.last_value);

    var read = try codec.readDocument(&world, entity, testing.allocator);
    defer read.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), state.read_documents);
    try testing.expect(read.component.eql(test_component_id));
    try testing.expectEqual(@as(usize, 1), read.fields.len);
    try testing.expectEqual(Value{ .bool = true }, read.fields[0].value);

    try codec.detach(&world, entity, testing.allocator);
    try testing.expectEqual(@as(u32, 1), state.detached);
    try testing.expect(state.last_entity.eql(entity));
}
