//! Draw and damage rules layered on the shared `battle_rules`.
//!
//! The shared module already owns the BIOS recurrence (`Draws`), the accuracy,
//! critical, physical-damage and status-percent helpers.  This file only adds
//! the two things the interaction resolver needs: a draw log that records the
//! exact source order, and a cursor snapshot so a refused branch can restore
//! the caller's stream instead of consuming its input.

const std = @import("std");
pub const battle_rules = @import("battle_rules");

pub const DrawStep = enum { accuracy, critical, physical_variance, counter_availability, status, boundary_wake };

pub const DrawRecord = struct { step: DrawStep, value: u15 };

pub const DrawLog = struct {
    entries: [8]DrawRecord = undefined,
    count: usize = 0,

    pub fn reset(self: *DrawLog) void {
        self.count = 0;
    }

    pub fn push(self: *DrawLog, step: DrawStep, value: u15) void {
        if (self.count == self.entries.len) return;
        self.entries[self.count] = .{ .step = step, .value = value };
        self.count += 1;
    }

    pub fn slice(self: *const DrawLog) []const DrawRecord {
        return self.entries[0..self.count];
    }

    pub fn countOf(self: *const DrawLog, step: DrawStep) usize {
        var result: usize = 0;
        for (self.slice()) |entry| if (entry.step == step) {
            result += 1;
        };
        return result;
    }
};

pub const Cursor = struct { cursor: usize, bios_state: ?u32 };

pub fn mark(draws: *const battle_rules.Draws) Cursor {
    return .{ .cursor = draws.cursor, .bios_state = draws.bios_state };
}

pub fn restore(draws: *battle_rules.Draws, cursor: Cursor) void {
    draws.cursor = cursor.cursor;
    draws.bios_state = cursor.bios_state;
}

pub fn pull(draws: *battle_rules.Draws, log: *DrawLog, step: DrawStep) !u15 {
    const value = try draws.next();
    log.push(step, value);
    return value;
}

/// `clamp(skill - (target_skill - 80), 60, 99)`, the clamped accuracy threshold
/// of MAIN 0x800F7D5C.  A halved threshold is the same value with the source
/// sign-bias/sra pair; both thresholds are strictly positive, so it is `>> 1`.
/// Promoted the formula into the shared `battle_rules` module; this
/// wrapper keeps the package contract and cannot drift from the owner.
pub fn accuracyThreshold(skill: u16, target_skill: u16, halved: bool) u16 {
    return battle_rules.accuracyThreshold(skill, target_skill, halved);
}

/// Physical hit test; the shared owner carries the threshold.
pub fn hit(skill: u16, target_skill: u16, roll: u15, halved: bool) bool {
    return roll % 100 < battle_rules.accuracyThreshold(skill, target_skill, halved);
}

/// `clamp((skill+luck)/8, 3, 25)`, doubled by the Killer rune (0x0F) *after* the
/// clamp, exactly as MAIN 0x800F835C does.
pub fn criticalChance(skill: u16, luck: u16, killer: bool) u32 {
    return battle_rules.criticalChance(skill, luck, killer);
}

pub fn criticalHit(skill: u16, luck: u16, killer: bool, roll: u15) bool {
    return battle_rules.criticalHit(skill, luck, killer, roll);
}

/// MAIN 0x800F7E90, shared with the battle owner via the battle-systems integration.
pub fn physicalDamage(attack: u16, defense: u16, roll: u15, defending: bool) u32 {
    return battle_rules.physicalDamage(attack, defense, roll, defending);
}

pub fn statusPercent(roll: u15) u32 {
    return battle_rules.statusPercent(roll);
}

test "accuracy thresholds match the shared helper at the clamp boundaries" {
    const cases = [_]struct { skill: u16, target: u16, halved: bool, threshold: u16, hit: u15, miss: u15 }{
        .{ .skill = 0, .target = 200, .halved = false, .threshold = 60, .hit = 59, .miss = 60 },
        .{ .skill = 255, .target = 0, .halved = false, .threshold = 99, .hit = 98, .miss = 99 },
        .{ .skill = 255, .target = 0, .halved = true, .threshold = 49, .hit = 48, .miss = 49 },
        .{ .skill = 60, .target = 60, .halved = false, .threshold = 80, .hit = 79, .miss = 80 },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.threshold, accuracyThreshold(case.skill, case.target, case.halved));
        try std.testing.expect(hit(case.skill, case.target, case.hit, case.halved));
        try std.testing.expect(!hit(case.skill, case.target, case.miss, case.halved));
    }
}

test "physical damage matches the source arms and truncates toward zero" {
    try std.testing.expectEqual(@as(u32, 1), physicalDamage(0, 100, 0, false));
    try std.testing.expectEqual(@as(u32, 1), physicalDamage(0, 100, 3, false));
    try std.testing.expectEqual(@as(u32, 6), physicalDamage(100, 95, 0, false));
    try std.testing.expectEqual(@as(u32, 11), physicalDamage(100, 90, 0, false));
    try std.testing.expectEqual(@as(u32, 110), physicalDamage(100, 0, 0, false));
    try std.testing.expectEqual(@as(u32, 55), physicalDamage(100, 0, 0, true));
}

test "critical clamp and Killer doubling" {
    try std.testing.expectEqual(@as(u32, 3), criticalChance(0, 0, false));
    try std.testing.expectEqual(@as(u32, 6), criticalChance(0, 0, true));
    try std.testing.expectEqual(@as(u32, 25), criticalChance(255, 255, false));
    try std.testing.expectEqual(@as(u32, 50), criticalChance(255, 255, true));
    try std.testing.expectEqual(@as(u32, 3), criticalChance(23, 0, false));
    try std.testing.expectEqual(@as(u32, 25), criticalChance(200, 0, false));
}
