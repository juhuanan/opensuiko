//! Logical cue-14 sequence stops; no playback or event acknowledgement.
//! MAIN 8015DF5C/8015E0C8 and 80158190, US v1.1. Caller authenticates
//! opened-handle receipt, complete live sequence/voice state and cue identity.
const std = @import("std");
const staging = @import("sound_staging.zig");
const media = @import("raw_media_owner.zig");
pub const source_sha256 = "ad0bead9bea912e046ddd2947e4c2eaca747bb0af6be1e9baf8723abb3d068c8".*;
pub const starts = [4]u32{ 16, 15828, 34368, 44454 };
pub const ends = [4]u32{ 15812, 34352, 44438, 71162 };
pub const initial_bpm = [4]u32{ 120, 115, 84, 114 };
pub const Channel = struct { program: u8, pan: u8, volume: u16 };
/// Cursor offsets are in pinned SEQ.BIN. Other sequence state belongs to its
/// owner and must be retained there; only fields touched by source stop appear.
pub const Record = struct {
    handle: u8,
    bank_slot: u8,
    generation: u64,
    flags: u32,
    cursor: u32,
    start: u32,
    loop_cursor: u32,
    event_control: [7]u8,
    loop_control: [5]u8,
    control_word: u16,
    countdown: i16,
    step: u16,
    initial_step: u16,
    initial_delay: u32,
    delay: u32,
    zero_word: u32,
    initial_bpm: u32,
    current_bpm: u32,
    channels: [16]Channel,
    levels: [2]u16,
    master_levels: [2]u16,
    last_velocity: u16,
};
pub const State = struct { records: [4]Record, voice: staging.State, generation: u64, revision: u64, receipt: u64 };
pub const Request = struct { instance: u64, batch: u64, origin: u16 };
pub const Proposal = struct { token: u64, request: Request, before: State, after: State, stopped_masks: [2]u32 };
/// Authenticates matching logical staging only. No field-event receipt.
pub const Receipt = struct { token: u64, revision: u64, request: Request, stopped_masks: [2]u32 };
/// Requires real SEQ.BIN bytes, not a caller-supplied digest alone.
pub fn verifySource(bytes: []const u8) !void {
    if (bytes.len != 71162) return error.InvalidSequenceSource;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), &source_sha256)) return error.InvalidSequenceSource;
}
fn expectedStep(bpm: u32, rate: u16) !u16 {
    if (rate != 50 and rate != 60) return error.InvalidSequenceClockRate;
    const product = 480 * bpm;
    const divisor: u32 = 60 * @as(u32, rate);
    if (10 * product < divisor) return @intCast((600 * @as(u32, rate)) / product);
    const numerator = 10 * product;
    return @intCast(numerator / divisor + @intFromBool(numerator % divisor > divisor / 2));
}
/// Derive initial fields from a sequence header. This parser does not
/// authenticate bytes or establish that a handle was opened.
pub fn initialRecord(header: []const u8, index: u8, generation: u64, rate: u16, prior_levels: [2]u16) !Record {
    if (index >= 4 or generation == 0 or header.len < 16) return error.InvalidSequenceSource;
    const tempos = [4]u32{ 500000, 521739, 717703, 525854 };
    if (!std.mem.eql(u8, header[0..8], "pQES\x00\x00\x00\x01") or
        std.mem.readInt(u16, header[8..10], .big) != 480 or
        (@as(u32, header[10]) << 16 | @as(u32, header[11]) << 8 | @as(u32, header[12])) != tempos[index] or header[15] != 0) return error.InvalidSequenceSource;
    var channels: [16]Channel = undefined;
    for (&channels, 0..) |*channel, i| channel.* = .{ .program = @intCast(i), .pan = 64, .volume = 127 };
    const step = try expectedStep(initial_bpm[index], rate);
    return .{ .handle = index, .bank_slot = if (index < 2) 1 else 2, .generation = generation, .flags = 0, .cursor = starts[index], .start = starts[index], .loop_cursor = starts[index], .event_control = @splat(0), .loop_control = @splat(0), .control_word = 0, .countdown = -1, .step = step, .initial_step = step, .initial_delay = 0, .delay = 0, .zero_word = 0, .initial_bpm = initial_bpm[index], .current_bpm = initial_bpm[index], .channels = channels, .levels = prior_levels, .master_levels = .{ 127, 127 }, .last_velocity = 127 };
}
fn validateState(state: State, rate: u16) !void {
    _ = try staging.Owner.restore(state.voice);
    if (state.generation == 0 or (state.revision == 0) != (state.receipt == 0)) return error.InvalidSequenceState;
    for (state.records, 0..) |record, i| {
        if (record.handle != i or record.bank_slot != (if (i < 2) @as(u8, 1) else 2) or record.generation != state.generation or
            record.start != starts[i] or record.initial_delay != 0 or record.initial_bpm != initial_bpm[i] or
            record.initial_step != try expectedStep(record.initial_bpm, rate) or record.cursor < starts[i] or record.cursor > ends[i] or
            record.loop_cursor < starts[i] or record.loop_cursor > ends[i]) return error.InvalidSequenceState;
    }
}
pub const Owner = struct {
    pub const OpenResult = struct { owner: Owner, allocation_mask: u32 };
    state: State,
    rate: u16,
    /// Apply the bounded action-8 close/open transform using real retained
    /// SEQ bytes. Caller authenticates the source loader's completed transfer,
    /// opening phase, handle mask, prior record values and live voice owner.
    /// Source close also touches gains and key-off of matching voices; refuse
    /// those cases until their actual gain/close owner is available.
    pub fn openFromLoaded(loaded: *const media.Loaded, voice: staging.Owner, prior_levels: [4][2]u16, allocation_mask: u32, generation: u64, rate: u16) !OpenResult {
        return openFromRetainedBytes(loaded, loaded.seq, voice, prior_levels, allocation_mask, generation, rate);
    }
    /// Consume the actual completed logical read buffer. Voice and close-state
    /// provenance remain caller-owned; this does not complete a loader action.
    pub fn openFromRetainedBytes(loaded: *const media.Loaded, retained: []const u8, voice: staging.Owner, prior_levels: [4][2]u16, allocation_mask: u32, generation: u64, rate: u16) !OpenResult {
        try verifySource(retained);
        if (!std.mem.eql(u8, &loaded.receipt.sequence_sha256, &source_sha256) or generation == 0) return error.InvalidSequenceOpenReceipt;
        _ = try staging.Owner.restore(voice.state);
        for (voice.state.voices.keys) |key| if (key.owner >= 0 and key.owner <= 3) return error.UnsupportedExistingSequenceVoice;
        var records: [4]Record = undefined;
        for (0..4) |i| {
            const handle = loaded.receipt.sequences[i];
            if (handle.index != i or handle.offset != starts[i] - 16 or handle.length != ends[i] - (starts[i] - 16) or handle.bank_slot != (if (i < 2) @as(u8, 1) else 2)) return error.InvalidSequenceOpenReceipt;
            const end = std.math.add(usize, handle.offset, handle.length) catch return error.InvalidSequenceOpenReceipt;
            if (end > retained.len) return error.InvalidSequenceOpenReceipt;
            const bytes = retained[handle.offset..end];
            records[i] = try initialRecord(bytes, @intCast(i), generation, rate, prior_levels[i]);
        }
        const owner: Owner = .{ .state = .{ .records = records, .voice = voice.state, .generation = generation, .revision = 0, .receipt = 0 }, .rate = rate };
        try validateState(owner.state, rate);
        return .{ .owner = owner, .allocation_mask = allocation_mask | 0x0f };
    }
    /// Caller authenticates restored handle provenance and earlier history.
    pub fn restore(state: State, rate: u16) !Owner {
        try validateState(state, rate);
        return .{ .state = state, .rate = rate };
    }
    pub fn proposeStop(self: Owner, request: Request, token: u64) !Proposal {
        try validateState(self.state, self.rate);
        if (request.instance == 0 or request.batch == 0 or token == 0 or token <= self.state.receipt or token <= self.state.voice.receipt or token <= self.state.voice.voices.allocator.receipt) return error.InvalidSequenceStopRequest;
        var next = self.state;
        var masks: [2]u32 = .{ 0, 0 };
        for (0..2) |sequence| {
            const record = &next.records[sequence];
            record.flags = (record.flags & ~@as(u32, 0x0b)) | 4;
            record.cursor = record.start;
            record.loop_cursor = record.start;
            record.event_control = @splat(0);
            record.loop_control = @splat(0);
            record.control_word = 0;
            record.zero_word = 0;
            record.delay = record.initial_delay;
            record.current_bpm = record.initial_bpm;
            record.step = record.initial_step;
            record.levels = .{ 127, 127 };
            for (&record.channels, 0..) |*channel, i| channel.* = .{ .program = @intCast(i), .pan = 64, .volume = 127 };
            for (&next.voice.voices.keys, 0..) |*key, i| {
                if (key.owner != @as(i16, @intCast(sequence))) continue;
                const bit = @as(u32, 1) << @intCast(i);
                masks[sequence] |= bit;
                next.voice.voices.allocator.voices[i].status = 0;
                key.sample = 0;
                next.voice.pitches[i] = 0;
                next.voice.voices.pending_key_off |= bit;
                next.voice.voices.pending_key_on &= ~next.voice.voices.pending_key_off;
            }
        }
        next.voice.voices.allocator.revision = std.math.add(u64, next.voice.voices.allocator.revision, 1) catch return error.SequenceRevisionExhausted;
        next.voice.voices.allocator.receipt = token;
        next.voice.revision = std.math.add(u64, next.voice.revision, 1) catch return error.SequenceRevisionExhausted;
        next.voice.receipt = token;
        next.revision = std.math.add(u64, next.revision, 1) catch return error.SequenceRevisionExhausted;
        next.receipt = token;
        return .{ .token = token, .request = request, .before = self.state, .after = next, .stopped_masks = masks };
    }
    pub fn commit(self: *Owner, proposal: Proposal, receipt: Receipt) !void {
        if (!std.meta.eql(self.state, proposal.before)) return error.StaleSequenceState;
        const expected = try self.proposeStop(proposal.request, proposal.token);
        if (!std.meta.eql(expected, proposal) or receipt.token != proposal.token or receipt.revision != self.state.revision or !std.meta.eql(receipt.request, proposal.request) or !std.meta.eql(receipt.stopped_masks, expected.stopped_masks)) return error.InvalidSequenceStopReceipt;
        self.state = expected.after;
    }
};
