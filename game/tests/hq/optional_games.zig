//! Focused port check: source mode entry, exclusive frame/dialogue/
//! animation ownership, the optional-game loop bridge, and atomic settlement/restore for
//! the three optional games.
//!
//! Static/port level only: no original instruction, emulator, window, media or
//! real save is touched. Dice and COIN are driven end to end through their real
//! sessions; KARUTA's rule loop and settlement are driven through its real
//! session directly because its field caller is still missing (admission refuses
//! it), exactly as the ledger states.

const std = @import("std");
const optional_games = @import("hq").optional_games;
const game_contracts = optional_games.contracts;
const host = optional_games.host;
const settle = optional_games.settle;
const ledger_mod = optional_games.ledger;
const types = optional_games.types;

const allocator = std.testing.allocator;

/// Hand-authored conformance values for the pinned optional-game contracts asset
/// (`game/assets/optional_game_contracts.json`). They are
/// values, not a second rule engine.
fn contracts() game_contracts.Contracts {
    return .{
        .dice = .{
            .modes = .{
                .{ .fixed_wager = null, .profit_goal = null },
                .{ .fixed_wager = 1000, .profit_goal = null },
                .{ .fixed_wager = null, .profit_goal = 5000 },
            },
            .minimum_balance = 100,
            .balance_cap = 999999,
            .step = 100,
            .increments = .{ 100, 1000 },
            .wager_maximum = 9900,
            .ordinary_min = 1,
            .ordinary_max = 6,
            .specials = .{
                .{ .score = 8, .roller_wins = true, .multiplier = 3 },
                .{ .score = 16, .roller_wins = false, .multiplier = 3 },
                .{ .score = 32, .roller_wins = true, .multiplier = 2 },
                .{ .score = 64, .roller_wins = false, .multiplier = 2 },
                .{ .score = 128, .roller_wins = false, .multiplier = 1 },
            },
            .failure_limit = 3,
            .third_multiplier = 1,
            .tie_when_opponent_zero = true,
        },
        .coin = .{
            .stakes = .{ 100, 1000, 10000 },
            .quit_option = 3,
            .balance_cap = 999999,
            .bases = .{ 15, 7, 4 },
            .ranges = .{ 20, 8, 6 },
            .shuffle_positions = 3,
            .shuffle_steps = 20,
            .motion_high = 32767,
            .cups = 3,
            .reveal_ticks = 70,
            .win_credit_stakes = 2,
            .net_credit_stakes = 2,
            .profit_threshold = 5000,
            .flag_mask = 0x00A00000,
            .flag_value = 0x00200000,
            .result_bit = 0x40,
        },
        .karuta = .{
            .rows = 8,
            .columns = 6,
            .cells = 48,
            .pairs = 24,
            .faces = 108,
            .empty_face = 109,
            .back_face = 108,
            .rounds = .{
                .{ .identities = 5, .record_moves = 900 },
                .{ .identities = 7, .record_moves = 1500 },
                .{ .identities = 10, .record_moves = 2400 },
                .{ .identities = 15, .record_moves = 3300 },
            },
            .quit_round = 4,
            .identity_divisor = 300,
            .row_divisor = 3640,
            .column_divisor = 4681,
            .row_candidates = 9,
            .column_candidates = 8,
            .flip_frames = 11,
            .matched_scale_frames = 6,
            .matched_fade_frames = 21,
            .resolve_frames = 31,
            .deal_ticks = 48,
            .moves_cap = 3600,
            .balance_cap = 999999,
            .flag_mask = 0x00A00000,
            .flag_value = 0x00200000,
            .result_bit = 0x40,
        },
    };
}

/// A deterministic caller RNG stream. The tape itself is empty: the BIOS
/// recurrence is the accepted source stream, so the checkpoint has a real
/// multi-word state to preserve.
fn draws() game_contracts.Draws {
    return .{ .bios_state = 0x12345678 };
}

fn newHost() !host.Host {
    return host.Host.init(allocator, @import("hq_data").optional_games.json, draws(), contracts());
}

fn coinEntry(receipt: u64, money: u32, net: i32, flags: u32) game_contracts.CoinEntry {
    return .{
        .entry_id = 0xC0_0001,
        .content_id = 11,
        .receipt_id = receipt,
        .balance = money,
        .net = net,
        .difficulty = 0,
        .flags = flags,
    };
}

