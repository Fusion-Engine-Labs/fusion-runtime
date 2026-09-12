const std = @import("std");
const zcs = @import("zcs");

const AssetManager = @import("../assets/asset_manager.zig").AssetManager;
const SchemaRegistry = @import("../scene/schema_registry.zig");
const engine_components = @import("../ecs/components.zig");
const DebugStats = @import("../graphics/debug_stats.zig");
const Renderer = @import("../graphics/renderer.zig");
const Project = @import("../project/project.zig");
const WorldInstance = @import("../ecs/world.zig");
const ecs = @import("../ecs/world.zig");
const Input = @import("input.zig");
const event = @import("event.zig");
const Game = @import("game.zig");
const Time = @import("time.zig");

pub fn Runtime(comptime game: Game) type {
    return struct {
        allocator: std.mem.Allocator,
        frame_cpu_start: f64 = 0,
        project: *const Project,
        schemas: SchemaRegistry,
        world: WorldInstance,
        assets: AssetManager,
        time: Time,
        renderer: Renderer,
        io: std.Io,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, project: *const Project) !*@This() {
            const runtime = try allocator.create(@This());
            errdefer allocator.destroy(runtime);

            runtime.* = .{
                .allocator = allocator,
                .io = io,
                .project = project,
                .schemas = undefined,
                .assets = undefined,
                .renderer = undefined,
                .world = undefined,
                .time = try Time.init(game.simulation),
            };

            runtime.renderer = try Renderer.init(allocator, .opengl);
            errdefer runtime.renderer.deinit();

            runtime.assets = try AssetManager.init(allocator, io, project, &runtime.renderer.device);
            errdefer runtime.assets.deinit();

            try runtime.assets.preloadBuiltins();

            runtime.schemas = SchemaRegistry.init(allocator);
            errdefer runtime.schemas.deinit();

            try runtime.world.init(allocator, &runtime.schemas, game);
            errdefer runtime.world.deinit();

            try runtime.world.setResource(Input, .{});
            try runtime.world.setResource(Time.SimulationClock, .{});

            return runtime;
        }

        pub fn start(self: *@This()) !void {
            const default_scene = try self.project.loadDefaultScene(
                self.allocator,
                self.io,
            );

            try self.world.startScene(
                self.allocator,
                &self.assets,
                default_scene,
            );
            self.resetSimulation();
        }

        pub fn resetActiveScene(self: *@This()) !void {
            try self.world.resetActiveScene();
            self.resetSimulation();
        }

        fn resetSimulation(self: *@This()) void {
            self.time.reset();
            self.world.getResource(Time.SimulationClock).* = .{};
        }

        pub fn setSimulationPaused(self: *@This(), paused: bool) void {
            self.time.setPaused(paused);
        }

        pub fn stepSimulation(self: *@This()) !void {
            try self.time.requestSingleStep();
        }

        pub fn setTimeScale(self: *@This(), scale: f64) !void {
            try self.time.setTimeScale(scale);
        }

        pub fn beginFrame(self: *@This(), now: f64, focused: bool) void {
            self.world.getResource(Input).beginFrame();
            self.world.getResource(Input).setFocused(focused);
            self.time.beginFrame(now);
            self.frame_cpu_start = now;
        }

        pub fn processEvents(self: *@This(), events: []const event.ZEvent) void {
            for (events) |ev| {
                self.processEvent(ev);
            }
        }

        fn processEvent(self: *@This(), ev: event.ZEvent) void {
            self.input().applyEvent(ev);
        }

        pub fn input(self: *@This()) *Input {
            return self.world.getResource(Input);
        }

        fn pumpAssets(self: *@This()) !void {
            try self.assets.pump();
        }

        pub fn update(self: *@This()) !void {
            try self.pumpAssets();
            try self.time.advanceFixed(&self.world.world, &self.world.command_buffer, game.fixed_update_schedule);
            try self.tickSchedule(game.update_schedule);
        }

        pub fn updateWithSchedule(self: *@This(), comptime schedule: zcs.Schedule.Spec) !void {
            try self.pumpAssets();
            self.time.discardFixed();
            try self.tickSchedule(schedule);
        }

        pub fn tickSchedule(self: *@This(), comptime schedule: zcs.Schedule.Spec) !void {
            if (self.world.world.getResourceOrNull(zcs.FrameCount)) |frame| {
                frame.value += 1;
            } else {
                try self.world.setResource(zcs.FrameCount, .{ .value = 1 });
            }
            try zcs.Schedule.run(
                &self.world.world,
                &self.world.command_buffer,
                .{ .delta_time = self.time.deltaTime() },
                schedule,
            );
        }

        pub fn render(self: *@This(), target: Renderer.RenderTarget) !void {
            try self.renderer.render(&self.world.world, &self.assets, target);
        }

        pub fn completeFrame(self: *@This(), now: f64) void {
            const elapsed_ms: f32 = @floatCast(@max(0, now - self.frame_cpu_start) * 1000);
            self.renderer.recordCpuFrame(self.time.deltaTime(), elapsed_ms);
        }

        pub fn setDebugStatsEnabled(self: *@This(), enabled: bool) void {
            self.renderer.setDebugStatsEnabled(enabled);
        }

        pub fn debugStats(self: *const @This()) ?DebugStats {
            return self.renderer.debugStats();
        }

        pub fn deltaTime(self: *const @This()) f32 {
            return self.time.deltaTime();
        }

        pub fn deinit(self: *@This()) void {
            self.assets.deinit();
            self.renderer.deinit();
            self.world.deinit();
            self.schemas.deinit();
            self.allocator.destroy(self);
        }
    };
}

