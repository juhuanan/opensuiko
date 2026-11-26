//! Duel, war, ending, and battle mode lifecycle & update handlers for journey.State.
const std = @import("std");
const battle_flow = @import("../journey_battle.zig");
const roster = @import("../journey_roster.zig");
const party_session = @import("party_session");
const battle = @import("battle");
const duel = @import("duel");
const war = @import("war");
const war_session = @import("war_session");
const war_scenarios_data = @import("war_scenarios_data");
const chapters = @import("chapters");
const final_assets = @import("final_assets");
const journey = @import("../journey.zig");

pub fn deinitActiveModes(state: *journey.State) void {
    if (state.active_duel) |*active| {
        active.parsed.deinit();
        state.active_duel = null;
    }
    if (state.active_war) |*active| {
        active.session.deinit();
        if (active.parsed) |parsed| parsed.deinit();
        state.active_war = null;
    }
    if (state.active_ending) |*active| {
        active.parsed.deinit();
        state.active_ending = null;
    }
}

pub fn startDuelById(state: *journey.State, allocator: std.mem.Allocator, duel_id: []const u8) !void {
    if (state.mode != .field or state.active_duel != null or state.active_war != null or state.active_ending != null) return error.GameBusy;
    const player = blk: {
        const target_id = if (std.mem.eql(u8, duel_id, "pahn_teo")) "pahn" else "hero";
        for (state.combat.progress.party.items(), 0..) |member, index| {
            if (std.mem.eql(u8, member.id, target_id)) break :blk duelFighter(member.*, state.combat.stats(index));
        }
        for (state.reserve_slots[0..state.reserveCount()]) |slot| {
            const owned = state.combat.progress.party.backing()[slot.?];
            if (!std.mem.eql(u8, owned.id, target_id)) continue;
            const augment = owned.weapon_augment;
            break :blk duelFighter(owned, battle.equippedStats(state.combat.content, owned, augment));
        }
        break :blk duel.FighterState{ .maximum_hp = 240, .hp = 240, .attack = 160, .defense = 80 };
    };
    const seed: u32 = @max(@as(u32, 1), @as(u32, @truncate(state.elapsed_ticks +% 1)));
    try startDuelWithOpponent(state, allocator, duel_id, player, null, .{ .bios_state = seed });
}

fn duelFighter(member: battle.Member, stats: battle.Stats) duel.FighterState {
    const maximum_hp: i32 = @max(@as(i32, member.max_hp), 1);
    return .{ .maximum_hp = maximum_hp, .hp = std.math.clamp(@as(i32, member.hp), 1, maximum_hp), .attack = stats.attack, .defense = stats.defense };
}

pub fn startDuel(state: *journey.State, allocator: std.mem.Allocator, duel_id: []const u8, fighters: [2]duel.FighterState, random: duel.Random) !void {
    try startDuelWithOpponent(state, allocator, duel_id, fighters[0], fighters[1], random);
}

fn startDuelWithOpponent(state: *journey.State, allocator: std.mem.Allocator, duel_id: []const u8, player: duel.FighterState, opponent: ?duel.FighterState, random: duel.Random) !void {
    if (state.mode != .field or state.active_duel != null or state.active_war != null or state.active_ending != null) return error.GameBusy;
    var parsed = try duel.load(allocator, duel.content_json);
    errdefer parsed.deinit();
    const entry = duel.findDuel(&parsed.value, duel_id) orelse return error.UnknownDuel;
    const initial_opponent = opponent orelse entry.initial_opponent orelse return error.InvalidDuelContent;
    const duel_state = try duel.State.init(&parsed.value, duel_id, .{ player, initial_opponent }, random);
    state.active_duel = .{ .parsed = parsed, .state = duel_state };
    state.mode = .duel;
    state.field_state.walking = false;
    state.field_state.action_pending = false;
}

pub fn chooseDuelCommand(state: *journey.State, command: duel.Command) !void {
    if (state.mode != .duel) return error.NotInDuel;
    const active = &(state.active_duel orelse return error.NotInDuel);
    try active.state.choose(command);
}

pub fn tickDuel(state: *journey.State, up: bool, down: bool, confirm: bool) !void {
    if (state.mode != .duel) return error.NotInDuel;
    const active = &(state.active_duel orelse return error.NotInDuel);
    switch (active.state.phase) {
        .choosing => {
            if (up) try active.state.moveSelection(-1) else if (down) try active.state.moveSelection(1);
            if (confirm) try active.state.confirm();
        },
        .finished => if (confirm) {
            const outcome = active.state.outcome orelse .defeat;
            const won = outcome == .victory;
            if (state.scripted_battle) |*scripted| {
                if (std.mem.eql(u8, scripted.request.id, "duel:pahn_teo")) {
                    const bit: u8 = if (won) 1 else 2;
                    state.recordPahnDuel(bit);
                }
                if (won or state.defeatContinuesScene() or !state.defeatEndsRun()) {
                    scripted.confirmed = if (!won and state.defeatContinuesScene()) .defeat else .victory;
                    return;
                }
                active.parsed.deinit();
                state.active_duel = null;
                state.checkpoint = null;
                state.field_event = null;
                state.scripted_battle = null;
                state.mode = .game_over;
                return;
            }
            active.parsed.deinit();
            state.active_duel = null;
            state.mode = if (won) .field else .defeat;
        },
        else => try active.state.tick(),
    }
}

