//! US v1.1 MAIN sound request decoding and confirmed New Game bank residency.
//! Static anchors: startup callback 800C97B4/800C9B80, table 80165884;
//! field bank selection 80131218..78, table 80170064; bank slot byte
//! 800C75B4/800C76B0; direct request table 801651BC and worker 800C5830.
//! MAIN body SHA256 e123263c3046a7283d8ca26598185672ed3f8de72d97f5efb0ee8e88ccaa55fa.
//! No callback timing, voice mutation, playback or event acknowledgement.
const history = @import("voice_history.zig");
pub const Bank = enum { stay, orch, a13, a12 };
const load_order = [_]Bank{ .stay, .orch, .a13, .a12 };
pub fn bankRequest(bank: Bank) u8 {
    return switch (bank) {
        .stay => 0x21,
        .orch => 0x25,
        .a13 => 0x32,
        .a12 => 0x31,
    };
}
pub fn bankSlot(bank: Bank) u8 {
    return switch (bank) {
        .stay => 0,
        .orch => 1,
        .a13, .a12 => 2,
    };
}
pub const Resident = struct { bank: Bank, generation: u64 };
pub const Pending = struct { bank: Bank, token: u64 };
pub const State = struct {
    residents: [3]?Resident = @splat(null),
    completed: u8 = 0,
    pending: ?Pending = null,
    last_token: u64,
};
/// Caller confirms the actual source sound reset, not merely port startup.
pub const ResetReceipt = struct { token: u64 };
/// Caller confirms target-slot close at 800C75B8 has completed.
pub const BeginReceipt = struct { request: u8, token: u64, closed_slot: u8 };
/// Caller confirms both header and complete body transfer; header status 2
/// alone is not residency (8015B124/80154C5C/80159AB0).
pub const TransferReceipt = struct { request: u8, token: u64 };
pub const Owner = struct {
    state: State,
    pub fn afterReset(receipt: ResetReceipt) !Owner {
        if (receipt.token == 0) return error.InvalidSoundResetReceipt;
        return .{ .state = .{ .last_token = receipt.token } };
    }
    pub fn restore(state: State) !Owner {
        if (state.last_token == 0 or state.completed > load_order.len) return error.InvalidSoundBankState;
        var expected: [3]?Bank = @splat(null);
        for (load_order[0..state.completed]) |bank| expected[bankSlot(bank)] = bank;
        if (state.pending) |pending| {
            if (state.completed == load_order.len or pending.bank != load_order[state.completed] or pending.token != state.last_token) return error.InvalidSoundBankState;
            expected[bankSlot(pending.bank)] = null;
        }
        var previous: u64 = 0;
        for (state.residents, expected) |resident, bank| {
            if ((resident == null) != (bank == null)) return error.InvalidSoundBankState;
            if (resident) |value| {
                if (value.bank != bank.? or value.generation <= previous or value.generation > state.last_token) return error.InvalidSoundBankState;
                if (state.pending != null and value.generation == state.last_token) return error.InvalidSoundBankState;
                previous = value.generation;
            }
        }
        return .{ .state = state };
    }
    pub fn confirmBegin(self: *Owner, receipt: BeginReceipt) !void {
        _ = try restore(self.state);
        if (self.state.pending != null) return error.SoundTransferPending;
        if (self.state.completed == load_order.len) return error.UnsupportedSoundBankRequest;
        const bank = load_order[self.state.completed];
        if (receipt.request != bankRequest(bank) or receipt.closed_slot != bankSlot(bank)) return error.InvalidSoundBankReceipt;
        if (receipt.token <= self.state.last_token) return error.StaleSoundBankReceipt;
        var next = self.state;
        next.residents[bankSlot(bank)] = null;
        next.pending = .{ .bank = bank, .token = receipt.token };
        next.last_token = receipt.token;
        self.state = next;
    }
    pub fn confirmTransfer(self: *Owner, receipt: TransferReceipt) !void {
        _ = try restore(self.state);
        const pending = self.state.pending orelse return error.NoSoundTransferPending;
        if (receipt.request != bankRequest(pending.bank) or receipt.token != pending.token) return error.InvalidSoundBankReceipt;
        var next = self.state;
        next.residents[bankSlot(pending.bank)] = .{ .bank = pending.bank, .generation = pending.token };
        next.completed += 1;
        next.pending = null;
        self.state = next;
    }
};
pub const Selector = struct { slot: u8, program: u8, note: u8, owner: u8 = 0x21 };
pub const Decoded = struct { command: u16, selector: Selector, level: u16, pan: u8 = 64 };
/// Table bytes: 547=01 02 1B 1E; 508=00 00 20 14; 506=00 00 1E 00.
/// 800C58E0..590C wraps the saved-level addition, sign compares and clamps.
pub fn decode(command: u16, saved_level: u16) !Decoded {
    const row: struct { selector: Selector, offset: u16 } = switch (command) {
        0x547 => .{ .selector = .{ .slot = 2, .program = 1, .note = 27 }, .offset = 30 },
        0x508 => .{ .selector = .{ .slot = 0, .program = 0, .note = 32 }, .offset = 20 },
        0x506 => .{ .selector = .{ .slot = 0, .program = 0, .note = 30 }, .offset = 0 },
        else => return error.UnsupportedDirectSoundRequest,
    };
    const level: i16 = @bitCast(saved_level +% row.offset);
    return .{ .command = command, .selector = row.selector, .level = if (level < 20) 20 else @intCast(level) };
}
pub const VoiceKey = struct { owner: i16, slot: i16, program: i16, note: i16, sample: i16 };
/// Supplied by a separate callback/note owner. No default, fabricated empty
/// state or conversion from scene_ticks is provided. The caller owns elapsed
/// sample progression, sampler/flush ordering and these identities/key masks.
pub const ExternalVoiceState = struct {
    checkpoint: u64,
    callback_token: u64,
    sample_clock: u64,
    allocator: history.State,
    keys: [history.voice_count]VoiceKey,
    pending_key_on: u32,
    pending_key_off: u32,
};
/// Source VAB selection: STAY p0 note30 VAG5, note32 VAG7; A13 p1 note27 VAG2.
/// STAY.VA SHA256 95051a43cf81d4303633d91379a08e45e13f03e33320bb7b14d2b3b666109952,
/// tone offsets 0x8c0 and 0x900; A13.VA SHA256
/// e114090195326edcc7090150400d844da010d23aa9a88fd3628301f07f5e3624,
/// tone offset 0xa60. Header and program records supply volume/pan.
/// A12 p1 has no note27 tone. It still needs the stop selector processed first.
/// Sequence-opening readiness is a separate caller-owned prerequisite.
pub const Tone = struct { sample: u8, center: u8, shift: u8, priority: u8 = 15, bank_volume: u8 = 127, program_volume: u8 = 127, tone_volume: u8 = 127, program_pan: u8 = 64, tone_pan: u8 = 64, adsr1: u16 = 0x80ff, adsr2: u16 = 0x1fc0 };
pub const Prepared = struct {
    decoded: Decoded,
    resident: Resident,
    tone: ?Tone,
    voices: ExternalVoiceState,
};
/// Returns an unapplied stop-then-start intent. Even a null start tone still
/// requires the external owner to perform matching key-off before any receipt.
/// This function cannot acknowledge scenery, an event, or audio playback.
pub fn prepare(owner: Owner, command: u16, saved_level: u16, checkpoint: u64, voices: ?ExternalVoiceState) !Prepared {
    _ = try Owner.restore(owner.state);
    const decoded = try decode(command, saved_level);
    const resident = owner.state.residents[decoded.selector.slot] orelse return error.SoundBankUnavailable;
    const external = voices orelse return error.MissingVoiceCallbackState;
    if (checkpoint == 0 or external.checkpoint != checkpoint or external.callback_token == 0) return error.StaleVoiceCallbackState;
    _ = try history.Owner.restore(external.allocator);
    if ((external.pending_key_on | external.pending_key_off) & 0xff000000 != 0) return error.InvalidVoiceKeyMasks;
    const tone: ?Tone = switch (command) {
        0x506 => if (resident.bank == .stay) .{ .sample = 5, .center = 54, .shift = 0 } else return error.MissingSoundToneInput,
        0x508 => if (resident.bank == .stay) .{ .sample = 7, .center = 61, .shift = 70 } else return error.MissingSoundToneInput,
        0x547 => switch (resident.bank) {
            .a13 => .{ .sample = 2, .center = 44, .shift = 70 },
            .a12 => null,
            else => return error.MissingSoundToneInput,
        },
        else => unreachable,
    };
    return .{ .decoded = decoded, .resident = resident, .tone = tone, .voices = external };
}
