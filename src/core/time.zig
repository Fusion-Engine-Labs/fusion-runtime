const std = @import("std");
const zcs = @import("zcs");
const Input = @import("input.zig");

const Time = @This();

pub const Config = struct {
    step_seconds: f64 = 1.0 / 60.0,
    max_frame_seconds: f64 = 0.25,
    max_steps_per_frame: u32 = 8,

    pub fn validate(self: Config) !void {
        if (!std.math.isFinite(self.step_seconds) or self.step_seconds < std.math.floatMin(f32) or
            self.step_seconds > std.math.floatMax(f32) or !std.math.isFinite(self.max_frame_seconds) or
            self.max_frame_seconds <= 0 or self.max_frame_seconds > std.math.floatMax(f32) or
            self.max_steps_per_frame == 0)
        {
            return error.InvalidSimulationConfig;
        }
    }
};

pub const SimulationClock = struct {
    tick: u64 = 0,
    seconds: f64 = 0,
    delta_time: f32 = 0,
};

config: Config,
frame_seconds: f64 = 0,
last_frame: ?f64 = null,
simulation: SimulationClock = .{},
accumulator: f64 = 0,
paused: bool = false,
time_scale: f64 = 1,
step_requested: bool = false,
steps_last_frame: u32 = 0,
dropped_seconds: f64 = 0,
pending_input: Input = .{},

pub fn init(config: Config) !Time {
    try config.validate();
    return .{ .config = config };
}

pub fn beginFrame(self: *Time, now: f64) void {
    self.frame_seconds = 0;
    if (!std.math.isFinite(now)) {
        return;
    }

    if (self.last_frame) |last| {
        if (now < last) {
            return;
        }

        const delta = now - last;
        if (!std.math.isFinite(delta)) {
            return;
        }
        self.frame_seconds = delta;
    }
    self.last_frame = now;
}

pub fn deltaTime(self: *const Time) f32 {
    return @floatCast(@min(self.frame_seconds, std.math.floatMax(f32)));
}

pub fn setPaused(self: *Time, paused: bool) void {
    if (self.paused == paused) {
        return;
    }
    self.paused = paused;
    self.discardFixed();
}

pub fn setTimeScale(self: *Time, scale: f64) !void {
    if (!std.math.isFinite(scale) or scale < 0 or scale > 100) {
        return error.InvalidTimeScale;
    }
    if (self.time_scale == scale) return;
    self.time_scale = scale;
    self.discardFixed();
}

pub fn requestSingleStep(self: *Time) !void {
    if (!self.paused) {
        return error.SimulationNotPaused;
    }
    self.step_requested = true;
}

pub fn discardFixed(self: *Time) void {
    self.accumulator = 0;
    self.step_requested = false;
    self.steps_last_frame = 0;
    self.pending_input.clear();
}

pub fn reset(self: *Time) void {
    self.discardFixed();
    self.simulation = .{};
    self.frame_seconds = 0;
    self.last_frame = null;
    self.dropped_seconds = 0;
}

pub fn advanceFixed(self: *Time, world: *zcs.World, commands: *zcs.CommandBuffer, comptime schedule: zcs.Schedule.Spec) !void {
    if (schedule.render.len != 0) {
        @compileError("fixed_update_schedule must not contain render systems");
    }

    self.steps_last_frame = 0;
    const single_step = self.paused and self.step_requested;
    self.step_requested = false;
    if ((self.paused or self.time_scale == 0) and !single_step) {
        self.pending_input.clear();
        return;
    }

    const frame_input = world.getResource(Input).*;
    self.pending_input.accumulateFrame(&frame_input);
    errdefer self.discardFixed();

    if (!single_step and self.frame_seconds > 0) {
        const accepted = @min(self.frame_seconds, self.config.max_frame_seconds);
        self.dropped_seconds += (self.frame_seconds - accepted) * self.time_scale;
        self.accumulator += accepted * self.time_scale;
    }
    const step = self.config.step_seconds;
    const max_steps = if (single_step) 1 else self.config.max_steps_per_frame;
    while (self.steps_last_frame < max_steps and (single_step or self.accumulator + step * 1e-9 >= step)) {
        try world.setResource(SimulationClock, .{
            .tick = self.simulation.tick + 1,
            .seconds = self.simulation.seconds + step,
            .delta_time = @floatCast(step),
        });

        var tick_input = self.pending_input;
        var input_scope: zcs.Resources.Scope = undefined;
        world.resources.pushScope(Input, &tick_input, &input_scope);
        defer input_scope.deinit();

        self.pending_input.beginFrame();
        if (!single_step) {
            self.accumulator = @max(0, self.accumulator - step);
        }

        self.simulation = world.getResource(SimulationClock).*;
        self.steps_last_frame += 1;
        try zcs.Schedule.run(world, commands, .{ .delta_time = @floatCast(step) }, schedule);
    }

    if (self.accumulator >= step) {
        const remainder = @mod(self.accumulator, step);
        self.dropped_seconds += self.accumulator - remainder;
        self.accumulator = remainder;
    }
}

