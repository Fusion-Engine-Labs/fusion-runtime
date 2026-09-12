const zcs = @import("zcs");
const Time = @import("time.zig");

components: []const type,
/// Runs once per rendered frame, after fixed simulation ticks.
update_schedule: zcs.Schedule.Spec = .{},
/// Runs zero or more times per frame with a constant DeltaTime.
fixed_update_schedule: zcs.Schedule.Spec = .{},
simulation: Time.Config = .{},