fn diceEntry(receipt: u64, money: u32, variant: game_contracts.DiceVariant, baseline: ?u32) game_contracts.DiceEntry {
    return .{
        .entry_id = 0xD1_CE,
        .content_id = 1,
        .receipt_id = receipt,
        .balance = money,
        .variant = variant,
        .baseline = baseline,
    };
}

// ---------------------------------------------------------------------------
// Ledger: the source mode entry and the proven/missing caller split
// ---------------------------------------------------------------------------

test "ledger: the module table, request path and game selectors are pinned" {
    var ledger = try ledger_mod.Ledger.load(allocator, @import("hq_data").optional_games.json);
    defer ledger.deinit();

    try std.testing.expectEqual(@as(u8, 0x47), ledger.entry.event_opcode);
    try std.testing.expectEqual(@as(u8, 8), ledger.entry.ff_context_flag);
    try std.testing.expectEqual(@as(u8, 16), ledger.entry.fe_context_flag);
    try std.testing.expectEqual(@as(u8, 4), ledger.entry.special_content_value);
    try std.testing.expectEqual(@as(u8, 5), ledger.entry.second_lane_value);
    try std.testing.expectEqual(@as(u32, 0x8016F258), ledger.entry.table_va);
    try std.testing.expectEqual(@as(u8, 16), ledger.entry.table_entries);
    try std.testing.expectEqualStrings("gs+0x1C", ledger.gs.money);
    try std.testing.expectEqualStrings("gs+0x230", ledger.gs.status);
    try std.testing.expectEqualStrings("gs+0x1AF4", ledger.gs.recruit);

    const coin = try ledger.requireFamily(.coin);
    const karuta = try ledger.requireFamily(.karuta);
    const dice = try ledger.requireFamily(.dice);
    try std.testing.expectEqual(@as(?u8, 11), coin.selector);
    try std.testing.expectEqual(@as(?u8, 15), karuta.selector);
    try std.testing.expectEqual(@as(?u8, null), dice.selector);
    try std.testing.expectEqual(types.EntryKind.field_room, dice.entry_kind);
    try std.testing.expectEqual(types.CallerStatus.proven, coin.entry_status);
    try std.testing.expectEqual(types.CallerStatus.proven, karuta.entry_status);
    try std.testing.expectEqual(types.CallerStatus.proven, dice.entry_status);

    // Independent overlay identity: these hashes were derived from the disc
    // extent before the ledger existed.
    try std.testing.expectEqualSlices(u8, &(try types.parseHex32("e4069ceb10282566fdc0788aa55bf89f400ae222cf439d1cfc4adbce9ea06a4c")), &coin.overlay.sha256);
    try std.testing.expectEqualSlices(u8, &(try types.parseHex32("a647a9f6674ccd0ece88294dfcd0b042f0ab5e06dbfbcbaffa91688202c0d03a")), &karuta.overlay.sha256);
    try std.testing.expectEqualSlices(u8, &(try types.parseHex32("cff3f996221e90b6b2571570e8ecda957ed24f4153e438bd255dcf879db0d442")), &dice.overlay.sha256);

    try std.testing.expectEqual(@as(usize, 2), coin.callers.len);
    try std.testing.expect(coin.admitsSite(0x26430));
    try std.testing.expectEqual(@as(u16, 0), coin.callers[0].room);
    try std.testing.expectEqual(@as(u16, 42), coin.callers[0].entity);
    try std.testing.expect(coin.admitsSite(0x31641));
    try std.testing.expectEqual(@as(u16, 12), coin.callers[1].entity);
    try std.testing.expect(karuta.admitsSite(0x3162D));
    try std.testing.expectEqual(@as(u16, 11), karuta.callers[0].entity);
    try std.testing.expect(!coin.admitsSite(0x29D75));
    try std.testing.expect(!karuta.admitsSite(0x29D75));
}

// ---------------------------------------------------------------------------
// Admission and ownership
// ---------------------------------------------------------------------------

