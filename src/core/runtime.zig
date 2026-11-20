const std = @import("std");
const zcs = @import("zcs");

const AssetManager = @import("../assets/asset_manager.zig").AssetManager;
const DebugStats = @import("../graphics/debug_stats.zig");
const Renderer = @import("../graphics/renderer.zig");
const Project = @import("../project/project.zig");
const GameLibrary = @import("game_module.zig").GameLibrary;
const Session = @import("session.zig");
const Input = @import("input.zig");
const event = @import("event.zig");
const Game = @import("game.zig");
const Time = @import("time.zig");

pub fn Runtime(comptime game: Game) type {
    return struct {
        allocator: std.mem.Allocator,
        frame_cpu_start: f64 = 0,
        project: *const Project,
        /// The open scene as it is authored. Game code never runs here.
        authoring: *Session,
        /// A disposable copy of the scene the game runs in, from `beginPlay`
        /// until `endPlay`.
        play: ?*Session = null,
        /// Supplies game components to both sessions. Owned by the caller.
        library: ?*const GameLibrary = null,
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
                .authoring = undefined,
                .assets = undefined,
                .renderer = undefined,
                .time = try Time.init(game.simulation),
            };

            runtime.renderer = try Renderer.init(allocator, .opengl);
            errdefer runtime.renderer.deinit();

            runtime.assets = try AssetManager.init(allocator, io, project, &runtime.renderer.device);
            errdefer runtime.assets.deinit();

            try runtime.assets.preloadBuiltins();

            runtime.authoring = try Session.create(allocator, game, .{});
            errdefer runtime.authoring.destroy();

            return runtime;
        }

        pub fn start(self: *@This()) !void {
            const default_scene = try self.project.loadDefaultScene(
                self.allocator,
                self.io,
            );

            try self.authoring.loadScene(&self.assets, default_scene);
            self.resetSimulation();
        }

        /// The session being simulated and rendered: the play session while
        /// playing, the authoring session otherwise.
        pub fn activeSession(self: *@This()) *Session {
            return self.play orelse self.authoring;
        }

        pub fn isPlaying(self: *const @This()) bool {
            return self.play != null;
        }

        /// Rebuilds the authoring session so it knows `library`'s components,
        /// keeping the open scene and its unsaved edits. The current session
        /// is replaced only once the new one is complete.
        ///
        /// `library` must stay open until it is replaced here or the runtime
        /// is destroyed. A play session keeps using the library it started
        /// with, so that one must stay open until the session has ended or
        /// been replaced by `beginPlay`.
        pub fn setGameLibrary(self: *@This(), library: ?*const GameLibrary) !void {
            const next = try Session.create(self.allocator, game, .{ .library = library });
            errdefer next.destroy();

            if (self.authoring.world.activeSceneDocument()) |scene| {
                const document = try scene.document.clone(self.allocator);
                try next.loadScene(&self.assets, document);
            }

            self.authoring.destroy();
            self.authoring = next;
            self.library = library;
        }

        /// Starts the game in a fresh world built from a copy of the
        /// authoring scene. A session that is already playing keeps running
        /// until its replacement has started, and survives if that fails.
        pub fn beginPlay(self: *@This()) !void {
            const scene = self.authoring.world.activeSceneDocument() orelse return error.NoActiveScene;

            const next = try Session.create(self.allocator, game, .{ .library = self.library, .simulate = true });
            errdefer next.destroy();

            const document = try scene.document.clone(self.allocator);
            try next.loadScene(&self.assets, document);
            try next.startGame();

            if (self.play) |previous| {
                previous.destroy();
            }
            self.play = next;
            self.resetSimulation();
        }

        /// Destroys the play session and everything the game created in it.
        pub fn endPlay(self: *@This()) void {
            const session = self.play orelse return;
            self.play = null;
            session.destroy();
            self.resetSimulation();
        }

        fn resetSimulation(self: *@This()) void {
            self.time.reset();
            self.activeSession().world.getResource(Time.SimulationClock).* = .{};
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
            self.input().beginFrame();
            self.input().setFocused(focused);
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

        /// Input for the active session.
        pub fn input(self: *@This()) *Input {
            return self.activeSession().world.getResource(Input);
        }

        fn pumpAssets(self: *@This()) !void {
            try self.assets.pump();
        }

        pub fn update(self: *@This()) !void {
            try self.pumpAssets();
            const world = &self.activeSession().world;
            try self.time.advanceFixed(&world.world, &world.command_buffer, game.fixed_update_schedule);
            try self.tickSchedule(game.update_schedule);
        }

        pub fn updateWithSchedule(self: *@This(), comptime schedule: zcs.Schedule.Spec) !void {
            try self.pumpAssets();
            self.time.discardFixed();
            try self.tickSchedule(schedule);
        }

        pub fn tickSchedule(self: *@This(), comptime schedule: zcs.Schedule.Spec) !void {
            const world = &self.activeSession().world;
            if (world.world.getResourceOrNull(zcs.FrameCount)) |frame| {
                frame.value += 1;
            } else {
                try world.setResource(zcs.FrameCount, .{ .value = 1 });
            }
            try zcs.Schedule.run(
                &world.world,
                &world.command_buffer,
                .{ .delta_time = self.time.deltaTime() },
                schedule,
            );
        }

        pub fn render(self: *@This(), target: Renderer.RenderTarget) !void {
            try self.renderer.render(&self.activeSession().world.world, &self.assets, target);
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
            if (self.play) |session| session.destroy();
            self.assets.deinit();
            self.renderer.deinit();
            self.authoring.destroy();
            self.allocator.destroy(self);
        }
    };
}

