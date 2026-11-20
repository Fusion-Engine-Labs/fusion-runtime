const std = @import("std");
const zcs = @import("zcs");

const Runtime = @import("runtime.zig").Runtime;
const Framebuffer = @import("../graphics/rhi/framebuffer.zig");
const DebugStats = @import("../graphics/debug_stats.zig");
const Renderer = @import("../graphics/renderer.zig");
const Project = @import("../project/project.zig");
const Window = @import("window.zig");
const Input = @import("input.zig");
const CursorLock = @import("cursor_lock.zig");
const event = @import("event.zig");
const Game = @import("game.zig");
const log = @import("log.zig");

pub fn Application(comptime game: Game) type {
    const GameRuntime = Runtime(game);

    return struct {
        events: std.ArrayList(event.ZEvent) = .empty,
        runtime: *GameRuntime,
        window: *Window,
        /// Whether the window's cursor is currently locked.
        cursor_locked: bool = false,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            params: Window.WindowParams,
            project: *const Project,
        ) !*@This() {
            const app = try allocator.create(@This());
            errdefer allocator.destroy(app);

            const window = try Window.init(allocator, params);
            errdefer window.deinit(allocator);

            const runtime = try GameRuntime.init(allocator, io, project);
            errdefer runtime.deinit();

            app.* = .{
                .window = window,
                .runtime = runtime,
            };
            window.setEventCallback(app, eventCallback);

            return app;
        }

        pub fn start(self: *@This()) !void {
            try self.runtime.start();
        }

        pub fn run(self: *@This()) !void {
            try self.start();

            while (self.window.shouldCloseWindow()) {
                _ = self.beginFrame(self.window.isFocused());
                self.processQueuedEvents();
                try self.update();
                self.updateCursorLock(self.window.isFocused());
                try self.renderScene(null);
                self.present();
            }

            Window.HandleInput();
        }

        pub fn eventCallback(self: *@This(), ev: event.ZEvent) !void {
            self.events.append(self.runtime.allocator, ev) catch |err| {
                log.err("dropping window events because the event queue cannot grow: {}", .{err});
            };
        }

        /// Polls window events and starts the frame. `focused` says whether
        /// the app has the user's attention; an unfocused frame gets no input
        /// edges or mouse movement. Pass `window.isFocused()` unless the
        /// window is embedded in another one (as the editor's native menu
        /// does), where only the host window knows.
        pub fn beginFrame(self: *@This(), focused: bool) []const event.ZEvent {
            self.events.clearRetainingCapacity();
            self.runtime.beginFrame(Window.GetTime(), focused);
            Window.HandleInput();

            return self.events.items;
        }

        pub fn processQueuedEvents(self: *@This()) void {
            self.runtime.processEvents(self.events.items);
        }

        pub fn input(self: *@This()) *Input {
            return self.runtime.input();
        }

        pub fn update(self: *@This()) !void {
            try self.runtime.update();
        }

        /// Applies the game's cursor lock request to the window. Call it every
        /// frame, after `update`: it also recenters a cursor locked by hand
        /// (see `Window.setCursorLocked`). `allow_lock` false refuses or ends
        /// any lock, for when the game should not hold the mouse (unfocused,
        /// paused, not playing).
        pub fn updateCursorLock(self: *@This(), allow_lock: bool) void {
            const cursor = self.runtime.activeSession().world.getResource(CursorLock);
            const locked = cursor.resolve(allow_lock);
            if (locked != self.cursor_locked) {
                self.window.setCursorLocked(locked);
                self.cursor_locked = locked;
                // Locking and unlocking warp the cursor; that is not movement.
                self.input().resetMousePosition();
            }

            // A cursor locked by hand goes back to the middle every frame,
            // after this frame's movement has been used.
            if (self.cursor_locked) {
                if (self.window.recenterCursor()) |position| {
                    self.input().anchorMousePosition(.{ .x = position[0], .y = position[1] });
                }
            }
        }

        /// Ends the lock as if the game had asked, e.g. when the player
        /// presses Escape. Applied by the next `updateCursorLock`.
        pub fn releaseCursorLock(self: *@This()) void {
            self.runtime.activeSession().world.getResource(CursorLock).requested = false;
        }

        pub fn setSimulationPaused(self: *@This(), paused: bool) void {
            self.runtime.setSimulationPaused(paused);
        }

        pub fn stepSimulation(self: *@This()) !void {
            try self.runtime.stepSimulation();
        }

        pub fn setTimeScale(self: *@This(), scale: f64) !void {
            try self.runtime.setTimeScale(scale);
        }

        pub fn updateWithSchedule(self: *@This(), comptime schedule: zcs.Schedule.Spec) !void {
            try self.runtime.updateWithSchedule(schedule);
        }

        pub fn renderScene(self: *@This(), framebuffer: ?*Framebuffer) !void {
            defer if (framebuffer != null) self.restoreSwapchainRenderTarget();

            const target: Renderer.RenderTarget = if (framebuffer) |value|
                .{ .framebuffer = value }
            else blk: {
                break :blk .{ .swapchain = self.defaultViewport() };
            };
            try self.runtime.render(target);
            self.runtime.completeFrame(Window.GetTime());
        }

        pub fn setDebugStatsEnabled(self: *@This(), enabled: bool) void {
            self.runtime.setDebugStatsEnabled(enabled);
        }

        pub fn debugStats(self: *const @This()) ?DebugStats {
            return self.runtime.debugStats();
        }

        pub fn deltaTime(self: *const @This()) f32 {
            return self.runtime.deltaTime();
        }

        pub fn present(self: *@This()) void {
            self.window.swapBuffers();
        }

        fn defaultViewport(self: *const @This()) Renderer.RenderViewport {
            const size = self.window.getFramebufferSize();
            return .{ .width = size.width, .height = size.height };
        }

        fn restoreSwapchainRenderTarget(self: *@This()) void {
            const viewport = self.defaultViewport();
            self.runtime.renderer.device.bindRenderTarget(.{ .swapchain = viewport });
        }

        pub fn deinit(self: *@This()) void {
            const allocator = self.runtime.allocator;
            self.events.deinit(allocator);
            self.runtime.deinit();
            self.window.deinit(allocator);
            allocator.destroy(self);
        }
    };
}
