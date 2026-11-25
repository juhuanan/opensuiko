const std = @import("std");

pub const content_json = @import("duel_data").json;
pub const schema = "suikoden.duel-rules.v1";

pub const Command = enum(u8) {
    attack,
    defend,
    desperate_attack,
};

pub const Side = enum(u8) {
    player,
    opponent,
};

pub const HitKind = enum {
    normal,
    defended,
    desperate_success,
    desperate_failure,
};

pub const Hit = struct {
    tick: u32,
    target: Side,
    kind: HitKind,
};

pub const Exchange = struct {
    id: []const u8,
    player: Command,
    opponent: Command,
    updates: u32,
    hits: []const Hit,
};

pub const Fighter = struct {
    id: []const u8,
    name: []const u8,
    defeat_updates: u32,
};

pub const Duel = struct {
    id: []const u8,
    fighters: [2]Fighter,
    initial_opponent: ?FighterState = null,
    cues: [3][3][]const u8,
    round_pause_updates: u32,
    defeat_prelude_updates: u32,
    exchanges: []const Exchange,
};

pub const Content = struct {
    schema: []const u8,
    target: []const u8,
    tick_unit: []const u8,
    commands: [3][]const u8,
    duels: []const Duel,
    entry_state: []const u8,

    pub fn validate(self: Content) !void {
        if (!std.mem.eql(u8, self.schema, schema) or self.duels.len != 3) return error.InvalidDuelContent;
        for (self.commands, 0..) |name, index| {
            if (!std.mem.eql(u8, name, @tagName(@as(Command, @fromBackingInt(@intCast(index)))))) return error.InvalidDuelContent;
        }
        for (self.duels, 0..) |duel, duel_index| {
            if (duel.id.len == 0 or duel.round_pause_updates != 20 or duel.defeat_prelude_updates != 120 or duel.exchanges.len != 9) return error.InvalidDuelContent;
            for (self.duels[0..duel_index]) |previous| {
                if (std.mem.eql(u8, duel.id, previous.id)) return error.InvalidDuelContent;
            }
            for (duel.fighters) |fighter| {
                if (fighter.id.len == 0 or fighter.defeat_updates == 0) return error.InvalidDuelContent;
            }
            if (duel.initial_opponent) |opponent| try opponent.validate();
            for (duel.exchanges, 0..) |exchange, exchange_index| {
                if (@backingInt(exchange.player) > 2 or @backingInt(exchange.opponent) > 2 or exchange.updates == 0) return error.InvalidDuelContent;
                for (duel.exchanges[0..exchange_index]) |previous| {
                    if (previous.player == exchange.player and previous.opponent == exchange.opponent) return error.InvalidDuelContent;
                }
                for (exchange.hits, 0..) |hit, hit_index| {
                    if (hit.tick >= exchange.updates) return error.InvalidDuelContent;
                    if (hit_index > 0) {
                        const previous = exchange.hits[hit_index - 1];
                        if (previous.tick > hit.tick or (previous.tick == hit.tick and previous.target != .player)) return error.InvalidDuelContent;
                    }
                }
            }
            for (0..3) |player| for (0..3) |opponent| {
                _ = findExchange(&duel, @fromBackingInt(@intCast(player)), @fromBackingInt(@intCast(opponent))) orelse return error.InvalidDuelContent;
            };
        }
    }
};

