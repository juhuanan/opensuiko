//! Headquarters stage plan: a pure, validated module for the source
//! castle-stage byte (`gs+0x34`) and its two producers.
//!
//! The source model (see the extraction pipeline and
//! the embedded campaign asset) is:
//!
//!   * `recount` counts the 108 `gs+0x1AF4` recruit flags.  Stage promotion
//!     uses `bit0 | bit1` ("ever recruited"); the script condition at
//!     `0x8013D764` uses `bit0 & !bit1` ("present").
//!   * `promote` is the one-step routine at `0x801395FC`: stage 1 -> 2 at
//!     count >= 25 **and** `gs+0x19F & 0x02`; stage 2 -> 3 at count >= 45;
//!     stage 3 -> 4 at count >= 90.  Stage 0 is never promoted and a lagged
//!     stage is not caught up in one call.
//!   * `applyForced` is event opcode `0x42` selector 2 (`0x801418C0`).  It has
//!     no count test and no source bound; this module's validated plan refuses
//!     stage 4 -> 5 because the mirror table has exactly five rows.
//!   * The castle-name field `gs+0x1B84` and its dialog consumer are proven,
//!     but **no producer is located**.  `commitCastleName` deliberately fails
//!     with `ProducerUnresolved`; do not fabricate a name-entry path.
//!
//! This module is pure: it never mutates flags, story, roster or a save.  The
//! host applies only the returned stage byte.

const std = @import("std");

pub const schema = "suikoden-hq-stage-plan/1";
pub const stage_domain: u8 = 5;
pub const flag_slots: usize = 108;

pub const Thresholds = struct {
    first: u16 = 25,
    second: u16 = 45,
    third: u16 = 90,
};

pub const thresholds: Thresholds = .{};

/// `gs+0x19F` bit `0x02`.  It lives in the scenario bank at `gs+0x190`;
/// its exact scene producer is a story-side dependency, not a stage formula.
pub const story_gate = struct {
    pub const offset: u16 = 0x19F;
    pub const mask: u8 = 0x02;
};

/// Mirror areas at `0x8016F3AF`, one row per stage.  Stage 4 reuses stage 3.
pub const mirror_areas = [stage_domain]u8{ 128, 32, 24, 16, 16 };

pub const Stage = enum(u8) {
    zero = 0,
    one = 1,
    two = 2,
    three = 3,
    four = 4,

    pub fn fromByte(value: u8) !Stage {
        if (value >= stage_domain) return error.StageOutOfRange;
        return @fromBackingInt(@intCast(value));
    }

    pub fn byte(self: Stage) u8 {
        return @backingInt(self);
    }

    /// The Blinking Mirror's castle-area index at `0x8016F3AF`.
    pub fn mirrorArea(self: Stage) u8 {
        return mirror_areas[@backingInt(self)];
    }

    /// The castle-area slot from `0x8013C024`: `stage < 4 ? stage - 1 : 2`.
    /// Stage 0 would compute 0xFF and is therefore `null`.
    pub fn castleAreaSlot(self: Stage) ?u8 {
        return switch (self) {
            .zero => null,
            .one => 0,
            .two => 1,
            .three => 2,
            .four => 2,
        };
    }
};

pub const Counts = struct {
    ever: u16,
    present: u16,

    pub fn validate(self: Counts) !void {
        if (self.ever > flag_slots) return error.InvalidRecruitCount;
        if (self.present > self.ever) return error.InvalidRecruitCount;
    }
};

/// Count the 108 `gs+0x1AF4` flags exactly as the two source loops do.
pub fn recount(flags: *const [flag_slots]u8) Counts {
    var ever: u16 = 0;
    var present: u16 = 0;
    for (flags) |byte| {
        const bit0 = byte & 0x01 != 0;
        const bit1 = byte & 0x02 != 0;
        if (bit0 or bit1) ever += 1;
        if (bit0 and !bit1) present += 1;
    }
    return .{ .ever = ever, .present = present };
}

