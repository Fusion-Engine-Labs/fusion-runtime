const std = @import("std");
const zcs = @import("zcs");
const sdk = @import("fusion_sdk");
const abi = sdk.abi;

const DynamicComponent = @import("../scene/dynamic_component.zig");
const ComponentTypeId = @import("zimp").id.types.ComponentTypeId;
const SchemaRegistry = @import("../scene/schema_registry.zig");

const Self = @This();

const builtin_types = sdk.components.builtin_types;
world: *zcs.World,
schemas: *SchemaRegistry,
registering: bool = false,
builtin_ids: [builtin_types.len]u32,

pub fn init(world: *zcs.World, schemas: *SchemaRegistry, registering: bool) Self {
    var self: Self = .{ .world = world, .schemas = schemas, .registering = registering, .builtin_ids = undefined };
    inline for (builtin_types, &self.builtin_ids) |T, *out| {
        out.* = if (world.componentId(T)) |native| @intFromEnum(native) else 0;
    }
    return self;
}

pub fn api(self: *Self) abi.Host {
    return .{
        .context = self,
        .register_component = register,
        .resolve = resolve,
        .next = next,
        .read = read,
        .write = write,
    };
}

fn from(ctx: *anyopaque) *Self {
    return @ptrCast(@alignCast(ctx));
}

fn register(ctx: *anyopaque, json: abi.Bytes) callconv(.c) abi.Status {
    const self = from(ctx);
    if (!self.registering) {
        return .invalid_argument;
    }

    self.schemas.registerDynamic(self.world, json.slice()) catch |err| {
        std.debug.print("game component registration: {s}\n", .{@errorName(err)});
        return .failed;
    };
    return .ok;
}
fn resolve(ctx: *anyopaque, uuid: *const [16]u8, layout: u64, size: u32) callconv(.c) u32 {
    const self = from(ctx);
    const codec = self.schemas.get(ComponentTypeId.fromBytes(uuid.*)) orelse return 0;
    switch (codec.impl) {
        .dynamic => |d| {
            if (layout != d.parsed.value.layout or size != d.parsed.value.defaults.len) {
                return 0;
            }
            return @intFromEnum(d.id);
        },
        .static => inline for (builtin_types, self.builtin_ids) |T, native| {
            if (codec.schema.id.eql(comptime sdk.schema.deriveSchema(T).id)) {
                if (layout != sdk.wire.layout(T) or size != sdk.wire.size(T)) {
                    return 0;
                }
                return native;
            }
        },
    }
    return 0;
}

fn validId(self: *Self, id: u32) bool {
    return id > 0 and id <= self.world.registry.count();
}

fn findDynamic(self: *Self, id: u32) ?*DynamicComponent {
    for (self.schemas.dynamic.items) |d| {
        if (id == @intFromEnum(d.id)) return d;
    }
    return null;
}