const testing = std.testing;
const zimp = @import("zimp");
const sdk = @import("fusion_sdk");
const game_module = @import("game_module.zig");
const TransformComponent = @import("../ecs/components.zig").TransformComponent;

/// The CPU-side runtime services, assembled without preloading GPU builtins
/// so these tests need no window or GL context.
fn TestRig(comptime definition: Game) type {
    return struct {
        tmp: testing.TmpDir,
        project: Project,
        runtime: Runtime(definition),

        /// Initialized in place: the asset manager keeps pointers to the
        /// project and the renderer's device.
        fn init(self: *@This()) !void {
            self.tmp = testing.tmpDir(.{});
            errdefer self.tmp.cleanup();
            try self.tmp.dir.createDirPath(testing.io, ".fusion/cooked");
            var manifest = try zimp.manifest.model.testManifest(testing.allocator, &.{});
            defer manifest.deinit();
            try zimp.manifest.codec.writeToDir(testing.allocator, testing.io, self.tmp.dir, ".fusion/assets.zmanifest", &manifest);
            self.project = .{ .root_dir = self.tmp.dir, .manifest = .{ .project_id = .zero } };

            self.runtime = .{
                .allocator = testing.allocator,
                .io = testing.io,
                .project = &self.project,
                .authoring = undefined,
                .assets = undefined,
                .renderer = undefined,
                .time = try Time.init(definition.simulation),
            };
            self.runtime.renderer = try Renderer.init(testing.allocator, .opengl);
            errdefer self.runtime.renderer.deinit();
            self.runtime.assets = try AssetManager.init(testing.allocator, testing.io, &self.project, &self.runtime.renderer.device);
            errdefer self.runtime.assets.deinit();
            self.runtime.authoring = try Session.create(testing.allocator, definition, .{});
        }

        fn deinit(self: *@This()) void {
            if (self.runtime.play) |session| session.destroy();
            self.runtime.assets.deinit();
            self.runtime.renderer.deinit();
            self.runtime.authoring.destroy();
            self.tmp.cleanup();
        }
    };
}

