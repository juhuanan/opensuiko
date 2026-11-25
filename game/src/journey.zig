const std = @import("std");
const item_ledger = @import("item_ledger");
pub const opening = @import("opening");
pub const field_dialogue_view = @import("field_dialogue_view.zig");
pub const opening_events = @import("opening_events");
pub const opening_route = @import("route");
const roster = @import("journey_roster");
const battle_flow = @import("journey_battle");
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
const war_scenarios_data = @import("war_scenarios_data");
pub const chapters = @import("chapters");
const final_assets = @import("final_assets");
const Flag = field.game_state.StoryFlag;
pub const recruitment = @import("recruitment");
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
const ScriptedBattleResult = field_events.BattleOutcome;
const ActiveFieldEvent = struct {
    session: *field_events.Session,
    binding: *const field_events.Binding,
};
pub const Reserves = @import("journey_save").Reserves;
const SharedItems = @import("journey_save").SharedItems;
pub fn initialRoute(package: field.Package) opening_route.Controller {
    return opening_route.initial(package);
}

fn roomId(package: field.Package, index: usize) []const u8 {
    return package.rooms[index].id;
}

pub const State = struct {
    package: field.Package,
    data: Data,
    field_state: field.State,
    combat: battle.State,
    menu: pause.State = .{},
    mode: Mode = .field,
    encounter_trigger: ?usize = null,
    field_encounter_clock: Snapshot.EncounterClock = .{},
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
    optional_games: Snapshot.OptionalGames = .{},
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

    pub fn initEpisode(package: field.Package, data: Data, content: battle.Content, rules: field.items.Rules, inn: field.inn.Rules, members: []battle.Member) !State {
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
        var world = field.State.init(package, combat.progress);
        if (package.roomIndex(inn.room) != null) try world.configureInn(package, inn);
        world.item_rules = rules;
        return .{ .package = package, .data = data, .field_state = world, .combat = combat, .route = initialRoute(package), .party_backing = members, .field_encounter_clock = battle_flow.initialFieldEncounterClock(data.field_encounters, world.progress.story.scenario) };
    }
    pub fn initOpening(package: field.Package, data: Data, content: battle.Content, rules: field.items.Rules, inn: field.inn.Rules, members: []battle.Member, hero: opening.Hero, money: u32) !State {
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
        var world = field.State.init(package, combat.progress);
        if (package.roomIndex(inn.room) != null) try world.configureInn(package, inn);
        world.item_rules = rules;
        members[0] = starting_party[0];
        combat.progress.party = members[0..1];
        world.progress = combat.progress;
        return .{ .package = package, .data = data, .field_state = world, .combat = combat, .route = initialRoute(package), .party_backing = members, .field_encounter_clock = battle_flow.initialFieldEncounterClock(data.field_encounters, world.progress.story.scenario) };
    }

    pub fn enterEncounterRoom(self: *State) void {
        const initial_story = if (self.room_battles) |rooms| rooms.initial_story else null;
        self.field_encounter_clock = battle_flow.initialFieldEncounterClock(self.data.field_encounters, self.field_state.progress.story.scenario orelse initial_story);
    }

    pub fn seedFieldStoryDefaults(self: *State) void {
        if (!self.package.supportsStoryExits() or self.combat.progress.story.scenario != null) return;
        const rooms = self.room_battles orelse return;
        self.combat.progress.story.scenario = rooms.initial_story;
        self.field_state.progress.story.scenario = rooms.initial_story;
    }

    pub fn bind(self: *State) void {
        self.menu.combat = &self.combat;
    }

    fn roomEventBinding(self: *State, rooms: *field_events.BattleRooms, binding: field_events.Binding) !field_events.Binding {
        const host = (self.combat.integration orelse return error.MissingBattleIntegration).host;
        for (self.field_state.progress.party, rooms.party[0..self.field_state.progress.party.len]) |member, *id| {
            id.* = host.characterId(member.id) orelse return error.UnknownFieldEventPartyMember;
        }
        @memset(&rooms.character_levels, 0);
        if (self.party_catalog) |catalog| for (catalog.characters) |character| {
            if (character.source_character_id >= rooms.character_levels.len) return error.UnknownFieldEventPartyMember;
            rooms.character_levels[character.source_character_id] = character.seed.level;
        };
        for (rooms.party[0..self.field_state.progress.party.len], 0..) |id, index|
            rooms.character_levels[id] = self.combat.levels[index];
        for (self.reserves) |entry| if (entry) |owned| {
            const id = host.characterId(owned.member.id) orelse return error.UnknownFieldEventPartyMember;
            rooms.character_levels[id] = owned.level;
        };
        var carried_count: usize = 0;
        var equipped_count: usize = 0;
        for (self.field_state.progress.party, 0..) |member, index| {
            for (member.inventory.slots) |entry| if (entry) |item| {
                rooms.carried_items[carried_count] = item.id.sourceId();
                carried_count += 1;
            };
            inline for (comptime std.meta.fieldNames(@TypeOf(self.combat.loadouts[0]))) |slot| {
                if (@field(self.combat.loadouts[index], slot)) |gear| {
                    const rules = self.combat.content.systems orelse return error.InvalidEquipment;
                    if (gear >= rules.equipment.len) return error.InvalidEquipment;
                    const id = std.meta.stringToEnum(field.items.Id, rules.equipment[gear].id) orelse return error.UnknownFieldEventItem;
                    if (!id.equipment()) return error.InvalidEquipment;
                    const carried = for (member.inventory.slots) |entry| {
                        if (entry != null and entry.?.id == id) break true;
                    } else false;
                    if (!carried) return error.InvalidEquipment;
                    rooms.equipped_items[equipped_count] = id.sourceId();
                    equipped_count += 1;
                }
            }
        }
        if (self.shared_item_catalogue) |catalogue| {
            for (self.shared_items) |entry| if (entry) |id| {
                const item = item_ledger.catalogue.findById(catalogue, id) orelse return error.SharedItemContentMismatch;
                rooms.carried_items[carried_count] = item.source_item_id;
                carried_count += 1;
            };
        }
        var result = binding;
        result.item_presence = .{ .carried = rooms.carried_items[0..carried_count], .equipped = rooms.equipped_items[0..equipped_count] };
        result.character_levels = &rooms.character_levels;
        result.player_name = if (self.combat.content.partyProfile("hero")) |profile| profile.name else null;
        result.party = rooms.party[0..self.field_state.progress.party.len];
        return result;
    }

    pub fn initializeRoomVisit(self: *State) !void {
        const rooms = self.room_battles orelse return;
        const world = &self.field_state;
        if (self.mode != .field or self.initialized_room_visit == world.room_entries) return;
        if (rooms.bindingFor(roomId(self.package, world.room))) |binding| {
            var story = world.progress.story.scenario orelse rooms.initial_story;
            if (try rooms.initializeStory(try self.roomEventBinding(rooms, binding), world, &story)) {
                world.progress.story.scenario = story;
                self.combat.progress.story.scenario = story;
                self.enterEncounterRoom();
            }
        }
        self.initialized_room_visit = world.room_entries;
    }

    pub fn deinitActiveModes(self: *State) void {
        if (self.active_duel) |*active| {
            active.parsed.deinit();
            self.active_duel = null;
        }
        if (self.active_war) |*active| {
            active.session.deinit();
            if (active.parsed) |parsed| parsed.deinit();
            self.active_war = null;
        }
        if (self.active_ending) |*active| {
            active.parsed.deinit();
            self.active_ending = null;
        }
    }

    pub fn releaseRestoredSave(self: *State) void {
        self.deinitActiveModes();
        const arena = self.restored_save_arena orelse return;
        self.restored_save_arena = null;
        const allocator = arena.child_allocator;
        arena.deinit();
        allocator.destroy(arena);
    }
    pub fn fromSnapshot(package: field.Package, data: Data, content: battle.Content, rules: field.items.Rules, inn: field.inn.Rules, snapshot: Snapshot, retry_seed: u64, members: []battle.Member) !State {
        try package.validate();
        if (content.systems == null) return error.MissingBattleSystems;
        try content.validate();
        try data.validate(package, content);
        try rules.validate();
        if (members.len < snapshot.party_count or snapshot.party_count == 0 or snapshot.party_count > 6) return error.InvalidParty;
        var owned = snapshot.party;
        const combat: battle.State = .{
            .content = content,
            .rules = rules,
            .progress = .{ .money = snapshot.money, .party = owned[0..snapshot.party_count] },
            .random = snapshot.random,
            .seed = retry_seed,
            .picker = try @FieldType(battle.State, "picker").init(.{ true, true, false, true, false }, .attack),
        };
        var state: State = .{ .package = package, .data = data, .combat = combat, .field_state = field.State.init(package, combat.progress), .route = initialRoute(package) };
        if (package.roomIndex(inn.room) != null) try state.field_state.configureInn(package, inn);
        state.field_state.item_rules = rules;
        try snapshot.apply(&state);
        if (data.recruitment) |definition| try definition.validate(state.combat);
        // Publish owned storage only after the entire checkpoint validates and references rebind.
        @memcpy(members[0..snapshot.party_count], owned[0..snapshot.party_count]);
        state.combat.progress.party = members[0..snapshot.party_count];
        state.party_backing = members;
        state.field_state.progress = state.combat.progress;
        state.menu.combat = null;
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
        try definition.validate(self.combat);
        const count = definition.drawCount();
        for (draws[0..count]) |*draw| draw.* = random.random().int(u15);
        const owned = try recruitment.prepare(definition, self.combat, draws[0..count]);
        try self.retainReserve(owned);
        self.combat.random = random;
        self.combat.progress.story.complete(.maas_recruited);
        self.field_state.progress = self.combat.progress;
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
        const world = &self.field_state;
        if (self.mode != .field or self.field_event != null or self.menu.phase != .closed or
            world.remaining != 0 or world.dialogue != null or world.rest_ticks != 0) return error.GameBusy;
        try session.validate(binding.*);
        if (!session.busy()) return error.InactiveFieldEvent;
        if (session.instance) |*instance| {
            if (instance.pendingBattle() != null and session.queuedBattle() == null) return error.InvalidFieldBattleReceipt;
        }
        try self.checkScriptedBattleField(session, binding.*);
        self.field_event = .{ .session = session, .binding = binding };
    }
    fn checkScriptedBattleField(self: *const State, event: *const field_events.Session, binding: field_events.Binding) !void {
        if (!std.mem.eql(u8, binding.room, self.package.rooms[self.field_state.room].id) or
            event.hero.x != self.field_state.x or event.hero.y != self.field_state.y) return error.ScriptedBattleFieldMismatch;
    }
    pub fn beginScriptedBattle(self: *State, event: *field_events.Session, binding: field_events.Binding) !void {
        if (self.field_event) |owner| if (owner.session != event) return error.ScriptedBattleFieldMismatch;
        try event.validate(binding);
        const request = event.queuedBattle() orelse return error.MissingScriptedBattleRequest;
        try self.checkScriptedBattleField(event, binding);
        if (std.mem.startsWith(u8, request.id, "war:")) {
            const seed: u32 = @truncate(self.elapsed_ticks +% 1);
            try self.startWarById(std.heap.page_allocator, request.id["war:".len..], if (seed == 0) 1 else seed);
            self.scripted_battle = .{ .owner = event, .request = event.takeBattle().?, .opening = false };
            return;
        }
        if (std.mem.startsWith(u8, request.id, "duel:")) {
            try self.startDuelById(std.heap.page_allocator, request.id["duel:".len..]);
            self.scripted_battle = .{ .owner = event, .request = event.takeBattle().?, .opening = false };
            return;
        }
        if (std.mem.startsWith(u8, request.id, "ending:")) {
            try self.startEnding(std.heap.page_allocator);
            self.scripted_battle = .{ .owner = event, .request = event.takeBattle().?, .opening = false };
            return;
        }
        const encounter = battle_flow.encounterIndex(self.combat.content, request.id) orelse return error.UnknownEncounter;
        const opening_battle = if (self.room_battles) |rooms|
            event == &rooms.session and rooms.isOpeningBattle(binding.room, request.receipt.program)
        else
            false;
        try battle_flow.beginCombat(self, encounter);
        self.scripted_battle = .{ .owner = event, .request = event.takeBattle().?, .opening = opening_battle };
    }
    pub fn resumeScriptedBattle(self: *State, event: *field_events.Session, binding: field_events.Binding) !void {
        const active = self.scripted_battle orelse return error.MissingScriptedBattleRequest;
        const result = active.confirmed orelse return error.ScriptedBattleNotReady;
        if (active.owner != event) return error.ScriptedBattleFieldMismatch;
        const special_mode: ?Mode = if (std.mem.startsWith(u8, active.request.id, "war:"))
            .war
        else if (std.mem.startsWith(u8, active.request.id, "duel:"))
            .duel
        else if (std.mem.startsWith(u8, active.request.id, "ending:"))
            .ending
        else
            null;
        if (special_mode) |mode| {
            const has_active = switch (mode) {
                .war => self.active_war != null,
                .duel => self.active_duel != null,
                .ending => self.active_ending != null,
                else => unreachable,
            };
            if (self.mode != mode or !has_active) return error.ScriptedBattleNotReady;
            try self.checkScriptedBattleField(event, binding);
            var next_field = self.field_state;
            next_field.progress = self.combat.progress;
            try event.resumeBattle(binding, &next_field, active.request, result);
            self.deinitActiveModes();
            self.field_state.progress = next_field.progress;
            self.combat.progress = next_field.progress;
            self.scripted_battle = null;
            self.mode = .field;
            return;
        }
        const phase: battle.Phase = switch (result) {
            .victory => .victory,
            .escape => .escaped,
            .defeat => .defeat,
        };
        if (self.mode != (if (result == .defeat) Mode.defeat else Mode.battle) or self.combat.phase != phase) return error.ScriptedBattleNotReady;
        try self.checkScriptedBattleField(event, binding);
        var next_field = self.field_state;
        next_field.progress = self.combat.progress;
        try event.resumeBattle(binding, &next_field, active.request, result);
        self.combat.progress = next_field.progress;
        if (result == .victory and active.opening) self.route.noteOpeningBattle(.victory_returned);
        self.scripted_battle = null;
        self.returnFromBattle(result == .victory);
    }
    fn returnFromBattle(self: *State, won: bool) void {
        battle_flow.returnFromBattle(self, won);
    }
    pub fn packagedOpeningRoute(self: *const State) ?field_events.BattleRooms.OpeningRoute {
        return if (self.room_battles) |rooms| rooms.opening_route else null;
    }

    fn usesPrototypeWorldExit(self: *const State) bool {
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
        self.combat.progress = self.field_state.progress;
    }

    noinline fn admitRoomEvent(self: *State, input: field.Input, selection: enum { automatic, all }) !bool {
        const rooms = self.room_battles orelse return false;
        const world = &self.field_state;
        if (self.mode != .field or self.field_event != null or self.menu.phase != .closed or
            world.remaining != 0 or world.dialogue != null or world.rest_ticks != 0) return false;
        const binding = rooms.bindingFor(self.package.rooms[world.room].id) orelse return false;
        if (world.progress.story.scenario == null) {
            world.progress.story.scenario = rooms.initial_story;
            self.combat.progress.story.scenario = rooms.initial_story;
        }
        rooms.active_binding = try self.roomEventBinding(rooms, binding);
        const construction = try rooms.constructActorsForVisit(rooms.active_binding, world.progress.story.scenario.?, world.room_entries);
        const actors = if (construction) |*value| value else null;
        const serial = try std.math.add(u64, rooms.serial, 1);
        var entry = world.*;
        // The completed cell owns event selection even while direction is held.
        entry.walking = false;
        const arrival = self.checked_arrival_visit != world.room_entries and
            try rooms.session.beginRoomEvent(rooms.active_binding, entry, serial, actors, .area_entry, null);
        if (!arrival) self.checked_arrival_visit = world.room_entries;
        const ordinary = !arrival and try rooms.session.beginRoomEvent(rooms.active_binding, entry, serial, actors, .ordinary, input.direction);
        if (!arrival and !ordinary) {
            if (selection == .automatic or input.cancel or (!input.action and !world.action_pending)) return false;
            entry.facing = input.direction orelse world.facing;
            for (binding.population.entities) |entity| {
                if (entity.trigger != .interaction or entity.event.status != .resolved) continue;
                const point = binding.interactionPosition(entity.source_order, actors) orelse continue;
                if (!field.interactionReaches(entry, self.package, point.x, point.y)) continue;
                rooms.session = field_events.Session.beginInteraction(rooms.active_binding, entry, serial, entity.source_order, construction) catch |err| switch (err) {
                    error.IneligibleFieldInteraction, error.UnavailableFieldInteraction, error.EventConditionFalse => continue,
                    else => return err,
                };
                break;
            } else return false;
        }
        try self.attachFieldEvent(&rooms.session, &rooms.active_binding);
        self.checked_arrival_visit = world.room_entries;
        world.walking = false;
        if (!ordinary) {
            world.facing = entry.facing;
            world.action_pending = false;
        }
        rooms.serial = serial;
        return !ordinary;
    }

    pub fn validateScenePartyChanges(self: *const State) !void {
        const rooms = self.room_battles orelse return;
        for (rooms.bindings) |binding| for (binding.population.entities) |entity| {
            if (entity.event.status != .resolved) continue;
            const program = binding.content.program(entity.event.program_id.?) orelse return error.UnknownEventProgram;
            for (program.commands) |command| {
                if (command.kind == .party_select) {
                    if (self.party_catalog == null or self.party_bindings == null) return error.MissingPartyCatalogue;
                    if (self.party_backing == null or self.party_backing.?.len < 6) return error.MissingPartyBacking;
                    if (self.combat.integrationHost() == null) return error.MissingBattleIntegration;
                    continue;
                }
                if (command.kind != .party_join and command.kind != .party_load and command.kind != .advance_character and command.kind != .party_leave) continue;
                const host = self.combat.integrationHost() orelse return error.MissingBattleIntegration;
                const id = command.character.?;
                if (host.characterId(id) == null or ((command.kind == .party_load or command.kind == .advance_character) and host.characterId(id).? >= 108) or self.combat.content.partyProfile(id) == null) return error.UnknownFieldEventPartyMember;
                if (command.kind == .party_join or command.kind == .party_load or command.kind == .advance_character) {
                    const catalog = self.party_catalog orelse return error.MissingPartyCatalogue;
                    _ = try party_session.catalogue.materializeBound(self.combat, catalog, id, self.party_bindings);
                }
            }
        };
    }

    fn prepareSceneInventory(self: *const State, member: usize, edit: field.game_state.event_runtime.InventoryEdit) !?field.items.Inventory {
        var inventory = self.combat.progress.party[member].inventory;
        if (edit.take) |name| {
            const id = std.meta.stringToEnum(field.items.Id, name) orelse return error.InvalidItem;
            const slot = for (inventory.slots[0..inventory.count()], 0..) |item, index| {
                if (item.?.id == id and !self.combat.itemEquipped(member, index)) break index;
            } else return null;
            inventory.remove(slot);
        }
        if (edit.give) |name| {
            const id = std.meta.stringToEnum(field.items.Id, name) orelse return error.InvalidItem;
            if (!try inventory.receive(id)) return null;
        }
        try inventory.validate();
        return inventory;
    }

    pub fn bindSharedItems(self: *const State, slots: SharedItems) !SharedItems {
        var bound = slots;
        var ended = false;
        for (&bound) |*slot| {
            if (slot.*) |name| {
                if (ended) return error.InvalidSharedItems;
                const catalogue = self.shared_item_catalogue orelse return error.MissingSharedItemCatalogue;
                const item = item_ledger.catalogue.sharedKey(catalogue, name) catch return error.SharedItemContentMismatch;
                slot.* = item.id;
            } else ended = true;
        }
        return bound;
    }

    pub fn sharedItemNames(self: *const State) SharedItems {
        var names: SharedItems = @splat(null);
        const catalogue = self.shared_item_catalogue orelse return names;
        for (self.shared_items, &names) |entry, *label| {
            const id = entry orelse break;
            if (item_ledger.catalogue.findById(catalogue, id)) |item| label.* = item.label;
        }
        return names;
    }

    fn prepareSharedInventory(self: *const State, edit: field.game_state.event_runtime.InventoryEdit) !?SharedItems {
        const catalogue = self.shared_item_catalogue orelse return error.MissingSharedItemCatalogue;
        var view = try item_ledger.ledger.viewOf(catalogue, self.shared_items, 0);
        if (edit.take) |name| {
            const item = try item_ledger.catalogue.sharedKey(catalogue, name);
            view = (item_ledger.ledger.apply(view, .remove, item.source_item_id) catch |err| switch (err) {
                error.ItemUnavailable => return null,
                else => return err,
            }).view;
        }
        if (edit.give) |name| {
            const item = try item_ledger.catalogue.sharedKey(catalogue, name);
            view = (item_ledger.ledger.apply(view, .acquire, item.source_item_id) catch |err| switch (err) {
                error.SharedLedgerFull => return null,
                else => return err,
            }).view;
        }
        return try item_ledger.ledger.slotsOf(catalogue, view);
    }

    fn collectFacilityItems(self: *State, ids: []const field.items.Id) !u8 {
        const catalogue = self.shared_item_catalogue orelse return error.MissingSharedItemCatalogue;
        var view = try item_ledger.ledger.viewOf(catalogue, self.shared_items, 0);
        var inventories: [6]field.items.Inventory = undefined;
        for (self.field_state.progress.party, inventories[0..self.field_state.progress.party.len]) |member, *inventory| inventory.* = member.inventory;
        var collected: u8 = 0;
        for (ids, 0..) |id, index| {
            const source = try item_ledger.catalogue.sharedKey(catalogue, @tagName(id));
            const bit = @as(u8, 1) << @as(u3, @intCast(index));
            while (view.find(source.source_item_id) != null) {
                view = (try item_ledger.ledger.apply(view, .remove, source.source_item_id)).view;
                collected |= bit;
            }
            for (inventories[0..self.field_state.progress.party.len]) |*inventory| {
                var slot: usize = 0;
                while (slot < inventory.count()) {
                    if (inventory.slots[slot].?.id == id) {
                        inventory.remove(slot);
                        collected |= bit;
                    } else slot += 1;
                }
            }
        }
        self.shared_items = try item_ledger.ledger.slotsOf(catalogue, view);
        for (self.field_state.progress.party, inventories[0..self.field_state.progress.party.len]) |*member, inventory| member.inventory = inventory;
        return collected;
    }

    noinline fn commitScenePartyEffect(self: *State, owner: ActiveFieldEvent) !void {
        const rooms = self.room_battles orelse return error.FieldEventBlocked;
        if (owner.session != &rooms.session or owner.binding != &rooms.active_binding) return error.FieldEventBlocked;
        const binding = owner.binding.*;
        if (try owner.session.pendingPartyEdit(binding)) |effect| {
            var story = self.field_state.progress.story.scenario orelse return error.MissingSourceStoryState;
            if (effect.kind == .party_gain_experience or effect.kind == .party_lose_experience) {
                if (self.combat.replay_draws != null) return error.InvalidCharacterGrowth;
                var members: [6]battle.Member = undefined;
                const count = self.combat.partyCount();
                @memcpy(members[0..count], self.combat.progress.party);
                var next = self.combat;
                next.progress.party = members[0..count];
                try next.sceneExperience(effect.kind == .party_gain_experience);
                try owner.session.acknowledgePartyEdit(binding, true, &story);
                for (0..count) |index| self.combat.setOwnedMember(index, next.ownedMember(index));
                self.combat.random = next.random;
                self.field_state.progress = self.combat.progress;
            } else if (effect.kind == .advance_character) {
                var advances = effect.level_advances.?;
                if (effect.add_hero_level == true) {
                    const hero_level = for (self.combat.progress.party, 0..) |member, index| {
                        if (std.mem.eql(u8, member.id, "hero")) break self.combat.levels[index];
                    } else return error.InvalidCharacterGrowth;
                    advances = @min(advances +| hero_level, 99);
                }
                const growth = try roster.prepareGrowth(self, effect.character.?, advances);
                try owner.session.acknowledgePartyEdit(binding, true, &story);
                roster.commitGrowth(self, growth);
            } else if (effect.kind == .warehouse_deposit) {
                const id = effect.character.?;
                const equipment = (self.combat.content.systems orelse return error.InvalidSystems).equipment;
                const catalogue = self.shared_item_catalogue orelse return error.MissingSharedItemCatalogue;
                const active = for (self.combat.progress.party, 0..) |member, index| {
                    if (std.mem.eql(u8, member.id, id)) break @as(?usize, index);
                } else null;
                const reserve = if (active == null) for (&self.reserves) |*entry| {
                    const member = if (entry.*) |*owned| owned else break null;
                    if (std.mem.eql(u8, member.member.id, id)) break member;
                } else null else null;
                if (active != null or reserve != null) {
                    const owned = if (active) |index| self.combat.ownedMember(index) else reserve.?.*;
                    var inventory = owned.member.inventory;
                    var storage = self.combat.progress.storage;
                    var slot = inventory.count();
                    while (slot > 0) {
                        slot -= 1;
                        const item = inventory.slots[slot].?;
                        const record = item_ledger.catalogue.findById(catalogue, @tagName(item.id)) orelse return error.UnknownItemIdentity;
                        if (!try item_ledger.ledger.transferEligible(record, .{
                            .identified = item.identified,
                            .worn = item_ledger.owners.wearsItem(equipment, owned, slot),
                        })) continue;
                        storage.deposit(&inventory, slot) catch |err| switch (err) {
                            error.StorageFull => continue,
                            else => return err,
                        };
                    }
                    try owner.session.acknowledgePartyEdit(binding, true, &story);
                    if (active) |index| {
                        self.combat.progress.party[index].inventory = inventory;
                    } else {
                        reserve.?.member.inventory = inventory;
                    }
                    self.combat.progress.storage = storage;
                    self.field_state.progress = self.combat.progress;
                } else try owner.session.acknowledgePartyEdit(binding, true, &story);
            } else if (effect.kind == .shared_inventory_edit) {
                const inventory = try self.prepareSharedInventory(effect.inventory.?);
                try owner.session.acknowledgePartyEdit(binding, inventory != null, &story);
                if (inventory) |next| self.shared_items = next;
            } else {
                const member = for (self.combat.progress.party, 0..) |character, index| {
                    if (std.mem.eql(u8, character.id, effect.character.?)) break @as(?usize, index);
                } else null;
                if (effect.inventory) |edit| {
                    const inventory = if (member) |index| try self.prepareSceneInventory(index, edit) else null;
                    try owner.session.acknowledgePartyEdit(binding, inventory != null, &story);
                    if (inventory) |next| self.combat.progress.party[member.?].inventory = next;
                } else {
                    const rules = self.combat.content.systems orelse return error.InvalidRune;
                    const rune = rules.runeIndex(effect.rune.?) orelse return error.InvalidRune;
                    const slot: *?usize, var owned: battle.OwnedMember = if (member) |index|
                        .{ &self.combat.runes[index], self.combat.ownedMember(index) }
                    else reserve: {
                        for (&self.reserves) |*entry| {
                            const record = if (entry.*) |*record| record else break;
                            if (std.mem.eql(u8, record.member.id, effect.character.?)) break :reserve .{ &record.rune, record.* };
                        }
                        return error.InvalidMember;
                    };
                    const was_empty = slot.* == null;
                    owned.rune = rune;
                    try self.combat.validateOwnedMember(owned);
                    try owner.session.acknowledgePartyEdit(binding, true, &story);
                    slot.* = rune;
                    if (was_empty and member != null) {
                        const party_member = &self.combat.progress.party[member.?];
                        if (std.mem.allEqual(u16, &party_member.rune_charges, 0)) {
                            party_member.rune_charges = party_member.max_rune_charges;
                        }
                    }
                }
            }
            self.field_state.progress.story.scenario = story;
            self.combat.progress.story.scenario = story;
            return;
        }
        const change = (try owner.session.pendingPartyChange(binding)) orelse return error.FieldEventBlocked;
        if (change.kind == .party_dismiss) {
            if (binding.party.len != self.combat.partyCount()) return error.FieldEventPartyMismatch;
            const dismissal = try roster.preparePartyDismiss(self);
            const keep = binding.party[dismissal.keep];
            const party_ids: [6]u8 = .{ keep, 255, 255, 255, 255, 255 };
            var story = self.field_state.progress.story.scenario orelse return error.MissingSourceStoryState;
            var auxiliary = self.field_state.auxiliary_party;
            if (auxiliary) |*list| for (binding.party, 0..) |departing, index| {
                if (index != dismissal.keep) field.editAuxiliaryParty(list, false, departing);
            };
            try owner.session.acknowledgePartyChange(binding, dismissal.keep, party_ids[0..1], &story);
            roster.commitPartyDismiss(self, dismissal);
            self.field_state.auxiliary_party = auxiliary;
            rooms.party = party_ids;
            rooms.active_binding.party = rooms.party[0..1];
            self.combat.progress.story.scenario = story;
            self.field_state.progress = self.combat.progress;
            return;
        }
        const id = change.character.?;
        const host = self.combat.integrationHost() orelse return error.MissingBattleIntegration;
        const source_id = host.characterId(id) orelse return error.UnknownFieldEventPartyMember;
        var party_ids = rooms.party;
        var count = binding.party.len;
        var story = self.field_state.progress.story.scenario orelse return error.MissingSourceStoryState;
        if (change.kind == .party_load and (count == 6 or std.mem.indexOfScalar(u8, binding.party, source_id) != null)) {
            try owner.session.acknowledgePartyLoad(binding, source_id, party_ids[0..count], &story);
        } else if (change.kind == .party_join or change.kind == .party_load) {
            const catalog = self.party_catalog orelse return error.MissingPartyCatalogue;
            const backing = self.party_backing orelse return error.InvalidParty;
            const join = try roster.preparePartyJoin(self, backing, catalog, self.party_bindings, id);
            party_ids[count] = source_id;
            if (change.kind == .party_load) {
                try owner.session.acknowledgePartyLoad(binding, source_id, party_ids[0 .. count + 1], &story);
            } else try owner.session.acknowledgePartyChange(binding, count, party_ids[0 .. count + 1], &story);
            roster.commitPartyJoin(self, backing, join);
            if (change.level_advances) |advances| {
                for (0..advances) |_| {
                    var rolls: [7]u15 = undefined;
                    for (&rolls) |*roll| roll.* = self.combat.roll();
                    self.combat.levelUp(count, rolls);
                }
            }
            count += 1;
        } else if (change.value == 1 and std.mem.indexOfScalar(u8, binding.party, source_id) == null) {
            try owner.session.acknowledgePartyChange(binding, count, party_ids[0..count], &story);
        } else {
            const leave = try roster.preparePartyLeave(self, id);
            if (party_ids[leave.member] != source_id) return error.FieldEventPartyMismatch;
            count -= 1;
            std.mem.copyForwards(u8, party_ids[leave.member..count], party_ids[leave.member + 1 .. count + 1]);
            party_ids[count] = 255;
            var auxiliary = self.field_state.auxiliary_party;
            if (auxiliary) |*list| field.editAuxiliaryParty(list, false, source_id);
            try owner.session.acknowledgePartyChange(binding, leave.member, party_ids[0..count], &story);
            roster.commitPartyLeave(self, leave);
            self.field_state.auxiliary_party = auxiliary;
        }
        rooms.party = party_ids;
        rooms.active_binding.party = rooms.party[0..count];
        if (story.castle_tier != self.combat.progress.story.scenario.?.castle_tier)
            self.combat.progress.story.recruitment_tier = story.castle_tier;
        self.combat.progress.story.scenario = story;
        self.field_state.progress = self.combat.progress;
    }

    pub noinline fn tickWithFieldEvents(self: *State, input: pause.Input, combat_input: battle.Input) !pause.Effect {
        if (self.teleport_session) |saved| {
            var session = saved;
            const command: travel.teleport.Input = if (input.field.cancel) .cancel else if (input.field.action) .confirm else if (input.left) .left else if (input.right) .right else switch (input.field.menu_direction orelse return .none) {
                .up => .up,
                .down => .down,
                .left => .left,
                .right => .right,
            };
            if (command == .confirm and session.visibleCount() == 0) return .none;
            switch (try session.tick(command)) {
                .none => self.teleport_session = session,
                .cancelled => self.teleport_session = null,
                .confirmed => |proposal| {
                    try travel.commitTeleport(&session, self.package, &self.field_state, proposal);
                    self.combat.progress = self.field_state.progress;
                    self.teleport_session = null;
                    try self.onRoomChange(false);
                },
            }
            return .none;
        }
        if (self.side_game != null) {
            try side_games.tick(self, input);
            self.elapsed_ticks +|= 1;
            return .none;
        }
        if (self.item_overload != null) {
            try overload.tick(self, input);
            self.elapsed_ticks +|= 1;
            return .none;
        }
        if (self.pendingFieldMusic() != null) return .none;
        if (self.auto_travel != null) {
            try self.tickAutomaticTravel();
            return .none;
        }
        if (self.shouldTickBoat(input)) {
            try self.tickBoat(input.field.direction);
            return .none;
        }
        if (self.dice_game != null or self.party_selection != null) {
            if (self.dice_game != null and !dice.usesModel(self)) try dice.tickPlain(self, input);
            self.elapsed_ticks +|= 1;
            return .none;
        }
        if (self.field_event == null and self.menu.phase != .closed) {
            return self.tickCore(input, combat_input, .disabled);
        }
        try self.initializeRoomVisit();
        const consumed_action = try self.admitRoomEvent(input.field, .all);
        const owner = self.field_event orelse {
            if (self.handleReadyFieldEncounter()) return .none;
            const effect = try self.tickCore(input, combat_input, .enabled);
            if (self.mode == .field and self.menu.phase == .closed) if (self.field_state.wheel_state) |*wheel| wheel.advance();
            return effect;
        };
        const binding = owner.binding.*;
        if (self.mode != .field) {
            const effect = try self.tickCore(input, combat_input, .enabled);
            if (self.scripted_battle) |active| if (active.confirmed != null) {
                try self.resumeScriptedBattle(owner.session, binding);
            };
            return effect;
        }

        self.elapsed_ticks +|= 1;
        const before_entry = self.field_state.room_entries;
        if (owner.session.queuedBattle() == null) {
            const old_entry = self.field_state.room_entries;
            const saved_field_facing = self.field_state.facing;
            var field_input = input.field;
            if (consumed_action) field_input.action = false;
            const result = try owner.session.tickField(binding, &self.field_state, field_input);
            self.combat.progress = self.field_state.progress;
            if (owner.session.inn_payment_refused) {
                owner.session.inn_payment_refused = false;
                const message = if (self.field_state.inn_rules) |rules| rules.insufficient_funds else "Not enough bits to stay.";
                self.menu.notify(message);
            }
            if (result == .blocked) {
                if (try owner.session.pendingWheelSpin(binding)) {
                    if (self.combat.replay_draws != null) return error.InvalidBattleReplay;
                    var random = self.combat.random;
                    // shortcut: shared prototype PRNG; qualify BIOS sequence before claiming RNG parity.
                    const roll = random.random().int(u15);
                    const wheel = self.field_state.wheel_state orelse field.wheel.Room{};
                    if (wheel.startDraws() == 2) _ = random.random().int(u15);
                    try owner.session.acknowledgeWheelSpin(binding, &self.field_state, roll);
                    self.combat.random = random;
                    self.combat.progress = self.field_state.progress;
                } else try self.commitScenePartyEffect(owner);
            }
            if (old_entry == self.field_state.room_entries) {
                if (self.field_state.wheel_state) |*wheel| wheel.advance();
                try owner.session.advanceWheelGraphics(binding, self.field_state);
            }
            self.field_state.scene_ticks +%= 1;
            if (old_entry != self.field_state.room_entries) {
                if (self.field_state.auto_route_id != null) {
                    if (owner.session.busy()) return error.PendingCrossingDeparture;
                    const receipt = owner.session.receipt orelse return error.MissingCrossingReceipt;
                    const program = binding.content.program(receipt.program) orelse return error.UnknownEventProgram;
                    self.auto_travel = try travel.Active.begin(self.package, self.field_state, binding, program);
                } else if (std.mem.eql(u8, self.package.rooms[self.field_state.room].id, travel.source.world_room) and
                    self.field_state.progress.story.scenario.?.world_mode == 1)
                {
                    if (self.boat_data == null or owner.session.busy()) return error.MissingBoatOwner;
                    self.boat_travel = try travel.Boat.begin(self.package, self.field_state, saved_field_facing);
                    self.field_state.facing = .right;
                }
                const scripted_world_exit = if (self.room_battles) |rooms|
                    if (owner.session.receipt) |receipt|
                        owner.session == &rooms.session and rooms.isOpeningWorldExit(binding.room, receipt.program)
                    else
                        false
                else
                    false;
                try self.onRoomChange(scripted_world_exit);
            }
        }
        if (owner.session.queuedBattle() != null) try self.beginScriptedBattle(owner.session, binding);
        if (owner.session.queuedFixedDice() != null) try dice.begin(self);
        if (owner.session.queuedPartySelect() != null) try party_selection.begin(self);
        if (owner.session.queuedItemOverload() != null) try overload.begin(self);
        if (!owner.session.busy()) {
            if (self.room_battles) |rooms| if (before_entry == self.field_state.room_entries and owner.session == &rooms.session and
                std.mem.eql(u8, binding.room, self.package.rooms[self.field_state.room].id))
            {
                try rooms.retainSettledActors(binding, owner.session, self.field_state.room_entries, self.field_state.progress.story.scenario);
            };
            self.field_event = null;
        }
        if (self.field_event == null and self.menu.phase == .closed and self.field_state.pending_service != null) {
            const service = self.field_state.pending_service.?.kind;
            if (service == .cup_game or service == .card_game) {
                try side_games.begin(self, binding, owner.session.receipt orelse return error.MissingFieldGameRequest, service);
                self.field_state.pending_service = null;
                return .none;
            }
            if (service == .teleport) {
                const catalogue = self.teleport_catalogue orelse return error.MissingTeleportCatalogue;
                const story = self.combat.progress.story.scenario orelse return error.MissingSourceStoryState;
                const receipt = owner.session.receipt orelse return error.MissingFieldTeleportRequest;
                self.teleport_session = try travel.beginTeleport(catalogue, story, self.combat.progress.money, receipt.batch);
                self.field_state.pending_service = null;
                return .none;
            }
            if (service == .library or service == .window_styles or service == .sound_themes) {
                const story = if (self.field_state.progress.story.scenario) |*story| story else return error.MissingSourceStoryState;
                switch (service) {
                    .library => story.library_books |= try self.collectFacilityItems(&.{ .old_book_vol_1, .old_book_vol_2, .old_book_vol_3, .old_book_vol_4, .old_book_vol_5, .old_book_vol_6, .old_book_vol_7, .old_book_vol_8 }),
                    .window_styles => story.scenario[36] |= try self.collectFacilityItems(&.{ .window_setting_0, .window_setting_1, .window_setting_2, .window_setting_3 }),
                    .sound_themes => story.scenario[36] |= (try self.collectFacilityItems(&.{ .sound_setting_0, .sound_setting_1, .sound_setting_2, .sound_setting_3 })) << 4,
                    else => unreachable,
                }
            }
            const effect = self.menu.tickWithArrival(self.package, &self.field_state, .{}, .immediate);
            self.combat.progress = self.field_state.progress;
            return effect;
        }
        return .none;
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
        if (self.auto_travel == null and self.handleReadyFieldEncounter()) return .none;
        return self.tickCore(input, combat_input, .disabled) catch |err| {
            std.log.warn("Room setup failed: {s}", .{@errorName(err)});
            self.menu.notify("Room setup failed.");
            return .none;
        };
    }

    fn handleReadyFieldEncounter(self: *State) bool {
        return battle_flow.beginReadyFieldEncounter(self) catch |err| {
            self.field_encounter_clock.ready = false;
            std.log.warn("Field encounter could not start: {s}", .{@errorName(err)});
            self.menu.notify("The field encounter could not start.");
            return true;
        };
    }

    fn clearWorldEncounterSuppression(self: *State) !void {
        const encounters = self.data.field_encounters orelse return;
        if (!encounters.clear_suppression_on_world_entry) return;
        var story = self.field_state.progress.story.scenario orelse if (self.room_battles) |rooms| rooms.initial_story else return;
        try story.clear(encounters.suppress_when.?.flag);
        self.field_state.progress.story.scenario = story;
        self.combat.progress.story.scenario = story;
    }

    fn onRoomChange(self: *State, scripted_world_exit: bool) !void {
        self.field_state.reconcileWorldEntry(self.package, null);
        if (self.room_battles) |rooms| {
            rooms.settled_actors = null;
        }
        const world_entry = scripted_world_exit or self.field_state.crossed_world_exit;
        if (world_entry) try self.clearWorldEncounterSuppression();
        if (world_entry and self.route.stage == .first_town) {
            _ = self.route.complete(.first_town) catch unreachable;
        } else self.syncRoute();
        self.join_failure_room = null;
        const new_id = roomId(self.package, self.field_state.room);
        if (!std.mem.eql(u8, new_id, "va1_room_0")) self.town_home_ticks = 0;
        if (!std.mem.eql(u8, new_id, "va1_room_1")) self.town_room_ticks = 0;
        if (!std.mem.eql(u8, new_id, "va1_room_2")) self.town_world_ticks = 0;
        if (!std.mem.eql(u8, new_id, "world_a")) self.world_battle_ticks = 0;
        self.enterEncounterRoom();
        try self.initializeRoomVisit();
    }

    fn usesDerivedRoomExit(self: *const State, room: []const u8) bool {
        const current = self.package.rooms[self.field_state.room];
        if (!std.mem.eql(u8, current.id, room) or current.hasWorldExit()) return false;
        if (self.room_battles) |rooms| return rooms.opening_route == null and !rooms.ownsRoomExit(room);
        return true;
    }

    fn tickAutomaticTravel(self: *State) !void {
        if (self.mode != .field or self.menu.phase != .closed) return error.InvalidCrossingOwner;
        const arrived = try self.auto_travel.?.tick(self.package, &self.field_state);
        self.elapsed_ticks +|= 1;
        self.combat.progress = self.field_state.progress;
        if (arrived) {
            self.auto_travel = null;
            self.field_event = null;
            try self.onRoomChange(false);
        }
    }

    fn shouldTickBoat(self: *const State, input: pause.Input) bool {
        return self.boat_travel != null and self.mode == .field and self.menu.phase == .closed and
            !(input.menu and self.field_state.remaining == 0);
    }

    fn tickBoat(self: *State, direction: ?field.Direction) !void {
        const packet = self.boat_data orelse return error.MissingBoatOwner;
        const arrived = try self.boat_travel.?.tick(packet.*, self.package, &self.field_state, direction);
        self.elapsed_ticks +|= 1;
        self.combat.progress = self.field_state.progress;
        if (arrived) {
            self.boat_travel = null;
            self.field_event = null;
            try self.onRoomChange(false);
        }
    }

    pub fn startDuelById(self: *State, allocator: std.mem.Allocator, duel_id: []const u8) !void {
        if (self.mode != .field or self.active_duel != null or self.active_war != null or self.active_ending != null) return error.GameBusy;
        const player = blk: {
            const target_id = if (std.mem.eql(u8, duel_id, "pahn_teo")) "pahn" else "hero";
            for (self.combat.progress.party, 0..) |member, index| {
                if (std.mem.eql(u8, member.id, target_id)) break :blk duelFighter(member, self.combat.stats(index));
            }
            for (self.reserves, self.reserve_extras) |entry, extra| if (entry) |owned| {
                if (!std.mem.eql(u8, owned.member.id, target_id)) continue;
                const augment: battle.systems.WeaponAugment = if (extra) |value| party_session.weaponAugment(value) else .{};
                break :blk duelFighter(owned.member, battle.equippedStats(self.combat.content, owned, augment));
            };
            break :blk duel.FighterState{ .maximum_hp = 240, .hp = 240, .attack = 160, .defense = 80 };
        };
        const seed: u32 = @max(@as(u32, 1), @as(u32, @truncate(self.elapsed_ticks +% 1)));
        try self.startDuelWithOpponent(allocator, duel_id, player, null, .{ .bios_state = seed });
    }

    fn duelFighter(member: battle.Member, stats: battle.Stats) duel.FighterState {
        const maximum_hp: i32 = @max(@as(i32, member.max_hp), 1);
        return .{ .maximum_hp = maximum_hp, .hp = std.math.clamp(@as(i32, member.hp), 1, maximum_hp), .attack = stats.attack, .defense = stats.defense };
    }

    pub fn startDuel(self: *State, allocator: std.mem.Allocator, duel_id: []const u8, fighters: [2]duel.FighterState, random: duel.Random) !void {
        try self.startDuelWithOpponent(allocator, duel_id, fighters[0], fighters[1], random);
    }

    fn startDuelWithOpponent(self: *State, allocator: std.mem.Allocator, duel_id: []const u8, player: duel.FighterState, opponent: ?duel.FighterState, random: duel.Random) !void {
        if (self.mode != .field or self.active_duel != null or self.active_war != null or self.active_ending != null) return error.GameBusy;
        var parsed = try duel.load(allocator, duel.content_json);
        errdefer parsed.deinit();
        const entry = duel.findDuel(&parsed.value, duel_id) orelse return error.UnknownDuel;
        const initial_opponent = opponent orelse entry.initial_opponent orelse return error.InvalidDuelContent;
        const duel_state = try duel.State.init(&parsed.value, duel_id, .{ player, initial_opponent }, random);
        self.active_duel = .{ .parsed = parsed, .state = duel_state };
        self.mode = .duel;
        self.field_state.walking = false;
        self.field_state.action_pending = false;
    }

    pub fn chooseDuelCommand(self: *State, command: duel.Command) !void {
        if (self.mode != .duel) return error.NotInDuel;
        const active = &(self.active_duel orelse return error.NotInDuel);
        try active.state.choose(command);
    }

    pub fn tickDuel(self: *State, up: bool, down: bool, confirm: bool) !void {
        if (self.mode != .duel) return error.NotInDuel;
        const active = &(self.active_duel orelse return error.NotInDuel);
        switch (active.state.phase) {
            .choosing => {
                if (up) try active.state.moveSelection(-1) else if (down) try active.state.moveSelection(1);
                if (confirm) try active.state.confirm();
            },
            .finished => if (confirm) {
                const outcome = active.state.outcome orelse .defeat;
                const won = outcome == .victory;
                if (self.scripted_battle) |*scripted| {
                    if (std.mem.eql(u8, scripted.request.id, "duel:pahn_teo")) {
                        const bit: u8 = if (won) 1 else 2;
                        if (self.field_state.progress.story.scenario) |*story| roster.recordPahnDuel(story, bit);
                        if (self.combat.progress.story.scenario) |*story| roster.recordPahnDuel(story, bit);
                    }
                    if (won or self.defeatContinuesScene() or !self.defeatEndsRun()) {
                        scripted.confirmed = if (!won and self.defeatContinuesScene()) .defeat else .victory;
                        return;
                    }
                    active.parsed.deinit();
                    self.active_duel = null;
                    self.checkpoint = null;
                    self.field_event = null;
                    self.scripted_battle = null;
                    self.mode = .game_over;
                    return;
                }
                active.parsed.deinit();
                self.active_duel = null;
                self.mode = if (won) .field else .defeat;
            },
            else => try active.state.tick(),
        }
    }

    pub fn startEnding(self: *State, allocator: std.mem.Allocator) !void {
        if (self.mode != .field or self.active_duel != null or self.active_war != null or self.active_ending != null) return error.GameBusy;
        var parsed = try chapters.endings.open(allocator, final_assets.endings.json);
        errdefer parsed.deinit();
        var recruit_flags: [108]u8 = @splat(0);
        if (self.field_state.progress.story.scenario) |story| recruit_flags = roster.recruitFlags(story);
        recruit_flags[8] |= 1;
        const census = try chapters.endings.census(parsed.value, &recruit_flags);
        self.active_ending = .{ .parsed = parsed, .census = census, .recruit_flags = recruit_flags };
        self.mode = .ending;
        self.field_state.walking = false;
        self.field_state.action_pending = false;
    }

    pub fn tickEnding(self: *State, up: bool, down: bool, confirm: bool) !void {
        if (self.mode != .ending) return error.NotInEnding;
        const active = &(self.active_ending orelse return error.NotInEnding);
        const total_phases = active.parsed.value.bounded_ending.main_ending_phases;
        if (active.phase_index < total_phases) {
            if (confirm) active.phase_index += 1;
            return;
        }
        const total_entries: u16 = @intCast(active.parsed.value.entries.len);
        if (up and active.entry_cursor > 0) active.entry_cursor -= 1;
        if (down and active.entry_cursor + 8 < total_entries) active.entry_cursor += 1;
        if (confirm) {
            if (self.scripted_battle) |*scripted| {
                scripted.confirmed = .victory;
                return;
            }
            active.parsed.deinit();
            self.active_ending = null;
            self.mode = .field;
        }
    }

    pub fn startWar(self: *State, allocator: std.mem.Allocator, entry: war_session.Entry) !void {
        if (self.mode != .field or self.active_duel != null or self.active_war != null) return error.GameBusy;
        const session = try war_session.Session.init(allocator, entry);
        self.active_war = .{ .session = session };
        self.mode = .war;
        self.field_state.walking = false;
        self.field_state.action_pending = false;
    }

    pub fn startWarById(self: *State, allocator: std.mem.Allocator, scenario_id: []const u8, rng_state: u32) !void {
        if (self.mode != .field or self.active_duel != null or self.active_war != null) return error.GameBusy;
        const parsed = try war.load(allocator, war_scenarios_data.json);
        errdefer parsed.deinit();
        const scenario = for (parsed.value.scenarios) |row| {
            if (std.mem.eql(u8, row.id, scenario_id)) break row;
        } else return error.UnknownWarScenario;
        const session = try war_session.Session.init(allocator, .{ .scenario = scenario, .rng = .{ .state = rng_state } });
        self.active_war = .{ .session = session, .parsed = parsed };
        self.mode = .war;
        self.field_state.walking = false;
        self.field_state.action_pending = false;
    }

    pub fn tickWar(self: *State, input: war_session.Input) !void {
        if (self.mode != .war) return error.NotInWar;
        const active = &(self.active_war orelse return error.NotInWar);
        if (active.session.engine.phase == .result) {
            if (input.confirm) {
                const result = active.session.engine.result orelse return error.InvalidWarState;
                const won = result.outcome != .forced_defeat and result.outcome != .side1_victory;
                if (self.scripted_battle) |*scripted| {
                    if (won or self.defeatContinuesScene()) {
                        scripted.confirmed = if (won) .victory else .defeat;
                        return;
                    }
                    active.session.deinit();
                    if (active.parsed) |parsed| parsed.deinit();
                    self.active_war = null;
                    self.checkpoint = null;
                    self.field_event = null;
                    self.scripted_battle = null;
                    self.mode = .game_over;
                    return;
                }
                active.session.deinit();
                if (active.parsed) |parsed| parsed.deinit();
                self.active_war = null;
                self.mode = if (won) .field else .defeat;
            }
            return;
        }
        try active.session.update(input);
    }

    fn tickCore(self: *State, input: pause.Input, combat_input: battle.Input, room_events: enum { enabled, disabled }) !pause.Effect {
        if (self.shouldTickBoat(input)) {
            try self.tickBoat(input.field.direction);
            return .none;
        }
        if (self.auto_travel != null) {
            try self.tickAutomaticTravel();
            return .none;
        }
        if (self.dice_game != null or self.party_selection != null) {
            self.elapsed_ticks +|= 1;
            return .none;
        }
        if (self.mode == .game_over) return .none;
        if (self.mode != .field or self.menu.phase == .closed) self.elapsed_ticks +|= 1;
        if (self.mode == .duel) {
            try self.tickDuel(combat_input.up, combat_input.down, combat_input.confirm);
            return .none;
        }
        if (self.mode == .ending) {
            try self.tickEnding(combat_input.up, combat_input.down, combat_input.confirm);
            return .none;
        }
        if (self.mode == .war) {
            try self.tickWar(.{
                .up = input.field.menu_direction == .up,
                .down = input.field.menu_direction == .down,
                .left = input.left,
                .right = input.right,
                .confirm = combat_input.confirm,
                .cancel = combat_input.cancel,
            });
            return .none;
        }
        self.bind();
        if (self.mode == .defeat) {
            if (self.combat.hasDepartureFlights()) {
                self.combat.advanceDefeatDeparture();
            } else if (combat_input.confirm) {
                if (self.defeatContinuesScene()) {
                    self.scripted_battle.?.confirmed = .defeat;
                } else if (self.defeatEndsRun() or self.checkpoint == null) {
                    self.mode = .game_over;
                    self.checkpoint = null;
                    self.field_event = null;
                    self.scripted_battle = null;
                } else battle_flow.retryCombat(self) catch unreachable;
            }
            return .none;
        }
        if (self.mode == .battle) {
            if (self.scripted_battle) |active| if (active.confirmed != null) return .none;
            const result: ?ScriptedBattleResult = if (combat_input.confirm) switch (self.combat.phase) {
                .victory => if (self.combat.rewardReady()) .victory else null,
                .escaped => .escape,
                else => null,
            } else null;
            if (result) |outcome| {
                if (self.scripted_battle) |*active| active.confirmed = outcome else self.returnFromBattle(outcome == .victory);
            } else {
                var action = combat_input;
                if (self.scripted_battle != null) action.restart = false;
                // Field encounters leave through Run/Let go, rather than the isolated trial's quit menu.
                if (self.combat.phase == .battle_menu) action.cancel = false;
                self.combat.tick(action);
                if (self.combat.phase == .defeat) self.mode = .defeat;
            }
            return .none;
        }
        self.field_state.progress = self.combat.progress;
        const old_room = self.field_state.room;
        const old_entry = self.field_state.room_entries;
        const old_x = self.field_state.x;
        const old_y = self.field_state.y;
        const old_dialogue = self.field_state.dialogue;
        const old_movement_updates = self.field_state.movement_updates;
        const can_arm = self.menu.phase == .closed and !self.menu.pending and !input.menu and
            old_dialogue == null and self.field_state.rest_ticks == 0 and self.field_state.remaining == 0 and input.field.direction != null;
        var menu_input = input;
        menu_input.weapon_pieces = true;
        menu_input.has_shared_items = self.shared_items[0] != null;
        menu_input.travel_tools = self.teleport_catalogue != null;
        const arrival: field.StepArrival = if (room_events == .enabled and self.room_battles != null and
            self.room_battles.?.bindingFor(self.package.rooms[old_room].id) != null) .deferred else .immediate;
        const ground_ctx: BoundaryGroundContext = .{ .state = self, .direction = input.field.direction };
        const ground: ?field.Ground = if (arrival == .deferred) .{
            .context = &ground_ctx,
            .query = roomBoundaryGroundQuery,
            .authoritative = true,
        } else null;
        var effect = self.menu.tickWithArrivalAndGround(self.package, &self.field_state, menu_input, arrival, ground);
        self.combat.progress = self.field_state.progress;
        if (effect == .blinking_mirror) {
            travel.useMirror(self.teleport_catalogue.?, self.package, &self.field_state, self.menu.member, self.menu.slot) catch |err| {
                if (err != error.OutsideRequired) return err;
                self.menu.message = "Use the Blinking Mirror on the world map.";
                self.menu.phase = .item_notice;
                return .none;
            };
            self.boat_travel = null;
            self.combat.progress = self.field_state.progress;
            self.menu.phase = .closed;
            try self.onRoomChange(false);
            return .none;
        }
        if (effect == .weapon_piece) {
            roster.useWeaponPiece(self, self.menu.member, self.menu.slot, self.menu.target, self.menu.weapon_piece_replace) catch |err| {
                if (err == error.ReplacementConfirmationRequired) {
                    self.menu.phase = .confirm_weapon_piece;
                    self.menu.yes = false;
                } else {
                    self.menu.message = if (err == error.WeaponPieceLimit) "This weapon already has nine pieces." else "The rune piece could not be used.";
                }
                effect = .none;
                return effect;
            };
            self.menu.message = "Rune piece attached to weapon.";
            self.menu.slot = @min(self.menu.slot, self.combat.progress.party[self.menu.member].inventory.count() -| 1);
            effect = .none;
        }
        const moved = old_movement_updates != self.field_state.movement_updates;
        if (arrival == .deferred and moved and self.field_state.remaining == 0) {
            _ = try self.admitRoomEvent(.{ .direction = input.field.direction }, .automatic);
            if (self.field_event == null) {
                self.field_state.finishStepArrival(self.package);
                self.menu.finishPending(&self.field_state);
                self.combat.progress = self.field_state.progress;
            } else self.menu.pending = false;
        }
        if (old_entry != self.field_state.room_entries) try self.onRoomChange(false);
        if (moved) {
            self.combat.applyFieldStatuses();
            self.field_state.progress = self.combat.progress;
        }
        if (self.field_event != null) {
            if (self.data.field_encounters) |configured| {
                if (configured.forRoom(self.package.rooms[old_room].id) != null) self.field_encounter_clock.updates +|= @intFromBool(moved);
            }
            return effect;
        }
        const has_world_movement = if (self.data.field_encounters) |configured| configured.forRoom("world_a") != null else false;
        if (!has_world_movement and self.world_battle_enabled and !self.world_battle_started and !self.combat.progress.story.world_patrol_won and std.mem.eql(u8, self.package.rooms[self.field_state.room].id, "world_a")) {
            var in_patrol_region = false;
            for (self.data.encounters) |trigger| {
                if (std.mem.eql(u8, trigger.room, "world_a") and self.containsLegacyTrigger(trigger)) in_patrol_region = true;
            }
            if (!in_patrol_region) self.world_battle_ticks = 0;
            self.world_battle_ticks +|= if (in_patrol_region) 1 else 0;
            if (self.world_battle_ticks >= 30 and in_patrol_region) {
                for (self.data.encounters, 0..) |trigger, i| {
                    if (!std.mem.eql(u8, trigger.room, "world_a") or !self.containsLegacyTrigger(trigger)) continue;
                    self.beginEncounter(i) catch continue;
                    self.world_battle_started = true;
                    break;
                }
            }
        }
        if (self.party_catalog) |catalog| {
            if (self.derived_scene_cadence and self.menu.phase == .closed and self.field_state.dialogue == null) {
                if (self.usesDerivedRoomExit("va1_room_0")) {
                    self.town_home_ticks +|= 1;
                    if (self.town_home_ticks >= 30 and self.field_state.remaining == 0) {
                        if (self.package.roomIndex("va1_room_1")) |next| {
                            self.field_state.enterRoom(next, .{ .x = 184, .y = 352 });
                            self.town_room_ticks = 0;
                            try self.onRoomChange(false);
                        }
                    }
                }
                if (self.usesDerivedRoomExit("va1_room_1")) {
                    self.town_room_ticks +|= 1;
                    if (self.town_room_ticks >= 30 and self.field_state.remaining == 0) {
                        if (self.package.roomIndex("va1_room_2")) |next| {
                            self.field_state.enterRoom(next, .{ .x = 152, .y = 264 });
                            try self.onRoomChange(false);
                        }
                    }
                }
                if (self.usesPrototypeWorldExit() and self.usesDerivedRoomExit("va1_room_2")) {
                    self.town_world_ticks +|= 1;
                    if (self.town_world_ticks >= 30 and self.field_state.remaining == 0) {
                        if (self.package.roomIndex("world_a")) |next| {
                            self.field_state.enterRoom(next, .{ .x = 640, .y = 480 });
                            try self.onRoomChange(false);
                        }
                    }
                }
            }
            self.joinOnRoomEntry(self.party_backing.?, catalog, self.party_bindings, self.package.rooms[self.field_state.room].id) catch {
                const room: u16 = @intCast(self.field_state.room);
                if (self.join_failure_room != room) {
                    self.join_failure_room = room;
                    self.menu.notify("Party join could not complete.\nParty and story state were preserved.");
                }
            };
        }
        const movement_encounters = if (self.data.field_encounters) |configured|
            configured.forRoom(roomId(self.package, self.field_state.room)) != null
        else
            false;
        if (old_entry == self.field_state.room_entries and movement_encounters) {
            self.field_encounter_clock.updates +|= @intFromBool(moved);
            if (can_arm and self.menu.phase == .closed and self.field_state.dialogue == null) self.field_encounter_clock.ready = true;
        }
        if (old_dialogue != null and self.field_state.dialogue == null and input.field.action and old_dialogue.?.source == .npc) {
            const npc = self.package.rooms[old_room].npcs[old_dialogue.?.source.npc];
            if (!input.field.cancel and old_dialogue.?.phase == .recruitment_joined and std.mem.eql(u8, npc.id, "maas")) {
                self.recruitMaas() catch {
                    self.menu.notify("Recruitment could not complete.\nParty and story state were preserved.");
                };
            }
        }
        self.applyFieldInteractions(old_room, old_dialogue, input.field);
        if (self.suppressed_trigger) |i| if (!self.containsLegacyTrigger(self.data.encounters[i])) {
            self.suppressed_trigger = null;
        };
        if (!movement_encounters and effect == .none and self.menu.phase == .closed and self.field_state.dialogue == null and self.field_state.remaining == 0 and (old_room != self.field_state.room or old_x != self.field_state.x or old_y != self.field_state.y)) {
            for (self.data.encounters, 0..) |trigger, i| if (!std.mem.eql(u8, trigger.room, "world_a") and self.suppressed_trigger != i and !self.combat.progress.story.has(trigger.flag) and self.containsLegacyTrigger(trigger)) {
                if (room_events == .enabled) {
                    _ = try self.admitRoomEvent(.{ .direction = input.field.direction }, .automatic);
                    if (self.field_event != null) break;
                }
                self.beginEncounter(i) catch unreachable;
                break;
            };
        }
        return effect;
    }
    // Shared episode effects; canonical script execution and encounter selection remain separate.
    pub fn applyFieldInteractions(self: *State, old_room: usize, old_dialogue: ?field.Dialogue, input: field.Input) void {
        if (old_dialogue != null and self.field_state.dialogue == null and input.action and old_dialogue.?.source == .npc) {
            const npc = self.package.rooms[old_room].npcs[old_dialogue.?.source.npc];
            if (std.mem.eql(u8, npc.id, "forest_villager")) self.combat.progress.story.complete(.heard_forest_warning);
        }
        if (self.field_state.dialogue) |dialogue| if (dialogue.source == .npc) {
            const room = self.package.rooms[self.field_state.room];
            const npc = room.npcs[dialogue.source.npc];
            for (self.data.treasures) |treasure| if (std.mem.eql(u8, treasure.room, room.id) and std.mem.eql(u8, treasure.npc, npc.id) and !self.combat.progress.story.has(treasure.flag)) {
                var recipient: ?usize = null;
                for (self.combat.progress.party, 0..) |member, i| if (member.inventory.count() < 9) {
                    recipient = i;
                    break;
                };
                if (recipient) |i| {
                    const inventory = &self.combat.progress.party[i].inventory;
                    inventory.slots[inventory.count()] = .{ .id = treasure.item, .uses = treasure.uses };
                    self.combat.progress.story.complete(treasure.flag);
                } else {
                    self.field_state.dialogue = null;
                    self.menu.notify("All inventories are full.\nThe chest remains closed.");
                }
            };
        };
        const story = &self.combat.progress.story;
        if (story.heard_forest_warning and story.forest_elf_seen and story.forest_treasure_needle and story.forest_treasure_water and story.forest_battle_one_won and story.forest_battle_two_won and story.forest_battle_three_won and std.mem.eql(u8, self.package.rooms[self.field_state.room].id, "vb6_village")) story.complete(.forest_returned);
        self.field_state.progress = self.combat.progress;
    }
    pub fn episodeObjective(self: *const State) ?[]const u8 {
        if (usesOpeningSeed(self.package.start_room) or self.packagedOpeningRoute() != null) return null;
        const story = self.combat.progress.story;
        if (story.forest_returned) return "Episode complete. Rest, shop, explore or save your party.";
        if (!story.heard_forest_warning) return "Speak to the villager northeast of the inn about the Great Forest.";
        if (!story.forest_elf_seen) return "Visit the central village path to see the elf encounter.";
        if (!story.forest_entered) return "Follow the eastern path from the village into the Great Forest.";
        if (!story.forest_treasure_needle or !story.forest_treasure_water) return "Explore the branching forest paths and open both chests.";
        if (!story.forest_battle_one_won or !story.forest_battle_two_won or !story.forest_battle_three_won) return "Clear the encounters along the forest route.";
        return "Return west to the village. Party progress carries with you.";
    }
};

