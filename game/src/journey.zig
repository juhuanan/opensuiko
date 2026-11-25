const std = @import("std");
const item_ledger = @import("item_ledger");
pub const opening = @import("opening");
pub const field_dialogue_view = @import("field_dialogue_view.zig");
pub const opening_events = @import("opening_events");
pub const opening_route = @import("route");
const save_data = @import("journey_save.zig");
const roster = @import("journey_roster.zig");
const battle_flow = @import("journey_battle.zig");
pub const dice = @import("journey_dice.zig");
pub const side_games = @import("journey_side_games.zig");
pub const overload = @import("journey_overload.zig");
pub const party_selection = @import("journey_party.zig");
pub const party_selector_view = @import("party_selector_view.zig");
pub const travel = @import("journey_travel");
const party_session = @import("party_session");
const field = @import("field");
const field_events = @import("field_events");
pub const RoomActorDraw = field_events.BattleRooms.ActorDraw;
const battle = @import("battle");
const pause = @import("pause_menu");
const campaign_state = @import("campaign_state");
const hq_state = @import("hq_state");
pub const duel = @import("duel");
pub const war = @import("war");
pub const war_session = @import("war_session");
pub const chapters = @import("chapters");
const Flag = field.game_state.StoryFlag;
pub const recruitment = @import("recruitment");

const dispatch = @import("journey/dispatch.zig");
const events_host = @import("journey/events_host.zig");
const exploration = @import("journey/exploration.zig");
const modes = @import("journey/modes.zig");
const progress_owner = @import("journey/progress.zig");

