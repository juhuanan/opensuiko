const std = @import("std");
const war = @import("war");

pub const snapshot_schema = "suikoden-war-session/6";
pub const max_snapshot_bytes = 1024 * 1024;

pub const Entry = struct {
    scenario: war.Scenario,
    rng: war.Random,
    attempt_id: ?u64 = null,
    initial: ?war.Initial = null,
    recruited: ?[]const bool = null,
    bits: ?u32 = null,
    snapshot: ?[]const u8 = null,
};

pub const Snapshot = struct {
    schema: []const u8,
    scenario_selector: u8,
    source_sha256: []const u8,
    scenario_sha256: []const u8,
    phase: war.Phase,
    sides: [2]war.SideState,
    rng: war.Random,
    attempt_id: u64,
    initial_rng: war.Random,
    troops: [2]u32,
    enemy: war.EnemyState,
    scouted_attack: ?u8 = null,
    ninja_scouts_used: u8 = 0,
    recruited: [108]bool,
    team_alive: [36]bool,
    charge_boost: u8,
    bits: u32,
    bits_earned: u32,
    script: ?war.ScriptState,
    selected_side: u8,
    selected_index: u8,
    target_index: u8,
    command_index: u8,
    updates: u64,
    result: ?war.Result,
    consumed_receipt: ?u64,
};

pub const Input = struct {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    confirm: bool = false,
    cancel: bool = false,
    target: bool = false,
    restart: bool = false,
};
pub const Action = enum { up, down, left, right, confirm, cancel, target, restart };
pub const Repeat = struct {
    previous: Input = .{},
    clock: u8 = 0,

    pub fn advance(self: *Repeat, input: Input) ?Action {
        defer self.previous = input;
        const changed = !std.meta.eql(input, self.previous);
        if (changed) self.clock = 0 else self.clock +|= 1;
        const fire = struct {
            fn check(value: bool, clock: u8, changed_input: bool) bool {
                return value and (changed_input or (clock >= 12 and clock % 3 == 0));
            }
        };
        if (fire.check(input.restart, self.clock, changed)) return .restart;
        if (fire.check(input.confirm, self.clock, changed)) return .confirm;
        if (fire.check(input.cancel, self.clock, changed)) return .cancel;
        if (fire.check(input.target, self.clock, changed)) return .target;
        if (fire.check(input.up, self.clock, changed)) return .up;
        if (fire.check(input.down, self.clock, changed)) return .down;
        if (fire.check(input.left, self.clock, changed)) return .left;
        if (fire.check(input.right, self.clock, changed)) return .right;
        return null;
    }
};

