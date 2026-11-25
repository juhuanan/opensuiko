//! Admission, frame/dialogue/animation ownership and the optional-game loop bridge.
//!
//! The host never computes a die, a cup or a card: every play input is forwarded
//! to the accepted optional-game session and every settlement is the engine proposal turned
//! into an ordered effect plan. What the host adds is the source-qualified
//! admission (a proven caller site, or the explicit `MissingFieldCaller`
//! refusal), exclusive frame ownership, and the atomic settlement/restore rules.

const std = @import("std");
const types = @import("types.zig");
const ledger = @import("ledger.zig");
const settle = @import("settle.zig");
const game_contracts = @import("optional_game_contracts");

pub const Game = types.Game;
pub const Wallet = settle.Wallet;
pub const input_mod = @import("input.zig");
pub const Input = input_mod.Input;

pub const max_receipts = settle.max_receipts;

pub const RecruitGrant = struct { index: u8, mask: u8 };

/// One field admission. `caller_site` names the decoded source request site;
/// a module selector alone is never enough.
pub const Admission = struct {
    game: Game,
    entry: Entry,
    caller_site: u32,
    revision: u64,
    /// KARUTA's face-availability table is a caller obligation.
    karuta_eligible: ?[game_contracts.face_count]bool = null,
    /// No traced optional game authorizes a recruit consequence; a grant is
    /// refused instead of inventing one.
    recruit: ?RecruitGrant = null,
};

pub const Entry = union(Game) {
    dice: game_contracts.DiceEntry,
    coin: game_contracts.CoinEntry,
    karuta: game_contracts.KarutaEntry,
};

pub const Session = union(Game) {
    dice: game_contracts.DiceSession,
    coin: game_contracts.CoinSession,
    karuta: game_contracts.KarutaSession,
};

pub const ModeOwner = enum { field, mode };

pub const Snapshot = struct {
    session: Session,
    wallet: Wallet,
    draws: game_contracts.Draws,
    token: u64,
    owner: ModeOwner,
    eligible: [game_contracts.face_count]bool,
};