pub const Trigger = struct { id: []const u8, room: []const u8, x: i32, y: i32, w: i32, h: i32, encounter: []const u8, flag: Flag };
pub const Treasure = struct { npc: []const u8, room: []const u8, item: field.items.Id, uses: u16, flag: Flag };
pub const Data = struct {
    pub const max_file_size = 2 * 1024 * 1024;

    schema: []const u8,
    title: []const u8,
    battle: []const u8,
    encounters: []const Trigger,
    treasures: []const Treasure,
    recruitment: ?recruitment.Definition = null,
    field_encounters: ?battle_flow.FieldEncounters = null,

    pub fn validate(self: Data, package: field.Package, content: battle.Content) !void {
        const canonical = std.mem.eql(u8, self.schema, "suikoden-journey/3");
        if ((!std.mem.eql(u8, self.schema, "suikoden-journey/1") and !std.mem.eql(u8, self.schema, "suikoden-journey/2") and !canonical) or !std.mem.eql(u8, self.battle, "battle/trial.json")) return error.InvalidJourney;
        if (std.mem.eql(u8, self.schema, "suikoden-journey/2") and self.recruitment == null) return error.MissingRecruitmentData;
        if (self.title.len == 0 or self.title.len > 80 or (!canonical and self.encounters.len == 0 and self.field_encounters == null) or self.encounters.len > 32 or self.treasures.len > 32) return error.InvalidJourney;
        if (self.field_encounters) |configured| try configured.validate(package, content);
        for (self.encounters, 0..) |trigger, i| {
            const room = package.rooms[package.roomIndex(trigger.room) orelse return error.UnknownRoom];
            if (trigger.id.len == 0 or trigger.x < 0 or trigger.y < 0 or trigger.w <= 0 or trigger.h <= 0 or trigger.x > room.width - trigger.w or trigger.y > room.height - trigger.h) return error.InvalidTrigger;
            if (battle_flow.encounterIndex(content, trigger.encounter) == null) return error.UnknownEncounter;
            for (self.encounters[0..i]) |other| if (std.mem.eql(u8, trigger.id, other.id) or trigger.flag == other.flag) return error.InvalidTrigger;
        }
        for (self.treasures, 0..) |treasure, i| {
            const room = package.rooms[package.roomIndex(treasure.room) orelse return error.UnknownRoom];
            if (treasure.uses != treasure.item.maxUses()) return error.InvalidTreasure;
            var found = false;
            for (room.npcs) |npc| if (std.mem.eql(u8, npc.id, treasure.npc) and npc.hidden_by == treasure.flag) {
                found = true;
            };
            if (!found) return error.UnknownTreasure;
            for (self.treasures[0..i]) |other| if (treasure.flag == other.flag) return error.InvalidTreasure;
        }
        if (self.recruitment) |definition| {
            const room = package.rooms[package.roomIndex("vb6_blacksmith") orelse return error.UnknownRoom];
            var found = false;
            for (room.npcs) |npc| if (std.mem.eql(u8, npc.id, definition.member)) {
                if (npc.recruitment == null or npc.minimum_recruitment_tier != definition.minimum_tier or npc.hidden_by != .maas_recruited or npc.absent_by != .maas_recruitment_blocked) return error.InvalidRecruitment;
                found = true;
            };
            if (!found) return error.InvalidRecruitment;
        }
    }
};
pub fn load(allocator: std.mem.Allocator, bytes: []const u8, package: field.Package, content: battle.Content) !std.json.Parsed(Data) {
    if (bytes.len > Data.max_file_size) return error.JourneyTooLarge;
    const parsed = try std.json.parseFromSlice(Data, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate(package, content);
    return parsed;
}
pub const Mode = enum { field, battle, duel, war, ending, defeat, game_over };
pub const TickSounds = struct {
    field: ?u16,
    party_window_count: u8,
    battle: []const battle.unite_playback.Sound,
};

pub const ModalOwner = dispatch.ModalOwner;
pub const SimulationInput = dispatch.SimulationInput;
pub const SimulationStep = dispatch.SimulationStep;
pub const RoomEventMode = enum { enabled, disabled };
pub const ActiveDuel = struct {
    parsed: std.json.Parsed(duel.Content),
    state: duel.State,
};
pub const ActiveWar = struct {
    session: war_session.Session,
    parsed: ?std.json.Parsed(war.Packet) = null,
    target_cursor: u8 = 0,
};
pub const ActiveEnding = struct {
    parsed: std.json.Parsed(chapters.endings.Asset),
    census: chapters.endings.Census,
    recruit_flags: [108]u8,
    phase_index: u8 = 0,
    entry_cursor: u16 = 0,
};
pub const ScriptedBattleResult = field_events.BattleOutcome;
pub const ActiveFieldEvent = struct {
    session: *field_events.Session,
    binding: *const field_events.Binding,
};
pub const Reserves = [72]?battle.OwnedMember;
pub const SharedItems = @FieldType(party_session.Snapshot, "shared");
pub fn initialRoute(package: field.Package) opening_route.Controller {
    return opening_route.initial(package);
}

pub fn roomId(package: field.Package, index: usize) []const u8 {
    return package.rooms[index].id;
}

pub const State = struct {
    package: field.Package,
    data: Data,
    field_state: field.State,
    // The session backing outlives copies of the journey and its room state.
    combat: *battle.State,
    menu: pause.State = .{},
    mode: Mode = .field,
    encounter_trigger: ?usize = null,
    field_encounter_clock: battle_flow.FieldEncounterClock = .{},
    initialized_room_visit: ?u32 = null,
    checked_arrival_visit: ?u32 = null,
    room_battles: ?*field_events.BattleRooms = null,
    field_event: ?ActiveFieldEvent = null,
    dice_host: ?*dice.games.Host = null,
    dice_model: ?*const dice.visual.Packet = null,
    dice_game: ?dice.Active = null,
    side_game: ?side_games.Active = null,
    teleport_catalogue: ?*const travel.teleport.catalogue.Loaded = null,
    teleport_session: ?travel.teleport.Session = null,
    optional_games: side_games.Records = .{},
    party_selection: ?party_selection.Active = null,
    item_overload: ?overload.Active = null,
    item_overload_sound: ?u16 = null,
    auto_travel: ?travel.Active = null,
    boat_travel: ?travel.Boat = null,
    boat_data: ?*const travel.BoatData = null,
    active_duel: ?ActiveDuel = null,
    active_war: ?ActiveWar = null,
    active_ending: ?ActiveEnding = null,
    scripted_battle: ?struct { owner: *field_events.Session, request: field_events.BattleRequest, opening: bool = false, confirmed: ?ScriptedBattleResult = null } = null,
    suppressed_trigger: ?usize = null,
    checkpoint: ?Snapshot = null,
    elapsed_ticks: u64 = 0,
    save_name: pause.save_slots.Label = pause.save_slots.defaultLabel(0),
    restored_save_arena: ?*std.heap.ArenaAllocator = null,
    reserves: Reserves = @splat(null),
    shared_items: SharedItems = @splat(null),
    shared_item_catalogue: ?item_ledger.catalogue.Packet = null,
    extras: [6]party_session.CharacterExtra = @splat(.{ .member_id = "" }),
    reserve_extras: [72]?party_session.CharacterExtra = @splat(null),
    party_backing: ?[]battle.Member = null,
    party_catalog: ?party_session.catalogue.Catalogue = null,
    party_bindings: ?party_session.catalogue.OwnershipBindings = null,
    town_home_ticks: u8 = 0,
    town_room_ticks: u8 = 0,
    town_world_ticks: u8 = 0,
    join_failure_room: ?u16 = null,
    world_battle_enabled: bool = false,
    world_battle_ticks: u8 = 0,
    world_battle_started: bool = false,
    derived_scene_cadence: bool = true,
    opening_event: ?[]const u8 = null,
    route: opening_route.Controller = .{},
    campaign: ?campaign_state.Snapshot = null,
    hq: ?hq_state.HqState = null,

    pub fn initEpisode(package: field.Package, data: Data, content: battle.Content, rules: field.items.Rules, inn: field.inn.Rules, members: []battle.Member, combat_backing: *battle.State) !State {
        try package.validate();
        try data.validate(package, content);
        if (members.len != 6 or content.initialPartyCount() != 6) return error.InvalidParty;
        try content.validate();
        const expected = [_][]const u8{ "hero", "gremio", "pahn", "viktor", "yam_koo", "tai_ho" };
        for (expected, 0..) |id, i| if (!std.mem.eql(u8, id, content.initialProfile(i).id)) return error.InvalidEpisodeParty;
        var combat = try battle.State.init(content, rules, members, battle.trial_seed);
        if (data.recruitment) |definition| try definition.validate(combat);
        combat.progress.money = 1200;
        combat.progress.party[0].inventory.slots[2] = .{ .id = .bandanna, .uses = 0 };
        combat.progress.party[3].inventory.slots[2] = .{ .id = .headband, .uses = 0 };
        try combat.equipOwned(0, 0);
        combat.experience[0] = 900;
        var world = field.State.init(package, &combat.progress);
        if (package.roomIndex(inn.room) != null) try world.configureInn(package, inn);
        world.item_rules = rules;
        combat_backing.* = combat;
        world.progress = &combat_backing.progress;
        return .{ .package = package, .data = data, .field_state = world, .combat = combat_backing, .route = initialRoute(package), .party_backing = members, .field_encounter_clock = battle_flow.initialFieldEncounterClock(data.field_encounters, world.progress.story.scenario) };
    }

    pub fn initOpening(package: field.Package, data: Data, content: battle.Content, rules: field.items.Rules, inn: field.inn.Rules, members: []battle.Member, combat_backing: *battle.State, hero: opening.Hero, money: u32) !State {
        try package.validate();
        try data.validate(package, content);
        if (members.len < 1) return error.InvalidParty;
        var canonical = content;
        canonical.initial_party = &.{"hero"};
        canonical.party_positions = canonical.party_positions[0..1];
        var starting_party: [1]battle.Member = undefined;
        var combat = try battle.State.init(canonical, rules, &starting_party, battle.trial_seed);
        combat.progress.party[0] = hero.member;
        combat.runes[0] = null;
        combat.progress.money = money;
        combat.levels[0] = hero.level;
        combat.experience[0] = hero.experience;
        combat.base_stats[0] = .{
            .attack = hero.base_stats.power,
            .defense = hero.base_stats.defense,
            .skill = hero.base_stats.skill,
            .speed = hero.base_stats.speed,
            .magic = hero.base_stats.magic,
            .luck = hero.base_stats.luck,
        };
        combat.weapon_levels[0] = hero.weapon_level;
        inline for (comptime std.enums.values(battle.systems.EquipmentSlot)) |slot| {
            if (@field(hero.equipped, @tagName(slot))) |item| {
                const systems = combat.content.systems orelse return error.InvalidEquipment;
                const equipment = for (systems.equipment, 0..) |gear, index| {
                    if (std.mem.eql(u8, gear.id, @tagName(item))) break index;
                } else return error.InvalidEquipment;
                try combat.equipSlotOwned(0, slot, equipment);
            }
        }
        var world = field.State.init(package, &combat.progress);
        if (package.roomIndex(inn.room) != null) try world.configureInn(package, inn);
        world.item_rules = rules;
        members[0] = starting_party[0];
        combat.progress.party = members[0..1];
        combat_backing.* = combat;
        world.progress = &combat_backing.progress;
        return .{ .package = package, .data = data, .field_state = world, .combat = combat_backing, .route = initialRoute(package), .party_backing = members, .field_encounter_clock = battle_flow.initialFieldEncounterClock(data.field_encounters, world.progress.story.scenario) };
    }

    pub fn progress(self: *const State) *const field.game_state.Progress {
        return progress_owner.current(self);
    }

    pub fn stageField(self: *const State, scratch: *field.game_state.Progress, members: *[6]battle.Member) field.State {
        return progress_owner.stageField(self, scratch, members);
    }

    pub fn commitFieldTransaction(self: *State, next_field: field.State) void {
        progress_owner.commitFieldTransaction(self, next_field);
    }

    pub fn setScenarioStory(self: *State, story: field.game_state.event_runtime.StoryState) void {
        progress_owner.setScenarioStory(self, story);
    }

    pub fn completeStoryFlag(self: *State, flag: Flag) void {
        progress_owner.completeStoryFlag(self, flag);
    }

    pub fn recordPahnDuel(self: *State, outcome: u8) void {
        progress_owner.recordPahnDuel(self, outcome);
    }

    pub fn replacePartySlice(self: *State, members: []battle.Member) void {
        progress_owner.replacePartySlice(self, members);
    }

    pub fn modalOwner(self: *const State, input: pause.Input) ModalOwner {
        return dispatch.modalOwner(self, input);
    }

    pub fn enterEncounterRoom(self: *State) void {
        const initial_story = if (self.room_battles) |rooms| rooms.initial_story else null;
        self.field_encounter_clock = battle_flow.initialFieldEncounterClock(self.data.field_encounters, self.field_state.progress.story.scenario orelse initial_story);
    }

    pub fn seedFieldStoryDefaults(self: *State) void {
        if (!self.package.supportsStoryExits() or self.combat.progress.story.scenario != null) return;
        const rooms = self.room_battles orelse return;
        self.combat.progress.story.scenario = rooms.initial_story;
    }

    pub fn bind(self: *State) void {
        self.menu.combat = self.combat;
    }

    pub fn initializeRoomVisit(self: *State) !void {
        return events_host.initializeRoomVisit(self);
    }

    pub fn deinitActiveModes(self: *State) void {
        modes.deinitActiveModes(self);
    }

    // Publish only validated startup or restore data into the long-lived session.
    pub fn bindValidatedStorage(self: *State, combat_backing: *battle.State, members: []battle.Member) void {
        const active = members[0..self.combat.partyCount()];
        @memcpy(active, self.combat.progress.party);
        combat_backing.* = self.combat.*;
        combat_backing.progress.party = active;
        self.combat = combat_backing;
        self.field_state.progress = &combat_backing.progress;
        self.party_backing = members;
        self.menu.combat = null;
    }

    pub fn releaseRestoredSave(self: *State) void {
        self.deinitActiveModes();
        const arena = self.restored_save_arena orelse return;
        self.restored_save_arena = null;
        const allocator = arena.child_allocator;
        arena.deinit();
        allocator.destroy(arena);
    }

    pub fn fromSnapshot(package: field.Package, data: Data, content: battle.Content, rules: field.items.Rules, inn: field.inn.Rules, snapshot: Snapshot, retry_seed: u64, members: []battle.Member, combat_backing: *battle.State) !State {
        try package.validate();
        if (content.systems == null) return error.MissingBattleSystems;
        try content.validate();
        try data.validate(package, content);
        try rules.validate();
        if (members.len < snapshot.party_count or snapshot.party_count == 0 or snapshot.party_count > 6) return error.InvalidParty;
        var owned = snapshot.party;
        var combat: battle.State = .{
            .content = content,
            .rules = rules,
            .progress = .{ .money = snapshot.money, .party = owned[0..snapshot.party_count] },
            .random = snapshot.random,
            .seed = retry_seed,
            .picker = try @FieldType(battle.State, "picker").init(.{ true, true, false, true, false }, .attack),
        };
        var state: State = .{ .package = package, .data = data, .combat = &combat, .field_state = field.State.init(package, &combat.progress), .route = initialRoute(package) };
        if (package.roomIndex(inn.room) != null) try state.field_state.configureInn(package, inn);
        state.field_state.item_rules = rules;
        try snapshot.apply(&state);
        if (data.recruitment) |definition| try definition.validate(state.combat.*);
        state.bindValidatedStorage(combat_backing, members);
        state.world_battle_enabled = true;
        state.updateOpeningPartyMilestone();
        return state;
    }

    // Event/service callers must establish recruitment and forced-member rules first.
    pub fn retainReserve(self: *State, owned: battle.OwnedMember) !void {
        return roster.retainReserve(self, owned);
    }

    pub fn swapReserve(self: *State, member_id: []const u8, reserve_id: []const u8) !void {
        return roster.swapReserve(self, member_id, reserve_id);
    }

    pub fn canRecruitMaas(self: State) bool {
        const definition = self.data.recruitment orelse return false;
        const story = self.combat.progress.story;
        return story.recruitment_tier >= definition.minimum_tier and !story.maas_recruited and !story.maas_recruitment_blocked;
    }

    pub fn recruitMaas(self: *State) !void {
        const definition = self.data.recruitment orelse return error.MissingRecruitmentData;
        if (!self.canRecruitMaas()) return error.RecruitmentUnavailable;
        // Prepare against copies: a failed join spends no RNG and changes no owned state.
        var random = self.combat.random;
        var draws: [17 * 7]u15 = undefined;
        try definition.validate(self.combat.*);
        const count = definition.drawCount();
        for (draws[0..count]) |*draw| draw.* = random.random().int(u15);
        const owned = try recruitment.prepare(definition, self.combat.*, draws[0..count]);
        try self.retainReserve(owned);
        self.combat.random = random;
        self.completeStoryFlag(.maas_recruited);
    }

    pub fn containsLegacyTrigger(self: *const State, trigger: Trigger) bool {
        const world = self.field_state;
        if (!std.mem.eql(u8, self.package.rooms[world.room].id, trigger.room) or
            world.x < trigger.x or world.x >= trigger.x + trigger.w or
            world.y < trigger.y or world.y >= trigger.y + trigger.h) return false;
        return if (self.room_battles) |rooms| !rooms.ownsOpeningEncounter(trigger.room, trigger.encounter) else true;
    }

    pub fn beginEncounter(self: *State, index: usize) !void {
        if (self.field_event != null) return error.GameBusy;
        return battle_flow.beginEncounter(self, index);
    }

    // The scene owner retains its binding and session through the battle return.
    pub fn attachFieldEvent(self: *State, session: *field_events.Session, binding: *const field_events.Binding) !void {
        return events_host.attachFieldEvent(self, session, binding);
    }

    pub fn beginScriptedBattle(self: *State, event: *field_events.Session, binding: field_events.Binding) !void {
        return events_host.beginScriptedBattle(self, event, binding);
    }

    pub fn resumeScriptedBattle(self: *State, event: *field_events.Session, binding: field_events.Binding) !void {
        return events_host.resumeScriptedBattle(self, event, binding);
    }

    pub fn packagedOpeningRoute(self: *const State) ?field_events.BattleRooms.OpeningRoute {
        return if (self.room_battles) |rooms| rooms.opening_route else null;
    }

    pub fn usesPrototypeWorldExit(self: *const State) bool {
        if (self.package.hasWorldExit()) return false;
        return if (self.room_battles) |rooms| rooms.opening_route == null and rooms.opening_world_exits.len == 0 else true;
    }

    pub fn syncRoute(self: *State) void {
        const id = roomId(self.package, self.field_state.room);
        if (self.usesPrototypeWorldExit() and std.mem.eql(u8, id, "world_a")) {
            if (self.route.stage == .world) return;
            if (self.route.stage == .first_town) {
                _ = self.route.complete(.first_town) catch unreachable;
                return;
            }
            self.route.stage = .world;
            self.route.completed = 4;
            self.route.journal += 1;
            return;
        }
        const route = self.packagedOpeningRoute();
        const next_room = switch (self.route.stage) {
            .opening => if (route) |configured| configured.dungeon else "vaa_room_1",
            .dungeon => if (route) |configured| configured.palace else "vaa_room_0",
            .palace => if (route) |configured| configured.first_town else "va1_room_0",
            else => return,
        };
        if (std.mem.eql(u8, id, next_room)) _ = self.route.complete(self.route.stage) catch unreachable;
    }

    pub fn updateOpeningPartyMilestone(self: *State) void {
        const required = if (self.packagedOpeningRoute()) |route| route.initial_party else &[_][]const u8{ "cleo", "ted" };
        required_members: for (required) |id| {
            for (self.combat.progress.party) |member| {
                if (std.mem.eql(u8, member.id, id)) continue :required_members;
            }
            for (self.reserves) |entry| if (entry) |member| {
                if (std.mem.eql(u8, member.member.id, id)) continue :required_members;
            };
            return;
        }
        self.route.noteInitialParty(true);
    }

    pub fn noteInitialParty(self: *State, applied: bool) void {
        self.route.noteInitialParty(applied);
    }

    pub fn defeatEndsRun(self: *const State) bool {
        if (self.scripted_battle) |active| return active.request.defeat_ends_run or (active.opening and active.request.defeat_target == null);
        return false;
    }

    pub fn defeatContinuesScene(self: *const State) bool {
        return if (self.scripted_battle) |active| active.request.defeat_target != null else false;
    }

    pub fn audioScene(self: *const State) @import("audio_route").Scene {
        return switch (self.mode) {
            .field => .field,
            .game_over => .title,
            .defeat => .defeat,
            .duel => .duel,
            .war => .war,
            .ending => .ending,
            .battle => switch (self.combat.phase) {
                .victory, .loot, .loot_replace, .confirm_loot_replace, .confirm_leave_loot => .victory,
                else => if (self.combat.content.encounters[self.combat.encounter].music == .boss) .boss else .battle,
            },
        };
    }

    pub fn fieldCamera(self: *const State) field.CameraOffset {
        const room = self.package.rooms[self.field_state.room];
        const position = self.field_state.position(self.package);
        if (self.field_event) |owner| return owner.session.fieldCamera(self.field_state, self.package);
        if (self.field_state.scene_view.camera) |camera| return .{ .x = -@as(f32, @floatFromInt(camera.x)), .y = -@as(f32, @floatFromInt(camera.y)) };
        if (room.wheel_map != null) {
            const scroll = field.sourceCameraScroll(room.width, room.height, @intFromFloat(position.x), @intFromFloat(position.y));
            return .{ .x = -@as(f32, @floatFromInt(scroll.x)), .y = -@as(f32, @floatFromInt(scroll.y)) };
        }
        return field.cameraOffset(room.width, room.height, position.x, position.y);
    }

    pub fn scriptedFieldHero(self: *const State, camera: field.CameraOffset) !?field_dialogue_view.FollowerDraw {
        if (self.field_event) |owner| return field_dialogue_view.hero(owner.session, self.package, camera);
        const position = self.field_state.scene_view.hero orelse return null;
        const variant: u2 = @intCast(@backingInt(self.field_state.facing));
        const clip = self.package.player_clips[variant];
        const frame = clip.frames[clip.idle_frame];
        return .{ .character = 8, .rect = frame.rect, .x = camera.x + @as(f32, @floatFromInt(position.x - frame.anchor_x)), .y = camera.y + @as(f32, @floatFromInt(position.y - frame.anchor_y)), .depth = @as(f32, @floatFromInt(position.y)) / 8, .variant = variant, .frame = @intCast(clip.idle_frame) };
    }

    pub fn roomActorDraws(self: *const State, camera: field.CameraOffset, out: *[64]RoomActorDraw) []const RoomActorDraw {
        const rooms = self.room_battles orelse return out[0..0];
        const story = if (self.field_state.progress.story.scenario) |*scenario| scenario else &rooms.initial_story;
        if (self.field_event) |owner| return field_events.BattleRooms.drawActors(owner.binding.*, story, owner.session, camera, out);
        const binding = rooms.bindingFor(self.package.rooms[self.field_state.room].id) orelse return out[0..0];
        if (rooms.settledForVisit(binding, self.field_state.room_entries)) |retained|
            return field_events.BattleRooms.drawSettledActors(binding, retained, camera, out);
        return field_events.BattleRooms.drawActors(binding, story, null, camera, out);
    }

    pub fn partyActorDraws(self: *const State, camera: field.CameraOffset, out: *[5]RoomActorDraw) ![]const RoomActorDraw {
        const owner = self.field_event orelse return out[0..0];
        return field_events.BattleRooms.drawPartyActors(owner.binding.*, owner.session, camera, out);
    }

    pub fn composeFieldBattleDialogue(self: *const State, font: anytype, list: *field_dialogue_view.presentation.List) !void {
        list.length = 0;
        list.appearance = if (self.field_state.progress.story.scenario) |story| story.window_appearance else .{};
        if (self.mode != .field) return;
        const owner = self.field_event orelse return;
        const choice_box = if (owner.session.instance) |*instance| instance.choiceBox(owner.binding.content) else null;
        try field_dialogue_view.compose(font, owner.session, owner.binding.dialogue, self.fieldCamera(), list, choice_box);
    }

    pub fn takeTickSounds(self: *State) TickSounds {
        const field_sound = if (self.mode == .field) self.takeFieldSound() else null;
        const queued_battle = self.combat.unite_vm.takeSounds();
        return .{
            .field = field_sound,
            .party_window_count = party_selection.takeWindowOpenCues(self),
            .battle = if (self.mode == .battle or self.mode == .defeat) queued_battle else &.{},
        };
    }

    pub fn takeFieldSound(self: *State) ?u16 {
        if (self.menu.pending_sound) |cue| {
            self.menu.pending_sound = null;
            return cue;
        }
        if (self.item_overload_sound) |cue| {
            self.item_overload_sound = null;
            return cue;
        }
        const owner = self.field_event orelse return null;
        return owner.session.takeSoundEffect();
    }

    pub fn pendingFieldMusic(self: *const State) ?field.game_state.event_runtime.FieldMusic {
        if (self.mode != .field) return null;
        const owner = self.field_event orelse return null;
        return owner.session.pendingFieldMusic();
    }

    pub fn completeFieldMusic(self: *State, music: field.game_state.event_runtime.FieldMusic) !void {
        if (self.pendingFieldMusic() != music) return error.InvalidFieldMusicReceipt;
        const owner = self.field_event orelse return error.MissingFieldMusicOwner;
        try owner.session.resumeFieldMusic(owner.binding.*, &self.field_state, music);
    }

    pub fn validateScenePartyChanges(self: *const State) !void {
        return events_host.validateScenePartyChanges(self);
    }

    pub fn bindSharedItems(self: *const State, slots: SharedItems) !SharedItems {
        return events_host.bindSharedItems(self, slots);
    }

    pub fn sharedItemNames(self: *const State) SharedItems {
        return events_host.sharedItemNames(self);
    }

    pub const advanceSimulation = dispatch.advanceSimulation;

    pub noinline fn tickWithFieldEvents(self: *State, input: pause.Input, combat_input: battle.Input) !pause.Effect {
        // Headless field replays provide neither a modeled dice audio host nor a party sample.
        return (try self.advanceSimulation(.{ .menu = input, .battle = combat_input }, null)).effect;
    }

    pub fn tickPartySelection(self: *State, controls: party_selection.selector.Controls) !void {
        try party_selection.tick(self, controls);
    }

    pub fn buildPartySnapshot(self: *const State) party_session.Snapshot {
        return roster.buildPartySnapshot(self);
    }

    pub fn joinPartyMember(self: *State, backing: []battle.Member, catalog: party_session.catalogue.Catalogue, bindings: ?party_session.catalogue.OwnershipBindings, id: []const u8) !void {
        return roster.joinPartyMember(self, backing, catalog, bindings, id);
    }

    pub fn joinOnRoomEntry(self: *State, backing: []battle.Member, catalog: party_session.catalogue.Catalogue, bindings: ?party_session.catalogue.OwnershipBindings, room_id: []const u8) !void {
        return roster.joinOnRoomEntry(self, backing, catalog, bindings, room_id);
    }

    pub fn tick(self: *State, input: pause.Input, combat_input: battle.Input) pause.Effect {
        const step = self.advanceSimulation(.{ .menu = input, .battle = combat_input, .room_events = .disabled }, null) catch |err| {
            std.log.warn("Room setup failed: {s}", .{@errorName(err)});
            self.menu.notify("Room setup failed.");
            return .none;
        };
        return step.effect;
    }

    pub fn startDuelById(self: *State, allocator: std.mem.Allocator, duel_id: []const u8) !void {
        return modes.startDuelById(self, allocator, duel_id);
    }

    pub fn startDuel(self: *State, allocator: std.mem.Allocator, duel_id: []const u8, fighters: [2]duel.FighterState, random: duel.Random) !void {
        return modes.startDuel(self, allocator, duel_id, fighters, random);
    }

    pub fn chooseDuelCommand(self: *State, command: duel.Command) !void {
        return modes.chooseDuelCommand(self, command);
    }

    pub fn tickDuel(self: *State, up: bool, down: bool, confirm: bool) !void {
        return modes.tickDuel(self, up, down, confirm);
    }

    pub fn startEnding(self: *State, allocator: std.mem.Allocator) !void {
        return modes.startEnding(self, allocator);
    }

    pub fn tickEnding(self: *State, up: bool, down: bool, confirm: bool) !void {
        return modes.tickEnding(self, up, down, confirm);
    }

    pub fn startWar(self: *State, allocator: std.mem.Allocator, entry: war_session.Entry) !void {
        return modes.startWar(self, allocator, entry);
    }

    pub fn startWarById(self: *State, allocator: std.mem.Allocator, scenario_id: []const u8, rng_state: u32) !void {
        return modes.startWarById(self, allocator, scenario_id, rng_state);
    }

    pub fn tickWar(self: *State, input: war_session.Input) !void {
        return modes.tickWar(self, input);
    }

    pub fn applyFieldInteractions(self: *State, old_room: usize, old_dialogue: ?field.Dialogue, input: field.Input) void {
        exploration.applyFieldInteractions(self, old_room, old_dialogue, input);
    }

    pub fn episodeObjective(self: *const State) ?[]const u8 {
        return exploration.episodeObjective(self);
    }
};

pub fn usesOpeningSeed(start_room: []const u8) bool {
    return std.mem.eql(u8, start_room, "vaa_room_1") or std.mem.eql(u8, start_room, "vaa_room_2");
}

pub const Snapshot = save_data.Snapshot;
pub const encounterIndex = battle_flow.encounterIndex;

pub const filename = save_data.filename;
pub const backup_filename = save_data.backup_filename;
pub const RestoreSource = save_data.RestoreSource;
pub const validateSnapshotFields = save_data.validateSnapshotFields;
pub const validateNestedSnapshotFields = save_data.validateNestedSnapshotFields;
pub const decodeSnapshot = save_data.decodeSnapshot;
pub const slotFilename = save_data.slotFilename;
pub const save = save_data.save;
pub const saveSlot = save_data.saveSlot;
pub const restoreWithSource = save_data.restoreWithSource;
pub const restoreSlotWithSource = save_data.restoreSlotWithSource;
pub const restore = save_data.restore;
pub const summaries = save_data.summaries;
