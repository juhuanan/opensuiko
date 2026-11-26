const std = @import("std");
const character_state = @import("field").game_state;

pub const Definition = struct {
    schema: []const u8,
    member: []const u8,
    minimum_tier: u8,
    level_advances: u8,
    seed: character_state.OwnedMemberRecord,

    pub fn validate(self: Definition, rules: character_state.CharacterRules) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-recruitment/1") or
            !std.mem.eql(u8, self.member, "maas") or
            !std.mem.eql(u8, self.seed.member.id, self.member) or
            self.minimum_tier != 1 or self.level_advances != 17) return error.InvalidRecruitment;
        try rules.validate(self.seed.character());
        const profile = rules.profile(self.member).?;
        const weapon = profile.weapon orelse return error.InvalidRecruitment;
        if (self.seed.stats.attack < weapon.powers[weapon.initial_level - 1]) return error.InvalidRecruitment;
    }

    pub fn drawCount(self: Definition) usize {
        return @as(usize, @min(self.level_advances, 99 - self.seed.level)) * 7;
    }
};

// Event growth uses raw STR; battle profiles include their initial weapon power.
pub fn prepare(definition: Definition, rules: character_state.CharacterRules, draws: []const u15) !character_state.Character {
    try definition.validate(rules);
    if (draws.len != definition.drawCount()) return error.InvalidRecruitmentDraws;
    const tables = rules.tables.?;
    const profile = rules.profile(definition.member).?;
    const weapon = profile.weapon.?;
    const initial_power = weapon.powers[weapon.initial_level - 1];
    var result = definition.seed.character();
    result.id = profile.id;
    result.name = profile.name;
    result.base_stats.attack -= initial_power;
    var cursor: usize = 0;
    while (cursor < draws.len) : (cursor += 7) {
        result.levelUp(tables, profile.growth, draws[cursor..][0..7].*);
    }
    result.base_stats.attack += initial_power;
    result.refillRuneCharges(tables);
    try rules.validate(result);
    return result;
}
