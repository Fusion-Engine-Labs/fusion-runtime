const builtin = @import("builtin");
const std = @import("std");
const zcs = @import("zcs");
const sdk = @import("fusion_sdk");
const abi = sdk.abi;

const DynamicComponent = @import("../scene/dynamic_component.zig");
const ComponentTypeId = @import("zimp").id.types.ComponentTypeId;
const SchemaRegistry = @import("../scene/schema_registry.zig");
const log = @import("log.zig");

const Self = @This();

const game_log = std.log.scoped(.game);
const builtin_types = sdk.components.builtin_types;

world: *zcs.World,
schemas: *SchemaRegistry,
/// Where structural changes wait until the game callback returns. Null while
/// the game is registering components, when nothing else is allowed.
commands: ?*zcs.CommandBuffer,
builtin_ids: [builtin_types.len]u32,

/// A host for `Game.register_components`.
pub fn forRegistration(world: *zcs.World, schemas: *SchemaRegistry) Self {
    return init(world, schemas, null);
}

/// A host for `Game.start`, `Game.fixed_update` and `Game.stop`. The caller
/// flushes `commands` when the callback succeeds and discards it otherwise.
pub fn forCallback(world: *zcs.World, schemas: *SchemaRegistry, commands: *zcs.CommandBuffer) Self {
    return init(world, schemas, commands);
}

fn init(world: *zcs.World, schemas: *SchemaRegistry, commands: ?*zcs.CommandBuffer) Self {
    var self: Self = .{ .world = world, .schemas = schemas, .commands = commands, .builtin_ids = undefined };
    inline for (builtin_types, &self.builtin_ids) |T, *out| {
        out.* = if (world.componentId(T)) |native| @backingInt(native) else 0;
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
        .spawn = spawn,
        .despawn = despawn,
        .add = add,
        .remove = remove,
        .get = get,
        .set = set,
        .log = logMessage,
    };
}

fn from(ctx: *anyopaque) *Self {
    return @ptrCast(@alignCast(ctx));
}

fn toEntity(entity: abi.Entity) zcs.EntityID {
    return zcs.EntityID.fromRaw(@backingInt(entity));
}

fn toComponent(id: u32) zcs.ComponentId {
    return @fromBackingInt(id);
}

fn register(ctx: *anyopaque, json: abi.Bytes) callconv(.c) abi.Status {
    const self = from(ctx);
    if (self.commands != null) {
        return .invalid_argument;
    }

    self.schemas.registerDynamic(self.world, json.slice()) catch |err| {
        log.err("game component registration: {s}", .{@errorName(err)});
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
            return @backingInt(d.id);
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
        if (id == @backingInt(d.id)) return d;
    }
    return null;
}

/// Marks a term that is a tag: it lives in the archetype mask but has no data column.
const no_column = std.math.maxInt(u32);

fn next(ctx: *anyopaque, cursor: *abi.Cursor, entity: *abi.Entity) callconv(.c) abi.Status {
    const self = from(ctx);
    if (self.commands == null or cursor.count == 0 or cursor.count > abi.max_query_terms) return .invalid_argument;
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
                if (!arch.has(toComponent(id))) {
                    break false;
                }
            } else true;

            if (!matches) {
                continue;
            }

            for (ids, cursor.columns[0..ids.len], cursor.ticks[0..ids.len]) |id, *column, *tick| {
                column.* = no_column;
                for (arch.columns.items, 0..) |c, i| {
                    if (c.id == toComponent(id)) {
                        column.* = @intCast(i);
                    }
                }
                tick.* = @intCast(arch.tickIndex(toComponent(id)).?);
            }
        }
        while (cursor.chunk < arch.chunks.items.len) : ({
            cursor.chunk += 1;
            cursor.row = 0;
        }) {
            const entities = zcs.Archetype.entityColumn(arch.chunks.items[cursor.chunk]);
            if (cursor.row < entities.len) {
                entity.* = @fromBackingInt(entities[cursor.row].toRaw());
                cursor.row += 1;
                return .ok;
            }
        }
    }
    return .not_found;
}

const Cell = struct {
    id: u32,
    bytes: []u8,
    arch: *zcs.Archetype,
    chunk: u32,
    tick: usize,
};

