const std = @import("std");
const battle = @import("battle");

pub const Definition = struct {
    schema: []const u8,
    member: []const u8,
    minimum_tier: u8,
    level_advances: u8,
    seed: battle.OwnedMember,

    pub fn validate(self: Definition, combat: battle.State) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-recruitment/1") or
            !std.mem.eql(u8, self.member, "maas") or
            !std.mem.eql(u8, self.seed.member.id, self.member) or
            self.minimum_tier != 1 or self.level_advances != 17) return error.InvalidRecruitment;
        try combat.validateOwnedMember(self.seed);
        const profile = combat.content.partyProfile(self.member).?;
        const weapon = profile.weapon orelse return error.InvalidRecruitment;
        if (self.seed.stats.attack < weapon.powers[weapon.initial_level - 1]) return error.InvalidRecruitment;
    }

    pub fn drawCount(self: Definition) usize {
        return @as(usize, @min(self.level_advances, 99 - self.seed.level)) * 7;
    }
};

// Event growth uses raw STR; battle profiles include their initial weapon power.
pub fn prepare(definition: Definition, combat: battle.State, draws: []const u15) !battle.OwnedMember {
    try definition.validate(combat);
    if (draws.len != definition.drawCount()) return error.InvalidRecruitmentDraws;
    var members = [_]battle.Member{definition.seed.member};
    var candidate = combat;
    candidate.progress.party = &members;
    candidate.setOwnedMember(0, definition.seed);
    candidate.clearTemporaryStats();
    const weapon = candidate.partyProfile(0).weapon.?;
    const initial_power = weapon.powers[weapon.initial_level - 1];
    candidate.base_stats[0].attack -= initial_power;
    var cursor: usize = 0;
    while (cursor < draws.len) : (cursor += 7) candidate.levelUp(0, draws[cursor..][0..7].*);
    candidate.base_stats[0].attack += initial_power;
    candidate.refillMagic(0);
    const result = candidate.ownedMember(0);
    try combat.validateOwnedMember(result);
    return result;
}
