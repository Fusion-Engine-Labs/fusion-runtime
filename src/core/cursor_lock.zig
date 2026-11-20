//! Whether the cursor is locked for mouse look. A world resource: the game
//! asks through `World.setCursorLocked`, and whoever owns the window decides
//! (see `Application.updateCursorLock`) and records the outcome here, which
//! games then read as `Frame.cursor_locked`.

const CursorLock = @This();

/// The state in effect, set only by the window owner.
locked: bool = false,
/// The game's latest request, cleared once the window owner has handled it.
requested: ?bool = null,

/// Consumes a pending request and returns the state the window should be in.
/// `allow_lock` false refuses (or ends) any lock, e.g. while not playing.
pub fn resolve(self: *CursorLock, allow_lock: bool) bool {
    const wanted = self.requested orelse self.locked;
    self.requested = null;
    self.locked = wanted and allow_lock;
    return self.locked;
}

const testing = @import("std").testing;

test "requests take effect when resolved and are consumed" {
    var cursor: CursorLock = .{};
    try testing.expect(!cursor.resolve(true));

    cursor.requested = true;
    try testing.expect(cursor.resolve(true));
    try testing.expect(cursor.locked);
    try testing.expectEqual(@as(?bool, null), cursor.requested);
    // Without a new request the lock holds.
    try testing.expect(cursor.resolve(true));

    cursor.requested = false;
    try testing.expect(!cursor.resolve(true));
}

test "a lock is refused or ended while locking is not allowed" {
    var cursor: CursorLock = .{ .requested = true };
    try testing.expect(!cursor.resolve(false));
    try testing.expect(!cursor.locked);

    cursor = .{ .locked = true };
    try testing.expect(!cursor.resolve(false));
    try testing.expect(!cursor.locked);
}