pub const Host = struct {
    ledger: ledger.Ledger,
    rules: game_contracts.Contracts,
    wallet: Wallet = .{},
    draws: game_contracts.Draws = .{},
    owner: ModeOwner = .field,
    token: u64 = 0,
    session: ?Session = null,
    eligible: [game_contracts.face_count]bool = @splat(false),

    pub fn init(allocator: std.mem.Allocator, ledger_bytes: []const u8, draws: game_contracts.Draws, rules: game_contracts.Contracts) !Host {
        return .{
            .ledger = try ledger.Ledger.load(allocator, ledger_bytes),
            .rules = rules,
            .draws = draws,
        };
    }

    pub fn deinit(self: *Host) void {
        self.ledger.deinit();
        self.* = undefined;
    }

    pub fn ownsFrame(self: Host) bool {
        return self.owner == .mode;
    }

    /// Field dialogue and animation are refused while the mode owns the frame:
    /// the source uninstalls the field driver, so the field script is not ticked.
    pub fn fieldDialogue(self: Host) !void {
        if (self.owner == .mode) return error.FieldSuspendedDuringMode;
    }

    pub fn fieldAnimation(self: Host) !void {
        if (self.owner == .mode) return error.FieldSuspendedDuringMode;
    }

    /// Text inside the mode is owned by the mode (COIN/KARUTA run the bytecode
    /// interpreter themselves); the field may not claim it.
    pub fn modeDialogue(self: Host) !void {
        if (self.owner != .mode) return error.ModeNotOwned;
    }

    pub fn admit(self: *Host, admission: Admission) !void {
        if (self.owner != .field) return error.ModeAlreadyOwned;
        if (std.meta.activeTag(admission.entry) != admission.game) return error.WrongGameInput;
        const family = try self.ledger.requireFamily(admission.game);
        if (family.entry_status != .proven) return error.MissingFieldCaller;
        if (!family.admitsSite(admission.caller_site)) return error.UnknownCaller;
        if (admission.game == .dice) {
            for (family.callers) |caller| {
                if (caller.site != admission.caller_site) continue;
                const variant = caller.dice_variant orelse return error.UnknownDiceVariant;
                if (variant != @backingInt(admission.entry.dice.variant)) return error.WrongDiceVariant;
            }
        }
        if (admission.revision != self.wallet.revision) return error.StaleRevision;
        if (admission.recruit != null) return error.RecruitConsequenceNotProven;
        try self.wallet.validate();

        const session: Session = switch (admission.entry) {
            .dice => |entry| .{ .dice = try self.admitDice(entry) },
            .coin => |entry| .{ .coin = try self.admitCoin(entry) },
            .karuta => |entry| blk: {
                const eligible = admission.karuta_eligible orelse return error.MissingEligibleFaces;
                const next = try self.admitKaruta(entry);
                self.eligible = eligible;
                break :blk .{ .karuta = next };
            },
        };
        self.session = session;
        self.owner = .mode;
        self.token +%= 1;
        if (self.token == 0) self.token = 1;
    }

    fn admitDice(self: Host, entry: game_contracts.DiceEntry) !game_contracts.DiceSession {
        if (!self.wallet.receiptAcceptable(entry.receipt_id)) return error.BadReceipt;
        if (entry.balance != self.wallet.money) return error.StaleBalance;
        if (entry.variant == .fixed and self.wallet.dice_flags.fixed_won) return error.EventConditionFalse;
        return game_contracts.DiceSession.init(self.rules.dice, entry);
    }

    fn admitCoin(self: Host, entry: game_contracts.CoinEntry) !game_contracts.CoinSession {
        if (!self.wallet.receiptAcceptable(entry.receipt_id)) return error.BadReceipt;
        if (entry.balance != self.wallet.money) return error.StaleBalance;
        if (entry.net != self.wallet.net) return error.StaleBalance;
        return game_contracts.CoinSession.init(self.rules.coin, entry);
    }

    fn admitKaruta(self: Host, entry: game_contracts.KarutaEntry) !game_contracts.KarutaSession {
        if (!self.wallet.receiptAcceptable(entry.receipt_id)) return error.BadReceipt;
        if (entry.balance != self.wallet.money) return error.StaleBalance;
        if (!std.mem.eql(u8, std.mem.asBytes(&entry.best), std.mem.asBytes(&self.wallet.best))) return error.StaleRecord;
        return game_contracts.KarutaSession.init(self.rules.karuta, entry);
    }

    /// Forward one ordinary input. The session and the caller RNG are committed
    /// only when the engine step succeeds, so a failed input leaves both untouched.
    pub fn tick(self: *Host, input: Input) !void {
        if (self.owner != .mode) return error.ModeNotOwned;
        var next = self.session orelse return error.NoSession;
        var draws = self.draws;
        switch (next) {
            .dice => |*session| switch (input) {
                .dice_tick => |frame_input| try session.tickThrow(frame_input.buttons, self.wallet.save_counter, &draws),
                else => try input_mod.applyDice(session, input),
            },
            .coin => |*session| try input_mod.applyCoin(session, &draws, input),
            .karuta => |*session| try input_mod.applyKaruta(session, &draws, &self.eligible, input),
        }
        self.session = next;
        self.draws = draws;
    }

    pub fn plan(self: Host) !settle.Settlement {
        if (self.owner != .mode) return error.ModeNotOwned;
        const session = self.session orelse return error.NoSession;
        return switch (session) {
            .dice => |value| planDice(value, self.wallet, drawsCursor(self.draws)),
            .coin => |value| planCoin(value, self.wallet, drawsCursor(self.draws)),
            .karuta => |value| planKaruta(value, self.wallet),
        };
    }

    /// Publish the proposal: duplicate/stale/tampered plans are refused before
    /// any canonical mutation, and the engine acknowledgement is proven on a
    /// copy first so a failed plan cannot half-settle.
    pub fn settleMode(self: *Host) !settle.Outcome {
        if (self.owner != .mode) return error.ModeNotOwned;
        const session = self.session orelse return error.NoSession;
        const settlement = switch (session) {
            .dice => |value| try planDice(value, self.wallet, drawsCursor(self.draws)),
            .coin => |value| try planCoin(value, self.wallet, drawsCursor(self.draws)),
            .karuta => |value| try planKaruta(value, self.wallet),
        };

        var applied_buffer: [max_receipts]u64 = undefined;
        const applied_count = self.wallet.receipt_count;
        @memcpy(applied_buffer[0..applied_count], self.wallet.receipts[0..applied_count]);
        const applied = applied_buffer[0..applied_count];

        var probe = session;
        try acknowledge(&probe, settlement, applied);

        const outcome = try settle.apply(settlement, &self.wallet);
        try acknowledge(&self.session.?, settlement, applied);
        return outcome;
    }

    /// Begin a follow-up round after an acknowledged settlement. The caller
    /// issues a fresh receipt; the committed wallet values are the entry facts.
    pub fn nextRound(self: *Host, receipt: u64) !void {
        if (self.owner != .mode) return error.ModeNotOwned;
        if (!self.wallet.receiptAcceptable(receipt)) return error.BadReceipt;
        var next = self.session orelse return error.NoSession;
        switch (next) {
            .dice => |*session| try session.beginNext(receipt, self.wallet.money),
            .coin => |*session| try session.continueRound(receipt, self.wallet.money, self.wallet.net),
            .karuta => |*session| try session.continueRound(receipt, self.wallet.money, self.wallet.best),
        }
        self.session = next;
    }

    pub fn completion(self: Host) ?settle.Completion {
        const session = self.session orelse return null;
        return switch (session) {
            .dice => |value| if (value.completionToken()) |token| mapDice(token) else null,
            .coin => |value| if (value.completionToken()) |token| mapCoin(token) else null,
            .karuta => |value| if (value.completionToken()) |token| mapKaruta(token) else null,
        };
    }

    /// Hand the frame back to the field. A pending proposal must be settled or
    /// cancelled first.
    pub fn finish(self: *Host) !void {
        if (self.owner != .mode) return error.ModeNotOwned;
        const session = self.session orelse return error.NoSession;
        const done = switch (session) {
            .dice => |value| value.phase == .exited or value.phase == .acknowledged,
            .coin => |value| value.phase == .exited or value.phase == .acknowledged,
            .karuta => |value| value.phase == .exited or value.phase == .acknowledged,
        };
        if (!done) return error.PendingSettlement;
        self.session = null;
        self.owner = .field;
    }

    pub fn checkpoint(self: Host) !Snapshot {
        if (self.owner != .mode) return error.ModeNotOwned;
        return .{
            .session = self.session orelse return error.NoSession,
            .wallet = self.wallet,
            .draws = self.draws,
            .token = self.token,
            .owner = self.owner,
            .eligible = self.eligible,
        };
    }

    /// Restore a mid-mode or post-result snapshot. The committed wallet must be
    /// unchanged since the checkpoint (a settlement in between makes it stale),
    /// the RNG tape must be the same stream, and the session is revalidated by
    /// the optional-game restore entry point before it is adopted.
    pub fn restore(self: *Host, snapshot: Snapshot) !void {
        if (snapshot.owner != .mode or snapshot.token != self.token) return error.StaleSnapshot;
        if (!std.meta.eql(snapshot.wallet, self.wallet)) return error.StaleSnapshot;
        if (snapshot.draws.values.ptr != self.draws.values.ptr or snapshot.draws.values.len != self.draws.values.len) {
            return error.StaleSnapshot;
        }
        if ((snapshot.draws.bios_state == null) != (self.draws.bios_state == null)) return error.StaleSnapshot;
        const session: Session = switch (snapshot.session) {
            .dice => |value| .{ .dice = try game_contracts.DiceSession.restore(value, self.rules.dice) },
            .coin => |value| .{ .coin = try game_contracts.CoinSession.restore(value, self.rules.coin) },
            .karuta => |value| .{ .karuta = try game_contracts.KarutaSession.restore(value, self.rules.karuta) },
        };
        self.session = session;
        self.draws = snapshot.draws;
        self.eligible = snapshot.eligible;
        self.owner = .mode;
    }
};