const TestCounts = struct { fixed: u32 = 0, frames: u32 = 0, fixed_presses: u32 = 0, frame_presses: u32 = 0 };
fn testFixedSystem(world: *zcs.World, _: *zcs.CommandBuffer) !void {
    const counts = world.getResource(TestCounts);
    counts.fixed += 1;
    counts.fixed_presses += @intFromBool(world.getResource(Input).wasKeyPressed(.W));
    try std.testing.expectEqual(@as(f32, 0.01), world.getResource(zcs.DeltaTime).seconds);
}
fn testFrameSystem(world: *zcs.World, _: *zcs.CommandBuffer) !void {
    const counts = world.getResource(TestCounts);
    counts.frames += 1;
    counts.frame_presses += @intFromBool(world.getResource(Input).wasKeyPressed(.W));
}

test "runtime runs fixed ticks before frame updates and preserves editor schedule overrides" {
    const zimp = @import("zimp");
    const testing = std.testing;
    const definition: Game = .{
        .components = &.{},
        .fixed_update_schedule = .{ .update = &.{testFixedSystem} },
        .update_schedule = .{ .update = &.{testFrameSystem} },
        .simulation = .{ .step_seconds = 0.01 },
    };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, ".fusion/cooked");
    var manifest = try zimp.manifest.model.testManifest(testing.allocator, &.{});
    defer manifest.deinit();
    try zimp.manifest.codec.writeToDir(testing.allocator, testing.io, tmp.dir, ".fusion/assets.zmanifest", &manifest);
    var project: Project = .{ .root_dir = tmp.dir, .manifest = .{ .project_id = .zero } };
    // Assemble the normal CPU-side runtime services without preloading GPU
    // builtins, so this integration test requires no window or GL context.
    var runtime: Runtime(definition) = undefined;
    runtime.allocator = testing.allocator;
    runtime.io = testing.io;
    runtime.project = &project;
    runtime.time = try Time.init(definition.simulation);
    runtime.renderer = try Renderer.init(testing.allocator, .opengl);
    defer runtime.renderer.deinit();
    runtime.schemas = SchemaRegistry.init(testing.allocator);
    defer runtime.schemas.deinit();
    try runtime.world.init(testing.allocator, &runtime.schemas, definition);
    defer runtime.world.deinit();
    runtime.assets = try AssetManager.init(testing.allocator, testing.io, &project, &runtime.renderer.device);
    defer runtime.assets.deinit();
    try runtime.world.setResource(Input, .{});
    try runtime.world.setResource(Time.SimulationClock, .{});
    try runtime.world.setResource(TestCounts, .{});
    runtime.beginFrame(100, true);
    runtime.processEvents(&.{.{ .KeyPressed = .W }});
    try runtime.update();
    runtime.beginFrame(100.005, true);
    try runtime.update();
    runtime.beginFrame(100.020, true);
    try runtime.update();
    const counts = runtime.world.getResource(TestCounts);
    try testing.expectEqual(@as(u32, 2), counts.fixed);
    try testing.expectEqual(@as(u32, 3), counts.frames);
    try testing.expectEqual(@as(u32, 1), counts.fixed_presses);
    try testing.expectEqual(@as(u32, 1), counts.frame_presses);
    try testing.expectEqual(@as(u64, 3), runtime.world.getResource(zcs.FrameCount).value);
    runtime.setSimulationPaused(true);
    runtime.beginFrame(101, true);
    try runtime.update();
    try testing.expectEqual(@as(u32, 2), counts.fixed);
    try runtime.stepSimulation();
    runtime.beginFrame(102, true);
    try runtime.update();
    try testing.expectEqual(@as(u32, 3), counts.fixed);
    runtime.setSimulationPaused(false);
    runtime.beginFrame(103, true);
    try runtime.updateWithSchedule(definition.update_schedule);
    try testing.expectEqual(@as(u32, 3), counts.fixed);
    runtime.beginFrame(103.01, true);
    try runtime.update();
    try testing.expectEqual(@as(u32, 4), counts.fixed);
}