test "admission: proven COIN and dice callers admit their modes" {
    var game_host = try newHost();
    defer game_host.deinit();
    game_host.wallet = .{ .money = 1500 };

    // A rejected candidate offset cannot admit a mode.
    try std.testing.expectError(error.UnknownCaller, game_host.admit(.{
        .game = .karuta,
        .caller_site = 0x29D75,
        .revision = 0,
        .entry = .{ .karuta = .{ .entry_id = 1, .content_id = 15, .receipt_id = 1, .round = 0, .balance = 1500, .best = @splat(0), .flags = 0 } },
        .karuta_eligible = @splat(true),
    }));
    try std.testing.expectError(error.UnknownCaller, game_host.admit(.{
        .game = .dice,
        .caller_site = 0x26430,
        .revision = 0,
        .entry = .{ .dice = diceEntry(1, 1500, .ordinary, null) },
    }));
    try std.testing.expect(!game_host.ownsFrame());

    // A caller site that is not in the ledger is refused even for COIN.
    try std.testing.expectError(error.UnknownCaller, game_host.admit(.{
        .game = .coin,
        .caller_site = 0x1234,
        .revision = 0,
        .entry = .{ .coin = coinEntry(1, 1500, 0, 0) },
    }));

    // A recruit consequence is never fabricated.
    try std.testing.expectError(error.RecruitConsequenceNotProven, game_host.admit(.{
        .game = .coin,
        .caller_site = 0x26430,
        .revision = 0,
        .entry = .{ .coin = coinEntry(1, 1500, 0, 0) },
        .recruit = .{ .index = 4, .mask = 1 },
    }));

    // The proven path admits, takes the frame and owns dialogue/animation.
    try game_host.admit(.{
        .game = .coin,
        .caller_site = 0x26430,
        .revision = 0,
        .entry = .{ .coin = coinEntry(1, 1500, 0, 0) },
    });
    try std.testing.expect(game_host.ownsFrame());
    try std.testing.expectError(error.FieldSuspendedDuringMode, game_host.fieldDialogue());
    try std.testing.expectError(error.FieldSuspendedDuringMode, game_host.fieldAnimation());
    try game_host.modeDialogue();

    // The mode is exclusive: a second admission cannot steal the frame.
    try std.testing.expectError(error.ModeAlreadyOwned, game_host.admit(.{
        .game = .coin,
        .caller_site = 0x26430,
        .revision = 0,
        .entry = .{ .coin = coinEntry(2, 1500, 0, 0) },
    }));

    // Exiting without settling is an ordinary return to the field.
    try game_host.tick(.coin_exit);
    try game_host.finish();
    try std.testing.expect(!game_host.ownsFrame());
    try game_host.fieldDialogue();
    try std.testing.expectEqual(@as(u32, 1500), game_host.wallet.money);
    var dice_admission: host.Admission = .{ .game = .dice, .caller_site = 0x2D0BC, .revision = 0, .entry = .{ .dice = diceEntry(1, 1500, .ordinary, null) } };
    try std.testing.expectError(error.WrongDiceVariant, game_host.admit(dice_admission));
    dice_admission.entry.dice.variant = .fixed;
    try game_host.admit(dice_admission);
    try game_host.tick(.start);
    try game_host.tick(.{ .dice_tick = .{ .buttons = .{ .up = true } } });
    try std.testing.expectEqual(@as(u16, 36), game_host.session.?.dice.throw_control.?.strength);
}

test "admission: stale entry facts are refused before a session is built" {
    var game_host = try newHost();
    defer game_host.deinit();
    game_host.wallet = .{ .money = 1500, .net = 0, .last_receipt = 7, .receipt_count = 1 };
    game_host.wallet.receipts[0] = 7;

    // Stale revision.
    try std.testing.expectError(error.StaleRevision, game_host.admit(.{
        .game = .coin,
        .caller_site = 0x26430,
        .revision = 3,
        .entry = .{ .coin = coinEntry(8, 1500, 0, 0) },
    }));
    // Stale balance.
    try std.testing.expectError(error.StaleBalance, game_host.admit(.{
        .game = .coin,
        .caller_site = 0x26430,
        .revision = 0,
        .entry = .{ .coin = coinEntry(8, 1400, 0, 0) },
    }));
    // Re-used receipt.
    try std.testing.expectError(error.BadReceipt, game_host.admit(.{
        .game = .coin,
        .caller_site = 0x26430,
        .revision = 0,
        .entry = .{ .coin = coinEntry(7, 1500, 0, 0) },
    }));
    // Fresh receipt admits.
    try game_host.admit(.{
        .game = .coin,
        .caller_site = 0x26430,
        .revision = 0,
        .entry = .{ .coin = coinEntry(8, 1500, 0, 0) },
    });
}