pub fn usesOpeningSeed(start_room: []const u8) bool {
    return std.mem.eql(u8, start_room, "vaa_room_1") or std.mem.eql(u8, start_room, "vaa_room_2");
}

const BoundaryGroundContext = struct {
    state: *const State,
    direction: ?field.Direction,
};

fn roomBoundaryGroundQuery(context: *const anyopaque, room_id: []const u8, x: i32, y: i32) bool {
    const info: *const BoundaryGroundContext = @ptrCast(@alignCast(context));
    const room_index = info.state.package.roomIndex(room_id) orelse return false;
    const room = info.state.package.rooms[room_index];
    const scenery = if (info.state.field_state.room_scenery) |*visit| visit else null;
    if (room.canStandWithScenery(scenery, x, y)) return true;
    if (!room.contains(x, y)) return false;
    if (x != room.width - 8 and y != room.height - 8) return false;
    const rooms = info.state.room_battles orelse return false;
    const story = &(info.state.field_state.progress.story.scenario orelse return false);
    const retained_world = if (info.state.field_state.world_context) |ctx|
        info.state.package.rooms[ctx.room].id
    else
        null;
    return rooms.ordinaryTransitionAt(
        room.id,
        story,
        @intCast(info.state.combat.partyCount()),
        &info.state.field_state.local_flags.values,
        info.state.field_state.progress.money,
        @divExact(x, 8),
        @divExact(y, 8),
        retained_world,
        info.direction,
    ) != null;
}

pub const Snapshot = @import("journey_save").Snapshot;

pub const filename = @import("journey_save").filename;
pub const backup_filename = @import("journey_save").backup_filename;
pub const RestoreSource = @import("journey_save").RestoreSource;
pub const validateSnapshotFields = @import("journey_save").validateSnapshotFields;
pub const validateNestedSnapshotFields = @import("journey_save").validateNestedSnapshotFields;
pub const decodeSnapshot = @import("journey_save").decodeSnapshot;
pub const slotFilename = @import("journey_save").slotFilename;
pub const save = @import("journey_save").save;
pub const saveSlot = @import("journey_save").saveSlot;
pub const restoreWithSource = @import("journey_save").restoreWithSource;
pub const restoreSlotWithSource = @import("journey_save").restoreSlotWithSource;
pub const restore = @import("journey_save").restore;
pub const summaries = @import("journey_save").summaries;