const testing = std.testing;
const Transform = @import("../ecs/components.zig").TransformComponent;
const Observed = struct {
    calls: u32 = 0,
    presses: u32 = 0,
    releases: u32 = 0,
    held: u32 = 0,
    mouse_x: f32 = 0,
};
fn observe(world: *zcs.World, _: *zcs.CommandBuffer) !void {
    const input = world.getResource(Input);
    const observed = world.getResource(Observed);
    observed.calls += 1;
    observed.presses += @intFromBool(input.wasKeyPressed(.W));
    observed.releases += @intFromBool(input.wasKeyReleased(.W));
    observed.held += @intFromBool(input.isKeyDown(.W));
    observed.mouse_x += input.mouse_delta.x;
    try testing.expectEqual(world.getResource(SimulationClock).delta_time, world.getResource(zcs.DeltaTime).seconds);
}
fn testWorld() !zcs.World {
    var world = zcs.World.init(testing.allocator);
    errdefer world.deinit();
    _ = try world.registerType(Transform, .{ .schema_hash = 0 });
    try world.setResource(Input, .{});
    try world.setResource(Observed, .{});
    return world;
}
const test_schedule: zcs.Schedule.Spec = .{ .update = &.{observe} };

fn advanceTestFrame(time: *Time, world: *zcs.World, commands: *zcs.CommandBuffer, seconds: f64, comptime schedule: zcs.Schedule.Spec) !void {
    if (time.last_frame == null) time.beginFrame(0);
    time.beginFrame(time.last_frame.? + seconds);
    try time.advanceFixed(world, commands, schedule);
}

test "fixed tick count is independent of render rate and has its own clock" {
    for ([_]u32{ 30, 60, 144 }) |fps| {
        var world = try testWorld();
        defer world.deinit();
        var commands = zcs.CommandBuffer.init(&world);
        defer commands.deinit();
        var time = try Time.init(.{});
        try world.setResource(zcs.FrameCount, .{ .value = 7 });
        for (0..fps) |_| try advanceTestFrame(&time, &world, &commands, 1.0 / @as(f64, @floatFromInt(fps)), test_schedule);
        try testing.expectEqual(@as(u64, 60), time.simulation.tick);
        try testing.expectApproxEqAbs(@as(f64, 1), time.simulation.seconds, 1e-9);
        try testing.expectEqual(@as(u64, 7), world.getResource(zcs.FrameCount).value);
    }
}