// ---------------------------------------------------------------------------
// Dice: wager grid, cancel, win/loss/tie, retained winnings, profit goal
// ---------------------------------------------------------------------------

test "dice: cancel and tie both end the loop without publishing money" {
    const wallet = settle.Wallet{ .money = 1000 };
    var session = try game_contracts.DiceSession.init(contracts().dice, diceEntry(1, 1000, .ordinary, null));

    // Wager edit, confirm, cancel (back to wager), cancel (exit).
    try host.input_mod.applyDice(&session, .wager_up);
    try host.input_mod.applyDice(&session, .wager_confirm);
    try host.input_mod.applyDice(&session, .cancel);
    try std.testing.expectEqual(game_contracts.DicePhase.wager, session.phase);
    try host.input_mod.applyDice(&session, .cancel);
    try std.testing.expectEqual(game_contracts.DicePhase.exited, session.phase);
    try std.testing.expectError(error.NoProposal, host.planDice(session, wallet, wallet.draws));

    // Tie: equal ordinary scores reach the tie prompt and replay the wager.
    var tied = try game_contracts.DiceSession.init(contracts().dice, diceEntry(2, 1000, .ordinary, null));
    try host.input_mod.applyDice(&tied, .wager_up);
    try host.input_mod.applyDice(&tied, .wager_confirm);
    try host.input_mod.applyDice(&tied, .start);
    try host.input_mod.applyDice(&tied, .{ .score = 5 });
    try host.input_mod.applyDice(&tied, .{ .score = 5 });
    try std.testing.expectEqual(game_contracts.DicePhase.tie_prompt, tied.phase);
    try host.input_mod.applyDice(&tied, .replay_tie);
    try std.testing.expectEqual(game_contracts.DicePhase.wager, tied.phase);
    try host.input_mod.applyDice(&tied, .cancel);
    try std.testing.expectEqual(game_contracts.DicePhase.exited, tied.phase);
    try std.testing.expectEqual(@as(u32, 1000), wallet.money);
    try std.testing.expectEqual(@as(u64, 0), wallet.revision);
}

test "dice: win and loss publish money and retained winnings atomically" {
    var wallet = settle.Wallet{ .money = 1000 };
    var session = try game_contracts.DiceSession.init(contracts().dice, diceEntry(1, 1000, .ordinary, null));
    try host.input_mod.applyDice(&session, .wager_larger); // increment 1000
    try host.input_mod.applyDice(&session, .wager_up); // 1000
    try host.input_mod.applyDice(&session, .wager_confirm);
    try host.input_mod.applyDice(&session, .start);
    try host.input_mod.applyDice(&session, .{ .score = 3 });
    try host.input_mod.applyDice(&session, .{ .score = 4 });

    const plan = try host.planDice(session, wallet, wallet.draws);
    try std.testing.expect(plan.effectOf(.net) == null);
    try std.testing.expectEqual(@as(u32, 1000), plan.effectOf(.retained).?.retained);
    try std.testing.expectEqual(@as(u32, 2000), plan.effectOf(.money).?.money);

    const outcome = try settle.apply(plan, &wallet);
    try std.testing.expectEqual(@as(u32, 2000), outcome.money);
    try std.testing.expectEqual(@as(u32, 1000), wallet.retained);
    try std.testing.expectEqual(@as(u64, 1), wallet.revision);
    try std.testing.expect(wallet.hasReceipt(1));

    const before = wallet;
    try std.testing.expectError(error.DuplicateSettlement, settle.apply(plan, &wallet));
    try std.testing.expectEqual(before, wallet);

    // Loss: a lower player score clears the retained winnings.
    var losing = try game_contracts.DiceSession.init(contracts().dice, diceEntry(2, 2000, .ordinary, null));
    try host.input_mod.applyDice(&losing, .wager_up);
    try host.input_mod.applyDice(&losing, .wager_confirm);
    try host.input_mod.applyDice(&losing, .start);
    try host.input_mod.applyDice(&losing, .{ .score = 6 });
    try host.input_mod.applyDice(&losing, .{ .score = 2 });
    const loss_plan = try host.planDice(losing, wallet, wallet.draws);
    _ = try settle.apply(loss_plan, &wallet);
    try std.testing.expectEqual(@as(u32, 1900), wallet.money);
    try std.testing.expectEqual(@as(u32, 0), wallet.retained);
}