pub fn drawsCursor(draws: game_contracts.Draws) u64 {
    return @as(u64, @intCast(draws.cursor));
}

fn acknowledge(session: *Session, settlement: settle.Settlement, applied: []const u64) !void {
    const receipts = [_]u64{settlement.receipt};
    switch (session.*) {
        .dice => |*value| _ = try value.acknowledge(moneyOf(settlement), &receipts, applied),
        .coin => |*value| _ = try value.acknowledge(moneyOf(settlement), netOf(settlement), &receipts, applied),
        .karuta => |*value| _ = try value.acknowledge(moneyOf(settlement), bestOf(settlement), &receipts, applied),
    }
}

fn moneyOf(settlement: settle.Settlement) u32 {
    const effect = settlement.effectOf(.money) orelse return 0;
    return effect.money;
}

fn netOf(settlement: settle.Settlement) i32 {
    const effect = settlement.effectOf(.net) orelse return 0;
    return effect.net;
}

fn bestOf(settlement: settle.Settlement) u32 {
    const effect = settlement.effectOf(.best_record) orelse return 0;
    return effect.best_record.elapsed;
}

fn mapDice(token: game_contracts.DiceCompletion) settle.Completion {
    return switch (token) {
        .settled => .settled,
        .replay_prompt => .replay_prompt,
        .exited => .exited,
        .bankrupt => .bankrupt,
    };
}

