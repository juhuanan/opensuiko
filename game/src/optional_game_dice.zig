//! Logical session contract for the optional Dice (VB2) game.

const rules_mod = @import("optional_game_rules.zig");
const DiceRules = rules_mod.DiceRules;
const Draws = @import("battle_rules").Draws;

pub const Throw = struct {
    horizontal_pixels: i16,
    strength: u16,
    random_salt: u32,
};

pub const Roll = struct {
    /// Threshold selection uses different source report text from natural face classification.
    forced: bool = false,
    faces: [3]u8,
    score: u16,
};

pub const ThrowButtons = struct {
    // Source input is the platform's pressed-edge mask for this update.
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    confirm: bool = false,
    alternate_confirm: bool = false,
    other: bool = false,
};

pub const ThrowControl = struct {
    horizontal_pixels: i16 = 117,
    vertical_pixels: i16 = 120,
    velocity_x_tenths: i16 = 10,
    velocity_y_tenths: i16 = 10,
    acceleration_x_tenths: i16 = 5,
    moving_right: bool = true,
    passed_center: bool = false,
    startup_ticks: u8 = 20,
    dealer_ticks: u8,
    strength: u16 = 32,
    finished: bool = false,

    pub fn init(draws: *Draws) !ThrowControl {
        return .{ .dealer_ticks = @intCast((try draws.next()) % 100) };
    }

    pub fn validate(self: ThrowControl) !void {
        if (self.strength < 32 or self.strength > 96 or self.strength % 4 != 0 or self.startup_ticks > 20 or
            (self.acceleration_x_tenths != 5 and self.acceleration_x_tenths != -5) or
            (self.velocity_y_tenths != 10 and self.velocity_y_tenths != -10)) return error.InvalidThrowControl;
    }

    pub fn tick(self: *ThrowControl, side: DiceSide, input: ThrowButtons) !bool {
        try self.validate();
        if (self.finished) return error.ThrowAlreadyReleased;
        const strength_only = !input.left and !input.right and !input.confirm and !input.alternate_confirm and !input.other;
        if (strength_only and input.up and !input.down and self.strength < 96) self.strength += 4;
        if (strength_only and input.down and !input.up and self.strength > 32) self.strength -= 4;
        if (self.moving_right) {
            if (self.passed_center) {
                if (self.horizontal_pixels >= 203) self.resetSweep(false);
            } else if (self.horizontal_pixels >= 160) self.passCenter();
        } else {
            if (self.passed_center) {
                if (self.horizontal_pixels < 118) self.resetSweep(true);
            } else if (self.horizontal_pixels < 161) self.passCenter();
        }
        self.velocity_x_tenths +%= self.acceleration_x_tenths;
        self.horizontal_pixels +%= @divTrunc(self.velocity_x_tenths, 10);
        self.vertical_pixels +%= @divTrunc(self.velocity_y_tenths, 10);
        if (self.startup_ticks != 0) {
            self.startup_ticks -= 1;
        } else if (side == .dealer) {
            self.dealer_ticks -%= 1;
            self.finished = self.dealer_ticks == 0;
        } else {
            self.finished = (input.confirm != input.alternate_confirm) and !input.other;
        }
        return self.finished;
    }

    fn passCenter(self: *ThrowControl) void {
        self.passed_center = true;
        self.acceleration_x_tenths = -self.acceleration_x_tenths;
        self.velocity_y_tenths = -self.velocity_y_tenths;
    }

    fn resetSweep(self: *ThrowControl, right: bool) void {
        self.moving_right = right;
        self.passed_center = false;
        self.horizontal_pixels = if (right) 117 else 203;
        self.vertical_pixels = 120;
        self.velocity_x_tenths = if (right) 10 else -10;
        self.velocity_y_tenths = 10;
        self.acceleration_x_tenths = if (right) 5 else -5;
    }
};

