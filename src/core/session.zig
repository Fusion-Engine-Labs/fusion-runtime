//! One ECS world together with the schemas that describe it.
//!
//! The runtime keeps an authoring session for the open scene and, while the
//! game is playing, a second disposable one built from a copy of that scene.
//! Each owns its own component registry, so destroying a session removes
//! every entity and resource in it, however it was created.

const std = @import("std");
const zimp = @import("zimp");

const AssetManager = @import("../assets/asset_manager.zig").AssetManager;
const SchemaRegistry = @import("../scene/schema_registry.zig");
const WorldInstance = @import("../ecs/world.zig");
const game_module = @import("game_module.zig");
const Input = @import("input.zig");
const Game = @import("game.zig");
const Time = @import("time.zig");
const log = @import("log.zig");

const GameLibrary = game_module.GameLibrary;

const Session = @This();

allocator: std.mem.Allocator,
schemas: SchemaRegistry,
world: WorldInstance,
/// Set once the game's `start` succeeded, so `destroy` owes it a `stop`.
game_started: bool = false,

pub const Options = struct {
    /// Declares this game's components in the session's world. The library
    /// must stay open for as long as the session exists.
    library: ?*const GameLibrary = null,
    /// Also lets the game run here: its callbacks are bound to the world.
    simulate: bool = false,
};

/// Heap-allocated because the world and its command buffer point at their
/// own storage.
pub fn create(allocator: std.mem.Allocator, comptime game: Game, options: Options) !*Session {
    const self = try allocator.create(Session);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .schemas = SchemaRegistry.init(allocator),
        .world = undefined,
    };
    errdefer self.schemas.deinit();

    try self.world.init(allocator, &self.schemas, game);
    errdefer self.world.deinit();

    try self.world.setResource(Input, .{});
    try self.world.setResource(Time.SimulationClock, .{});

    if (options.library) |library| {
        if (options.simulate) {
            try library.bind(&self.world);
        } else {
            try library.registerComponents(&self.world);
        }
    }

    return self;
}

/// Spawns `document` into the world. Takes ownership of it, including when
/// this fails.
pub fn loadScene(self: *Session, assets: *AssetManager, document: zimp.scene.SceneDocument) !void {
    try self.world.startScene(self.allocator, assets, document);
}

/// Runs the game's `start` callback. A no-op unless the session simulates.
pub fn startGame(self: *Session) !void {
    try game_module.start(&self.world);
    self.game_started = true;
}

pub fn destroy(self: *Session) void {
    if (self.game_started) {
        game_module.stop(&self.world) catch |err| {
            log.err("game stop failed: {s}", .{@errorName(err)});
        };
    }

    self.world.deinit();
    self.schemas.deinit();

    const allocator = self.allocator;
    allocator.destroy(self);
}

const testing = std.testing;

test "a session registers engine components and owns its resources" {
    const session = try Session.create(testing.allocator, .{ .components = &.{} }, .{});
    defer session.destroy();

    try testing.expect(session.schemas.getByName("fusion.runtime.transform") != null);
    try testing.expect(session.world.world.getResourceOrNull(Input) != null);
    try testing.expect(session.world.world.getResourceOrNull(Time.SimulationClock) != null);
    try testing.expect(session.world.world.getResourceOrNull(game_module.Binding) == null);
    try testing.expect(!session.game_started);

    // Without a bound game, starting is harmless.
    try session.startGame();
}

test "two sessions never share entities or registries" {
    const TransformComponent = @import("../ecs/components.zig").TransformComponent;
    const first = try Session.create(testing.allocator, .{ .components = &.{} }, .{});
    defer first.destroy();
    const second = try Session.create(testing.allocator, .{ .components = &.{} }, .{});
    defer second.destroy();

    const entity = try first.world.world.spawnWith(.{TransformComponent{}});
    try testing.expect(first.world.world.isAlive(entity));
    try testing.expect(!second.world.world.isAlive(entity));
    try testing.expect(&first.schemas != &second.schemas);
}
