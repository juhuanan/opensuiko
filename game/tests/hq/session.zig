const std = @import("std");
const session = @import("hq_session");

test "the HQ constructor returns the context refusal" {
    _ = &session.attachJourney;
    try std.testing.expectError(error.MissingRosterContext, session.create(std.testing.allocator, .missing_roster));
}
