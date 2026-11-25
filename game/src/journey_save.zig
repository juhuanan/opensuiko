//! Journey checkpoint shape and migration rules.
const std = @import("std");
const field = @import("field");
const battle = @import("battle");
const party_session = @import("party_session");
const pause = @import("pause_menu");
const opening_route = @import("route");
const campaign_state = @import("campaign_state");
const hq_state = @import("hq_state");
const travel = @import("journey_travel");
const ordinary = @import("field_actors");

pub const Reserves = [72]?battle.OwnedMember;
pub const SharedItems = @FieldType(party_session.Snapshot, "shared");

fn emptyExtra(extra: party_session.CharacterExtra) bool {
    if (extra.member_id.len != 0 or extra.weapon_element != .none) return false;
    for (extra.weapon_fragments) |count| if (count != 0) return false;
    for (extra.locked_equipment) |locked| if (locked) return false;
    return true;
}

const current_save_version = 43;
const save_prefix = "suikoden-journey-save/";

fn saveVersion(schema: []const u8) !u8 {
    if (!std.mem.startsWith(u8, schema, save_prefix)) return error.UnsupportedSaveVersion;
    const digits = schema[save_prefix.len..];
    if (digits.len == 0 or digits.len > 2 or digits[0] == '0') return error.UnsupportedSaveVersion;
    for (digits) |digit| if (!std.ascii.isDigit(digit)) return error.UnsupportedSaveVersion;
    const version = std.fmt.parseInt(u8, digits, 10) catch unreachable;
    if (version > current_save_version) return error.UnsupportedSaveVersion;
    return version;
}