pub const Session = struct {
    engine: war.Engine,
    initial_rng: war.Random,
    consumed_receipt: ?u64 = null,
    target_index: u8 = 0,
    command_index: u8 = 0,
    repeat: Repeat = .{},

    pub fn init(allocator: std.mem.Allocator, entry: Entry) !Session {
        if (entry.snapshot) |bytes| {
            if (entry.initial != null) return error.MismatchedWarEntry;
            var session: Session = .{ .engine = try restore(allocator, entry.scenario, bytes), .initial_rng = entry.rng };
            errdefer session.deinit();
            const parsed = try std.json.parseFromSlice(Snapshot, allocator, bytes, .{ .allocate = .alloc_always });
            defer parsed.deinit();
            session.initial_rng = parsed.value.initial_rng;
            if (entry.attempt_id) |attempt_id| {
                if (attempt_id != session.engine.attempt_id) return error.MismatchedWarEntry;
            }
            if (entry.recruited) |roster| {
                if (roster.len != 108 or !std.mem.eql(bool, roster, &session.engine.recruited)) return error.MismatchedWarEntry;
            }
            if (entry.bits) |bits| {
                if (bits != session.engine.bits) return error.MismatchedWarEntry;
            }
            session.target_index = parsed.value.target_index;
            session.command_index = parsed.value.command_index;
            session.consumed_receipt = parsed.value.consumed_receipt;
            return session;
        }
        var scenario = entry.scenario;
        if (entry.initial) |initial| scenario.initial = initial;
        var engine = try war.Engine.init(allocator, scenario, entry.rng);
        engine.attempt_id = entry.attempt_id orelse 1;
        errdefer engine.deinit();
        if (entry.recruited) |roster| {
            if (roster.len != 108 or try war.initialTroops(scenario, roster) != scenario.initial.initial_army_troops) return error.MismatchedWarEntry;
            @memcpy(&engine.recruited, roster);
        }
        if (entry.bits) |bits| {
            if (bits > 999999) return error.InvalidWarEntry;
            engine.bits = bits;
        }
        return .{ .engine = engine, .initial_rng = entry.rng };
    }

    pub fn deinit(self: *Session) void {
        self.engine.deinit();
        self.* = undefined;
    }

    fn stepTeam(self: *Session, direction: i8) !void {
        var candidate = self.engine.selected_index;
        for (0..36) |_| {
            candidate = @intCast(@mod(@as(i16, candidate) + 36 + direction, 36));
            if (self.engine.team_alive[candidate] and try war.teamAvailable(self.engine.scenario, candidate, self.command_index, &self.engine.recruited)) {
                self.engine.selected_index = candidate;
                return;
            }
        }
    }

    pub fn update(self: *Session, input: Input) !void {
        const action = self.repeat.advance(input) orelse {
            if (self.engine.phase != .result) try self.engine.tick();
            return;
        };
        if (action == .restart) {
            const allocator = self.engine.allocator;
            const scenario = self.engine.scenario;
            const attempt_id = std.math.add(u64, self.engine.attempt_id, 1) catch return error.WarAttemptExhausted;
            self.engine.deinit();
            self.engine = try war.Engine.init(allocator, scenario, self.initial_rng);
            self.engine.attempt_id = attempt_id;
            self.consumed_receipt = null;
            self.target_index = 0;
            self.command_index = 0;
            self.repeat = .{};
            return;
        }
        if (self.engine.phase == .result) return;
        if (self.engine.phase == .scripted) {
            if (action == .confirm) {
                if (self.engine.script.?.phase == self.engine.scenario.lifecycle.wait_phase) {
                    try self.engine.confirmScript();
                } else {
                    return;
                }
            } else {
                try self.engine.tick();
            }
            return;
        }
        switch (action) {
            .up => self.command_index = (self.command_index + 3) % 4,
            .down => self.command_index = (self.command_index + 1) % 4,
            .left => try self.stepTeam(-1),
            .right => try self.stepTeam(1),
            .target => {},
            .cancel => self.command_index = 0,
            .confirm => self.engine.issueTeam(self.command_index, self.engine.selected_index) catch |err| switch (err) {
                error.InvalidWarCommand => return,
                else => return err,
            },
            .restart => unreachable,
        }
        if (self.engine.phase != .result) try self.engine.tick();
    }

    pub fn snapshot(self: *const Session, allocator: std.mem.Allocator) ![]u8 {
        if (self.engine.phase == .resolving) return error.WarSnapshotRequiresCheckpoint;
        const value: Snapshot = .{
            .schema = snapshot_schema,
            .scenario_selector = self.engine.scenario.selector,
            .source_sha256 = self.engine.scenario.source.sha256,
            .scenario_sha256 = self.engine.scenario.content_sha256,
            .phase = self.engine.phase,
            .sides = self.engine.sides,
            .rng = self.engine.rng,
            .attempt_id = self.engine.attempt_id,
            .initial_rng = self.initial_rng,
            .troops = self.engine.troops,
            .enemy = self.engine.enemy,
            .scouted_attack = self.engine.scouted_attack,
            .ninja_scouts_used = self.engine.ninja_scouts_used,
            .recruited = self.engine.recruited,
            .team_alive = self.engine.team_alive,
            .charge_boost = self.engine.charge_boost,
            .bits = self.engine.bits,
            .bits_earned = self.engine.bits_earned,
            .script = self.engine.script,
            .selected_side = self.engine.selected_side,
            .selected_index = self.engine.selected_index,
            .target_index = self.target_index,
            .command_index = self.command_index,
            .updates = self.engine.updates,
            .result = self.engine.result,
            .consumed_receipt = self.consumed_receipt,
        };
        return std.json.Stringify.valueAlloc(allocator, value, .{});
    }

    pub fn consumeResult(self: *Session, receipt: u64) !war.Result {
        const result = self.engine.result orelse return error.WarResultNotReady;
        if (self.consumed_receipt != null) return error.WarResultAlreadyConsumed;
        if (result.receipt != receipt) return error.WarResultReceiptMismatch;
        self.consumed_receipt = receipt;
        return result;
    }
};

pub const Receipt = struct {
    scenario_sha256: [64]u8,
    attempt_id: u64,
    receipt: u64,
};

