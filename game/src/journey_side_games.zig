//! Field admission and settlement for the cup and matching-card games.
const State = @import("journey.zig").State;
const std = @import("std");
const events = @import("field_events");
const pause = @import("pause_menu");
const games = @import("journey_dice.zig").games;
const Service = @import("field").game_state.event_runtime.FieldService;

pub const shuffle_frames: u8 = 12;
const mode_status_start = 160;
pub const Records = struct {
    cup_profit: i32 = 0,
    card_records: [4]u32 = @splat(0),
};

pub const Active = struct {
    shuffle_ticks: u8 = 0,
    message: []const u8 = "",
};

pub fn caller(host: games.Host, binding: events.Binding, entity: u16, service: Service) !games.Caller {
    const game: games.Game = switch (service) {
        .cup_game => .coin,
        .card_game => .karuta,
        else => return error.UnknownOptionalGame,
    };
    const family = try host.ledger.requireFamily(game);
    const source = binding.population.source;
    for (family.callers) |candidate| {
        if (candidate.room == source.room and candidate.entity == entity and
            std.mem.eql(u8, candidate.path, source.file) and
            std.mem.eql(u8, candidate.sha256, source.sha256)) return candidate;
    }
    return error.UnknownCaller;
}

pub fn begin(state: *State, binding: events.Binding, receipt: events.Receipt, service: Service) !void {
    const program = binding.content.program(receipt.program) orelse return error.MissingFieldGameRequest;
    const host = state.dice_host orelse return error.MissingOptionalGameHost;
    if (host.ownsFrame()) return error.ModeAlreadyOwned;
    const source = try caller(host.*, binding, program.entity, service);
    const identity = @max(1, std.hash.Wyhash.hash(0, receipt.content_sha256));
    const progress = state.optional_games;
    const money = state.combat.progress.money;
    const story = state.combat.progress.story.scenario orelse return error.MissingSourceStoryState;
    const status = story.scenario[mode_status_start..][0..games.settle.status_bytes].*;
    const flags = std.mem.readInt(u32, status[0..4], .little);
    const entry: games.host.Entry = switch (service) {
        .cup_game => .{ .coin = .{
            .entry_id = receipt.instance,
            .content_id = identity,
            .receipt_id = receipt.batch,
            .balance = money,
            .net = progress.cup_profit,
            .difficulty = 0,
            .flags = flags,
        } },
        .card_game => .{ .karuta = .{
            .entry_id = receipt.instance,
            .content_id = identity,
            .receipt_id = receipt.batch,
            .balance = money,
            .best = progress.card_records,
            .round = 0,
            .flags = flags,
        } },
        else => unreachable,
    };
    var next = host.*;
    next.wallet = .{ .money = money, .net = progress.cup_profit, .best = progress.card_records, .status = status };
    next.draws = .{ .prng = state.combat.random };
    try next.admit(.{
        .game = std.meta.activeTag(entry),
        .entry = entry,
        .caller_site = source.site,
        .revision = next.wallet.revision,
        // The authored board uses numbered pairs, so all symbols can be dealt.
        .karuta_eligible = if (service == .card_game) @splat(true) else null,
    });
    host.* = next;
    state.side_game = .{};
}

pub fn tick(state: *State, input: pause.Input) !void {
    const host = state.dice_host orelse return error.MissingOptionalGameHost;
    var next = host.*;
    var active = state.side_game.?;
    const session = next.session orelse return error.MissingOptionalGame;
    const x: i8 = @as(i8, @intFromBool(input.right)) - @as(i8, @intFromBool(input.left));
    const y: i8 = @as(i8, @intFromBool(input.field.menu_direction == .down)) - @as(i8, @intFromBool(input.field.menu_direction == .up));
    const confirm = input.field.action;
    const cancel = input.field.cancel;
    var settle = false;
    var finish = false;
    var replay: ?u64 = null;
    switch (session) {
        .coin => |coin| switch (coin.phase) {
            .select => if (cancel) {
                try next.tick(.coin_exit);
                finish = true;
            } else if (x != 0 or y != 0) {
                active.message = "";
                try next.tick(.{ .coin_select = if (y != 0) y else x });
            } else if (confirm) {
                next.tick(.coin_admit) catch |err| switch (err) {
                    error.InsufficientFunds => {
                        state.side_game.?.message = "You do not have enough bits for that wager.";
                        return;
                    },
                    else => return err,
                };
                active.message = "";
                finish = next.session.?.coin.phase == .exited;
            },
            .shuffling => {
                active.shuffle_ticks += 1;
                if (active.shuffle_ticks == shuffle_frames) {
                    active.shuffle_ticks = 0;
                    try next.tick(.{ .shuffle = true });
                }
            },
            .choice => if (active.shuffle_ticks < shuffle_frames) {
                active.shuffle_ticks += 1;
            } else if (x != 0 or y != 0) {
                try next.tick(.{ .coin_move = if (x != 0) x else y });
            } else if (confirm) {
                try next.tick(.coin_commit);
            },
            .reveal => try next.tick(.reveal_tick),
            .proposal => settle = true,
            .acknowledged => if (cancel or (confirm and coin.consequence == .profit_flag)) {
                finish = true;
            } else if (confirm) {
                replay = coin.receipt_id;
            },
            .exited => finish = true,
        },
        .karuta => |cards| switch (cards.phase) {
            .select => if (cancel) {
                try next.tick(.karuta_exit);
                finish = true;
            } else if (x != 0 or y != 0) {
                try next.tick(.{ .karuta_select = if (y != 0) y else x });
            } else if (confirm) {
                try next.tick(.karuta_confirm_round);
                finish = next.session.?.karuta.phase == .exited;
            },
            .dealing, .play => if (cancel) {
                try next.tick(.karuta_exit);
                finish = true;
            } else {
                if (cards.phase == .play and cards.boardStable()) {
                    if (x != 0 or y != 0) try next.tick(.{ .karuta_move = .{ .row = y, .column = x } });
                    if (confirm) next.tick(.karuta_confirm) catch |err| switch (err) {
                        error.CellNotSelectable => {},
                        else => return err,
                    };
                }
                try next.tick(.karuta_advance);
            },
            .proposal => settle = true,
            .acknowledged => if (cancel or (confirm and cards.consequence == .story_flag)) {
                finish = true;
            } else if (confirm) {
                replay = cards.receipt_id;
            },
            .exited => finish = true,
        },
        .dice => return error.WrongGameInput,
    }
    if (replay) |receipt| {
        // last_receipt rejects earlier results after the in-session receipt window fills.
        if (next.wallet.receipt_count == games.host.max_receipts) next.wallet.receipt_count = 0;
        try next.nextRound(try std.math.add(u64, receipt, 1));
    }
    if (settle) _ = try next.settleMode();
    if (settle or finish) {
        const random = next.draws.prng orelse return error.InvalidRandomSource;
        if (finish) try next.finish();
        state.combat.progress.money = next.wallet.money;
        state.combat.random = random;
        state.optional_games.cup_profit = next.wallet.net;
        state.optional_games.card_records = next.wallet.best;
        if (settle) {
            const status = state.combat.progress.story.scenario.?.scenario[mode_status_start..][0..games.settle.status_bytes];
            for (status, next.wallet.status) |*current, result| current.* |= result;
        }
    }
    host.* = next;
    state.side_game = if (finish) null else active;
}
