//! Journey ownership of the source fixed-game request and its atomic return.
const State = @import("journey.zig").State;
const field = @import("field");
const std = @import("std");
const battle = @import("battle");
const events = @import("field_events");
const pause = @import("pause_menu");
pub const games = @import("hq").optional_games;
pub const visual = @import("dice_presentation");
pub const Entry = @import("dice_entry.zig");
pub const Result = @import("dice_result.zig");

const Before = struct {
    money: u32,
    random: std.Random.DefaultPrng,
    save_counter: u32,
    flags: games.settle.DiceFlags,
};

pub const Hud = struct { wager: u32, balance: u32 };

pub const Active = struct {
    receipt: events.Receipt,
    entry: Entry = .{},
    dialogue: Entry.Dialogue = .{},
    result: ?Result = null,
    rolling_side: ?games.contracts.DiceSide = null,
    entry_audio_ready: bool = false,
    pending_exit: bool = false,
    exit_ready: bool = false,
    before: Before,
    payout: ?games.contracts.DicePayout = null,
    poses: [3]visual.Pose,
    frame: ?visual.Frame = null,
    animation: ?visual.Animation = null,
    aim_started: bool = false,
    hud: ?Hud = null,
    cursor: ?visual.Cursor = null,
    plain_wait: u8 = 0,
    plain_message: []const u8 = "",
};
pub const Input = union(enum) {
    entry_audio_ready,
    entry_tick: Entry.Controls,
    result_tick: Entry.Controls,
    exit_ready,
    start,
    dice_tick: struct { buttons: games.contracts.DiceThrowButtons = .{} },
    replay_tie,
    exit_tie,
    payout_tick: bool,
    animation_tick,
};

pub const AudioEvents = struct {
    landings: u2 = 0,
    box_opened: bool = false,
    won: bool = false,
};

pub fn advanceFrame(state: *State, menu_input: pause.Input, controls: Entry.Controls, audio: anytype) !AudioEvents {
    var cues: AudioEvents = .{};
    if (!usesModel(state)) {
        try tickPlain(state, menu_input);
    } else if (comptime @TypeOf(audio) != @TypeOf(null)) {
        cues = try advanceModel(state, controls, audio);
    }
    state.elapsed_ticks +|= 1;
    return cues;
}

fn advanceModel(state: *State, controls: Entry.Controls, audio: anytype) !AudioEvents {
    const active = state.dice_game.?;
    var cues: AudioEvents = .{};
    if (!active.entry_audio_ready) {
        try audio.requestDiceMusic(.dice);
        try tick(state, .entry_audio_ready);
    } else if (active.pending_exit and !active.exit_ready) {
        try audio.requestDiceMusic(.dice);
        try tick(state, .exit_ready);
    } else {
        if (active.pending_exit and active.exit_ready) try audio.requestDiceMusic(.area_b);
        try tickFrame(state, controls);
        if (active.animation != null) {
            const frame = state.dice_game.?.frame.?;
            for (frame.landed) |landed| cues.landings += @intFromBool(landed);
        }
    }
    if (state.dice_game) |next| {
        cues.box_opened = active.dialogue.phase == .allocate and next.dialogue.phase == .opening;
        if (active.result) |report| {
            const advanced = if (next.result) |result| result.cursor != report.cursor else true;
            const session = state.dice_host.?.session.?.dice;
            cues.won = report.hand_report and report.cursor == 0 and advanced and
                session.phase == .proposal and session.decision.?.outcome == .win;
        }
    }
    return cues;
}

pub fn usesModel(state: *const State) bool {
    return state.dice_model != null and state.dice_host.?.session.?.dice.entry.variant == .fixed;
}

fn facts(state: *const State) !Before {
    const story = state.combat.progress.story.scenario orelse return error.MissingSourceStoryState;
    return .{
        .money = state.combat.progress.money,
        .random = state.combat.random,
        .save_counter = story.save_counter,
        .flags = .{ .fixed_won = story.scenario[12] & 1 != 0, .profit_goal = story.scenario[194] & 2 != 0 },
    };
}

fn validateField(state: *const State) !void {
    const owner = state.field_event orelse return error.MissingFieldDiceRequest;
    if (!std.mem.eql(u8, owner.binding.room, state.package.rooms[state.field_state.room].id) or
        owner.session.hero.x != state.field_state.x or owner.session.hero.y != state.field_state.y) return error.ScriptedDiceFieldMismatch;
    try owner.session.validate(owner.binding.*);
}

