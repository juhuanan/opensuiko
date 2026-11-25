//! Logical session contract for the optional three-cup COIN game.

const draws_mod = @import("battle_rules");
const rules_mod = @import("optional_game_rules.zig");
const CoinRules = rules_mod.CoinRules;
const host_rejection_budget = rules_mod.host_rejection_budget;

pub const CoinPhase = enum(u8) { select, shuffling, choice, reveal, proposal, acknowledged, exited };
pub const CoinConsequence = enum(u8) { none, profit_flag, insufficient_funds };
pub const CoinCompletion = enum { settled, round_continues, profit_flag, exited };

pub const CoinEntry = struct {
    entry_id: u64,
    content_id: u64,
    receipt_id: u64,
    balance: u32,
    net: i32,
    difficulty: u8,
    flags: u32,
};

pub const CoinResult = struct {
    entry_id: u64,
    content_id: u64,
    receipt_id: u64,
    before_balance: u32,
    after_balance: u32,
    before_net: i32,
    after_net: i32,
    stake: u32,
    win: bool,
    difficulty: u8,
    cup: u8,
    coin_position: u8,
    profit_flag: bool,
    consequence: CoinConsequence,
};

pub const CoinSession = struct {
    version: u8 = 1,
    rules: CoinRules,
    entry_id: u64,
    content_id: u64,
    receipt_id: u64,
    flags: u32,
    balance: u32,
    net: i32,
    start_balance: u32 = 0,
    start_net: i32 = 0,
    difficulty: u8,
    phase: CoinPhase,
    stake: u32 = 0,
    coin_position: u8 = 1,
    shuffle_remaining: u8 = 0,
    last_swap: ?[2]u8 = null,
    cup: u8 = 0,
    reveal_countdown: u16 = 0,
    win: bool = false,
    profit_flag: bool = false,
    consequence: CoinConsequence = .none,

    pub fn init(rules: CoinRules, entry: CoinEntry) !CoinSession {
        if (entry.entry_id == 0 or entry.content_id == 0 or entry.receipt_id == 0) return error.InvalidEntry;
        if (entry.balance > rules.balance_cap) return error.InvalidEntry;
        if (entry.difficulty > rules.quit_option) return error.InvalidEntry;
        var session = CoinSession{
            .rules = rules,
            .entry_id = entry.entry_id,
            .content_id = entry.content_id,
            .receipt_id = entry.receipt_id,
            .flags = entry.flags,
            .balance = entry.balance,
            .net = entry.net,
            .difficulty = entry.difficulty,
            .phase = .select,
        };
        try session.validate();
        return session;
    }

    pub fn validate(self: CoinSession) !void {
        if (self.version != 1) return error.InvalidState;
        if (self.balance > self.rules.balance_cap) return error.InvalidState;
        if (self.difficulty > self.rules.quit_option) return error.InvalidState;
        if (self.coin_position >= self.rules.shuffle_positions) return error.InvalidState;
        if (self.cup >= self.rules.cups) return error.InvalidState;
        if (self.last_swap) |swap| {
            if (swap[0] >= self.rules.shuffle_positions or swap[1] >= self.rules.shuffle_positions or swap[0] == swap[1]) return error.InvalidState;
        }
        switch (self.phase) {
            .select => {
                if (self.stake != 0 or self.shuffle_remaining != 0) return error.InvalidState;
                if (self.start_balance != 0 or self.start_net != 0) return error.InvalidState;
            },
            .shuffling => {
                if (self.stake == 0) return error.InvalidState;
                if (self.shuffle_remaining > self.rules.shuffle_steps) return error.InvalidState;
            },
            .choice => {
                if (self.shuffle_remaining != 0) return error.InvalidState;
                if (self.stake == 0) return error.InvalidState;
            },
            .reveal => {
                if (self.reveal_countdown > self.rules.reveal_ticks) return error.InvalidState;
                if (self.stake == 0) return error.InvalidState;
            },
            .proposal, .acknowledged => {
                if (self.stake == 0) return error.InvalidState;
                if (self.start_balance < self.stake) return error.InvalidState;
            },
            .exited => {},
        }
    }

    pub fn select(self: *CoinSession, delta: i8) !void {
        if (self.phase != .select) return error.InvalidPhase;
        var next = self.*;
        const option_count: i8 = @intCast(self.rules.quit_option + 1);
        var value: i8 = @as(i8, @intCast(next.difficulty)) + delta;
        while (value < 0) value += option_count;
        while (value >= option_count) value -= option_count;
        next.difficulty = @intCast(value);
        try next.validate();
        self.* = next;
    }

    /// Confirm the difficulty selection. The quit entry ends the game; a stake
    /// larger than the balance is refused without changing the session.
    pub fn admit(self: *CoinSession) !void {
        if (self.phase != .select) return error.InvalidPhase;
        if (self.difficulty == self.rules.quit_option) {
            try self.exit();
            return;
        }
        const stake = self.rules.stakes[self.difficulty];
        if (self.balance < stake) return error.InsufficientFunds;
        var next = self.*;
        next.start_balance = self.balance;
        next.start_net = self.net;
        next.stake = stake;
        next.balance -= stake;
        next.net -= @as(i32, @intCast(stake));
        next.coin_position = 1;
        next.shuffle_remaining = self.rules.shuffle_steps;
        next.cup = 0;
        next.phase = .shuffling;
        try next.validate();
        self.* = next;
    }

    /// One shuffle step. A step is applied only when the presentation signals
    /// readiness; a paused animation leaves the session, the countdown and the
    /// RNG stream untouched.
    pub fn shuffleStep(self: *CoinSession, ready: bool, draws: *draws_mod.Draws) !void {
        if (self.phase != .shuffling) return error.InvalidPhase;
        if (!ready) return error.PresentationNotReady;
        if (self.shuffle_remaining == 0) return error.InvalidPhase;
        const range = self.rules.ranges[self.difficulty];
        const base = self.rules.bases[self.difficulty];
        const divisor = self.rules.motion_high / (@as(u32, range) + 1);
        if (divisor == 0) return error.InvalidContracts;
        var next = self.*;
        var random = draws.*;
        var attempts: usize = 0;
        while (true) : (attempts += 1) {
            if (attempts == host_rejection_budget) return error.RejectionBudget;
            const first = @as(u16, try random.next()) / 10922;
            const second = @as(u16, try random.next()) / 10922;
            if (first >= @as(u16, self.rules.shuffle_positions)) continue;
            if (second >= @as(u16, self.rules.shuffle_positions)) continue;
            if (first == second) continue;
            const motion = @as(u32, base) + @as(u32, try random.next()) / divisor;
            if (motion <= base) return error.InvalidMotion;
            next.last_swap = .{ @intCast(first), @intCast(second) };
            if (next.coin_position == first) {
                next.coin_position = @intCast(second);
            } else if (next.coin_position == second) {
                next.coin_position = @intCast(first);
            }
            break;
        }
        next.shuffle_remaining -= 1;
        if (next.shuffle_remaining == 0) next.phase = .choice;
        try next.validate();
        self.* = next;
        draws.* = random;
    }

    pub fn moveChoice(self: *CoinSession, delta: i8) !void {
        if (self.phase != .choice) return error.InvalidPhase;
        var next = self.*;
        const count: i8 = @intCast(self.rules.cups);
        var value: i8 = @as(i8, @intCast(next.cup)) + delta;
        while (value < 0) value += count;
        while (value >= count) value -= count;
        next.cup = @intCast(value);
        try next.validate();
        self.* = next;
    }

    /// Commit the cup and start the reveal countdown. The comparison is a real
    /// gate: it happens only after the source's reveal delay has elapsed.
    pub fn commitChoice(self: *CoinSession) !void {
        if (self.phase != .choice) return error.InvalidPhase;
        var next = self.*;
        next.reveal_countdown = self.rules.reveal_ticks;
        next.phase = .reveal;
        try next.validate();
        self.* = next;
    }

    /// Advance the reveal. Returns true when the comparison happened.
    pub fn advanceReveal(self: *CoinSession) !bool {
        if (self.phase != .reveal) return error.InvalidPhase;
        if (self.reveal_countdown > 0) {
            var next = self.*;
            next.reveal_countdown -= 1;
            try next.validate();
            self.* = next;
            return false;
        }
        var next = self.*;
        next.win = next.cup == next.coin_position;
        if (next.win) {
            const credit = @as(u64, next.stake) * next.rules.win_credit_stakes;
            const credited: u64 = @min(@as(u64, self.rules.balance_cap), @as(u64, next.balance) + credit);
            next.balance = @intCast(credited);
            next.net += @as(i32, @intCast(credit));
        }
        next.profit_flag = (next.flags & next.rules.flag_mask) == next.rules.flag_value and
            next.net >= next.rules.profit_threshold;
        next.consequence = if (next.profit_flag) .profit_flag else .none;
        next.phase = .proposal;
        try next.validate();
        self.* = next;
        return true;
    }

    pub fn propose(self: CoinSession) !CoinResult {
        if (self.phase != .proposal and self.phase != .acknowledged) return error.NoProposal;
        return .{
            .entry_id = self.entry_id,
            .content_id = self.content_id,
            .receipt_id = self.receipt_id,
            .before_balance = self.start_balance,
            .after_balance = self.balance,
            .before_net = self.start_net,
            .after_net = self.net,
            .stake = self.stake,
            .win = self.win,
            .difficulty = self.difficulty,
            .cup = self.cup,
            .coin_position = self.coin_position,
            .profit_flag = self.profit_flag,
            .consequence = self.consequence,
        };
    }

    pub fn acknowledge(self: *CoinSession, balance: u32, net: i32, receipts: []const u64, applied: []const u64) !CoinResult {
        if (self.phase != .proposal) return error.InvalidPhase;
        const proposal = try self.propose();
        if (balance != proposal.after_balance or net != proposal.after_net) return error.StaleBalance;
        try rules_mod.verifyReceipt(proposal.receipt_id, receipts, applied);
        var next = self.*;
        next.phase = .acknowledged;
        try next.validate();
        self.* = next;
        return proposal;
    }

    /// Continue after an acknowledged round. A profit consequence consumes the
    /// session; otherwise the caller supplies a fresh receipt and the selector
    /// restarts with the committed balance and net.
    pub fn continueRound(self: *CoinSession, receipt_id: u64, balance: u32, net: i32) !void {
        if (self.phase != .acknowledged) return error.InvalidPhase;
        if (self.consequence == .profit_flag) return error.ConsequenceConsumesSession;
        if (receipt_id == 0 or receipt_id == self.receipt_id) return error.InvalidEntry;
        if (balance > self.rules.balance_cap) return error.InvalidEntry;
        var next = self.*;
        next.receipt_id = receipt_id;
        next.balance = balance;
        next.net = net;
        next.phase = .select;
        next.stake = 0;
        next.start_balance = 0;
        next.start_net = 0;
        next.shuffle_remaining = 0;
        next.last_swap = null;
        next.cup = 0;
        next.coin_position = 1;
        next.win = false;
        next.profit_flag = false;
        next.consequence = .none;
        try next.validate();
        self.* = next;
    }

    pub fn exit(self: *CoinSession) !void {
        var next = self.*;
        next.phase = .exited;
        self.* = next;
    }

    pub fn completionToken(self: CoinSession) ?CoinCompletion {
        return switch (self.phase) {
            .exited => .exited,
            .acknowledged => if (self.consequence == .profit_flag) .profit_flag else .round_continues,
            .proposal => if (self.consequence == .profit_flag) .profit_flag else .settled,
            else => null,
        };
    }

    pub fn checkpoint(self: CoinSession) CoinSession {
        return self;
    }

    pub fn restore(candidate: CoinSession, rules: CoinRules) !CoinSession {
        var session = candidate;
        session.rules = rules;
        try session.validate();
        return session;
    }
};
