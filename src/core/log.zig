const builtin = @import("builtin");
const std = @import("std");

const logger = std.log.scoped(.runtime);

pub fn err(comptime format: []const u8, args: anytype) void {
    if (comptime builtin.is_test) {
        return;
    }
    logger.err(format, args);
}

pub fn warn(comptime format: []const u8, args: anytype) void {
    if (comptime builtin.is_test) {
        return;
    }
    logger.warn(format, args);
}

pub fn info(comptime format: []const u8, args: anytype) void {
    logger.info(format, args);
}

pub fn debug(comptime format: []const u8, args: anytype) void {
    if (comptime builtin.mode == .fast) {
        return;
    }
    logger.debug(format, args);
}
