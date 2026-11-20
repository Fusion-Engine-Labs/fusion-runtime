const builtin = @import("builtin");
const sdk = @import("fusion_sdk");
const std = @import("std");
const zcs = @import("zcs");

const SchemaRegistry = @import("../scene/schema_registry.zig");
const World = @import("../ecs/world.zig");
const Host = @import("game_host.zig");
const Input = @import("input.zig");
const CursorLock = @import("cursor_lock.zig");

pub const GameModule = sdk.abi.Game;
pub const GetGame = sdk.abi.GetGame;

/// Present as a resource only in a world the game runs in.
pub const Binding = struct {
    game: *const GameModule,
    schemas: *SchemaRegistry,
};

/// Builds the game's view of this fixed step from the world's input and clock.
fn frameFor(world: *zcs.World) sdk.Frame {
    var frame: sdk.Frame = .{ .seconds = world.getResource(zcs.DeltaTime).seconds };
    if (world.getResourceOrNull(CursorLock)) |cursor| frame.cursor_locked = cursor.locked;
    const input = world.getResourceOrNull(Input) orelse return frame;

    for (&frame.keys, input.key_down) |*out, down| out.* = @intFromBool(down);
    for (&frame.keys_pressed, input.key_pressed) |*out, pressed| out.* = @intFromBool(pressed);
    for (&frame.keys_released, input.key_released) |*out, released| out.* = @intFromBool(released);
    for (&frame.mouse_buttons, input.mouse_button_down) |*out, down| out.* = @intFromBool(down);
    for (&frame.mouse_pressed, input.mouse_button_pressed) |*out, pressed| out.* = @intFromBool(pressed);
    for (&frame.mouse_released, input.mouse_button_released) |*out, released| out.* = @intFromBool(released);
    frame.mouse_position = .{ input.mouse_pos.x, input.mouse_pos.y };
    frame.mouse_delta = .{ input.mouse_delta.x, input.mouse_delta.y };
    frame.mouse_scroll = .{ input.mouse_scroll.x, input.mouse_scroll.y };
    return frame;
}

/// A fixed-update system. The schedule flushes `commands` after it returns
/// and discards them if it fails, which is the game's structural barrier.
pub fn fixedUpdate(world: *zcs.World, commands: *zcs.CommandBuffer) !void {
    const binding = world.getResourceOrNull(Binding) orelse return;
    var host = Host.forCallback(world, binding.schemas, commands);
    const api = host.api();
    const frame = frameFor(world);

    if (binding.game.fixed_update(&api, &frame) != .ok) {
        return error.GameFixedUpdateFailed;
    }
}

/// Calls the game's `start`, then applies what it queued. A no-op for a
/// world the game isn't bound to.
pub fn start(world: *World) !void {
    const binding = world.world.getResourceOrNull(Binding) orelse return;
    var host = Host.forCallback(&world.world, binding.schemas, &world.command_buffer);
    const api = host.api();
    errdefer world.command_buffer.discard();

    if (binding.game.start(&api) != .ok) {
        return error.GameStartFailed;
    }
    try world.command_buffer.flush();
}

/// Calls the game's `stop`, then applies what it queued. A no-op for a
/// world the game isn't bound to.
pub fn stop(world: *World) !void {
    const binding = world.world.getResourceOrNull(Binding) orelse return;
    var host = Host.forCallback(&world.world, binding.schemas, &world.command_buffer);
    const api = host.api();
    errdefer world.command_buffer.discard();

    if (binding.game.stop(&api) != .ok) {
        return error.GameStopFailed;
    }
    try world.command_buffer.flush();
}

pub const GameLibrary = struct {
    const supported = switch (builtin.os.tag) {
        .linux, .macos => true,
        else => false,
    };

    const Handle = if (supported) std.DynLib else struct {};

    handle: Handle,
    game: *const GameModule,

    pub fn open(path: []const u8) !GameLibrary {
        if (!supported) {
            return error.UnsupportedPlatform;
        }

        var handle = try std.DynLib.open(path);
        errdefer handle.close();

        const get_game = handle.lookup(GetGame, sdk.abi.entry_symbol) orelse return error.MissingGameLibraryEntryPoint;
        const game = get_game();

        if (game.version != sdk.abi.version or game.size != @sizeOf(GameModule)) {
            return error.IncompatibleGameLibraryVersion;
        }

        return .{
            .handle = handle,
            .game = game,
        };
    }

    /// Declares the game's components in `world`, so scenes that use them
    /// load and the editor can show them. The game does not run there.
    pub fn registerComponents(self: *const GameLibrary, world: *World) !void {
        var host = Host.forRegistration(&world.world, world.schemas);
        const api = host.api();
        if (self.game.register_components(&api) != .ok) {
            return error.GameRegistrationFailed;
        }
    }

    /// Declares the game's components in `world` and lets `start`,
    /// `fixedUpdate` and `stop` call into the game there.
    pub fn bind(self: *const GameLibrary, world: *World) !void {
        try self.registerComponents(world);
        try world.setResource(Binding, .{ .game = self.game, .schemas = world.schemas });
    }

    pub fn deinit(self: *GameLibrary) void {
        if (comptime supported) {
            self.handle.close();
        }
    }
};

const testing = std.testing;
const TransformComponent = sdk.components.TransformComponent;

