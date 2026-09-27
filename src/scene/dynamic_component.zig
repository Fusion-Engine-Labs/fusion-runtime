const sdk = @import("fusion_sdk");
const std = @import("std");
const zimp = @import("zimp");
const zcs = @import("zcs");

const wire = sdk.wire;
const max_fields = 64;

const Self = @This();

parsed: std.json.Parsed(sdk.descriptor.Descriptor),
id: zcs.ComponentId = .invalid,
/// Where each schema field starts in the packed value; the last entry is the total size.
offsets: [max_fields + 1]u16,

pub fn init(allocator: std.mem.Allocator, json: []const u8) !*Self {
    if (json.len > sdk.abi.max_descriptor_size) {
        return error.DescriptorTooLarge;
    }

    var parsed = try std.json.parseFromSlice(sdk.descriptor.Descriptor, allocator, json, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();

    const d = parsed.value;
    try zimp.scene.validateSchema(d.schema);
    if (d.defaults.len > sdk.abi.max_component_size or d.schema.fields.len > max_fields) {
        return error.InvalidDescriptor;
    }

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{ .parsed = parsed, .offsets = undefined };
    self.offsets[0] = 0;
    for (d.schema.fields, 0..) |field, i| {
        self.offsets[i + 1] = self.offsets[i] + @as(u16, @intCast(try valueSize(field.kind)));
    }
    try self.validateBytes(d.defaults);
    return self;
}

fn fieldBytes(self: *const Self, bytes: anytype, index: usize) @TypeOf(bytes) {
    return bytes[self.offsets[index]..self.offsets[index + 1]];
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.parsed.deinit();
    allocator.destroy(self);
}

pub fn attachDefault(self: *const Self, world: *zcs.World, entity: zcs.EntityID) !void {
    try world.add(entity, self.id, self.parsed.value.defaults);
}

pub fn attach(self: *const Self, world: *zcs.World, entity: zcs.EntityID, data: zimp.scene.SceneComponentData) !void {
    const d = self.parsed.value;
    if (!data.component.eql(d.schema.id)) {
        return error.InvalidComponent;
    }
    try self.commit(world, entity, d.defaults, data.fields);
}

pub fn detach(self: *const Self, world: *zcs.World, entity: zcs.EntityID) !void {
    try world.remove(entity, self.id);
}

pub fn readDocument(self: *const Self, world: *zcs.World, entity: zcs.EntityID, allocator: std.mem.Allocator) !zimp.scene.SceneComponentData {
    const bytes = world.get(entity, self.id) orelse return error.ComponentMissing;
    const d = self.parsed.value;
    const fields = try allocator.alloc(zimp.scene.SceneField, d.schema.fields.len);
    errdefer allocator.free(fields);

    for (d.schema.fields, fields, 0..) |schema, *out, i| {
        out.* = .{ .number = schema.number, .value = try readValue(schema.kind, self.fieldBytes(bytes, i)) };
    }
    return .{ .component = d.schema.id, .fields = fields };
}

pub fn writeField(self: *const Self, world: *zcs.World, entity: zcs.EntityID, number: u32, value: zimp.scene.Value) !void {
    const old = world.get(entity, self.id) orelse return error.ComponentMissing;
    try self.commit(world, entity, old, &.{.{ .number = number, .value = value }});
}

/// Copies `base`, applies `fields` over it, and stores the result on `entity`.
fn commit(self: *const Self, world: *zcs.World, entity: zcs.EntityID, base: []const u8, fields: []const zimp.scene.SceneField) !void {
    var storage: [sdk.abi.max_component_size]u8 = undefined;
    const bytes = storage[0..base.len];
    @memcpy(bytes, base);
    for (fields) |f| {
        try self.setField(bytes, f.number, f.value);
    }
    try world.add(entity, self.id, bytes);
}

fn setField(self: *const Self, bytes: []u8, number: u32, value: zimp.scene.Value) !void {
    const d = self.parsed.value;
    for (d.schema.fields, 0..) |schema, i| {
        if (schema.number != number) {
            continue;
        }

        if (!value.kindMatches(schema.kind)) {
            return error.ValueKindMismatch;
        }

        const out = self.fieldBytes(bytes, i);
        switch (try gameKind(schema.kind)) {
            inline else => |k| wire.encode(WireType(k), @field(value, @tagName(k)), out),
        }
        return;
    }
    return error.UnknownFieldNumber;
}

pub fn validateBytes(self: *const Self, bytes: []const u8) !void {
    const fields = self.parsed.value.schema.fields;
    if (bytes.len != self.offsets[fields.len]) {
        return error.InvalidWireSize;
    }

    for (fields, 0..) |schema, i| {
        _ = try readValue(schema.kind, self.fieldBytes(bytes, i));
    }
}

/// Field kinds a game component may declare; each is stored as its `Value` payload in wire format.
const GameKind = enum { bool, i32, u32, f32, vec2, vec3, quat, asset_ref, entity_ref };

fn gameKind(kind: zimp.scene.FieldKind) !GameKind {
    return switch (kind) {
        inline else => |_, k| if (@hasField(GameKind, @tagName(k))) @field(GameKind, @tagName(k)) else error.UnsupportedGameField,
    };
}

fn WireType(comptime kind: GameKind) type {
    return @FieldType(zimp.scene.Value, @tagName(kind));
}

fn valueSize(kind: zimp.scene.FieldKind) !usize {
    return switch (try gameKind(kind)) {
        inline else => |k| wire.size(WireType(k)),
    };
}

fn readValue(kind: zimp.scene.FieldKind, bytes: []const u8) !zimp.scene.Value {
    return switch (try gameKind(kind)) {
        inline else => |k| @unionInit(zimp.scene.Value, @tagName(k), try wire.decode(WireType(k), bytes)),
    };
}

const Fixture = struct {
    enabled: bool = true,
    speed: f32 = 2,
    direction: sdk.Vec3 = sdk.Vec3.new(1, 2, 3),
    pub const schema_meta = zimp.scene.SchemaMeta{
        .id = "214513f1-c12d-476a-a4a3-a598f06a39ed",
        .name = "test.sdk.component",
        .version = 1,
        .fields = &.{ .{ .name = "enabled", .number = 1 }, .{ .name = "speed", .number = 2 }, .{ .name = "direction", .number = 3 } },
    };
};

test "dynamic descriptors reject mismatched layouts and invalid wire values" {
    const allocator = std.testing.allocator;
    var desc = sdk.descriptor.describe(Fixture);
    desc.defaults = desc.defaults[0 .. desc.defaults.len - 1];
    const invalid = try std.json.Stringify.valueAlloc(allocator, desc, .{});
    defer allocator.free(invalid);
    try std.testing.expectError(error.InvalidWireSize, Self.init(allocator, invalid));
    const valid = try std.json.Stringify.valueAlloc(allocator, sdk.descriptor.describe(Fixture), .{});
    defer allocator.free(valid);
    const component = try Self.init(allocator, valid);
    defer component.deinit(allocator);
    var bytes: [sdk.wire.size(Fixture)]u8 = undefined;
    sdk.wire.encode(Fixture, .{}, &bytes);
    bytes[0] = 2;
    try std.testing.expectError(error.InvalidWireValue, component.validateBytes(&bytes));
}

test "host-owned dynamic codecs preserve bool scalar and vector fields" {
    const allocator = std.testing.allocator;
    const json = try std.json.Stringify.valueAlloc(allocator, sdk.descriptor.describe(Fixture), .{});
    defer allocator.free(json);
    const component = try Self.init(allocator, json);
    defer component.deinit(allocator);
    var world = zcs.World.init(allocator);
    defer world.deinit();
    component.id = try world.register(.{ .name = "test.sdk.component", .size = sdk.wire.size(Fixture), .alignment = 1, .schema_hash = 1 });
    const entity = try world.spawn();
    try component.attachDefault(&world, entity);
    try component.writeField(&world, entity, 1, .{ .bool = false });
    try component.writeField(&world, entity, 2, .{ .f32 = 4 });
    try component.writeField(&world, entity, 3, .{ .vec3 = .{ 7, 8, 9 } });
    const decoded = try sdk.wire.decode(Fixture, world.get(entity, component.id).?);
    try std.testing.expect(!decoded.enabled);
    try std.testing.expectEqual(@as(f32, 4), decoded.speed);
    try std.testing.expectEqual(@as(f32, 8), decoded.direction.y);
    var document = try component.readDocument(&world, entity, allocator);
    defer document.deinit(allocator);
    try component.detach(&world, entity);
    try component.attach(&world, entity, document);
    try std.testing.expectEqualDeep(decoded, try sdk.wire.decode(Fixture, world.get(entity, component.id).?));
}
