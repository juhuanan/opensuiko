//! Shared parsed rule definitions and JSON wire validation for optional games.

const std = @import("std");

pub const host_rejection_budget = 65536;

/// Verify that `receipt_id` is authorized in `receipts` and not yet recorded in `applied`.
pub fn verifyReceipt(receipt_id: u64, receipts: []const u64, applied: []const u64) !void {
    if (std.mem.indexOfScalar(u64, applied, receipt_id) != null) return error.ReceiptAlreadyUsed;
    if (std.mem.indexOfScalar(u64, receipts, receipt_id) == null) return error.MissingReceipt;
}

pub const DiceSpecial = struct { score: u16, roller_wins: bool, multiplier: u32 };
pub const DiceMode = struct { fixed_wager: ?u32, profit_goal: ?u32 };

pub const DiceRules = struct {
    modes: [3]DiceMode,
    minimum_balance: u32,
    balance_cap: u32,
    step: u32,
    increments: [2]u32,
    wager_maximum: u32,
    ordinary_min: u8,
    ordinary_max: u8,
    specials: [5]DiceSpecial,
    failure_limit: u8,
    third_multiplier: u32,
    tie_when_opponent_zero: bool,

    pub fn fixedWager(self: DiceRules) u32 {
        return self.modes[1].fixed_wager.?;
    }
    pub fn profitGoal(self: DiceRules) u32 {
        return self.modes[2].profit_goal.?;
    }
    pub fn special(self: DiceRules, score: u16) ?DiceSpecial {
        for (self.specials) |row| {
            if (row.score == score) return row;
        }
        return null;
    }
};

pub const CoinRules = struct {
    stakes: [3]u32,
    quit_option: u8,
    balance_cap: u32,
    bases: [3]u8,
    ranges: [3]u8,
    shuffle_positions: u8,
    shuffle_steps: u8,
    motion_high: u32,
    cups: u8,
    reveal_ticks: u16,
    win_credit_stakes: u32,
    net_credit_stakes: u32,
    profit_threshold: i32,
    flag_mask: u32,
    flag_value: u32,
    result_bit: u8,
};

pub const KarutaRound = struct { identities: u8, record_moves: u32 };

pub const KarutaRules = struct {
    rows: u8,
    columns: u8,
    cells: u8,
    pairs: u8,
    faces: u8,
    empty_face: u8,
    back_face: u8,
    rounds: [4]KarutaRound,
    quit_round: u8,
    identity_divisor: u32,
    row_divisor: u32,
    column_divisor: u32,
    row_candidates: u8,
    column_candidates: u8,
    flip_frames: u8,
    matched_scale_frames: u8,
    matched_fade_frames: u8,
    resolve_frames: u8,
    deal_ticks: u8,
    moves_cap: u32,
    balance_cap: u32,
    flag_mask: u32,
    flag_value: u32,
    result_bit: u8,
};

pub const ParsedFamilies = struct {
    dice: DiceRules,
    coin: CoinRules,
    karuta: KarutaRules,
};

