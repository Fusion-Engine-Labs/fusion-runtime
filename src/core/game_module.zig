const builtin = @import("builtin");
const sdk = @import("fusion_sdk");
const std = @import("std");
const zcs = @import("zcs");

const SchemaRegistry = @import("../scene/schema_registry.zig");
const World = @import("../ecs/world.zig");
const Host = @import("game_host.zig");
const Input = @import("input.zig");

pub const GameModule = sdk.abi.Game;
pub const GetGame = sdk.abi.GetGame;
pub const Binding = struct {
    game: *const GameModule,
    schemas: *SchemaRegistry,
};

pub fn fixedUpdate(world: *zcs.World, _: *zcs.CommandBuffer) !void {
    const binding = world.getResourceOrNull(Binding) orelse return;
    var host = Host.init(world, binding.schemas, false);
    const api = host.api();

    var frame: sdk.Frame = .{ .seconds = world.getResource(zcs.DeltaTime).seconds };
    if (world.getResourceOrNull(Input)) |input| {
        for (&frame.keys, input.key_down) |*out, down| {
            out.* = @intFromBool(down);
        }
    }

    if (binding.game.fixed_update(&api, &frame) != .ok) {
        return error.GameFixedUpdateFailed;
    }
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

    pub fn bind(self: *const GameLibrary, world: *World) !void {
        var host = Host.init(&world.world, world.schemas, true);
        const api = host.api();
        if (self.game.register_components(&api) != .ok) return error.GameRegistrationFailed;
        try world.setResource(Binding, .{ .game = self.game, .schemas = world.schemas });
    }

    pub fn deinit(self: *GameLibrary) void {
        if (comptime supported) {
            self.handle.close();
        }
    }
};