pub fn begin(state: *State) !void {
    if (state.mode != .field or state.dice_game != null or state.menu.phase != .closed) return error.GameBusy;
    const owner = state.field_event orelse return error.MissingFieldDiceRequest;
    const receipt = owner.session.queuedFixedDice() orelse return error.MissingFieldDiceRequest;
    const host = state.dice_host orelse return error.MissingJourneyDiceHost;
    const packet = state.dice_model;
    if (packet) |model| try model.validate();
    if (host.ownsFrame()) return error.ModeAlreadyOwned;
    try validateField(state);
    const before = try facts(state);
    const family = try host.ledger.requireFamily(.dice);
    const source = owner.binding.population.source;
    const program = owner.binding.content.program(receipt.program) orelse return error.UnknownEventProgram;
    const digest = try games.types.parseHex32(source.sha256);
    if (!std.mem.eql(u8, source.file, family.overlay.path) or source.lba != family.overlay.lba or
        source.size != family.overlay.size or !std.mem.eql(u8, &digest, &family.overlay.sha256)) return error.UnknownCaller;
    const caller = for (family.callers) |entry| {
        if (source.room == entry.room and program.entity == entry.entity) break entry;
    } else return error.UnknownCaller;
    const variant: games.contracts.DiceVariant = @fromBackingInt(@intCast(caller.dice_variant orelse return error.UnknownDiceVariant));
    var next = host.*;
    next.wallet = .{ .money = before.money, .save_counter = before.save_counter, .dice_flags = before.flags };
    // shortcut: use Journey's native RNG until campaign BIOS stream ownership is bound.
    next.draws = .{ .prng = before.random };
    const identity = std.hash.Wyhash.hash(0, receipt.content_sha256);
    next.admit(.{
        .game = .dice,
        .caller_site = caller.site,
        .revision = next.wallet.revision,
        .entry = .{ .dice = .{
            .entry_id = receipt.instance,
            .content_id = if (identity == 0) 1 else identity,
            .receipt_id = receipt.batch,
            .balance = before.money,
            .variant = variant,
            .baseline = if (variant == .profit) before.money else null,
        } },
    }) catch |err| {
        if (err != error.InsufficientFunds) return err;
        try owner.session.resumeFixedDice(owner.binding.*, &state.field_state, receipt);
        state.menu.notify("You do not have enough bits to play dice.");
        return;
    };
    host.* = next;
    state.dice_game = .{
        .receipt = receipt,
        .before = before,
        .poses = if (packet) |model| model.initial_poses else @splat(.{ .center_x = 0, .center_y = 0, .angles = @splat(0) }),
    };
}

fn validateOwner(state: *const State) !Active {
    const active = state.dice_game orelse return error.MissingFieldDiceRequest;
    const owner = state.field_event orelse return error.MissingFieldDiceRequest;
    const host = state.dice_host orelse return error.MissingJourneyDiceHost;
    try validateField(state);
    if (state.mode != .field or !host.ownsFrame() or host.session == null or host.session.? != .dice) return error.InvalidJourneyDiceOwner;
    const pending = owner.session.queuedFixedDice() orelse return error.InvalidFieldDiceReceipt;
    if (!events.semanticEqual(active.receipt, pending)) return error.InvalidFieldDiceReceipt;
    if (!std.meta.eql(active.before, try facts(state))) return error.StaleJourneyDiceState;
    return active;
}

