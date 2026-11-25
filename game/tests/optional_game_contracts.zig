const std = @import("std");
const contracts = @import("optional_game_contracts");
const allocator = std.testing.allocator;

const Fixture = struct {
    schema: []const u8,
    dice: struct {
        balance_cap: u32,
        wager_increments: [2]u32,
        specials: [5]struct { score: u16, roller_wins: bool, multiplier: u32 },
        modes: [3]struct { id: []const u8, wager: []const u8, fixed_wager: ?u32, profit_goal: ?u32 },
    },
    coin: struct {
        stakes: [3]u32,
        difficulty: [3]struct { base: u8, range: u8 },
        profit: struct { threshold: i32, flag_mask: u32, flag_value: u32, result_bit: u8 },
        shuffle_steps: u8,
    },
    karuta: struct {
        rounds: [4]struct { index: u8, identities: u8, record_moves: u32 },
        quit_round: u8,
        board: struct { rows: u8, columns: u8, cells: u8, pairs: u8, faces: u8, empty_face: u8, back_face: u8 },
        cell_state_codes: [11]u8,
        cell_state_ids: [11][]const u8,
        index_examples: [4]struct { index: u8, row: u8, column: u8 },
        pair_faces: u8,
        moves_cap: u32,
    },
};

fn readAsset() ![]u8 {
    const paths = [_][]const u8{
        "game/assets/optional_game_contracts.json",
        "assets/optional_game_contracts.json",
        "../assets/optional_game_contracts.json",
    };
    for (paths) |path| {
        return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1 << 20)) catch continue;
    }
    return error.AssetNotFound;
}

fn loadContracts() !contracts.Contracts {
    const bytes = try readAsset();
    defer allocator.free(bytes);
    return contracts.Contracts.parse(allocator, bytes);
}

fn fixture() !std.json.Parsed(Fixture) {
    return std.json.parseFromSlice(Fixture, allocator, @embedFile("fixtures/optional_game_contracts.json"), .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

fn coinStream() [60]u15 {
    var values: [60]u15 = undefined;
    for (0..20) |i| {
        values[i * 3] = 0;
        values[i * 3 + 1] = 10922;
        values[i * 3 + 2] = 32767;
    }
    return values;
}

fn diceEntry(balance: u32, variant: contracts.DiceVariant, baseline: ?u32) contracts.DiceEntry {
    return .{ .entry_id = 1, .content_id = 2, .receipt_id = 7, .balance = balance, .variant = variant, .baseline = baseline };
}

fn wagerTo(session: *contracts.DiceSession, target: u32) !void {
    while (session.wager != target) try session.adjust(.up);
}

fn coinEntry(balance: u32, difficulty: u8, net: i32, flags: u32) contracts.CoinEntry {
    return .{ .entry_id = 11, .content_id = 12, .receipt_id = 21, .balance = balance, .net = net, .difficulty = difficulty, .flags = flags };
}

fn karutaEntry(round: u8, flags: u32, best: [4]u32) contracts.KarutaEntry {
    return .{ .entry_id = 31, .content_id = 32, .receipt_id = 41, .round = round, .balance = 5000, .best = best, .flags = flags };
}

fn dealStream(identities: [5]u16) [101]u15 {
    var values: [101]u15 = undefined;
    for (0..5) |i| values[i] = @intCast(identities[i] * 300);
    for (0..48) |k| {
        const row: u16 = @intCast(k / 6);
        const column: u16 = @intCast(k % 6);
        values[5 + k * 2] = @intCast(row * 3640);
        values[5 + k * 2 + 1] = @intCast(column * 4681);
    }
    return values;
}

fn settle(session: *contracts.KarutaSession) !void {
    var guard: usize = 0;
    while (!session.boardStable()) : (guard += 1) {
        if (guard > 4000) return error.Stuck;
        try session.advance();
    }
}

fn moveTo(session: *contracts.KarutaSession, row: u8, column: u8) !void {
    const dr: i8 = @as(i8, @intCast(row)) - @as(i8, @intCast(session.cursor_row));
    const dc: i8 = @as(i8, @intCast(column)) - @as(i8, @intCast(session.cursor_column));
    if (dr != 0) try session.moveCursor(dr, 0);
    if (dc != 0) try session.moveCursor(0, dc);
}

fn playBoard(session: *contracts.KarutaSession) !void {
    while (session.phase == .play) {
        try settle(session);
        if (session.phase != .play) break;
        var first: ?usize = null;
        var second: ?usize = null;
        outer: for (session.cells, 0..) |cell, i| {
            if (cell.state != .face_down) continue;
            for (session.cells[i + 1 ..], i + 1..) |other, j| {
                if (other.state == .face_down and other.face == cell.face) {
                    first = i;
                    second = j;
                    break :outer;
                }
            }
        }
        const a = first orelse return error.NoPair;
        const b = second orelse return error.NoPair;
        try moveTo(session, @intCast(a / 6), @intCast(a % 6));
        try session.confirm();
        try settle(session);
        if (session.phase != .play) break;
        try moveTo(session, @intCast(b / 6), @intCast(b % 6));
        try session.confirm();
        try settle(session);
    }
}

test "asset identity, schema and fixture agreement" {
    const rules = try loadContracts();
    const fix = try fixture();
    defer fix.deinit();
    try std.testing.expectEqualStrings("suikoden.optional-games.fixture.v1", fix.value.schema);
    try std.testing.expectEqual(rules.dice.balance_cap, fix.value.dice.balance_cap);
    try std.testing.expectEqual(rules.dice.increments, fix.value.dice.wager_increments);
    for (rules.dice.specials, fix.value.dice.specials) |actual, expected| {
        try std.testing.expectEqual(expected.score, actual.score);
        try std.testing.expectEqual(expected.roller_wins, actual.roller_wins);
        try std.testing.expectEqual(expected.multiplier, actual.multiplier);
    }
    try std.testing.expectEqualStrings("ordinary", fix.value.dice.modes[0].id);
    try std.testing.expectEqualStrings("fixed", fix.value.dice.modes[1].id);
    try std.testing.expectEqualStrings("profit", fix.value.dice.modes[2].id);
    try std.testing.expectEqual(rules.dice.fixedWager(), fix.value.dice.modes[1].fixed_wager.?);
    try std.testing.expectEqual(rules.dice.profitGoal(), fix.value.dice.modes[2].profit_goal.?);
    try std.testing.expectEqual(rules.coin.stakes, fix.value.coin.stakes);
    for (0..3) |i| {
        try std.testing.expectEqual(rules.coin.bases[i], fix.value.coin.difficulty[i].base);
        try std.testing.expectEqual(rules.coin.ranges[i], fix.value.coin.difficulty[i].range);
    }
    try std.testing.expectEqual(rules.coin.profit_threshold, fix.value.coin.profit.threshold);
    try std.testing.expectEqual(rules.coin.shuffle_steps, fix.value.coin.shuffle_steps);
    try std.testing.expectEqual(rules.karuta.quit_round, fix.value.karuta.quit_round);
    for (0..4) |i| {
        try std.testing.expectEqual(rules.karuta.rounds[i].identities, fix.value.karuta.rounds[i].identities);
        try std.testing.expectEqual(rules.karuta.rounds[i].record_moves, fix.value.karuta.rounds[i].record_moves);
    }
    try std.testing.expectEqual(rules.karuta.cells, fix.value.karuta.board.cells);
    try std.testing.expectEqual(rules.karuta.pairs, fix.value.karuta.board.pairs);
    for (0..11) |i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), fix.value.karuta.cell_state_codes[i]);
    }
    try std.testing.expectEqualStrings("face_up", fix.value.karuta.cell_state_ids[0]);
    try std.testing.expectEqualStrings("empty", fix.value.karuta.cell_state_ids[10]);
    for (fix.value.karuta.index_examples) |example| {
        const row = example.index % 8;
        const column = example.index / 8;
        try std.testing.expectEqual(example.row, row);
        try std.testing.expectEqual(example.column, column);
        try std.testing.expectEqual(example.index, contracts.KarutaSession.linearIndex(row, column));
    }
    try std.testing.expectEqual(rules.karuta.moves_cap, fix.value.karuta.moves_cap);
}

