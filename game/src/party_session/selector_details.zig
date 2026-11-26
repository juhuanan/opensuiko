//! Persistent character values for the headquarters details window.
const std = @import("std");
const battle = @import("battle");
const party = @import("session.zig");

pub const Details = struct {
    level: u16,
    max_hp: u16,
    power: u16,
    skill: u16,
    defense: u16,
    speed: u16,
    magic: u16,
    luck: u16,
    attack: u16 = 0,
    armour: u16 = 0,
    charges: [4]u16,
    range: battle.WeaponRange,
    rune: ?[]const u8,

    pub fn derive(combat: battle.State, owned: battle.OwnedMember, extra: party.CharacterExtra) !Details {
        const rules = combat.content.systems orelse return error.MissingSelectorSystems;
        try combat.validateOwnedMember(owned);
        if (extra.member_id.len != 0 and !std.mem.eql(u8, extra.member_id, owned.id)) return error.InvalidSelectorExtra;
        const profile = combat.content.partyProfile(owned.id) orelse return error.MissingSelectorProfile;
        const weapon = profile.weapon orelse return error.MissingSelectorWeapon;
        // Native base attack retains the initial weapon power; menu PWR excludes it.
        const power = std.math.sub(u16, owned.base_stats.attack, weapon.powers[weapon.initial_level - 1]) catch return error.InvalidSelectorPower;
        var result: Details = .{
            .level = owned.level,
            .max_hp = owned.max_hp,
            .power = power,
            .skill = owned.base_stats.skill,
            .defense = owned.base_stats.defense,
            .speed = owned.base_stats.speed,
            .magic = owned.base_stats.magic,
            .luck = owned.base_stats.luck,
            .charges = owned.rune_charges,
            .range = profile.weapon_range orelse return error.MissingSelectorWeaponRange,
            .rune = if (owned.rune) |index| rules.runes[index].name else null,
        };
        if (owned.rune) |index| if (std.mem.eql(u8, rules.runes[index].id, "gale")) {
            result.speed *%= 2;
        };
        const augment = party.weaponAugment(extra);
        if (augment.rune == .wind) result.defense +%= @as(u16, augment.fragments) * 3;
        if (augment.rune == .earth) result.skill +%= @as(u16, augment.fragments) * 2;
        for (std.enums.values(battle.systems.EquipmentSlot)) |slot| if (owned.loadout.get(slot)) |index| {
            const bonuses = rules.equipment[index].bonuses;
            inline for (.{ &result.power, &result.skill, &result.defense, &result.speed, &result.magic, &result.luck, &result.attack, &result.armour }, 0..) |value, column| {
                value.* +%= @as(u16, @bitCast(@as(i16, bonuses[column])));
            }
        };
        result.attack +%= result.power;
        result.attack +%= weapon.powers[owned.weapon_level - 1];
        result.armour +%= result.defense;
        return result;
    }
};
