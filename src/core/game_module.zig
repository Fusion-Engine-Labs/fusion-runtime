const builtin = @import("builtin");
const std = @import("std");
const zcs = @import("zcs");

const World = @import("../ecs/world.zig");

pub const version: u32 = 1;
pub const symbol: [:0]const u8 = "fusion_get_game";

pub const GameModule = struct {
    version: u32 = version,
    register_components: *const fn (*World) bool,
    fixed_update: *const fn (*zcs.World, *zcs.CommandBuffer) bool,
};

pub const GetGame = *const fn () callconv(.c) *const GameModule;

pub const Binding = struct {
    game: *const GameModule,
};

pub fn fixedUpdate(world: *zcs.World, commands: *zcs.CommandBuffer) !void {
    const binding = world.getResourceOrNull(Binding) orelse return;
    if (!binding.game.fixed_update(world, commands)) {
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

        const get_game = handle.lookup(GetGame, symbol) orelse return error.MissingGameLibraryEntryPoint;
        const game = get_game();

        if (game.version != version) {
            return error.IncompatibleGameLibraryVersion;
        }

        return .{
            .handle = handle,
            .game = game,
        };
    }

    pub fn deinit(self: *GameLibrary) void {
        if (comptime supported) {
            self.handle.close();
        }
    }
};