pub fn scoreFaces(faces: [3]u8) !u16 {
    var mask: u8 = 0;
    for (faces) |face| {
        if (face < 1 or face > 6) return error.InvalidDieFace;
        mask |= @as(u8, 1) << @as(u3, @intCast(face - 1));
    }
    if (mask == 7) return 64;
    if (mask == 56) return 32;
    if (faces[0] == faces[1] and faces[1] == faces[2]) return if (faces[0] == 1) 16 else 8;
    if (faces[0] == faces[1]) return faces[2];
    if (faces[0] == faces[2]) return faces[1];
    if (faces[1] == faces[2]) return faces[0];
    return 0;
}

const RollDraws = struct {
    draws: Draws,
    salt: u32,
    // shortcut: bound source rejection loops; revisit only if a legitimate throw reaches this guard.
    remaining: u32 = rules_mod.host_rejection_budget,

    fn percent(self: *RollDraws) !u8 {
        if (self.remaining == 0) return error.RandomDrawBudgetExceeded;
        self.remaining -= 1;
        return @intCast((@as(u32, try self.draws.next()) +% self.salt) % 100);
    }

    fn face(self: *RollDraws) !u8 {
        var accumulator: u8 = 0;
        while (true) {
            accumulator +%= @intCast(try self.percent());
            if (accumulator < 6) return accumulator + 1;
        }
    }

    fn faces(self: *RollDraws) ![3]u8 {
        return .{ try self.face(), try self.face(), try self.face() };
    }
};

fn wrap16(value: i32) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(@as(u32, @bitCast(value))))));
}

pub fn produceRoll(input: Throw, draws: *Draws) !Roll {
    var random: RollDraws = .{ .draws = draws.*, .salt = input.random_salt };
    const x: i32 = input.horizontal_pixels;
    const distance = if (x < 160) 144 - x else x - 176;
    const strength: i32 = @as(i16, @bitCast(input.strength -% 32));
    const half_distance = @divTrunc(wrap16(distance), 2);
    const eighth_strength = @divTrunc(strength, 8);
    const quarter_strength = @divTrunc(strength, 4);
    const thresholds = [_]i32{
        wrap16(eighth_strength - half_distance + 5),
        wrap16(half_distance + 5 - eighth_strength),
        wrap16(quarter_strength - distance + 5),
        wrap16(distance + 5 - quarter_strength),
    };
    var result: ?Roll = null;
    for (thresholds, 0..) |threshold, index| {
        const chance = try random.percent();
        if (threshold <= 0 or threshold < chance) continue;
        result = switch (index) {
            0 => triple: {
                var face = try random.face();
                while (face == 1) face = try random.face();
                break :triple .{ .faces = .{ face, face, face }, .score = 8, .forced = true };
            },
            1 => .{ .faces = .{ 1, 1, 1 }, .score = 16, .forced = true },
            2 => .{ .faces = .{ 4, 5, 6 }, .score = 32, .forced = true },
            3 => .{ .faces = .{ 1, 2, 3 }, .score = 64, .forced = true },
            else => unreachable,
        };
        break;
    }
    if (result == null) {
        const chance = try random.percent();
        const outside_bowl = x < 144 or x > 176;
        const escaped = outside_bowl and wrap16(strength + distance + 5) >= chance;
        const faces = try random.faces();
        result = .{ .faces = faces, .score = if (escaped) 128 else try scoreFaces(faces) };
    }
    draws.* = random.draws;
    return result.?;
}

pub const DiceVariant = enum(u8) { ordinary = 0, fixed = 1, profit = 2 };
pub const DicePhase = enum(u8) {
    wager,
    confirm,
    fixed_prompt,
    dealer_roll,
    player_roll,
    tie_prompt,
    proposal,
    acknowledged,
    exited,
};
pub const DiceOutcome = enum(u8) { win, loss };
pub const DiceDecision = struct { outcome: DiceOutcome, multiplier: u32 };
pub const DiceConsequence = enum(u8) { none, fixed_win, profit_goal };
pub const DiceSide = enum(u8) { dealer, player };
pub const DiceCompletion = enum { settled, replay_prompt, exited, bankrupt };

pub const DiceEntry = struct {
    entry_id: u64,
    content_id: u64,
    receipt_id: u64,
    balance: u32,
    variant: DiceVariant,
    /// Required for the profit variant: the balance on first entry.
    baseline: ?u32 = null,
};

