//! Ordinary mode inputs, forwarded to the accepted optional-game sessions.
//!
//! Every variant names the source-side action; there is no generic "advance"
//! that would silently skip an animation gate. A variant that does not belong
//! to the active game is refused (`WrongGameInput`).

const std = @import("std");
const game_contracts = @import("optional_game_contracts");

pub const Input = union(enum) {
    // dice / VB2
    wager_up,
    wager_down,
    wager_larger,
    wager_smaller,
    wager_confirm,
    cancel,
    start,
    score: u16,
    dice_tick: struct { buttons: game_contracts.DiceThrowButtons = .{} },
    replay_tie,
    exit_tie,
    exit,
    // COIN
    coin_select: i8,
    coin_admit,
    shuffle: bool,
    coin_move: i8,
    coin_commit,
    reveal_tick,
    coin_exit,
    // KARUTA
    karuta_select: i8,
    karuta_confirm_round,
    karuta_advance,
    karuta_move: struct { row: i8, column: i8 },
    karuta_confirm,
    karuta_exit,
};

pub fn applyDice(session: *game_contracts.DiceSession, input: Input) !void {
    switch (input) {
        .wager_up => try session.adjust(.up),
        .wager_down => try session.adjust(.down),
        .wager_larger => try session.adjust(.larger),
        .wager_smaller => try session.adjust(.smaller),
        .wager_confirm => try session.confirmWager(),
        .cancel => try session.cancel(),
        .start => {
            if (session.phase == .fixed_prompt) {
                try session.startFixed();
            } else {
                try session.start();
            }
        },
        .score => |value| try session.submitScore(value),
        .replay_tie => try session.replayTie(),
        .exit_tie => try session.exitTie(),
        .exit => try session.exit(),
        else => return error.WrongGameInput,
    }
}

pub fn applyCoin(session: *game_contracts.CoinSession, draws: *game_contracts.Draws, input: Input) !void {
    switch (input) {
        .coin_select => |delta| try session.select(delta),
        .coin_admit => try session.admit(),
        .shuffle => |ready| try session.shuffleStep(ready, draws),
        .coin_move => |delta| try session.moveChoice(delta),
        .coin_commit => try session.commitChoice(),
        .reveal_tick => _ = try session.advanceReveal(),
        .coin_exit => try session.exit(),
        else => return error.WrongGameInput,
    }
}

pub fn applyKaruta(session: *game_contracts.KarutaSession, draws: *game_contracts.Draws, eligible: *const [game_contracts.face_count]bool, input: Input) !void {
    switch (input) {
        .karuta_select => |delta| try session.selectRound(delta),
        .karuta_confirm_round => try session.confirmRound(eligible, draws),
        .karuta_advance => try session.advance(),
        .karuta_move => |move| try session.moveCursor(move.row, move.column),
        .karuta_confirm => try session.confirm(),
        .karuta_exit => try session.exit(),
        else => return error.WrongGameInput,
    }
}
