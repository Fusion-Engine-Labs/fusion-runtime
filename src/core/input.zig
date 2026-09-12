const std = @import("std");

const event = @import("event.zig");

const Input = @This();

pub const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const key_count = @intFromEnum(event.Key.Menu) + 1;
pub const mouse_button_count = @intFromEnum(event.MouseButton.Button7) + 1;
pub const text_capacity = 64;

key_down: [key_count]bool = [_]bool{false} ** key_count,
key_pressed: [key_count]bool = [_]bool{false} ** key_count,
key_released: [key_count]bool = [_]bool{false} ** key_count,
mouse_button_down: [mouse_button_count]bool = [_]bool{false} ** mouse_button_count,
mouse_button_pressed: [mouse_button_count]bool = [_]bool{false} ** mouse_button_count,
mouse_button_released: [mouse_button_count]bool = [_]bool{false} ** mouse_button_count,
mouse_pos: Position = .{},
mouse_delta: Position = .{},
mouse_scroll: Position = .{},
text_codepoints: [text_capacity]u32 = [_]u32{0} ** text_capacity,
text_len: usize = 0,
focused: bool = true,
has_mouse_position: bool = false,

pub fn beginFrame(self: *Input) void {
    @memset(&self.key_pressed, false);
    @memset(&self.key_released, false);
    @memset(&self.mouse_button_pressed, false);
    @memset(&self.mouse_button_released, false);

    self.mouse_delta = .{};
    self.mouse_scroll = .{};
    self.text_len = 0;
}

pub fn accumulateFrame(self: *Input, frame: *const Input) void {
    if (!frame.focused) {
        self.* = frame.*;
        self.beginFrame();
        return;
    }
    self.key_down = frame.key_down;
    self.mouse_button_down = frame.mouse_button_down;
    for (&self.key_pressed, frame.key_pressed) |*pending, edge| pending.* = pending.* or edge;
    for (&self.key_released, frame.key_released) |*pending, edge| pending.* = pending.* or edge;
    for (&self.mouse_button_pressed, frame.mouse_button_pressed) |*pending, edge| pending.* = pending.* or edge;
    for (&self.mouse_button_released, frame.mouse_button_released) |*pending, edge| pending.* = pending.* or edge;
    self.mouse_pos = frame.mouse_pos;
    self.has_mouse_position = frame.has_mouse_position;
    self.focused = frame.focused;
    self.mouse_delta.x += frame.mouse_delta.x;
    self.mouse_delta.y += frame.mouse_delta.y;
    self.mouse_scroll.x += frame.mouse_scroll.x;
    self.mouse_scroll.y += frame.mouse_scroll.y;
    for (frame.textInput()) |codepoint| self.appendText(codepoint);
}

pub fn clear(self: *Input) void {
    @memset(&self.key_down, false);
    @memset(&self.key_pressed, false);
    @memset(&self.key_released, false);

    @memset(&self.mouse_button_down, false);
    @memset(&self.mouse_button_pressed, false);
    @memset(&self.mouse_button_released, false);

    self.mouse_delta = .{};
    self.mouse_scroll = .{};
    self.text_len = 0;
    self.has_mouse_position = false;
}

pub fn applyEvent(self: *Input, ev: event.ZEvent) void {
    switch (ev) {
        .KeyPressed => |key| self.setKeyDown(key),
        .KeyReleased => |key| self.setKeyUp(key),
        .KeyRepeated => {},
        .MousePressed => |button| self.setMouseButtonDown(button),
        .MouseReleased => |button| self.setMouseButtonUp(button),
        .MouseMove => |position| self.setMousePosition(.{ .x = position.x, .y = position.y }),
        .MouseScroll => |scroll| {
            self.mouse_scroll.x += scroll.x;
            self.mouse_scroll.y += scroll.y;
        },
        .CharInput => |codepoint| self.appendText(codepoint),
        else => {},
    }
}

pub fn isKeyDown(self: *const Input, key: event.Key) bool {
    return self.key_down[@intFromEnum(key)];
}

pub fn wasKeyPressed(self: *const Input, key: event.Key) bool {
    return self.key_pressed[@intFromEnum(key)];
}

pub fn wasKeyReleased(self: *const Input, key: event.Key) bool {
    return self.key_released[@intFromEnum(key)];
}

pub fn isMouseButtonDown(self: *const Input, button: event.MouseButton) bool {
    return self.mouse_button_down[@intFromEnum(button)];
}

pub fn wasMouseButtonPressed(self: *const Input, button: event.MouseButton) bool {
    return self.mouse_button_pressed[@intFromEnum(button)];
}

pub fn wasMouseButtonReleased(self: *const Input, button: event.MouseButton) bool {
    return self.mouse_button_released[@intFromEnum(button)];
}

pub fn textInput(self: *const Input) []const u32 {
    return self.text_codepoints[0..self.text_len];
}

fn setDown(down: []bool, pressed: []bool, index: usize) void {
    if (!down[index]) {
        pressed[index] = true;
        down[index] = true;
    }
}

fn setUp(down: []bool, released: []bool, index: usize) void {
    if (down[index]) {
        released[index] = true;
        down[index] = false;
    }
}

fn setKeyDown(self: *Input, key: event.Key) void {
    setDown(&self.key_down, &self.key_pressed, @intFromEnum(key));
}