test "rejecting a tampered asset" {
    const bytes = try readAsset();
    defer allocator.free(bytes);
    const tampered = try allocator.dupe(u8, bytes);
    defer allocator.free(tampered);
    tampered[0] = 'X';
    try std.testing.expectError(error.AssetIdentityMismatch, contracts.Contracts.parse(allocator, tampered));
    try std.testing.expectError(error.AssetIdentityMismatch, contracts.Contracts.parse(allocator, "{}"));
}

test "dice ordinary loop: wager, win, acknowledgement, caps and ties" {
    const rules = try loadContracts();
    var session = try contracts.DiceSession.init(rules.dice, diceEntry(1000, .ordinary, null));
    try std.testing.expectEqual(contracts.DicePhase.wager, session.phase);

    // A failed step leaves the session unchanged.
    const before = session;
    try std.testing.expectError(error.ZeroWager, (blk: {
        var copy = session;
        copy.phase = .confirm;
        break :blk copy.start();
    }));
    try std.testing.expectEqual(before, session);

    try session.adjust(.up);
    try std.testing.expectEqual(@as(u32, 100), session.wager);
    try session.adjust(.down);
    try std.testing.expectEqual(@as(u32, 0), session.wager); // a step to zero is legal
    try session.adjust(.down);
    try std.testing.expectEqual(@as(u32, 9900), session.wager); // below zero wraps to the maximum
    try session.adjust(.up); // past the maximum wraps to zero
    try std.testing.expectEqual(@as(u32, 0), session.wager);
    try session.adjust(.up);
    try session.adjust(.larger);
    try std.testing.expectEqual(@as(u32, 1000), session.increment());
    try session.adjust(.smaller);
    try std.testing.expectEqual(@as(u32, 100), session.increment());

    try wagerTo(&session, 100);
    try session.confirmWager();
    try session.start();
    try session.submitScore(3); // dealer
    try session.submitScore(5); // player
    try std.testing.expectEqual(contracts.DicePhase.proposal, session.phase);
    const proposal = try session.propose();
    try std.testing.expectEqual(contracts.DiceOutcome.win, proposal.decision.outcome);
    try std.testing.expectEqual(@as(u32, 1100), proposal.after_balance);
    try std.testing.expectEqual(@as(u32, 100), proposal.retained);
    var payout = try contracts.DicePayout.init(proposal, rules.dice.balance_cap);
    payout.tick(false);
    try std.testing.expectEqual(@as(u32, 1001), payout.balance);
    try std.testing.expectEqual(@as(u32, 99), payout.remaining_wager);
    payout.tick(true);
    try std.testing.expectEqual(proposal.after_balance, payout.balance);
    try std.testing.expect(!payout.complete);
    payout.tick(false);
    try std.testing.expect(payout.complete);

    // Stale balance and duplicate receipts are refused without changing state.
    try std.testing.expectError(error.StaleBalance, session.acknowledge(1099, &.{7}, &.{}));
    try std.testing.expectError(error.MissingReceipt, session.acknowledge(1100, &.{}, &.{}));
    try std.testing.expectError(error.ReceiptAlreadyUsed, session.acknowledge(1100, &.{7}, &.{7}));
    try std.testing.expectEqual(contracts.DicePhase.proposal, session.phase);
    const accepted = try session.acknowledge(1100, &.{7}, &.{});
    try std.testing.expectEqual(proposal.after_balance, accepted.after_balance);
    try std.testing.expectEqual(contracts.DiceCompletion.settled, session.completionToken().?);
    try session.beginNext(8, 1100);
    try std.testing.expectEqual(contracts.DicePhase.wager, session.phase);

    // Cap at 999999.
    var rich = try contracts.DiceSession.init(rules.dice, diceEntry(999999, .ordinary, null));
    while (rich.wager != 9900) try rich.adjust(.up);
    try rich.confirmWager();
    try rich.start();
    try rich.submitScore(1);
    try rich.submitScore(6);
    try std.testing.expectEqual(@as(u32, 999999), (try rich.propose()).after_balance);

    // Tie then replay, tie then exit.
    var tie = try contracts.DiceSession.init(rules.dice, diceEntry(500, .ordinary, null));
    try tie.adjust(.up);
    try tie.confirmWager();
    try tie.start();
    try tie.submitScore(4);
    try tie.submitScore(4);
    try std.testing.expectEqual(contracts.DicePhase.tie_prompt, tie.phase);
    try tie.replayTie();
    try std.testing.expectEqual(contracts.DicePhase.wager, tie.phase);
    try tie.adjust(.up);
    try tie.confirmWager();
    try tie.start();
    try tie.submitScore(4);
    try tie.submitScore(4);
    try tie.exitTie();
    try std.testing.expectEqual(contracts.DiceCompletion.exited, tie.completionToken().?);
}

