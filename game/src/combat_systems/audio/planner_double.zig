//! Planner protocol placeholder and conformance double.
//!
//! **This file is not a full audio playback planner.**  The double implements
//! only the host-facing shapes the audio contract documents -- bounded queue
//! with dedupe/append, three bank busy gates, the transfer phase/token machine,
//! score start/stop ordering, voice ownership and sequence open -- over the
//! projected plan data.  It decodes no bank, plays nothing and cannot accept a
//! token the host did not receive.
//!
//! `Unbound` is the honest state of this campaign: every modeled request
//! returns `error.PlannerUnbound`, the host records it as pending and the scene
//! is never acknowledged until connected to an accepted `audio_request_contracts.Engine`.

const std = @import("std");
const events = @import("events.zig");
const plan = @import("plan.zig");

pub const Loader = enum { none, bank, sequence };

pub const Phase = enum {
    idle,
    requested,
    header_transfer,
    header_dma,
    header_open,
    body_transfer,
    body_dma,
    body_commit,
    sequence_transfer,
    sequence_dma,
    sequence_open,
};

const Voice = struct {
    active: bool = false,
    owner: events.VoiceOwner = .free,
};

const DoubleState = struct {
    queue: [31]u8,
    loader: Loader,
    phase: Phase,
    request: u8,
    generation: u32,
    remaining: u32,
    chunk: u32,
    resident: [3]?u8,
    selected: u8,
    desired: u8,
    sequences_open: bool,
    voices: [24]Voice,
    cue_context: ?u8,
};

pub const Unbound = struct {
    pub const Snapshot = void;

    pub fn requestBank(self: *Unbound, request: u8, effects: *events.PlanEffects) !events.Outcome {
        _ = self;
        _ = request;
        _ = effects;
        return error.PlannerUnbound;
    }

    pub fn requestScore(self: *Unbound, cue: u8, effects: *events.PlanEffects) !void {
        _ = self;
        _ = cue;
        _ = effects;
        return error.PlannerUnbound;
    }

    pub fn requestVolume(self: *Unbound, command: u16, configured: u16, effects: *events.PlanEffects) !void {
        _ = self;
        _ = command;
        _ = configured;
        _ = effects;
        return error.PlannerUnbound;
    }

    pub fn requestCue(self: *Unbound, operand: u16, effects: *events.PlanEffects) !void {
        _ = self;
        _ = operand;
        _ = effects;
        return error.PlannerUnbound;
    }

    pub fn requestSequenceOpen(self: *Unbound, effects: *events.PlanEffects) !void {
        _ = self;
        _ = effects;
        return error.PlannerUnbound;
    }

    pub fn service(self: *Unbound, effects: *events.PlanEffects) !void {
        _ = self;
        _ = effects;
        return error.PlannerUnbound;
    }

    pub fn pending(self: *const Unbound) ?events.Pending {
        _ = self;
        return null;
    }

    pub fn pendingSequence(self: *const Unbound) ?events.Pending {
        _ = self;
        return null;
    }

    pub fn complete(self: *Unbound, token: events.Token, effects: *events.PlanEffects) !void {
        _ = self;
        _ = token;
        _ = effects;
        return error.PlannerUnbound;
    }

    pub fn completeSequence(self: *Unbound, token: events.Token, effects: *events.PlanEffects) !void {
        _ = self;
        _ = token;
        _ = effects;
        return error.PlannerUnbound;
    }

    pub fn stopCueContext(self: *Unbound, effects: *events.PlanEffects) !void {
        _ = self;
        _ = effects;
    }

    pub fn voiceActive(self: *const Unbound, index: usize) bool {
        _ = self;
        _ = index;
        return false;
    }

    pub fn activeVoices(self: *const Unbound) usize {
        _ = self;
        return 0;
    }

    pub fn activeSequenceVoices(self: *const Unbound) usize {
        _ = self;
        return 0;
    }

    pub fn generationValue(self: *const Unbound) u32 {
        _ = self;
        return 0;
    }

    pub fn snapshot(self: *const Unbound) Snapshot {
        _ = self;
        return {};
    }

    pub fn restore(self: *Unbound, state: Snapshot) !void {
        _ = self;
        _ = state;
    }
};