fn setKeyUp(self: *Input, key: event.Key) void {
    setUp(&self.key_down, &self.key_released, @intFromEnum(key));
}

fn setMouseButtonDown(self: *Input, button: event.MouseButton) void {
    setDown(&self.mouse_button_down, &self.mouse_button_pressed, @intFromEnum(button));
}

fn setMouseButtonUp(self: *Input, button: event.MouseButton) void {
    setUp(&self.mouse_button_down, &self.mouse_button_released, @intFromEnum(button));
}

fn setMousePosition(self: *Input, position: Position) void {
    if (self.has_mouse_position) {
        self.mouse_delta.x += position.x - self.mouse_pos.x;
        self.mouse_delta.y += position.y - self.mouse_pos.y;
    }
    self.mouse_pos = position;
    self.has_mouse_position = true;
}

fn appendText(self: *Input, codepoint: u32) void {
    if (self.text_len == text_capacity) {
        return;
    }
    self.text_codepoints[self.text_len] = codepoint;
    self.text_len += 1;
}

pub fn setFocused(self: *Input, focused: bool) void {
    if (self.focused == focused) {
        return;
    }

    self.focused = focused;
    self.has_mouse_position = false;
    if (!focused) {
        self.releaseAll();
    }
}

fn releaseAll(self: *Input) void {
    @memset(&self.key_down, false);
    @memset(&self.mouse_button_down, false);
}

test "Input tracks press, hold, and release edges" {
    var input: Input = .{};

    input.applyEvent(.{ .KeyPressed = .A });
    try std.testing.expect(input.isKeyDown(.A));
    try std.testing.expect(input.wasKeyPressed(.A));
    try std.testing.expect(!input.wasKeyReleased(.A));

    input.applyEvent(.{ .KeyReleased = .A });
    try std.testing.expect(!input.isKeyDown(.A));
    try std.testing.expect(input.wasKeyPressed(.A));
    try std.testing.expect(input.wasKeyReleased(.A));
}

test "Input frame reset preserves held input and clears transient input" {
    var input: Input = .{};
    input.applyEvent(.{ .KeyPressed = .W });
    input.applyEvent(.{ .MousePressed = .Left });
    input.applyEvent(.{ .MouseScroll = .{ .x = 2, .y = -1 } });
    input.applyEvent(.{ .CharInput = 'z' });

    input.beginFrame();

    try std.testing.expect(input.isKeyDown(.W));
    try std.testing.expect(input.isMouseButtonDown(.Left));
    try std.testing.expect(!input.wasKeyPressed(.W));
    try std.testing.expect(!input.wasMouseButtonPressed(.Left));
    try std.testing.expectEqual(@as(f32, 0), input.mouse_scroll.x);
    try std.testing.expectEqual(@as(usize, 0), input.textInput().len);
}

test "Input does not turn repeated keys into additional pressed edges" {
    var input: Input = .{};
    input.applyEvent(.{ .KeyPressed = .W });
    input.beginFrame();
    input.applyEvent(.{ .KeyRepeated = .W });

    try std.testing.expect(input.isKeyDown(.W));
    try std.testing.expect(!input.wasKeyPressed(.W));
}

test "Input accumulates mouse movement for the whole frame" {
    var input: Input = .{};
    input.applyEvent(.{ .MouseMove = .{ .x = 10, .y = 20 } });
    input.beginFrame();
    input.applyEvent(.{ .MouseMove = .{ .x = 15, .y = 22 } });
    input.applyEvent(.{ .MouseMove = .{ .x = 12, .y = 30 } });

    try std.testing.expectEqual(@as(f32, 2), input.mouse_delta.x);
    try std.testing.expectEqual(@as(f32, 10), input.mouse_delta.y);
}

test "Input records text input until its fixed capacity" {
    var input: Input = .{};
    input.applyEvent(.{ .CharInput = 'a' });
    input.applyEvent(.{ .CharInput = 0x1F642 });

    try std.testing.expectEqualSlices(u32, &.{ 'a', 0x1F642 }, input.textInput());
}

test "Input focus loss clears held input and prevents a mouse jump" {
    var input: Input = .{};
    input.applyEvent(.{ .KeyPressed = .W });
    input.applyEvent(.{ .MousePressed = .Right });
    input.applyEvent(.{ .MouseMove = .{ .x = 10, .y = 10 } });
    input.setFocused(false);
    input.setFocused(true);
    input.applyEvent(.{ .MouseMove = .{ .x = 100, .y = 100 } });

    try std.testing.expect(input.focused);
    try std.testing.expect(!input.isKeyDown(.W));
    try std.testing.expect(!input.isMouseButtonDown(.Right));
    try std.testing.expectEqual(@as(f32, 0), input.mouse_delta.x);
    try std.testing.expectEqual(@as(f32, 0), input.mouse_delta.y);
}

test "clear removes held and transient input" {
    var input: Input = .{};

    input.applyEvent(.{ .KeyPressed = .W });
    input.applyEvent(.{ .MousePressed = .Right });
    input.applyEvent(.{
        .MouseScroll = .{ .x = 0, .y = 2 },
    });

    input.clear();

    try std.testing.expect(!input.isKeyDown(.W));
    try std.testing.expect(!input.wasKeyPressed(.W));
    try std.testing.expect(
        !input.isMouseButtonDown(.Right),
    );
    try std.testing.expectEqual(
        @as(f32, 0),
        input.mouse_scroll.y,
    );
}