pub const Snapshot = struct {
    pub const EncounterClock = struct {
        updates: u16 = 0,
        ready: bool = false,
        enabled: bool = true,
    };

    pub const WorldContext = struct { room: []const u8, entry: ?[]const u8 = null };
    pub const OptionalGames = struct {
        cup_profit: i32 = 0,
        card_records: [4]u32 = @splat(0),
    };

    optional_games: ?OptionalGames = null,
    world_context: ?WorldContext = null,
    room_actors: ?ordinary.State = null,
    save_name: ?pause.save_slots.Label = null,
    elapsed_ticks: ?u64 = null,
    schema: []const u8,
    spell_scene_hash: ?[32]u8 = null,
    unite_actor_hash: ?[32]u8 = null,
    room: []const u8,
    x: i32,
    y: i32,
    facing: field.Direction,
    money: u32,
    story: field.game_state.Story,
    party: [6]battle.Member,
    party_count: u8 = 6,
    extras: [6]party_session.CharacterExtra = @splat(.{ .member_id = "" }),
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
    levels: [6]u8,
    experience: [6]u32,
    stats: [6]battle.Stats,
    formation: [6]u8,
    weapon_levels: ?[6]u8 = null,
    equipment: [6]?usize,
    loadouts: ?[6]battle.systems.Loadout = null,
    runes: [6]?usize,
    random: std.Random.DefaultPrng,
    field_music: ?field.game_state.event_runtime.FieldMusic = null,
    auxiliary_party: ?[6]u8 = null,
    field_encounter_clock: ?EncounterClock = null,
    pending_room_arrival: bool = false,
    suppressed_trigger_id: ?[]const u8 = null,
    room_flags: ?field.room_flags.State = null,
    shown_props: ?u64 = null,
    room_scenery: ?field.scenery.State = null,
    wheel_state: ?field.wheel.Room = null,
    storage: ?field.game_state.storage.Storage = null,
    shared_items: ?SharedItems = null,
    reserves: ?Reserves = null,
    reserve_extras: ?[72]?party_session.CharacterExtra = null,
    opening_event: ?[]const u8 = null,
    route: ?opening_route.Checkpoint = null,
    campaign: ?campaign_state.Snapshot = null,
    hq: ?hq_state.HqState = null,
    boat_travel: ?travel.Boat = null,

    pub fn capture(state: anytype) !Snapshot {
        const world = &state.field_state;
        if (state.mode != .field or state.dice_game != null or state.side_game != null or state.teleport_session != null or state.party_selection != null or state.item_overload != null or state.auto_travel != null or world.auto_route_id != null or world.remaining != 0 or world.dialogue != null or world.rest_ticks != 0) return error.GameBusy;
        const combat = &state.combat;
        if (state.boat_travel) |boat| try boat.validate((state.boat_data orelse return error.MissingBoatOwner).*, state.package.rooms[world.room].id, world.x, world.y, world.facing, combat.progress.story.scenario orelse return error.MissingSourceStoryState);
        const count: u8 = @intCast(combat.partyCount());
        var snapshot: Snapshot = .{ .schema = std.fmt.comptimePrint("{s}{d}", .{ save_prefix, current_save_version }), .spell_scene_hash = if (combat.spell_scenes) |packet| try packet.digest() else null, .unite_actor_hash = if (combat.unite_actors) |packet| try packet.digest() else null, .party_count = count, .party = @splat(combat.progress.party[0]), .extras = state.extras, .reserves = state.reserves, .reserve_extras = state.reserve_extras, .storage = combat.progress.storage, .save_name = state.save_name, .elapsed_ticks = state.elapsed_ticks, .room = state.package.rooms[world.room].id, .x = world.x, .y = world.y, .facing = world.facing, .field_music = world.music, .money = combat.progress.money, .story = combat.progress.story, .levels = combat.levels, .experience = combat.experience, .stats = combat.base_stats, .formation = combat.formation, .weapon_levels = combat.weapon_levels, .equipment = combat.headEquipment(), .loadouts = combat.loadouts, .runes = combat.runes, .random = combat.random, .opening_event = state.opening_event, .route = state.route.checkpoint(), .campaign = state.campaign, .hq = state.hq, .world_battle_enabled = state.world_battle_enabled, .world_battle_ticks = state.world_battle_ticks, .world_battle_started = state.world_battle_started };
        snapshot.auxiliary_party = world.auxiliary_party;
        if (!std.meta.eql(state.optional_games, OptionalGames{})) snapshot.optional_games = state.optional_games;
        snapshot.wheel_state = world.wheel_state;
        if (world.world_context) |context| snapshot.world_context = .{
            .room = state.package.rooms[context.room].id,
            .entry = if (context.entry) |index| state.package.world_entries[index].id else null,
        };

        if (state.data.field_encounters) |encounters| {
            if (encounters.forRoom(snapshot.room) != null) snapshot.field_encounter_clock = state.field_encounter_clock;
        }
        snapshot.boat_travel = state.boat_travel;
        if (state.room_battles) |rooms| {
            snapshot.pending_room_arrival = state.checked_arrival_visit != world.room_entries and rooms.bindingFor(snapshot.room) != null;
            if (rooms.bindingFor(snapshot.room)) |binding| if (rooms.settledForVisit(binding, world.room_entries)) |retained| {
                snapshot.room_actors = retained.state;
            };
        }
        if (state.suppressed_trigger) |index| {
            const trigger = state.data.encounters[index];
            if (state.containsLegacyTrigger(trigger)) snapshot.suppressed_trigger_id = trigger.id;
        }
        if (!std.mem.allEqual(u8, &world.local_flags.values, 0)) snapshot.room_flags = world.local_flags;
        if (world.shown_props != 0) snapshot.shown_props = world.shown_props;
        snapshot.room_scenery = world.room_scenery;
        for (state.shared_items) |item| if (item != null) {
            snapshot.shared_items = state.shared_items;
            break;
        };
        for (0..count) |i| snapshot.party[i] = combat.progress.party[i];
        return snapshot;
    }
    pub fn validate(self: *const Snapshot, state: anytype) !void {
        const version = try saveVersion(self.schema);
        if (self.optional_games != null and version < 43) return error.InvalidSave;
        if (self.room_actors) |actors| {
            if (version < 41) return error.InvalidSave;
            const rooms = state.room_battles orelse return error.InvalidSave;
            const binding = rooms.bindingFor(self.room) orelse return error.InvalidSave;
            const packet = binding.ordinary orelse return error.InvalidSave;
            try actors.validate(packet, binding.animations);
            const quiet = try actors.settle(packet, binding.animations);
            if (!std.meta.eql(quiet.settled_positions, actors.settled_positions) or !std.meta.eql(quiet.slots, actors.slots)) return error.InvalidSave;
        }
        if (self.world_context) |context| {
            if (version < 40) return error.InvalidSave;
            _ = state.package.roomIndex(context.room) orelse return error.InvalidSave;
            var known = false;
            for (state.package.world_entries) |entry| if (std.mem.eql(u8, entry.world_room, context.room)) {
                known = true;
                break;
            };
            if (!known) return error.InvalidSave;
            if (context.entry) |id| {
                const entry = state.package.world_entries[state.package.worldEntryIndex(id) orelse return error.InvalidSave];
                if (!std.mem.eql(u8, entry.world_room, context.room)) return error.InvalidSave;
            }
        }

        if (version < 34 and self.field_music == .infiltration) return error.InvalidSave;
        if (self.wheel_state) |wheel| {
            if (version < 39) return error.InvalidSave;
            try wheel.validate();
            if (wheel.clock.phase != null or wheel.clock.alignment != null) return error.InvalidSave;
            const rooms = state.room_battles orelse return error.InvalidSave;
            const binding = rooms.bindingFor(self.room) orelse return error.InvalidSave;
            if (!binding.content.hasWheelMotion()) return error.InvalidSave;
        }
        if (version < 37 and self.field_music == .wheel) return error.InvalidSave;
        if (version < 36 and self.field_music == .mansion) return error.InvalidSave;
        if (version < 33 and self.boat_travel != null) return error.InvalidSave;
        if (version < 29 and self.field_music != null) return error.InvalidSave;
        if (version < 30 and self.field_music == .headquarters) return error.InvalidSave;
        if (version < 31 and self.field_music == .founding) return error.InvalidSave;
        if (version < 32 and self.auxiliary_party != null) return error.InvalidSave;
        if (self.field_music == .fade) return error.InvalidSave;
        if (version < 22 and self.field_encounter_clock != null) return error.InvalidSave;
        if (version < 24 and self.pending_room_arrival) return error.InvalidSave;
        if (self.suppressed_trigger_id) |id| if (version < 25 or id.len == 0) return error.InvalidSave;
        if (version < 26 and self.room_flags != null) return error.InvalidSave;
        if (self.shown_props) |shown| {
            if (version < 35 or !state.package.supportsProps()) return error.InvalidSave;
            var known: u64 = 0;
            const room = state.package.rooms[state.package.roomIndex(self.room) orelse return error.InvalidSave];
            for (room.draws) |draw| if (draw.prop) |id| {
                known |= @as(u64, 1) << id;
            };
            if (shown == 0 or shown & ~known != 0) return error.InvalidSave;
        }
        if (version < 27) if (self.story.scenario) |story| if (story.soul_eater_spell_slots != 1) return error.InvalidSave;
        if (version < 28) if (self.story.scenario) |story| if (story.save_counter != 0) return error.InvalidSave;
        if (self.story.scenario) |story| {
            if (!story.hasWindowStyle(story.window_appearance.style) or !story.hasSoundTheme(story.sound_theme)) return error.InvalidSave;
        }
        if (self.shared_items) |slots| {
            if (version < 23) return error.InvalidSave;
            _ = try state.bindSharedItems(slots);
        }
        const expected_scene_hash: ?[32]u8 = if (state.combat.spell_scenes) |packet| try packet.digest() else null;
        if (!std.meta.eql(self.spell_scene_hash, expected_scene_hash) or (version == 19 and self.spell_scene_hash == null)) return error.SpellSceneContentMismatch;
        const expected_actor_hash: ?[32]u8 = if (state.combat.unite_actors) |packet| try packet.digest() else null;
        if (!std.meta.eql(self.unite_actor_hash, expected_actor_hash) or (version == 20 and self.unite_actor_hash == null)) return error.UniteActorContentMismatch;
        if (version >= 3 and (self.save_name == null or self.elapsed_ticks == null)) return error.MissingSaveMetadata;
        if (version >= 4 and self.storage == null) return error.MissingStorage;
        if (version >= 5 and self.reserves == null) return error.MissingReserves;
        if (version >= 21 and self.reserve_extras == null) return error.MissingReserveExtras;
        if (self.storage) |store| try store.validate();
        if (self.route) |route| try route.validate();
        if (self.save_name) |name| {
            try name.validate();
        }
        const room = state.package.roomIndex(self.room) orelse return error.UnknownRoom;
        const destination = state.package.rooms[room];
        const scenery = if (self.room_scenery) |*value| value else null;
        if (scenery) |visit| {
            if (version < 42) return error.InvalidSave;
            try visit.validate(destination.scenery_model orelse return error.InvalidSave);
        }
        if (self.boat_travel) |boat| {
            try boat.validate((state.boat_data orelse return error.MissingBoatOwner).*, self.room, self.x, self.y, self.facing, self.story.scenario orelse return error.MissingSourceStoryState);
        } else if (std.mem.eql(u8, self.room, travel.source.world_room)) {
            if (self.story.scenario) |story| if (story.world_mode == 1) return error.MissingBoatOwner;
        }
        const source_arrival = state.package.permitsSourceArrival(self.room, self.x, self.y) or if (state.room_battles) |rooms| rooms.permitsSourceArrival(self.room, self.x, self.y) else false;
        const river_boat = self.riverBoat(destination);
        if (destination.boat_rapids != null and self.story.scenario != null and
            self.story.scenario.?.world_mode == 1 and !river_boat) return error.InvalidSave;
        const walkable = river_boat or destination.canStandWithScenery(scenery, self.x, self.y);
        const source_push = if (!walkable and !source_arrival) push: {
            const rooms = state.room_battles orelse break :push false;
            const story = self.story.scenario orelse break :push false;
            const flags = self.room_flags orelse field.room_flags.State{};
            break :push rooms.permitsSourcePush(self.room, self.x, self.y, &story, self.party_count, &flags.values, self.money);
        } else false;
        if (!destination.contains(self.x, self.y) or (!walkable and !source_arrival and !source_push and self.boat_travel == null) or self.money > 999999) return error.InvalidSave;
        if (self.party_count == 0 or self.party_count > 6) return error.InvalidSave;
        for (self.extras[0..self.party_count], 0..) |extra, i| {
            if (extra.member_id.len != 0 and !std.mem.eql(u8, extra.member_id, self.party[i].id)) return error.InvalidExtras;
            if (extra.member_id.len == 0 and !emptyExtra(extra)) return error.InvalidExtras;
        }
        for (self.extras[self.party_count..]) |extra| if (!emptyExtra(extra)) return error.InvalidExtras;
        var members = self.party;
        const active = members[0..self.party_count];
        try (field.game_state.Progress{ .money = self.money, .party = active, .story = self.story }).validate();
        var seen: [6]bool = @splat(false);
        for (self.formation, 0..) |member, slot| {
            if (member >= seen.len or seen[member] or (slot < self.party_count and member >= self.party_count)) return error.InvalidFormation;
            seen[member] = true;
        }
        if (version > 1 and (self.loadouts == null or self.weapon_levels == null)) return error.InvalidEquipment;
        const loadouts = self.loadouts orelse battle.systems.legacyLoadouts(self.equipment);
        for (active, 0..) |_, i| {
            if (self.equipment[i] != loadouts[i].head) return error.InvalidEquipment;
            try state.combat.validateOwnedMember(try self.ownedMember(i, state.combat.content));
        }
        if (self.story.maas_recruited and !self.story.maas_recruitment_blocked) {
            var owned = false;
            for (active) |member| owned = owned or std.mem.eql(u8, member.id, "maas");
            for (self.reserves orelse @as(Reserves, @splat(null))) |entry| if (entry) |member| {
                owned = owned or std.mem.eql(u8, member.member.id, "maas");
            };
            if (!owned) return error.MissingRecruitedMember;
        }
        if (self.reserves) |reserves| {
            var ended = false;
            for (reserves, 0..) |entry, i| {
                if (entry) |owned| {
                    if (ended) return error.InvalidReserves;
                    try state.combat.validateOwnedMember(owned);
                    for (active) |member| if (std.mem.eql(u8, member.id, owned.member.id)) return error.DuplicateMember;
                    for (reserves[0..i]) |other| if (std.mem.eql(u8, other.?.member.id, owned.member.id)) return error.DuplicateMember;
                } else ended = true;
            }
        }
        if (self.reserve_extras) |extras| {
            const reserves = self.reserves orelse @as(Reserves, @splat(null));
            for (extras, reserves) |extra, owned| {
                if (extra) |value| {
                    if (owned == null) return error.InvalidExtras;
                    if (value.member_id.len == 0) {
                        if (!emptyExtra(value)) return error.InvalidExtras;
                    } else if (!std.mem.eql(u8, value.member_id, owned.?.member.id)) return error.InvalidExtras;
                } else if (owned != null and version >= 21) return error.InvalidExtras;
            }
        }
    }
    fn riverBoat(self: *const Snapshot, destination: field.Room) bool {
        if (destination.boat_rapids == null) return false;
        const story = self.story.scenario orelse return false;
        // Earlier saves could arrive on the river before the boat mode was wired.
        if (story.world_mode != 1 and (story.world_mode != 0 or destination.canStand(self.x, self.y))) return false;
        return destination.boatPassage(self.x, self.y, &story) == .open;
    }
    fn ownedMember(self: Snapshot, i: usize, content: battle.Content) !battle.OwnedMember {
        const profile = content.partyProfile(self.party[i].id) orelse return error.InvalidMember;
        const loadouts = self.loadouts orelse battle.systems.legacyLoadouts(self.equipment);
        return .{ .member = self.party[i], .level = self.levels[i], .experience = self.experience[i], .stats = self.stats[i], .weapon_level = if (self.weapon_levels) |levels| levels[i] else if (profile.weapon) |weapon| weapon.initial_level else 1, .loadout = loadouts[i], .rune = self.runes[i] };
    }
    // The caller keeps the opening, campaign and headquarters payloads alive while applied.
    pub fn apply(self: *const Snapshot, state: anytype) !void {
        try self.validate(state);
        const restored_actors = if (self.room_actors) |actors| blk: {
            const binding = state.room_battles.?.bindingFor(self.room).?;
            if (binding.needsFreshRoomActors(actors.construction_story, self.story.scenario)) break :blk null;
            break :blk try actors.rebind(binding.ordinary.?, binding.animations);
        } else null;
        const shared = if (self.shared_items) |slots| try state.bindSharedItems(slots) else @as(SharedItems, @splat(null));
        const backing = state.party_backing orelse state.combat.progress.party;
        if (self.party_count > backing.len) return error.InvalidParty;
        var restored_party: [6]battle.OwnedMember = undefined;
        const active = restored_party[0..self.party_count];
        for (active, 0..) |*member, i| member.* = try self.ownedMember(i, state.combat.content);
        state.combat.progress.party = backing[0..self.party_count];
        for (active, 0..) |member, i| {
            backing[i] = member.member;
            state.combat.setOwnedMember(i, member);
        }
        state.extras = self.extras;
        state.reserves = self.reserves orelse @splat(null);
        state.reserve_extras = self.reserve_extras orelse @splat(null);
        for (state.extras[0..self.party_count], 0..) |*extra, i| if (extra.member_id.len != 0) {
            extra.member_id = state.combat.progress.party[i].id;
        };
        state.combat.weapon_augments = @splat(.{});
        for (state.extras[0..self.party_count], 0..) |extra, i| state.combat.weapon_augments[i] = party_session.weaponAugment(extra);
        for (&state.reserves, 0..) |*entry, i| if (entry.*) |owned| {
            const profile = state.combat.content.partyProfile(owned.member.id).?;
            entry.*.?.member.id = profile.id;
            entry.*.?.member.name = profile.name;
            if (state.reserve_extras[i] == null) state.reserve_extras[i] = .{ .member_id = "" };
            if (state.reserve_extras[i].?.member_id.len != 0) state.reserve_extras[i].?.member_id = profile.id;
        };
        state.combat.progress.storage = self.storage orelse .{};
        state.optional_games = self.optional_games orelse .{};
        state.teleport_session = null;
        if (state.side_game != null) {
            state.dice_host.?.owner = .field;
            state.dice_host.?.session = null;
            state.side_game = null;
        }
        state.shared_items = shared;
        state.combat.progress.money = self.money;
        state.combat.progress.story = self.story;
        if (state.combat.progress.story.scenario) |*story| story.schema = "suikoden-event-story/1";
        const destination = state.package.roomIndex(self.room).?;
        if (self.riverBoat(state.package.rooms[destination])) state.combat.progress.story.scenario.?.world_mode = 1;
        state.combat.formation = self.formation;
        state.combat.random = self.random;
        state.route = if (self.route) |checkpoint| try opening_route.Controller.restore(checkpoint) else opening_route.initial(state.package);
        if (state.packagedOpeningRoute() != null) state.updateOpeningPartyMilestone();
        state.combat.asleep = @splat(0);
        state.combat.clearTemporaryStats();
        state.combat.unbalanced = @splat(0);
        state.combat.active = null;
        state.combat.source_camera_hold = null;
        state.combat.source_camera_return = null;
        state.combat.actions = @splat(null);
        state.combat.quit_requested = false;
        const inn = state.field_state.inn_rules;
        const items = state.field_state.item_rules;
        state.field_state = field.State.init(state.package, state.combat.progress);
        state.field_state.inn_rules = inn;
        state.field_state.item_rules = items;
        state.field_state.room = destination;
        state.field_state.x = self.x;
        state.field_state.y = self.y;
        state.field_state.destination = .{ .x = self.x, .y = self.y };
        state.field_state.facing = self.facing;
        state.field_state.music = self.field_music;
        state.field_state.auxiliary_party = self.auxiliary_party;
        state.field_state.local_flags = self.room_flags orelse .{};
        state.field_state.shown_props = self.shown_props orelse 0;
        state.field_state.room_scenery = self.room_scenery;
        state.field_state.wheel_state = self.wheel_state;
        state.field_state.world_context = if (self.world_context) |context| .{
            .room = state.package.roomIndex(context.room).?,
            .entry = if (context.entry) |id| state.package.worldEntryIndex(id).? else null,
        } else null;
        state.field_state.reconcileWorldEntry(state.package, null);

        state.mode = .field;
        state.save_name = self.save_name orelse pause.save_slots.defaultLabel(0);
        state.elapsed_ticks = self.elapsed_ticks orelse 0;
        state.opening_event = self.opening_event;

        state.campaign = self.campaign;
        state.hq = self.hq;
        state.world_battle_ticks = self.world_battle_ticks;
        state.world_battle_started = self.world_battle_started;
        state.menu = .{ .preferences = state.menu.preferences, .save_slot = state.menu.save_slot, .region_bgm = state.menu.region_bgm };
        state.encounter_trigger = null;
        state.seedFieldStoryDefaults();
        state.enterEncounterRoom();
        state.initialized_room_visit = state.field_state.room_entries;
        state.checked_arrival_visit = if (self.pending_room_arrival) null else state.field_state.room_entries;
        if (self.field_encounter_clock) |clock| {
            if (state.data.field_encounters) |encounters| {
                if (encounters.forRoom(self.room) != null) state.field_encounter_clock = clock;
            }
        }
        state.field_event = null;
        if (state.room_battles) |rooms| {
            rooms.settled_actors = if (restored_actors) |actors| .{
                .room = rooms.bindingFor(self.room).?.room,
                .visit = state.field_state.room_entries,
                .state = actors,
            } else null;
        }
        state.dice_game = null;
        state.party_selection = null;
        state.item_overload = null;
        state.item_overload_sound = null;
        state.auto_travel = null;
        state.boat_travel = self.boat_travel;
        if (self.boat_travel != null) state.field_state.step_duration = 16;
        state.field_state.auto_route_id = null;
        if (state.dice_host) |host| {
            host.session = null;
            host.owner = .field;
        }
        state.scripted_battle = null;
        state.suppressed_trigger = if (self.suppressed_trigger_id) |id| for (state.data.encounters, 0..) |trigger, i| {
            if (std.mem.eql(u8, trigger.id, id) and state.containsLegacyTrigger(trigger)) break i;
        } else null else null;
        state.bind();
    }
};

