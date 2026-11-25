//! VA1 room 2 entity 2 opcode 06 descriptor movement batches.
//! MAIN 0x8013F0C0 gates the VM while 0x801716B8 is nonzero;
//! 0x8013F110 calls the VM before 0x8013E450 each driver invocation.
//! 0x8013E4BC skips exhausted slots; 0x8013E518..564 attempts movement
//! only at countdown 4 with a nonzero source count. The final four-pass
//! drain has no movement attempt (0x8013E584..620).
//! Movement collision/position belongs to the caller's room descriptor owner.
const std = @import("std");

pub const Source = struct { offset: u32, selector: u8, parameter: u8, repetitions: u8, direction: u2 };
pub const sources = [_]Source{
    .{ .offset = 0x3d17c, .selector = 0, .parameter = 2, .repetitions = 14, .direction = 0 },
    .{ .offset = 0x3d181, .selector = 0, .parameter = 3, .repetitions = 5, .direction = 2 },
    .{ .offset = 0x3d19f, .selector = 0, .parameter = 3, .repetitions = 2, .direction = 2 },
};
fn sourceFor(offset: u32) !Source {
    for (sources) |s| if (s.offset == offset) return s;
    return error.UnsupportedSourceRequest;
}
pub const State = struct {
    source_offset: ?u32 = null,
    countdown: u8 = 0,
    remaining: u8 = 0,
    revision: u64 = 0,
    receipt: u64 = 0,
    checkpoint: u64 = 0,
};
pub const Attempt = struct { source_offset: u32, selector: u8, direction: u2 };
pub const Operation = union(enum) { request: u32, tick };
pub const Proposal = struct { operation: Operation, before: State, after: State, attempt: ?Attempt };
pub const Owner = struct {
    state: State = .{},
    pub fn restore(state: State) !Owner {
        if (state.receipt != state.revision or (state.revision == 0) != (state.checkpoint == 0) or state.checkpoint < state.revision) return error.InvalidBatchState;
        if (state.source_offset) |offset| {
            const source = try sourceFor(offset);
            if (state.countdown == 0 or state.countdown > 4 or state.remaining > source.repetitions) return error.InvalidBatchState;
        } else if (state.countdown != 0 or state.remaining != 0) return error.InvalidBatchState;
        return .{ .state = state };
    }
    pub fn active(self: Owner) bool {
        return self.state.source_offset != null;
    }
    fn replay(self: Owner, op: Operation, checkpoint: u64) !Proposal {
        _ = try restore(self.state);
        if (checkpoint <= self.state.checkpoint) return error.InvalidCheckpoint;
        var next = self.state;
        var attempt: ?Attempt = null;
        switch (op) {
            .request => |offset| {
                if (self.active()) return error.BatchBusy;
                const source = try sourceFor(offset);
                next.source_offset = offset;
                next.countdown = 4;
                next.remaining = source.repetitions;
            },
            .tick => {
                const source = try sourceFor(next.source_offset orelse return error.NoActiveBatch);
                if (next.countdown == 4 and next.remaining != 0) attempt = .{ .source_offset = source.offset, .selector = source.selector, .direction = source.direction };
                next.countdown -= 1;
                if (next.countdown == 0) {
                    if (next.remaining > 0) {
                        next.remaining -= 1;
                        next.countdown = 4;
                    } else next.source_offset = null;
                }
            },
        }
        next.revision = try std.math.add(u64, next.revision, 1);
        next.receipt = try std.math.add(u64, next.receipt, 1);
        next.checkpoint = checkpoint;
        return .{ .operation = op, .before = self.state, .after = next, .attempt = attempt };
    }
    pub fn proposeRequest(self: Owner, offset: u32, checkpoint: u64) !Proposal {
        return self.replay(.{ .request = offset }, checkpoint);
    }
    pub fn proposeTick(self: Owner, checkpoint: u64) !Proposal {
        return self.replay(.tick, checkpoint);
    }
    pub fn commit(self: *Owner, proposal: Proposal) !void {
        if (!std.meta.eql(self.state, proposal.before)) return error.StaleBatchState;
        const expected = try self.replay(proposal.operation, proposal.after.checkpoint);
        if (!std.meta.eql(expected, proposal)) return error.InvalidBatchProposal;
        self.state = expected.after;
    }
};
