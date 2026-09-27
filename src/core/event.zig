const std = @import("std");

const Window = @import("window.zig");
const log = @import("log.zig");
const c = @import("../c.zig");
const glfw = c.glfw;

pub const MouseButton = enum(u8) {
    Left = 0,
    Right = 1,
    Middle = 2,
    Button3 = 3,
    Button4 = 4,
    Button5 = 5,
    Button6 = 6,
    Button7 = 7,
};

pub const Key = @import("fusion_sdk").Key;

pub const ZEvent = union(enum) {
    WindowClose,
    WindowResize: struct { width: u32, height: u32 },
    FramebufferResize: struct { width: u32, height: u32 },
    ContentScaleChange: struct { x: f32, y: f32 },
    KeyPressed: Key,
    KeyReleased: Key,
    KeyRepeated: Key,
    CharInput: u32, // Unicode codepoint for text input
    MouseScroll: struct { x: f32, y: f32 },
    MouseMove: struct { x: f32, y: f32 },
    MousePressed: MouseButton,
    MouseReleased: MouseButton,
};

inline fn getWindowFromGLFW(window: c.Window) ?*Window {
    const ptr = glfw.glfwGetWindowUserPointer(window) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

pub fn mouseButtonCallback(window: c.Window, btn: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = mods;

    const isPress = action == glfw.GLFW_PRESS;
    const isRelease = action == glfw.GLFW_RELEASE;
    if (!isPress and !isRelease) {
        return;
    }

    if (btn < 0 or btn > 7) {
        return;
    }

    const win = getWindowFromGLFW(window) orelse return;

    const button: MouseButton = @enumFromInt(@as(u8, @intCast(btn)));
    const ev: ZEvent = if (isPress)
        ZEvent{ .MousePressed = button }
    else
        ZEvent{ .MouseReleased = button };

    win.dispatchEvent(ev);
}

pub fn keyButtonCallback(window: c.Window, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = mods;
    _ = scancode;

    const win = getWindowFromGLFW(window) orelse return;
    const mappedKey = Key.fromGLFW(key);
    if (mappedKey == .Unknown) {
        log.debug("ignoring unknown GLFW key code: {}", .{key});
        return;
    }

    const ev: ZEvent = switch (action) {
        glfw.GLFW_PRESS => .{ .KeyPressed = mappedKey },
        glfw.GLFW_REPEAT => .{ .KeyRepeated = mappedKey },
        glfw.GLFW_RELEASE => .{ .KeyReleased = mappedKey },
        else => return,
    };

    win.dispatchEvent(ev);
}

pub fn windowResizeCallback(window: c.Window, width: c_int, height: c_int) callconv(.c) void {
    if (width < 0 or height < 0) return;
    const win = getWindowFromGLFW(window) orelse return;
    win.setSize(@intCast(width), @intCast(height));

    const ev = ZEvent{ .WindowResize = .{
        .height = @intCast(height),
        .width = @intCast(width),
    } };
    win.dispatchEvent(ev);
}

pub fn framebufferSizeCallback(window: c.Window, width: c_int, height: c_int) callconv(.c) void {
    if (width < 0 or height < 0) return;
    const win = getWindowFromGLFW(window) orelse return;

    const ev = ZEvent{ .FramebufferResize = .{
        .width = @intCast(width),
        .height = @intCast(height),
    } };
    win.dispatchEvent(ev);
}

pub fn contentScaleCallback(window: c.Window, xscale: f32, yscale: f32) callconv(.c) void {
    const win = getWindowFromGLFW(window) orelse return;

    const ev = ZEvent{ .ContentScaleChange = .{ .x = xscale, .y = yscale } };
    win.dispatchEvent(ev);
}

pub fn windowCloseCallback(window: c.Window) callconv(.c) void {
    const win = getWindowFromGLFW(window) orelse return;

    const ev: ZEvent = .WindowClose;
    win.dispatchEvent(ev);
}

pub fn cursorPosCallback(window: c.Window, x: f64, y: f64) callconv(.c) void {
    const win = getWindowFromGLFW(window) orelse return;

    const ev = ZEvent{ .MouseMove = .{ .x = @floatCast(x), .y = @floatCast(y) } };
    win.dispatchEvent(ev);
}

pub fn cursorScrollCallback(window: c.Window, x: f64, y: f64) callconv(.c) void {
    const win = getWindowFromGLFW(window) orelse return;

    const ev = ZEvent{ .MouseScroll = .{ .x = @floatCast(x), .y = @floatCast(y) } };
    win.dispatchEvent(ev);
}

pub fn charCallback(window: c.Window, codepoint: c_uint) callconv(.c) void {
    const win = getWindowFromGLFW(window) orelse return;

    const ev = ZEvent{ .CharInput = @intCast(codepoint) };
    win.dispatchEvent(ev);
}

test "Key.fromGLFW maps known and unknown key codes" {
    try std.testing.expectEqual(Key.A, Key.fromGLFW(glfw.GLFW_KEY_A));
    try std.testing.expectEqual(Key.F12, Key.fromGLFW(glfw.GLFW_KEY_F12));
    try std.testing.expectEqual(Key.Unknown, Key.fromGLFW(-1));
    try std.testing.expectEqual(Key.Unknown, Key.fromGLFW(glfw.GLFW_KEY_UNKNOWN));
    try std.testing.expectEqual(Key.Unknown, Key.fromGLFW(31));
}

test "Key values are the GLFW key codes" {
    try std.testing.expectEqual(@intFromEnum(Key.Space), glfw.GLFW_KEY_SPACE);
    try std.testing.expectEqual(@intFromEnum(Key.Apostrophe), glfw.GLFW_KEY_APOSTROPHE);
    try std.testing.expectEqual(@intFromEnum(Key.Num0), glfw.GLFW_KEY_0);
    try std.testing.expectEqual(@intFromEnum(Key.A), glfw.GLFW_KEY_A);
    try std.testing.expectEqual(@intFromEnum(Key.GraveAccent), glfw.GLFW_KEY_GRAVE_ACCENT);
    try std.testing.expectEqual(@intFromEnum(Key.Escape), glfw.GLFW_KEY_ESCAPE);
    try std.testing.expectEqual(@intFromEnum(Key.F1), glfw.GLFW_KEY_F1);
    try std.testing.expectEqual(@intFromEnum(Key.F25), glfw.GLFW_KEY_F25);
    try std.testing.expectEqual(@intFromEnum(Key.Kp0), glfw.GLFW_KEY_KP_0);
    try std.testing.expectEqual(@intFromEnum(Key.KpEqual), glfw.GLFW_KEY_KP_EQUAL);
    try std.testing.expectEqual(@intFromEnum(Key.LeftShift), glfw.GLFW_KEY_LEFT_SHIFT);
    try std.testing.expectEqual(@intFromEnum(Key.Menu), glfw.GLFW_KEY_MENU);

    inline for (@typeInfo(Key).@"enum".fields) |f| {
        const key: Key = @enumFromInt(f.value);
        try std.testing.expectEqual(key, Key.fromGLFW(f.value));
    }
}