pub const filename = "journey-slot.json";
pub const backup_filename = "journey-slot.json.bak";
pub const RestoreSource = enum { primary, backup };
fn atomicWrite(io: std.Io, directory: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    try @import("save_file").atomicWrite(io, directory, name, bytes);
}
pub fn validateSnapshotFields(allocator: std.mem.Allocator, bytes: []const u8) !void {
    const version = try std.json.parseFromSlice(struct { schema: []const u8 }, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer version.deinit();
    const number = try saveVersion(version.value.schema);
    if (number == 8 or number >= 17) {
        // Defaults migrate old saves; a current save must carry every new story field.
        const Required = struct { story: struct { recruitment_tier: u8, maas_recruited: bool, maas_recruitment_blocked: bool, castle_name: [8]u8 } };
        const required = std.json.parseFromSlice(Required, allocator, bytes, .{ .ignore_unknown_fields = true }) catch |err| {
            return if (err == error.MissingField) error.MissingRecruitmentState else err;
        };
        required.deinit();
    }
}
pub fn validateNestedSnapshotFields(allocator: std.mem.Allocator, bytes: []const u8, key: []const u8) !void {
    const document = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer document.deinit();
    if (document.value != .object) return error.InvalidSave;
    const nested = document.value.object.get(key) orelse return error.MissingSnapshot;
    const encoded = try std.json.Stringify.valueAlloc(allocator, nested, .{});
    defer allocator.free(encoded);
    try validateSnapshotFields(allocator, encoded);
}
const HeapSnapshot = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    value: *Snapshot,

    fn deinit(self: HeapSnapshot) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
    }
};

