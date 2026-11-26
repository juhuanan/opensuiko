const Character = @import("field").game_state.Character;

pub fn capture(comptime field: []const u8, party: @import("field").game_state.Party) [6]@FieldType(Character, field) {
    var result: [6]@FieldType(Character, field) = @splat(@field(@as(Character, .{
        .id = "",
        .name = "",
        .status = .healthy,
        .hp = 1,
        .max_hp = 1,
        .rune_charges = @splat(0),
        .max_rune_charges = @splat(0),
    }), field));
    for (party.items(), 0..) |member, i| result[i] = @field(member.*, field);
    return result;
}