pub const DiceResult = struct {
    entry_id: u64,
    content_id: u64,
    receipt_id: u64,
    before_balance: u32,
    after_balance: u32,
    wager: u32,
    decision: DiceDecision,
    variant: DiceVariant,
    baseline: ?u32,
    consequence: DiceConsequence,
    retained: u32,
};

pub const Payout = struct {
    balance: u32,
    remaining_wager: u32,
    decision: DiceDecision,
    balance_cap: u32,
    complete: bool = false,

    pub fn init(result: DiceResult, balance_cap: u32) !Payout {
        if (result.before_balance > balance_cap or result.wager == 0 or result.wager > result.before_balance or
            result.decision.multiplier == 0 or result.decision.multiplier > 3) return error.InvalidPayout;
        var check: Payout = .{ .balance = result.before_balance, .remaining_wager = result.wager, .decision = result.decision, .balance_cap = balance_cap };
        check.tick(true);
        if (check.balance != result.after_balance) return error.InvalidPayout;
        return .{ .balance = result.before_balance, .remaining_wager = result.wager, .decision = result.decision, .balance_cap = balance_cap };
    }

    pub fn tick(self: *Payout, confirm: bool) void {
        if (self.complete) return;
        if (self.remaining_wager == 0) {
            self.complete = true;
            return;
        }
        const units = if (confirm) self.remaining_wager else 1;
        self.remaining_wager -= units;
        const amount = @as(u64, units) * self.decision.multiplier;
        self.balance = switch (self.decision.outcome) {
            .win => @intCast(@min(self.balance_cap, @as(u64, self.balance) + amount)),
            .loss => @intCast(@as(u64, self.balance) -| amount),
        };
    }
};