/// One application of the source promotion routine; never more than one step.
pub fn promote(stage: Stage, counts: Counts, story_castle_flag: bool) Stage {
    return switch (stage) {
        .one => if (counts.ever >= thresholds.first and story_castle_flag) .two else .one,
        .two => if (counts.ever >= thresholds.second) .three else .two,
        .three => if (counts.ever >= thresholds.third) .four else .three,
        .zero, .four => stage,
    };
}

/// The source event `0x42` selector 2 forced transition.
pub fn applyForced(stage: Stage) !Stage {
    return switch (stage) {
        .zero => .one,
        .one => .two,
        .two => .three,
        .three => .four,
        .four => error.StageSaturated,
    };
}

pub const Requirement = union(enum) {
    /// Stage 0 has no count formula; only the forced selector can advance it.
    source_forced_only,
    /// The story bit is already satisfied; this count remains.
    count: u16,
    /// Both the count and `gs+0x19F & 0x02` are required.
    count_and_story: u16,
    none,
};

pub const Plan = struct {
    stage: Stage,
    mirror_area: u8,
    castle_area_slot: ?u8,
    counts: Counts,
    next: Requirement,
    story_castle_flag: bool,
};

/// Validate the supplied facts and describe the current stage without changing
/// it.  `next` names the gate that is *not yet applied*; call `afterRecount`
/// after committing a recruit flag or loading a save.
pub fn plan(stage: Stage, counts: Counts, story_castle_flag: bool) !Plan {
    try counts.validate();
    return .{
        .stage = stage,
        .mirror_area = stage.mirrorArea(),
        .castle_area_slot = stage.castleAreaSlot(),
        .counts = counts,
        .next = nextRequirement(stage, story_castle_flag),
        .story_castle_flag = story_castle_flag,
    };
}

/// Apply exactly one source promotion step to a validated count snapshot.
pub fn afterRecount(stage: Stage, counts: Counts, story_castle_flag: bool) !Plan {
    try counts.validate();
    return plan(promote(stage, counts, story_castle_flag), counts, story_castle_flag);
}

pub fn nextRequirement(stage: Stage, story_castle_flag: bool) Requirement {
    return switch (stage) {
        .zero => .source_forced_only,
        .one => if (story_castle_flag)
            .{ .count = thresholds.first }
        else
            .{ .count_and_story = thresholds.first },
        .two => .{ .count = thresholds.second },
        .three => .{ .count = thresholds.third },
        .four => .none,
    };
}

// --- castle name -----------------------------------------------------------

pub const castle_name = struct {
    pub const field_offset: u16 = 0x1B84;
    pub const terminator: u16 = 0x1B8C;
    pub const glyphs: usize = 8;
    /// The setup's pointer global.  No producer loads it.
    pub const pointer_global: u32 = 0x8017C1DC;
};

pub const NameProducer = enum { unresolved };
pub const castle_name_producer: NameProducer = .unresolved;

pub const NameError = error{
    ProducerUnresolved,
    InvalidGlyph,
    EmptyName,
};

/// Validate the eight stored glyph bytes against the game's text code table
/// (`0x10` space, `0x11..0x4E` letters/digits).  This is a storage check only:
/// the accepted name-entry grid is not established, so it is not claimed here.
pub fn validateCastleName(glyphs: *const [castle_name.glyphs]u8) NameError!usize {
    var length: usize = 0;
    var ended = false;
    for (glyphs) |glyph| {
        if (glyph == 0) {
            ended = true;
            continue;
        }
        if (ended) return error.InvalidGlyph;
        if (!(glyph == 0x10 or (glyph >= 0x11 and glyph <= 0x4E))) return error.InvalidGlyph;
        length += 1;
    }
    if (length == 0) return error.EmptyName;
    return length;
}

/// There is no proven source writer for `gs+0x1B84`; refuse rather than invent.
pub fn commitCastleName(glyphs: *const [castle_name.glyphs]u8) NameError!void {
    _ = try validateCastleName(glyphs);
    return error.ProducerUnresolved;
}
