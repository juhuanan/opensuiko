const std = @import("std");
const batch = @import("movement_batch");
test "source batches preserve four ticks per attempt and direction" {
    for (batch.sources, [_]u16{ 60, 24, 12 }, [_]u16{ 14, 5, 2 }) |source, total, attempts| {
        var owner: batch.Owner = .{};
        try owner.commit(try owner.proposeRequest(source.offset, 1));
        var observed: u16 = 0;
        for (0..total) |i| {
            const p = try owner.proposeTick(@intCast(i + 2));
            if (p.attempt) |a| {
                observed += 1;
                try std.testing.expectEqual(source.direction, a.direction);
                try std.testing.expectEqual(@as(u8, 0), a.selector);
            }
            try owner.commit(p);
            try std.testing.expectEqual(i + 1 < total, owner.active());
        }
        try std.testing.expectEqual(attempts, observed);
        try std.testing.expectError(error.NoActiveBatch, owner.proposeTick(total + 2));
    }
}
test "source identity stale replay and forged movement are rejected" {
    var owner: batch.Owner = .{};
    try std.testing.expectError(error.UnsupportedSourceRequest, owner.proposeRequest(0x3d17d, 1));
    const request = try owner.proposeRequest(0x3d17c, 1);
    try owner.commit(request);
    try std.testing.expectError(error.StaleBatchState, owner.commit(request));
    try std.testing.expectError(error.BatchBusy, owner.proposeRequest(0x3d181, 2));
    var tick = try owner.proposeTick(2);
    tick.attempt.?.direction = 2;
    try std.testing.expectError(error.InvalidBatchProposal, owner.commit(tick));
    try std.testing.expectEqual(@as(u8, 4), owner.state.countdown);
    var bad = owner.state;
    bad.countdown = 5;
    try std.testing.expectError(error.InvalidBatchState, batch.Owner.restore(bad));
    bad = owner.state;
    bad.remaining = 15;
    try std.testing.expectError(error.InvalidBatchState, batch.Owner.restore(bad));
    bad = owner.state;
    bad.receipt = 0;
    try std.testing.expectError(error.InvalidBatchState, batch.Owner.restore(bad));
}