test "dice third failed roll and zero-score turn pass" {
    const rules = try loadContracts();
    var session = try contracts.DiceSession.init(rules.dice, diceEntry(500, .ordinary, null));
    try session.adjust(.up);
    try session.confirmWager();
    try session.start();
    try session.submitScore(0);
    try session.submitScore(0);
    try std.testing.expectEqual(contracts.DicePhase.dealer_roll, session.phase);
    try std.testing.expectEqual(@as(u8, 2), session.failures);
    try session.submitScore(0); // third failure passes the turn
    try std.testing.expectEqual(contracts.DicePhase.player_roll, session.phase);
    try std.testing.expectEqual(@as(u8, 0), session.failures);
    try session.submitScore(0);
    try session.submitScore(0);
    try session.submitScore(0); // third player failure with dealer zero ties
    try std.testing.expectEqual(contracts.DicePhase.tie_prompt, session.phase);

    var losing = try contracts.DiceSession.init(rules.dice, diceEntry(500, .ordinary, null));
    try losing.adjust(.up);
    try losing.confirmWager();
    try losing.start();
    try losing.submitScore(5);
    try losing.submitScore(0);
    try losing.submitScore(0);
    try losing.submitScore(0);
    try std.testing.expectEqual(contracts.DicePhase.proposal, losing.phase);
    const proposal = try losing.propose();
    try std.testing.expectEqual(contracts.DiceOutcome.loss, proposal.decision.outcome);
    try std.testing.expectEqual(@as(u32, 1), proposal.decision.multiplier);
    try std.testing.expectEqual(@as(u32, 400), proposal.after_balance);
}