test "dice: fixed and profit variants reach their source consequence" {
    var wallet = settle.Wallet{ .money = 1000 };
    var fixed = try game_contracts.DiceSession.init(contracts().dice, diceEntry(1, 1000, .fixed, null));
    try host.input_mod.applyDice(&fixed, .start);
    try host.input_mod.applyDice(&fixed, .{ .score = 2 });
    try host.input_mod.applyDice(&fixed, .{ .score = 6 });
    const fixed_plan = try host.planDice(fixed, wallet, wallet.draws);
    try std.testing.expectEqual(settle.Completion.settled, fixed_plan.completion);
    var stale = wallet;
    stale.dice_flags.fixed_won = true;
    try std.testing.expectError(error.StaleBefore, settle.apply(fixed_plan, &stale));
    _ = try settle.apply(fixed_plan, &wallet);
    try std.testing.expect(wallet.dice_flags.fixed_won);
    try std.testing.expectEqual(@as(u32, 2000), wallet.money);

    // Profit variant: a 5000 win over the entry baseline consumes the session.
    // The wager cannot exceed the entry balance, so the profit run starts from a
    // balance that can stake the 5000.
    wallet = .{ .money = 6000, .revision = wallet.revision, .receipts = wallet.receipts, .receipt_count = wallet.receipt_count, .last_receipt = wallet.last_receipt };
    var profit_session = try game_contracts.DiceSession.init(contracts().dice, diceEntry(2, 6000, .profit, 1000));
    try host.input_mod.applyDice(&profit_session, .wager_larger);
    var i: usize = 0;
    while (i < 5) : (i += 1) try host.input_mod.applyDice(&profit_session, .wager_up);
    try host.input_mod.applyDice(&profit_session, .wager_confirm);
    try host.input_mod.applyDice(&profit_session, .start);
    try host.input_mod.applyDice(&profit_session, .{ .score = 3 });
    try host.input_mod.applyDice(&profit_session, .{ .score = 4 });
    const profit_plan = try host.planDice(profit_session, wallet, wallet.draws);
    // Dice publishes scenario flags, separate from the status page.
    try std.testing.expect(profit_plan.effectOf(.status_bit) == null);
    try std.testing.expectEqual(settle.Completion.settled, profit_plan.completion);
    _ = try settle.apply(profit_plan, &wallet);
    try std.testing.expect(wallet.dice_flags.profit_goal);
    try std.testing.expectEqual(@as(u32, 11000), wallet.money);
}

// ---------------------------------------------------------------------------
// COIN: admission, readiness gates, reveal, profit flag, RNG publication
// ---------------------------------------------------------------------------

test "coin: not-ready shuffle is refused and leaves the session and RNG alone" {
    var game_host = try newHost();
    defer game_host.deinit();
    game_host.wallet = .{ .money = 1500 };

    try game_host.admit(.{ .game = .coin, .caller_site = 0x26430, .revision = 0, .entry = .{ .coin = coinEntry(1, 1500, 0, 0) } });
    try game_host.tick(.coin_admit); // stake 100 leaves the balance at 1400
    const session_before = game_host.session.?;
    const draws_before = game_host.draws;
    try std.testing.expectError(error.PresentationNotReady, game_host.tick(.{ .shuffle = false }));
    try std.testing.expectEqual(session_before, game_host.session.?);
    try std.testing.expectEqual(draws_before, game_host.draws);
}

