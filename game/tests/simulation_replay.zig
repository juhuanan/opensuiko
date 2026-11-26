//! Drive the same simulation boundary as the native frame loop from recorded inputs.
const std = @import("std");
const engine = @import("engine");
const journey = @import("journey");
const battle = @import("battle");
const field = @import("field");
const field_events = @import("field_events");

const scenario_schema = "suikoden-simulation-replay/1";
const trace_schema = "suikoden-simulation-trace/1";
const diagnostic_schema = "suikoden-simulation-trace/2";
const max_ticks = 100_000;

const World = struct {
    room: field.Package,
    battle: battle.Content,
    journey: journey.Data,
    items: field.items.Rules,
    inn: field.inn.Rules,
    opening: struct { hero: journey.opening.Hero, money: u32 },
    field_events: ?std.json.Value = null,
};

const Cue = struct { tick: u32, field: ?u16 = null, battle: ?u16 = null };
const Music = field.game_state.event_runtime.FieldMusic;
const Hash = std.crypto.hash.sha2.Sha256;

const Replay = struct {
    schema: []const u8,
    id: []const u8,
    seed: u64 = battle.trial_seed,
    steps: []const Step,

    const Step = struct {
        ticks: u32 = 1,
        input: struct {
            menu: @FieldType(journey.SimulationInput, "menu") = .{},
            combat: battle.Input = .{},
            dice: @FieldType(journey.SimulationInput, "dice") = .{},
            party: @FieldType(journey.SimulationInput, "party") = null,
        } = .{},
        checkpoint: ?[]const u8 = null,
    };

    fn validate(self: Replay, allocator: std.mem.Allocator, every_tick: bool) !void {
        if (!std.mem.eql(u8, self.schema, scenario_schema)) return error.UnsupportedReplaySchema;
        if (self.id.len == 0 or self.steps.len == 0 or self.steps[self.steps.len - 1].checkpoint == null)
            return error.InvalidReplay;
        var ids: std.StringHashMapUnmanaged(void) = .empty;
        defer ids.deinit(allocator);
        try ids.put(allocator, "initial", {});
        var total: u64 = 0;
        for (self.steps) |step| {
            total += step.ticks;
            if (step.ticks == 0 or total > max_ticks) return error.InvalidReplayTickCount;
            if (step.checkpoint) |id| {
                if (id.len == 0 or (every_tick and std.mem.startsWith(u8, id, "tick_"))) return error.InvalidReplayCheckpoint;
                const entry = try ids.getOrPut(allocator, id);
                if (entry.found_existing) return error.DuplicateReplayCheckpoint;
            }
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const every_tick = args.len == 4 and std.mem.eql(u8, args[3], "--every-tick");
    if (args.len != 3 and !every_tick) {
        std.debug.print("Usage: simulation-replay WORLD.json REPLAY.json [--every-tick]\n", .{});
        return error.InvalidArguments;
    }
    run(init.io, allocator, args[1], args[2], every_tick) catch |err| {
        std.debug.print("{s} ({s}): {s}\n", .{ args[2], args[1], @errorName(err) });
        std.process.exit(1);
    };
}

fn run(io: std.Io, allocator: std.mem.Allocator, world_path: []const u8, replay_path: []const u8, every_tick: bool) !void {
    const dir = std.Io.Dir.cwd();
    const replay_bytes = try dir.readFileAlloc(io, replay_path, allocator, .limited(2 * 1024 * 1024));
    const replay = try std.json.parseFromSliceLeaky(Replay, allocator, replay_bytes, .{});
    try replay.validate(allocator, every_tick);
    const world_bytes = try dir.readFileAlloc(io, world_path, allocator, .limited(16 * 1024 * 1024));
    const world = try std.json.parseFromSliceLeaky(World, allocator, world_bytes, .{});
    try world.inn.validate();

    var members: [6]battle.Member = undefined;
    var combat_backing: battle.State = undefined;
    var state = try engine.State.initOpening(world.room, world.journey, world.battle, world.items, world.inn, &members, &combat_backing, world.opening.hero, world.opening.money);
    defer state.releaseRestoredSave();
    state.combat.seed = replay.seed;
    state.combat.random = .init(replay.seed);
    if (world.field_events) |events| {
        const packet = try std.json.Stringify.valueAlloc(allocator, events, .{});
        state.room_battles = try field_events.BattleRooms.open(allocator, packet, state.package);
        state.seedFieldStoryDefaults();
        try state.validateScenePartyChanges();
        try state.initializeRoomVisit();
    }
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    var json: std.json.Stringify = .{ .writer = &stdout.interface, .options = .{ .whitespace = .indent_2 } };
    try json.beginObject();
    try json.objectField("schema");
    try json.write(if (every_tick) diagnostic_schema else trace_schema);
    try json.objectField("id");
    try json.write(replay.id);
    if (every_tick) {
        var world_digest: [Hash.digest_length]u8 = undefined;
        var replay_digest: [Hash.digest_length]u8 = undefined;
        Hash.hash(world_bytes, &world_digest, .{});
        Hash.hash(replay_bytes, &replay_digest, .{});
        try json.objectField("inputs");
        try json.write(.{
            .world_sha256 = &std.fmt.bytesToHex(world_digest, .lower),
            .replay_sha256 = &std.fmt.bytesToHex(replay_digest, .lower),
            .seed = replay.seed,
        });
    }
    try json.objectField("checkpoints");
    try json.beginArray();
    try checkpoint(&json, &state, "initial", 0, &.{}, every_tick, null);

    var tick: u32 = 0;
    var cues: std.ArrayList(Cue) = .empty;
    for (replay.steps) |step| {
        for (0..step.ticks) |offset| {
            tick += 1;
            const input: journey.SimulationInput = .{
                .menu = step.input.menu,
                .battle = step.input.combat,
                .dice = step.input.dice,
                .party = step.input.party orelse .{},
                .dice_music_ready = state.preTickDiceMusic(step.input.menu),
            };
            const update = state.advanceSimulation(input) catch |err| {
                std.debug.print("Simulation failed at tick {d} ({s}): {s}\n", .{ tick, @tagName(state.mode), @errorName(err) });
                return err;
            };
            if (update.field_music) |music| try state.completeFieldMusic(music);
            if (update.sounds.field) |cue| try cues.append(allocator, .{ .tick = tick, .field = cue });
            for (update.sounds.battle) |cue| try cues.append(allocator, .{ .tick = tick, .battle = cue.id });
            switch (update.effect) {
                .save, .load, .inspect_saves, .new_game => {
                    std.debug.print("Unsupported host effect at tick {d}: {s}\n", .{ tick, @tagName(update.effect) });
                    return error.UnsupportedReplayHostEffect;
                },
                else => {},
            }
            if (every_tick) {
                var name: [32]u8 = undefined;
                const label = if (offset + 1 == step.ticks) step.checkpoint else null;
                try checkpoint(&json, &state, label orelse try std.fmt.bufPrint(&name, "tick_{d}", .{tick}), tick, cues.items, true, update.field_music);
                cues.clearRetainingCapacity();
            }
        }
        if (!every_tick) if (step.checkpoint) |id| {
            try checkpoint(&json, &state, id, tick, cues.items, false, null);
            cues.clearRetainingCapacity();
        };
    }
    try json.endArray();
    try json.endObject();
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}

fn checkpoint(json: *std.json.Stringify, state: *const engine.State, id: []const u8, tick: u32, cues: []const Cue, every_tick: bool, music_request: ?Music) !void {
    const world = &state.field_state;
    const room = state.package.rooms[world.room];
    const combat = state.combat;
    const progress = state.progress();
    var flags: [std.meta.fieldNames(field.game_state.StoryFlag).len]field.game_state.StoryFlag = undefined;
    var flag_count: usize = 0;
    for (std.enums.values(field.game_state.StoryFlag)) |flag| {
        if (!progress.story.has(flag)) continue;
        flags[flag_count] = flag;
        flag_count += 1;
    }
    const Mark = struct { index: usize, value: u8 };
    var marks: [240]Mark = undefined;
    var mark_count: usize = 0;
    if (progress.story.scenario) |scenario| {
        for (scenario.scenario, 0..) |value, index| {
            if (value == 0) continue;
            marks[mark_count] = .{ .index = index, .value = value };
            mark_count += 1;
        }
    }

    const Member = struct {
        id: []const u8,
        hp: u16,
        status: field.game_state.Status,
        level: u8,
        experience: u32,
        formation_slot: usize,
        inventory: field.items.Inventory,
        rune_charges: [4]u16,
    };
    var party: [6]Member = undefined;
    for (progress.party, 0..) |member, i| {
        party[i] = .{
            .id = member.id,
            .hp = member.hp,
            .status = member.status,
            .level = member.level,
            .experience = member.experience,
            .formation_slot = combat.formationSlot(i),
            .inventory = member.inventory,
            .rune_charges = member.rune_charges,
        };
    }

    const Dialogue = struct { speaker: []const u8, page: usize, text: []const u8, revealed: usize, phase: []const u8 };
    const dialogue: ?Dialogue = if (world.dialogue) |d| blk: {
        const pages = d.pages(room);
        const text = if (d.page < pages.len) pages[d.page] else "";
        break :blk .{ .speaker = d.name(room), .page = d.page, .text = text, .revealed = d.revealedLength(text.len, world.scene_ticks), .phase = @tagName(d.phase) };
    } else null;

    const Battle = struct {
        encounter: []const u8,
        phase: battle.Phase,
        round: u32,
        menu_row: ?usize,
        enemy_hp: []const u16,
        reward_money: u32,
        drop: ?field.items.Stack,
    };
    const encounter: ?Battle = if (state.mode == .battle or state.mode == .defeat) .{
        .encounter = combat.content.encounters[combat.encounter].id,
        .phase = combat.phase,
        .round = combat.round,
        .menu_row = if (combat.phase == .battle_menu) combat.selection else null,
        .enemy_hp = combat.enemy_hp[0..combat.enemyCount()],
        .reward_money = combat.reward_money,
        .drop = combat.dropped_item,
    } else null;

    // Observe the next values without advancing the live random stream.
    var random = combat.random;
    const rng_probe = random.random();
    const next_random = [2]u32{ rng_probe.int(u32), rng_probe.int(u32) };
    const point = .{
        .id = id,
        .tick = tick,
        .elapsed_ticks = state.elapsed_ticks,
        .mode = state.mode,
        .room = room.id,
        .position = world.position(state.package),
        .facing = world.facing,
        .menu = .{ .phase = state.menu.phase, .command = if (state.menu.phase == .root) state.menu.selected else null },
        .dialogue = dialogue,
        .script = if (state.field_event) |event| if (event.session.instance) |instance| instance.program_id else null else null,
        .battle = encounter,
        .story_flags = flags[0..flag_count],
        .scenario_marks = marks[0..mark_count],
        .field_music = world.music,
        .sound_cues = cues,
        .money = progress.money,
        .party = party[0..progress.party.len],
        .next_random = next_random,
    };
    if (!every_tick) return json.write(point);
    try json.beginObject();
    inline for (comptime std.meta.fieldNames(@TypeOf(point))) |key| {
        try json.objectField(key);
        try json.write(@field(point, key));
    }
    try writeDiagnostics(json, state, music_request);
    try json.endObject();
}

const Actor = struct {
    side: enum { party, enemy },
    slot: usize,
    id: []const u8,

    fn fromIndex(combat: *const battle.State, index: usize) ?Actor {
        if (index < combat.partyCount()) return .{ .side = .party, .slot = index, .id = combat.progress.party[index].id };
        const enemy = index - combat.partyCount();
        if (enemy >= combat.enemyCount()) return null;
        return .{ .side = .enemy, .slot = enemy, .id = combat.enemy(enemy).id };
    }
};

fn writeDiagnostics(json: *std.json.Stringify, state: *const engine.State, music_request: ?Music) !void {
    const combat = state.combat;
    const world = &state.field_state;
    const in_combat = state.mode == .battle or state.mode == .defeat;
    var stats: [6]struct { max_hp: u16, stats: battle.Stats } = undefined;
    for (state.progress().party, 0..) |member, index| {
        stats[index] = .{ .max_hp = member.max_hp, .stats = combat.stats(index) };
    }
    try json.objectField("party_stats");
    try json.write(stats[0..state.progress().party.len]);

    const Instance = field.game_state.event_runtime.Instance;
    const instance: ?*const Instance = if (state.field_event) |event|
        if (event.session.instance) |*active| active else null
    else
        null;
    const Event = struct { instruction: u16, wait: ?field.game_state.event_runtime.Wait, pending_batch: bool };
    try json.objectField("event");
    try json.write(if (instance) |event| @as(?Event, .{
        .instruction = event.execution.pc,
        .wait = event.execution.wait,
        .pending_batch = event.pending != null,
    }) else null);

    const Request = std.meta.Tag(field_events.GameplayRequest);
    const request: ?Request = if (state.field_event) |event|
        if (event.session.queuedGameplayRequest()) |queued| std.meta.activeTag(queued) else null
    else
        null;
    try json.objectField("requests");
    try json.write(.{
        .script = request,
        .scripted_battle = if (state.scripted_battle) |fight| fight.request.id else null,
        .service = world.pending_service,
        .checkpoint = world.pending_checkpoint,
        .field_music = music_request,
        .party_selection = state.party_selection != null,
        .item_overload = state.item_overload != null,
        .dice = state.dice_game != null,
    });

    const Action = struct {
        kind: []const u8,
        actor: ?Actor,
        target: ?Actor,
        retargeted_from: ?Actor,
        amount: u32,
        critical: bool,
    };
    const action: ?Action = if (in_combat and combat.active != null) blk: {
        const active = combat.active.?;
        break :blk .{
            .kind = @tagName(active.kind),
            .actor = Actor.fromIndex(combat, active.actor),
            .target = Actor.fromIndex(combat, active.target),
            .retargeted_from = if (active.retargeted_from) |actor| Actor.fromIndex(combat, actor) else null,
            .amount = active.amount,
            .critical = active.critical,
        };
    } else null;
    const Command = struct { actor: ?Actor, target: ?Actor };
    const command: ?Command = if (in_combat) switch (combat.phase) {
        .command, .target, .rune_target, .item, .item_target, .spell, .spell_target, .unite_target => .{
            .actor = Actor.fromIndex(combat, combat.actor),
            .target = if (combat.selectedTargetActor()) |target| Actor.fromIndex(combat, target) else null,
        },
        else => null,
    } else null;
    try json.objectField("battle_resolution");
    const Resolution = struct { command: ?Command, action: ?Action, rewards_committed: bool, rewards_ready: bool };
    try json.write(if (in_combat) @as(?Resolution, .{
        .command = command,
        .action = action,
        .rewards_committed = combat.rewards_committed,
        .rewards_ready = combat.phase == .victory and combat.rewardReady(),
    }) else null);
}
