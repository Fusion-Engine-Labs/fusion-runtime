const builtin = @import("builtin");
const std = @import("std");

const Backend = @import("../graphics/device_factory.zig").Backend;
const graphics_context = @import("../graphics/context.zig");
const event = @import("event.zig");
const log = @import("log.zig");
const c = @import("../c.zig");
const glfw = c.glfw;

const macos = if (builtin.os.tag == .macos) @import("macos_objc") else struct {};

extern fn glfwGetCocoaWindow(window: c.Window) ?*anyopaque;
extern fn glfwGetX11Window(window: c.Window) c_ulong;
extern fn glfwGetWin32Window(window: c.Window) ?*anyopaque;

pub const WindowError = error{
    InitializeFailed,
    ContextLoadFailed,
    MemoryError,
    NativeWindowHandleUnavailable,
};

pub const WindowData = struct {
    width: u32,
    height: u32,
};

pub const WindowSize = struct {
    width: u32,
    height: u32,
};

pub const WindowParams = struct {
    width: ?u32,
    height: ?u32,
    title: []const u8,
    msaa_samples: u32 = 4,
    backend: Backend = .opengl,
};

pub const CursorKind = enum {
    arrow,
    hand,
    text,
    resize_x,
    resize_y,

    /// Adding a kind above is a compile error here until it gets a shape, and
    /// creation/lookup/teardown all follow from this one mapping.
    fn glfwShape(kind: CursorKind) c_int {
        return switch (kind) {
            .arrow => glfw.GLFW_ARROW_CURSOR,
            .hand => glfw.GLFW_HAND_CURSOR,
            .text => glfw.GLFW_IBEAM_CURSOR,
            .resize_x => glfw.GLFW_HRESIZE_CURSOR,
            .resize_y => glfw.GLFW_VRESIZE_CURSOR,
        };
    }
};

const CursorSet = std.EnumArray(CursorKind, ?*glfw.GLFWcursor);

const DefaultWindowBounds = struct {
    x: c_int = 0,
    y: c_int = 0,
    width: u32 = 1280,
    height: u32 = 720,
};

fn getDefaultWindowBounds() DefaultWindowBounds {
    const monitor = glfw.glfwGetPrimaryMonitor() orelse return .{};

    var x: c_int = 0;
    var y: c_int = 0;
    var width: c_int = 0;
    var height: c_int = 0;
    glfw.glfwGetMonitorWorkarea(monitor, &x, &y, &width, &height);
    if (width > 0 and height > 0) {
        return .{
            .x = x,
            .y = y,
            .width = @intCast(width),
            .height = @intCast(height),
        };
    }

    const video = glfw.glfwGetVideoMode(monitor) orelse return .{};
    return .{
        .width = @intCast(video.*.width),
        .height = @intCast(video.*.height),
    };
}

const Window = @This();

allocator: std.mem.Allocator,
window: c.Window,
data: WindowData,
clipboard_buffer: std.ArrayList(u8) = .empty,
event_fn: ?*const fn (*anyopaque, event.ZEvent) anyerror!void = null,
event_ctx: *anyopaque = undefined,
cursors: CursorSet = CursorSet.initFill(null),

pub fn init(allocator: std.mem.Allocator, params: WindowParams) WindowError!*Window {
    if (comptime builtin.os.tag == .linux) {
        glfw.glfwInitHint(glfw.GLFW_PLATFORM, glfw.GLFW_PLATFORM_X11);
    }
    if (glfw.glfwInit() == 0) {
        log.err("failed to initialize GLFW", .{});
        return WindowError.InitializeFailed;
    }
    errdefer glfw.glfwTerminate();

    glfw.glfwDefaultWindowHints();
    if (comptime builtin.os.tag == .linux) {
        glfw.glfwWindowHint(glfw.GLFW_DECORATED, glfw.GLFW_FALSE);
    }
    graphics_context.configure(params.backend, params.msaa_samples);

    const title = allocator.dupeZ(u8, params.title) catch |err| {
        log.err("failed to allocate window title: {}", .{err});
        return WindowError.MemoryError;
    };
    defer allocator.free(title);

    const maximize = params.width == null and params.height == null;
    if (maximize) {
        glfw.glfwWindowHint(glfw.GLFW_MAXIMIZED, glfw.GLFW_TRUE);
    }

    const default_bounds = if (maximize) DefaultWindowBounds{} else getDefaultWindowBounds();
    const width = params.width orelse default_bounds.width;
    const height = params.height orelse default_bounds.height;

    const window = glfw.glfwCreateWindow(@intCast(width), @intCast(height), title, null, null);
    if (window == null) {
        log.err("failed to create GLFW window", .{});
        return WindowError.InitializeFailed;
    }
    errdefer glfw.glfwDestroyWindow(window);

    setBlankWindowIcon(window);
    if (!maximize and (params.width == null or params.height == null)) {
        glfw.glfwSetWindowPos(window, default_bounds.x, default_bounds.y);
    }
    applyPlatformWindowAppearance(window);

    graphics_context.initialize(params.backend, window, params.msaa_samples) catch {
        log.err("failed to load OpenGL functions", .{});
        return WindowError.ContextLoadFailed;
    };

    const win = allocator.create(Window) catch |err| {
        log.err("failed to allocate window state: {}", .{err});
        return WindowError.MemoryError;
    };

    win.* = Window{
        .allocator = allocator,
        .window = window,
        .data = WindowData{
            .width = width,
            .height = height,
        },
    };
    for (std.enums.values(CursorKind)) |kind| {
        win.cursors.set(kind, glfw.glfwCreateStandardCursor(kind.glfwShape()));
    }

    return win;
}

