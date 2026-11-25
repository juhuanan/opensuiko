//! Battle status state.
//!
//! The nine classes are the u16 masks read from MAIN 0x8016BAA8.  They are
//! independent: a class may be present or absent without touching any other,
//! and each has its own object slot/remaining counter.  Durations are only the
//! ones the source proves:
//!
//!   class 8 protection/Copper Flesh  counter 2, removed on the third boundary
//!                                    entered with counter 0 (0x800F65B8)
//!   class 7 recovery                 action-supplied boundary count; no fixed
//!                                    source count exists in this pack
//!   class 5 sleep                    enemy round reset wakes on
//!                                    floor(roll*100/32767) < 50 (0x800F6F58);
//!                                    a party count is applied without a draw
//!   class 0 poison                   max_hp/20 at each boundary
//!   classes 1..3 balloons            first empty class at application
//!   classes 4/6                      persist until cured or battle exit
//!
//! General cure removes classes 6..0 and preserves 7/8 (0x801204EC).  Battle
//! exit keeps only the low nibble 0x000F (0x800DE234..0x800DE240).

const std = @import("std");
const rules = @import("rules.zig");
const battle_rules = @import("battle_rules");
const data = @import("constants.zig");

pub const Class = enum(u4) {
    poison = 0,
    balloon_one = 1,
    balloon_two = 2,
    balloon_three = 3,
    accuracy_reduced = 4,
    sleep = 5,
    rune_blocked = 6,
    recovery = 7,
    protection = 8,
};

pub const class_count = 9;

pub fn maskOf(class: Class) u16 {
    return data.status_masks[@backingInt(class)];
}

pub fn nameOf(class: Class) []const u8 {
    return data.status_names[@backingInt(class)];
}

pub fn isBalloon(class: Class) bool {
    return class == .balloon_one or class == .balloon_two or class == .balloon_three;
}

pub const Attempt = struct {
    class: Class,
    /// Rejection threshold from the source status descriptor: apply only when
    /// `((roll*100)/32767)%100 >= failure_percent`.
    failure_percent: u8 = 0,
    /// Class 7 needs the action's recovery count.  Class 5 may carry a party
    /// count.  Class 8 ignores it and uses the source counter 2.
    boundaries: u8 = 0,
};

pub const Result = enum { applied, duplicate, rejected, immune, pointed_hat };

pub const Outcome = struct {
    result: Result,
    /// The class actually touched; for a balloon attempt this is the selected
    /// first-empty class, not necessarily `attempt.class`.
    class: Class,
};

pub const State = struct {
    mask: u16 = 0,
    counters: [class_count]u8 = @splat(0),

    pub fn has(self: State, class: Class) bool {
        return self.mask & maskOf(class) != 0;
    }

    pub fn protectionActive(self: State) bool {
        return self.has(.protection);
    }

    pub fn clearAll(self: *State) void {
        self.mask = 0;
        self.counters = @splat(0);
    }

    pub fn remove(self: *State, class: Class) void {
        self.mask &= ~maskOf(class);
        self.counters[@backingInt(class)] = 0;
    }

    /// General cure order 6 down to 0; recovery 7 and protection 8 survive.
    pub fn cureGeneral(self: *State) void {
        self.remove(.rune_blocked);
        self.remove(.sleep);
        self.remove(.accuracy_reduced);
        self.remove(.balloon_three);
        self.remove(.balloon_two);
        self.remove(.balloon_one);
        self.remove(.poison);
    }

    /// Battle exit keeps the persistent low nibble only.
    pub fn battleExit(self: *State) void {
        self.mask &= data.battle_exit_keep_mask;
        var index: usize = 4;
        while (index < class_count) : (index += 1) self.counters[index] = 0;
    }

    fn firstEmptyBalloon(self: State) Class {
        if (!self.has(.balloon_one)) return .balloon_one;
        if (!self.has(.balloon_two)) return .balloon_two;
        return .balloon_three;
    }

    /// Apply one status operand.  The caller passes the source flags that are
    /// not part of the status set: party membership, Turtle rune immunity and
    /// the Pointed-hat balloon block.  A Turtle target returns before the draw
    /// (source 0x800E6BD0); every other path consumes exactly one draw.
    pub fn apply(
        self: *State,
        attempt: Attempt,
        party: bool,
        turtle: bool,
        pointed_hat: bool,
        draws: *battle_rules.Draws,
        log: *rules.DrawLog,
    ) !Outcome {
        _ = party;
        if (attempt.class == .recovery and attempt.boundaries == 0) return error.MissingDuration;
        if (turtle) return .{ .result = .immune, .class = attempt.class };
        const roll = try rules.pull(draws, log, .status);
        if (rules.statusPercent(roll) < attempt.failure_percent) {
            return .{ .result = .rejected, .class = attempt.class };
        }
        var chosen = attempt.class;
        if (attempt.class == .balloon_one) chosen = self.firstEmptyBalloon();
        if (pointed_hat and isBalloon(chosen)) return .{ .result = .pointed_hat, .class = chosen };
        if (self.has(chosen)) return .{ .result = .duplicate, .class = chosen };
        if (isBalloon(chosen)) {
            self.mask |= maskOf(chosen);
            return .{ .result = .applied, .class = chosen };
        }
        self.mask |= maskOf(chosen);
        const index = @backingInt(chosen);
        self.counters[index] = switch (chosen) {
            .protection => data.copper_counter,
            .recovery, .sleep => attempt.boundaries,
            else => 0,
        };
        return .{ .result = .applied, .class = chosen };
    }
};