pub fn tick(state: *State, input: Input) !void {
    var active = try validateOwner(state);
    const host = state.dice_host.?;
    const packet = state.dice_model orelse return error.MissingDiceModel;
    var next = host.*;
    if (!active.entry_audio_ready and input != .entry_audio_ready) return error.PendingDiceEntryAudio;
    if (active.animation != null and input != .animation_tick) return error.PendingDiceAnimation;
    if (active.result != null and input != .result_tick) return error.PendingDiceResultText;
    if (active.pending_exit and input != .exit_ready) return error.PendingDiceExit;
    if (input != .entry_audio_ready and input != .exit_ready) {
        const session = next.session.?.dice;
        active.hud = if (active.payout) |payout| .{ .wager = payout.remaining_wager, .balance = payout.balance } else .{ .wager = session.wager, .balance = session.entry.balance };
    }
    switch (input) {
        .entry_audio_ready => active.entry_audio_ready = true,
        .entry_tick => |controls| {
            if (next.session.?.dice.phase != .fixed_prompt) return error.InvalidPhase;
            try active.dialogue.tick(&active.entry, packet.*, controls, @backingInt(state.field_event.?.session.text_speed), "");
            if (active.dialogue.phase == .finished) {
                active.result = .{ .action = .start };
                active.dialogue = .{};
            }
        },
        .result_tick => |controls| {
            active.cursor = null;
            var result = active.result orelse return error.MissingDiceResultText;
            if (!result.finished()) {
                const owner = state.field_event.?;
                const name = owner.binding.player_name orelse return error.MissingSourcePartyIdentity;
                try active.dialogue.tick(&result, packet.*, controls, @backingInt(owner.session.text_speed), name);
                if (result.hand_report and result.cursor != 0) active.frame = null;
            }
            if (result.finished()) {
                active.result = null;
                active.dialogue = .{};
                switch (result.action) {
                    .start => try next.tick(.start),
                    .resume_roll => {},
                    .payout => active.frame = .{ .poses = active.poses },
                    .replay => {
                        try next.tick(.replay_tie);
                        try next.tick(.start);
                        active.frame = null;
                    },
                    .exit_wait => active.pending_exit = true,
                }
            } else active.result = result;
        },
        .exit_ready => {
            if (!active.pending_exit) return error.PendingDiceExit;
            active.exit_ready = true;
            active.hud = null;
            active.cursor = null;
        },
        .start => {
            if (active.entry.message != .ready or active.dialogue.phase != .finished) return error.PendingDiceEntry;
            try next.tick(.start);
        },
        .dice_tick => |frame| {
            if (active.pending_exit) return error.PendingDiceExit;
            active.rolling_side = next.session.?.dice.side() orelse return error.InvalidPhase;
            try next.tick(.{ .dice_tick = .{ .buttons = frame.buttons } });
            const session = next.session.?.dice;
            const control = session.throw_control orelse session.last_release orelse return error.MissingDiceThrowControl;
            active.cursor = .{ .x = control.horizontal_pixels, .y = control.vertical_pixels };
            if (!active.aim_started) active.poses = packet.initial_poses;
            for (&active.poses, 0..) |*pose, index| visual.spin(pose, @intCast(control.strength), index);
            active.aim_started = true;
            active.frame = .{ .poses = active.poses };
            if (control.finished) {
                const roll = session.last_roll orelse return error.MissingDiceRoll;
                active.animation = try visual.Animation.init(packet.*, .{
                    .poses = active.poses,
                    .pips = roll.faces,
                    .target_x = control.horizontal_pixels,
                    .target_y = control.vertical_pixels,
                    .strength = control.strength,
                    .escaped = roll.score == 128,
                });
            }
        },
        .animation_tick => {
            const animation = if (active.animation) |*value| value else return error.MissingDiceAnimation;
            active.frame = animation.tick();
            active.poses = animation.poses();
            if (animation.complete) {
                active.animation = null;
                active.aim_started = false;
                active.result = try Result.init(next.session.?.dice, active.rolling_side orelse return error.MissingDiceThrowSide);
                active.dialogue = .{};
            }
        },
        .replay_tie => try next.tick(.replay_tie),
        .exit_tie => try next.tick(.exit_tie),
        .payout_tick => |confirm| {
            const session = next.session.?.dice;
            if (session.phase != .proposal) return error.InvalidPhase;
            var payout = active.payout orelse try games.contracts.DicePayout.init(try session.propose(), session.rules.balance_cap);
            payout.tick(confirm);
            active.payout = payout;
            if (payout.complete) {
                const continuation = Result.afterPayout(payout.balance);
                active.result = if (continuation.finished()) null else continuation;
                active.pending_exit = continuation.finished();
                active.dialogue = .{};
                active.frame = null;
            }
        },
    }
    host.* = next;
    state.dice_game = active;
}

