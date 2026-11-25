//! The mode-local settlement wallet and its atomic journal.
//!
//! This is *not* a second save/result host. The wallet is the projection of the
//! exact source fields the three overlays publish -- money at `gs+0x1C`, the
//! status flag page at `gs+0x230`, the recruit flags at `gs+0x1AF4`, the dice
//! progression flags, retained-winnings context and KARUTA per-round records -- plus the
//! caller's draw cursor and receipt list.  The host publishes the same
//! effects through the shared mode-result host; this type only proves the
//! ordered effect plan, the duplicate/stale refusal and the mid-mode restore
//! rules that the durable owner has to honour.

const std = @import("std");
const types = @import("types.zig");

pub const Game = types.Game;
pub const max_receipts = 32;
pub const max_effects = 8;

pub const money_cap: u32 = 999999;

/// Source status-flag page base (`gs+0x230`) and recruit bitmap base
/// (`gs+0x1AF4`). Both are addressed by the overlay stores the ledger pins.
pub const status_bytes = 16;
pub const recruit_bytes = 108;

pub const Retained = u32;
pub const DiceFlag = enum { fixed_win, profit_goal };
pub const DiceFlags = struct { fixed_won: bool = false, profit_goal: bool = false };

/// The canonical values a settlement may touch. Everything is compared before
/// publication; the publication itself is one assignment of the candidate.
pub const Wallet = struct {
    revision: u64 = 0,
    money: u32 = 0,
    net: i32 = 0,
    status: [status_bytes]u8 = @splat(0),
    dice_flags: DiceFlags = .{},
    save_counter: u32 = 0,
    recruited: [recruit_bytes]u8 = @splat(0),
    retained: Retained = 0,
    best: [4]u32 = @splat(0),
    draws: u64 = 0,
    receipts: [max_receipts]u64 = @splat(0),
    receipt_count: u8 = 0,
    last_receipt: u64 = 0,

    pub fn hasReceipt(self: Wallet, receipt: u64) bool {
        for (self.receipts[0..self.receipt_count]) |id| if (id == receipt) return true;
        return false;
    }

    /// A fresh caller receipt must be nonzero, newer than the last settled one
    /// and absent from the retained window.
    pub fn receiptAcceptable(self: Wallet, receipt: u64) bool {
        if (receipt == 0) return false;
        if (receipt <= self.last_receipt) return false;
        return !self.hasReceipt(receipt);
    }

    pub fn validate(self: Wallet) !void {
        if (self.money > money_cap) return error.InvalidWallet;
        if (self.receipt_count > max_receipts) return error.InvalidWallet;
        for (self.receipts[0..self.receipt_count]) |id| if (id == 0) return error.InvalidWallet;
        if (self.last_receipt != 0 and !self.hasReceipt(self.last_receipt) and
            self.receipt_count >= max_receipts) return error.InvalidWallet;
    }
};

/// The before-facts a settlement was computed against.
pub const Expected = struct {
    revision: u64 = 0,
    money: u32 = 0,
    net: i32 = 0,
    status: [status_bytes]u8 = @splat(0),
    dice_flags: DiceFlags = .{},
    save_counter: u32 = 0,
    retained: Retained = 0,
    best: [4]u32 = @splat(0),
    draws: u64 = 0,
};

pub const EffectKind = enum { money, net, status_bit, dice_flag, retained, best_record, draws, recruit_bit };