const TestCounts = struct { fixed: u32 = 0, frames: u32 = 0, fixed_presses: u32 = 0, frame_presses: u32 = 0 };
fn testFixedSystem(world: *zcs.World, _: *zcs.CommandBuffer) !void {
    const counts = world.getResource(TestCounts);
    counts.fixed += 1;
    counts.fixed_presses += @intFromBool(world.getResource(Input).wasKeyPressed(.W));
    try testing.expectEqual(@as(f32, 0.01), world.getResource(zcs.DeltaTime).seconds);
}
fn testFrameSystem(world: *zcs.World, _: *zcs.CommandBuffer) !void {
    const counts = world.getResource(TestCounts);
    counts.frames += 1;
    counts.frame_presses += @intFromBool(world.getResource(Input).wasKeyPressed(.W));
}

test "runtime runs fixed ticks before frame updates and preserves editor schedule overrides" {
    const definition: Game = .{
        .components = &.{},
        .fixed_update_schedule = .{ .update = &.{testFixedSystem} },
        .update_schedule = .{ .update = &.{testFrameSystem} },
        .simulation = .{ .step_seconds = 0.01 },
    };
    var rig: TestRig(definition) = undefined;
    try rig.init();
    defer rig.deinit();
    const runtime = &rig.runtime;

    try runtime.authoring.world.setResource(TestCounts, .{});
    runtime.beginFrame(100, true);
    runtime.processEvents(&.{.{ .KeyPressed = .W }});
    try runtime.update();
    runtime.beginFrame(100.005, true);
    try runtime.update();
    runtime.beginFrame(100.020, true);
    try runtime.update();
    const counts = runtime.authoring.world.getResource(TestCounts);
    try testing.expectEqual(@as(u32, 2), counts.fixed);
    try testing.expectEqual(@as(u32, 3), counts.frames);
    try testing.expectEqual(@as(u32, 1), counts.fixed_presses);
    try testing.expectEqual(@as(u32, 1), counts.frame_presses);
    try testing.expectEqual(@as(u64, 3), runtime.authoring.world.getResource(zcs.FrameCount).value);
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

const TestMarker = struct {
    value: u32 = 0,

    pub const schema_meta = sdk.scene_schema.SchemaMeta{
        .id = "c1d2e3f4-0a1b-4c2d-8e3f-4a5b6c7d8e90",
        .name = "test.runtime.marker",
        .version = 1,
        .fields = &.{.{ .name = "value", .number = 1 }},
    };
};

const TestGame = struct {
    var starts: u32 = 0;
    var stops: u32 = 0;
    var fail_start = false;

    fn onStart(world: sdk.World) !void {
        if (fail_start) return error.TestStartFailed;
        starts += 1;
        _ = try world.spawn(.{ TransformComponent{}, TestMarker{} });
    }

    fn onUpdate(world: sdk.World, _: *const sdk.Frame) !void {
        _ = try world.spawn(.{ TransformComponent{}, TestMarker{} });
    }

    fn onStop(_: sdk.World) !void {
        stops += 1;
    }

    const module = sdk.game(.{
        .components = &.{TestMarker},
        .start = onStart,
        .update = onUpdate,
        .stop = onStop,
    });

    /// Stands in for an opened library; never `deinit` it.
    const library: GameLibrary = .{ .handle = undefined, .game = &module };
};

const play_definition: Game = .{
    .components = &.{},
    .fixed_update_schedule = .{ .update = &.{game_module.fixedUpdate} },
    .simulation = .{ .step_seconds = 0.01 },
};

const test_scene_id = zimp.SceneId.parseComptime("0c9d4a55-6b1e-4f3a-9d27-5e8f1a2b3c4d");
const test_entity_id = zimp.SceneEntityId.parseComptime("7e1f2a3b-4c5d-4e6f-8a7b-9c0d1e2f3a4b");
const transform_type_id = zimp.ComponentTypeId.parseComptime(TransformComponent.schema_meta.id);
const marker_type_id = zimp.ComponentTypeId.parseComptime(TestMarker.schema_meta.id);

/// A scene with one entity carrying a transform and the game's marker.
fn testScene() !zimp.scene.SceneDocument {
    var document = try zimp.scene.SceneDocument.init(testing.allocator, test_scene_id, .zero, "Play Test");
    errdefer document.deinit();
    const arena = document.arena.allocator();

    const components = try arena.alloc(zimp.scene.SceneComponent, 2);
    components[0] = .{ .type_id = transform_type_id, .fields = &.{} };
    components[1] = .{ .type_id = marker_type_id, .fields = &.{} };
    document.entities = try arena.alloc(zimp.scene.SceneEntity, 1);
    document.entities[0] = .{ .id = test_entity_id, .name = "entity", .components = components, .prefab = .{} };
    return document;
}

fn countTransforms(session: *Session) usize {
    var count: usize = 0;
    var query = session.world.world.query(.{ .read = &.{TransformComponent} });
    while (query.each()) |_| count += 1;
    return count;
}

test "play runs the game in a disposable copy of the authoring scene" {
    var rig: TestRig(play_definition) = undefined;
    try rig.init();
    defer rig.deinit();
    const runtime = &rig.runtime;
    TestGame.starts = 0;
    TestGame.stops = 0;
    TestGame.fail_start = false;

    try testing.expectError(error.NoActiveScene, runtime.beginPlay());

    // Without the library the marker has no schema, so the world omits it.
    try runtime.authoring.loadScene(&runtime.assets, try testScene());
    try testing.expect(runtime.authoring.schemas.get(marker_type_id) == null);
    try testing.expectEqual(@as(usize, 1), countTransforms(runtime.authoring));

    // Installing the library rebuilds the authoring world around the same scene.
    try runtime.setGameLibrary(&TestGame.library);
    try testing.expect(runtime.authoring.schemas.get(marker_type_id) != null);
    try testing.expectEqual(@as(usize, 1), countTransforms(runtime.authoring));
    try testing.expectEqual(@as(usize, 2), runtime.authoring.world.activeSceneDocument().?.document.entities[0].components.len);
    try testing.expect(!runtime.isPlaying());
    try testing.expectEqual(runtime.authoring, runtime.activeSession());

    try runtime.beginPlay();
    try testing.expect(runtime.isPlaying());
    try testing.expectEqual(runtime.play.?, runtime.activeSession());
    try testing.expectEqual(@as(u32, 1), TestGame.starts);
    try testing.expectEqual(@as(usize, 2), countTransforms(runtime.play.?));

    // Reinstalling a library mid-play rebuilds only the authoring world.
    const playing = runtime.play.?;
    try runtime.setGameLibrary(&TestGame.library);
    try testing.expectEqual(playing, runtime.play.?);
    try testing.expectEqual(@as(usize, 1), countTransforms(runtime.authoring));

    runtime.beginFrame(100, true);
    try runtime.update();
    runtime.beginFrame(100.02, true);
    try runtime.update();
    try testing.expectEqual(@as(usize, 4), countTransforms(runtime.play.?));
    // Nothing the game did reached the authoring world.
    try testing.expectEqual(@as(usize, 1), countTransforms(runtime.authoring));
    try testing.expectEqual(@as(u64, 2), runtime.play.?.world.getResource(Time.SimulationClock).tick);

    // A failed restart leaves the running session alone.
    const running = runtime.play.?;
    TestGame.fail_start = true;
    try testing.expectError(error.GameStartFailed, runtime.beginPlay());
    try testing.expectEqual(running, runtime.play.?);
    try testing.expectEqual(@as(u32, 0), TestGame.stops);
    TestGame.fail_start = false;

    // A successful restart replaces it with a fresh world.
    try runtime.beginPlay();
    try testing.expectEqual(@as(u32, 1), TestGame.stops);
    try testing.expectEqual(@as(usize, 2), countTransforms(runtime.play.?));
    try testing.expectEqual(@as(u64, 0), runtime.play.?.world.getResource(Time.SimulationClock).tick);

    runtime.endPlay();
    try testing.expect(!runtime.isPlaying());
    try testing.expectEqual(@as(u32, 2), TestGame.stops);
    try testing.expectEqual(@as(usize, 1), countTransforms(runtime.authoring));
    runtime.endPlay();
    try testing.expectEqual(@as(u32, 2), TestGame.stops);
}