test "dice specials, fixed and profit variants" {
    const rules = try loadContracts();
    const Case = struct { score: u16, player_wins: bool, multiplier: u32 };
    const cases = [_]Case{
        .{ .score = 8, .player_wins = true, .multiplier = 3 },
        .{ .score = 16, .player_wins = false, .multiplier = 3 },
        .{ .score = 32, .player_wins = true, .multiplier = 2 },
        .{ .score = 64, .player_wins = false, .multiplier = 2 },
        .{ .score = 128, .player_wins = false, .multiplier = 1 },
    };
    for (cases) |case| {
        var session = try contracts.DiceSession.init(rules.dice, diceEntry(10000, .ordinary, null));
        try session.adjust(.up);
        try session.confirmWager();
        try session.start();
        try session.submitScore(2);
        try session.submitScore(case.score);
        const proposal = try session.propose();
        try std.testing.expectEqual(case.player_wins, proposal.decision.outcome == .win);
        try std.testing.expectEqual(case.multiplier, proposal.decision.multiplier);
        // A special rolled by the dealer inverts the same table.
        var dealer = try contracts.DiceSession.init(rules.dice, diceEntry(10000, .ordinary, null));
        try dealer.adjust(.up);
        try dealer.confirmWager();
        try dealer.start();
        try dealer.submitScore(case.score);
        const other = try dealer.propose();
        try std.testing.expectEqual(!case.player_wins, other.decision.outcome == .win);
        try std.testing.expectEqual(case.multiplier, other.decision.multiplier);
    }

    var fixed = try contracts.DiceSession.init(rules.dice, diceEntry(1000, .fixed, null));
    try std.testing.expectEqual(contracts.DicePhase.fixed_prompt, fixed.phase);
    try std.testing.expectError(error.InvalidPhase, fixed.adjust(.up));
    try fixed.startFixed();
    try std.testing.expectEqual(rules.dice.fixedWager(), fixed.wager);
    try std.testing.expectError(error.DealerMustRerollSpecial, fixed.submitScore(8));
    try fixed.submitScore(2);
    try fixed.submitScore(8);
    const fixed_proposal = try fixed.propose();
    try std.testing.expectEqual(contracts.DiceConsequence.fixed_win, fixed_proposal.consequence);
    _ = try fixed.acknowledge(fixed_proposal.after_balance, &.{7}, &.{});
    try std.testing.expectError(error.ConsequenceConsumesSession, fixed.beginNext(8, fixed_proposal.after_balance));

    // The goal is exactly 5000 over the entry baseline.
    var profit = try contracts.DiceSession.init(rules.dice, diceEntry(5000, .profit, 1000));
    try wagerTo(&profit, 1000);
    try profit.confirmWager();
    try profit.start();
    try profit.submitScore(2);
    try profit.submitScore(6); // 5000 + 1000 = 6000 = baseline + 5000
    const goal = try profit.propose();
    try std.testing.expectEqual(contracts.DiceConsequence.profit_goal, goal.consequence);
    try std.testing.expectEqual(@as(u32, 6000), goal.after_balance);

    // One bit less profit is not the goal.
    var near = try contracts.DiceSession.init(rules.dice, diceEntry(4999, .profit, 1000));
    try wagerTo(&near, 1000);
    try near.confirmWager();
    try near.start();
    try near.submitScore(2);
    try near.submitScore(6);
    try std.testing.expectEqual(@as(u32, 5999), (try near.propose()).after_balance);
    try std.testing.expectEqual(contracts.DiceConsequence.none, (try near.propose()).consequence);

    try std.testing.expectError(error.MissingBaseline, contracts.DiceSession.init(rules.dice, diceEntry(1000, .profit, null)));
    try std.testing.expectError(error.InsufficientFunds, contracts.DiceSession.init(rules.dice, diceEntry(99, .ordinary, null)));
}

test "coin loop: admission, gated shuffle, choice, payout, acknowledgement" {
    const rules = try loadContracts();
    const values = [_]u15{ 0, 10922, 32767, 0, 10922, 32767, 0, 10922, 32767, 0, 10922, 32767, 0, 10922, 32767, 0, 10922, 32767, 0, 10922, 32767, 0, 10922, 32767, 0, 10922, 32767, 0, 10922, 32767, 0, 10922, 32767, 0, 10922, 32767, 0, 10922, 32767, 0, 10922, 32767, 0, 10922, 32767, 0, 10922, 32767, 0, 10922, 32767, 0, 10922, 32767, 0, 10922, 32767, 0, 10922, 32767 };
    var session = try contracts.CoinSession.init(rules.coin, coinEntry(1000, 0, 0, rules.coin.flag_value));
    try session.select(1);
    try session.select(-1);
    try std.testing.expectEqual(@as(u8, 0), session.difficulty);
    try session.admit();
    try std.testing.expectEqual(@as(u32, 900), session.balance);
    try std.testing.expectEqual(@as(i32, -100), session.net);
    try std.testing.expectEqual(rules.coin.shuffle_steps, session.shuffle_remaining);
    try std.testing.expectEqual(@as(u8, 1), session.coin_position);

    // A paused animation consumes no draw and changes nothing.
    var draws = contracts.Draws{ .values = &values };
    const paused = session;
    const paused_draws = draws;
    try std.testing.expectError(error.PresentationNotReady, session.shuffleStep(false, &draws));
    try std.testing.expectEqual(paused, session);
    try std.testing.expectEqual(paused_draws.cursor, draws.cursor);

    var i: u8 = 0;
    while (i < rules.coin.shuffle_steps) : (i += 1) try session.shuffleStep(true, &draws);
    try std.testing.expectEqual(contracts.CoinPhase.choice, session.phase);
    try std.testing.expect(session.coin_position < 3);
    // Move the cup to the tracked coin and commit; the reveal gate must elapse.
    while (session.cup != session.coin_position) try session.moveChoice(1);
    try session.commitChoice();
    var waited: u16 = 0;
    while (waited < rules.coin.reveal_ticks) : (waited += 1) {
        try std.testing.expect(!try session.advanceReveal());
    }
    try std.testing.expect(try session.advanceReveal());
    const proposal = try session.propose();
    try std.testing.expect(proposal.win);
    try std.testing.expectEqual(@as(u32, 1100), proposal.after_balance);
    try std.testing.expectEqual(@as(i32, 100), proposal.after_net);
    try std.testing.expect(!proposal.profit_flag);
    try std.testing.expectError(error.StaleBalance, session.acknowledge(1099, 100, &.{21}, &.{}));
    _ = try session.acknowledge(1100, 100, &.{21}, &.{});
    try std.testing.expectEqual(contracts.CoinCompletion.round_continues, session.completionToken().?);
    try session.continueRound(22, 1100, 100);
    try std.testing.expectEqual(contracts.CoinPhase.select, session.phase);

    // Insufficient funds and the quit entry.
    var poor = try contracts.CoinSession.init(rules.coin, coinEntry(9999, 2, 0, 0));
    try std.testing.expectError(error.InsufficientFunds, poor.admit());
    try std.testing.expectEqual(contracts.CoinPhase.select, poor.phase);
    try poor.select(1); // difficulty 3 is the quit entry
    try poor.admit();
    try std.testing.expectEqual(contracts.CoinCompletion.exited, poor.completionToken().?);
}