pub const Host = struct {
    bits: u32 = 0,
    casualties: [2]u32 = .{ 0, 0 },
    outcome: ?war.Outcome = null,
    scenario_sha256: ?[64]u8 = null,
    consumed_receipt: ?u64 = null,
    receipts: [16]Receipt = undefined,
    receipt_count: usize = 0,
};

pub fn applyResult(host: *Host, session: *Session, receipt: u64) !void {
    for (host.receipts[0..host.receipt_count]) |existing| {
        if (existing.receipt == receipt and existing.attempt_id == session.engine.attempt_id and
            std.mem.eql(u8, &existing.scenario_sha256, session.engine.scenario.content_sha256)) return error.WarResultAlreadyConsumed;
    }
    if (host.receipt_count == host.receipts.len) return error.WarReceiptCapacityExhausted;
    const result = session.engine.result orelse return error.WarResultNotReady;
    if (result.receipt != receipt) return error.WarResultReceiptMismatch;
    if (session.engine.scenario.content_sha256.len != 64) return error.InvalidWarConsequence;
    var next = host.*;
    next.outcome = result.outcome;
    next.scenario_sha256 = session.engine.scenario.content_sha256[0..64].*;
    for (result.consequences[0..result.consequence_count]) |request| {
        if (request.amount < 0 or !std.mem.eql(u8, request.scenario_id, session.engine.scenario.id)) return error.InvalidWarConsequence;
        switch (request.kind) {
            .scenario_victory, .scenario_defeat, .scenario_completed, .scenario_parameter => {},
            .casualties => {
                const side = request.side orelse return error.InvalidWarConsequence;
                if (side > 1) return error.InvalidWarConsequence;
                next.casualties[side] = std.math.add(u32, next.casualties[side], @intCast(request.amount)) catch return error.InvalidWarConsequence;
            },
            .bits => next.bits = @min(999999, next.bits + @as(u32, @intCast(request.amount))),
        }
    }
    _ = try session.consumeResult(receipt);
    next.consumed_receipt = receipt;
    next.receipts[next.receipt_count] = .{
        .scenario_sha256 = session.engine.scenario.content_sha256[0..64].*,
        .attempt_id = session.engine.attempt_id,
        .receipt = receipt,
    };
    next.receipt_count += 1;
    host.* = next;
}