test "coin: win publishes money, net, RNG cursor and the profit result bit" {
    var game_host = try newHost();
    defer game_host.deinit();
    // flags already carry the source gate value, and the running net is close
    // enough that the win crosses the 5000 threshold.
    game_host.wallet = .{ .money = 1500, .net = 4900 };

    try game_host.admit(.{ .game = .coin, .caller_site = 0x26430, .revision = 0, .entry = .{ .coin = coinEntry(1, 1500, 4900, 0x00200000) } });
    try game_host.tick(.coin_admit);
    var steps: usize = 0;
    while (steps < 20) : (steps += 1) try game_host.tick(.{ .shuffle = true });
    // The player watched the shuffle: choose the cup that holds the tracked coin.
    const tracked = game_host.session.?.coin;
    const win_delta: i8 = @as(i8, @intCast(tracked.coin_position)) - @as(i8, @intCast(tracked.cup));
    try game_host.tick(.{ .coin_move = win_delta });
    try game_host.tick(.coin_commit);
    var ticks: usize = 0;
    while (ticks < 71) : (ticks += 1) try game_host.tick(.reveal_tick);

    const plan = try game_host.plan();
    const money = plan.effectOf(.money).?;
    const net = plan.effectOf(.net).?;
    const draws_effect = plan.effectOf(.draws).?;
    const status = plan.effectOf(.status_bit);
    // A deliberate win or loss is data, not an assumption: both outcomes are
    // legal here, but the plan must agree with the session.
    try std.testing.expectEqual(@as(u32, 1600), money.money);
    try std.testing.expectEqual(@as(i32, 5000), net.net);
    try std.testing.expect(draws_effect.draws > 0);
    try std.testing.expect(status != null);
    try std.testing.expectEqual(@as(u8, 2), status.?.status_bit.offset); // gs+0x232
    try std.testing.expectEqual(@as(u8, 0x40), status.?.status_bit.mask);

    _ = try game_host.settleMode();
    try std.testing.expectEqual(@as(u32, 1600), game_host.wallet.money);
    try std.testing.expectEqual(@as(i32, 5000), game_host.wallet.net);
    try std.testing.expectEqual(@as(u8, 0x40), game_host.wallet.status[2]);
    try std.testing.expectEqual(host.drawsCursor(game_host.draws), game_host.wallet.draws);
    try std.testing.expectEqual(settle.Completion.profit_flag, game_host.completion().?);
    try game_host.finish();

    const before = game_host.wallet;
    try std.testing.expectError(error.DuplicateSettlement, settle.apply(plan, &game_host.wallet));
    try std.testing.expectEqual(before, game_host.wallet);
}

test "coin: a loss publishes the debited stake without the result bit" {
    var game_host = try newHost();
    defer game_host.deinit();
    game_host.wallet = .{ .money = 1500, .net = 0 };

    try game_host.admit(.{ .game = .coin, .caller_site = 0x26430, .revision = 0, .entry = .{ .coin = coinEntry(1, 1500, 0, 0) } });
    try game_host.tick(.coin_admit);
    var steps: usize = 0;
    while (steps < 20) : (steps += 1) try game_host.tick(.{ .shuffle = true });
    // Deliberately choose a different cup than the tracked coin: a loss.
    const coin = game_host.session.?.coin;
    const wrong = (coin.coin_position + 1) % 3;
    const delta: i8 = @as(i8, @intCast(wrong)) - @as(i8, @intCast(coin.cup));
    try game_host.tick(.{ .coin_move = delta });
    try game_host.tick(.coin_commit);
    var ticks: usize = 0;
    while (ticks < 71) : (ticks += 1) try game_host.tick(.reveal_tick);
    const plan = try game_host.plan();
    try std.testing.expect(plan.effectOf(.status_bit) == null);
    _ = try game_host.settleMode();
    try std.testing.expectEqual(@as(u32, 1400), game_host.wallet.money);
    try std.testing.expectEqual(@as(i32, -100), game_host.wallet.net);
    try game_host.finish();
}

// ---------------------------------------------------------------------------
// KARUTA: the real session loop and settlement (entry blocked, plan tested)
// ---------------------------------------------------------------------------

fn advanceToStable(session: *game_contracts.KarutaSession) !void {
    var guard: usize = 0;
    while (!session.boardStable()) : (guard += 1) {
        if (guard > 4096) return error.SolverStuck;
        try session.advance();
    }
}

fn moveTo(session: *game_contracts.KarutaSession, row: u8, column: u8) !void {
    const row_delta: i8 = @as(i8, @intCast(row)) - @as(i8, @intCast(session.cursor_row));
    const column_delta: i8 = @as(i8, @intCast(column)) - @as(i8, @intCast(session.cursor_column));
    try session.moveCursor(row_delta, column_delta);
}

