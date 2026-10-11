const std = @import("std");
const zimp = @import("zimp");
const codec_mod = @import("component_codec.zig");

const ComponentTypeId = zimp.id.types.ComponentTypeId;
const deriveCodec = @import("derive_schema.zig").deriveCodec;

const SchemaRegistry = @This();
const DynamicComponent = @import("dynamic_component.zig");
const Codec = codec_mod.ComponentCodec;

allocator: std.mem.Allocator,
codecs: std.AutoHashMap(ComponentTypeId, Codec),
names: std.StringHashMap(ComponentTypeId),
dynamic: std.ArrayList(*DynamicComponent) = .empty,

pub fn init(allocator: std.mem.Allocator) SchemaRegistry {
    return .{
        .allocator = allocator,
        .codecs = std.AutoHashMap(ComponentTypeId, Codec).init(allocator),
        .names = std.StringHashMap(ComponentTypeId).init(allocator),
    };
}

pub fn deinit(self: *SchemaRegistry) void {
    self.codecs.deinit();
    self.names.deinit();
    for (self.dynamic.items) |d| {
        d.deinit(self.allocator);
    }
    self.dynamic.deinit(self.allocator);
}

pub fn registerComponents(self: *SchemaRegistry, comptime components: []const type) !void {
    inline for (components) |Component| {
        if (@hasDecl(Component, "schema_meta")) {
            try self.register(Component);
        }
    }
}

pub fn register(self: *SchemaRegistry, comptime Component: type) !void {
    const codec = comptime deriveCodec(Component);
    try zimp.scene.validateSchema(codec.schema);
    try self.ensureUnique(codec.schema);

    try self.codecs.put(codec.schema.id, codec);
    try self.names.put(codec.schema.name, codec.schema.id);
}

pub fn registerDynamic(self: *SchemaRegistry, world: *@import("zcs").World, json: []const u8) !void {
    const d = try DynamicComponent.init(self.allocator, json);
    errdefer d.deinit(self.allocator);

    const schema = d.parsed.value.schema;
    try self.ensureUnique(schema);
    try self.dynamic.ensureUnusedCapacity(self.allocator, 1);
    try self.codecs.ensureUnusedCapacity(1);
    try self.names.ensureUnusedCapacity(1);

    d.id = try world.register(.{
        .name = schema.name,
        .size = d.parsed.value.defaults.len,
        .alignment = 1,
        .schema_hash = zimp.scene.descriptor.schemaHash(&.{schema}),
    });
    self.codecs.putAssumeCapacity(schema.id, .{ .schema = schema, .impl = .{ .dynamic = d } });
    self.names.putAssumeCapacity(schema.name, schema.id);
    self.dynamic.appendAssumeCapacity(d);
}

fn ensureUnique(self: *const SchemaRegistry, schema: zimp.scene.ComponentSchema) !void {
    if (self.codecs.contains(schema.id)) {
        return error.DuplicateComponentId;
    }

    if (self.names.contains(schema.name)) {
        return error.DuplicateComponentName;
    }
}

pub fn get(self: *const SchemaRegistry, id: ComponentTypeId) ?*const Codec {
    return self.codecs.getPtr(id);
}

pub fn getByName(self: *const SchemaRegistry, name: []const u8) ?*const Codec {
    const id = self.names.get(name) orelse return null;
    return self.get(id);
}

pub fn sortedSchemas(self: *const SchemaRegistry, allocator: std.mem.Allocator) ![]zimp.scene.ComponentSchema {
    var out = try allocator.alloc(zimp.scene.ComponentSchema, self.codecs.count());
    var it = self.codecs.valueIterator();
    var i: usize = 0;
    while (it.next()) |codec| : (i += 1) out[i] = codec.schema;
    std.mem.sort(zimp.scene.ComponentSchema, out, {}, struct {
        fn lessThan(_: void, a: zimp.scene.ComponentSchema, b: zimp.scene.ComponentSchema) bool {
            return std.mem.order(u8, &a.id.uuid.bytes, &b.id.uuid.bytes) == .lt;
        }
    }.lessThan);
    return out;
}

pub fn schemaHash(self: *const SchemaRegistry, allocator: std.mem.Allocator) !u64 {
    const schemas = try self.sortedSchemas(allocator);
    defer allocator.free(schemas);
    return zimp.scene.descriptor.schemaHash(schemas);
}

pub fn descriptor(self: *const SchemaRegistry, allocator: std.mem.Allocator) !zimp.scene.descriptor.SchemaDescriptor {
    const schemas = try self.sortedSchemas(allocator);
    return .{
        .schema_hash = zimp.scene.descriptor.schemaHash(schemas),
        .components = schemas,
    };
}

const testing = std.testing;

const RegistryComponentA = struct {
    enabled: bool = true,

    pub const schema_meta: zimp.scene.SchemaMeta = .{
        .id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        .name = "RegistryComponentA",
        .display_name = "Registry Component A",
        .version = 1,
        .fields = &.{.{
            .name = "enabled",
            .number = 1,
        }},
    };
};

