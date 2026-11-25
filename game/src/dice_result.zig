//! Fixed-game hand reports and continuations after a throw has settled.
const contracts = @import("hq").optional_games.contracts;
const Entry = @import("dice_entry.zig");
const visual = @import("dice_presentation");
const audience = @import("opening").audience;

pub const Message = union(enum) {
    player_hand: u3,
    dealer_hand: u3,
    escaped,
    straight_receive,
    straight_pay,
    storm_pay,
    storm_receive,
    zero_score,
    player_turn,
    dealer_turn,
    farewell,
    player_win,
    dealer_win,
    draw,
    bankrupt,
    tie_notice,
    player_straight_pay,
    player_straight_receive,
};
pub const Action = enum { start, resume_roll, payout, replay, exit_wait };
messages: [4]Message = @splat(.dealer_turn),
length: u3 = 1,
cursor: u3 = 0,
action: Action,
hand_report: bool = false,
text_ready: bool = false,
close_requested: bool = false,

pub fn init(session: contracts.DiceSession, side: contracts.DiceSide) !@This() {
    try session.validate();
    if (session.entry.variant != .fixed) return error.WrongDiceVariant;
    const roll = session.last_roll orelse return error.MissingDiceRoll;
    var flow: @This() = .{ .action = .resume_roll, .hand_report = true };
    flow.messages[0] = try report(side, roll);
    switch (session.phase) {
        .dealer_roll, .player_roll => {
            flow.messages[1] = if (session.phase == .dealer_roll) .dealer_turn else .player_turn;
            flow.length = 2;
        },
        .proposal => {
            flow.action = .payout;
            if (roll.score <= 6) {
                const decision = session.decision orelse return error.MissingDiceDecision;
                flow.messages[1] = if (decision.outcome == .win) .player_win else .dealer_win;
                flow.length = 2;
            }
        },
        .tie_prompt => {
            flow.messages[1] = .draw;
            flow.messages[2] = .tie_notice;
            flow.messages[3] = .dealer_turn;
            flow.length = 4;
            flow.action = .replay;
        },
        else => return error.InvalidPhase,
    }
    return flow;
}

pub fn report(side: contracts.DiceSide, roll: contracts.DiceRoll) !Message {
    if (roll.score >= 1 and roll.score <= 6) return if (side == .dealer)
        .{ .dealer_hand = @intCast(roll.score - 1) }
    else
        .{ .player_hand = @intCast(roll.score - 1) };
    // The natural-face classifier retains its literal source wording for both sides.
    const forced_player = roll.forced and side == .player;
    return switch (roll.score) {
        0 => .zero_score,
        8 => if (forced_player) .storm_receive else .storm_pay,
        16 => if (forced_player) .storm_pay else .storm_receive,
        32 => if (forced_player) .player_straight_receive else .straight_pay,
        64 => if (forced_player) .player_straight_pay else .straight_receive,
        128 => .escaped,
        else => error.InvalidScore,
    };
}

pub fn afterPayout(balance: u32) @This() {
    return if (balance == 0) .{ .action = .exit_wait, .messages = .{ .bankrupt, .farewell, .farewell, .farewell }, .length = 2 } else .{ .action = .exit_wait, .length = 0 };
}

pub fn finished(self: @This()) bool {
    return self.cursor == self.length;
}

pub fn choicesAvailable(_: @This()) bool {
    return false;
}

pub fn acceptsDirections(_: @This()) bool {
    return false;
}

pub fn update(self: *@This(), input: Entry.Input) !void {
    if (self.finished()) return error.DiceResultComplete;
    switch (input) {
        .text_ready => self.text_ready = true,
        .text_closed => {
            if (!self.close_requested or !self.text_ready) return error.PendingDiceText;
            self.cursor += 1;
            self.text_ready = false;
            self.close_requested = false;
        },
        .up, .down => {},
        .confirm, .cancel => self.close_requested = true,
    }
}

pub fn textFor(self: @This(), packet: visual.Packet) !audience.Text {
    if (self.finished()) return error.DiceResultComplete;
    return switch (self.messages[self.cursor]) {
        .player_hand => |pip| packet.result_messages.player_hands[pip],
        .dealer_hand => |pip| packet.result_messages.dealer_hands[pip],
        inline else => |_, tag| @field(packet.result_messages, @tagName(tag)),
    };
}
