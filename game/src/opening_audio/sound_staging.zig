//! Pure staging of direct commands 506, 508 and 547, requiring an actual callback snapshot
//! and source sample receipt. No sampler clock, audio device or event ack.
//! Caller must also own the source command scratch halfwords at 0x80189050,
//! 0x80189058, 0x80189060 and 0x80189068, written before this operation.
//! MAIN: stop 80157BE0; allocate 80154C8C; note fields 801579CC..80157B40;
//! sample/ADSR/history 801553E8; gain/pitch/key masks 80154F08..801553D8.
//! Status-2 allocation clears all noise bits through 80160B58/801638B0.
//! Sample FF stop instead mutes CD input at 80157CD8/CE0.
const std = @import("std");
pub const requests = @import("sound_requests.zig");
pub const history = @import("voice_history.zig");
pub const sampler = @import("sound_sampler.zig");
pub const sample_sha256 = "a122fca915c35f983652c18f9c172de54b86561731b9d20d1a37cc31d93289c2";
/// Raw STAY.VB sample5: offset6656, length2512. Caller validates this source
/// identity when binding its decoded sample; this module never opens media.
pub const SampleReceipt = struct { bank_generation: u64, source_bytes: u32, source_sha256: [64]u8 };
pub const sample_508_sha256 = "f3dbbc74cddb415836dcf2b07a8cbfd89f12ce016eef9e0d1e5b60accce8378c";
pub const sample_547_sha256 = "f5b60a2aed7dd7104c6e640eae28f0ceeda4d0e295ade190adba2bbca10df1dc";
/// Verify source bytes; the caller binds generation to the authenticated bank.
pub fn verifySample(bank_generation: u64, bytes: []const u8) !SampleReceipt {
    return verifyCueSample(0x506, bank_generation, bytes);
}
pub fn verifyCueSample(command: u16, bank_generation: u64, bytes: []const u8) !SampleReceipt {
    const expected: struct { length: usize, sha: []const u8 } = switch (command) {
        0x506 => .{ .length = 2512, .sha = sample_sha256 },
        0x508 => .{ .length = 4256, .sha = sample_508_sha256 },
        0x547 => .{ .length = 13168, .sha = sample_547_sha256 },
        else => return error.UnsupportedDirectVoiceRequest,
    };
    if (bank_generation == 0 or bytes.len != expected.length) return error.InvalidDirectSampleReceipt;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, expected.sha)) return error.InvalidDirectSampleReceipt;
    return .{ .bank_generation = bank_generation, .source_bytes = @intCast(bytes.len), .source_sha256 = hex };
}
pub const Sample = struct { bank: requests.Bank, generation: u64, index: u8, source_sha256: [64]u8 };
pub const Image = struct { left: u16, right: u16, pitch: u16, sample: ?Sample, adsr1: u16, adsr2: u16 };
pub const Transition = struct { active: i16, delta: i16, period: i16, countdown: i16, current: i16, target: i16 };
/// Source writes compact program rank and tone subindex separately at
/// 80157A80/80157ACC. STAY p0 is compact rank0; note30 is record5
/// (VA offset820 + 5*20 = 8C0), independently of its sample index5.
pub const ToneId = struct { bank: requests.Bank, generation: u64, program: u8, note: u8, sample: u8, compact_program_rank: u8, tone_subindex: u8 };
/// Caller supplies every field. Existing transitions are retained: source
/// direct note setup does not clear their active/countdown/current fields.
pub const State = struct {
    voices: requests.ExternalVoiceState,
    images: [history.voice_count]Image,
    pitches: [history.voice_count]u16,
    tones: [history.voice_count]?ToneId,
    dirty: [history.voice_count]u8,
    volume_transitions: [history.voice_count]Transition,
    pan_transitions: [history.voice_count]Transition,
    noise_enabled: u32,
    reverb_enabled: u32,
    cd_input: [2]u16,
    adsr2_bias: u16,
    revision: u64,
    receipt: u64,
};
pub const Proposal = struct {
    token: u64,
    before: State,
    after: State,
    matched: u32,
    allocation: u8,
    noise_disable_all: bool,
    cd_input_muted: bool,
};
/// Confirms the pure staging result only; not a field-event or playback receipt.
pub const Receipt = struct {
    token: u64,
    revision: u64,
    checkpoint: u64,
    matched: u32,
    allocation: u8,
    noise_disable_all: bool,
    cd_input_muted: bool,
    sample: ?SampleReceipt,
};
fn bit(index: usize) u32 {
    return @as(u32, 1) << @intCast(index);
}
fn matches(key: requests.VoiceKey, selector: requests.Selector) bool {
    return key.owner == selector.owner and key.slot == selector.slot and key.program == selector.program and key.note == selector.note;
}
pub const Owner = struct {
    state: State,
    pub fn restore(state: State) !Owner {
        _ = try history.Owner.restore(state.voices.allocator);
        if (state.voices.checkpoint == 0 or state.voices.callback_token == 0 or (state.revision == 0) != (state.receipt == 0)) return error.InvalidDirectVoiceState;
        if ((state.noise_enabled | state.reverb_enabled | state.voices.pending_key_on | state.voices.pending_key_off) & 0xff000000 != 0) return error.InvalidDirectVoiceState;
        return .{ .state = state };
    }
    /// Caller must derive Prepared from requests.prepare against its current
    /// authenticated bank owner and source saved level; matching scalar fields
    /// here do not authenticate caller-created Prepared values. Caller also
    /// authenticates the actual ordered callback snapshot and its sample clock,
    /// all retained voice fields, and the decoded sample's binding to the source
    /// fingerprint/generation. SampleReceipt only checks that reported metadata
    /// agrees; it does not hash sample bytes or prove a callback occurred.
    pub fn propose(self: Owner, prepared: requests.Prepared, resource: ?SampleReceipt, token: u64) !Proposal {
        _ = try restore(self.state);
        if (token == 0 or token <= self.state.receipt or token <= self.state.voices.allocator.receipt) return error.StaleDirectVoiceReceipt;
        if (!std.meta.eql(prepared.voices, self.state.voices)) return error.StaleVoiceCallbackState;
        const d = prepared.decoded;
        const Cue = struct { selector: requests.Selector, tone: requests.Tone, bank: requests.Bank, pitch: u16, rank: u8, tone_index: u8, length: u32, sha: []const u8 };
        const cue: Cue = switch (d.command) {
            0x506 => .{ .selector = .{ .slot = 0, .program = 0, .note = 30 }, .tone = .{ .sample = 5, .center = 54, .shift = 0 }, .bank = .stay, .pitch = 1024, .rank = 0, .tone_index = 5, .length = 2512, .sha = sample_sha256 },
            0x508 => .{ .selector = .{ .slot = 0, .program = 0, .note = 32 }, .tone = .{ .sample = 7, .center = 61, .shift = 70 }, .bank = .stay, .pitch = 789, .rank = 0, .tone_index = 7, .length = 4256, .sha = sample_508_sha256 },
            0x547 => .{ .selector = .{ .slot = 2, .program = 1, .note = 27 }, .tone = .{ .sample = 2, .center = 44, .shift = 70 }, .bank = .a13, .pitch = 1579, .rank = 1, .tone_index = 2, .length = 13168, .sha = sample_547_sha256 },
            else => return error.UnsupportedDirectVoiceRequest,
        };
        if (!std.meta.eql(d.selector, cue.selector) or d.pan != 64 or d.level < 20 or d.level > 32767) return error.UnsupportedDirectVoiceRequest;
        const stop_only = d.command == 0x547 and prepared.resident.bank == .a12;
        if (prepared.resident.generation == 0 or (!stop_only and prepared.resident.bank != cue.bank)) return error.MissingDirectToneInput;
        if (stop_only) {
            if (prepared.tone != null or resource != null) return error.InvalidDirectSampleReceipt;
        } else {
            if (prepared.tone == null or !std.meta.eql(prepared.tone.?, cue.tone)) return error.MissingDirectToneInput;
            const sample = resource orelse return error.MissingDirectSampleInput;
            if (sample.bank_generation != prepared.resident.generation or sample.source_bytes != cue.length or !std.mem.eql(u8, &sample.source_sha256, cue.sha)) return error.InvalidDirectSampleReceipt;
        }
        var next = self.state;
        var matched: u32 = 0;
        var cd_muted = false;
        // The source matches owner/bank/program/note even when status is zero.
        for (&next.voices.keys, 0..) |*key, i| {
            if (!matches(key.*, cue.selector)) continue;
            matched |= bit(i);
            next.voices.allocator.voices[i].status = 0;
            next.pitches[i] = 0;
            if (key.sample == 0xff) {
                next.cd_input = .{ 0, 0 };
                cd_muted = true;
            } else {
                key.sample = 0;
                next.voices.pending_key_off |= bit(i);
                next.voices.pending_key_on &= ~next.voices.pending_key_off;
            }
        }
        var choice: u8 = history.voice_count;
        var noise_disabled = false;
        if (!stop_only) {
            const allocator = try history.Owner.restore(next.voices.allocator);
            const allocation = try allocator.proposeAllocation(token, cue.tone.priority);
            choice = allocation.choice;
            noise_disabled = allocation.noise_off != 0;
        }
        if (choice < history.voice_count) {
            const sample = resource.?;
            if (noise_disabled) next.noise_enabled = 0;
            for (&next.voices.allocator.voices) |*voice| voice.age +%= 1;
            next.voices.allocator.voices[choice].age = 0;
            next.voices.allocator.voices[choice].priority = cue.tone.priority;
            next.voices.allocator.voices[choice].status = 1;
            next.voices.allocator.voices[choice].level = 32767;
            for (&next.voices.allocator.history) |*mask| mask.* &= ~bit(choice);
            next.voices.keys[choice] = .{ .owner = cue.selector.owner, .slot = cue.selector.slot, .program = cue.selector.program, .note = cue.selector.note, .sample = @as(i16, cue.tone.sample) + 1 };
            next.pitches[choice] = cue.pitch;
            next.tones[choice] = .{ .bank = cue.bank, .generation = sample.bank_generation, .program = cue.selector.program, .note = cue.selector.note, .sample = cue.tone.sample, .compact_program_rank = cue.rank, .tone_subindex = cue.tone_index };
            // SDK stores level as a byte before gain setup. All three pans64
            // and all source volumes127 make both direct levels identical.
            const level: u32 = @as(u8, @truncate(d.level));
            const linear = 129 * level;
            const gain: u16 = @truncate(linear * linear / 16383);
            next.images[choice] = .{ .left = gain, .right = gain, .pitch = cue.pitch, .sample = .{ .bank = cue.bank, .generation = sample.bank_generation, .index = cue.tone.sample, .source_sha256 = sample.source_sha256 }, .adsr1 = 0x80ff, .adsr2 = 0x1fc0 +% next.adsr2_bias };
            next.dirty[choice] |= 0x3f;
            next.reverb_enabled &= ~bit(choice);
            next.voices.pending_key_on |= bit(choice);
            next.voices.pending_key_off &= ~next.voices.pending_key_on;
        }
        next.revision = std.math.add(u64, next.revision, 1) catch return error.DirectVoiceRevisionExhausted;
        next.receipt = token;
        next.voices.allocator.revision = std.math.add(u64, next.voices.allocator.revision, 1) catch return error.VoiceRevisionExhausted;
        next.voices.allocator.receipt = token;
        return .{ .token = token, .before = self.state, .after = next, .matched = matched, .allocation = choice, .noise_disable_all = noise_disabled, .cd_input_muted = cd_muted };
    }
    /// Commit authenticates agreement with this staged proposal only. The
    /// caller owns bank/callback/sample provenance and every field-event receipt;
    /// this receipt cannot establish playback or acknowledge an event.
    pub fn commit(self: *Owner, prepared: requests.Prepared, resource: ?SampleReceipt, proposal: Proposal, receipt: Receipt) !void {
        if (!std.meta.eql(self.state, proposal.before)) return error.StaleDirectVoiceState;
        const expected = try self.propose(prepared, resource, proposal.token);
        if (!std.meta.eql(expected, proposal) or receipt.token != proposal.token or receipt.revision != self.state.revision or receipt.checkpoint != self.state.voices.checkpoint or receipt.matched != expected.matched or receipt.allocation != expected.allocation or receipt.noise_disable_all != expected.noise_disable_all or receipt.cd_input_muted != expected.cd_input_muted or !std.meta.eql(receipt.sample, resource)) return error.InvalidDirectVoiceReceipt;
        self.state = expected.after;
    }
};