pub fn parseFamilies(allocator: std.mem.Allocator, bytes: []const u8, expected_schema: []const u8) !ParsedFamilies {
    const parsed = try std.json.parseFromSlice(Wire, allocator, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer parsed.deinit();
    const value = parsed.value;
    if (!std.mem.eql(u8, value.schema, expected_schema)) return error.UnsupportedSchema;
    return .{
        .dice = try diceRules(value.families.dice),
        .coin = try coinRules(value.families.coin),
        .karuta = try karutaRules(value.families.karuta),
    };
}

const ModeWire = struct { id: []const u8, fixed_wager: ?u32 = null, profit_goal: ?u32 = null };
const SpecialWire = struct { score: u32, roller_wins: bool, multiplier: u32 };
const DiceWire = struct {
    modes: [3]ModeWire,
    minimum_balance: u32,
    balance_cap: u32,
    wager: struct { step: u32, increments: [2]u32, maximum: u32 },
    ordinary_scores: struct { minimum: u8, maximum: u8 },
    specials: [5]SpecialWire,
    zero_score: struct {
        failures_before_turn_passes: u8,
        tie_when_opponent_zero: bool,
        third_failure_multiplier: u32,
    },
};
const CoinWire = struct {
    stakes: [3]u32,
    quit_option: u8,
    balance_cap: u32,
    difficulty: [3]struct { base: u8, range: u8 },
    shuffle: struct { positions: u8, steps: u8, motion_high: u32 },
    choice: struct { cups: u8 },
    reveal_ticks: u16,
    settlement: struct { win_credit_stakes: u32, net_credit_stakes: u32 },
    profit: struct { threshold: i32, flag_mask: u32, flag_value: u32, result_bit: u8 },
};
const KarutaWire = struct {
    board: struct { rows: u8, columns: u8, cells: u8, pairs: u8, faces: u8, empty_face: u8, back_face: u8 },
    rounds: [4]struct { index: u8, identities: u8, record_moves: u32 },
    quit_round: u8,
    deal: struct {
        identity_divisor: u32,
        row_divisor: u32,
        column_divisor: u32,
        row_candidates: u8,
        column_candidates: u8,
    },
    timing: struct {
        flip_frames: u8,
        matched_scale_frames: u8,
        matched_fade_frames: u8,
        resolve_frames: u8,
        deal_ticks: u8,
    },
    moves_cap: u32,
    settlement: struct { balance_cap: u32, flag_mask: u32, flag_value: u32, result_bit: u8 },
};
const Wire = struct {
    schema: []const u8,
    families: struct { dice: DiceWire, coin: CoinWire, karuta: KarutaWire },
};

fn diceRules(wire: DiceWire) !DiceRules {
    if (!std.mem.eql(u8, wire.modes[0].id, "ordinary") or
        !std.mem.eql(u8, wire.modes[1].id, "fixed") or
        !std.mem.eql(u8, wire.modes[2].id, "profit")) return error.InvalidContracts;
    if (wire.modes[0].fixed_wager != null or wire.modes[0].profit_goal != null) return error.InvalidContracts;
    if (wire.modes[1].fixed_wager == null or wire.modes[1].profit_goal != null) return error.InvalidContracts;
    if (wire.modes[2].fixed_wager != null or wire.modes[2].profit_goal == null) return error.InvalidContracts;
    var rules = DiceRules{
        .modes = .{
            .{ .fixed_wager = null, .profit_goal = null },
            .{ .fixed_wager = wire.modes[1].fixed_wager.?, .profit_goal = null },
            .{ .fixed_wager = null, .profit_goal = wire.modes[2].profit_goal.? },
        },
        .minimum_balance = wire.minimum_balance,
        .balance_cap = wire.balance_cap,
        .step = wire.wager.step,
        .increments = wire.wager.increments,
        .wager_maximum = wire.wager.maximum,
        .ordinary_min = wire.ordinary_scores.minimum,
        .ordinary_max = wire.ordinary_scores.maximum,
        .specials = undefined,
        .failure_limit = wire.zero_score.failures_before_turn_passes,
        .third_multiplier = wire.zero_score.third_failure_multiplier,
        .tie_when_opponent_zero = wire.zero_score.tie_when_opponent_zero,
    };
    for (wire.specials, 0..) |row, i| {
        rules.specials[i] = .{
            .score = @intCast(row.score),
            .roller_wins = row.roller_wins,
            .multiplier = row.multiplier,
        };
    }
    if (rules.step == 0 or rules.increments[0] == 0 or rules.increments[1] == 0 or
        rules.wager_maximum == 0 or rules.failure_limit == 0 or rules.balance_cap == 0 or
        rules.ordinary_min == 0 or rules.ordinary_min > rules.ordinary_max) return error.InvalidContracts;
    return rules;
}

fn coinRules(wire: CoinWire) !CoinRules {
    if (wire.stakes[0] == 0 or wire.stakes[1] == 0 or wire.stakes[2] == 0 or
        wire.shuffle.positions < 2 or wire.shuffle.steps == 0 or wire.choice.cups < 2 or
        wire.balance_cap == 0 or wire.reveal_ticks == 0) return error.InvalidContracts;
    if (wire.quit_option != 3) return error.InvalidContracts;
    for (wire.difficulty) |row| {
        if (row.base == 0 or row.range == 0) return error.InvalidContracts;
        if (wire.shuffle.motion_high == 0 or wire.shuffle.motion_high <= row.range) return error.InvalidContracts;
    }
    return .{
        .stakes = wire.stakes,
        .quit_option = wire.quit_option,
        .balance_cap = wire.balance_cap,
        .bases = .{ wire.difficulty[0].base, wire.difficulty[1].base, wire.difficulty[2].base },
        .ranges = .{ wire.difficulty[0].range, wire.difficulty[1].range, wire.difficulty[2].range },
        .shuffle_positions = wire.shuffle.positions,
        .shuffle_steps = wire.shuffle.steps,
        .motion_high = wire.shuffle.motion_high,
        .cups = wire.choice.cups,
        .reveal_ticks = wire.reveal_ticks,
        .win_credit_stakes = wire.settlement.win_credit_stakes,
        .net_credit_stakes = wire.settlement.net_credit_stakes,
        .profit_threshold = wire.profit.threshold,
        .flag_mask = wire.profit.flag_mask,
        .flag_value = wire.profit.flag_value,
        .result_bit = wire.profit.result_bit,
    };
}

fn karutaRules(wire: KarutaWire) !KarutaRules {
    if (wire.board.rows != 8 or wire.board.columns != 6 or wire.board.cells != 48 or
        wire.board.pairs != 24 or wire.board.faces == 0) return error.InvalidContracts;
    var rules = KarutaRules{
        .rows = wire.board.rows,
        .columns = wire.board.columns,
        .cells = wire.board.cells,
        .pairs = wire.board.pairs,
        .faces = wire.board.faces,
        .empty_face = wire.board.empty_face,
        .back_face = wire.board.back_face,
        .rounds = undefined,
        .quit_round = wire.quit_round,
        .identity_divisor = wire.deal.identity_divisor,
        .row_divisor = wire.deal.row_divisor,
        .column_divisor = wire.deal.column_divisor,
        .row_candidates = wire.deal.row_candidates,
        .column_candidates = wire.deal.column_candidates,
        .flip_frames = wire.timing.flip_frames,
        .matched_scale_frames = wire.timing.matched_scale_frames,
        .matched_fade_frames = wire.timing.matched_fade_frames,
        .resolve_frames = wire.timing.resolve_frames,
        .deal_ticks = wire.timing.deal_ticks,
        .moves_cap = wire.moves_cap,
        .balance_cap = wire.settlement.balance_cap,
        .flag_mask = wire.settlement.flag_mask,
        .flag_value = wire.settlement.flag_value,
        .result_bit = wire.settlement.result_bit,
    };
    for (wire.rounds, 0..) |row, i| {
        if (row.index != i) return error.InvalidContracts;
        if (row.identities == 0 or row.identities > 15 or row.record_moves == 0) return error.InvalidContracts;
        rules.rounds[i] = .{ .identities = row.identities, .record_moves = row.record_moves };
    }
    if (rules.flip_frames == 0 or rules.matched_scale_frames == 0 or rules.matched_fade_frames == 0 or
        rules.resolve_frames == 0 or rules.deal_ticks == 0 or rules.moves_cap == 0 or
        rules.identity_divisor == 0 or rules.row_divisor == 0 or rules.column_divisor == 0 or
        rules.rows != 8 or rules.columns != 6) return error.InvalidContracts;
    return rules;
}