const RegistryComponentB = struct {
    count: i32 = -2,

    pub const schema_meta: zimp.scene.SchemaMeta = .{
        .id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        .name = "RegistryComponentB",
        .version = 3,
        .fields = &.{.{
            .name = "count",
            .number = 1,
        }},
    };
};

const DuplicateIdComponent = struct {
    visible: bool = false,

    pub const schema_meta: zimp.scene.SchemaMeta = .{
        .id = RegistryComponentA.schema_meta.id,
        .name = "DuplicateIdComponent",
        .version = 1,
        .fields = &.{.{
            .name = "visible",
            .number = 1,
        }},
    };
};

const DuplicateNameComponent = struct {
    active: bool = false,

    pub const schema_meta: zimp.scene.SchemaMeta = .{
        .id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
        .name = RegistryComponentA.schema_meta.name,
        .version = 1,
        .fields = &.{.{
            .name = "active",
            .number = 1,
        }},
    };
};

const InvalidSchemaComponent = struct {
    bad: bool = false,

    pub const schema_meta: zimp.scene.SchemaMeta = .{
        .id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
        .name = "",
        .version = 1,
        .fields = &.{.{
            .name = "bad",
            .number = 1,
        }},
    };
};

test "SchemaRegistry registers derived codecs and looks them up by id and name" {
    var registry = SchemaRegistry.init(testing.allocator);
    defer registry.deinit();

    try registry.register(RegistryComponentA);

    const expected_id = ComponentTypeId.parseComptime(RegistryComponentA.schema_meta.id);
    const by_id = registry.get(expected_id).?;
    try testing.expect(by_id.schema.id.eql(expected_id));
    try testing.expectEqualStrings("RegistryComponentA", by_id.schema.name);
    try testing.expectEqualStrings("Registry Component A", by_id.schema.display_name);

    const by_name = registry.getByName("RegistryComponentA").?;
    try testing.expect(by_name.schema.id.eql(expected_id));
    try testing.expect(registry.get(ComponentTypeId.zero) == null);
    try testing.expect(registry.getByName("MissingComponent") == null);
}

test "SchemaRegistry rejects duplicate component ids and names" {
    var registry = SchemaRegistry.init(testing.allocator);
    defer registry.deinit();

    try registry.register(RegistryComponentA);
    try testing.expectError(error.DuplicateComponentId, registry.register(DuplicateIdComponent));
    try testing.expectError(error.DuplicateComponentName, registry.register(DuplicateNameComponent));
}

test "SchemaRegistry returns schemas sorted by component id" {
    var registry = SchemaRegistry.init(testing.allocator);
    defer registry.deinit();

    try registry.register(RegistryComponentA);
    try registry.register(RegistryComponentB);

    const schemas = try registry.sortedSchemas(testing.allocator);
    defer testing.allocator.free(schemas);

    try testing.expectEqual(@as(usize, 2), schemas.len);
    try testing.expect(schemas[0].id.eql(ComponentTypeId.parseComptime(RegistryComponentB.schema_meta.id)));
    try testing.expect(schemas[1].id.eql(ComponentTypeId.parseComptime(RegistryComponentA.schema_meta.id)));
}

test "SchemaRegistry computes descriptor and schema hash from sorted schemas" {
    var registry = SchemaRegistry.init(testing.allocator);
    defer registry.deinit();

    try registry.register(RegistryComponentA);
    try registry.register(RegistryComponentB);

    const hash = try registry.schemaHash(testing.allocator);
    var desc = try registry.descriptor(testing.allocator);
    defer testing.allocator.free(desc.components);

    try testing.expectEqual(hash, desc.schema_hash);
    try testing.expectEqual(@as(usize, 2), desc.components.len);
    try testing.expect(desc.components[0].id.eql(ComponentTypeId.parseComptime(RegistryComponentB.schema_meta.id)));
    try testing.expect(desc.components[1].id.eql(ComponentTypeId.parseComptime(RegistryComponentA.schema_meta.id)));
}

const RuntimeOnlyComponent = struct {
    ticks: u32 = 0,
};

test "registerComponents registers annotated components and skips runtime-only ones" {
    var registry = SchemaRegistry.init(testing.allocator);
    defer registry.deinit();

    try registry.registerComponents(&.{ RegistryComponentA, RuntimeOnlyComponent });

    try testing.expectEqual(@as(usize, 1), registry.codecs.count());
    try testing.expect(registry.getByName("RegistryComponentA") != null);
}

test "SchemaRegistry validates derived schemas before insertion" {
    var registry = SchemaRegistry.init(testing.allocator);
    defer registry.deinit();

    try testing.expectError(error.InvalidComponentName, registry.register(InvalidSchemaComponent));
    try testing.expectEqual(@as(usize, 0), registry.codecs.count());
    try testing.expectEqual(@as(usize, 0), registry.names.count());
}