pub fn load(allocator: std.mem.Allocator, source: []const u8) !std.json.Parsed(Content) {
    const parsed = try std.json.parseFromSlice(Content, allocator, source, .{ .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

pub fn findDuel(content: *const Content, id: []const u8) ?*const Duel {
    for (content.duels) |*duel| {
        if (std.mem.eql(u8, duel.id, id)) return duel;
    }
    return null;
}

pub fn findExchange(duel: *const Duel, player: Command, opponent: Command) ?*const Exchange {
    for (duel.exchanges) |*exchange| {
        if (exchange.player == player and exchange.opponent == opponent) return exchange;
    }
    return null;
}

pub const Random = struct {
    values: []const u15 = &.{},
    cursor: usize = 0,
    bios_state: ?u32 = null,

    pub fn valid(self: Random) bool {
        return if (self.bios_state != null) self.values.len == 0 else self.cursor <= self.values.len;
    }

    pub fn ensure(self: Random, count: usize) !void {
        if (!self.valid()) return error.InvalidRandomSource;
        if (self.bios_state == null and count > self.values.len - self.cursor) return error.RandomInputExhausted;
    }

    pub fn next(self: *Random) !u15 {
        try self.ensure(1);
        if (self.bios_state) |state| {
            const next_state = state *% 0x41c64e6d +% 0x3039;
            self.bios_state = next_state;
            self.cursor += 1;
            return @intCast((next_state >> 16) & 0x7fff);
        }
        defer self.cursor += 1;
        return self.values[self.cursor];
    }
};

pub fn opponentChoice(roll: u15) Command {
    return @fromBackingInt(@intCast((3 * @as(u32, roll) / 32767) % 3));
}

pub fn resolveDamage(target_hp: i32, attacker_attack: u16, target_defense: u16, kind: HitKind, roll: u15) i32 {
    const base = @max(@as(i32, attacker_attack) - @as(i32, target_defense), 1);
    var amount = base + @as(i32, @intCast(@rem(@divTrunc(base, 100) * @as(i32, roll), 10)));
    switch (kind) {
        .normal => {},
        .defended => amount = @divTrunc(amount, 2),
        .desperate_success => {
            amount *= 2;
            amount = @min(amount, @divTrunc(target_hp, 4));
        },
        .desperate_failure => amount = @min(amount, @divTrunc(target_hp, 4)),
    }
    return amount;
}

pub const FighterState = struct {
    maximum_hp: i32,
    hp: i32,
    attack: u16,
    defense: u16,

    pub fn validate(self: FighterState) !void {
        if (self.maximum_hp <= 0 or self.hp <= 0 or self.hp > self.maximum_hp) return error.InvalidFighterState;
    }
};

pub const Phase = enum {
    choosing,
    exchange,
    round_pause,
    defeat_prelude,
    defeat_animation,
    finished,
};

pub const Outcome = enum {
    victory,
    defeat,
};

pub const DamageEvent = struct {
    tick: u32,
    target: Side,
    kind: HitKind,
    damage: i32,
    hp_after: i32,
};

pub const State = struct {
    duel: *const Duel,
    fighters: [2]FighterState,
    random: Random,
    phase: Phase = .choosing,
    outcome: ?Outcome = null,
    loser: ?Side = null,
    round: u32 = 1,
    selected: Command = .attack,
    opponent: Command,
    previous_opponent: Command = .attack,
    current_exchange: ?*const Exchange = null,
    exchange_tick: u32 = 0,
    timer: u32 = 0,
    last_hit: ?DamageEvent = null,
    hit_count: u32 = 0,

    pub fn init(content: *const Content, duel_id: []const u8, fighters: [2]FighterState, random: Random) !State {
        try random.ensure(1);
        for (fighters) |fighter| try fighter.validate();
        const duel = findDuel(content, duel_id) orelse return error.UnknownDuel;
        var state = State{
            .duel = duel,
            .fighters = fighters,
            .random = random,
            .opponent = .attack,
        };
        state.opponent = opponentChoice(try state.random.next());
        return state;
    }

    pub fn cue(self: *const State) []const u8 {
        return self.duel.cues[@backingInt(self.previous_opponent)][@backingInt(self.opponent)];
    }

    pub fn moveSelection(self: *State, delta: i8) !void {
        if (self.phase != .choosing or delta == 0) return error.InvalidDuelInput;
        const next = @mod(@as(i32, @backingInt(self.selected)) + @as(i32, delta), 3);
        self.selected = @fromBackingInt(@intCast(next));
    }

    pub fn confirm(self: *State) !void {
        return self.choose(self.selected);
    }

    pub fn choose(self: *State, command: Command) !void {
        if (self.phase != .choosing) return error.InvalidDuelPhase;
        self.current_exchange = findExchange(self.duel, command, self.opponent) orelse return error.InvalidDuelContent;
        self.selected = command;
        self.exchange_tick = 0;
        self.last_hit = null;
        self.phase = .exchange;
    }

    pub fn cancel(self: *State) bool {
        _ = self;
        return false;
    }

    pub fn tick(self: *State) !void {
        self.last_hit = null;
        switch (self.phase) {
            .choosing, .finished => {},
            .exchange => try self.tickExchange(),
            .round_pause => {
                if (self.timer == 0) return error.InvalidDuelState;
                self.timer -= 1;
                if (self.timer == 0) try self.finishRound();
            },
            .defeat_prelude => {
                if (self.timer == 0) return error.InvalidDuelState;
                self.timer -= 1;
                if (self.timer == 0) {
                    self.phase = .defeat_animation;
                    self.timer = self.duel.fighters[@backingInt(self.loser.?)].defeat_updates;
                }
            },
            .defeat_animation => {
                if (self.timer == 0) return error.InvalidDuelState;
                self.timer -= 1;
                if (self.timer == 0) self.phase = .finished;
            },
        }
    }

    fn tickExchange(self: *State) !void {
        const exchange = self.current_exchange orelse return error.InvalidDuelState;
        var draws: usize = 0;
        for (exchange.hits) |hit| {
            if (hit.tick == self.exchange_tick) draws += 1;
        }
        try self.random.ensure(draws);
        for (exchange.hits) |hit| {
            if (hit.tick != self.exchange_tick) continue;
            const target = @backingInt(hit.target);
            const attacker = 1 - target;
            const amount = resolveDamage(self.fighters[target].hp, self.fighters[attacker].attack, self.fighters[target].defense, hit.kind, try self.random.next());
            self.fighters[target].hp -= amount;
            if (self.fighters[target].hp > self.fighters[target].maximum_hp) self.fighters[target].hp = self.fighters[target].maximum_hp;
            self.last_hit = .{
                .tick = self.exchange_tick,
                .target = hit.target,
                .kind = hit.kind,
                .damage = amount,
                .hp_after = self.fighters[target].hp,
            };
            self.hit_count += 1;
        }
        self.exchange_tick += 1;
        if (self.exchange_tick == exchange.updates) {
            self.phase = .round_pause;
            self.timer = self.duel.round_pause_updates;
        }
    }

    fn finishRound(self: *State) !void {
        if (self.fighters[0].hp <= 0) {
            self.beginDefeat(.player);
        } else if (self.fighters[1].hp <= 0) {
            self.beginDefeat(.opponent);
        } else {
            try self.random.ensure(1);
            self.previous_opponent = self.opponent;
            self.opponent = opponentChoice(try self.random.next());
            self.current_exchange = null;
            self.exchange_tick = 0;
            self.selected = .attack;
            self.round += 1;
            self.phase = .choosing;
        }
    }

    fn beginDefeat(self: *State, loser: Side) void {
        self.loser = loser;
        self.outcome = if (loser == .player) .defeat else .victory;
        self.phase = .defeat_prelude;
        self.timer = self.duel.defeat_prelude_updates;
    }
};