pub const BoundaryResult = struct {
    copper_expired: bool = false,
    recovery_expired: bool = false,
    sleep_woke: bool = false,
    poison_damage: u16 = 0,
    poison_blocked: bool = false,
};

/// One round boundary in source order: protection expiry, recovery decrement,
/// sleep wake, poison damage.  Only the enemy sleep wake consumes a draw.
pub fn boundary(self: *State, maximum_hp: u16, party: bool, draws: *battle_rules.Draws, log: *rules.DrawLog) !BoundaryResult {
    var result = BoundaryResult{};
    if (self.has(.protection)) {
        if (self.counters[@backingInt(Class.protection)] == 0) {
            self.remove(.protection);
            result.copper_expired = true;
        } else self.counters[@backingInt(Class.protection)] -= 1;
    }
    if (self.has(.recovery)) {
        const index = @backingInt(Class.recovery);
        if (self.counters[index] > 0) {
            self.counters[index] -= 1;
            if (self.counters[index] == 0) {
                self.remove(.recovery);
                result.recovery_expired = true;
            }
        }
    }
    if (self.has(.sleep)) {
        if (party) {
            const index = @backingInt(Class.sleep);
            if (self.counters[index] > 0) {
                self.counters[index] -= 1;
                if (self.counters[index] == 0) {
                    self.remove(.sleep);
                    result.sleep_woke = true;
                }
            }
        } else {
            const roll = try rules.pull(draws, log, .boundary_wake);
            if (@as(u32, roll) * 100 / 32767 < data.sleep_wake_percent) {
                self.remove(.sleep);
                result.sleep_woke = true;
            }
        }
    }
    if (party and self.has(.poison)) {
        const damage = maximum_hp / data.poison_divisor;
        if (self.has(.protection)) result.poison_blocked = true else result.poison_damage = damage;
    }
    return result;
}

test "masks are independent and cure preserves recovery/protection" {
    var state = State{};
    for (0..class_count) |index| {
        const class: Class = @fromBackingInt(@intCast(index));
        state.mask |= maskOf(class);
    }
    try std.testing.expectEqual(@as(u16, 0x80FF), state.mask);
    state.cureGeneral();
    try std.testing.expectEqual(@as(u16, maskOf(.recovery) | maskOf(.protection)), state.mask);
    try std.testing.expect(state.has(.recovery));
    try std.testing.expect(state.has(.protection));
}

test "battle exit keeps only classes 0..3" {
    var state = State{};
    for ([_]Class{ .poison, .balloon_one, .balloon_two, .balloon_three, .accuracy_reduced, .sleep, .rune_blocked, .recovery, .protection }) |class| {
        state.mask |= maskOf(class);
    }
    state.battleExit();
    try std.testing.expectEqual(@as(u16, 0x000F), state.mask);
}

test "copper flesh expires on the third boundary and blocks poison" {
    var state = State{};
    state.mask |= maskOf(.protection) | maskOf(.poison);
    state.counters[@backingInt(Class.protection)] = data.copper_counter;
    var draws = battle_rules.Draws{ .values = &.{ 1, 1, 1 } };
    var log = rules.DrawLog{};
    const first = try boundary(&state, 100, true, &draws, &log);
    try std.testing.expect(!first.copper_expired);
    try std.testing.expectEqual(@as(u16, 0), first.poison_damage);
    try std.testing.expect(first.poison_blocked);
    const second = try boundary(&state, 100, true, &draws, &log);
    try std.testing.expect(!second.copper_expired);
    try std.testing.expectEqual(@as(u16, 0), second.poison_damage);
    const third = try boundary(&state, 100, true, &draws, &log);
    try std.testing.expect(third.copper_expired);
    try std.testing.expectEqual(@as(u16, 5), third.poison_damage);
    try std.testing.expect(!third.poison_blocked);
}

test "party sleep count wakes without a draw and enemy sleep wakes on the roll" {
    var state = State{};
    state.mask |= maskOf(.sleep);
    state.counters[@backingInt(Class.sleep)] = 2;
    var draws = battle_rules.Draws{ .values = &.{ 32767, 0 } };
    var log = rules.DrawLog{};
    const first = try boundary(&state, 100, true, &draws, &log);
    try std.testing.expect(!first.sleep_woke);
    const second = try boundary(&state, 100, true, &draws, &log);
    try std.testing.expect(second.sleep_woke);
    try std.testing.expectEqual(@as(usize, 0), log.count);

    var enemy = State{};
    enemy.mask |= maskOf(.sleep);
    var wake_draws = battle_rules.Draws{ .values = &.{0} };
    const awake = try boundary(&enemy, 100, false, &wake_draws, &log);
    try std.testing.expect(awake.sleep_woke);
    try std.testing.expectEqual(@as(usize, 1), log.count);
}

test "application checks Turtle before the draw and selects first empty balloon" {
    var draws = battle_rules.Draws{ .values = &.{ 0, 32767 } };
    var log = rules.DrawLog{};
    var state = State{};
    const immune = try state.apply(.{ .class = .accuracy_reduced }, true, true, false, &draws, &log);
    try std.testing.expectEqual(Result.immune, immune.result);
    try std.testing.expectEqual(@as(usize, 0), log.count);
    const balloon = try state.apply(.{ .class = .balloon_one }, true, false, false, &draws, &log);
    try std.testing.expectEqual(Class.balloon_one, balloon.class);
    const second = try state.apply(.{ .class = .balloon_one }, true, false, false, &draws, &log);
    try std.testing.expectEqual(Class.balloon_two, second.class);
    try std.testing.expectEqual(@as(usize, 2), log.count);
}
