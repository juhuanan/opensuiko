const journey = @import("journey");
const rl = @import("raylib");
const ui = @import("ui");
const cards_lib = journey.dice.games.contracts;

pub fn draw(context: *const ui.Context, state: *const journey.State) void {
    const active = state.side_game.?;
    context.panel(72, 42, 496, 376);
    switch (state.dice_host.?.session.?) {
        .coin => |coin| {
            context.text("Cup Game", 92, 58, 25, .gold);
            context.numberText("{d} bits", .{coin.balance}, 414, 62, 18, .ray_white);
            switch (coin.phase) {
                .select => {
                    for (coin.rules.stakes, 0..) |stake, i| {
                        context.numberText("{s}Wager {d} bits", .{ if (coin.difficulty == i) "> " else "  ", stake }, 160, 112 + row(i, 37), 20, .ray_white);
                    }
                    context.text(if (coin.difficulty == coin.rules.quit_option) "> Leave" else "  Leave", 160, 112 + row(coin.rules.stakes.len, 37), 20, .ray_white);
                    context.text(active.message, 92, 366, 18, .gold);
                },
                .shuffling, .choice, .reveal => {
                    const ticks = @as(i32, active.shuffle_ticks);
                    const span = @as(i32, journey.side_games.shuffle_frames);
                    for (0..3) |i| {
                        var x = 163 + row(i, 128);
                        var y: i32 = 185;
                        if (coin.phase != .reveal) if (coin.last_swap) |swap| {
                            if (ticks < span and (i == swap[0] or i == swap[1])) {
                                const other = if (i == swap[0]) swap[1] else swap[0];
                                x += @divTrunc((row(other, 128) - row(i, 128)) * (span - ticks), span);
                                const arc = @min(ticks, span - ticks) * 7;
                                y += if (i == swap[0]) arc else -arc;
                            }
                        };
                        const shown = (coin.phase == .reveal and i == coin.cup) or (coin.phase == .shuffling and coin.last_swap == null and i == coin.coin_position);
                        rl.drawRectangle(x, y - @as(i32, if (shown) 28 else 0), 52, 53, .dark_blue);
                        rl.drawRectangle(x - 5, y + 48 - @as(i32, if (shown) 28 else 0), 62, 8, .sky_blue);
                        if (shown and i == coin.coin_position) rl.drawCircle(x + 26, y + 61, 8, .gold);
                        if (coin.phase == .choice and i == coin.cup) context.text("^", x + 20, 265, 21, .gold);
                    }
                    context.text(if (coin.phase == .choice) "Choose a cup." else if (coin.phase == .shuffling) "Watch the cups." else "Revealing your cup...", 94, 334, 19, .ray_white);
                },
                .proposal, .acknowledged => {
                    context.text(if (coin.win) "You found the coin." else "The coin was under another cup.", 110, 164, 23, .ray_white);
                    context.text(if (coin.consequence == .profit_flag) "Confirm to return." else "Confirm to play again or Cancel to return.", 110, 300, 16, .gold);
                },
                .exited => {},
            }
        },
        .karuta => |cards| {
            context.text("Matching Cards", 92, 58, 25, .gold);
            switch (cards.phase) {
                .select => {
                    for (cards.rules.rounds, 0..) |round, i| {
                        context.numberText("{s}{d} pairs", .{ if (cards.round == i) "> " else "  ", round.identities }, 162, 116 + row(i, 35), 20, .ray_white);
                    }
                    context.text(if (cards.round == cards.rules.quit_round) "> Leave" else "  Leave", 162, 116 + row(cards.rules.rounds.len, 35), 20, .ray_white);
                },
                .dealing, .play => {
                    for (0..cards.rules.rows) |r| for (0..cards.rules.columns) |c| {
                        const cell = cards.cells[cards_lib.KarutaSession.storage(@intCast(r), @intCast(c))];
                        const cursor = cards.phase == .play and r == cards.cursor_row and c == cards.cursor_column;
                        if (cell.state == .empty and !cursor) continue;
                        const x = 128 + row(c, 66);
                        const y = 106 + row(r, 33);
                        rl.drawRectangle(x, y, 51, 27, if (cursor) .gold else .dark_blue);
                        const show = switch (cell.state) {
                            .face_up, .flip_face_in, .flip_face_out, .matched_scale_in, .matched_scale_out, .matched_fade, .resolving => true,
                            else => false,
                        };
                        if (show and cell.face < cards.rules.faces) {
                            context.numberText("{d}", .{cell.face + 1}, x + 9, y + 4, 16, if (cursor) .black else .ray_white);
                        }
                    };
                    context.text("Find the matching pairs.", 92, 385, 17, .ray_white);
                },
                .proposal, .acknowledged => {
                    context.text("All pairs matched.", 108, 164, 22, .gold);
                    context.text(if (cards.consequence == .story_flag) "Confirm to return." else "Confirm to play again or Cancel to return.", 108, 300, 16, .ray_white);
                },
                .exited => {},
            }
        },
        .dice => unreachable,
    }
}

