const std = @import("std");
// BIOS A0/2F recurrence; seed ownership and unported consumers remain outside this stream.
pub const Draws = struct {
    values: []const u15 = &.{},
    cursor: usize = 0,
    bios_state: ?u32 = null,
    prng: ?std.Random.DefaultPrng = null,
    pub fn valid(self: Draws) bool {
        if (self.prng != null) return self.bios_state == null and self.values.len == 0;
        return if (self.bios_state != null) self.values.len == 0 else self.cursor <= self.values.len;
    }

    pub fn restorePosition(self: Draws, cursor: usize, bios_state: ?u32, prng: ?std.Random.DefaultPrng) !Draws {
        if ((self.bios_state == null) != (bios_state == null) or (self.prng == null) != (prng == null)) return error.InvalidRandomSource;
        const restored: Draws = .{ .values = self.values, .cursor = cursor, .bios_state = bios_state, .prng = prng };
        if (!restored.valid()) return error.InvalidRandomCursor;
        return restored;
    }

    pub fn next(self: *Draws) !u15 {
        if (!self.valid()) return error.InvalidRandomSource;
        if (self.cursor == std.math.maxInt(usize)) return error.RandomInputExhausted;
        if (self.prng) |*random| {
            self.cursor += 1;
            return random.random().int(u15);
        }
        if (self.bios_state) |state| {
            const next_state = state *% 0x41c64e6d +% 0x3039;
            self.bios_state = next_state;
            self.cursor += 1;
            return @intCast((next_state >> 16) & 0x7fff);
        }
        if (self.cursor >= self.values.len) return error.RandomInputExhausted;
        defer self.cursor += 1;
        return self.values[self.cursor];
    }
};
pub const Element = enum { fire, water, earth, lightning, wind };
pub const Affinity = enum { neutral, weak, resistant, immune };
pub const Affinities = struct {
    fire: Affinity = .neutral,
    water: Affinity = .neutral,
    earth: Affinity = .neutral,
    lightning: Affinity = .neutral,
    wind: Affinity = .neutral,
    pub fn get(self: Affinities, element: Element) Affinity {
        return switch (element) {
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }
};
pub const Spell = struct { id: []const u8, name: []const u8, kind: enum { damage, heal, revive, cure, sleep, skill_bonus_scale, defense_bonus_scale, protection, source_rule }, allies: bool, group: bool, power: u16, field_use: bool = true, element: ?Element = null, full_heal: bool = false, clear_status: bool = false, sleep_failure_percent: ?u8 = null };
pub const PhysicalRune = struct { power: u8, recovery_rounds: u8 };
pub const Rune = struct {
    physical: ?PhysicalRune = null,
    id: []const u8,
    name: []const u8,
    spell_names: [4][]const u8,
    spells: [4]?usize,
    crystal: ?[]const u8 = null,
    allowed_members: ?[]const []const u8 = null,
    pub fn allows(self: Rune, member: []const u8) bool {
        if (self.allowed_members) |members| {
            for (members) |id| if (std.mem.eql(u8, id, member)) return true;
            return false;
        }
        return true;
    }
};
pub const EquipmentSlot = enum { head, body, shield, accessory_one, accessory_two };
pub const WeaponRune = enum { none, fire, water, wind, thunder, earth };
pub const WeaponAugment = struct { rune: WeaponRune = .none, fragments: u8 = 0 };
pub const Weapon = struct {
    initial_level: u8,
    names: [16][]const u8,
    powers: [16]u16,
    upgrade_costs: [16]u32,
    element: ?Element = null,

    pub fn jsonStringify(self: Weapon, writer: anytype) !void {
        try writer.beginObject();
        inline for (.{ "initial_level", "names", "powers", "upgrade_costs" }) |name| {
            try writer.objectField(name);
            try writer.write(@field(self, name));
        }
        if (self.element) |element| {
            try writer.objectField("element");
            try writer.write(element);
        }
        try writer.endObject();
    }
};
pub const Loadout = struct {
    head: ?usize = null,
    body: ?usize = null,
    shield: ?usize = null,
    accessory_one: ?usize = null,
    accessory_two: ?usize = null,
    pub fn get(self: Loadout, slot: EquipmentSlot) ?usize {
        return switch (slot) {
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }
    pub fn set(self: *Loadout, slot: EquipmentSlot, item: ?usize) void {
        switch (slot) {
            inline else => |tag| @field(self, @tagName(tag)) = item,
        }
    }
};
pub fn legacyLoadouts(headgear: [6]?usize) [6]Loadout {
    var result: [6]Loadout = @splat(.{});
    for (&result, headgear) |*loadout, head| loadout.head = head;
    return result;
}
pub const Equipment = struct {
    id: []const u8,
    name: []const u8,
    bonuses: [8]i8,
    category: enum { head, body, shield, accessory } = .head,
    allowed_members: ?[]const []const u8 = null,
    pub fn allows(self: Equipment, member: []const u8, slot: EquipmentSlot) bool {
        if (!switch (slot) {
            .head => self.category == .head,
            .body => self.category == .body,
            .shield => self.category == .shield,
            .accessory_one, .accessory_two => self.category == .accessory,
        }) return false;
        if (self.allowed_members) |members| {
            for (members) |id| if (std.mem.eql(u8, id, member)) return true;
            return false;
        }
        return true;
    }
};
pub const Unite = struct { name: []const u8, members: [2][]const u8, power: u16, recovery_rounds: u8 = 0 };
pub const Systems = struct {
    spells: []const Spell,
    runes: []const Rune,
    magic_thresholds: [4][9]u8,
    equipment: []const Equipment,
    stat_growth: [48]u32,
    hp_growth: [48]u32,
    experience: [30]u32,
    unite: Unite,
    sleep_recovery_percent: ?u8 = null,
    additional_unites: []const Unite = &.{},

    pub fn validate(self: Systems) !void {
        if (self.spells.len == 0 or self.spells.len > 33 or self.equipment.len > 64 or self.unite.power == 0 or self.unite.power > 4 or self.unite.recovery_rounds > 3) return error.InvalidSystems;
        if (self.sleep_recovery_percent) |percent| if (percent > 100) return error.InvalidSystems;
        for (self.spells, 0..) |spell, i| {
            try validName(spell.id);
            try validName(spell.name);
            if (spell.power == 0 or spell.power > 9999 or (spell.kind == .revive and spell.power > 100) or (spell.kind != .source_rule and spell.allies == (spell.kind == .damage or spell.kind == .sleep or spell.kind == .skill_bonus_scale))) return error.InvalidSpell;
            if (spell.element != null and spell.kind != .damage) return error.InvalidSpell;
            if (spell.kind == .protection and spell.power > 10) return error.InvalidSpell;
            if ((spell.kind == .skill_bonus_scale or spell.kind == .defense_bonus_scale) and spell.power > 200) return error.InvalidSpell;
            if (spell.sleep_failure_percent) |percent| if (spell.kind != .sleep or percent > 100) return error.InvalidSpell;
            for (self.spells[0..i]) |other| if (std.mem.eql(u8, spell.id, other.id)) return error.InvalidSpell;
        }
        if (self.runes.len == 0 or self.runes.len > 33) return error.InvalidRune;
        for (self.runes, 0..) |rune, i| {
            try validName(rune.id);
            try validName(rune.name);
            if (rune.crystal) |id| {
                try validName(id);
                for (self.runes[0..i]) |previous| if (previous.crystal != null and std.mem.eql(u8, previous.crystal.?, id)) return error.InvalidRune;
            }
            if (rune.allowed_members) |members| {
                if (members.len > 78) return error.InvalidRune;
                for (members, 0..) |id, j| {
                    try validName(id);
                    for (members[0..j]) |previous| if (std.mem.eql(u8, previous, id)) return error.InvalidRune;
                }
            }
            if (rune.physical) |technique| {
                if (technique.power == 0 or technique.power > 4 or technique.recovery_rounds > 3) return error.InvalidRune;
                for (rune.spells) |spell| if (spell != null) return error.InvalidRune;
            }
            for (rune.spell_names) |name| try validName(name);
            for (rune.spells, rune.spell_names) |slot, name| if (slot) |spell| {
                if (spell >= self.spells.len or !std.mem.eql(u8, name, self.spells[spell].name)) return error.InvalidRune;
            };
            for (self.runes[0..i]) |other| if (std.mem.eql(u8, rune.id, other.id)) return error.InvalidRune;
        }
        for (self.magic_thresholds) |row| for (row, 0..) |threshold, i| {
            if (i > 0 and threshold <= row[i - 1]) return error.InvalidMagicThresholds;
        };
        for (self.equipment, 0..) |item, i| {
            try validName(item.id);
            try validName(item.name);
            if (item.allowed_members) |members| {
                if (members.len > 78) return error.InvalidEquipment;
                for (members, 0..) |id, j| {
                    try validName(id);
                    for (members[0..j]) |previous| if (std.mem.eql(u8, previous, id)) return error.InvalidEquipment;
                }
            }
            for (self.equipment[0..i]) |other| if (std.mem.eql(u8, item.id, other.id)) return error.InvalidEquipment;
        }
        for (self.stat_growth ++ self.hp_growth) |value| if (value > 32768) return error.InvalidGrowth;
        for (self.experience) |value| if (value > 1000000) return error.InvalidGrowth;
        if (self.additional_unites.len > 16) return error.InvalidSystems;
        for (self.additional_unites) |unite| {
            try validName(unite.name);
            if (unite.power == 0 or unite.power > 4 or unite.recovery_rounds > 3 or std.mem.eql(u8, unite.members[0], unite.members[1])) return error.InvalidSystems;
            for (unite.members) |id| try validName(id);
        }
        for (self.additional_unites, 0..) |unite, i| for (unite.members) |id| {
            for (self.unite.members) |existing| if (std.mem.eql(u8, id, existing)) return error.InvalidSystems;
            for (self.additional_unites[0..i]) |other| for (other.members) |existing| if (std.mem.eql(u8, id, existing)) return error.InvalidSystems;
        };
        try validName(self.unite.name);
        for (self.unite.members) |id| try validName(id);
        if (std.mem.eql(u8, self.unite.members[0], self.unite.members[1])) return error.InvalidSystems;
    }
    pub fn runeIndex(self: Systems, id: []const u8) ?usize {
        for (self.runes, 0..) |rune, i| if (std.mem.eql(u8, rune.id, id)) return i;
        return null;
    }
    pub fn magicCapacity(self: Systems, magic: u16) [4]u16 {
        var charges: [4]u16 = @splat(0);
        for (self.magic_thresholds, 0..) |row, tier| for (row) |threshold| {
            if (magic > threshold) charges[tier] += 1;
        };
        return charges;
    }
};
fn validName(value: []const u8) !void {
    if (value.len == 0 or value.len > 64 or !std.unicode.utf8ValidateSlice(value)) return error.InvalidSystems;
    for (value) |c| if (c < 32 or c == 127) return error.InvalidSystems;
}
pub fn statIndex(level: u8, rate: u4) usize {
    const first: u8 = if (rate == 14) 60 else if (rate == 9 or rate == 10) 15 else 20;
    const second: u8 = if (rate == 14) 80 else 60;
    return @as(usize, rate) * 3 + @as(usize, if (level < first) 0 else if (level < second) 1 else 2);
}

/// Rune id -> magic-damage selector, MAIN 0x800C1414/0x800F82AC.
/// VAD MAGIC93 uses this path; named player spells use elemental coefficients.
/// IDs 8..26 retain the incoming selector; 0 and >31 are out of range.
pub fn magicRuneSelector(rune: u8, incoming: u8) ?u8 {
    return switch (rune) {
        1 => 7,
        2, 27 => 1,
        3, 28 => 2,
        4, 29 => 5,
        5, 31 => 4,
        6, 30 => 3,
        7 => 6,
        8...26 => incoming,
        else => null,
    };
}

/// Halve when the element operand matches or the selector is 7, floor at 1.
pub fn magicSelectorDamage(base: u32, selector: u8, element: u8) u32 {
    if (selector == 7 or selector == element) return @max(base / 2, 1);
    return @max(base, 1);
}

pub fn elementalDamage(power: u16, magic: u16, affinity: Affinity) u32 {
    const base = @as(u32, power) + magic / 2;
    return switch (affinity) {
        .neutral => base,
        .weak => base * 2,
        .resistant => base / 2,
        .immune => 0,
    };
}
pub fn statusPercent(roll: u15) u32 {
    return (@as(u32, roll) * 100 / 32767) % 100;
}

/// `clamp(skill - (target_skill - 80), 60, 99)` from MAIN 0x800F7D5C.  A
/// halved threshold is the source sign-bias/`sra` pair; both thresholds are
/// strictly positive, so it is `>> 1`.  Promoted here once so the
/// battle owner and the battle status module cannot drift apart.
pub fn accuracyThreshold(skill: u16, target_skill: u16, halved: bool) u16 {
    const raw: i32 = @as(i32, skill) - (@as(i32, target_skill) - 80);
    var threshold: u16 = @intCast(std.math.clamp(raw, 60, 99));
    if (halved) threshold >>= 1;
    return threshold;
}

/// `clamp((skill+luck)/8, 3, 25)`, doubled by the Killer rune *after* the
/// clamp (MAIN 0x800F835C).
pub fn criticalChance(skill: u16, luck: u16, killer: bool) u32 {
    const base = std.math.clamp((@as(u32, skill) + @as(u32, luck)) / 8, 3, 25);
    return base * @as(u32, if (killer) 2 else 1);
}

pub fn criticalHit(skill: u16, luck: u16, killer: bool, roll: u15) bool {
    return roll % 100 < criticalChance(skill, luck, killer);
}

/// MAIN 0x800F7E90: unsigned attack minus unsigned defence, the two variance
/// arms, defender halving and a floor of 1.  Signed quotients truncate toward
/// zero (`@divTrunc`), which matters in the d<10 arm where d can be negative.
pub fn physicalDamage(attack: u16, defense: u16, roll: u15, defending: bool) u32 {
    var damage: i32 = @as(i32, attack) - @as(i32, defense);
    if (damage < 10) {
        damage += 1 - @as(i32, roll % 4);
    } else {
        damage += @divTrunc(@divTrunc(damage, 2) - @rem(@as(i32, roll), damage), 5);
    }
    if (defending) damage = @divTrunc(damage, 2);
    return @intCast(@max(1, damage));
}

/// MAIN 0x800F8068: rune types index the five target affinity bytes in source order.
pub fn weaponElement(weapon: ?Element, rune: WeaponRune) ?Element {
    return switch (rune) {
        .none => weapon,
        .fire => .fire,
        .water => .water,
        .wind => .earth,
        .thunder => .lightning,
        .earth => .wind,
    };
}

pub fn physicalWeaponDamage(base: u32, weak: bool, augment: WeaponAugment) u32 {
    var result = base;
    if (weak) result += result / 2;
    if (augment.rune == .fire or augment.rune == .wind) result += (result / 20) * augment.fragments;
    return result;
}

pub fn battlePoison(maximum_hp: u16) u16 {
    return maximum_hp / 20;
}
pub const FieldPoison = struct { cured: bool, damage: u16 };
pub fn fieldPoison(hp: u16, maximum_hp: u16, roll: u15) FieldPoison {
    if ((roll / 255) & 15 == 0) return .{ .cured = true, .damage = 0 };
    const damage = maximum_hp / 5;
    return .{ .cured = false, .damage = if (hp > damage) damage else 0 };
}