test "coin profit flag, cap, flag mask and rejection budget" {
    const rules = try loadContracts();
    var session = try contracts.CoinSession.init(rules.coin, coinEntry(20000, 2, 4900, rules.coin.flag_value));
    try session.admit();
    try std.testing.expectEqual(@as(u32, 10000), session.balance);
    try std.testing.expectEqual(@as(i32, -5100), session.net);
    var stream = coinStream();
    var draws = contracts.Draws{ .values = &stream };
    var i: u8 = 0;
    while (i < rules.coin.shuffle_steps) : (i += 1) try session.shuffleStep(true, &draws);
    while (session.cup != session.coin_position) try session.moveChoice(1);
    try session.commitChoice();
    var waited: u16 = 0;
    while (waited < rules.coin.reveal_ticks) : (waited += 1) _ = try session.advanceReveal();
    _ = try session.advanceReveal();
    const proposal = try session.propose();
    try std.testing.expect(proposal.profit_flag);
    try std.testing.expectEqual(contracts.CoinConsequence.profit_flag, proposal.consequence);
    _ = try session.acknowledge(proposal.after_balance, proposal.after_net, &.{21}, &.{});
    try std.testing.expectEqual(contracts.CoinCompletion.profit_flag, session.completionToken().?);
    try std.testing.expectError(error.ConsequenceConsumesSession, session.continueRound(22, proposal.after_balance, proposal.after_net));

    // Without the matching flag mask the same net does not set the flag.
    var no_flag = try contracts.CoinSession.init(rules.coin, coinEntry(20000, 2, 4900, 0));
    try no_flag.admit();
    var draws2 = contracts.Draws{ .values = &stream };
    i = 0;
    while (i < rules.coin.shuffle_steps) : (i += 1) try no_flag.shuffleStep(true, &draws2);
    while (no_flag.cup != no_flag.coin_position) try no_flag.moveChoice(1);
    try no_flag.commitChoice();
    waited = 0;
    while (waited < rules.coin.reveal_ticks) : (waited += 1) _ = try no_flag.advanceReveal();
    _ = try no_flag.advanceReveal();
    try std.testing.expect(!(try no_flag.propose()).profit_flag);

    // Balance cap: a win from the cap cannot exceed 999999.
    var capped = try contracts.CoinSession.init(rules.coin, coinEntry(999999, 2, 0, 0));
    try capped.admit();
    var draws3 = contracts.Draws{ .values = &stream };
    i = 0;
    while (i < rules.coin.shuffle_steps) : (i += 1) try capped.shuffleStep(true, &draws3);
    while (capped.cup != capped.coin_position) try capped.moveChoice(1);
    try capped.commitChoice();
    waited = 0;
    while (waited < rules.coin.reveal_ticks) : (waited += 1) _ = try capped.advanceReveal();
    _ = try capped.advanceReveal();
    try std.testing.expectEqual(@as(u32, 999999), (try capped.propose()).after_balance);

    // A stream of equal positions exhausts the documented host rejection budget.
    const zeros = try allocator.alloc(u15, 2 * (contracts.host_rejection_budget + 1));
    defer allocator.free(zeros);
    @memset(zeros, 0);
    var stuck = try contracts.CoinSession.init(rules.coin, coinEntry(1000, 0, 0, 0));
    try stuck.admit();
    var stuck_draws = contracts.Draws{ .values = zeros };
    try std.testing.expectError(error.RejectionBudget, stuck.shuffleStep(true, &stuck_draws));
    try std.testing.expectEqual(rules.coin.shuffle_steps, stuck.shuffle_remaining);
}

