//! Bounded logical sampler/flush for US v1.1 MAIN 8015735C..801576F8.
//! Caller authenticates callback, envelope readings and sequence completion;
//! this owner neither advances envelopes nor completes a callback application.
//! Active volume or pan transitions are refused until their workers are owned.
const std = @import("std");
pub const history = @import("voice_history.zig");
pub const callbacks = @import("sound_callbacks.zig");
pub const voice_count = 24;
pub const Registers = struct { left: u16, right: u16, pitch: u16, start: u16, adsr1: u16, adsr2: u16 };
pub const State = struct {
    history: history.State,
    staged: [voice_count]Registers,
    hardware: [voice_count]Registers,
    dirty: [voice_count]u8,
    volume_active: [voice_count]i16,
    pan_active: [voice_count]i16,
    key_on: [2]u16,
    key_off: [2]u16,
    reverb: [2]u16,
    sample_clock: u64,
    revision: u64,
    receipt: u64,
};
/// Readings must come from the actual source-bound producer at this boundary.
pub const Samples = struct { token: u64, checkpoint: u64, sample_clock: u64, levels: [history.voice_count]u16, inhibit: bool };
pub const Writes = struct { key_on: [2]u16, key_off: [2]u16, reverb: [2]u16, noise_off: u32 };
pub const Proposal = struct { input: callbacks.Input, samples: Samples, before: State, after: State, writes: Writes };
/// External owner confirms sequence processing followed this specific flush.
/// This does not establish wrapper post-work or a complete callback application.
pub const SequenceReceipt = struct { token: u64, checkpoint: u64, sampler_revision: u64, flush_consumed: bool, service_complete: bool };
pub const Receipt = struct { token: u64, checkpoint: u64, sample_clock: u64, noise_off: u32, sequence: SequenceReceipt };
pub const Owner = struct {
    state: State,
    pub fn restore(state: State) !Owner {
        _ = try history.Owner.restore(state.history);
        if ((state.revision == 0) != (state.receipt == 0)) return error.InvalidSamplerState;
        return .{ .state = state };
    }
    /// Samples, callback owner, and their source checkpoint must be authenticated
    /// by the caller; equality here binds a transaction, not its provenance.
    pub fn propose(self: Owner, callback: callbacks.Owner, input: callbacks.Input, samples: Samples) !Proposal {
        _ = try restore(self.state);
        if (input.token == 0 or input.token <= self.state.receipt or input.token <= self.state.history.receipt) return error.StaleSamplerReceipt;
        const call = try callback.propose(input);
        if (call.call != .worker or samples.token != input.token or samples.checkpoint != input.checkpoint or samples.sample_clock != callback.state.observed_samples or samples.sample_clock < self.state.sample_clock) return error.InvalidSamplerBoundary;
        for (self.state.volume_active, self.state.pan_active) |volume, pan| if (volume != 0 or pan != 0) return error.UnsupportedSamplerTransition;
        var next = self.state;
        var h = try history.Owner.restore(next.history);
        const poll = try h.proposePoll(input.token, &samples.levels, samples.inhibit);
        try h.commitPoll(poll, .{ .token = input.token, .revision = poll.revision, .noise_off = poll.noise_off });
        next.history = h.state;
        var writes: Writes = .{ .key_on = undefined, .key_off = next.key_off, .reverb = next.reverb, .noise_off = poll.noise_off };
        for (0..2) |i| writes.key_on[i] = next.key_on[i] & ~next.key_off[i];
        for (0..voice_count) |i| {
            const dirty = next.dirty[i];
            if (dirty & 1 != 0) {
                next.hardware[i].left = next.staged[i].left;
                next.hardware[i].right = next.staged[i].right;
            }
            if (dirty & 4 != 0) next.hardware[i].pitch = next.staged[i].pitch;
            if (dirty & 8 != 0) next.hardware[i].start = next.staged[i].start;
            if (dirty & 16 != 0) {
                next.hardware[i].adsr1 = next.staged[i].adsr1;
                next.hardware[i].adsr2 = next.staged[i].adsr2;
            }
            next.dirty[i] = 0;
        }
        next.key_on = .{ 0, 0 };
        next.key_off = .{ 0, 0 };
        next.sample_clock = samples.sample_clock;
        next.revision = std.math.add(u64, next.revision, 1) catch return error.SamplerRevisionExhausted;
        next.receipt = input.token;
        return .{ .input = input, .samples = samples, .before = self.state, .after = next, .writes = writes };
    }
    /// Caller must atomically coordinate this state with callback, hardware,
    /// noise switch and sequence owners; sequence must consume this flush.
    pub fn commit(self: *Owner, callback: callbacks.Owner, proposal: Proposal, receipt: Receipt) !void {
        if (!std.meta.eql(self.state, proposal.before)) return error.StaleSamplerState;
        const expected = try self.propose(callback, proposal.input, proposal.samples);
        const seq = receipt.sequence;
        if (!std.meta.eql(expected, proposal) or receipt.token != proposal.input.token or receipt.checkpoint != proposal.input.checkpoint or receipt.sample_clock != proposal.samples.sample_clock or receipt.noise_off != expected.writes.noise_off or seq.token != proposal.input.token or seq.checkpoint != proposal.input.checkpoint or seq.sampler_revision != proposal.before.revision or !seq.flush_consumed or !seq.service_complete) return error.InvalidSamplerReceipt;
        self.state = expected.after;
    }
};