fn current(self: *Self, cursor: *const abi.Cursor, term: u32) ?Cell {
    if (self.commands == null or cursor.count > abi.max_query_terms or term >= cursor.count or cursor.row == 0) {
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
    if (tick >= arch.change_ids.items.len or @backingInt(arch.change_ids.items[tick]) != id) return null;
    const column = cursor.columns[term];
    const bytes: []u8 = if (column == no_column) &.{} else blk: {
        if (column >= arch.columns.items.len or @backingInt(arch.columns.items[column].id) != id) return null;
        break :blk zcs.Archetype.cell(chunk, @intCast(row), arch.columns.items[column]);
    };
    return .{ .id = id, .bytes = bytes, .arch = arch, .chunk = cursor.chunk, .tick = tick };
}

/// Copies a stored component out to `out` in wire format.
fn load(self: *Self, id: u32, stored: []const u8, out: []u8) abi.Status {
    inline for (builtin_types, self.builtin_ids) |T, native| {
        if (id == native) {
            if (out.len != sdk.wire.size(T)) return .incompatible;
            if (comptime @sizeOf(T) != 0) {
                sdk.wire.encode(T, @as(*const T, @ptrCast(@alignCast(stored.ptr))).*, out);
            }
            return .ok;
        }
    }
    if (self.findDynamic(id) == null) return .not_found;
    if (out.len != stored.len) return .incompatible;
    @memcpy(out, stored);
    return .ok;
}

/// Overwrites a stored component in place from wire format, so it never changes structure.
fn store(self: *Self, id: u32, stored: []u8, value: []const u8) abi.Status {
    inline for (builtin_types, self.builtin_ids) |T, native| {
        if (id == native) {
            const decoded = sdk.wire.decode(T, value) catch return .invalid_argument;
            if (comptime @sizeOf(T) != 0) @as(*T, @ptrCast(@alignCast(stored.ptr))).* = decoded;
            return .ok;
        }
    }
    const d = self.findDynamic(id) orelse return .not_found;
    d.validateBytes(value) catch return .invalid_argument;
    @memcpy(stored, value);
    return .ok;
}

fn read(ctx: *anyopaque, cursor: *const abi.Cursor, term: u32, ptr: [*]u8, len: usize) callconv(.c) abi.Status {
    const self = from(ctx);
    if (len > abi.max_component_size) return .invalid_argument;
    const cell = self.current(cursor, term) orelse return .invalid_argument;
    return self.load(cell.id, cell.bytes, ptr[0..len]);
}

fn write(ctx: *anyopaque, cursor: *const abi.Cursor, term: u32, value: abi.Bytes) callconv(.c) abi.Status {
    const self = from(ctx);
    if (value.len > abi.max_component_size) return .invalid_argument;
    const cell = self.current(cursor, term) orelse return .invalid_argument;
    const status = self.store(cell.id, cell.bytes, value.slice());
    if (status == .ok) self.world.stampAt(cell.arch, cell.chunk, cell.tick);
    return status;
}

fn spawn(ctx: *anyopaque, entity: *abi.Entity) callconv(.c) abi.Status {
    const commands = from(ctx).commands orelse return .invalid_argument;
    const spawned = commands.spawn() catch return .failed;
    entity.* = @fromBackingInt(spawned.toRaw());
    return .ok;
}

fn despawn(ctx: *anyopaque, entity: abi.Entity) callconv(.c) abi.Status {
    const commands = from(ctx).commands orelse return .invalid_argument;
    commands.despawn(toEntity(entity)) catch return .failed;
    return .ok;
}

fn add(ctx: *anyopaque, entity: abi.Entity, id: u32, value: abi.Bytes) callconv(.c) abi.Status {
    const self = from(ctx);
    const commands = self.commands orelse return .invalid_argument;
    if (value.len > abi.max_component_size or !self.validId(id)) return .invalid_argument;

    // Built-ins are stored in their native layout, game components as wire bytes.
    inline for (builtin_types, self.builtin_ids) |T, native| {
        if (id == native) {
            const decoded = sdk.wire.decode(T, value.slice()) catch return .invalid_argument;
            commands.add(toEntity(entity), toComponent(id), std.mem.asBytes(&decoded)) catch return .failed;
            return .ok;
        }
    }
    const d = self.findDynamic(id) orelse return .not_found;
    d.validateBytes(value.slice()) catch return .invalid_argument;
    commands.add(toEntity(entity), toComponent(id), value.slice()) catch return .failed;
    return .ok;
}

fn remove(ctx: *anyopaque, entity: abi.Entity, id: u32) callconv(.c) abi.Status {
    const self = from(ctx);
    const commands = self.commands orelse return .invalid_argument;
    if (!self.validId(id)) return .invalid_argument;
    commands.remove(toEntity(entity), toComponent(id)) catch return .failed;
    return .ok;
}

fn get(ctx: *anyopaque, entity: abi.Entity, id: u32, ptr: [*]u8, len: usize) callconv(.c) abi.Status {
    const self = from(ctx);
    if (self.commands == null or len > abi.max_component_size or !self.validId(id)) return .invalid_argument;
    const stored = self.world.get(toEntity(entity), toComponent(id)) orelse return .not_found;
    return self.load(id, stored, ptr[0..len]);
}

fn set(ctx: *anyopaque, entity: abi.Entity, id: u32, value: abi.Bytes) callconv(.c) abi.Status {
    const self = from(ctx);
    if (self.commands == null or value.len > abi.max_component_size or !self.validId(id)) return .invalid_argument;
    const target = toEntity(entity);
    const stored = self.world.get(target, toComponent(id)) orelse return .not_found;
    const status = self.store(id, stored, value.slice());
    if (status == .ok) {
        const location = self.world.locations.items[target.index];
        self.world.stamp(location.archetype.?, location.chunk_idx, toComponent(id));
    }
    return status;
}

fn logMessage(_: *anyopaque, level: abi.LogLevel, message: abi.Bytes) callconv(.c) void {
    if (comptime builtin.is_test) {
        return;
    }

    const text = message.slice()[0..@min(message.len, abi.max_log_message)];
    switch (level) {
        .err => game_log.err("{s}", .{text}),
        .warn => game_log.warn("{s}", .{text}),
        .debug => game_log.debug("{s}", .{text}),
        .info, _ => game_log.info("{s}", .{text}),
    }
}

const TestTag = struct {
    value: u32 = 0,

    pub const schema_meta = sdk.scene_schema.SchemaMeta{
        .id = "5d0e3c11-7a44-4f0a-9d53-2f1c6a8b9e40",
        .name = "test.host.tag",
        .version = 1,
        .fields = &.{.{ .name = "value", .number = 1 }},
    };
};

const TestHost = struct {
    schemas: SchemaRegistry,
    world: zcs.World,
    commands: zcs.CommandBuffer,

    /// Initialized in place: the command buffer points at `world`.
    fn init(self: *TestHost) !void {
        self.schemas = SchemaRegistry.init(std.testing.allocator);
        errdefer self.schemas.deinit();
        self.world = zcs.World.init(std.testing.allocator);
        errdefer self.world.deinit();
        try @import("../ecs/world.zig").registerEngineComponents(&self.world, &self.schemas);
        self.commands = zcs.CommandBuffer.init(&self.world);
    }

    fn deinit(self: *TestHost) void {
        self.commands.deinit();
        self.world.deinit();
        self.schemas.deinit();
    }

    fn registerGameComponent(self: *TestHost, comptime T: type) !u32 {
        var host = forRegistration(&self.world, &self.schemas);
        const table = host.api();
        const json = try std.json.Stringify.valueAlloc(std.testing.allocator, sdk.descriptor.describe(T), .{});
        defer std.testing.allocator.free(json);
        try std.testing.expectEqual(abi.Status.ok, table.register_component(&host, abi.Bytes.from(json)));
        const schema = comptime sdk.schema.deriveSchema(T);
        return table.resolve(&host, &schema.id.uuid.bytes, sdk.wire.layout(T), comptime sdk.wire.size(T));
    }
};

fn transformId(host: *Self) u32 {
    const T = sdk.components.TransformComponent;
    const schema = comptime sdk.schema.deriveSchema(T);
    return host.api().resolve(host, &schema.id.uuid.bytes, sdk.wire.layout(T), comptime sdk.wire.size(T));
}

test "host validates layouts and sizes and writes only the queried row" {
    var fixture: TestHost = undefined;
    try fixture.init();
    defer fixture.deinit();
    const world = &fixture.world;
    var host = forCallback(world, &fixture.schemas, &fixture.commands);
    const table = host.api();
    const T = sdk.components.TransformComponent;
    const schema = comptime sdk.schema.deriveSchema(T);
    const id = transformId(&host);
    try std.testing.expect(id != 0);
    try std.testing.expectEqual(@as(u32, 0), table.resolve(&host, &schema.id.uuid.bytes, sdk.wire.layout(T) ^ 1, comptime sdk.wire.size(T)));
    const entity = try world.spawnWith(.{T{}});
    _ = try world.spawn();
    var bytes: [sdk.wire.size(T)]u8 = undefined;
    sdk.wire.encode(T, .{ .position = sdk.Vec3.new(1, 2, 3) }, &bytes);
    var cursor: abi.Cursor = .{ .count = 1, .ids = @splat(0) };
    cursor.ids[0] = id;
    try std.testing.expectEqual(abi.Status.invalid_argument, table.write(&host, &cursor, 0, abi.Bytes.from(&bytes)));
    var found: abi.Entity = .none;
    try std.testing.expectEqual(abi.Status.ok, table.next(&host, &cursor, &found));
    try std.testing.expectEqual(entity.toRaw(), @backingInt(found));
    try std.testing.expectEqual(abi.Status.invalid_argument, table.write(&host, &cursor, 0, abi.Bytes.from(bytes[0..1])));
    try std.testing.expectEqual(abi.Status.invalid_argument, table.write(&host, &cursor, 1, abi.Bytes.from(&bytes)));
    try std.testing.expectEqual(abi.Status.ok, table.write(&host, &cursor, 0, abi.Bytes.from(&bytes)));
    try std.testing.expectEqual(@as(f32, 2), world.getComponent(entity, T).?.position.y);
    try std.testing.expectEqual(abi.Status.incompatible, table.read(&host, &cursor, 0, &bytes, 1));
    try std.testing.expectEqual(abi.Status.not_found, table.next(&host, &cursor, &found));
}

test "a registering host only accepts component registration" {
    var fixture: TestHost = undefined;
    try fixture.init();
    defer fixture.deinit();
    var host = forRegistration(&fixture.world, &fixture.schemas);
    const table = host.api();

    var entity: abi.Entity = .none;
    var cursor: abi.Cursor = .{ .count = 1, .ids = @splat(1) };
    var bytes: [4]u8 = undefined;
    try std.testing.expectEqual(abi.Status.invalid_argument, table.spawn(&host, &entity));
    try std.testing.expectEqual(abi.Status.invalid_argument, table.despawn(&host, entity));
    try std.testing.expectEqual(abi.Status.invalid_argument, table.add(&host, entity, 1, abi.Bytes.from(&bytes)));
    try std.testing.expectEqual(abi.Status.invalid_argument, table.remove(&host, entity, 1));
    try std.testing.expectEqual(abi.Status.invalid_argument, table.get(&host, entity, 1, &bytes, bytes.len));
    try std.testing.expectEqual(abi.Status.invalid_argument, table.set(&host, entity, 1, abi.Bytes.from(&bytes)));
    try std.testing.expectEqual(abi.Status.invalid_argument, table.next(&host, &cursor, &entity));

    var callback_host = forCallback(&fixture.world, &fixture.schemas, &fixture.commands);
    try std.testing.expectEqual(abi.Status.invalid_argument, callback_host.api().register_component(&callback_host, abi.Bytes.from("{}")));
}

test "structural commands wait for the flush and apply in order" {
    var fixture: TestHost = undefined;
    try fixture.init();
    defer fixture.deinit();
    const world = &fixture.world;
    const tag_id = try fixture.registerGameComponent(TestTag);
    try std.testing.expect(tag_id != 0);

    var host = forCallback(world, &fixture.schemas, &fixture.commands);
    const table = host.api();
    const T = sdk.components.TransformComponent;
    const transform_id = transformId(&host);

    var transform_bytes: [sdk.wire.size(T)]u8 = undefined;
    sdk.wire.encode(T, .{ .position = sdk.Vec3.new(4, 5, 6) }, &transform_bytes);
    var tag_bytes: [sdk.wire.size(TestTag)]u8 = undefined;
    sdk.wire.encode(TestTag, .{ .value = 9 }, &tag_bytes);

    var spawned: abi.Entity = .none;
    try std.testing.expectEqual(abi.Status.ok, table.spawn(&host, &spawned));
    try std.testing.expect(spawned != .none);
    try std.testing.expectEqual(abi.Status.ok, table.add(&host, spawned, transform_id, abi.Bytes.from(&transform_bytes)));
    try std.testing.expectEqual(abi.Status.ok, table.add(&host, spawned, tag_id, abi.Bytes.from(&tag_bytes)));
    try std.testing.expectEqual(abi.Status.invalid_argument, table.add(&host, spawned, transform_id, abi.Bytes.from(transform_bytes[0..3])));
    try std.testing.expectEqual(abi.Status.invalid_argument, table.add(&host, spawned, tag_id, abi.Bytes.from(tag_bytes[0..1])));
    try std.testing.expectEqual(abi.Status.invalid_argument, table.add(&host, spawned, 0, abi.Bytes.from(&tag_bytes)));

    // Nothing is attached until the callback's commands are flushed.
    const entity = zcs.EntityID.fromRaw(@backingInt(spawned));
    try std.testing.expect(world.isAlive(entity));
    try std.testing.expect(!world.hasComponent(entity, T));
    var out: [sdk.wire.size(T)]u8 = undefined;
    try std.testing.expectEqual(abi.Status.not_found, table.get(&host, spawned, transform_id, &out, out.len));

    try fixture.commands.flush();
    try std.testing.expectEqual(@as(f32, 5), world.getComponent(entity, T).?.position.y);
    try std.testing.expectEqual(abi.Status.ok, table.get(&host, spawned, tag_id, &tag_bytes, tag_bytes.len));
    try std.testing.expectEqual(@as(u32, 9), (try sdk.wire.decode(TestTag, &tag_bytes)).value);

    try std.testing.expectEqual(abi.Status.ok, table.remove(&host, spawned, tag_id));
    try fixture.commands.flush();
    try std.testing.expect(world.isAlive(entity));
    try std.testing.expectEqual(abi.Status.not_found, table.get(&host, spawned, tag_id, &tag_bytes, tag_bytes.len));

    try std.testing.expectEqual(abi.Status.ok, table.despawn(&host, spawned));
    try std.testing.expect(world.isAlive(entity));
    try fixture.commands.flush();
    try std.testing.expect(!world.isAlive(entity));
    try std.testing.expectEqual(abi.Status.not_found, table.get(&host, spawned, transform_id, &out, out.len));
}

test "discarding the commands removes entities a failed callback spawned" {
    var fixture: TestHost = undefined;
    try fixture.init();
    defer fixture.deinit();
    var host = forCallback(&fixture.world, &fixture.schemas, &fixture.commands);
    const table = host.api();

    var spawned: abi.Entity = .none;
    try std.testing.expectEqual(abi.Status.ok, table.spawn(&host, &spawned));
    const entity = zcs.EntityID.fromRaw(@backingInt(spawned));
    try std.testing.expect(fixture.world.isAlive(entity));
    fixture.commands.discard();
    try std.testing.expect(!fixture.world.isAlive(entity));
}

test "point access reads and overwrites one entity without changing structure" {
    var fixture: TestHost = undefined;
    try fixture.init();
    defer fixture.deinit();
    const world = &fixture.world;
    var host = forCallback(world, &fixture.schemas, &fixture.commands);
    const table = host.api();
    const T = sdk.components.TransformComponent;
    const id = transformId(&host);

    const entity = try world.spawnWith(.{T{ .position = sdk.Vec3.new(1, 0, 0) }});
    const bare = try world.spawn();
    const handle: abi.Entity = @fromBackingInt(entity.toRaw());
    const bare_handle: abi.Entity = @fromBackingInt(bare.toRaw());

    var bytes: [sdk.wire.size(T)]u8 = undefined;
    try std.testing.expectEqual(abi.Status.ok, table.get(&host, handle, id, &bytes, bytes.len));
    try std.testing.expectEqual(@as(f32, 1), (try sdk.wire.decode(T, &bytes)).position.x);
    try std.testing.expectEqual(abi.Status.incompatible, table.get(&host, handle, id, &bytes, 1));
    try std.testing.expectEqual(abi.Status.not_found, table.get(&host, bare_handle, id, &bytes, bytes.len));
    try std.testing.expectEqual(abi.Status.invalid_argument, table.get(&host, handle, 0, &bytes, bytes.len));

    sdk.wire.encode(T, .{ .position = sdk.Vec3.new(8, 0, 0) }, &bytes);
    try std.testing.expectEqual(abi.Status.ok, table.set(&host, handle, id, abi.Bytes.from(&bytes)));
    try std.testing.expectEqual(@as(f32, 8), world.getComponent(entity, T).?.position.x);
    try std.testing.expectEqual(abi.Status.invalid_argument, table.set(&host, handle, id, abi.Bytes.from(bytes[0..2])));
    // `set` never attaches a component; that is `add`'s job.
    try std.testing.expectEqual(abi.Status.not_found, table.set(&host, bare_handle, id, abi.Bytes.from(&bytes)));
    try std.testing.expect(!world.hasComponent(bare, T));

    world.despawn(entity);
    try std.testing.expectEqual(abi.Status.not_found, table.set(&host, handle, id, abi.Bytes.from(&bytes)));
}