pub const Effect = union(EffectKind) {
    /// The source writes the balanced money value, not a delta.
    money: u32,
    /// COIN's signed running net (`net += 2*stake` on a win).
    net: i32,
    /// `offset` is relative to the status page (`gs+0x230`), so COIN's result
    /// byte `gs+0x232` is offset 2 and KARUTA's `gs+0x233` is offset 3.
    status_bit: struct { offset: u8, mask: u8 },
    dice_flag: DiceFlag,
    retained: Retained,
    best_record: struct { round: u8, elapsed: u32 },
    draws: u64,
    recruit_bit: struct { index: u8, mask: u8 },

    pub fn validate(self: Effect) !void {
        switch (self) {
            .money => |value| if (value > money_cap) return error.InvalidEffect,
            .net => |value| if (value > 10_000_000 or value < -10_000_000) return error.InvalidEffect,
            .status_bit => |bit| if (bit.offset >= status_bytes or bit.mask == 0) return error.InvalidEffect,
            .dice_flag => {},
            .retained => |value| if (value > money_cap) return error.InvalidEffect,
            .best_record => |record| if (record.round >= 4 or record.elapsed == 0) return error.InvalidEffect,
            .draws => {},
            .recruit_bit => |bit| if (bit.index >= recruit_bytes or bit.mask == 0) return error.InvalidEffect,
        }
    }

    fn apply(self: Effect, wallet: *Wallet) !void {
        switch (self) {
            .money => |value| wallet.money = value,
            .net => |value| wallet.net = value,
            .status_bit => |bit| wallet.status[bit.offset] |= bit.mask,
            .dice_flag => |flag| switch (flag) {
                .fixed_win => wallet.dice_flags.fixed_won = true,
                .profit_goal => wallet.dice_flags.profit_goal = true,
            },
            .retained => |value| wallet.retained = value,
            .best_record => |record| {
                // Lower elapsed is the better record, exactly like the source
                // comparison; a worse run never overwrites a better one.
                if (wallet.best[record.round] == 0 or record.elapsed < wallet.best[record.round]) {
                    wallet.best[record.round] = record.elapsed;
                }
            },
            .draws => |cursor| {
                if (cursor < wallet.draws) return error.NonMonotonicDraws;
                wallet.draws = cursor;
            },
            .recruit_bit => |bit| wallet.recruited[bit.index] |= bit.mask,
        }
    }
};

pub const Completion = enum {
    settled,
    replay_prompt,
    exited,
    bankrupt,
    round_continues,
    profit_flag,
    round_complete,
    record,
    flag,
    round_selected,
};

pub const Settlement = struct {
    game: Game,
    entry_id: u64,
    content_id: u64,
    receipt: u64,
    expected: Expected,
    effect_count: u8 = 0,
    effects: [max_effects]Effect = undefined,
    completion: Completion = .settled,

    pub fn init(game: Game, entry_id: u64, content_id: u64, receipt: u64, expected: Expected) Settlement {
        std.debug.assert(entry_id != 0 and content_id != 0 and receipt != 0);
        return .{
            .game = game,
            .entry_id = entry_id,
            .content_id = content_id,
            .receipt = receipt,
            .expected = expected,
        };
    }

    pub fn add(self: *Settlement, effect: Effect) !void {
        if (self.effect_count >= max_effects) return error.TooManyEffects;
        try effect.validate();
        self.effects[self.effect_count] = effect;
        self.effect_count += 1;
    }

    pub fn effectOf(self: Settlement, kind: EffectKind) ?Effect {
        for (self.effects[0..self.effect_count]) |effect| {
            if (std.meta.activeTag(effect) == kind) return effect;
        }
        return null;
    }

    pub fn validate(self: Settlement) !void {
        if (self.entry_id == 0 or self.content_id == 0 or self.receipt == 0) return error.InvalidSettlement;
        if (self.effect_count == 0 or self.effect_count > max_effects) return error.InvalidSettlement;
        var money_seen = false;
        var draws_seen = false;
        var net_seen = false;
        for (self.effects[0..self.effect_count]) |effect| {
            try effect.validate();
            switch (effect) {
                .money => {
                    if (money_seen) return error.InvalidSettlement;
                    money_seen = true;
                },
                .draws => {
                    if (draws_seen) return error.InvalidSettlement;
                    draws_seen = true;
                },
                .net => {
                    if (net_seen) return error.InvalidSettlement;
                    net_seen = true;
                },
                // A duel/COIN/KARUTA run publishes exactly one record slot and,
                // for KARUTA, at most one flag byte.
                .best_record => {},
                .status_bit => {},
                .dice_flag => if (self.game != .dice) return error.InvalidSettlement,
                .recruit_bit => {},
                .retained => {},
            }
        }
        if (!money_seen) return error.MissingMoneyEffect;
        if (self.game == .coin or self.game == .dice) {
            if (!draws_seen) return error.MissingDrawsEffect;
            if (self.game == .coin and !net_seen) return error.MissingNetEffect;
            if (self.game == .dice and net_seen) return error.UnexpectedNetEffect;
        } else {
            if (draws_seen) return error.UnexpectedDrawsEffect;
            if (net_seen) return error.UnexpectedNetEffect;
        }
    }
};

pub const Outcome = struct {
    revision: u64,
    receipt: u64,
    money: u32,
};