/// Play a whole board with ordinary inputs. The driver may read the face values
/// a player has already seen; it never mutates the session.
fn solveBoard(session: *game_contracts.KarutaSession) !void {
    while (session.phase == .dealing) try session.advance();
    var pairs: usize = 0;
    while (session.phase == .play) {
        if (pairs > 24) return error.SolverStuck;
        try advanceToStable(session);
        if (session.phase != .play) break;
        var first: ?usize = null;
        var second: ?usize = null;
        outer: for (0..game_contracts.cell_count) |i| {
            if (session.cells[i].state != .face_down) continue;
            for (i + 1..game_contracts.cell_count) |j| {
                if (session.cells[j].state == .face_down and session.cells[j].face == session.cells[i].face) {
                    first = i;
                    second = j;
                    break :outer;
                }
            }
        }
        const a = first orelse return error.NoPair;
        const b = second orelse return error.NoPair;
        try moveTo(session, @intCast(a / game_contracts.board_columns), @intCast(a % game_contracts.board_columns));
        try session.confirm();
        try advanceToStable(session);
        try moveTo(session, @intCast(b / game_contracts.board_columns), @intCast(b % game_contracts.board_columns));
        try session.confirm();
        try advanceToStable(session);
        pairs += 1;
    }
    if (session.phase != .proposal) return error.SolverStuck;
}

test "karuta: the admitted castle caller publishes the record and the flag result bit" {
    const entry = game_contracts.KarutaEntry{
        .entry_id = 0x4B_0001,
        .content_id = 15,
        .receipt_id = 1,
        .round = 0,
        .balance = 1500,
        .best = @splat(0),
        .flags = 0x00200000,
    };
    const eligible: [game_contracts.face_count]bool = @splat(true);
    var game_host = try newHost();
    defer game_host.deinit();
    game_host.wallet = .{ .money = entry.balance };
    var request: host.Admission = .{
        .game = .karuta,
        .caller_site = 0x3162D,
        .revision = 0,
        .entry = .{ .karuta = entry },
    };
    try std.testing.expectError(error.MissingEligibleFaces, game_host.admit(request));
    request.karuta_eligible = eligible;
    request.entry.karuta.balance += 1;
    try std.testing.expectError(error.StaleBalance, game_host.admit(request));
    try std.testing.expectEqualDeep(@as([game_contracts.face_count]bool, @splat(false)), game_host.eligible);
    request.entry.karuta.balance = entry.balance;
    try game_host.admit(request);
    try std.testing.expect(game_host.ownsFrame());
    try game_host.tick(.karuta_confirm_round);
    try solveBoard(&game_host.session.?.karuta);
    const plan = try game_host.plan();
    const record = plan.effectOf(.best_record).?;
    try std.testing.expectEqual(@as(u8, 0), record.best_record.round);
    try std.testing.expect(record.best_record.elapsed > 0);
    try std.testing.expectEqual(@as(u32, 1500), plan.effectOf(.money).?.money);
    const status = plan.effectOf(.status_bit).?;
    try std.testing.expectEqual(@as(u8, 3), status.status_bit.offset); // gs+0x233
    try std.testing.expectEqual(@as(u8, 0x40), status.status_bit.mask);

    _ = try game_host.settleMode();
    try std.testing.expectEqual(record.best_record.elapsed, game_host.wallet.best[0]);
    try std.testing.expectEqual(@as(u8, 0x40), game_host.wallet.status[3]);
    try std.testing.expectEqual(@as(u32, 1500), game_host.wallet.money);
    try std.testing.expectError(error.DuplicateSettlement, settle.apply(plan, &game_host.wallet));
    try game_host.finish();
    try std.testing.expect(!game_host.ownsFrame());
}

test "karuta: settlement refuses a stale record before and after the board" {
    const rules = contracts().karuta;
    var caller_draws = draws();
    const entry = game_contracts.KarutaEntry{
        .entry_id = 0x4B_0002,
        .content_id = 15,
        .receipt_id = 3,
        .round = 1,
        .balance = 1500,
        .best = .{ 0, 1500, 0, 0 },
        .flags = 0,
    };
    var session = try game_contracts.KarutaSession.init(rules, entry);
    const eligible: [game_contracts.face_count]bool = @splat(true);
    try session.confirmRound(&eligible, &caller_draws);
    try solveBoard(&session);

    // The wallet's record disagrees with the session's entry: the plan is stale.
    const stale = settle.Wallet{ .money = 1500, .best = .{ 0, 1600, 0, 0 } };
    try std.testing.expectError(error.StaleRecord, host.planKaruta(session, stale));
    // The matching wallet plans.
    const matching = settle.Wallet{ .money = 1500, .best = .{ 0, 1500, 0, 0 } };
    const plan = try host.planKaruta(session, matching);
    try std.testing.expect(plan.effectOf(.best_record) != null);
}

