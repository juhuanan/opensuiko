const std = @import("std");

pub const simulation_ticks_per_second = 60;
pub const SimulationClock = FixedStepClock(simulation_ticks_per_second);

pub fn FixedStepClock(comptime ticks_per_second: u32) type {
    return struct {
        const Self = @This();
        const tick_seconds: f64 = 1.0 / @as(f64, @floatFromInt(ticks_per_second));
        const max_frame_seconds: f32 = 0.1;

        accumulated_seconds: f64 = 0,

        pub fn addFrame(self: *Self, frame_seconds: f32) void {
            self.accumulated_seconds += @min(frame_seconds, max_frame_seconds);
        }

        pub fn tickReady(self: Self) bool {
            return self.accumulated_seconds >= tick_seconds;
        }

        pub fn finishTick(self: *Self) void {
            self.accumulated_seconds -= tick_seconds;
        }

        pub fn takeTick(self: *Self) bool {
            if (!self.tickReady()) return false;
            self.finishTick();
            return true;
        }
    };
}

test "fixed-step clock retains frame remainder and clamps long frames" {
    var clock: SimulationClock = .{};
    clock.addFrame(0.01);
    try std.testing.expect(!clock.takeTick());
    clock.addFrame(0.01);
    try std.testing.expect(clock.takeTick());
    try std.testing.expect(!clock.takeTick());
    try std.testing.expectApproxEqAbs(@as(f64, 0.02 - 1.0 / 60.0), clock.accumulated_seconds, 0.000001);

    clock = .{};
    clock.addFrame(1.0);
    for (0..6) |_| try std.testing.expect(clock.takeTick());
    try std.testing.expect(!clock.takeTick());

    clock.addFrame(0.1);
    try std.testing.expect(clock.takeTick());
    clock = .{};
    clock.addFrame(1.0 / 60.0);
    try std.testing.expect(clock.takeTick());
    try std.testing.expect(!clock.takeTick());
}