test "karuta deal: identity counts, pair placement, linear index and rejection" {
    const rules = try loadContracts();
    var eligible: [contracts.face_count]bool = @splat(true);
    var stream = dealStream(.{ 0, 1, 2, 3, 4 });
    var draws = contracts.Draws{ .values = &stream };
    var session = try contracts.KarutaSession.init(rules.karuta, karutaEntry(0, 0, .{ 900, 1500, 2400, 3300 }));
    try session.deal(&eligible, &draws);
    try std.testing.expectEqual(contracts.KarutaPhase.dealing, session.phase);
    try std.testing.expectEqual(@as(u8, 0), session.deal_cursor);
    try std.testing.expectEqual(@as(u8, 101), draws.cursor);
    // Every identity appears twice per pair, so all 48 cells hold a face.
    var counts: [contracts.face_count]u8 = @splat(0);
    for (session.cells) |cell| {
        try std.testing.expect(cell.face != rules.karuta.empty_face);
        counts[cell.face] += 1;
    }
    try std.testing.expectEqual(@as(u8, 10), counts[0]);
    try std.testing.expectEqual(@as(u8, 8), counts[4]);
    // The board order is column-major: index 7 is the last row of column 0.
    try std.testing.expectEqual(@as(u8, 0), contracts.KarutaSession.linearIndex(0, 0));
    try std.testing.expectEqual(@as(u8, 7), contracts.KarutaSession.linearIndex(7, 0));
    try std.testing.expectEqual(@as(u8, 8), contracts.KarutaSession.linearIndex(0, 1));
    try std.testing.expectEqual(@as(u8, 47), contracts.KarutaSession.linearIndex(7, 5));

    // The deal animation is the entry gate: no play until all cards landed.
    var frame: usize = 0;
    while (session.phase == .dealing) : (frame += 1) {
        if (frame > 200) return error.Stuck;
        try session.advance();
    }
    try std.testing.expectEqual(contracts.KarutaPhase.play, session.phase);
    try std.testing.expectEqual(@as(u8, 48), session.deal_cursor);
    for (session.cells) |cell| try std.testing.expectEqual(contracts.KarutaCellState.face_down, cell.state);
    try std.testing.expectEqual(@as(u8, 3), session.cursor_row);
    try std.testing.expectEqual(@as(u8, 2), session.cursor_column);

    // A face table with fewer identities than the round needs is refused.
    var sparse: [contracts.face_count]bool = @splat(false);
    sparse[0] = true;
    var sparse_stream = dealStream(.{ 0, 0, 0, 0, 0 });
    var sparse_draws = contracts.Draws{ .values = &sparse_stream };
    var sparse_session = try contracts.KarutaSession.init(rules.karuta, karutaEntry(0, 0, .{ 900, 1500, 2400, 3300 }));
    try std.testing.expectError(error.InsufficientEligibleFaces, sparse_session.deal(&sparse, &sparse_draws));

    // Duplicate identity draws are rejected, matching the source retry.
    var duplicate_stream: [8]u15 = .{ 0, 0, 300, 300, 600, 600, 900, 900 };
    var duplicate_draws = contracts.Draws{ .values = &duplicate_stream };
    var duplicate_session = try contracts.KarutaSession.init(rules.karuta, karutaEntry(0, 0, .{ 900, 1500, 2400, 3300 }));
    try std.testing.expectError(error.RandomInputExhausted, duplicate_session.deal(&eligible, &duplicate_draws));

    // The quit round does not deal.
    var quit_session = try contracts.KarutaSession.init(rules.karuta, karutaEntry(rules.karuta.quit_round, 0, .{ 900, 1500, 2400, 3300 }));
    var quit_draws = contracts.Draws{ .values = &stream };
    try quit_session.confirmRound(&eligible, &quit_draws);
    try std.testing.expectEqual(contracts.KarutaCompletion.exited, quit_session.completionToken().?);
}

test "karuta full headless loop: record, acknowledgement and stale receipts" {
    const rules = try loadContracts();
    var stream = dealStream(.{ 0, 1, 2, 3, 4 });
    var draws = contracts.Draws{ .values = &stream };
    var session = try contracts.KarutaSession.init(rules.karuta, karutaEntry(0, 0, .{ 900, 1500, 2400, 3300 }));
    var eligible: [contracts.face_count]bool = @splat(true);
    try session.deal(&eligible, &draws);
    var frame: usize = 0;
    while (session.phase == .dealing) : (frame += 1) {
        if (frame > 200) return error.Stuck;
        try session.advance();
    }
    try playBoard(&session);
    try std.testing.expectEqual(contracts.KarutaPhase.proposal, session.phase);
    try std.testing.expect(session.boardComplete());
    try std.testing.expect(session.boardStable());
    const proposal = try session.propose();
    try std.testing.expectEqual(@as(u32, 900), proposal.best_before);
    try std.testing.expectEqual(proposal.elapsed < 900, proposal.record);
    try std.testing.expectEqual(proposal.elapsed, proposal.best_after);
    try std.testing.expectEqual(
        if (proposal.record) contracts.KarutaCompletion.record else contracts.KarutaCompletion.round_complete,
        session.completionToken().?,
    );
    try std.testing.expectEqual(proposal.elapsed, session.elapsed);

    try std.testing.expectError(error.StaleRecord, session.acknowledge(session.balance, proposal.elapsed + 1, &.{41}, &.{}));
    try std.testing.expectError(error.ReceiptAlreadyUsed, session.acknowledge(session.balance, proposal.elapsed, &.{41}, &.{41}));
    try std.testing.expectError(error.StaleBalance, session.acknowledge(session.balance + 1, proposal.elapsed, &.{41}, &.{}));
    try std.testing.expectEqual(contracts.KarutaPhase.proposal, session.phase);
    const accepted = try session.acknowledge(session.balance, proposal.elapsed, &.{41}, &.{});
    try std.testing.expectEqual(proposal.elapsed, accepted.best_after);
    try std.testing.expectEqual(contracts.KarutaCompletion.round_complete, session.completionToken().?);
    var best = session.best;
    best[0] = accepted.best_after;
    try session.continueRound(42, session.balance, best);
    try std.testing.expectEqual(contracts.KarutaPhase.select, session.phase);
    try std.testing.expectEqual(contracts.KarutaCompletion.round_selected, session.completionToken().?);
}