fn setBlankWindowIcon(window: c.Window) void {
    var pixels = [_]u8{ 0, 0, 0, 0 };
    var icon = glfw.GLFWimage{
        .width = 1,
        .height = 1,
        .pixels = &pixels,
    };
    glfw.glfwSetWindowIcon(window, 1, &icon);
}

pub fn setEventCallback(self: *Window, context: anytype, comptime callback: fn (@TypeOf(context), event.ZEvent) anyerror!void) void {
    const Ctx = @TypeOf(context);
    self.event_fn = struct {
        fn dispatch(ctx: *anyopaque, ev: event.ZEvent) anyerror!void {
            try callback(@as(Ctx, @ptrCast(@alignCast(ctx))), ev);
        }
    }.dispatch;
    self.event_ctx = @ptrCast(context);

    glfw.glfwSetWindowUserPointer(self.window, @ptrCast(self));
    _ = glfw.glfwSetMouseButtonCallback(self.window, event.mouseButtonCallback);
    _ = glfw.glfwSetKeyCallback(self.window, event.keyButtonCallback);
    _ = glfw.glfwSetCharCallback(self.window, event.charCallback);
    _ = glfw.glfwSetWindowSizeCallback(self.window, event.windowResizeCallback);
    _ = glfw.glfwSetFramebufferSizeCallback(self.window, event.framebufferSizeCallback);
    _ = glfw.glfwSetWindowContentScaleCallback(self.window, event.contentScaleCallback);
    _ = glfw.glfwSetWindowCloseCallback(self.window, event.windowCloseCallback);
    _ = glfw.glfwSetCursorPosCallback(self.window, event.cursorPosCallback);
    _ = glfw.glfwSetScrollCallback(self.window, event.cursorScrollCallback);
}

pub fn dispatchEvent(self: *Window, ev: event.ZEvent) void {
    const event_fn = self.event_fn orelse return;
    event_fn(self.event_ctx, ev) catch |err| {
        log.err("failed to dispatch window event: {}", .{err});
    };
}

pub fn setSize(self: *Window, width: u32, height: u32) void {
    self.data.width = width;
    self.data.height = height;
}

pub fn getWindowSize(self: *const Window) WindowSize {
    var width: c_int = 0;
    var height: c_int = 0;
    glfw.glfwGetWindowSize(self.window, &width, &height);
    return .{
        .width = @intCast(@max(1, width)),
        .height = @intCast(@max(1, height)),
    };
}

pub fn getFramebufferSize(self: *const Window) WindowSize {
    var width: c_int = 0;
    var height: c_int = 0;
    glfw.glfwGetFramebufferSize(self.window, &width, &height);
    return .{
        .width = @intCast(@max(1, width)),
        .height = @intCast(@max(1, height)),
    };
}

pub fn getContentScale(self: *const Window) struct { x: f32, y: f32 } {
    var x_scale: f32 = 1;
    var y_scale: f32 = 1;
    glfw.glfwGetWindowContentScale(self.window, &x_scale, &y_scale);
    return .{ .x = x_scale, .y = y_scale };
}

pub fn isFocused(self: *const Window) bool {
    return glfw.glfwGetWindowAttrib(self.window, glfw.GLFW_FOCUSED) == glfw.GLFW_TRUE;
}

pub fn setCursor(self: *Window, cursor: CursorKind) void {
    glfw.glfwSetCursor(self.window, self.cursors.get(cursor));
}