const TestCounter = struct {
    count: u32 = 0,

    pub const schema_meta = sdk.scene_schema.SchemaMeta{
        .id = "9b0f6f0e-55a7-4a52-a0c7-3d4d1f7c2e11",
        .name = "test.module.counter",
        .version = 1,
        .fields = &.{.{ .name = "count", .number = 1 }},
    };
};

const TestGame = struct {
    var seen: sdk.Frame = .{};
    var stops: u32 = 0;
    var fail_update = false;

    fn onStart(world: sdk.World) !void {
        _ = try world.spawn(.{ TransformComponent{}, TestCounter{} });
    }

    fn onUpdate(world: sdk.World, frame: *const sdk.Frame) !void {
        seen = frame.*;
        if (frame.wasMousePressed(.Right)) try world.setCursorLocked(!frame.cursor_locked);
        var query = try world.query(.{ .write = &.{TestCounter} });
        while (try query.each()) |row| {
            var counter = try row.read(TestCounter);
            counter.count += 1;
            try row.write(TestCounter, counter);
            if (counter.count == 2) try row.despawn();
        }
        if (fail_update) {
            _ = try world.spawn(.{TransformComponent{}});
            return error.TestUpdateFailed;
        }
    }

    fn onStop(_: sdk.World) !void {
        stops += 1;
    }

    const module = sdk.game(.{
        .components = &.{TestCounter},
        .start = onStart,
        .update = onUpdate,
        .stop = onStop,
    });

    /// Stands in for an opened library; never `deinit` it.
    const library: GameLibrary = .{ .handle = undefined, .game = &module };
};

fn countTransforms(world: *zcs.World) usize {
    var count: usize = 0;
    var query = world.query(.{ .read = &.{TransformComponent} });
    while (query.each()) |_| count += 1;
    return count;
}

test "a bound game starts, updates through the schedule and stops in its world" {
    var schemas = SchemaRegistry.init(testing.allocator);
    defer schemas.deinit();
    var instance: World = undefined;
    try instance.init(testing.allocator, &schemas, .{ .components = &.{} });
    defer instance.deinit();
    const world = &instance.world;
    const schedule: zcs.Schedule.Spec = .{ .update = &.{fixedUpdate} };

    // Unbound worlds ignore every game entry point.
    try start(&instance);
    try zcs.Schedule.run(world, &instance.command_buffer, .{ .delta_time = 0.5 }, schedule);
    try stop(&instance);
    try testing.expectEqual(@as(usize, 0), countTransforms(world));

    TestGame.stops = 0;
    TestGame.fail_update = false;
    try TestGame.library.bind(&instance);
    try testing.expect(schemas.getByName("test.module.counter") != null);
    try testing.expectError(error.GameRegistrationFailed, TestGame.library.registerComponents(&instance));

    try start(&instance);
    try testing.expectEqual(@as(usize, 1), countTransforms(world));

    var input: Input = .{};
    input.applyEvent(.{ .KeyPressed = .W });
    input.applyEvent(.{ .MousePressed = .Right });
    input.applyEvent(.{ .MouseMove = .{ .x = 10, .y = 20 } });
    input.applyEvent(.{ .MouseMove = .{ .x = 13, .y = 24 } });
    input.applyEvent(.{ .MouseScroll = .{ .x = 0, .y = -2 } });
    try instance.setResource(Input, input);

    try zcs.Schedule.run(world, &instance.command_buffer, .{ .delta_time = 0.5 }, schedule);
    try testing.expectEqual(@as(f32, 0.5), TestGame.seen.seconds);
    try testing.expect(TestGame.seen.isKeyDown(.W));
    try testing.expect(TestGame.seen.wasKeyPressed(.W));
    try testing.expect(!TestGame.seen.wasKeyReleased(.W));
    try testing.expect(TestGame.seen.isMouseDown(.Right));
    try testing.expect(TestGame.seen.wasMousePressed(.Right));
    try testing.expect(!TestGame.seen.isMouseDown(.Left));
    try testing.expectEqual([2]f32{ 13, 24 }, TestGame.seen.mouse_position);
    try testing.expectEqual([2]f32{ 3, 4 }, TestGame.seen.mouse_delta);
    try testing.expectEqual([2]f32{ 0, -2 }, TestGame.seen.mouse_scroll);
    try testing.expectEqual(@as(usize, 1), countTransforms(world));

    // The game asked for a cursor lock; the window owner grants it later and
    // the game sees the result on its next frame.
    const cursor = world.getResource(CursorLock);
    try testing.expectEqual(@as(?bool, true), cursor.requested);
    try testing.expect(!TestGame.seen.cursor_locked);
    try testing.expect(cursor.resolve(true));
    world.getResource(Input).beginFrame();

    // The second update despawns the counter entity once the system returns.
    try zcs.Schedule.run(world, &instance.command_buffer, .{ .delta_time = 0.5 }, schedule);
    try testing.expectEqual(@as(usize, 0), countTransforms(world));
    try testing.expect(TestGame.seen.cursor_locked);

    // A failing update leaves nothing behind from that callback.
    TestGame.fail_update = true;
    try testing.expectError(error.GameFixedUpdateFailed, zcs.Schedule.run(world, &instance.command_buffer, .{ .delta_time = 0.5 }, schedule));
    try testing.expectEqual(@as(usize, 0), countTransforms(world));
    TestGame.fail_update = false;

    try stop(&instance);
    try testing.expectEqual(@as(u32, 1), TestGame.stops);
}