test "fixed input retains edges across empty frames and consumes them once during catch-up" {
    var world = try testWorld();
    defer world.deinit();
    var commands = zcs.CommandBuffer.init(&world);
    defer commands.deinit();
    var time = try Time.init(.{ .step_seconds = 0.01 });
    const input = world.getResource(Input);
    input.applyEvent(.{ .KeyPressed = .W });
    input.mouse_delta.x = 2;
    try advanceTestFrame(&time, &world, &commands, 0.004, test_schedule);
    try testing.expectEqual(@as(u64, 0), time.simulation.tick);
    input.beginFrame();
    input.applyEvent(.{ .KeyReleased = .W });
    input.mouse_delta.x = 3;
    try advanceTestFrame(&time, &world, &commands, 0.026, test_schedule);
    const observed = world.getResource(Observed);
    try testing.expectEqual(@as(u32, 3), observed.calls);
    try testing.expectEqual(@as(u32, 1), observed.presses);
    try testing.expectEqual(@as(u32, 1), observed.releases);
    try testing.expectEqual(@as(u32, 0), observed.held);
    try testing.expectEqual(@as(f32, 5), observed.mouse_x);
    try testing.expect(input.wasKeyReleased(.W));
    try testing.expectEqual(@as(f32, 3), input.mouse_delta.x);
}

test "simulation caps stalls, pauses without debt, steps once, and scales time" {
    var world = try testWorld();
    defer world.deinit();
    var commands = zcs.CommandBuffer.init(&world);
    defer commands.deinit();
    var time = try Time.init(.{ .step_seconds = 0.01, .max_steps_per_frame = 3 });
    try advanceTestFrame(&time, &world, &commands, 5, test_schedule);
    try testing.expectEqual(@as(u32, 3), time.steps_last_frame);
    try testing.expect(time.dropped_seconds > 4.9);
    try testing.expect(time.accumulator < 0.01);
    time.setPaused(true);
    try advanceTestFrame(&time, &world, &commands, 5, test_schedule);
    try testing.expectEqual(@as(u64, 3), time.simulation.tick);
    try testing.expectEqual(@as(f32, 5), time.deltaTime());
    try time.requestSingleStep();
    try advanceTestFrame(&time, &world, &commands, 5, test_schedule);
    try testing.expectEqual(@as(u64, 4), time.simulation.tick);
    try advanceTestFrame(&time, &world, &commands, 5, test_schedule);
    try testing.expectEqual(@as(u64, 4), time.simulation.tick);
    time.setPaused(false);
    try time.setTimeScale(0.5);
    try advanceTestFrame(&time, &world, &commands, 0.02, test_schedule);
    try testing.expectEqual(@as(u64, 5), time.simulation.tick);
    try testing.expectApproxEqAbs(@as(f64, 0.02), time.frame_seconds, 1e-9);
    try time.setTimeScale(0);
    try advanceTestFrame(&time, &world, &commands, 5, test_schedule);
    try testing.expectEqual(@as(u64, 5), time.simulation.tick);
    try testing.expectError(error.SimulationNotPaused, time.requestSingleStep());
    try testing.expectError(error.InvalidTimeScale, time.setTimeScale(std.math.nan(f64)));
}

test "invalid simulation configuration is rejected" {
    try testing.expectError(error.InvalidSimulationConfig, Time.init(.{ .step_seconds = 0 }));
    try testing.expectError(error.InvalidSimulationConfig, Time.init(.{ .step_seconds = std.math.nan(f64) }));
    try testing.expectError(error.InvalidSimulationConfig, Time.init(.{ .max_steps_per_frame = 0 }));
}

fn failTick(world: *zcs.World, commands: *zcs.CommandBuffer) !void {
    _ = try commands.spawnWith(.{Transform{}});
    world.removeResource(Input);
    world.removeResource(zcs.DeltaTime);
    return error.TestSystemFailure;
}

test "fixed-system failure restores frame input and delta and drops pending work" {
    var world = try testWorld();
    defer world.deinit();
    var commands = zcs.CommandBuffer.init(&world);
    defer commands.deinit();
    var time = try Time.init(.{});
    world.getResource(Input).applyEvent(.{ .KeyPressed = .W });
    try world.setResource(zcs.DeltaTime, .{ .seconds = 0.123 });
    try testing.expectError(error.TestSystemFailure, advanceTestFrame(&time, &world, &commands, 0.1, .{ .update = &.{failTick} }));
    try testing.expect(world.getResource(Input).wasKeyPressed(.W));
    try testing.expectEqual(@as(f32, 0.123), world.getResource(zcs.DeltaTime).seconds);
    try testing.expectEqual(@as(f64, 0), time.accumulator);
    try testing.expectEqual(@as(u32, 0), world.entity_pool.alive_count);
    try testing.expectEqual(@as(usize, 0), commands.commands.items.len);
    try advanceTestFrame(&time, &world, &commands, time.config.step_seconds, test_schedule);
    try testing.expectEqual(@as(u32, 0), world.entity_pool.alive_count);
}