/// The single canonical mutation. On any error the wallet is unchanged.
pub fn apply(settlement: Settlement, wallet: *Wallet) !Outcome {
    // Duplicate settlement is decided before staleness: a receipt that is
    // already in the ledger must be reported as a duplicate even though the
    // money/records it produced make every expected fact stale.
    if (wallet.hasReceipt(settlement.receipt) or settlement.receipt <= wallet.last_receipt) {
        return error.DuplicateSettlement;
    }
    try checkExpected(settlement.expected, wallet.*);
    try settlement.validate();

    var candidate = wallet.*;
    for (settlement.effects[0..settlement.effect_count]) |effect| try effect.apply(&candidate);
    if (candidate.money > money_cap) return error.InvalidWallet;
    candidate.revision = wallet.revision + 1;
    if (candidate.receipt_count == max_receipts) return error.ReceiptWindowFull;
    candidate.receipts[candidate.receipt_count] = settlement.receipt;
    candidate.receipt_count += 1;
    candidate.last_receipt = settlement.receipt;
    try candidate.validate();

    wallet.* = candidate;
    return .{ .revision = candidate.revision, .receipt = settlement.receipt, .money = candidate.money };
}

pub fn checkExpected(expected: Expected, wallet: Wallet) !void {
    if (expected.revision != wallet.revision) return error.StaleBefore;
    if (expected.money != wallet.money) return error.StaleBefore;
    if (expected.net != wallet.net) return error.StaleBefore;
    if (expected.retained != wallet.retained) return error.StaleBefore;
    if (expected.draws != wallet.draws) return error.StaleBefore;
    if (expected.save_counter != wallet.save_counter) return error.StaleBefore;
    if (!std.mem.eql(u8, &expected.status, &wallet.status)) return error.StaleBefore;
    if (!std.meta.eql(expected.dice_flags, wallet.dice_flags)) return error.StaleBefore;
    if (!std.mem.eql(u8, std.mem.asBytes(&expected.best), std.mem.asBytes(&wallet.best))) return error.StaleBefore;
}

pub fn expectedOf(wallet: Wallet) Expected {
    return .{
        .revision = wallet.revision,
        .money = wallet.money,
        .net = wallet.net,
        .status = wallet.status,
        .dice_flags = wallet.dice_flags,
        .save_counter = wallet.save_counter,
        .retained = wallet.retained,
        .best = wallet.best,
        .draws = wallet.draws,
    };
}

test "wallet: default is valid and accepts only fresh receipts" {
    const wallet = Wallet{};
    try wallet.validate();
    try std.testing.expect(wallet.receiptAcceptable(1));
    try std.testing.expect(!wallet.receiptAcceptable(0));
}

test "settlement: duplicate and stale are refused without mutation" {
    var wallet = Wallet{ .money = 1000 };
    var first = Settlement.init(.coin, 7, 11, 1, expectedOf(wallet));
    try first.add(.{ .money = 900 });
    try first.add(.{ .net = 100 });
    try first.add(.{ .draws = 3 });
    const outcome = try apply(first, &wallet);
    try std.testing.expectEqual(@as(u32, 900), outcome.money);
    try std.testing.expectEqual(@as(u64, 1), wallet.revision);
    const snapshot = wallet;

    try std.testing.expectError(error.DuplicateSettlement, apply(first, &wallet));
    try std.testing.expectEqual(snapshot, wallet);

    var second = Settlement.init(.coin, 7, 11, 2, expectedOf(Wallet{ .money = 1000 }));
    try second.add(.{ .money = 900 });
    try second.add(.{ .net = 100 });
    try second.add(.{ .draws = 3 });
    try std.testing.expectError(error.StaleBefore, apply(second, &wallet));
    try std.testing.expectEqual(snapshot, wallet);
}

test "settlement: effects are ordered and validated" {
    var wallet = Wallet{ .money = 500 };
    var plan = Settlement.init(.karuta, 8, 15, 4, expectedOf(wallet));
    try plan.add(.{ .money = 500 });
    try plan.add(.{ .best_record = .{ .round = 2, .elapsed = 2400 } });
    try plan.add(.{ .status_bit = .{ .offset = 3, .mask = 0x40 } });
    _ = try apply(plan, &wallet);
    try std.testing.expectEqual(@as(u32, 500), wallet.money);
    try std.testing.expectEqual(@as(u32, 2400), wallet.best[2]);
    try std.testing.expectEqual(@as(u8, 0x40), wallet.status[3]);

    var worse = Settlement.init(.karuta, 8, 15, 5, expectedOf(wallet));
    try worse.add(.{ .money = 500 });
    try worse.add(.{ .best_record = .{ .round = 2, .elapsed = 3300 } });
    _ = try apply(worse, &wallet);
    try std.testing.expectEqual(@as(u32, 2400), wallet.best[2]);
}