/// Marks a term that is a tag: it lives in the archetype mask but has no data column.
const no_column = std.math.maxInt(u32);
fn next(ctx: *anyopaque, cursor: *abi.Cursor, entity: *u64) callconv(.c) abi.Status {
    const self = from(ctx);
    if (self.registering or cursor.count == 0 or cursor.count > abi.max_query_terms) return .invalid_argument;
    const ids = cursor.ids[0..cursor.count];
    while (cursor.archetype < self.world.archetypes.items.len) : ({
        cursor.archetype += 1;
        cursor.chunk = 0;
        cursor.row = 0;
    }) {
        const arch = self.world.archetypes.items[cursor.archetype];
        if (cursor.chunk == 0 and cursor.row == 0) {
            for (ids) |id| {
                if (!self.validId(id)) {
                    return .invalid_argument;
                }
            }

            const matches = for (ids) |id| {
                if (!arch.has(@enumFromInt(id))) {
                    break false;
                }
            } else true;

            if (!matches) {
                continue;
            }

            for (ids, cursor.columns[0..ids.len], cursor.ticks[0..ids.len]) |id, *column, *tick| {
                column.* = no_column;
                for (arch.columns.items, 0..) |c, i| {
                    if (c.id == @as(zcs.ComponentId, @enumFromInt(id))) {
                        column.* = @intCast(i);
                    }
                }
                tick.* = @intCast(arch.tickIndex(@enumFromInt(id)).?);
            }
        }
        while (cursor.chunk < arch.chunks.items.len) : ({
            cursor.chunk += 1;
            cursor.row = 0;
        }) {
            const entities = zcs.Archetype.entityColumn(arch.chunks.items[cursor.chunk]);
            if (cursor.row < entities.len) {
                entity.* = entities[cursor.row].toRaw();
                cursor.row += 1;
                return .ok;
            }
        }
    }
    return .not_found;
}
const Cell = struct { id: u32, bytes: []u8, arch: *zcs.Archetype, chunk: u32, tick: usize };
fn current(self: *Self, cursor: *const abi.Cursor, term: u32) ?Cell {
    if (self.registering or cursor.count > abi.max_query_terms or term >= cursor.count or cursor.row == 0) {
        return null;
    }

    if (cursor.archetype >= self.world.archetypes.items.len) {
        return null;
    }

    const arch = self.world.archetypes.items[cursor.archetype];
    if (cursor.chunk >= arch.chunks.items.len) {
        return null;
    }

    const chunk = arch.chunks.items[cursor.chunk];
    const row = cursor.row - 1;
    if (row >= chunk.count) return null;
    // The cursor is game-owned, so check its cached slots still name this term.
    const id = cursor.ids[term];
    const tick = cursor.ticks[term];
    if (tick >= arch.change_ids.items.len or @intFromEnum(arch.change_ids.items[tick]) != id) return null;
    const column = cursor.columns[term];
    const bytes: []u8 = if (column == no_column) &.{} else blk: {
        if (column >= arch.columns.items.len or @intFromEnum(arch.columns.items[column].id) != id) return null;
        break :blk zcs.Archetype.cell(chunk, @intCast(row), arch.columns.items[column]);
    };
    return .{ .id = id, .bytes = bytes, .arch = arch, .chunk = cursor.chunk, .tick = tick };
}
fn read(ctx: *anyopaque, cursor: *const abi.Cursor, term: u32, ptr: [*]u8, len: usize) callconv(.c) abi.Status {
    const self = from(ctx);
    if (len > abi.max_component_size) return .invalid_argument;
    const cell = self.current(cursor, term) orelse return .invalid_argument;
    inline for (builtin_types, self.builtin_ids) |T, native| {
        if (cell.id == native) {
            if (len != sdk.wire.size(T)) return .incompatible;
            if (comptime @sizeOf(T) != 0) {
                sdk.wire.encode(T, @as(*const T, @ptrCast(@alignCast(cell.bytes.ptr))).*, ptr[0..len]);
            }
            return .ok;
        }
    }
    if (self.findDynamic(cell.id) == null) return .not_found;
    if (len != cell.bytes.len) return .incompatible;
    @memcpy(ptr[0..len], cell.bytes);
    return .ok;
}
fn write(ctx: *anyopaque, cursor: *const abi.Cursor, term: u32, value: abi.Bytes) callconv(.c) abi.Status {
    const self = from(ctx);
    if (value.len > abi.max_component_size) return .invalid_argument;
    const cell = self.current(cursor, term) orelse return .invalid_argument;
    const status = self.store(cell, value.slice());
    if (status == .ok) self.world.stampAt(cell.arch, cell.chunk, cell.tick);
    return status;
}
/// Writes go straight into the queried row, so iteration never changes structure.
fn store(self: *Self, cell: Cell, value: []const u8) abi.Status {
    inline for (builtin_types, self.builtin_ids) |T, native| {
        if (cell.id == native) {
            const decoded = sdk.wire.decode(T, value) catch return .invalid_argument;
            if (comptime @sizeOf(T) != 0) @as(*T, @ptrCast(@alignCast(cell.bytes.ptr))).* = decoded;
            return .ok;
        }
    }
    const d = self.findDynamic(cell.id) orelse return .not_found;
    d.validateBytes(value) catch return .invalid_argument;
    @memcpy(cell.bytes, value);
    return .ok;
}

test "host validates layouts and sizes and writes only the queried row" {
    const allocator = std.testing.allocator;
    var schemas = SchemaRegistry.init(allocator);
    defer schemas.deinit();
    var world = zcs.World.init(allocator);
    defer world.deinit();
    try @import("../ecs/world.zig").registerEngineComponents(&world, &schemas);
    var host = Self.init(&world, &schemas, false);
    const table = host.api();
    const T = sdk.components.TransformComponent;
    const schema = comptime sdk.schema.deriveSchema(T);
    const id = table.resolve(&host, &schema.id.uuid.bytes, sdk.wire.layout(T), comptime sdk.wire.size(T));
    try std.testing.expect(id != 0);
    try std.testing.expectEqual(@as(u32, 0), table.resolve(&host, &schema.id.uuid.bytes, sdk.wire.layout(T) ^ 1, comptime sdk.wire.size(T)));
    const entity = try world.spawnWith(.{T{}});
    _ = try world.spawn();
    var bytes: [sdk.wire.size(T)]u8 = undefined;
    sdk.wire.encode(T, .{ .position = sdk.Vec3.new(1, 2, 3) }, &bytes);
    var cursor: abi.Cursor = .{ .count = 1, .ids = @splat(0) };
    cursor.ids[0] = id;
    try std.testing.expectEqual(abi.Status.invalid_argument, table.write(&host, &cursor, 0, abi.Bytes.from(&bytes)));
    var found: u64 = undefined;
    try std.testing.expectEqual(abi.Status.ok, table.next(&host, &cursor, &found));
    try std.testing.expectEqual(entity.toRaw(), found);
    try std.testing.expectEqual(abi.Status.invalid_argument, table.write(&host, &cursor, 0, abi.Bytes.from(bytes[0..1])));
    try std.testing.expectEqual(abi.Status.invalid_argument, table.write(&host, &cursor, 1, abi.Bytes.from(&bytes)));
    try std.testing.expectEqual(abi.Status.ok, table.write(&host, &cursor, 0, abi.Bytes.from(&bytes)));
    try std.testing.expectEqual(@as(f32, 2), world.getComponent(entity, T).?.position.y);
    try std.testing.expectEqual(abi.Status.incompatible, table.read(&host, &cursor, 0, &bytes, 1));
    try std.testing.expectEqual(abi.Status.not_found, table.next(&host, &cursor, &found));
}