test "focus loss and editor overrides discard input awaiting a fixed tick" {
    var world = try testWorld();
    defer world.deinit();
    var commands = zcs.CommandBuffer.init(&world);
    defer commands.deinit();
    var time = try Time.init(.{ .step_seconds = 0.01 });
    const input = world.getResource(Input);
    input.applyEvent(.{ .KeyPressed = .W });
    try advanceTestFrame(&time, &world, &commands, 0.004, test_schedule);
    input.beginFrame();
    input.setFocused(false);
    try advanceTestFrame(&time, &world, &commands, 0.006, test_schedule);
    try testing.expectEqual(@as(u32, 0), world.getResource(Observed).presses);
    try testing.expectEqual(@as(u32, 0), world.getResource(Observed).held);
    input.setFocused(true);
    input.applyEvent(.{ .KeyPressed = .W });
    try advanceTestFrame(&time, &world, &commands, 0.004, test_schedule);
    time.discardFixed();
    input.clear();
    try advanceTestFrame(&time, &world, &commands, 0.006, test_schedule);
    try testing.expectEqual(@as(u64, 1), time.simulation.tick);
    try advanceTestFrame(&time, &world, &commands, 0.004, test_schedule);
    try testing.expectEqual(@as(u32, 0), world.getResource(Observed).presses);
}

test "frame clock starts at an arbitrary epoch and preserves long-running precision" {
    var time = try Time.init(.{});
    time.beginFrame(1_000_000);
    try std.testing.expectEqual(@as(f32, 0), time.deltaTime());
    time.beginFrame(1_000_000.016);
    try std.testing.expectApproxEqAbs(@as(f64, 0.016), time.frame_seconds, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 0.016), time.deltaTime(), 1e-7);
}

test "frame clock ignores backwards and non-finite samples" {
    var time = try Time.init(.{});
    time.beginFrame(10);
    for ([_]f64{ 9, std.math.nan(f64), std.math.inf(f64), 10 }) |now| {
        time.beginFrame(now);
        try std.testing.expectEqual(@as(f32, 0), time.deltaTime());
    }
    time.beginFrame(10.5);
    try std.testing.expectEqual(@as(f64, 0.5), time.frame_seconds);
}

test "reset clears both clocks and pending work while preserving playback settings" {
    var world = try testWorld();
    defer world.deinit();
    var commands = zcs.CommandBuffer.init(&world);
    defer commands.deinit();
    var time = try Time.init(.{ .step_seconds = 0.01 });
    try advanceTestFrame(&time, &world, &commands, 0.025, test_schedule);
    try testing.expectEqual(@as(u64, 2), time.simulation.tick);
    time.setPaused(true);
    try time.setTimeScale(0.5);
    try time.requestSingleStep();
    time.reset();
    try testing.expect(time.paused);
    try testing.expectEqual(@as(f64, 0.5), time.time_scale);
    try testing.expectEqual(@as(u64, 0), time.simulation.tick);
    try testing.expectEqual(@as(f64, 0), time.simulation.seconds);
    try testing.expectEqual(@as(f64, 0), time.accumulator);
    try testing.expectEqual(@as(f64, 0), time.frame_seconds);
    try testing.expect(time.last_frame == null);
    time.beginFrame(100);
    try time.advanceFixed(&world, &commands, test_schedule);
    try testing.expectEqual(@as(u64, 0), time.simulation.tick);
    try testing.expectEqual(@as(f32, 0), time.deltaTime());
    time.setPaused(false);
    time.beginFrame(100.02);
    try time.advanceFixed(&world, &commands, test_schedule);
    try testing.expectEqual(@as(u64, 1), time.simulation.tick);
}