// ---------------------------------------------------------------------------
// Mid-mode restore and cross-cutting refusals
// ---------------------------------------------------------------------------

test "checkpoint/restore keeps money, RNG and receipts, and refuses tampering" {
    var game_host = try newHost();
    defer game_host.deinit();
    game_host.wallet = .{ .money = 1500, .net = 0 };

    try game_host.admit(.{ .game = .coin, .caller_site = 0x26430, .revision = 0, .entry = .{ .coin = coinEntry(1, 1500, 0, 0) } });
    try game_host.tick(.coin_admit);
    var steps: usize = 0;
    while (steps < 4) : (steps += 1) try game_host.tick(.{ .shuffle = true });
    const snapshot = try game_host.checkpoint();
    const saved_session = game_host.session.?;
    const saved_draws = game_host.draws;

    var first_run = saved_draws;
    steps = 0;
    while (steps < 6) : (steps += 1) {
        try game_host.tick(.{ .shuffle = true });
    }
    first_run = game_host.draws;
    try std.testing.expect(!std.meta.eql(saved_draws, game_host.draws));
    try game_host.restore(snapshot);
    try std.testing.expectEqual(saved_session, game_host.session.?);
    try std.testing.expectEqual(saved_draws, game_host.draws);
    // The stake is debited inside the session; the wallet is only written at
    // settlement, so it still holds the pre-round money.
    try std.testing.expectEqual(@as(u32, 1500), game_host.wallet.money);
    try std.testing.expectEqual(@as(u8, 0), game_host.wallet.receipt_count);

    // The rollback keeps playing deterministically from the same RNG point.
    steps = 0;
    while (steps < 6) : (steps += 1) try game_host.tick(.{ .shuffle = true });
    // The same ordinary inputs from the same checkpoint reproduce the same RNG
    // stream exactly (BIOS state and cursor), not merely the same count.
    try std.testing.expectEqual(first_run, game_host.draws);

    // A committed settlement invalidates the mid-mode checkpoint.
    steps = 0;
    while (steps < 10) : (steps += 1) try game_host.tick(.{ .shuffle = true });
    try game_host.tick(.coin_commit);
    var ticks: usize = 0;
    while (ticks < 71) : (ticks += 1) try game_host.tick(.reveal_tick);
    _ = try game_host.settleMode();
    try std.testing.expectError(error.StaleSnapshot, game_host.restore(snapshot));
}

test "restore: an externally changed wallet or a foreign RNG tape is refused" {
    var game_host = try newHost();
    defer game_host.deinit();
    game_host.wallet = .{ .money = 1000 };

    game_host.wallet = .{ .money = 1000 };
    try game_host.admit(.{ .game = .coin, .caller_site = 0x26430, .revision = 0, .entry = .{ .coin = coinEntry(1, 1000, 0, 0) } });
    const snapshot = try game_host.checkpoint();

    game_host.wallet.money = 900;
    try std.testing.expectError(error.StaleSnapshot, game_host.restore(snapshot));
    game_host.wallet.money = 1000;

    var other_tape = [_]u15{ 1, 2, 3 };
    game_host.draws = .{ .values = &other_tape, .cursor = 0 };
    try std.testing.expectError(error.StaleSnapshot, game_host.restore(snapshot));
}

test "ownership: a pending proposal cannot hand the frame back; inputs are per game" {
    var game_host = try newHost();
    defer game_host.deinit();
    game_host.wallet = .{ .money = 1000 };

    try game_host.admit(.{ .game = .coin, .caller_site = 0x26430, .revision = 0, .entry = .{ .coin = coinEntry(1, 1000, 0, 0) } });
    try std.testing.expectError(error.PendingSettlement, game_host.finish());

    // A dice input against a COIN session is refused and changes nothing.
    const before = game_host.session.?;
    try std.testing.expectError(error.WrongGameInput, game_host.tick(.start));
    try std.testing.expectEqual(before, game_host.session.?);

    // Field ownership calls are refused while the mode runs.
    try std.testing.expectError(error.FieldSuspendedDuringMode, game_host.fieldDialogue());
    try game_host.tick(.coin_exit);
    try game_host.finish();
    try game_host.fieldDialogue();
    try std.testing.expectError(error.ModeNotOwned, game_host.modeDialogue());
}
