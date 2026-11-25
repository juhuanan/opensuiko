//! Ordinary movement encounter eligibility, rate and candidate picker.
//!
//! Source contract (MAIN.EXE, static instruction words; no original instruction
//! is executed here):
//!
//!   field update 0x8013295C -> validator 0x8012CC38/0x8012CC40
//!     0x8012CC4C  lbu  area_state+0x37 / andi 4      already-armed short path
//!     0x8012CC64  lbu  0x8017159A                    armed flag
//!     0x8012CC74  lbu  area_state+0x36               ready flag
//!     0x8012CC88  lbu  0x8017BD7A                    global suppression
//!     0x8012CC9C  lbu  0x8017159C + lw area_state+0x30
//!     0x8012CCC0  lw   area_header+0x38               candidate table
//!     0x8012CCD0  jal  0x8013879C                     rand()/127
//!     0x8012CCE0  andi 0xFF / 0x8012CCE4 sltu        strict roll < rate
//!     0x8012CD08  jal  0x80126228                     picker
//!     0x8012CD24  sb   1, area_state+0x37             request transition
//!
//!   picker 0x80126228
//!     one BIOS draw; index = min(N, draw / (0x7FFF / N) + 1)
//!     candidate roster's six slots sum levels; *15/10 against the party level
//!     sum only when rune 0x18 is present; rejection does not retry.
//!
//! One caller RNG only: every draw is taken from the caller's `Draws` and the
//! returned progress carries the exact advanced value.  Nothing here seeds,
//! previews or rerolls.  Eligibility is decided before the first draw.

const std = @import("std");
const rules = @import("battle_rules");

pub const draws = rules.Draws;

/// The runtime content exposes only the two fields the picker needs: a stable
/// encounter identity and the sum of the six slot levels (0 = empty slot).
pub const Candidate = struct {
    id: []const u8,
    enemy_level_sum: u16,
};

pub const max_candidates: usize = 64;

/// One source area's movement rate.  `counter_threshold` is the per-area byte
/// pair at 0x8017159C; `rate` is 0x8017159D.  A domain whose rate is not
/// statically paired is represented by `.blocked`, never by a guessed number.
pub const RatePolicy = union(enum) {
    source: SourceRate,
    blocked: Blocker,
};

pub const SourceRate = struct {
    rate: u8,
    counter_threshold: u16,
};

pub const Blocker = enum {
    already_armed,
    encounters_disabled,
    unsupported_travel_mode,
    moving,
    no_pending_step,
    not_armed,
    ready_flag_clear,
    globally_suppressed,
    counter_not_past_threshold,
    arm_suppressed,
    rate_unavailable,
    rate_threshold_mismatch,
    no_candidates,
    too_many_candidates,
};

/// Runtime state bits that gate the validator.  All are decisions, not draws.
pub const Eligibility = struct {
    encounters_enabled: bool = true,
    /// Foot travel: not boat and not scripted/auto-routed.
    foot_travel: bool = true,
    /// The interpolating movement step has finished.
    ready: bool = true,
    /// A completed step is waiting for its encounter check.
    arrival_pending: bool = true,
    /// The per-area counter (area_state+0x30) is the caller's travel counter.
    travel_counter: u16,
    /// The per-area counter threshold (0x8017159C) from the same source area.
    counter_threshold: u16,
    /// 0x8017159A, set by the area loader only for a non-zero source rate.
    armed: bool = true,
    /// area_state+0x36.
    ready_flag: bool = true,
    /// 0x8017BD7A != 0 suppresses the validator before any draw.
    global_suppressed: bool = false,
    /// Port-level pre-draw suppressor (the caller's armed/auto-route preview).
    /// This is deliberately checked before the rate draw so a suppressed
    /// movement does not consume the caller's RNG.
    arm_suppressed: bool = false,
    /// area_state+0x37 bit 2: a transition is already requested; no new draw.
    transition_already_armed: bool = false,
};

pub const Party = struct {
    level_sum: u16 = 0,
    /// Rune 0x18 (the source matcher at 0x801261B0 tests that code).
    suppression_rune: bool = false,
};

pub const Progress = struct {
    draws: draws,
    rate_draw: u15,
    rate_roll: u8,
    pick_draw: ?u15 = null,
    enemy_level_scaled: u16 = 0,
};

pub const Selection = struct {
    progress: Progress,
    candidate: Candidate,
    /// One-based index, as stored at gs+0x1BC0.
    index: u16,
};

pub const Rejection = struct {
    progress: Progress,
    candidate: Candidate,
    index: u16,
};

pub const Outcome = union(enum) {
    /// No draw and no state change.
    blocked: Blocker,
    /// One draw consumed; the movement produced no encounter.
    rate_failed: Progress,
    /// Two draws consumed; the rune comparison refused the picked candidate.
    rejected: Rejection,
    /// Two draws consumed; this is the candidate the caller admits.
    selected: Selection,
};

/// Source 0x8013879C: returns BIOS rand() / 127, then 0x8012CCE0 masks it to a
/// byte before the strict `< rate` comparison.  (Not a modulo: the helper's
/// `div` result is taken from LO with `mflo`.)
pub fn rateRoll(draw: u15) u8 {
    return @intCast((@as(u16, draw) / 127) & 0xff);
}