pub const DiceSession = struct {
    version: u8 = 1,
    rules: DiceRules,
    entry: DiceEntry,
    phase: DicePhase,
    wager: u32 = 0,
    increment_index: u1 = 0,
    dealer_score: u8 = 0,
    failures: u8 = 0,
    decision: ?DiceDecision = null,
    consequence: DiceConsequence = .none,
    retained: u32 = 0,
    throw_control: ?ThrowControl = null,
    last_roll: ?Roll = null,
    last_release: ?ThrowControl = null,

    pub fn init(rules: DiceRules, entry: DiceEntry) !DiceSession {
        if (entry.entry_id == 0 or entry.content_id == 0 or entry.receipt_id == 0) return error.InvalidEntry;
        if (entry.balance > rules.balance_cap) return error.InvalidEntry;
        const mode = rules.modes[@backingInt(entry.variant)];
        if (mode.profit_goal == null and entry.baseline != null) return error.InvalidEntry;
        if (mode.profit_goal) |_| {
            const baseline = entry.baseline orelse return error.MissingBaseline;
            if (baseline > rules.balance_cap) return error.InvalidEntry;
        }
        var session = DiceSession{
            .rules = rules,
            .entry = entry,
            .phase = if (entry.variant == .fixed) .fixed_prompt else .wager,
        };
        if (entry.variant == .fixed) {
            if (entry.balance < rules.fixedWager()) return error.InsufficientFunds;
        } else if (entry.balance < rules.minimum_balance) return error.InsufficientFunds;
        try session.validate();
        return session;
    }

    pub fn increment(self: DiceSession) u32 {
        return self.rules.increments[self.increment_index];
    }

    pub fn retainedWinnings(self: DiceSession) u32 {
        return self.retained;
    }

    pub fn validate(self: DiceSession) !void {
        if (self.last_release) |control| {
            try control.validate();
            if (!control.finished or self.last_roll == null) return error.InvalidState;
        }
        if (self.throw_control) |control| {
            try control.validate();
            if (self.side() == null or control.finished) return error.InvalidState;
        }
        if (self.last_roll) |roll| {
            if (roll.forced and roll.score != 8 and roll.score != 16 and roll.score != 32 and roll.score != 64) return error.InvalidState;
            const score = try scoreFaces(roll.faces);
            if (roll.score != 128 and roll.score != score) return error.InvalidState;
        }
        if (self.version != 1) return error.InvalidState;
        if (self.rules.step == 0 or self.wager % self.rules.step != 0) return error.InvalidState;
        if (self.wager > self.rules.wager_maximum) return error.InvalidState;
        if (self.dealer_score > self.rules.ordinary_max) return error.InvalidState;
        if (self.failures > self.rules.failure_limit) return error.InvalidState;
        switch (self.phase) {
            .wager, .confirm => {
                if (self.decision != null or self.consequence != .none) return error.InvalidState;
            },
            .fixed_prompt => {
                if (self.entry.variant != .fixed) return error.InvalidState;
                if (self.wager != 0 or self.dealer_score != 0) return error.InvalidState;
            },
            .dealer_roll => {
                if (self.wager == 0 or self.wager > self.entry.balance) return error.InvalidState;
            },
            .player_roll => {
                // The dealer may have failed three times, so a zero dealer score
                // is a legal player turn.
                if (self.wager == 0 or self.wager > self.entry.balance) return error.InvalidState;
            },
            .tie_prompt => {},
            .proposal, .acknowledged => {
                const decision = self.decision orelse return error.InvalidState;
                if (self.wager == 0 or self.wager > self.entry.balance) return error.InvalidState;
                if (decision.multiplier == 0 or decision.multiplier > 3) return error.InvalidState;
            },
            .exited => {},
        }
        if (self.entry.variant == .fixed) {
            switch (self.phase) {
                .wager, .confirm => return error.InvalidState,
                .fixed_prompt, .exited => {},
                else => {
                    if (self.wager != self.rules.fixedWager()) return error.InvalidState;
                },
            }
        }
    }

    /// Wager adjustment. Up/down step by the increment and wrap at the source
    /// boundary; larger/smaller cycle the 100/1000 increment pair.
    pub fn adjust(self: *DiceSession, input: enum { up, down, larger, smaller }) !void {
        if (self.phase != .wager) return error.InvalidPhase;
        var next = self.*;
        switch (input) {
            .up => next.wager = if (next.wager + next.increment() > self.rules.wager_maximum) 0 else next.wager + next.increment(),
            .down => next.wager = if (next.wager < next.increment()) self.rules.wager_maximum else next.wager - next.increment(),
            .larger, .smaller => next.increment_index = if (next.increment_index == 0) 1 else 0,
        }
        try next.validate();
        self.* = next;
    }

    pub fn confirmWager(self: *DiceSession) !void {
        if (self.phase != .wager) return error.InvalidPhase;
        var next = self.*;
        next.phase = .confirm;
        try next.validate();
        self.* = next;
    }

    pub fn cancel(self: *DiceSession) !void {
        var next = self.*;
        switch (self.phase) {
            .wager => next.phase = .exited,
            .confirm => {
                next.wager = 0;
                next.phase = .wager;
            },
            else => return error.CannotCancel,
        }
        try next.validate();
        self.* = next;
    }

    pub fn start(self: *DiceSession) !void {
        if (self.phase != .confirm) return error.InvalidPhase;
        if (self.wager == 0) return error.ZeroWager;
        if (self.wager > self.entry.balance) return error.InsufficientFunds;
        var next = self.*;
        next.failures = 0;
        next.dealer_score = 0;
        next.phase = .dealer_roll;
        try next.validate();
        self.* = next;
    }

    pub fn startFixed(self: *DiceSession) !void {
        if (self.entry.variant != .fixed or self.phase != .fixed_prompt) return error.InvalidPhase;
        if (self.entry.balance < self.rules.fixedWager()) return error.InsufficientFunds;
        var next = self.*;
        next.wager = self.rules.fixedWager();
        next.failures = 0;
        next.dealer_score = 0;
        next.phase = .dealer_roll;
        try next.validate();
        self.* = next;
    }

    pub fn side(self: DiceSession) ?DiceSide {
        return switch (self.phase) {
            .dealer_roll => .dealer,
            .player_roll => .player,
            else => null,
        };
    }

    pub fn throwDice(self: *DiceSession, input: Throw, draws: *Draws) !Roll {
        try self.validate();
        if (self.side() == null) return error.InvalidPhase;
        var next = self.*;
        next.last_release = null;
        var next_draws = draws.*;
        const first_draw = next_draws.cursor;
        while (true) {
            if (next_draws.cursor - first_draw >= rules_mod.host_rejection_budget) return error.RandomDrawBudgetExceeded;
            const roll = try produceRoll(input, &next_draws);
            next.submitScore(roll.score) catch |err| switch (err) {
                error.DealerMustRerollSpecial => continue,
                else => return err,
            };
            next.last_roll = roll;
            self.* = next;
            draws.* = next_draws;
            return roll;
        }
    }

    pub fn tickThrow(self: *DiceSession, input: ThrowButtons, random_salt: u32, draws: *Draws) !void {
        try self.validate();
        const active_side = self.side() orelse return error.InvalidPhase;
        var next = self.*;
        var next_draws = draws.*;
        if (next.throw_control == null) next.last_release = null;
        var control = next.throw_control orelse try ThrowControl.init(&next_draws);
        if (try control.tick(active_side, input)) {
            next.throw_control = null;
            _ = try next.throwDice(.{ .horizontal_pixels = control.horizontal_pixels, .strength = control.strength, .random_salt = random_salt }, &next_draws);
            next.last_release = control;
        } else next.throw_control = control;
        try next.validate();
        self.* = next;
        draws.* = next_draws;
    }

    /// Score arbitration. A zero score is a failed roll; three failures pass the
    /// turn. A special by the dealer in the fixed variant forces a reroll, as
    /// the source driver loops instead of arbitrating it.
    pub fn submitScore(self: *DiceSession, score: u16) !void {
        const current_side = self.side() orelse return error.InvalidPhase;
        var next = self.*;
        next.throw_control = null;
        next.last_roll = null;
        next.last_release = null;
        if (self.rules.special(score)) |special| {
            if (current_side == .dealer and self.entry.variant == .fixed) return error.DealerMustRerollSpecial;
            const player_wins = special.roller_wins == (current_side == .player);
            next.decision = .{
                .outcome = if (player_wins) .win else .loss,
                .multiplier = special.multiplier,
            };
            next.phase = .proposal;
            next.failures = 0;
            try next.validate();
            self.* = next;
            return;
        }
        if (score == 0) {
            next.failures += 1;
            if (next.failures < self.rules.failure_limit) {
                try next.validate();
                self.* = next;
                return;
            }
            next.failures = 0;
            if (current_side == .dealer) {
                next.dealer_score = 0;
                next.phase = .player_roll;
            } else if (self.dealer_score == 0 and self.rules.tie_when_opponent_zero) {
                next.phase = .tie_prompt;
            } else {
                next.decision = .{ .outcome = .loss, .multiplier = self.rules.third_multiplier };
                next.phase = .proposal;
            }
            try next.validate();
            self.* = next;
            return;
        }
        if (score < self.rules.ordinary_min or score > self.rules.ordinary_max) return error.InvalidScore;
        next.failures = 0;
        const ordinary: u8 = @intCast(score);
        if (current_side == .dealer) {
            next.dealer_score = ordinary;
            next.phase = .player_roll;
        } else if (ordinary == self.dealer_score) {
            next.phase = .tie_prompt;
        } else {
            next.decision = .{
                .outcome = if (ordinary > self.dealer_score) .win else .loss,
                .multiplier = 1,
            };
            next.phase = .proposal;
        }
        try next.validate();
        self.* = next;
    }

    pub fn replayTie(self: *DiceSession) !void {
        if (self.phase != .tie_prompt) return error.InvalidPhase;
        var next = self.*;
        next.dealer_score = 0;
        next.failures = 0;
        next.wager = 0;
        next.increment_index = 0;
        next.phase = if (self.entry.variant == .fixed) .fixed_prompt else .wager;
        try next.validate();
        self.* = next;
    }

    pub fn exitTie(self: *DiceSession) !void {
        if (self.phase != .tie_prompt) return error.InvalidPhase;
        var next = self.*;
        next.phase = .exited;
        self.* = next;
    }

    pub fn exit(self: *DiceSession) !void {
        if (self.phase == .acknowledged) return error.InvalidPhase;
        var next = self.*;
        next.phase = .exited;
        self.* = next;
    }

    /// The proposal for the settled round. Idempotent: calling it twice yields
    /// the same value and never mutates the session.
    pub fn propose(self: DiceSession) !DiceResult {
        if (self.phase != .proposal and self.phase != .acknowledged) return error.NoProposal;
        const decision = self.decision orelse return error.NoProposal;
        const amount = self.wager * decision.multiplier;
        const after: u32 = switch (decision.outcome) {
            .win => @min(self.rules.balance_cap, self.entry.balance + amount),
            .loss => self.entry.balance - @min(self.entry.balance, amount),
        };
        var consequence: DiceConsequence = .none;
        switch (self.entry.variant) {
            .ordinary => {},
            .fixed => if (decision.outcome == .win) {
                consequence = .fixed_win;
            },
            .profit => {
                const baseline = self.entry.baseline orelse return error.MissingBaseline;
                if (after >= baseline + self.rules.profitGoal()) consequence = .profit_goal;
            },
        }
        const retained: u32 = if (decision.outcome == .win)
            @min(self.rules.balance_cap, self.retained + amount)
        else
            0;
        return .{
            .entry_id = self.entry.entry_id,
            .content_id = self.entry.content_id,
            .receipt_id = self.entry.receipt_id,
            .before_balance = self.entry.balance,
            .after_balance = after,
            .wager = self.wager,
            .decision = decision,
            .variant = self.entry.variant,
            .baseline = self.entry.baseline,
            .consequence = consequence,
            .retained = retained,
        };
    }

    /// Acknowledge the canonical owner's committed balance. The receipt must be
    /// present in the caller ledger and must not already be applied. On any
    /// failure the session is unchanged and the proposal stays retryable.
    pub fn acknowledge(self: *DiceSession, balance: u32, receipts: []const u64, applied: []const u64) !DiceResult {
        if (self.phase != .proposal) return error.InvalidPhase;
        const proposal = try self.propose();
        if (balance != proposal.after_balance) return error.StaleBalance;
        try rules_mod.verifyReceipt(proposal.receipt_id, receipts, applied);
        var next = self.*;
        next.phase = .acknowledged;
        next.consequence = proposal.consequence;
        next.retained = proposal.retained;
        try next.validate();
        self.* = next;
        return proposal;
    }

    /// Begin the next round after an acknowledged result. The caller supplies a
    /// fresh receipt and the committed balance.
    pub fn beginNext(self: *DiceSession, receipt_id: u64, balance: u32) !void {
        if (self.phase != .acknowledged) return error.InvalidPhase;
        if (self.consequence != .none) return error.ConsequenceConsumesSession;
        if (balance > self.rules.balance_cap or receipt_id == 0) return error.InvalidEntry;
        var next = try DiceSession.init(self.rules, .{
            .entry_id = self.entry.entry_id,
            .content_id = self.entry.content_id,
            .receipt_id = receipt_id,
            .balance = balance,
            .variant = self.entry.variant,
            .baseline = self.entry.baseline,
        });
        next.retained = self.retained;
        try next.validate();
        self.* = next;
    }

    pub fn completionToken(self: DiceSession) ?DiceCompletion {
        return switch (self.phase) {
            .exited => .exited,
            .acknowledged => .settled,
            .proposal => blk: {
                const proposal = self.propose() catch break :blk @as(?DiceCompletion, null);
                if (proposal.after_balance == 0) break :blk .bankrupt;
                if (proposal.consequence != .none) break :blk .settled;
                if (self.entry.variant == .fixed) break :blk .settled;
                break :blk .replay_prompt;
            },
            else => null,
        };
    }

    pub fn checkpoint(self: DiceSession) DiceSession {
        return self;
    }

    pub fn restore(candidate: DiceSession, rules: DiceRules) !DiceSession {
        var session = candidate;
        session.rules = rules;
        try session.validate();
        return session;
    }
};
