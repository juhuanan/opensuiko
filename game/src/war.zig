const std = @import("std");

pub const schema = "suikoden-war-rules/4";
pub const max_json_bytes = 4 * 1024 * 1024;
pub const max_units = 64;
pub const max_events = 256;

pub const Source = struct { file: []const u8, lba: u32, size: u32, sha256: []const u8 };
pub const Leader = struct {
    id: u8,
    record_offset: u32,
    troops: u16,
    flags: u8,
    unit_class: u8,
    attack_class: u8,
    variant: u8,
    member_ids: []const u16,
};
pub const LeaderContract = struct {
    record_bytes: u8,
    record_count: u8,
    fields: []const u8,
    leaders: []const Leader,
};
pub const Attack = struct {
    offset: u32,
    flags: u32,
    name: []const u8,
    parameter0: u32,
    parameter1: u32,
};
pub const State = enum(u8) {
    idle = 0,
    reset = 1,
    move = 2,
    melee = 3,
    ranged = 4,
    effect = 5,
    impact = 6,
    retiring = 7,
    retreat = 8,
    special_wait = 9,
    special_move = 10,
    inert = 11,
    finished = 12,
};
pub const Unit = struct {
    x: i32,
    y: i32,
    target_x: i32,
    target_y: i32,
    velocity_x: i32,
    velocity_y: i32,
    state: State,
    state_code: u8,
    secondary_state: u8,
    counter: i16,
};
pub const InitialSide = struct { total_records: u8, remaining_records: u8, records: []const Unit };
pub const InitializationProof = struct {
    initializer: []const u8,
    total_address: u32,
    parameter_address: u32,
    unit_table_address: u32,
    unit_count_address: u32,
    record_stride: u8,
    coordinate_rule: []const u8,
    setup_instruction_calls: u32,
};
pub const Initial = struct {
    initial_army_troops: u32,
    scenario_parameter: u32,
    initial_stage: u8,
    sides: []const InitialSide,
    proof: InitializationProof,
};
pub const ScriptTransition = struct {
    phase: u8,
    ticks: u16,
    next: u8,
    terminal: bool = false,
};
pub const Lifecycle = struct {
    kind: []const u8,
    phase_entry: u32,
    phase_state_address: u32,
    main_state_address: u32,
    phase_table_address: u32,
    phase_table: []const u32,
    wait_phase: u8,
    dispatch_phase: u8,
    confirmation_count: u8,
    second_confirmation_phase: u8,
    completion_main_phase: u8,
    transitions: []const ScriptTransition,
    proof: []const u8,
};
pub const EnemyPolicy = struct {
    range_address: u32,
    action_map_address: u32,
    ranges: [5][2]u8,
    action_map: [9]u8,
    selector: []const u8,
};
pub const Scenario = struct {
    selector: u8,
    id: []const u8,
    source: Source,
    initial: Initial,
    lifecycle: Lifecycle,
    attacks: []const Attack,
    enemy_policy: ?EnemyPolicy,
    leaders: []const Leader,
    content_sha256: []const u8,
    troops_per_record: u16 = 300,
};
pub const Packet = struct {
    schema: []const u8,
    id: []const u8,
    target: []const u8,
    selector_contract: []const u8,
    leader_contract: LeaderContract,
    state_contract: std.json.Value,
    rng_contract: []const u8,
    casualty_contract: []const u8,
    ordinary_contract: std.json.Value,
    special_contract: std.json.Value,
    troops_per_record: ?[9]u16 = null,
    scenarios: []Scenario,
    variant_matrix: []const std.json.Value,
    content_sha256: []const u8,

    pub fn scenario(self: Packet, id: []const u8) ?Scenario {
        for (self.scenarios) |candidate| if (std.mem.eql(u8, candidate.id, id)) return candidate;
        return null;
    }
};

pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Packet) {
    if (bytes.len > max_json_bytes) return error.WarContentTooLarge;
    const parsed = try std.json.parseFromSlice(Packet, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    try validate(parsed.value);
    // Packet metadata leaves saved scenario identities intact.
    const costs: [9]u16 = parsed.value.troops_per_record orelse @splat(300);
    for (parsed.value.scenarios, costs) |*scenario, cost| scenario.troops_per_record = cost;
    return parsed;
}

pub fn validate(packet: Packet) !void {
    const legacy = std.mem.eql(u8, packet.schema, "suikoden-war-rules/3");
    if ((!legacy and !std.mem.eql(u8, packet.schema, schema)) or
        packet.scenarios.len != 9 or packet.leader_contract.leaders.len != 108 or
        (packet.troops_per_record == null) != legacy) return error.InvalidWarContent;
    if (packet.troops_per_record) |costs| for (costs) |cost| {
        if (cost == 0) return error.InvalidWarContent;
    };
    for (packet.scenarios, 0..) |scenario, index| {
        if (scenario.selector != index or scenario.initial.sides.len != 2 or scenario.attacks.len == 0 or scenario.leaders.len != 108 or scenario.lifecycle.phase_table.len != 17) return error.InvalidWarScenario;
        const empty = scenario.initial.sides[0].total_records == 0 and scenario.initial.sides[1].total_records == 0;
        const scripted = std.mem.eql(u8, scenario.lifecycle.kind, "scripted");
        if (scripted != empty or (!scripted and !std.mem.eql(u8, scenario.lifecycle.kind, "unit_battle")) or
            scenario.lifecycle.confirmation_count != (if (scripted) @as(u8, 2) else @as(u8, 4))) return error.InvalidWarLifecycle;
        for (scenario.lifecycle.transitions) |transition| {
            if (transition.ticks == 0 or transition.phase >= 17 or transition.next >= 17) return error.InvalidWarLifecycle;
        }
        if ((scenario.enemy_policy == null) != scripted) return error.InvalidWarEnemyState;
        if (scenario.enemy_policy) |policy| for (policy.ranges) |range| {
            if (range[0] > range[1] or range[1] >= scenario.attacks.len) return error.InvalidWarEnemyState;
        };
        for (scenario.initial.sides) |side| {
            if (side.total_records != side.remaining_records or side.total_records != side.records.len or side.total_records > max_units) return error.InvalidWarInitialForce;
            for (side.records) |unit| if (unit.state_code != @backingInt(unit.state)) return error.InvalidWarUnitState;
        }
    }
    for (packet.leader_contract.leaders, 0..) |leader, index| {
        if (leader.id != index or leader.member_ids.len != (if (index < 36) @as(usize, 3) else @as(usize, 0))) return error.InvalidWarLeader;
    }
}

pub fn isScripted(scenario: Scenario) bool {
    return std.mem.eql(u8, scenario.lifecycle.kind, "scripted");
}

pub fn teamStrength(scenario: Scenario, team: u8, recruited: []const bool, charge_boost: u8) !u8 {
    if (team >= 36 or recruited.len != 108) return error.InvalidWarTeam;
    var strength: u8 = 0;
    var first_flags: ?u8 = null;
    for (scenario.leaders[team].member_ids) |member| {
        if (member >= recruited.len) return error.InvalidWarTeam;
        if (!recruited[member]) continue;
        const combatant = scenario.leaders[member];
        if (first_flags == null) {
            first_flags = combatant.flags;
            strength = combatant.unit_class;
        } else {
            strength +%= combatant.attack_class;
        }
    }
    if (first_flags != null and first_flags.? == 0 and charge_boost != 0) strength +%= strength >> 1;
    return strength;
}

pub fn teamAvailable(scenario: Scenario, team: u8, category: u8, recruited: []const bool) !bool {
    if (team >= 36 or category > 3 or recruited.len != 108) return error.InvalidWarTeam;
    for (scenario.leaders[team].member_ids) |member| {
        if (member >= recruited.len) return error.InvalidWarTeam;
        if (recruited[member]) return scenario.leaders[member].flags == category;
    }
    return false;
}

pub fn initialTroops(scenario: Scenario, recruited: []const bool) !u32 {
    if (recruited.len != 108) return error.InvalidWarRoster;
    var total: u32 = 0;
    for (scenario.leaders, recruited) |combatant, present| {
        if (present) total += combatant.troops;
    }
    return total;
}

pub const OrdinaryAction = struct {
    category: u8,
    team: u8,
    enemy_attack: u8,
};
pub const ActionResolution = struct {
    losses: [2]i32,
    remaining_troops: [2]i32,
    action_code: u8,
    player_strength: u8,
    enemy_strength: u8,
};

fn randomQuotient(rng: *Random) i32 {
    return @intCast(rng.next() / 541);
}

pub fn resolveOrdinary(
    scenario: Scenario,
    action: OrdinaryAction,
    player_troops: u32,
    enemy_troops: u32,
    recruited: []const bool,
    charge_boost: u8,
    rng: *Random,
) !ActionResolution {
    if (action.category >= 3 or action.enemy_attack >= scenario.attacks.len) return error.InvalidWarAction;
    const attack = scenario.attacks[action.enemy_attack];
    const enemy_type = attack.flags & 3;
    const policy = scenario.enemy_policy orelse return error.UnsupportedWarScenario;
    const action_code = policy.action_map[action.category * 3 + enemy_type];
    const team_strength = try teamStrength(scenario, action.team, recruited, charge_boost);
    const enemy_strength: u8 = @intCast((attack.flags >> 8) & 0xFF);
    const player = @as(i32, team_strength) + @as(i32, @intCast(player_troops / 3000));
    const enemy = @as(i32, enemy_strength) + @as(i32, @intCast(enemy_troops / 3000));
    var remaining = [2]i32{ 0, 0 };
    switch (action_code) {
        0 => switch (action.category) {
            0 => {
                remaining[1] = 130 * player + randomQuotient(rng) - 30;
                remaining[0] = 80 * player + randomQuotient(rng) - 30;
            },
            1 => remaining[1] = 120 * player + randomQuotient(rng) - 30,
            2 => remaining[1] = 200 * @as(i32, team_strength),
            else => unreachable,
        },
        1 => switch (action.category) {
            0 => remaining[0] = 200 * @as(i32, enemy_strength),
            1 => {
                remaining[1] = 80 * player + randomQuotient(rng) - 30;
                remaining[0] = 130 * player + randomQuotient(rng) - 30;
            },
            2 => remaining[0] = 120 * enemy + randomQuotient(rng) - 30,
            else => unreachable,
        },
        2 => switch (action.category) {
            0 => {
                remaining[1] = 100 * player + randomQuotient(rng) - 30;
                remaining[0] = 100 * enemy + randomQuotient(rng) - 30;
            },
            1 => {
                remaining[1] = 90 * player + randomQuotient(rng) - 30;
                remaining[0] = 90 * enemy + randomQuotient(rng) - 30;
            },
            2 => remaining[1] = 200 * @as(i32, team_strength),
            else => unreachable,
        },
        else => return error.InvalidWarAction,
    }
    return .{
        .losses = .{ @as(i32, @intCast(player_troops)) - remaining[0], @as(i32, @intCast(enemy_troops)) - remaining[1] },
        .remaining_troops = remaining,
        .action_code = action_code,
        .player_strength = team_strength,
        .enemy_strength = enemy_strength,
    };
}

pub const SpecialKind = enum { ninja, thieves, strategists, dragon_knights, merchants };
pub const SpecialResolution = struct {
    kind: SpecialKind,
    enemy_attack: u8,
    bits_awarded: u32 = 0,
    charge_boost: u8 = 0,
    player_loss: u32 = 0,
    enemy_loss: u32 = 0,
};

pub fn specialKind(team: u8) ?SpecialKind {
    return switch (team) {
        24 => .thieves,
        32 => .strategists,
        33 => .ninja,
        34 => .dragon_knights,
        35 => .merchants,
        else => null,
    };
}

pub fn resolveSpecial(
    scenario: Scenario,
    team: u8,
    enemy_attack: u8,
    current_bits: u32,
    player_troops: u32,
    enemy_troops: u32,
    recruited: []const bool,
    rng: *Random,
) !SpecialResolution {
    const kind = specialKind(team) orelse return error.InvalidWarCommand;
    if (enemy_attack >= scenario.attacks.len) return error.InvalidWarAction;
    var result: SpecialResolution = .{ .kind = kind, .enemy_attack = enemy_attack };
    switch (kind) {
        .ninja => {},
        .strategists => result.charge_boost = try teamStrength(scenario, team, recruited, 0),
        .thieves => {
            const roll = @as(u32, rng.next()) / 8191;
            if (roll >= 3) result.bits_awarded = @min(2000, 999999 -| current_bits);
        },
        .merchants => {
            if ((scenario.attacks[enemy_attack].flags & 3) != 1) result.enemy_loss = enemy_troops / 4;
        },
        .dragon_knights => {
            const roll = @as(u32, rng.next()) / 8191;
            if (roll != 0) {
                const damage = if (player_troops < enemy_troops / 8) enemy_troops / 4 else enemy_troops / 8;
                result.player_loss = player_troops + damage;
                result.enemy_loss = damage;
            }
        },
    }
    return result;
}

pub const Random = struct {
    state: u32,
    cursor: u64 = 0,

    pub fn next(self: *Random) u15 {
        self.state = self.state *% 0x41C64E6D +% 0x3039;
        self.cursor += 1;
        return @intCast((self.state >> 16) & 0x7FFF);
    }
};

pub const EnemyState = struct {
    group: u8 = 0,
    used: [6]bool = @splat(false),
};

pub fn nextEnemyAttack(scenario: Scenario, state: *EnemyState, rng: *Random) !u8 {
    if (state.group >= 5) return error.InvalidWarEnemyState;
    const policy = scenario.enemy_policy orelse return error.UnsupportedWarScenario;
    const range = policy.ranges[state.group];
    const span = @as(u32, range[1] - range[0] + 1);
    if (span == 0) return error.InvalidWarEnemyState;
    const divisor = @as(u32, 32767) / span;
    if (divisor == 0) return error.InvalidWarEnemyState;
    for (0..32) |_| {
        const candidate = @as(u32, range[0]) + @as(u32, rng.next()) / divisor;
        if (candidate >= scenario.attacks.len or candidate >= state.used.len) return error.InvalidWarEnemyAttack;
        if (!state.used[candidate]) {
            state.used[candidate] = true;
            if (state.group == 4) {
                state.group = 0;
                for (0..5) |index| state.used[index] = false;
            } else {
                state.group += 1;
            }
            return @intCast(candidate);
        }
    }
    return error.WarEnemySelectionExhausted;
}

pub const Command = enum { move, charge, bow, magic, retreat, special };
pub const Outcome = enum { side0_victory, side1_victory, forced_victory, forced_defeat, scripted_completion };
pub const Phase = enum { player_command, resolving, scripted, result };
pub const SideState = struct {
    total: u8,
    remaining: u8,
    units: []Unit,
};
pub const Event = struct {
    kind: enum { state, command, casualty, message, effect, script, outcome },
    side: u8,
    index: u8,
    state: ?State = null,
    command: ?Command = null,
    amount: i32 = 0,
    x: i32 = 0,
    y: i32 = 0,
};
pub const ConsequenceKind = enum { scenario_victory, scenario_defeat, scenario_completed, casualties, scenario_parameter, bits };
pub const ConsequenceRequest = struct {
    kind: ConsequenceKind,
    scenario_id: []const u8,
    side: ?u8 = null,
    amount: i32,
};
pub fn recordsAfterLoss(current: u8, troop_loss: u16, troops_per_record: u16) u8 {
    if (troop_loss == 0) return current;
    return current -% @as(u8, @truncate(@as(u32, troop_loss) / troops_per_record + 1));
}

fn boundedRecordsAfterLoss(current: u8, troop_loss: u16, troops_per_record: u16) u8 {
    if (troop_loss == 0) return current;
    const lost_records = @as(u32, troop_loss) / troops_per_record + 1;
    if (lost_records >= current) return 0;
    return @intCast(current - lost_records);
}

pub fn troopsLost(previous_records: u8, current_records: u8, initial_troops: u32) u32 {
    if (previous_records == 0) return initial_troops;
    const difference = @as(i32, previous_records) - @as(i32, current_records);
    if (difference <= 0) return 0;
    return @intCast(@divTrunc(@as(i64, difference) * @as(i64, initial_troops), @as(i64, previous_records)));
}

pub const Result = struct {
    outcome: Outcome,
    casualties: [2]u32,
    rng: Random,
    attempt_id: u64,
    receipt: u64,
    consequence_count: u8,
    consequences: [5]ConsequenceRequest,
};

fn makeResult(engine: *const Engine, outcome: Outcome) Result {
    const casualties = if (outcome == .scripted_completion) [2]u32{ 0, 0 } else [2]u32{
        troopsLost(engine.scenario.initial.sides[0].total_records, engine.sides[0].remaining, engine.scenario.initial.initial_army_troops),
        troopsLost(engine.scenario.initial.sides[1].total_records, engine.sides[1].remaining, engine.scenario.initial.scenario_parameter),
    };
    return .{
        .outcome = outcome,
        .casualties = casualties,
        .rng = engine.rng,
        .attempt_id = engine.attempt_id,
        .receipt = engine.updates,
        .consequence_count = 5,
        .consequences = .{
            .{ .kind = if (outcome == .scripted_completion) .scenario_completed else if (outcome == .forced_defeat or outcome == .side1_victory) .scenario_defeat else .scenario_victory, .scenario_id = engine.scenario.id, .amount = @backingInt(outcome) },
            .{ .kind = .casualties, .scenario_id = engine.scenario.id, .side = 0, .amount = @intCast(casualties[0]) },
            .{ .kind = .casualties, .scenario_id = engine.scenario.id, .side = 1, .amount = @intCast(casualties[1]) },
            .{ .kind = .scenario_parameter, .scenario_id = engine.scenario.id, .amount = @intCast(engine.scenario.initial.scenario_parameter) },
            .{ .kind = .bits, .scenario_id = engine.scenario.id, .amount = @intCast(engine.bits_earned) },
        },
    };
}

pub const ScriptState = struct {
    phase: u8 = 0,
    previous_phase: u8 = 0,
    clock: u16 = 0,
    confirmations: u8 = 0,
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    scenario: Scenario,
    phase: Phase,
    sides: [2]SideState,
    troops: [2]u32,
    rng: Random,
    attempt_id: u64 = 1,
    enemy: EnemyState = .{},
    scouted_attack: ?u8 = null,
    ninja_scouts_used: u8 = 0,
    recruited: [108]bool = @splat(true),
    team_alive: [36]bool = @splat(true),
    charge_boost: u8 = 0,
    bits: u32 = 0,
    bits_earned: u32 = 0,
    script: ?ScriptState = null,
    selected_side: u8 = 0,
    selected_index: u8 = 0,
    events: [max_events]Event = undefined,
    event_count: usize = 0,
    result: ?Result = null,
    updates: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, scenario: Scenario, rng: Random) !Engine {
        const scripted = isScripted(scenario);
        const empty = scenario.initial.sides[0].total_records == 0 and scenario.initial.sides[1].total_records == 0;
        if (scripted != empty or scenario.troops_per_record == 0) return error.InvalidWarScenarioInitialization;
        if (!scripted and (scenario.initial.sides[0].total_records == 0 or scenario.initial.sides[1].total_records == 0)) return error.UnsupportedWarScenarioInitialization;
        var sides: [2]SideState = undefined;
        var initialized: usize = 0;
        errdefer for (sides[0..initialized]) |side| allocator.free(side.units);
        for (scenario.initial.sides, 0..) |initial, index| {
            if (initial.records.len > max_units) return error.InvalidWarInitialForce;
            sides[index] = .{
                .total = initial.total_records,
                .remaining = initial.remaining_records,
                .units = try allocator.dupe(Unit, initial.records),
            };
            initialized += 1;
        }
        return .{
            .allocator = allocator,
            .scenario = scenario,
            .phase = .scripted,
            .sides = sides,
            .troops = .{ scenario.initial.initial_army_troops, scenario.initial.scenario_parameter },
            .rng = rng,
            .script = .{},
        };
    }

    pub fn deinit(self: *Engine) void {
        for (self.sides) |side| self.allocator.free(side.units);
        self.* = undefined;
    }

    pub fn eventSlice(self: *const Engine) []const Event {
        return self.events[0..self.event_count];
    }

    fn emit(self: *Engine, event: Event) void {
        if (self.event_count < max_events) {
            self.events[self.event_count] = event;
            self.event_count += 1;
        }
    }

    fn transition(self: *Engine, side: u8, index: u8, state: State) void {
        const unit = &self.sides[side].units[index];
        unit.state = state;
        unit.state_code = @backingInt(state);
        self.emit(.{ .kind = .state, .side = side, .index = index, .state = state, .x = unit.x, .y = unit.y });
    }

    fn validateUnit(self: *const Engine, side: u8, index: u8) !void {
        if (side > 1 or index >= self.sides[side].total or self.phase == .result) return error.InvalidWarCommand;
        if (self.sides[side].units[index].state == .finished) return error.InvalidWarCommand;
    }

    fn issueSpecial(self: *Engine, team: u8) !void {
        if (self.script != null or self.phase != .player_command) return error.InvalidWarCommand;
        const kind = specialKind(team) orelse return error.InvalidWarCommand;
        if (team >= 36 or !self.team_alive[team] or !try teamAvailable(self.scenario, team, 3, &self.recruited)) return error.InvalidWarCommand;
        if (kind == .ninja and self.scouted_attack != null) return error.InvalidWarCommand;
        const enemy_attack = self.scouted_attack orelse try nextEnemyAttack(self.scenario, &self.enemy, &self.rng);
        const resolution = try resolveSpecial(self.scenario, team, enemy_attack, self.bits, self.troops[0], self.troops[1], &self.recruited, &self.rng);
        if (kind == .ninja) {
            self.scouted_attack = enemy_attack;
            self.ninja_scouts_used += 1;
            var available: u8 = 0;
            for (self.scenario.leaders[team].member_ids) |member| if (self.recruited[member]) {
                available += 1;
            };
            if (self.ninja_scouts_used >= available) self.team_alive[team] = false;
        }
        const old_bits = self.bits;
        self.bits = @min(999999, self.bits + resolution.bits_awarded);
        self.bits_earned += self.bits - old_bits;
        if (resolution.charge_boost != 0) self.charge_boost = resolution.charge_boost;
        for (0..2) |side_index| {
            const loss = @min(self.troops[side_index], if (side_index == 0) resolution.player_loss else resolution.enemy_loss);
            self.troops[side_index] -= loss;
            self.sides[side_index].remaining = boundedRecordsAfterLoss(self.sides[side_index].remaining, @intCast(loss), self.scenario.troops_per_record);
        }
        self.updates += 1;
        self.event_count = 0;
        self.emit(.{ .kind = .effect, .side = 3, .index = team, .amount = @backingInt(resolution.kind) });
        if (resolution.bits_awarded != 0) self.emit(.{ .kind = .message, .side = 0, .index = team, .amount = @intCast(resolution.bits_awarded) });
        if (self.sides[0].remaining == 0 or self.sides[1].remaining == 0) {
            const outcome: Outcome = if (self.sides[0].remaining == 0) .side1_victory else .side0_victory;
            self.scouted_attack = null;
            self.phase = .result;
            self.result = makeResult(self, outcome);
            self.emit(.{ .kind = .outcome, .side = 0, .index = 0, .amount = @backingInt(outcome) });
        }
    }

    pub fn issueTeam(self: *Engine, category: u8, team: u8) !void {
        if (self.script != null or self.phase != .player_command) return error.InvalidWarCommand;
        if (category == 3) return self.issueSpecial(team);
        if (category > 3 or team >= 36 or !self.team_alive[team]) return error.InvalidWarCommand;
        if (!try teamAvailable(self.scenario, team, category, &self.recruited)) return error.InvalidWarCommand;
        const enemy_attack = self.scouted_attack orelse try nextEnemyAttack(self.scenario, &self.enemy, &self.rng);
        const resolution = try resolveOrdinary(self.scenario, .{ .category = category, .team = team, .enemy_attack = enemy_attack }, self.troops[0], self.troops[1], &self.recruited, self.charge_boost, &self.rng);
        self.scouted_attack = null;
        for (0..2) |side_index| {
            const remaining_troops: u32 = if (resolution.remaining_troops[side_index] <= 0) 0 else @min(self.troops[side_index], @as(u32, @intCast(resolution.remaining_troops[side_index])));
            const troop_loss: u32 = @min(self.troops[side_index], @as(u32, @intCast(@max(0, resolution.losses[side_index]))));
            self.troops[side_index] = remaining_troops;
            self.sides[side_index].remaining = boundedRecordsAfterLoss(self.sides[side_index].remaining, @intCast(troop_loss), self.scenario.troops_per_record);
        }
        self.updates += 1;
        self.event_count = 0;
        self.emit(.{ .kind = .command, .side = category, .index = team, .amount = resolution.action_code });
        self.emit(.{ .kind = .casualty, .side = 0, .index = team, .amount = resolution.losses[0] });
        self.emit(.{ .kind = .casualty, .side = 1, .index = enemy_attack, .amount = resolution.losses[1] });
        if (self.sides[0].remaining == 0 or self.sides[1].remaining == 0) {
            const outcome: Outcome = if (self.sides[0].remaining == 0) .side1_victory else .side0_victory;
            self.phase = .result;
            self.result = makeResult(self, outcome);
            self.emit(.{ .kind = .outcome, .side = 0, .index = 0, .amount = @backingInt(outcome) });
        }
    }

    pub fn issue(self: *Engine, side: u8, index: u8, command: Command, target_side: u8, target_index: u8) !void {
        _ = target_side;
        _ = target_index;
        switch (command) {
            .charge, .bow, .magic => {
                if (side != 0) return error.InvalidWarCommand;
                return self.issueTeam(@backingInt(command) - 1, index);
            },
            else => {},
        }
        try self.validateUnit(side, index);
        const unit = &self.sides[side].units[index];
        switch (command) {
            .move => {
                if (unit.state != .retiring and unit.state != .retreat) return error.InvalidWarCommand;
                self.transition(side, index, .move);
            },
            .charge, .bow, .magic => unreachable,
            .retreat => {
                if (unit.state != .retiring and unit.state != .retreat) return error.InvalidWarCommand;
                unit.target_x = unit.x;
                unit.target_y = unit.y;
                unit.velocity_x = unit.x;
                unit.velocity_y = -128;
                unit.counter = 0;
                self.transition(side, index, .retreat);
            },
            .special => return error.UnsupportedWarSpecial,
        }
        self.emit(.{ .kind = .command, .side = side, .index = index, .command = command, .x = unit.target_x, .y = unit.target_y });
    }

    fn moveEffect(self: *Engine, side: u8, index: u8, amount: i32, direction: i32) void {
        const unit = &self.sides[side].units[index];
        if (unit.state != .retiring and unit.state != .retreat) return;
        const first = self.rng.next();
        if (first % 324 < 20) {
            const second = self.rng.next();
            unit.velocity_x = second % 799 + amount - 20;
            unit.velocity_y = self.rng.next() % 537 + 50;
            self.transition(side, index, .effect);
            _ = self.rng.next();
        } else {
            const span = @as(i32, @intCast((self.rng.next() % 32767) / 32767)) + direction - amount + 1;
            const denominator = if (span == 0) 1 else span;
            unit.velocity_x = @divTrunc(@rem(@as(i32, self.rng.next()), 32767), denominator) + amount;
            unit.velocity_y = self.rng.next() % 537 + 50;
            self.transition(side, index, .melee);
            _ = self.rng.next();
        }
    }

    fn updateMelee(self: *Engine, side: u8, index: u8) void {
        if (self.sides[side].remaining == 0) return;
        const unit = &self.sides[side].units[index];
        const delay = @min(@as(u32, self.sides[side].remaining) / 5, 2);
        unit.counter -%= 1;
        if (unit.counter > 0) return;
        if (self.sides[side].remaining > 0 and self.rng.next() % (delay + 1) != 0) return;
        if (self.sides[side].remaining == 1 or (side == 0 and index == 0)) {
            if (self.rng.next() % 2 == 1) {
                unit.target_x = unit.x;
                unit.target_y = unit.y;
                unit.velocity_x = unit.x;
                unit.velocity_y = -128;
                unit.counter = 0;
                self.transition(side, index, .retreat);
            }
        }
        const roll = self.rng.next() % 8192;
        const message: i32 = if (roll == 1) 0x59B else if (roll < 2) 0x59A else 0x59C;
        self.emit(.{ .kind = .message, .side = side, .index = index, .amount = message, .x = unit.x, .y = unit.y });
        if (side == 0 and index == 0) {
            self.moveEffect(0, index, @intCast(self.scenario.initial.scenario_parameter), 150);
        } else {
            self.moveEffect(side, index, -@as(i32, @intCast(self.scenario.initial.scenario_parameter)), -150);
        }
    }

    pub fn confirmScript(self: *Engine) !void {
        if (self.phase != .scripted or self.script == null) return error.InvalidWarCommand;
        const script = &self.script.?;
        if (script.phase != self.scenario.lifecycle.wait_phase or script.confirmations >= self.scenario.lifecycle.confirmation_count) return error.InvalidWarCommand;
        script.previous_phase = script.phase;
        script.phase = 10;
        script.clock = 0;
        script.confirmations += 1;
        self.event_count = 0;
        self.emit(.{ .kind = .script, .side = 0, .index = script.confirmations, .amount = 10 });
    }

    fn tickScript(self: *Engine) !void {
        if (self.phase == .result) return error.WarResultAlreadyResolved;
        if (self.script == null) return error.InvalidWarLifecycle;
        self.event_count = 0;
        self.updates += 1;
        const script = &self.script.?;
        script.clock +|= 1;
        if (script.phase == self.scenario.lifecycle.wait_phase) return;
        var following: ?u8 = null;
        var terminal = false;
        if (script.phase == self.scenario.lifecycle.dispatch_phase) {
            following = if (script.previous_phase == 8) self.scenario.lifecycle.wait_phase else if (script.previous_phase == 10) 11 else return error.InvalidWarLifecycle;
        } else for (self.scenario.lifecycle.transitions) |step| {
            if (step.phase == script.phase) {
                if (script.clock < step.ticks) return;
                following = if (step.phase == 7 and script.confirmations >= self.scenario.lifecycle.confirmation_count) self.scenario.lifecycle.second_confirmation_phase else step.next;
                terminal = step.terminal;
                break;
            }
        }
        const next = following orelse return error.InvalidWarLifecycle;
        const previous = script.phase;
        script.previous_phase = previous;
        script.phase = next;
        script.clock = 0;
        self.emit(.{ .kind = .script, .side = 0, .index = script.confirmations, .amount = next });
        if (terminal) {
            if (isScripted(self.scenario)) {
                self.phase = .result;
                self.result = makeResult(self, .scripted_completion);
                self.emit(.{ .kind = .outcome, .side = 0, .index = 0, .amount = @backingInt(Outcome.scripted_completion) });
            } else {
                self.script = null;
                self.phase = .player_command;
                self.emit(.{ .kind = .script, .side = 0, .index = script.confirmations, .amount = self.scenario.lifecycle.completion_main_phase });
            }
        }
    }

    pub fn tick(self: *Engine) !void {
        if (self.script != null) return self.tickScript();
        if (self.phase == .result) return error.WarResultAlreadyResolved;
        const combat_rng = self.rng;
        defer self.rng = combat_rng;
        self.phase = .resolving;
        self.event_count = 0;
        for (0..2) |side_index| {
            const side: u8 = @intCast(side_index);
            var index: u8 = 0;
            while (index < self.sides[side].total) : (index += 1) {
                const unit = &self.sides[side].units[index];
                switch (unit.state) {
                    .idle => unit.target_x = 0,
                    .reset => {
                        unit.x +%= unit.target_x;
                        unit.y +%= unit.target_y;
                        unit.counter -%= 1;
                        if (unit.counter <= 0) {
                            unit.counter = 0;
                            self.transition(side, index, .idle);
                        }
                    },
                    .move => {
                        unit.x +%= unit.target_x;
                        unit.y +%= unit.target_y;
                        if (self.rng.next() % 16 == 1) {
                            unit.counter = 61;
                            self.transition(side, index, .impact);
                        } else {
                            unit.counter -%= 1;
                            if (unit.counter <= 0) {
                                if (side == 0) self.moveEffect(0, index, @intCast(self.scenario.initial.scenario_parameter), 150) else self.moveEffect(side, index, -@as(i32, @intCast(self.scenario.initial.scenario_parameter)), -150);
                            }
                        }
                    },
                    .melee => self.updateMelee(side, index),
                    .ranged => {
                        unit.x +%= unit.target_x;
                        unit.y +%= unit.target_y;
                        unit.counter -%= 1;
                        if (unit.counter <= 0) {
                            self.emit(.{ .kind = .effect, .side = side, .index = index, .x = unit.x, .y = unit.y });
                            const delay = self.rng.next() % 1057 + 60;
                            unit.counter = @intCast(delay);
                            self.transition(side, index, .effect);
                            unit.target_x = 0;
                            unit.target_y = 0;
                        }
                    },
                    .effect => {
                        unit.counter -%= 1;
                        if (unit.counter <= 0) {
                            if (side == 0) self.moveEffect(0, index, @intCast(self.scenario.initial.scenario_parameter), 150) else self.moveEffect(side, index, -@as(i32, @intCast(self.scenario.initial.scenario_parameter)), -150);
                        }
                    },
                    .impact => {
                        const counter: i32 = unit.counter;
                        unit.velocity_x = unit.x -% @divTrunc((unit.target_x -% unit.x) *% counter, 300);
                        unit.velocity_y = unit.y -% @divTrunc((unit.target_y -% unit.y) *% counter, 300);
                        unit.x +%= @divTrunc(300 - counter, 10) *% counter;
                        unit.counter +%= 1;
                        if (unit.counter >= 301) self.transition(side, index, .retiring);
                    },
                    .retiring => {
                        if (unit.counter == 0 and self.rng.next() % 324 == 1) {
                            unit.counter = 87;
                            self.transition(side, index, .special_move);
                        } else {
                            unit.counter -%= 1;
                            if (unit.counter == 28) {
                                if (self.sides[1 - side].remaining != 0 and self.rng.next() % 16384 == 1) {
                                    const other = 1 - side;
                                    var target: u8 = @intCast(self.rng.next() % self.sides[other].remaining);
                                    while (self.sides[other].units[target].state == .retreat) {
                                        target = @intCast(self.rng.next() % self.sides[other].remaining);
                                    }
                                    if (self.sides[other].units[target].state == .retiring) {
                                        target = @intCast(self.rng.next() % self.sides[other].remaining);
                                    }
                                    self.emit(.{ .kind = .effect, .side = other, .index = target, .x = self.sides[other].units[target].x + 6, .y = self.sides[other].units[target].y + 16 });
                                } else if (self.sides[1 - side].remaining == 0) {
                                    self.emit(.{ .kind = .message, .side = side, .index = index, .amount = 0x5A0 });
                                }
                            }
                            if (unit.counter == 0) self.transition(side, index, .move);
                        }
                    },
                    .retreat => {
                        unit.x +%= @divTrunc((unit.target_x -% unit.x) *% unit.counter, 150);
                        unit.y +%= @divTrunc((unit.target_y -% unit.y) *% unit.counter, 150);
                        unit.counter +%= 1;
                        if (unit.counter >= 151) {
                            self.transition(side, index, .special_move);
                            unit.counter = 0;
                        }
                    },
                    .special_wait => {
                        unit.target_x = 0;
                        unit.target_y = 0;
                        unit.counter +%= 1;
                        if (unit.counter >= 91) self.transition(side, index, .finished);
                    },
                    .special_move => unit.target_x = 0,
                    .inert, .finished => {},
                }
            }
        }
        self.updates += 1;
        if (self.sides[0].remaining != 0 and self.sides[1].remaining != 0) {
            self.phase = .player_command;
        } else {
            const outcome: Outcome = if (self.sides[0].remaining == 0) .side1_victory else .side0_victory;
            self.phase = .result;
            self.result = makeResult(self, outcome);
            self.emit(.{ .kind = .outcome, .side = 0, .index = 0, .amount = @backingInt(outcome) });
        }
    }
};