test "karuta adjacency reveal auto-matches a partner and paused animation is a gate" {
    const rules = try loadContracts();
    var session = try contracts.KarutaSession.init(rules.karuta, karutaEntry(0, 0, .{ 900, 1500, 2400, 3300 }));
    // Synthetic stable board: a matching pair at (3,2)/(3,3) and two marked
    // neighbours with the same face at (3,4)/(4,3).
    session.phase = .play;
    session.deal_cursor = 48;
    session.balance = 5000;
    for (&session.cells) |*cell| cell.* = .{ .face = 40, .state = .face_down };
    session.cells[contracts.KarutaSession.storage(3, 2)] = .{ .face = 0, .state = .face_down };
    session.cells[contracts.KarutaSession.storage(3, 3)] = .{ .face = 0, .state = .face_down };
    session.cells[contracts.KarutaSession.storage(3, 4)] = .{ .face = 1, .state = .face_down };
    session.cells[contracts.KarutaSession.storage(4, 3)] = .{ .face = 1, .state = .face_down };
    try session.validate();

    try moveTo(&session, 3, 2);
    try session.confirm();
    try std.testing.expectError(error.PresentationBusy, session.moveCursor(0, 1));
    try std.testing.expectError(error.PresentationBusy, session.confirm());
    const busy = session;
    try std.testing.expectError(error.PresentationBusy, session.moveCursor(0, 1));
    try std.testing.expectEqual(busy, session);
    try settle(&session);
    try moveTo(&session, 3, 3);
    try session.confirm();
    try settle(&session);
    // The pair is removed and both neighbours were marked and resolved.
    try std.testing.expectEqual(contracts.KarutaCellState.empty, session.cells[contracts.KarutaSession.storage(3, 2)].state);
    try std.testing.expectEqual(contracts.KarutaCellState.empty, session.cells[contracts.KarutaSession.storage(3, 3)].state);
    try std.testing.expectEqual(contracts.KarutaCellState.empty, session.cells[contracts.KarutaSession.storage(3, 4)].state);
    try std.testing.expectEqual(contracts.KarutaCellState.empty, session.cells[contracts.KarutaSession.storage(4, 3)].state);
    try std.testing.expect(!session.boardComplete()); // the rest of the board is still there
}

test "karuta mismatch turns both cards back and keeps the board playable" {
    const rules = try loadContracts();
    var session = try contracts.KarutaSession.init(rules.karuta, karutaEntry(0, 0, .{ 900, 1500, 2400, 3300 }));
    session.phase = .play;
    session.deal_cursor = 48;
    for (&session.cells) |*cell| cell.* = .{ .face = 40, .state = .face_down };
    session.cells[contracts.KarutaSession.storage(0, 0)] = .{ .face = 3, .state = .face_down };
    session.cells[contracts.KarutaSession.storage(0, 1)] = .{ .face = 4, .state = .face_down };
    try session.validate();
    try moveTo(&session, 0, 0);
    try session.confirm();
    try settle(&session);
    try std.testing.expectEqual(contracts.KarutaCellState.face_up, session.cells[0].state);
    try moveTo(&session, 0, 1);
    try session.confirm();
    try settle(&session);
    try std.testing.expectEqual(contracts.KarutaCellState.face_down, session.cells[0].state);
    try std.testing.expectEqual(contracts.KarutaCellState.face_down, session.cells[1].state);
    try std.testing.expect(session.boardStable());
    // Pressing the same card again cancels the selection (source toggle).
    try moveTo(&session, 0, 0);
    try session.confirm();
    try settle(&session);
    try std.testing.expectEqual(contracts.KarutaCellState.face_up, session.cells[0].state);
    try session.confirm();
    try settle(&session);
    try std.testing.expectEqual(contracts.KarutaCellState.face_down, session.cells[0].state);
    try std.testing.expectEqual(@as(?u8, null), session.first);
}