/// Source picker index: min(N, draw / (32767 / N) + 1), one-based.
pub fn pickIndex(draw: u15, count: u16) !u16 {
    if (count == 0 or count > 0x7fff) return error.InvalidCandidateCount;
    const divisor: u16 = 0x7fff / count;
    if (divisor == 0) return error.InvalidCandidateCount;
    const index: u32 = @as(u32, draw) / @as(u32, divisor) + 1;
    return @intCast(@min(@as(u32, count), index));
}

/// floor(enemy-level sum * 15 / 10).
pub fn enemyLevelScaled(sum: u16) u16 {
    return @intCast((@as(u32, sum) * 15) / 10);
}

/// Rune 0x18 refuses only when the party sum is strictly greater than the
/// scaled candidate sum.  Equality accepts.
pub fn runeRejects(party: Party, candidate: Candidate) bool {
    if (!party.suppression_rune) return false;
    return party.level_sum > enemyLevelScaled(candidate.enemy_level_sum);
}

fn eligibleBlocker(eligibility: Eligibility, rate: RatePolicy, candidates: []const Candidate) ?Blocker {
    if (eligibility.transition_already_armed) return .already_armed;
    if (!eligibility.encounters_enabled) return .encounters_disabled;
    if (!eligibility.foot_travel) return .unsupported_travel_mode;
    if (!eligibility.ready) return .moving;
    if (!eligibility.arrival_pending) return .no_pending_step;
    if (!eligibility.armed) return .not_armed;
    if (!eligibility.ready_flag) return .ready_flag_clear;
    if (eligibility.global_suppressed) return .globally_suppressed;
    if (eligibility.travel_counter <= eligibility.counter_threshold) return .counter_not_past_threshold;
    if (eligibility.arm_suppressed) return .arm_suppressed;
    switch (rate) {
        .blocked => |blocker| return blocker,
        .source => |source| if (source.counter_threshold != eligibility.counter_threshold) return .rate_threshold_mismatch,
    }
    if (candidates.len == 0) return .no_candidates;
    if (candidates.len > max_candidates) return .too_many_candidates;
    return null;
}

/// Run one ordinary movement-encounter check.  The caller's `draws` value is
/// never mutated.  Blocked outcomes consume nothing; `rate_failed` consumes the
/// rate draw; `rejected`/`selected` consume the rate draw and the picker draw.
/// Any RNG error leaves the caller's value untouched because the local copy is
/// discarded by the error return.
pub fn attempt(eligibility: Eligibility, party: Party, rate: RatePolicy, candidates: []const Candidate, caller_draws: draws) !Outcome {
    if (eligibleBlocker(eligibility, rate, candidates)) |blocker| return .{ .blocked = blocker };
    const source = switch (rate) {
        .source => |source| source,
        .blocked => unreachable,
    };
    var working = caller_draws;
    const rate_draw = try working.next();
    var progress = Progress{
        .draws = working,
        .rate_draw = rate_draw,
        .rate_roll = rateRoll(rate_draw),
    };
    if (progress.rate_roll >= source.rate) return .{ .rate_failed = progress };

    const pick_draw = try working.next();
    progress.pick_draw = pick_draw;
    progress.draws = working;
    const index = try pickIndex(pick_draw, @intCast(candidates.len));
    const candidate = candidates[index - 1];
    progress.enemy_level_scaled = enemyLevelScaled(candidate.enemy_level_sum);
    if (runeRejects(party, candidate)) return .{ .rejected = .{ .progress = progress, .candidate = candidate, .index = index } };
    return .{ .selected = .{ .progress = progress, .candidate = candidate, .index = index } };
}

pub fn drawsUsed(outcome: Outcome) usize {
    return switch (outcome) {
        .blocked => 0,
        .rate_failed => 1,
        .rejected, .selected => 2,
    };
}

test "rate helper is rand()/127 masked to a byte, not a modulo" {
    try std.testing.expectEqual(@as(u8, 0), rateRoll(0));
    try std.testing.expectEqual(@as(u8, 0), rateRoll(126));
    try std.testing.expectEqual(@as(u8, 1), rateRoll(127));
    try std.testing.expectEqual(@as(u8, 2), rateRoll(254));
    try std.testing.expectEqual(@as(u8, 0), rateRoll(32512)); // 256 -> byte 0
    try std.testing.expectEqual(@as(u8, 2), rateRoll(32767)); // 258 -> byte 2
}

test "picker is min(N, draw/(32767/N)+1)" {
    try std.testing.expectEqual(@as(u16, 1), try pickIndex(0, 8));
    try std.testing.expectEqual(@as(u16, 1), try pickIndex(4094, 8));
    try std.testing.expectEqual(@as(u16, 2), try pickIndex(4095, 8));
    try std.testing.expectEqual(@as(u16, 8), try pickIndex(32767, 8));
    try std.testing.expectEqual(@as(u16, 4), try pickIndex(32767, 4));
    try std.testing.expectError(error.InvalidCandidateCount, pickIndex(0, 0));
}