pub fn startEnding(state: *journey.State, allocator: std.mem.Allocator) !void {
    if (state.mode != .field or state.active_duel != null or state.active_war != null or state.active_ending != null) return error.GameBusy;
    var parsed = try chapters.endings.open(allocator, final_assets.endings.json);
    errdefer parsed.deinit();
    var recruit_flags: [108]u8 = @splat(0);
    if (state.field_state.progress.story.scenario) |story| recruit_flags = roster.recruitFlags(story);
    recruit_flags[8] |= 1;
    const census = try chapters.endings.census(parsed.value, &recruit_flags);
    state.active_ending = .{ .parsed = parsed, .census = census, .recruit_flags = recruit_flags };
    state.mode = .ending;
    state.field_state.walking = false;
    state.field_state.action_pending = false;
}

pub fn tickEnding(state: *journey.State, up: bool, down: bool, confirm: bool) !void {
    if (state.mode != .ending) return error.NotInEnding;
    const active = &(state.active_ending orelse return error.NotInEnding);
    const total_phases = active.parsed.value.bounded_ending.main_ending_phases;
    if (active.phase_index < total_phases) {
        if (confirm) active.phase_index += 1;
        return;
    }
    const total_entries: u16 = @intCast(active.parsed.value.entries.len);
    if (up and active.entry_cursor > 0) active.entry_cursor -= 1;
    if (down and active.entry_cursor + 8 < total_entries) active.entry_cursor += 1;
    if (confirm) {
        if (state.scripted_battle) |*scripted| {
            scripted.confirmed = .victory;
            return;
        }
        active.parsed.deinit();
        state.active_ending = null;
        state.mode = .field;
    }
}

pub fn startWar(state: *journey.State, allocator: std.mem.Allocator, entry: war_session.Entry) !void {
    if (state.mode != .field or state.active_duel != null or state.active_war != null) return error.GameBusy;
    const session = try war_session.Session.init(allocator, entry);
    state.active_war = .{ .session = session };
    state.mode = .war;
    state.field_state.walking = false;
    state.field_state.action_pending = false;
}

pub fn startWarById(state: *journey.State, allocator: std.mem.Allocator, scenario_id: []const u8, rng_state: u32) !void {
    if (state.mode != .field or state.active_duel != null or state.active_war != null) return error.GameBusy;
    const parsed = try war.load(allocator, war_scenarios_data.json);
    errdefer parsed.deinit();
    const scenario = for (parsed.value.scenarios) |row| {
        if (std.mem.eql(u8, row.id, scenario_id)) break row;
    } else return error.UnknownWarScenario;
    const session = try war_session.Session.init(allocator, .{ .scenario = scenario, .rng = .{ .state = rng_state } });
    state.active_war = .{ .session = session, .parsed = parsed };
    state.mode = .war;
    state.field_state.walking = false;
    state.field_state.action_pending = false;
}

pub fn tickWar(state: *journey.State, input: war_session.Input) !void {
    if (state.mode != .war) return error.NotInWar;
    const active = &(state.active_war orelse return error.NotInWar);
    if (active.session.engine.phase == .result) {
        if (input.confirm) {
            const result = active.session.engine.result orelse return error.InvalidWarState;
            const won = result.outcome != .forced_defeat and result.outcome != .side1_victory;
            if (state.scripted_battle) |*scripted| {
                if (won or state.defeatContinuesScene()) {
                    scripted.confirmed = if (won) .victory else .defeat;
                    return;
                }
                active.session.deinit();
                if (active.parsed) |parsed| parsed.deinit();
                state.active_war = null;
                state.checkpoint = null;
                state.field_event = null;
                state.scripted_battle = null;
                state.mode = .game_over;
                return;
            }
            active.session.deinit();
            if (active.parsed) |parsed| parsed.deinit();
            state.active_war = null;
            state.mode = if (won) .field else .defeat;
        }
        return;
    }
    try active.session.update(input);
}

pub fn tickDefeat(state: *journey.State, combat_input: battle.Input) void {
    if (state.combat.hasDepartureFlights()) {
        state.combat.advanceDefeatDeparture();
    } else if (combat_input.confirm) {
        if (state.defeatContinuesScene()) {
            state.scripted_battle.?.confirmed = .defeat;
        } else if (state.defeatEndsRun() or state.checkpoint == null) {
            state.mode = .game_over;
            state.checkpoint = null;
            state.field_event = null;
            state.scripted_battle = null;
        } else battle_flow.retryCombat(state) catch unreachable;
    }
}

pub fn tickBattle(state: *journey.State, combat_input: battle.Input) void {
    if (state.scripted_battle) |active| if (active.confirmed != null) return;
    const result: ?journey.ScriptedBattleResult = if (combat_input.confirm) switch (state.combat.phase) {
        .victory => if (state.combat.rewardReady()) .victory else null,
        .escaped => .escape,
        else => null,
    } else null;
    if (result) |outcome| {
        if (state.scripted_battle) |*active| active.confirmed = outcome else battle_flow.returnFromBattle(state, outcome == .victory);
    } else {
        var action = combat_input;
        if (state.scripted_battle != null) action.restart = false;
        // Field encounters leave through Run/Let go, rather than the isolated trial's quit menu.
        if (state.combat.phase == .battle_menu) action.cancel = false;
        state.combat.tick(action);
        if (state.combat.phase == .defeat) state.mode = .defeat;
    }
}
