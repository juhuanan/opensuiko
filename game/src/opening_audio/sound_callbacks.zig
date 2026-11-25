//! Explicit source call-boundary schedule; never invents timer frequency.
//! MAIN gameplay dispatch800C2870 precedes flag clear800C2884. Callback
//! 800C2988 calls the wrapper only when flag==1, then writes1; tail800C2964
//! calls unconditionally. Worker8015E11C skips guard==1, otherwise sets1,
//! samples/flushes at8015E160 before sequence service, then clears the guard.
//! Wrapper800C9388 also performs its conditional post-worker reverb operation.
const std = @import("std");
pub const Phase = enum { before_dispatch, dispatched, flag_cleared };
pub const State = struct {
    flag: u32,
    worker_guard: u32,
    phase: Phase,
    frame: u64,
    callbacks: u64,
    wrappers: u64,
    workers: u64,
    observed_samples: u64,
    applied_samples: u64,
    last_application: u64,
    checkpoint: u64,
    revision: u64,
    receipt: u64,
};
/// Authenticated actual startup/call boundary. No arbitrary default for the
/// source flag or guard is supplied. Sample counts are relative to this reset.
pub const ResetReceipt = struct { token: u64, checkpoint: u64, flag: u32, worker_guard: u32 };
pub const Operation = union(enum) {
    /// Only records externally observed samples; does not advance envelopes.
    elapsed_samples: u64,
    gameplay_dispatched,
    clear_flag,
    callback_arrival,
    frame_tail,
};
pub const Input = struct { token: u64, checkpoint: u64, operation: Operation };
pub const Call = enum { none, worker, reentry };
pub const Proposal = struct { input: Input, before: State, after: State, call: Call };
/// The caller owns the sequence/envelope/register processor and authenticates
/// its result. A boolean asserted without performing that work is not proof.
/// An inactive sequence set may be serviced as a verified no-op, never guessed.
pub const Application = struct {
    token: u64,
    sample_clock: u64,
    envelopes_through: u64,
    sampler_flush_before_sequences: bool,
    sequence_service_complete: bool,
    post_worker_complete: bool,
    returned_guard: u32,
};
pub const Receipt = struct {
    input_token: u64,
    revision: u64,
    checkpoint: u64,
    application: ?Application,
};
fn increment(value: u64) !u64 {
    return std.math.add(u64, value, 1) catch error.AudioScheduleExhausted;
}
pub const Owner = struct {
    state: State,
    pub fn atReset(receipt: ResetReceipt) !Owner {
        if (receipt.token == 0 or receipt.checkpoint == 0) return error.InvalidAudioResetReceipt;
        return .{ .state = .{ .flag = receipt.flag, .worker_guard = receipt.worker_guard, .phase = .before_dispatch, .frame = 0, .callbacks = 0, .wrappers = 0, .workers = 0, .observed_samples = 0, .applied_samples = 0, .last_application = 0, .checkpoint = receipt.checkpoint, .revision = 1, .receipt = receipt.token } };
    }
    /// A guard==1 snapshot retains the source reentry boundary. The external
    /// worker's continuation belongs to its own authenticated checkpoint; this
    /// owner cannot synthesize its completion or clear the guard to unblock it.
    pub fn restore(state: State) !Owner {
        if (state.checkpoint == 0 or state.revision == 0 or state.receipt == 0 or state.applied_samples > state.observed_samples or state.workers > state.wrappers or (state.workers == 0 and state.applied_samples != 0) or ((state.wrappers == 0) != (state.last_application == 0))) return error.InvalidAudioScheduleState;
        if (state.last_application > state.receipt) return error.InvalidAudioScheduleState;
        return .{ .state = state };
    }
    /// Inputs assert real ordered boundaries, not instructions to fabricate a
    /// timer. Caller retains any host-clock fractional sample remainder outside
    /// this owner and checkpoints it alongside the producer that creates inputs.
    pub fn propose(self: Owner, input: Input) !Proposal {
        _ = try restore(self.state);
        if (input.token <= self.state.receipt or input.checkpoint < self.state.checkpoint) return error.StaleAudioScheduleInput;
        var next = self.state;
        var call: Call = .none;
        switch (input.operation) {
            .elapsed_samples => |samples| next.observed_samples = std.math.add(u64, next.observed_samples, samples) catch return error.AudioSampleClockExhausted,
            .gameplay_dispatched => {
                if (next.phase != .before_dispatch) return error.InvalidAudioFrameOrder;
                next.frame = try increment(next.frame);
                next.phase = .dispatched;
            },
            .clear_flag => {
                if (next.phase != .dispatched) return error.InvalidAudioFrameOrder;
                next.flag = 0;
                next.phase = .flag_cleared;
            },
            .callback_arrival => {
                next.callbacks = try increment(next.callbacks);
                if (next.flag == 1) call = if (next.worker_guard == 1) .reentry else .worker;
                next.flag = 1;
            },
            .frame_tail => {
                if (next.phase != .flag_cleared) return error.InvalidAudioFrameOrder;
                call = if (next.worker_guard == 1) .reentry else .worker;
                next.phase = .before_dispatch;
            },
        }
        if (call != .none) next.wrappers = try increment(next.wrappers);
        if (call == .worker) {
            next.workers = try increment(next.workers);
            next.worker_guard = 0;
        }
        next.checkpoint = input.checkpoint;
        next.revision = try increment(next.revision);
        next.receipt = input.token;
        return .{ .input = input, .before = self.state, .after = next, .call = call };
    }
    pub fn commit(self: *Owner, proposal: Proposal, receipt: Receipt) !void {
        if (!std.meta.eql(self.state, proposal.before)) return error.StaleAudioScheduleState;
        const expected = try self.propose(proposal.input);
        if (!std.meta.eql(expected, proposal) or receipt.input_token != proposal.input.token or receipt.revision != self.state.revision or receipt.checkpoint != proposal.input.checkpoint) return error.InvalidAudioScheduleReceipt;
        var next = expected.after;
        if (expected.call == .none) {
            if (receipt.application != null) return error.UnexpectedAudioApplicationReceipt;
        } else {
            const application = receipt.application orelse return error.MissingAudioApplicationReceipt;
            if (application.token != proposal.input.token or application.sample_clock != self.state.observed_samples or !application.post_worker_complete) return error.InvalidAudioApplicationReceipt;
            if (expected.call == .worker) {
                if (application.envelopes_through != self.state.observed_samples or !application.sampler_flush_before_sequences or !application.sequence_service_complete or application.returned_guard != 0) return error.InvalidAudioApplicationReceipt;
                next.applied_samples = application.envelopes_through;
            } else {
                if (application.envelopes_through != self.state.applied_samples or application.sampler_flush_before_sequences or application.sequence_service_complete or application.returned_guard != 1) return error.InvalidAudioApplicationReceipt;
            }
            next.last_application = application.token;
        }
        _ = try restore(next);
        self.state = next;
    }
};
