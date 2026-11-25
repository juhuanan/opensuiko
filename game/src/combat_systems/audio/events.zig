//! Normalised planner events shared by the host and the test double.
//!
//! The host never sees a raw planner `Effect`.  A planner adapter maps each engine effect
//! to one of these named events, so the host can be gated against a double
//! today and bound to the accepted audio engine by module without changing its
//! state machine.

const std = @import("std");

pub const TokenKind = enum { transfer_ready, dma_ready, commit_ready };

pub fn tokenKind(name: []const u8) ?TokenKind {
    return std.meta.stringToEnum(TokenKind, name);
}

pub const Token = struct {
    kind: TokenKind,
    request: u8,
    generation: u32,
    chunk: u32,
};

pub const Pending = struct {
    kind: TokenKind,
    request: u8,
    generation: u32,
    chunk: u32,
    phase: []const u8,
};

pub const Outcome = enum { accepted, gated };

pub const VoiceOwner = union(enum) {
    free,
    sequence: u8,
    direct: u8,
};

pub const Event = union(enum) {
    bank_close: struct { request: u8, slot: u8 },
    bank_header: struct { request: u8, slot: u8 },
    bank_open: struct { request: u8, slot: u8, generation: u32 },
    bank_loaded: struct { request: u8, slot: u8, generation: u32 },
    bank_body: struct { request: u8, slot: u8, chunk: u32 },
    score_play: struct { cue: u8, slot: u8 },
    score_select: struct { cue: u8 },
    score_clear: void,
    score_release: struct { owner: u8 },
    voice_reset: struct { count: u16 },
    cue_context_stop: struct { cue: u8 },
    sequences_open: void,
    cue_request: struct { operand: u16 },
};

/// Bounded effect buffer.  A planner that needs more than this in one call has
/// a contract problem; the host turns it into `error.EffectOverflow`.
pub const PlanEffects = struct {
    pub const capacity = 32;
    items: [capacity]Event = undefined,
    len: usize = 0,

    pub fn push(self: *PlanEffects, event: Event) !void {
        if (self.len == capacity) return error.EffectOverflow;
        self.items[self.len] = event;
        self.len += 1;
    }

    pub fn slice(self: *const PlanEffects) []const Event {
        return self.items[0..self.len];
    }
};
