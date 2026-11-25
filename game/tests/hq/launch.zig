const std = @import("std");
const launch = @import("hq").launch;

test "the HQ loader refuses a missing roster instead of inventing one" {
    try std.testing.expectError(error.MissingRosterContext, launch.open(std.testing.allocator, .missing_roster));
}

test "the HQ loader names the missing recruit bytes" {
    try std.testing.expectError(error.MissingRecruitContext, launch.open(std.testing.allocator, .missing_recruit));
}

test "the HQ roster factory rejects an empty baseline instead of inventing members" {
    const snapshot = launch.emptySnapshot();
    try std.testing.expectError(error.EmptyRoster, launch.rosterFrom(std.testing.allocator, snapshot, &.{}));
}