pub fn getClipboard(self: *const Window) []const u8 {
    const ptr = glfw.glfwGetClipboardString(self.window) orelse return "";
    return std.mem.span(ptr);
}

pub fn setClipboard(self: *Window, text: []const u8) void {
    if (!std.unicode.utf8ValidateSlice(text)) {
        return;
    }

    self.clipboard_buffer.clearRetainingCapacity();
    self.clipboard_buffer.appendSlice(self.allocator, text) catch return;
    self.clipboard_buffer.append(self.allocator, 0) catch return;
    glfw.glfwSetClipboardString(self.window, @ptrCast(self.clipboard_buffer.items.ptr));
}

pub fn getProcAddress(name: [*:0]const u8) ?*const anyopaque {
    return @ptrCast(glfw.glfwGetProcAddress(name));
}

pub fn GetTime() f64 {
    return glfw.glfwGetTime();
}

pub fn SetVsync(value: bool) void {
    glfw.glfwSwapInterval(@intFromBool(value));
}

pub fn HandleInput() void {
    glfw.glfwPollEvents();
}

pub fn swapBuffers(self: *const Window) void {
    glfw.glfwSwapBuffers(self.window);
}

pub fn shouldCloseWindow(self: *const Window) bool {
    return glfw.glfwWindowShouldClose(self.window) == 0;
}

pub fn requestClose(self: *Window) void {
    glfw.glfwSetWindowShouldClose(self.window, glfw.GLFW_TRUE);
}

pub fn nativeMenuWindowHandle(self: *const Window) WindowError!usize {
    if (builtin.os.tag == .linux) {
        if (glfw.glfwGetPlatform() != glfw.GLFW_PLATFORM_X11) {
            return WindowError.NativeWindowHandleUnavailable;
        }
        const x11_window = glfwGetX11Window(self.window);
        return if (x11_window == 0) WindowError.NativeWindowHandleUnavailable else @intCast(x11_window);
    }
    if (builtin.os.tag == .macos) {
        const cocoa_window = glfwGetCocoaWindow(self.window) orelse return WindowError.NativeWindowHandleUnavailable;
        return @intFromPtr(cocoa_window);
    }
    if (builtin.os.tag == .windows) {
        const win32_window = glfwGetWin32Window(self.window) orelse return WindowError.NativeWindowHandleUnavailable;
        return @intFromPtr(win32_window);
    }
    return WindowError.NativeWindowHandleUnavailable;
}

pub fn deinit(self: *Window, allocator: std.mem.Allocator) void {
    for (self.cursors.values) |cursor| {
        if (cursor) |handle| glfw.glfwDestroyCursor(handle);
    }
    self.clipboard_buffer.deinit(self.allocator);
    glfw.glfwDestroyWindow(self.window);
    glfw.glfwTerminate();
    allocator.destroy(self);
}

fn applyPlatformWindowAppearance(window: c.Window) void {
    if (builtin.os.tag == .macos) {
        applyMacWindowAppearance(window);
    }
}

fn applyMacWindowAppearance(window: c.Window) void {
    const ns_window = glfwGetCocoaWindow(window) orelse return;

    const ns_string_class = macos.objc_getClass("NSString");
    const ns_appearance_class = macos.objc_getClass("NSAppearance");
    const dark_aqua_name = objcMsgSendId(
        ns_string_class,
        macos.sel_registerName("stringWithUTF8String:"),
        "NSAppearanceNameDarkAqua",
    ) orelse return;
    const dark_appearance = objcMsgSendId(
        ns_appearance_class,
        macos.sel_registerName("appearanceNamed:"),
        dark_aqua_name,
    ) orelse return;

    objcMsgSendVoid(
        ns_window,
        macos.sel_registerName("setAppearance:"),
        dark_appearance,
    );
}

fn objcMsgSendId(receiver: anytype, selector: anytype, argument: anytype) ?*anyopaque {
    const Fn = *const fn (@TypeOf(receiver), @TypeOf(selector), @TypeOf(argument)) callconv(.c) ?*anyopaque;
    const msg_send: Fn = @ptrCast(&macos.objc_msgSend);
    return msg_send(receiver, selector, argument);
}

fn objcMsgSendVoid(receiver: anytype, selector: anytype, argument: anytype) void {
    const Fn = *const fn (@TypeOf(receiver), @TypeOf(selector), @TypeOf(argument)) callconv(.c) void;
    const msg_send: Fn = @ptrCast(&macos.objc_msgSend);
    msg_send(receiver, selector, argument);
}