fn row(i: usize, spacing: i32) i32 {
    return @as(i32, @intCast(i)) * spacing;
}

pub fn drawDice(context: *const ui.Context, state: *const journey.State) void {
    const active = state.dice_game.?;
    const host = state.dice_host.?;
    const dice = host.session.?.dice;
    context.panel(72, 42, 496, 376);
    context.text("Dice", 92, 58, 25, .gold);
    context.numberText("{d} bits", .{host.wallet.money}, 414, 62, 18, .ray_white);
    if (active.plain_wait != 0) {
        const roll = dice.last_roll.?;
        context.numberText("Dice  {d}    {d}    {d}", .{ roll.faces[0], roll.faces[1], roll.faces[2] }, 166, 156, 28, .ray_white);
        if (roll.score == 128) context.text("The dice left the bowl.", 166, 237, 17, .gold);
        return;
    }
    switch (dice.phase) {
        .fixed_prompt => {
            context.numberText("Wager {d} bits and roll?", .{dice.rules.fixedWager()}, 146, 145, 23, .ray_white);
            context.text("Confirm to play or Cancel to leave.", 146, 216, 17, .gold);
        },
        .wager, .confirm => {
            context.numberText("Wager    {d} bits", .{dice.wager}, 146, 145, 23, .ray_white);
            if (dice.phase == .confirm) {
                context.text("Confirm the wager or Cancel to change it.", 146, 216, 17, .gold);
            } else {
                context.numberText("Up/Down: change by {d}   Left/Right: change step", .{dice.increment()}, 116, 216, 16, .gold);
            }
            context.text(active.plain_message, 92, 366, 17, .gold);
        },
        .dealer_roll, .player_roll => {
            rl.drawRectangle(146, 175, 348, 60, .dark_blue);
            rl.drawRectangle(258, 175, 128, 60, .blue);
            if (dice.throw_control) |aim| {
                rl.drawRectangle(320 + (@as(i32, aim.horizontal_pixels) - 160) * 4, 182, 4, 46, .gold);
                if (dice.phase == .player_roll) context.numberText("Strength {d}", .{aim.strength}, 146, 264, 17, .ray_white);
            }
            context.text(if (dice.phase == .dealer_roll) "Dealer is rolling." else "Up/Down: strength    Confirm: roll", 146, 302, 18, .gold);
        },
        .tie_prompt => {
            context.text("Tie", 146, 145, 23, .ray_white);
            context.text("Confirm to roll again or Cancel to leave.", 146, 216, 17, .gold);
        },
        .proposal, .acknowledged => {
            context.text(if (dice.decision.?.outcome == .win) "You won." else "You lost this round.", 146, 145, 23, .ray_white);
            context.text(if (dice.entry.variant == .fixed or dice.consequence != .none or host.wallet.money < dice.rules.minimum_balance) "Confirm to return." else "Confirm to play again or Cancel to return.", 146, 216, 16, .gold);
        },
        .exited => {},
    }
}