pub const Double = struct {
    pub const Snapshot = DoubleState;

    plan: *const plan.Projection,
    queue: [31]u8 = @splat(0),
    sentinel: u8 = 0,
    loader: Loader = .none,
    phase: Phase = .idle,
    request: u8 = 0,
    generation: u32 = 0,
    remaining: u32 = 0,
    chunk: u32 = 0,
    resident: [3]?u8 = .{ null, null, null },
    selected: u8 = 0,
    desired: u8 = 0,
    sequences_open: bool = false,
    voices: [24]Voice = @splat(.{}),
    cue_context: ?u8 = null,

    pub fn init(projection: *const plan.Projection) Double {
        var self = Double{ .plan = projection };
        self.voices[22] = .{ .active = true, .owner = .{ .direct = 22 } };
        self.voices[23] = .{ .active = true, .owner = .{ .direct = 23 } };
        return self;
    }

    fn bankRecord(self: *const Double, request: u8) ?*const plan.Bank {
        for (self.plan.banks) |*row| if (row.request == request) return row;
        return null;
    }

    fn scoreRecord(self: *const Double, cue: u8) ?*const plan.Score {
        for (self.plan.scores) |*row| if (row.cue == cue) return row;
        return null;
    }

    fn enqueue(self: *Double, action: u8) !void {
        if (action < self.plan.queue.action_min or action > self.plan.queue.action_max) {
            return error.UnknownAction;
        }
        var index: usize = self.plan.queue.dedupe_first;
        while (index <= self.plan.queue.dedupe_last) : (index += 1) {
            if (self.queue[index] == action) {
                var shift = index;
                while (shift < self.plan.queue.dequeue_copies) : (shift += 1) {
                    self.queue[shift] = self.queue[shift + 1];
                }
                self.sentinel = 0;
            }
        }
        index = self.plan.queue.append_first;
        while (index <= self.plan.queue.append_last) : (index += 1) {
            if (self.queue[index] == 0) {
                self.queue[index] = action;
                return;
            }
        }
        return error.QueueFull;
    }

    fn dequeue(self: *Double) ?u8 {
        const head = self.queue[0];
        if (head == 0) return null;
        var index: usize = 0;
        while (index < self.plan.queue.dequeue_copies) : (index += 1) {
            self.queue[index] = self.queue[index + 1];
        }
        return head;
    }

    pub fn requestBank(self: *Double, request: u8, effects: *events.PlanEffects) !events.Outcome {
        _ = effects;
        const record = self.bankRecord(request) orelse return error.UnknownResource;
        if (self.loader != .none or self.cue_context != null) return .gated;
        try self.enqueue(7);
        self.request = request;
        self.generation +%= 1;
        self.loader = .bank;
        self.phase = .requested;
        self.remaining = record.request_bytes;
        self.chunk = 0;
        return .accepted;
    }

    pub fn requestScore(self: *Double, cue: u8, effects: *events.PlanEffects) !void {
        _ = self.scoreRecord(cue) orelse return error.UnknownScore;
        self.desired = cue;
        if (self.selected == cue) return;
        if (self.cue_context) |active| {
            try effects.push(.{ .cue_context_stop = .{ .cue = active } });
            self.cue_context = null;
        }
        if (self.selected != 0) try self.enqueue(4);
        try self.enqueue(1);
    }

    pub fn requestVolume(self: *Double, command: u16, configured: u16, effects: *events.PlanEffects) !void {
        if (configured > 24) return error.InvalidVoiceCount;
        if (command != 0x00B0 and command != 0x00B1) return error.UnknownRequest;
        if (command == 0x00B0) {
            for (0..4) |index| self.voices[index].active = false;
            try effects.push(.{ .voice_reset = .{ .count = configured } });
        }
    }

    pub fn requestCue(self: *Double, operand: u16, effects: *events.PlanEffects) !void {
        const family_index: u8 = @intCast(operand >> 8);
        var found: ?*const plan.Family = null;
        for (self.plan.families) |*row| if (row.family == family_index) {
            found = row;
            break;
        };
        const family = found orelse return error.UnknownRequest;
        if (!std.mem.eql(u8, family.planner, "cue_request")) return error.UnmodeledFamily;
        var admitted = false;
        for (self.plan.cue_operands) |value| if (value == operand) {
            admitted = true;
            break;
        };
        if (!admitted) return error.UnadmittedCueOperand;
        try effects.push(.{ .cue_request = .{ .operand = operand } });
    }

    pub fn requestSequenceOpen(self: *Double, effects: *events.PlanEffects) !void {
        _ = effects;
        if (self.loader != .none) return error.LoaderBusy;
        try self.enqueue(self.plan.sequence_open.action);
        self.generation +%= 1;
        self.loader = .sequence;
        self.phase = .requested;
        self.chunk = 0;
    }

    fn tokenKindForPhase(phase: Phase) ?events.TokenKind {
        return switch (phase) {
            .header_transfer, .body_transfer => .transfer_ready,
            .header_dma, .body_dma => .dma_ready,
            .body_commit => .commit_ready,
            else => null,
        };
    }

    pub fn pending(self: *const Double) ?events.Pending {
        if (self.loader != .bank) return null;
        const kind = tokenKindForPhase(self.phase) orelse return null;
        return .{
            .kind = kind,
            .request = self.request,
            .generation = self.generation,
            .chunk = self.chunk,
            .phase = @tagName(self.phase),
        };
    }

    pub fn pendingSequence(self: *const Double) ?events.Pending {
        if (self.loader != .sequence) return null;
        const kind: events.TokenKind = switch (self.phase) {
            .sequence_transfer => .transfer_ready,
            .sequence_dma => .dma_ready,
            else => return null,
        };
        return .{
            .kind = kind,
            .request = 0,
            .generation = self.generation,
            .chunk = 0,
            .phase = @tagName(self.phase),
        };
    }

    pub fn service(self: *Double, effects: *events.PlanEffects) !void {
        if (self.loader == .sequence) {
            switch (self.phase) {
                .requested => self.phase = .sequence_transfer,
                .sequence_open => {
                    try effects.push(.{ .sequences_open = {} });
                    self.sequences_open = true;
                    self.loader = .none;
                    self.phase = .idle;
                    _ = self.dequeue();
                    for (0..4) |index| {
                        self.voices[index] = .{ .active = true, .owner = .{ .sequence = @intCast(index) } };
                    }
                },
                else => {},
            }
            return;
        }
        const head = self.queue[0];
        if (head == 0) return;
        switch (head) {
            1 => {
                const row = self.scoreRecord(self.desired) orelse return error.NoDesiredScore;
                if (self.loader != .none or !self.sequences_open) return error.ScoreNotAdmissible;
                if (self.resident[row.slot] == null) return error.BankNotResident;
                try effects.push(.{ .score_play = .{ .cue = row.cue, .slot = row.slot } });
                try effects.push(.{ .score_select = .{ .cue = row.cue } });
                self.selected = row.cue;
                _ = self.dequeue();
            },
            4 => {
                for (0..4) |owner| {
                    try effects.push(.{ .score_release = .{ .owner = @intCast(owner) } });
                    for (&self.voices) |*voice| {
                        if (!voice.active) continue;
                        switch (voice.owner) {
                            .sequence => |value| {
                                if (value == @as(u8, @intCast(owner))) voice.active = false;
                            },
                            else => {},
                        }
                    }
                }
                self.selected = 0;
                try effects.push(.{ .score_clear = {} });
                _ = self.dequeue();
            },
            5 => _ = self.dequeue(),
            7 => {
                const row = self.bankRecord(self.request) orelse return error.UnknownResource;
                if (self.phase == .requested) {
                    self.resident[row.slot] = null;
                    try effects.push(.{ .bank_close = .{ .request = row.request, .slot = row.slot } });
                    try effects.push(.{ .bank_header = .{ .request = row.request, .slot = row.slot } });
                    self.phase = .header_transfer;
                } else if (self.phase == .header_open) {
                    self.phase = .body_transfer;
                    try effects.push(.{ .bank_body = .{ .request = row.request, .slot = row.slot, .chunk = self.chunk } });
                }
            },
            8 => {
                if (self.phase == .requested) self.phase = .sequence_transfer;
            },
            else => return error.UnmodeledAction,
        }
    }

    pub fn complete(self: *Double, token: events.Token, effects: *events.PlanEffects) !void {
        if (self.loader != .bank) return error.NoPendingTransfer;
        if (token.request != self.request or token.generation != self.generation) {
            return error.WrongTransferOwner;
        }
        if (token.chunk != self.chunk) return error.WrongTransferChunk;
        const expected = tokenKindForPhase(self.phase) orelse return error.NoPendingTransfer;
        if (token.kind != expected) return error.WrongTransferKind;
        const record = self.bankRecord(self.request) orelse return error.UnknownResource;
        switch (self.phase) {
            .header_transfer => self.phase = .header_dma,
            .header_dma => {
                try effects.push(.{ .bank_open = .{ .request = record.request, .slot = record.slot, .generation = self.generation } });
                self.resident[record.slot] = record.request;
                self.phase = .header_open;
            },
            .body_transfer => self.phase = .body_dma,
            .body_dma => self.phase = .body_commit,
            .body_commit => {
                if (self.remaining > self.plan.chunk_bytes) {
                    self.remaining -= self.plan.chunk_bytes;
                    self.chunk += 1;
                    self.phase = .body_transfer;
                } else {
                    self.remaining = 0;
                    try effects.push(.{ .bank_loaded = .{ .request = record.request, .slot = record.slot, .generation = self.generation } });
                    self.loader = .none;
                    self.phase = .idle;
                    _ = self.dequeue();
                }
            },
            else => return error.NoPendingTransfer,
        }
    }

    pub fn completeSequence(self: *Double, token: events.Token, effects: *events.PlanEffects) !void {
        _ = effects;
        if (self.loader != .sequence) return error.NoPendingTransfer;
        if (token.generation != self.generation or token.chunk != 0) return error.WrongTransferOwner;
        switch (self.phase) {
            .sequence_transfer => {
                if (token.kind != .transfer_ready) return error.WrongTransferKind;
                self.phase = .sequence_dma;
            },
            .sequence_dma => {
                if (token.kind != .dma_ready) return error.WrongTransferKind;
                self.phase = .sequence_open;
            },
            else => return error.NoPendingTransfer,
        }
    }

    pub fn stopCueContext(self: *Double, effects: *events.PlanEffects) !void {
        if (self.cue_context) |active| {
            self.cue_context = null;
            try effects.push(.{ .cue_context_stop = .{ .cue = active } });
        }
    }

    pub fn voiceActive(self: *const Double, index: usize) bool {
        if (index >= self.voices.len) return false;
        return self.voices[index].active;
    }

    pub fn activeVoices(self: *const Double) usize {
        var count: usize = 0;
        for (self.voices) |voice| if (voice.active) {
            count += 1;
        };
        return count;
    }

    pub fn generationValue(self: *const Double) u32 {
        return self.generation;
    }

    pub fn activeSequenceVoices(self: *const Double) usize {
        var count: usize = 0;
        for (self.voices) |voice| {
            if (!voice.active) continue;
            switch (voice.owner) {
                .sequence => count += 1,
                else => {},
            }
        }
        return count;
    }

    pub fn snapshot(self: *const Double) Snapshot {
        return .{
            .queue = self.queue,
            .loader = self.loader,
            .phase = self.phase,
            .request = self.request,
            .generation = self.generation,
            .remaining = self.remaining,
            .chunk = self.chunk,
            .resident = self.resident,
            .selected = self.selected,
            .desired = self.desired,
            .sequences_open = self.sequences_open,
            .voices = self.voices,
            .cue_context = self.cue_context,
        };
    }

    pub fn restore(self: *Double, state: Snapshot) !void {
        for (state.queue) |action| {
            if (action > self.plan.queue.action_max) return error.CorruptState;
        }
        if (state.selected > 4 or state.desired > 4) return error.CorruptState;
        if (state.request != 0 and self.bankRecord(state.request) == null) return error.CorruptState;
        for (state.resident) |slot| if (slot) |request| {
            if (self.bankRecord(request) == null) return error.CorruptState;
        };
        switch (state.loader) {
            .none => if (state.phase != .idle) return error.CorruptState,
            .bank => if (state.phase == .idle) return error.CorruptState,
            .sequence => if (state.phase == .idle) return error.CorruptState,
        }
        for (state.voices) |voice| {
            switch (voice.owner) {
                .sequence => |value| if (value > 3) return error.CorruptState,
                .direct => |value| if (value < 22 or value >= 24) return error.CorruptState,
                .free => {},
            }
        }
        self.* = .{
            .plan = self.plan,
            .queue = state.queue,
            .sentinel = 0,
            .loader = state.loader,
            .phase = state.phase,
            .request = state.request,
            .generation = state.generation,
            .remaining = state.remaining,
            .chunk = state.chunk,
            .resident = state.resident,
            .selected = state.selected,
            .desired = state.desired,
            .sequences_open = state.sequences_open,
            .voices = state.voices,
            .cue_context = state.cue_context,
        };
    }
};
