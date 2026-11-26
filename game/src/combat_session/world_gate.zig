const std = @import("std");
const battle = @import("battle");
const world = @import("world");
const session = @import("combat_session");

pub const Step = struct {
    event: world.Event,
    combat: ?session.Session = null,
};

// The world driver owns movement, counter, guards, status processing and draws.
// Admission failure rolls its entire update back, including poison/healing.
pub fn tick(travel: *world.State, content: world.Content, input: world.Input, party: world.Party, draws: *world.Draws, battle_source: battle.State, scratch: []battle.Member, entry_id: []const u8, receipt: []const u8, content_id: []const u8, content_fingerprint: []const u8) !Step {
    if (travel.mode == .battle_pending) {
        const id = travel.selected orelse return error.InvalidWorldState;
        if (content.encounter(id) == null) return error.InvalidWorldState;
    }
    if (travel.mode == .field_pending and travel.pending_entrance == null) return error.InvalidWorldState;
    if (!party.members.equal(battle_source.progress.party) or party.members.len > 6) return error.WorldPartyMismatch;
    const old_travel = travel.*;
    const old_draws = draws.*;
    var old_members: [6]battle.Member = undefined;
    party.members.copyTo(old_members[0..party.members.len]);
    errdefer {
        travel.* = old_travel;
        draws.* = old_draws;
        party.members.copyFrom(old_members[0..party.members.len]);
    }
    const event = try travel.tick(content, input, draws, party);
    return switch (event) {
        .battle => |encounter| .{ .event = event, .combat = try session.Session.begin(.{ .id = entry_id, .receipt = receipt, .content_id = content_id, .encounter_id = encounter.id, .content_fingerprint = content_fingerprint }, battle_source, scratch, draws.*) },
        else => .{ .event = event },
    };
}

pub const ReturnPlan = struct {
    world_id: []const u8,
    before: world.State,
    after: world.State,
    outcome: world.Outcome,
    result: session.Result,
};

// The caller commits this plan and the battle receipt with its canonical roster,
// money and RNG in one transaction; merely constructing it mutates no world.
pub fn returnPlan(content: world.Content, travel: world.State, expected: session.Entry, result: session.Result) !ReturnPlan {
    try travel.validate(content);
    if (travel.mode != .battle) return error.NotInWorldBattle;
    const selected = travel.selected orelse return error.InvalidWorldState;
    if (!std.mem.eql(u8, selected, result.entry.encounter_id) or !std.mem.eql(u8, expected.id, result.entry.id) or !std.mem.eql(u8, expected.receipt, result.entry.receipt) or !std.mem.eql(u8, expected.content_id, result.entry.content_id) or !std.mem.eql(u8, expected.encounter_id, result.entry.encounter_id) or !std.mem.eql(u8, expected.content_fingerprint, result.entry.content_fingerprint)) return error.CombatIdentityMismatch;
    if (!result.draws.valid() or result.member_count == 0 or result.member_count > 6) return error.InvalidCombatResult;
    const outcome: world.Outcome = switch (result.outcome) {
        .victory => .victory,
        .fled, .bribed => .fled,
        .released => .released,
        .defeat => .defeated,
    };
    var next = travel;
    try next.finishBattle(outcome);
    return .{ .world_id = content.id, .before = travel, .after = next, .outcome = outcome, .result = result };
}