fn decodeSnapshotHeap(allocator: std.mem.Allocator, bytes: []const u8, state: anytype) !HeapSnapshot {
    try validateSnapshotFields(allocator, bytes);
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var value_arena = std.heap.ArenaAllocator.init(allocator);
    defer value_arena.deinit();
    const doc_parsed = try std.json.parseFromSlice(std.json.Value, value_arena.allocator(), bytes, .{});
    if (doc_parsed.value != .object) return error.InvalidSave;
    const snap = try arena.allocator().create(Snapshot);
    const info = @typeInfo(Snapshot).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |fname, ftype, fattrs| {
        if (doc_parsed.value.object.get(fname)) |raw| {
            @field(snap, fname) = try std.json.parseFromValueLeaky(ftype, arena.allocator(), raw, .{ .allocate = .alloc_always });
        } else if (fattrs.defaultValue(ftype)) |default_val| {
            @field(snap, fname) = default_val;
        } else {
            return error.MissingField;
        }
    }
    try snap.validate(state);
    return .{ .allocator = allocator, .arena = arena, .value = snap };
}

pub fn decodeSnapshot(allocator: std.mem.Allocator, bytes: []const u8, state: anytype) !std.json.Parsed(Snapshot) {
    try validateSnapshotFields(allocator, bytes);
    const parsed = try std.json.parseFromSlice(Snapshot, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate(state);
    return parsed;
}
pub fn slotFilename(index: usize, backup: bool) ![]const u8 {
    return switch (index) {
        0 => if (backup) backup_filename else filename,
        1 => if (backup) "journey-slot2.json.bak" else "journey-slot2.json",
        2 => if (backup) "journey-slot3.json.bak" else "journey-slot3.json",
        else => error.InvalidSaveSlot,
    };
}
pub fn save(io: std.Io, allocator: std.mem.Allocator, directory: std.Io.Dir, state: anytype) !void {
    try saveSlot(io, allocator, directory, state, 0, state.save_name);
}

fn canRotateSnapshot(allocator: std.mem.Allocator, bytes: []const u8, state: anytype) !bool {
    const parsed = decodeSnapshotHeap(allocator, bytes, state) catch |err| switch (err) {
        error.OutOfMemory,
        error.UnsupportedSaveVersion,
        error.UnknownField,
        error.UnknownRoom,
        error.SpellSceneContentMismatch,
        error.UniteActorContentMismatch,
        error.MissingSharedItemCatalogue,
        error.SharedItemContentMismatch,
        => return err,
        else => return false,
    };
    parsed.deinit();
    return true;
}

pub fn saveSlot(io: std.Io, allocator: std.mem.Allocator, directory: std.Io.Dir, state: anytype, index: usize, name: pause.save_slots.Label) !void {
    if (state.field_event != null) return error.GameBusy;
    const primary = try slotFilename(index, false);
    const backup = try slotFilename(index, true);
    const snapshot = try allocator.create(Snapshot);
    defer allocator.destroy(snapshot);
    snapshot.* = try Snapshot.capture(state);
    snapshot.save_name = name;
    try snapshot.validate(state);
    const bytes = try std.json.Stringify.valueAlloc(allocator, snapshot.*, .{});
    defer allocator.free(bytes);
    const previous = directory.readFileAlloc(io, primary, allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (previous) |old| allocator.free(old);
    const keep_previous = if (previous) |old| try canRotateSnapshot(allocator, old, state) else false;
    const prior_backup = directory.readFileAlloc(io, backup, allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (prior_backup) |old| allocator.free(old);
    if (prior_backup) |old| _ = try canRotateSnapshot(allocator, old, state);
    if (keep_previous) try atomicWrite(io, directory, backup, previous.?);
    try atomicWrite(io, directory, primary, bytes);
}
fn readSnapshot(io: std.Io, allocator: std.mem.Allocator, directory: std.Io.Dir, name: []const u8, state: anytype) !HeapSnapshot {
    const bytes = try directory.readFileAlloc(io, name, allocator, .limited(256 * 1024));
    defer allocator.free(bytes);
    const parsed = try decodeSnapshotHeap(allocator, bytes, state);
    errdefer parsed.deinit();
    const backing = state.party_backing orelse state.combat.progress.party;
    if (parsed.value.party_count > backing.len) return error.InvalidParty;
    return parsed;
}

const SlotSnapshot = struct { parsed: HeapSnapshot, source: RestoreSource };

fn readSlotSnapshot(io: std.Io, allocator: std.mem.Allocator, directory: std.Io.Dir, state: anytype, index: usize) !SlotSnapshot {
    const primary = try slotFilename(index, false);
    const parsed = readSnapshot(io, allocator, directory, primary, state) catch |primary_error| {
        if (primary_error == error.UnsupportedSaveVersion) return primary_error;
        const backup = try slotFilename(index, true);
        const previous = readSnapshot(io, allocator, directory, backup, state) catch |backup_error| {
            if (backup_error == error.UnsupportedSaveVersion or primary_error == error.FileNotFound) return backup_error;
            return primary_error;
        };
        return .{ .parsed = previous, .source = .backup };
    };
    return .{ .parsed = parsed, .source = .primary };
}

pub fn restoreWithSource(io: std.Io, allocator: std.mem.Allocator, directory: std.Io.Dir, state: anytype) !RestoreSource {
    return restoreSlotWithSource(io, allocator, directory, state, 0);
}
fn applyReadSnapshot(parsed: HeapSnapshot, state: anytype, index: usize) !void {
    errdefer parsed.deinit();
    try parsed.value.apply(state);
    state.checkpoint = null;
    state.releaseRestoredSave();
    if (parsed.value.opening_event != null or parsed.value.campaign != null or parsed.value.hq != null) {
        state.restored_save_arena = parsed.arena;
    } else parsed.deinit();
    state.menu.save_slot = index;
}
pub fn restoreSlotWithSource(io: std.Io, allocator: std.mem.Allocator, directory: std.Io.Dir, state: anytype, index: usize) !RestoreSource {
    const loaded = try readSlotSnapshot(io, allocator, directory, state, index);
    try applyReadSnapshot(loaded.parsed, state, index);
    return loaded.source;
}
pub fn restore(io: std.Io, allocator: std.mem.Allocator, directory: std.Io.Dir, state: anytype) !void {
    _ = try restoreWithSource(io, allocator, directory, state);
}

pub fn summaries(io: std.Io, allocator: std.mem.Allocator, directory: std.Io.Dir, state: anytype) [pause.save_slots.count]pause.save_slots.Summary {
    var result = pause.save_slots.emptySummaries();
    for (&result, 0..) |*entry, index| {
        const loaded = readSlotSnapshot(io, allocator, directory, state, index) catch |err| {
            entry.status = switch (err) {
                error.UnsupportedSaveVersion => .future,
                error.FileNotFound => .empty,
                else => .damaged,
            };
            continue;
        };
        defer loaded.parsed.deinit();
        entry.* = summarize(loaded.parsed.value, state);
        if (loaded.source == .backup) entry.status = .backup;
    }
    return result;
}
fn summarize(snapshot: *const Snapshot, state: anytype) pause.save_slots.Summary {
    const leader = snapshot.formation[0];
    return .{ .status = .ready, .name = snapshot.save_name orelse pause.save_slots.defaultLabel(0), .scene = state.package.rooms[state.package.roomIndex(snapshot.room).?].title, .leader = state.combat.content.partyProfile(snapshot.party[leader].id).?.name, .level = snapshot.levels[leader], .seconds = (snapshot.elapsed_ticks orelse 0) / 60 };
}