pub fn finish(state: *State) !void {
    const active = try validateOwner(state);
    if (active.animation != null) return error.PendingDiceAnimation;
    if (active.result != null) return error.PendingDiceResultText;
    if (!active.exit_ready) return error.PendingDiceExit;
    const owner = state.field_event.?;
    const host = state.dice_host.?;
    var next_host = host.*;
    switch (next_host.session.?.dice.phase) {
        .proposal => {
            const payout = active.payout orelse return error.PendingDicePayout;
            const result = try next_host.session.?.dice.propose();
            if (!payout.complete or payout.balance != result.after_balance) return error.PendingDicePayout;
            _ = try next_host.settleMode();
        },
        .exited, .acknowledged => {},
        else => return error.PendingSettlement,
    }
    try next_host.finish();
    var next_event = owner.session.*;
    var members: [6]battle.Member = undefined;
    var draft: field.game_state.Progress = undefined;
    var next_field = state.stageField(&draft, &members);
    next_field.progress.money = next_host.wallet.money;
    if (usesModel(state)) next_field.music = .area_b;
    if (next_host.wallet.dice_flags.fixed_won) next_field.progress.story.scenario.?.scenario[12] |= 1;
    if (next_host.wallet.dice_flags.profit_goal) next_field.progress.story.scenario.?.scenario[194] |= 2;
    try next_field.progress.validate();
    const random = next_host.draws.prng orelse return error.InvalidRandomSource;
    try next_event.resumeFixedDice(owner.binding.*, &next_field, active.receipt);
    owner.session.* = next_event;
    state.commitFieldTransaction(next_field);
    state.combat.random = random;
    host.* = next_host;
    state.dice_game = null;
}

fn tickPlain(state: *State, input: pause.Input) !void {
    var active = try validateOwner(state);
    const host = state.dice_host.?;
    var next = host.*;
    const session = next.session.?.dice;
    if (active.plain_wait != 0) {
        active.plain_wait -= 1;
        state.dice_game = active;
        return;
    }
    const action = input.field.action;
    const cancel = input.field.cancel;
    const up = input.field.menu_direction == .up;
    const down = input.field.menu_direction == .down;
    switch (session.phase) {
        .fixed_prompt => if (cancel) {
            try next.tick(.exit);
        } else if (action) {
            try next.tick(.start);
        },
        .wager => if (cancel) {
            try next.tick(.cancel);
        } else if (up) {
            try next.tick(.wager_up);
        } else if (down) {
            try next.tick(.wager_down);
        } else if (input.left or input.right) {
            try next.tick(.wager_larger);
        } else if (action) {
            try next.tick(.wager_confirm);
        },
        .confirm => if (cancel) {
            try next.tick(.cancel);
        } else if (action) {
            next.tick(.start) catch |err| switch (err) {
                error.ZeroWager => active.plain_message = "Choose a wager first.",
                error.InsufficientFunds => active.plain_message = "That wager is above your balance.",
                else => return err,
            };
            if (next.session.?.dice.phase == .confirm) try next.tick(.cancel);
        },
        .dealer_roll, .player_roll => {
            active.plain_message = "";
            try next.tick(.{ .dice_tick = .{ .buttons = .{ .confirm = action, .up = up, .down = down } } });
            if (next.session.?.dice.last_release != null) active.plain_wait = 45;
        },
        .tie_prompt => if (cancel) {
            try next.tick(.exit_tie);
        } else if (action) {
            try next.tick(.replay_tie);
        },
        .proposal => _ = try next.settleMode(),
        .acknowledged => if (cancel or (action and (session.entry.variant == .fixed or
            session.consequence != .none or next.wallet.money < session.rules.minimum_balance)))
        {
            active.exit_ready = true;
        } else if (action) {
            if (next.wallet.receipt_count == games.host.max_receipts) next.wallet.receipt_count = 0;
            try next.nextRound(try std.math.add(u64, session.entry.receipt_id, 1));
        },
        .exited => {},
    }
    if (next.session.?.dice.phase == .exited) active.exit_ready = true;
    host.* = next;
    state.dice_game = active;
    if (active.exit_ready) try finish(state);
}

fn tickFrame(state: *State, input: Entry.Controls) !void {
    const active = try validateOwner(state);
    if (!active.entry_audio_ready) return;
    if (active.animation != null) return tick(state, .animation_tick);
    const phase = state.dice_host.?.session.?.dice.phase;
    if (active.result != null) return tick(state, .{ .result_tick = input });
    if (active.pending_exit) {
        if (active.exit_ready) try finish(state);
        return;
    }
    if (phase == .fixed_prompt) {
        return tick(state, .{ .entry_tick = input });
    }
    if (phase == .proposal) return tick(state, .{ .payout_tick = input.pressed.confirm or input.pressed.triangle });
    if (phase == .dealer_roll or phase == .player_roll) return tick(state, .{ .dice_tick = .{ .buttons = .{
        .up = input.pressed.up,
        .down = input.pressed.down,
        .left = input.pressed.left,
        .right = input.pressed.right,
        .confirm = input.pressed.confirm,
        .alternate_confirm = input.pressed.cancel,
        .other = input.pressed.triangle or input.pressed.square,
    } } });
}
