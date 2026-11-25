//! Source-derived 22-voice allocation and 16-slot silence history.
//! No mixer, envelope clock, bank/tone dispatch, or audio playback is owned here.
const std = @import("std");
pub const voice_count = 22;
pub const Voice = struct { status: u8 = 0, level: u16 = 0, priority: u16 = 0, age: u16 = 0 };
pub const State = struct {
    voices: [voice_count]Voice = @splat(.{}),
    history: [16]u32 = @splat(0),
    index: u8 = 0,
    revision: u64 = 0,
    receipt: u64 = 0,
};
/// Each set bit confirms the caller completed the source status-2 noise-off
/// callback for that voice. Source callback arguments are (0, 0xFFFFFF).
pub const Receipt = struct { token: u64, revision: u64, noise_off: u32 = 0 };
pub const Poll = struct {
    token: u64,
    revision: u64,
    levels: [voice_count]u16,
    inhibit: bool,
    noise_off: u32,
};
pub const Allocation = struct {
    token: u64,
    revision: u64,
    priority: u8,
    /// 22 or 99 are source out-of-range results; neither allocates a voice.
    choice: u8,
    noise_off: u32,
};
pub const Reset = struct { token: u64, revision: u64, voice: u8 };

pub const Owner = struct {
    state: State = .{},
    pub fn restore(snapshot: State) !Owner {
        if (snapshot.index >= 16 or (snapshot.revision == 0) != (snapshot.receipt == 0)) return error.InvalidVoiceHistorySnapshot;
        return .{ .state = snapshot };
    }
    fn next(self: Owner, token: u64) !u64 {
        _ = try restore(self.state);
        if (token == 0 or token <= self.state.receipt) return error.StaleVoiceReceipt;
        return std.math.add(u64, self.state.revision, 1) catch error.VoiceRevisionExhausted;
    }
    fn bit(index: usize) u32 {
        return @as(u32, 1) << @intCast(index);
    }
    fn signed(value: u16) i32 {
        return @as(i16, @bitCast(value));
    }

    pub fn proposePoll(self: Owner, token: u64, levels: []const u16, inhibit: bool) !Poll {
        _ = try self.next(token);
        if (levels.len != voice_count) return error.InvalidVoiceSamples;
        var samples: [voice_count]u16 = undefined;
        @memcpy(&samples, levels);
        const index = (self.state.index + 1) & 15;
        var sample_mask: u32 = 0;
        for (samples, 0..) |level, i| if (level == 0) {
            sample_mask |= bit(i);
        };
        var quiet: u32 = std.math.maxInt(u32);
        for (self.state.history[0..15], 0..) |mask, i| quiet &= if (i == index) sample_mask else mask;
        var noise_off: u32 = 0;
        if (!inhibit) for (self.state.voices, 0..) |v, i| {
            if (quiet & bit(i) != 0 and v.status == 2) noise_off |= bit(i);
        };
        return .{ .token = token, .revision = self.state.revision, .levels = samples, .inhibit = inhibit, .noise_off = noise_off };
    }
    pub fn commitPoll(self: *Owner, proposal: Poll, receipt: Receipt) !void {
        const expected = try self.proposePoll(proposal.token, &proposal.levels, proposal.inhibit);
        if (!std.meta.eql(expected, proposal) or receipt.token != proposal.token or receipt.revision != proposal.revision or receipt.noise_off != expected.noise_off) return error.InvalidVoiceReceipt;
        const revision = try self.next(proposal.token);
        var next_state = self.state;
        next_state.index = (next_state.index + 1) & 15;
        var mask: u32 = 0;
        for (&next_state.voices, proposal.levels, 0..) |*v, level, i| {
            v.level = level;
            if (level == 0) mask |= bit(i);
        }
        next_state.history[next_state.index] = mask;
        var quiet: u32 = std.math.maxInt(u32);
        for (next_state.history[0..15]) |entry| quiet &= entry;
        if (!proposal.inhibit) for (&next_state.voices, 0..) |*v, i| {
            if (quiet & bit(i) != 0) v.status = 0;
        };
        next_state.revision = revision;
        next_state.receipt = proposal.token;
        self.state = next_state;
    }

    pub fn proposeAllocation(self: Owner, token: u64, priority: u8) !Allocation {
        _ = try self.next(token);
        var chosen: u8 = 99;
        var ties: u8 = 0;
        var best_priority: i32 = priority;
        var best_level: u16 = 65535;
        var best_age: i32 = 0;
        for (self.state.voices, 0..) |voice, i| {
            if (voice.status == 0 and voice.level == 0) {
                chosen = @intCast(i);
                break;
            }
            const old = signed(voice.priority);
            if (old < best_priority) {
                best_priority = voice.priority;
                chosen = @intCast(i);
                best_level = voice.level;
                best_age = voice.age;
                ties = 1;
            } else if (old == best_priority) {
                ties += 1;
                const age = signed(voice.age);
                if (voice.level < best_level) {
                    chosen = @intCast(i);
                    best_level = voice.level;
                    best_age = voice.age;
                } else if (voice.level == best_level and best_age < age) {
                    chosen = @intCast(i);
                    best_age = age;
                }
            }
        }
        if (chosen == 99 and ties == 0) chosen = voice_count;
        const noise_off: u32 = if (chosen < voice_count and self.state.voices[chosen].status == 2) bit(chosen) else 0;
        return .{ .token = token, .revision = self.state.revision, .priority = priority, .choice = chosen, .noise_off = noise_off };
    }
    pub fn commitAllocation(self: *Owner, proposal: Allocation, receipt: Receipt) !void {
        const expected = try self.proposeAllocation(proposal.token, proposal.priority);
        if (!std.meta.eql(expected, proposal) or receipt.token != proposal.token or receipt.revision != proposal.revision or receipt.noise_off != expected.noise_off) return error.InvalidVoiceReceipt;
        const revision = try self.next(proposal.token);
        var next_state = self.state;
        if (proposal.choice < voice_count) {
            for (&next_state.voices) |*v| v.age +%= 1;
            next_state.voices[proposal.choice].age = 0;
            next_state.voices[proposal.choice].priority = proposal.priority;
        }
        next_state.revision = revision;
        next_state.receipt = proposal.token;
        self.state = next_state;
    }
    /// Note staging clears that voice's bit in all 16 quiet-history slots.
    pub fn proposeReset(self: Owner, token: u64, voice: u8) !Reset {
        _ = try self.next(token);
        if (voice >= voice_count) return error.InvalidVoiceIndex;
        return .{ .token = token, .revision = self.state.revision, .voice = voice };
    }
    pub fn commitReset(self: *Owner, proposal: Reset, receipt: Receipt) !void {
        const expected = try self.proposeReset(proposal.token, proposal.voice);
        if (!std.meta.eql(expected, proposal) or receipt.token != proposal.token or receipt.revision != proposal.revision or receipt.noise_off != 0) return error.InvalidVoiceReceipt;
        const revision = try self.next(proposal.token);
        var next_state = self.state;
        for (&next_state.history) |*mask| mask.* &= ~bit(proposal.voice);
        next_state.revision = revision;
        next_state.receipt = proposal.token;
        self.state = next_state;
    }
    /// Status is supplied by the separate source note/key owner; no sound or
    /// envelope progress is inferred. It must validate its producer receipt.
    pub fn commitStatus(self: *Owner, token: u64, expected_revision: u64, voice: u8, status: u8) !void {
        const revision = try self.next(token);
        if (expected_revision != self.state.revision) return error.InvalidVoiceReceipt;
        if (voice >= voice_count) return error.InvalidVoiceIndex;
        var next_state = self.state;
        next_state.voices[voice].status = status;
        next_state.revision = revision;
        next_state.receipt = token;
        self.state = next_state;
    }
};