test "karuta flag proposal and snapshot restart mid-deal and mid-play" {
    const rules = try loadContracts();
    var eligible: [contracts.face_count]bool = @splat(true);
    var stream = dealStream(.{ 0, 1, 2, 3, 4 });
    var draws = contracts.Draws{ .values = &stream };
    var session = try contracts.KarutaSession.init(rules.karuta, karutaEntry(0, rules.karuta.flag_value, .{ 900, 1500, 2400, 3300 }));
    try session.deal(&eligible, &draws);
    try session.advance();
    try session.advance();
    const mid_deal = session.checkpoint();
    var restored = try contracts.KarutaSession.restore(mid_deal, rules.karuta);
    try std.testing.expectEqual(session, restored);
    try session.advance();
    try restored.advance();
    try std.testing.expectEqual(session, restored);

    var frame: usize = 0;
    while (session.phase == .dealing) : (frame += 1) {
        if (frame > 200) return error.Stuck;
        try session.advance();
    }
    try playBoard(&session);
    const proposal = try session.propose();
    try std.testing.expect(proposal.flag_set);
    try std.testing.expectEqual(contracts.KarutaConsequence.story_flag, proposal.consequence);
    try std.testing.expectEqual(contracts.KarutaCompletion.flag, session.completionToken().?);
    _ = try session.acknowledge(session.balance, proposal.elapsed, &.{41}, &.{});
    try std.testing.expectEqual(contracts.KarutaCompletion.flag, session.completionToken().?);
    var best = session.best;
    best[0] = proposal.elapsed;
    try std.testing.expectError(error.ConsequenceConsumesSession, session.continueRound(42, session.balance, best));
}

test "coin snapshot restart reproduces the same future" {
    const rules = try loadContracts();
    var stream = coinStream();
    var session = try contracts.CoinSession.init(rules.coin, coinEntry(1000, 0, 0, 0));
    try session.admit();
    var draws = contracts.Draws{ .values = &stream };
    try session.shuffleStep(true, &draws);
    try session.shuffleStep(true, &draws);
    const snapshot = session.checkpoint();
    const draw_snapshot = draws;
    var restored = try contracts.CoinSession.restore(snapshot, rules.coin);
    var restored_draws = draw_snapshot;
    var forward = session;
    var forward_draws = draws;
    var i: usize = 0;
    while (i < 18) : (i += 1) {
        try forward.shuffleStep(true, &forward_draws);
        try restored.shuffleStep(true, &restored_draws);
    }
    try std.testing.expectEqual(forward, restored);
    try std.testing.expectEqual(forward_draws.cursor, restored_draws.cursor);
}

test "dice snapshot restart and invalid score preservation" {
    const rules = try loadContracts();
    var session = try contracts.DiceSession.init(rules.dice, diceEntry(500, .ordinary, null));
    try session.adjust(.up);
    try session.confirmWager();
    try session.start();
    try session.submitScore(3);
    const snapshot = session.checkpoint();
    var restored = try contracts.DiceSession.restore(snapshot, rules.dice);
    try std.testing.expectEqual(session, restored);
    try std.testing.expectError(error.InvalidScore, session.submitScore(7));
    try std.testing.expectEqual(snapshot, session);
    try std.testing.expectError(error.InvalidScore, session.submitScore(9));
    try session.submitScore(5);
    try restored.submitScore(5);
    try std.testing.expectEqual(session, restored);
}

test "source dice throw produces faces and preserves draws on failure" {
    const input: contracts.DiceThrow = .{ .horizontal_pixels = 160, .strength = 32, .random_salt = 0 };
    var triple: contracts.Draws = .{ .values = &.{ 0, 0, 4 } };
    const win = try contracts.produceDiceRoll(input, &triple);
    try std.testing.expect(win.forced);
    try std.testing.expectEqual([3]u8{ 5, 5, 5 }, win.faces);
    try std.testing.expectEqual(@as(u16, 8), win.score);
    try std.testing.expectEqual(@as(usize, 3), triple.cursor);
    var ordinary: contracts.Draws = .{ .values = &.{ 99, 99, 99, 99, 99, 0, 1, 2 } };
    const sequence = try contracts.produceDiceRoll(input, &ordinary);
    try std.testing.expect(!sequence.forced);
    try std.testing.expectEqual([3]u8{ 1, 2, 3 }, sequence.faces);
    try std.testing.expectEqual(@as(u16, 64), sequence.score);
    var exhausted: contracts.Draws = .{ .values = &.{99} };
    try std.testing.expectError(error.RandomInputExhausted, contracts.produceDiceRoll(input, &exhausted));
    try std.testing.expectEqual(@as(usize, 0), exhausted.cursor);
    const rules = try loadContracts();
    var fixed = try contracts.DiceSession.init(rules.dice, diceEntry(2000, .fixed, null));
    try fixed.startFixed();
    var retry: contracts.Draws = .{ .values = &.{ 0, 0, 4, 99, 99, 99, 99, 99, 1, 1, 2 } };
    const accepted = try fixed.throwDice(input, &retry);
    try std.testing.expectEqual(@as(u16, 3), accepted.score);
    try std.testing.expectEqual(contracts.DicePhase.player_roll, fixed.phase);
    try std.testing.expectEqual(@as(usize, 11), retry.cursor);
    var control_draws: contracts.Draws = .{ .values = &.{0} };
    try fixed.tickThrow(.{ .up = true }, 0, &control_draws);
    const control = fixed.throw_control.?;
    try std.testing.expectEqual(@as(i16, 118), control.horizontal_pixels);
    try std.testing.expectEqual(@as(u16, 36), control.strength);
    try std.testing.expectEqual(@as(u8, 19), control.startup_ticks);
    const restored = try contracts.DiceSession.restore(fixed.checkpoint(), rules.dice);
    try std.testing.expectEqual(fixed, restored);
}
