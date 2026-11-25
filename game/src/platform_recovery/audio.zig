//! Audio availability recovery over the existing opening-audio logical
//! adapter (`opening_audio.State`).  No device call is made here: the running
//! platform loop supplies a typed backend, and this gate owns at most one
//! device stream lease.
//!
//! Policy: an unavailable device is a waiver, not a mode stop.  A cue is kept
//! as at most one pending request, the logical track is not advanced, and no
//! playback is claimed.  When the device returns the pending cue is applied
//! once; a failed stream start rolls the logical track back and stays
//! retryable.  This mirrors the existing opening fallback and the campaign field
//! audio waiver without inventing a second audio host.

const std = @import("std");
const opening_audio = @import("opening").audio;
const diagnostic = @import("diagnostic.zig");

pub const Id = opening_audio.Id;

pub const Backend = struct {
    context: *anyopaque,
    play: *const fn (context: *anyopaque, id: Id) anyerror!void,
    stop: *const fn (context: *anyopaque, id: Id) void,
};

pub const Result = enum { unchanged, waived, applied, retryable };

pub const Outcome = struct {
    result: Result,
    track: ?Id = null,
    pending: bool = false,
    diagnostic: ?diagnostic.Diagnostic = null,
};

pub const Counters = struct {
    cues: u32 = 0,
    waived: u32 = 0,
    coalesced: u32 = 0,
    applied: u32 = 0,
    failed: u32 = 0,
    retried: u32 = 0,
    plays: u32 = 0,
    stops: u32 = 0,
    device_losses: u32 = 0,
};

pub const Gate = struct {
    backend: ?Backend = null,
    ready: bool = false,
    state: opening_audio.State = .{},
    /// The single device stream this gate currently owns, if any.
    device_track: ?Id = null,
    pending: ?u16 = null,
    counters: Counters = .{},
    last: ?diagnostic.Diagnostic = null,

    /// The device appeared or disappeared.  Losing the device releases the
    /// device-stream lease once; the logical track is kept so the caller can
    /// resume it after reconnect.
    pub fn setReady(self: *Gate, ready: bool) void {
        if (ready == self.ready) return;
        if (!ready) {
            self.stopDevice();
            self.counters.device_losses +|= 1;
        }
        self.ready = ready;
    }

    pub fn attach(self: *Gate, backend: Backend) void {
        self.backend = backend;
    }

    /// Stop and forget the backend exactly once.  Repeating detach is a no-op.
    pub fn detach(self: *Gate) void {
        self.stopDevice();
        self.backend = null;
        self.ready = false;
    }

    fn stopDevice(self: *Gate) void {
        if (self.device_track) |id| {
            if (self.backend) |backend| backend.stop(backend.context, id);
            self.device_track = null;
            self.counters.stops +|= 1;
        }
    }

    /// Probe the existing adapter's cue mapping without mutating the logical
    /// track: a snapshot/restore, not a second copy of the 0x81/0x422/0x15 map.
    fn knownCue(self: *Gate, value: u16) bool {
        const saved = self.state;
        const changed = self.state.cue(value);
        self.state = saved;
        return changed;
    }

    pub fn cue(self: *Gate, value: u16) Outcome {
        self.counters.cues +|= 1;
        if (!self.knownCue(value)) return .{ .result = .unchanged, .track = self.state.track };
        if (!self.ready or self.backend == null) {
            if (self.pending != null and self.pending.? != value) self.counters.coalesced +|= 1;
            self.pending = value;
            self.counters.waived +|= 1;
            self.last = diagnostic.of(.audio_device_unavailable);
            return .{ .result = .waived, .track = self.state.track, .pending = true, .diagnostic = self.last };
        }
        return self.apply(value);
    }

    /// Retry the one pending request.  Repeating it after success is unchanged.
    pub fn retry(self: *Gate) Outcome {
        const value = self.pending orelse return .{ .result = .unchanged, .track = self.state.track };
        if (!self.ready or self.backend == null) {
            self.last = diagnostic.of(.audio_device_unavailable);
            return .{ .result = .waived, .track = self.state.track, .pending = true, .diagnostic = self.last };
        }
        self.counters.retried +|= 1;
        return self.apply(value);
    }

    fn apply(self: *Gate, value: u16) Outcome {
        const before = self.state.track;
        if (!self.state.cue(value)) {
            self.pending = null;
            return .{ .result = .unchanged, .track = self.state.track };
        }
        self.converge() catch |err| {
            self.state.track = before;
            self.pending = value;
            self.counters.failed +|= 1;
            self.last = diagnostic.describe(err);
            return .{ .result = .retryable, .track = self.state.track, .pending = true, .diagnostic = self.last };
        };
        self.pending = null;
        self.counters.applied +|= 1;
        return .{ .result = .applied, .track = self.state.track };
    }

    /// Make the single device stream match the logical track.  The previous
    /// stream is stopped before the next one starts; a start failure leaves no
    /// device lease behind.
    fn converge(self: *Gate) !void {
        const backend = self.backend orelse return error.AudioDeviceUnavailable;
        const desired = self.state.track;
        if (desired == self.device_track) return;
        self.stopDevice();
        if (desired) |id| {
            try backend.play(backend.context, id);
            self.device_track = id;
            self.counters.plays +|= 1;
        }
    }

    /// Resume the logical track after a device loss without a new cue.
    pub fn resumeTrack(self: *Gate) Outcome {
        if (self.state.track == null) return .{ .result = .unchanged, .track = null };
        if (!self.ready or self.backend == null) {
            self.last = diagnostic.of(.audio_device_unavailable);
            return .{ .result = .waived, .track = self.state.track, .pending = self.pending != null, .diagnostic = self.last };
        }
        self.converge() catch |err| {
            self.counters.failed +|= 1;
            self.last = diagnostic.describe(err);
            return .{ .result = .retryable, .track = self.state.track, .pending = self.pending != null, .diagnostic = self.last };
        };
        return .{ .result = .applied, .track = self.state.track };
    }

    pub fn deviceLeases(self: *const Gate) usize {
        return if (self.device_track == null) 0 else 1;
    }
};

test "unknown cue leaves state and pending untouched" {
    var gate: Gate = .{};
    const before = gate.state.track;
    const out = gate.cue(0x1234);
    try std.testing.expectEqual(Result.unchanged, out.result);
    try std.testing.expectEqual(before, gate.state.track);
    try std.testing.expect(gate.pending == null);
}