fn mapCoin(token: game_contracts.CoinCompletion) settle.Completion {
    return switch (token) {
        .settled => .settled,
        .round_continues => .round_continues,
        .profit_flag => .profit_flag,
        .exited => .exited,
    };
}

fn mapKaruta(token: game_contracts.KarutaCompletion) settle.Completion {
    return switch (token) {
        .round_complete => .round_complete,
        .record => .record,
        .flag => .flag,
        .round_selected => .round_selected,
        .exited => .exited,
    };
}

pub fn planDice(session: game_contracts.DiceSession, wallet: Wallet, draws: u64) !settle.Settlement {
    if (session.phase != .proposal) return error.NoProposal;
    const proposal = try session.propose();
    if (proposal.before_balance != wallet.money) return error.StaleBalance;
    var plan = settle.Settlement.init(.dice, proposal.entry_id, proposal.content_id, proposal.receipt_id, settle.expectedOf(wallet));
    try plan.add(.{ .money = proposal.after_balance });
    try plan.add(.{ .retained = proposal.retained });
    try plan.add(.{ .draws = draws });
    switch (proposal.consequence) {
        .none => {},
        .fixed_win => try plan.add(.{ .dice_flag = .fixed_win }),
        .profit_goal => try plan.add(.{ .dice_flag = .profit_goal }),
    }
    plan.completion = if (session.completionToken()) |token| mapDice(token) else .settled;
    return plan;
}

pub fn planCoin(session: game_contracts.CoinSession, wallet: Wallet, draws: u64) !settle.Settlement {
    if (session.phase != .proposal) return error.NoProposal;
    const proposal = try session.propose();
    if (proposal.before_balance != wallet.money) return error.StaleBalance;
    if (proposal.before_net != wallet.net) return error.StaleBalance;
    var plan = settle.Settlement.init(.coin, proposal.entry_id, proposal.content_id, proposal.receipt_id, settle.expectedOf(wallet));
    try plan.add(.{ .money = proposal.after_balance });
    try plan.add(.{ .net = proposal.after_net });
    try plan.add(.{ .draws = draws });
    if (proposal.profit_flag or proposal.consequence == .profit_flag) {
        // The source sets result bit 0x40 in gs+0x232 (status page offset 2).
        try plan.add(.{ .status_bit = .{ .offset = 2, .mask = 0x40 } });
    }
    plan.completion = if (session.completionToken()) |token| mapCoin(token) else .settled;
    return plan;
}

pub fn planKaruta(session: game_contracts.KarutaSession, wallet: Wallet) !settle.Settlement {
    if (session.phase != .proposal) return error.NoProposal;
    const proposal = try session.propose();
    if (session.balance != wallet.money) return error.StaleBalance;
    if (proposal.best_before != wallet.best[proposal.round]) return error.StaleRecord;
    var plan = settle.Settlement.init(.karuta, proposal.entry_id, proposal.content_id, proposal.receipt_id, settle.expectedOf(wallet));
    // KARUTA pays no bits: the completion path only clamps the caller balance.
    try plan.add(.{ .money = session.balance });
    try plan.add(.{ .best_record = .{ .round = proposal.round, .elapsed = proposal.best_after } });
    if (proposal.flag_set) {
        // The source sets result bit 0x40 in gs+0x233 (status page offset 3).
        try plan.add(.{ .status_bit = .{ .offset = 3, .mask = 0x40 } });
    }
    plan.completion = if (session.completionToken()) |token| mapKaruta(token) else .round_complete;
    return plan;
}