fn validateSnapshot(scenario: war.Scenario, snapshot: Snapshot) !void {
    if (!std.mem.eql(u8, snapshot.schema, snapshot_schema) or snapshot.scenario_selector != scenario.selector or
        !std.mem.eql(u8, snapshot.source_sha256, scenario.source.sha256) or
        !std.mem.eql(u8, snapshot.scenario_sha256, scenario.content_sha256)) return error.StaleWarSnapshot;
    for (snapshot.sides, scenario.initial.sides) |side, initial| {
        if (side.total != initial.total_records or side.remaining > side.total or side.units.len != side.total) return error.InvalidWarSnapshot;
        for (side.units) |unit| if (unit.state_code != @backingInt(unit.state)) return error.InvalidWarSnapshot;
        if (side.total - side.remaining > side.total) return error.InvalidWarSnapshot;
    }
    const scripted = war.isScripted(scenario);
    const scripted_phase = snapshot.phase == .scripted;
    if (scripted_phase and snapshot.script == null) return error.InvalidWarSnapshot;
    if (snapshot.enemy.group >= 5 or snapshot.troops[0] > scenario.initial.initial_army_troops or
        snapshot.troops[1] > scenario.initial.scenario_parameter) return error.InvalidWarSnapshot;
    if (snapshot.ninja_scouts_used > 3) return error.InvalidWarSnapshot;
    if (snapshot.scouted_attack) |attack| {
        if (snapshot.phase != .player_command or attack >= scenario.attacks.len or snapshot.ninja_scouts_used == 0) return error.InvalidWarSnapshot;
    }
    if (snapshot.script) |script| {
        if (script.phase >= 17 or script.previous_phase >= 17 or script.confirmations > scenario.lifecycle.confirmation_count or script.clock > 248) return error.InvalidWarSnapshot;
    }
    if (snapshot.selected_side > 1) return error.InvalidWarSnapshot;
    const selected_total = snapshot.sides[snapshot.selected_side].total;
    const target_total = snapshot.sides[1 - snapshot.selected_side].total;
    if ((selected_total == 0 and snapshot.selected_index != 0) or (selected_total != 0 and snapshot.selected_index >= selected_total) or
        (target_total == 0 and snapshot.target_index != 0) or (target_total != 0 and snapshot.target_index >= target_total) or
        (!scripted and (snapshot.selected_index >= 36 or snapshot.command_index >= 4)) or (scripted and snapshot.command_index >= 4)) return error.InvalidWarSnapshot;
    if (snapshot.consumed_receipt) |receipt| {
        const result = snapshot.result orelse return error.InvalidWarSnapshot;
        if (result.receipt != receipt) return error.InvalidWarSnapshot;
    }
    switch (snapshot.phase) {
        .player_command => if (snapshot.result != null or snapshot.script != null) return error.InvalidWarSnapshot,
        .scripted => if (snapshot.result != null or snapshot.script == null) return error.InvalidWarSnapshot,
        .resolving => return error.WarSnapshotRequiresCheckpoint,
        .result => {
            const result = snapshot.result orelse return error.InvalidWarSnapshot;
            const expected_casualties = if (result.outcome == .scripted_completion) [2]u32{ 0, 0 } else [2]u32{
                war.troopsLost(scenario.initial.sides[0].total_records, snapshot.sides[0].remaining, scenario.initial.initial_army_troops),
                war.troopsLost(scenario.initial.sides[1].total_records, snapshot.sides[1].remaining, scenario.initial.scenario_parameter),
            };
            const expected_outcome: war.ConsequenceKind = if (result.outcome == .scripted_completion) .scenario_completed else if (result.outcome == .forced_defeat or result.outcome == .side1_victory) .scenario_defeat else .scenario_victory;
            if (result.receipt != snapshot.updates or result.attempt_id != snapshot.attempt_id or (result.outcome == .scripted_completion) != scripted or
                result.casualties[0] != expected_casualties[0] or
                result.casualties[1] != expected_casualties[1] or
                result.consequence_count != 5 or snapshot.bits > 999999 or snapshot.bits_earned > 999999 or
                (result.outcome == .side0_victory and snapshot.sides[1].remaining != 0) or
                (result.outcome == .side1_victory and snapshot.sides[0].remaining != 0)) return error.InvalidWarSnapshot;
            for (result.consequences, 0..) |request, index| {
                const expected_kind: war.ConsequenceKind = switch (index) {
                    0 => expected_outcome,
                    1, 2 => .casualties,
                    3 => .scenario_parameter,
                    4 => .bits,
                    else => unreachable,
                };
                const expected_side: ?u8 = if (index == 1 or index == 2) @intCast(index - 1) else null;
                const expected_amount: i32 = switch (index) {
                    0 => @backingInt(result.outcome),
                    1, 2 => @intCast(expected_casualties[index - 1]),
                    3 => @intCast(scenario.initial.scenario_parameter),
                    4 => @intCast(snapshot.bits_earned),
                    else => unreachable,
                };
                if (!std.mem.eql(u8, request.scenario_id, scenario.id) or request.kind != expected_kind or
                    request.side != expected_side or request.amount != expected_amount) return error.InvalidWarSnapshot;
            }
        },
    }
}

pub fn restore(allocator: std.mem.Allocator, scenario: war.Scenario, bytes: []const u8) !war.Engine {
    if (bytes.len > max_snapshot_bytes) return error.WarSnapshotTooLarge;
    const parsed = try std.json.parseFromSlice(Snapshot, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try validateSnapshot(scenario, parsed.value);
    var engine = try war.Engine.init(allocator, scenario, parsed.value.rng);
    errdefer engine.deinit();
    for (&engine.sides, parsed.value.sides) |*destination, source| {
        destination.remaining = source.remaining;
        @memcpy(destination.units, source.units);
    }
    engine.troops = parsed.value.troops;
    engine.enemy = parsed.value.enemy;
    engine.scouted_attack = parsed.value.scouted_attack;
    engine.ninja_scouts_used = parsed.value.ninja_scouts_used;
    engine.recruited = parsed.value.recruited;
    engine.team_alive = parsed.value.team_alive;
    engine.charge_boost = parsed.value.charge_boost;
    engine.bits = parsed.value.bits;
    engine.bits_earned = parsed.value.bits_earned;
    engine.attempt_id = parsed.value.attempt_id;
    engine.phase = parsed.value.phase;
    engine.script = parsed.value.script;
    engine.selected_side = parsed.value.selected_side;
    engine.selected_index = parsed.value.selected_index;
    engine.updates = parsed.value.updates;
    engine.result = parsed.value.result;
    if (engine.result) |*result| for (&result.consequences) |*request| {
        request.scenario_id = scenario.id;
    };
    return engine;
}
