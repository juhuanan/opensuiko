const std = @import("std");
const world = @import("world");
const field = @import("field");
const battle = @import("battle");
const field_link = @import("world_field");
const battle_link = @import("world_battle");
const party = @import("party_session");
const view = @import("world_view");
const pause = @import("pause_menu");
const controller = pause.controller;
const routes = @import("route_transitions");
const travel_modes = @import("travel_modes");
const event_runtime = @import("event_runtime");
const route_edges = @import("travel").routes;
const route_data = @import("travel_data").navigation;
pub const event_host = @import("field_events");

pub const Traits = struct { level_sum: u16 = 0, healing: bool = false, suppression: bool = false, faster: bool = false };
pub fn partyTraits(combat: *const battle.State) !Traits {
    try combat.progress.validate();
    if (combat.partyCount() == 0 or combat.partyCount() > 6) return error.InvalidParty;
    var traits: Traits = .{};
    for (combat.progress.party, 0..) |member, i| {
        traits.level_sum += combat.levels[i];
        traits.healing = traits.healing or combat.hasRune(i, "sunbeam");
        traits.suppression = traits.suppression or combat.hasRune(i, "champion's");
        traits.faster = traits.faster or std.mem.eql(u8, member.id, "stallion");
    }
    return traits;
}
pub const Input = struct { world: world.Input = .{}, field: field.Input = .{}, combat: battle.Input = .{}, menu: bool = false, text: [32]u8 = @splat(0), text_len: u8 = 0, erase: bool = false, physical_up: bool = false, source_dispatch: ?event_host.DispatchInput = null };
pub const Event = union(enum) { none, field_entered, world_returned, battle_started, battle_returned, defeated, settings_changed, inspect_saves, save_requested, load_requested, party_give, party_discard, party_equip, recruitment_requested: []const u8, unsupported_entrance: []const u8, scene_event_blocked: event_host.Blocker };

// Host edges survive frames without updates and failed updates, but never a committed callback.
pub const Controls = struct {
    pending: Input = .{},
    menu: bool = false,
    focused: bool = false,
    pub fn sample(self: *Controls, buttons: controller.Output, suppress_encounter: bool) void {
        self.focused = true;
        self.pending.world.direction = if (buttons.direction) |direction| switch (direction) {
            .up => .north,
            .right => .east,
            .down => .south,
            .left => .west,
        } else null;
        self.pending.world.encounter_arm_suppressed = suppress_encounter;
        self.pending.field.direction = buttons.direction;
        self.pending.physical_up = buttons.physical_up;
        if (buttons.navigation != null) self.pending.field.menu_direction = buttons.navigation;
        self.pending.field.action = self.pending.field.action or buttons.confirm;
        self.pending.field.cancel = self.pending.field.cancel or buttons.cancel;
        self.pending.combat.up = self.pending.combat.up or buttons.navigation == .up;
        self.pending.combat.down = self.pending.combat.down or buttons.navigation == .down;
        self.pending.combat.left = self.pending.combat.left or buttons.navigation == .left;
        self.pending.combat.right = self.pending.combat.right or buttons.navigation == .right;
        self.pending.combat.confirm = self.pending.combat.confirm or buttons.confirm;
        self.pending.combat.cancel = self.pending.combat.cancel or buttons.cancel;
        self.menu = self.menu or buttons.menu;
    }
    pub fn reset(self: *Controls) void {
        self.* = .{};
    }
    pub fn sampleText(self: *Controls, bytes: []const u8, erase: bool) void {
        self.pending.erase = self.pending.erase or erase;
        for (bytes) |byte| {
            if (byte < 32 or byte > 126 or self.pending.text_len >= self.pending.text.len) continue;
            self.pending.text[self.pending.text_len] = byte;
            self.pending.text_len += 1;
        }
    }
    pub fn advance(self: *Controls, state: *State, draws: *world.Draws) !Event {
        if (!self.focused) return .none;
        var input = self.pending;
        input.menu = self.menu;
        const event = try state.advance(input, draws);
        self.pending = .{ .world = self.pending.world, .field = .{ .direction = self.pending.field.direction }, .physical_up = self.pending.physical_up };
        self.menu = false;
        return event;
    }
};

// Adopts combat metadata by value; parsed data and party storage remain caller-owned.
pub const Region = struct {
    map: world.Content,
    art: view.Data,
    battles: ?battle_link.Data = null,
    pub fn jsonStringify(self: Region, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("map");
        try writer.write(self.map);
        try writer.objectField("art");
        try writer.write(self.art);
        if (self.battles) |data| {
            try writer.objectField("battles");
            try writer.write(data);
        }
        try writer.endObject();
    }
    pub fn validate(self: Region) !void {
        try self.map.validate();
        try self.art.validate();
        if (!std.mem.eql(u8, self.map.id, self.art.region)) return error.WorldRegionMismatch;
        if (self.battles) |data| {
            if (data.presentation) |presentation| {
                try presentation.validate();
                if (!std.mem.eql(u8, self.map.id, presentation.region)) return error.WorldRegionMismatch;
            } else if (data.actor_content == null) return error.MissingBattlePresentation;
            if (data.actor_content) |content| {
                if (!std.mem.eql(u8, self.map.id, "region_c") or !data.supportsActorContent()) return error.WorldRegionMismatch;
                try content.validate();
            }
        }
    }
};
pub const AreaCommandState = struct { cached: u16, area: ?u16 = null };
pub const VillageAccess = struct { source: *const event_host.village.Source, dialogue: event_host.Binding, exit: event_host.Binding };
pub const State = struct {
    link: field_link.Session,
    combat: battle.State,
    overlay: battle_link.Data,
    art: view.Data,
    visual: view.State,
    adapter: battle_link.Adapter = .{},
    menu: pause.State = .{},
    world_menu: bool = false,
    blocked_entrance: ?[]const u8 = null,
    live_saves: bool = false,
    party_transactions: bool = false,
    /// The roster owner retains this snapshot for the lifetime of the binding.
    party_snapshot: ?*const party.Snapshot = null,
    battle_receipt: u64 = 0,
    travel_receipt: u64 = 0,
    /// Durable route-consumer facts. Values only: the packet is
    /// revalidated per cue and never retained across a frame, so a copied
    /// State cannot hold a dangling edge slice.
    route_settled: u64 = 0,
    /// The parsed route catalogue is session lifetime.  The
    /// integrated campaign host already owns one parsed copy, so a cue borrows
    /// it instead of re-decoding 76,936 bytes per transition (cached at boot).
    /// A session without the host keeps the owned fallback parse.
    route_packet: ?*const route_edges.edges.Packet = null,
    /// The integrated travel host switches field->world exits and doorways to
    /// the route consumer.  A session without the host keeps the
    /// legacy field-owner path, so legacy fixtures stay untouched.
    route_authority: bool = false,
    /// The last source `area_index_set` write. MAIN 0x8013DB6C writes the area
    /// index; the port retains the written value for the area/audio owner. Its
    /// consumers are not part of this transaction, so it is recorded, not faked.
    route_area_index: ?u16 = null,
    region_b: ?Region = null,
    region_c: ?Region = null,
    scene_binding: ?event_host.Binding = null,
    scene_event: ?event_host.Session = null,
    area_commands: ?AreaCommandState = null,
    source_dispatch_enabled: bool = false,
    source_dispatch: ?event_host.DispatchTracker = null,
    village_access: ?VillageAccess = null,
    village_actors: ?event_host.village.State = null,
    village_interaction_active: bool = false,

    const RouteOutcome = struct {
        receipt: u64,
        destination: [64]u8 = @splat(0),
        destination_len: u8 = 0,
        spawn_x: i32 = 0,
        spawn_y: i32 = 0,
        field_destination: bool = false,
        reconstruction_required: bool = false,
        continuation: route_edges.edges.ContinuationKind = .field_ready,

        fn id(self: *const RouteOutcome) []const u8 {
            return self.destination[0..self.destination_len];
        }
    };

    /// The constructible set is the attached package plus the bound world
    /// regions. A source room without a package is absent from it, so the
    /// consumer refuses with UnavailableDestination instead of retargeting.
    fn routeScope(self: *const State, buffer: *[32][]const u8) route_edges.Scope {
        var count: usize = 0;
        buffer[count] = self.link.content.id;
        count += 1;
        if (self.region_b) |binding| {
            var seen = false;
            for (buffer[0..count]) |id| seen = seen or std.mem.eql(u8, id, binding.map.id);
            if (!seen and count < buffer.len) {
                buffer[count] = binding.map.id;
                count += 1;
            }
        }
        if (self.region_c) |binding| {
            var seen = false;
            for (buffer[0..count]) |id| seen = seen or std.mem.eql(u8, id, binding.map.id);
            if (!seen and count < buffer.len) {
                buffer[count] = binding.map.id;
                count += 1;
            }
        }
        for (self.link.package.rooms) |room| {
            var seen = false;
            for (buffer[0..count]) |id| seen = seen or std.mem.eql(u8, id, room.id);
            if (!seen and count < buffer.len) {
                buffer[count] = room.id;
                count += 1;
            }
        }
        return .{ .locations = buffer[0..count] };
    }

    /// Execute one ordered prefix effect with the port's documented projection.
    /// An effect the port cannot produce stops the cue before a destination is
    /// returned; it is never skipped and never reported as success.
    fn applyRouteEffect(self: *State, effect: route_edges.edges.Effect, story: *event_runtime.StoryState) !void {
        switch (effect.kind) {
            .story_or => {
                const flag = effect.flag orelse return error.InvalidRouteEffect;
                const index = route_edges.edges.scenarioIndex(flag.id) orelse return error.UnknownRouteStoryValue;
                story.scenario[index] |= flag.mask;
            },
            .area_index_set => self.route_area_index = effect.area_index orelse return error.InvalidRouteEffect,
            else => return error.UnsupportedRouteEffect,
        }
    }

    /// One source cue through the ordered prefix. Returns null only when no
    /// catalogue edge owns the cue; every other refusal is typed.
    fn routeTransition(self: *State, cue: route_edges.Cue, story: *event_runtime.StoryState) !?RouteOutcome {
        // One decode per session when the campaign host supplied its packet;
        // the owned parse remains only for a session without that host.
        const owned: ?std.json.Parsed(route_edges.edges.Packet) = if (self.route_packet == null)
            try route_edges.edges.load(self.link.allocator, route_data.route_json)
        else
            null;
        defer if (owned) |parsed| parsed.deinit();
        const packet = if (self.route_packet) |cached| cached else &owned.?.value;
        var scope_buffer: [32][]const u8 = undefined;
        const scope = self.routeScope(&scope_buffer);
        var consumer = route_edges.Consumer{ .settled_receipt = self.route_settled };
        const proposal = consumer.begin(packet, cue, story, scope) catch |err| switch (err) {
            error.NoMatchingEdge => return null,
            else => return err,
        };
        var next_story = story.*;
        var index: usize = 0;
        while (index < proposal.effects.len) : (index += 1) {
            try self.applyRouteEffect(try consumer.acknowledgeEffect(proposal.receipt, index), &next_story);
        }
        const commit = try consumer.commit(packet, proposal.receipt, &next_story);
        const id = commit.destination.location_id;
        if (id.len == 0 or id.len > 64) return error.InvalidRouteDestination;
        var outcome: RouteOutcome = .{
            .receipt = commit.receipt,
            .destination_len = @intCast(id.len),
            .spawn_x = commit.destination.spawn.x,
            .spawn_y = commit.destination.spawn.y,
            .field_destination = commit.destination.spawn.domain == .field_pixel,
            .reconstruction_required = commit.reconstruction.required,
            .continuation = commit.continuation.kind,
        };
        @memcpy(outcome.destination[0..outcome.destination_len], id);
        try consumer.settle(commit.receipt);
        self.route_settled = commit.receipt;
        story.* = next_story;
        return outcome;
    }

    pub fn attachGround(self: *State, ground: field.Ground) void {
        self.link.ground = ground;
        self.route_authority = true;
    }

    /// Travel-host production field entry for a declared mode arrival. The world
    /// point record owns the room identity and world cell; the source packet
    /// owns the field spawn, which must equal this point's exported spawn.
    pub fn enterFieldAtPoint(self: *State, point_id: []const u8, spawn: field.Point, facing: field.Direction) !void {
        if (self.link.travel.mode != .world) return error.NotInFootWorld;
        const point = for (self.link.content.points) |entry| {
            if (std.mem.eql(u8, entry.id, point_id)) break entry;
        } else return error.UnknownWorldEntrance;
        if (point.destination == null) return error.UnsupportedEntranceDestination;
        const room_index = if (std.mem.eql(u8, point.destination.?, "village")) self.link.village else self.link.package.roomIndex(point.destination.?) orelse return error.UnknownRoom;
        if (spawn.x != point.spawn_x or spawn.y != point.spawn_y) return error.ArrivalSpawnMismatch;
        if (!self.link.package.rooms[room_index].canStand(spawn.x, spawn.y)) return error.InvalidWorldFieldSpawn;
        self.enterFieldState(room_index, spawn, facing);
        self.link.travel.camera = .{ .x = point.x, .y = point.y };
        self.link.travel.pending_entrance = point.id;
    }

    /// Travel-host field-mode arrival: the source reconstructs the destination room
    /// in place (a Viki event raises no world-map walk), so the current world
    /// point that owns the field session stays the same.
    pub fn reconstructFieldRoom(self: *State, room_id: []const u8, spawn: field.Point, facing: field.Direction) !void {
        if (self.link.travel.mode != .field) return error.NotInFootWorld;
        const room_index = self.link.package.roomIndex(room_id) orelse return error.UnknownRoom;
        if (!self.link.package.rooms[room_index].canStand(spawn.x, spawn.y)) return error.InvalidWorldFieldSpawn;
        self.enterFieldState(room_index, spawn, facing);
    }

    fn enterFieldState(self: *State, room_index: usize, spawn: field.Point, facing: field.Direction) void {
        self.link.field_moving_updates = 0;
        const source = &self.link.field_state;
        source.room = room_index;
        source.x = spawn.x;
        source.y = spawn.y;
        source.destination = .{ .x = spawn.x, .y = spawn.y };
        source.remaining = 0;
        source.walking = false;
        source.action_pending = false;
        source.dialogue = null;
        source.animation_ticks = 0;
        source.scene_ticks = 0;
        source.facing = facing;
        self.link.travel.mode = .field;
        self.link.travel.remaining = 0;
        self.link.travel.heading = .east;
        self.combat.progress = source.progress;
    }
    pub fn attachVillage(self: *State, access: VillageAccess) !void {
        if (self.village_access != null) return error.VillageAlreadyBound;
        try access.dialogue.validate(self.link.package, self.combat.partyCount());
        try access.exit.validate(self.link.package, self.combat.partyCount());
        if (!std.mem.eql(u8, access.dialogue.room, self.link.package.rooms[self.link.village].id)) return error.UnknownEventRoom;
        _ = try (try event_host.village.State.construct(access.source.*, .{}, access.source.ground())).actors.rebindEquivalent(access.source.packet.value, access.dialogue.ordinary orelse return error.MissingFieldActorConstruction, access.dialogue.animations);
        self.village_access = access;
        errdefer self.village_access = null;
        if (self.link.travel.mode == .field and self.link.field_state.room == self.link.village) try self.constructVillage();
    }

    fn constructVillage(self: *State) !void {
        const access = self.village_access orelse return;
        const story = self.link.field_state.progress.story.scenario orelse return error.MissingSourceStoryState;
        const constructed = try event_host.village.State.construct(access.source.*, story, access.source.ground());
        // shortcut: the reviewed prototype has only these two static actors; replace it when source actors are rendered.
        if (constructed.actors.slots[0].?.phase != .absent or constructed.actors.slots[1].?.phase != .active or constructed.actors.slots[2].?.phase != .active) return error.UnsupportedVillagePresentation;
        self.village_actors = constructed;
    }
    fn commitVillageEntry(self: *State, point: world.Entrance, facing: field.Direction) !void {
        if (self.village_access == null) return;
        _ = point;
        const story = self.link.field_state.progress.story.scenario orelse return error.MissingSourceStoryState;
        const camera = self.link.travel.camera;
        if (camera.x < 0 or camera.y < 0) return error.UnsupportedVillageRoute;
        const cue: route_edges.Cue = .{
            .origin_id = self.link.content.id,
            .trigger = .{ .world_point = .{ .domain = .world_cell, .x = camera.x, .y = camera.y } },
        };
        var story_after = story;
        const outcome = (try self.routeTransition(cue, &story_after)) orelse return error.RouteTriggerMismatch;
        // The world-point entry carries no prefix effects; the source spawn is
        // the village room spawn the entrance step already produced.
        if (!outcome.field_destination or !outcome.reconstruction_required or outcome.continuation != .field_ready) return error.UnsupportedVillageRoute;
        if (!std.mem.eql(u8, outcome.id(), self.link.package.rooms[self.link.village].id)) return error.UnsupportedVillageRoute;
        if (outcome.spawn_x != self.link.field_state.x or outcome.spawn_y != self.link.field_state.y) return error.UnsupportedVillageRoute;
        if (self.link.field_state.facing != facing) return error.UnsupportedVillageRoute;
        try self.constructVillage();
        self.link.field_state.progress.story.scenario = story_after;
        self.travel_receipt = outcome.receipt;
    }
    pub fn restoreVillage(self: *State, saved: ?event_host.village.State) !void {
        const access = self.village_access orelse {
            if (saved != null) return error.MissingVillageBinding;
            return;
        };
        if (self.link.travel.mode != .field or self.link.field_state.room != self.link.village) {
            if (saved != null) return error.InvalidVillageState;
            self.village_actors = null;
            return;
        }
        if (saved) |value| {
            const restored = try value.rebind(access.source.*, access.source.ground());
            if (restored.actors.slots[0].?.phase != .absent or restored.actors.slots[1].?.phase != .active or restored.actors.slots[2].?.phase != .active) return error.UnsupportedVillagePresentation;
            self.village_actors = restored;
        } else try self.constructVillage();
    }

    fn villageInteraction(self: *State, input: Input) !bool {
        const access = self.village_access orelse return false;
        const construction = self.village_actors orelse return false;
        const state = &self.link.field_state;
        if (self.village_interaction_active) {
            const event = if (self.scene_event) |*value| value else return error.InvalidVillageState;
            const result = try event.tick(access.dialogue, state, input.field.action);
            if (result == .blocked) return error.UnsupportedVillageDialogue;
            if (result == .completed or result == .idle) {
                self.scene_event = null;
                self.village_interaction_active = false;
            }
            return true;
        }
        if (!input.field.action or input.field.cancel or self.menu.phase != .closed or state.remaining != 0 or state.dialogue != null) return false;
        const facing = input.field.direction orelse state.facing;
        const target = switch (facing) {
            .down => field.Point{ .x = state.x, .y = state.y + 16 },
            .up => field.Point{ .x = state.x, .y = state.y - 8 },
            .left => field.Point{ .x = state.x - 16, .y = state.y },
            .right => field.Point{ .x = state.x + 16, .y = state.y },
        };
        for (access.dialogue.ordinary.?.actors[1..3]) |actor| {
            const hit = switch (facing) {
                .up, .down => actor.y == target.y and actor.x >= target.x - 8 and actor.x <= target.x + 8,
                .left, .right => actor.x == target.x and actor.y >= target.y and actor.y <= target.y + 8,
            };
            if (!hit) continue;
            if (self.scene_event != null) return error.UnsupportedConcurrentFieldScene;
            const actors = try construction.actors.rebindEquivalent(access.source.packet.value, access.dialogue.ordinary.?, access.dialogue.animations);
            state.facing = facing;
            state.walking = false;
            self.scene_event = try event_host.Session.beginInteraction(access.dialogue, state.*, 1, actor.entity, actors);
            self.village_interaction_active = true;
            return true;
        }
        return false;
    }

    fn tickVillageExit(self: *State, traits: Traits) !Event {
        const access = self.village_access orelse return error.MissingVillageBinding;
        const event = if (self.scene_event) |*value| value else return error.MissingFieldEventOwner;
        const result = try event.tick(access.exit, &self.link.field_state, false);
        self.combat.progress = self.link.field_state.progress;
        if (result != .blocked) return .none;
        const pending = event.instance.?.pending orelse return error.InvalidFieldEventReceipt;
        const effect = pending.batch.effects[0];
        if (pending.batch.effect_count != 1 or effect.kind != .world_transition or effect.destination == null or !std.mem.eql(u8, effect.destination.?, "region_b") or effect.x != 86 or effect.y != 85) return error.InvalidFieldEventReceipt;
        const region = if (self.region_b) |binding| binding.map else self.link.content;
        if (!std.mem.eql(u8, region.id, "region_b") or region.return_camera.x != effect.x.? or region.return_camera.y != effect.y.?) return error.UnsupportedVillageRoute;
        const story = self.link.field_state.progress.story.scenario orelse return error.MissingSourceStoryState;
        if (story.scenario[39] & 0x10 == 0) return error.InvalidFieldEventStory;
        var committed_story = story;
        try event.acknowledgeWorldExit(access.exit, &committed_story);
        const cue: route_edges.Cue = .{
            .origin_id = access.dialogue.room,
            .trigger = .{ .field_rectangle = .{ .position = .{ .domain = .field_pixel, .x = self.link.field_state.x, .y = self.link.field_state.y } } },
        };
        const outcome = (try self.routeTransition(cue, &committed_story)) orelse return error.UnsupportedVillageRoute;
        if (outcome.field_destination or outcome.reconstruction_required or outcome.continuation != .world_ready) return error.UnsupportedVillageRoute;
        if (!std.mem.eql(u8, outcome.id(), "region_b") or outcome.spawn_x != effect.x.? or outcome.spawn_y != effect.y.?) return error.UnsupportedVillageRoute;
        try self.activateRegion("region_b");
        try self.link.travel.leaveField(region);
        if (self.link.travel.camera.x != outcome.spawn_x or self.link.travel.camera.y != outcome.spawn_y) return error.UnsupportedVillageRoute;
        self.link.field_state.progress.story.scenario = committed_story;
        self.link.field_state.progress.story.village_south_exit_reached = true;
        self.combat.progress = self.link.field_state.progress;
        self.travel_receipt = outcome.receipt;
        self.scene_event = null;
        self.village_actors = null;
        self.link.travel.speed = if (traits.faster) .stallion else .normal;
        self.visual.reload(self.art);
        return .world_returned;
    }

    pub fn attachSceneEvents(self: *State, binding: event_host.Binding) !void {
        if (self.scene_binding != null) return error.SceneEventsAlreadyBound;
        try binding.validate(self.link.package, self.combat.partyCount());
        if (binding.audio) |audio| if (self.area_commands == null and audio.initial_cached_command != null) {
            self.area_commands = .{ .cached = audio.initial_cached_command.? };
        };
        self.scene_binding = binding;
    }
    pub fn enableSourceDispatch(self: *State) !void {
        if (self.source_dispatch_enabled or self.scene_event != null or self.scene_binding == null or self.scene_binding.?.dispatch == null) return error.InvalidFieldDispatchState;
        self.source_dispatch_enabled = true;
    }

    pub fn attachRegionC(self: *State, region: Region) !void {
        if (self.region_c != null or !std.mem.eql(u8, self.link.content.id, "region_b")) return error.WorldRegionAlreadyBound;
        try region.validate();
        if (!std.mem.eql(u8, region.map.id, "region_c")) return error.UnknownWorldRegion;
        try self.link.enableKoboldExit();
        if (region.battles) |data| _ = try data.view(region.map, self.combat.content);
        self.region_b = .{ .map = self.link.content, .art = self.art, .battles = self.overlay };
        self.region_c = region;
    }
    pub fn activateRegion(self: *State, id: []const u8) !void {
        if (std.mem.eql(u8, id, self.link.content.id)) return;
        const region = if (std.mem.eql(u8, id, "region_b")) self.region_b else if (std.mem.eql(u8, id, "region_c")) self.region_c else null;
        const binding = region orelse return error.UnknownWorldRegion;
        self.link.content = binding.map;
        self.art = binding.art;
        self.overlay = binding.battles orelse self.region_b.?.battles.?;
    }
    /// Route-managed field->world exit. The source rectangle and destination come
    /// from the catalogue; there is no `region.map.field_exit` shortcut and no
    /// fabricated story flag. The port's derived convenience flag is kept in
    /// step after the source commit for the existing save/progress projections.
    fn routeWorldExit(self: *State) !bool {
        if (self.menu.phase != .closed) return false;
        const state = &self.link.field_state;
        if (state.remaining != 0 or state.dialogue != null) return false;
        // A session without the source story bank (legacy fixtures) has no route
        // owner to consult; the integrated production session always carries it.
        const story_state = state.progress.story.scenario orelse return false;
        var story = story_state;
        const cue: route_edges.Cue = .{
            .origin_id = self.link.package.rooms[state.room].id,
            .trigger = .{ .field_rectangle = .{ .position = .{ .domain = .field_pixel, .x = state.x, .y = state.y } } },
        };
        const outcome = (try self.routeTransition(cue, &story)) orelse return false;
        if (outcome.field_destination or outcome.reconstruction_required or outcome.continuation != .world_ready) return error.UnsupportedRouteContinuation;
        const region = if (self.region_b) |binding| if (std.mem.eql(u8, binding.map.id, outcome.id())) binding else null else null;
        const destination = region orelse if (self.region_c) |binding| if (std.mem.eql(u8, binding.map.id, outcome.id())) binding else null else null;
        const binding = destination orelse return error.UnknownWorldRegion;
        state.progress.story.scenario = story;
        state.progress.story.village_south_exit_reached = state.progress.story.village_south_exit_reached or std.mem.eql(u8, outcome.id(), "region_b");
        state.progress.story.kobold_world_exit_reached = state.progress.story.kobold_world_exit_reached or std.mem.eql(u8, outcome.id(), "region_c");
        try self.activateRegion(outcome.id());
        try self.link.travel.leaveField(binding.map);
        if (self.link.travel.camera.x != outcome.spawn_x or self.link.travel.camera.y != outcome.spawn_y) return error.UnsupportedRouteDestination;
        state.walking = false;
        state.action_pending = false;
        self.combat.progress = state.progress;
        self.travel_receipt = outcome.receipt;
        self.visual.reload(self.art);
        return true;
    }

    /// Legacy cross-region exit, kept for sessions without the integrated
    /// host.  The integrated path is `routeWorldExit`.
    fn legacyCrossRegionExit(self: *State) !bool {
        if (self.region_c == null or self.menu.phase != .closed) return false;
        const state = &self.link.field_state;
        if (state.remaining != 0 or state.dialogue != null) return false;
        for ([_]Region{ self.region_b.?, self.region_c.? }) |region| {
            if (std.mem.eql(u8, self.link.content.id, region.map.id)) continue;
            const room = if (std.mem.eql(u8, region.map.id, "region_b")) self.link.village else self.link.package.roomIndex(region.map.field_room) orelse return error.UnknownRoom;
            const exit = region.map.field_exit;
            if (state.room != room or state.x < exit.x or state.x >= exit.x + exit.w or state.y < exit.y or state.y >= exit.y + exit.h) continue;
            try self.activateRegion(region.map.id);
            try self.link.travel.leaveField(region.map);
            state.progress.story.complete(if (std.mem.eql(u8, region.map.id, "region_b")) .village_south_exit_reached else .kobold_world_exit_reached);
            state.walking = false;
            state.action_pending = false;
            self.combat.progress = state.progress;
            return true;
        }
        return false;
    }

    /// Source doorway reconciliation. The package moved the hero through a
    /// doorway; the catalogue must own that exact rectangle and destination, and
    /// every prefix effect must be executable before the step is accepted.
    fn routeDoorway(self: *State, from_room: usize, from_x: i32, from_y: i32, facing: field.Direction, to_room: usize) !void {
        const state = &self.link.field_state;
        const delta: field.Point = switch (facing) {
            .down => .{ .x = 0, .y = 8 },
            .up => .{ .x = 0, .y = -8 },
            .left => .{ .x = -8, .y = 0 },
            .right => .{ .x = 8, .y = 0 },
        };
        const position = field.Point{ .x = from_x + delta.x, .y = from_y + delta.y };
        const direction: ?route_edges.edges.Direction = switch (facing) {
            .down => .down,
            .up => .up,
            .left => .left,
            .right => .right,
        };
        const story_state = state.progress.story.scenario orelse return;
        var story = story_state;
        const cue: route_edges.Cue = .{
            .origin_id = self.link.package.rooms[from_room].id,
            .trigger = .{ .field_rectangle = .{ .position = .{ .domain = .field_pixel, .x = position.x, .y = position.y }, .direction = direction } },
        };
        const outcome = (try self.routeTransition(cue, &story)) orelse return error.UnprovenDoorway;
        if (!outcome.field_destination or !outcome.reconstruction_required or outcome.continuation != .field_ready) return error.UnsupportedRouteContinuation;
        if (!std.mem.eql(u8, outcome.id(), self.link.package.rooms[to_room].id)) return error.UnprovenDoorway;
        if (outcome.spawn_x != state.x or outcome.spawn_y != state.y) return error.UnprovenDoorway;
        state.progress.story.scenario = story;
        self.combat.progress = state.progress;
        self.travel_receipt = outcome.receipt;
    }

    pub fn open(allocator: std.mem.Allocator, map: world.Content, art: view.Data, overlay: battle_link.Data, package: field.Package, combat: battle.State, starting_field: field.State) !State {
        try (Region{ .map = map, .art = art }).validate();
        if (combat.partyCount() == 0 or combat.partyCount() > 6) return error.InvalidParty;
        _ = try overlay.view(map, combat.content);
        if (combat.progress.party.ptr != starting_field.progress.party.ptr or combat.partyCount() != starting_field.progress.party.len or combat.active != null or combat.pending_enemy_actor != null or combat.coordinator != null) return error.WorldPartyMismatch;
        for (0..combat.partyCount()) |i| try combat.validateOwnedMember(combat.ownedMember(i));
        var link = try field_link.Session.open(allocator, map, package, starting_field, .east);
        errdefer link.deinit();
        var owned = combat;
        owned.progress = starting_field.progress;
        if (link.field_state.item_rules == null) link.field_state.item_rules = owned.rules;
        link.travel.speed = if ((try partyTraits(&owned)).faster) .stallion else .normal;
        return .{ .link = link, .combat = owned, .overlay = overlay, .art = art, .visual = view.State.init(art) };
    }
    pub fn deinit(self: *State) void {
        self.adapter.deinit(self.link.allocator);
        self.link.deinit();
    }
    pub fn attachPartySnapshot(self: *State, snapshot: *const party.Snapshot) !void {
        if (self.link.travel.mode == .battle or self.adapter.transaction != null or self.adapter.original != null) return error.WorldBattleNotReady;
        _ = try party.weaponAugments(self.combat, snapshot.*);
        self.party_snapshot = snapshot;
    }
    fn supportedRoom(id: []const u8) bool {
        for ([_][]const u8{ "village", "vb6_village", "inn", "vb6_inn", "shop", "vb6_shop", "blacksmith", "vb6_blacksmith", "vb6_forest_edge", "vb6_forest_paths", "vb6_forest_crossing", "vb6_forest_bend", "vb6_forest_clearing", "vb6_kobold_village" }) |allowed| if (std.mem.eql(u8, id, allowed)) return true;
        return false;
    }
    fn menuEvent(self: State, effect: pause.Effect) !Event {
        return switch (effect) {
            .none => .none,
            .settings_changed => .settings_changed,
            .inspect_saves => if (self.live_saves) .inspect_saves else error.UnimplementedWorldMenuEffect,
            .save => if (self.live_saves) .save_requested else error.UnimplementedWorldMenuEffect,
            .load => if (self.live_saves) .load_requested else error.UnimplementedWorldMenuEffect,
            .party_give => if (self.party_transactions) .party_give else error.UnimplementedWorldMenuEffect,
            .party_discard => if (self.party_transactions) .party_discard else error.UnimplementedWorldMenuEffect,
            .party_equip => if (self.party_transactions) .party_equip else error.UnimplementedWorldMenuEffect,
            .weapon_piece, .blinking_mirror => error.UnimplementedWorldMenuEffect,
            .new_game => error.UnimplementedWorldMenuEffect,
        };
    }
    pub fn advance(self: *State, input: Input, draws: *world.Draws) !Event {
        if (input.text_len > input.text.len) return error.InvalidWorldTextInput;
        if (self.blocked_entrance) |id| return .{ .unsupported_entrance = id };
        const traits = try partyTraits(&self.combat);
        const before = self.*;
        const saved_draws = draws.*;
        var members: [6]battle.Member = undefined;
        @memcpy(members[0..self.combat.partyCount()], self.combat.progress.party);
        errdefer {
            self.* = before;
            @memcpy(self.combat.progress.party, members[0..self.combat.partyCount()]);
            draws.* = saved_draws;
        }
        self.menu.live_world_context = self.live_saves;
        const menu_input: pause.Input = .{ .field = input.field, .left = input.field.menu_direction == .left, .right = input.field.menu_direction == .right, .menu = input.menu, .text = input.text[0..input.text_len], .erase = input.erase, .party_transactions = self.party_transactions };
        // shortcut: Shared menu presentation omits original transition fades; add source driver scheduling before presentation parity.
        if (self.world_menu) {
            self.menu.combat = &self.combat;
            self.link.field_state.progress = self.combat.progress;
            const effect = self.menu.tick(self.link.package, &self.link.field_state, menu_input);
            self.combat.progress = self.link.field_state.progress;
            if (self.menu.phase == .closed) {
                self.world_menu = false;
                self.menu.travel_context = false;
            }
            return self.menuEvent(effect);
        }
        switch (self.link.travel.mode) {
            .world, .field_pending, .battle_pending => {
                const event = try self.link.tickWorld(input.world, draws, traits.level_sum, traits.suppression, traits.healing);
                self.combat.progress = self.link.field_state.progress;
                if (before.link.travel.mode == .world) try self.visual.step(self.art, before.link.travel, self.link.travel, input.world);
                if (event == .entrance and self.link.field_state.room == self.link.village) try self.commitVillageEntry(event.entrance, before.link.field_state.facing);
                // Source point entry wins; otherwise menu selection follows this frame's encounter draw.
                if (before.link.travel.mode == .world and input.menu and event != .entrance_requested and event != .unsupported_entrance) {
                    self.link.travel.mode = .world;
                    self.world_menu = true;
                    self.menu = .{ .phase = .root, .travel_context = true, .live_world_context = self.live_saves, .selected = .item, .preferences = self.menu.preferences };
                    return .none;
                }
                return switch (event) {
                    .entrance => .field_entered,
                    .battle => block: {
                        if (std.mem.eql(u8, self.link.content.id, "region_c") and (self.region_c == null or self.region_c.?.battles == null)) return error.UnimplementedRegionCCombat;
                        if (self.party_snapshot) |snapshot| {
                            self.combat.weapon_augments = try party.weaponAugments(self.combat, snapshot.*);
                        } else if (self.party_transactions) return error.UnsupportedCombatSidecar;
                        if (self.party_transactions) {
                            try self.adapter.beginTransactional(&self.link, &self.combat, self.overlay, draws.*, self.battle_receipt);
                        } else try self.adapter.begin(&self.link, &self.combat, self.overlay);
                        break :block .battle_started;
                    },
                    .unsupported_entrance => |id| block: {
                        self.blocked_entrance = id;
                        break :block .{ .unsupported_entrance = id };
                    },
                    else => .none,
                };
            },
            .field => {
                if (self.scene_event) |*scene| if (std.mem.eql(u8, scene.content_sha256, if (self.village_access) |access| access.exit.content.content_sha256 else "")) return self.tickVillageExit(traits);
                if (self.link.field_state.room == self.link.village and try self.villageInteraction(input)) return .none;
                if (self.scene_binding) |attached| {
                    var binding = attached;
                    if (binding.audio) |*audio| {
                        audio.initial_cached_command = if (self.area_commands) |commands| commands.cached else null;
                    }
                    const state = &self.link.field_state;
                    if (std.mem.eql(u8, self.link.package.rooms[state.room].id, binding.room) and state.progress.story.scenario != null) {
                        if (self.scene_event == null or !self.scene_event.?.inside) {
                            if (self.scene_event != null and self.scene_event.?.audio_request != null) return error.PendingFieldAudioRequest;
                            const serial = if (self.scene_event) |previous| std.math.add(u64, previous.serial, 1) catch return error.FieldEventSequenceOverflow else 1;
                            self.scene_event = try event_host.Session.enter(binding, state.*, serial);
                            if (self.source_dispatch_enabled) self.source_dispatch = try event_host.DispatchTracker.start(binding, state.progress.story.scenario.?);
                        }
                        if (self.source_dispatch_enabled and self.scene_event.?.instance != null and !self.scene_event.?.busy()) {
                            const tracker = if (self.source_dispatch) |*value| value else return error.InvalidFieldDispatchState;
                            const facts = input.source_dispatch orelse return .{ .scene_event_blocked = .{ .entity = binding.content.program(self.scene_event.?.instance.?.program_id).?.entity, .reason = .source_gate_unknown } };
                            const story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
                            const decision = try tracker.advance(binding, &self.scene_event.?, state.*, &story, facts);
                            switch (decision.kind) {
                                .blocked => {
                                    if (decision.reason == .caller_gate) return .none;
                                    const reason: @FieldType(event_host.Blocker, "reason") = switch (decision.reason orelse return error.InvalidFieldDispatchState) {
                                        .unsupported_predicate => .unsupported_predicate,
                                        .room_coordinate_transition => .room_coordinate_transition,
                                        .program_not_compiled => .unexported_program,
                                        else => return error.UnsupportedFieldDispatchDecision,
                                    };
                                    return .{ .scene_event_blocked = .{ .entity = decision.source_order orelse return error.InvalidFieldDispatchState, .reason = reason } };
                                },
                                .selected_ordinary => {
                                    if (decision.source_order != 7) return .{ .scene_event_blocked = .{ .entity = decision.source_order.?, .reason = .unbound_dispatch_program } };
                                    _ = try tracker.startSelected(binding, &self.scene_event.?, state.*, &story, facts);
                                    return .none;
                                },
                                .wait_current_instance => return .none,
                                .no_candidate => if (decision.action == .rearm_free_selection) return .none,
                                else => return error.UnsupportedFieldDispatchDecision,
                            }
                        }
                        if (self.source_dispatch_enabled and self.scene_event.?.completed_event != null and self.scene_event.?.busy()) {
                            const tracker = if (self.source_dispatch) |*value| value else return error.InvalidFieldDispatchState;
                            const facts = input.source_dispatch orelse return .{ .scene_event_blocked = .{ .entity = 7, .reason = .source_gate_unknown } };
                            const story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
                            const decision = try tracker.advance(binding, &self.scene_event.?, state.*, &story, facts);
                            switch (decision.kind) {
                                .continue_current_instance => {},
                                .wait_current_instance => return .none,
                                else => return error.UnsupportedFieldDispatchDecision,
                            }
                        }
                        const result = try self.scene_event.?.tick(binding, state, input.field.action);
                        if (self.scene_event.?.audio_cached_command) |cached| {
                            self.area_commands = .{ .cached = cached, .area = self.scene_event.?.area_command };
                        }
                        self.combat.progress = state.progress;
                        if (result == .blocked) {
                            if (self.source_dispatch_enabled and self.scene_event.?.completed_event != null and try self.scene_event.?.reconstruct(binding, state)) {
                                self.source_dispatch = try event_host.DispatchTracker.start(binding, state.progress.story.scenario.?);
                                self.combat.progress = state.progress;
                                return .none;
                            }
                            return .{ .scene_event_blocked = self.scene_event.?.blocker.? };
                        }
                        if (result == .completed and self.source_dispatch_enabled and !self.scene_event.?.busy()) {
                            if (input.source_dispatch) |facts| {
                                const tracker = if (self.source_dispatch) |*value| value else return error.InvalidFieldDispatchState;
                                const story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
                                const decision = try tracker.advance(binding, &self.scene_event.?, state.*, &story, facts);
                                if (decision.kind != .wait_current_instance and
                                    !(decision.kind == .no_candidate and decision.action == .rearm_free_selection)) return error.UnsupportedFieldDispatchDecision;
                            }
                        }
                        if (self.scene_event.?.busy() or result == .completed) return .none;
                    } else if (self.scene_event) |*scene| scene.inside = false;
                }
                // The session owns reserves and commits this request atomically with its draw stream.
                if (before.link.field_state.dialogue) |dialogue| if (dialogue.phase == .recruitment_joined and input.field.action and !input.field.cancel) {
                    if (dialogue.source != .npc) return error.InvalidRecruitment;
                    const npcs = self.link.package.rooms[before.link.field_state.room].npcs;
                    if (dialogue.source.npc >= npcs.len) return error.InvalidRecruitment;
                    return .{ .recruitment_requested = npcs[dialogue.source.npc].id };
                };
                self.menu.combat = &self.combat;
                if (input.menu and self.menu.phase == .closed) {
                    self.menu.travel_context = true;
                    self.menu.selected = .item;
                }
                const source_village = self.village_access != null and before.link.field_state.room == self.link.village;
                // Under route-consumer authority the consumer owns field->world exits and
                // doorways, so the field owner only moves the hero
                // (`allow_exit = false`).  Without the host the legacy field-owner
                // path is unchanged.
                var returned = if (self.route_authority)
                    try self.link.tickFieldMenuSource(menu_input, draws, traits.healing, &self.menu)
                else if (source_village)
                    try self.link.tickFieldMenuSource(menu_input, draws, traits.healing, &self.menu)
                else
                    try self.link.tickFieldMenu(menu_input, draws, traits.healing, &self.menu);
                if (self.route_authority) {
                    if (!returned and self.link.field_state.room != before.link.field_state.room) try self.routeDoorway(before.link.field_state.room, before.link.field_state.x, before.link.field_state.y, before.link.field_state.facing, self.link.field_state.room);
                    if (!returned and !source_village) returned = try self.routeWorldExit();
                } else if (!returned and !source_village) {
                    returned = try self.legacyCrossRegionExit();
                }
                if (source_village and self.link.field_state.room == self.link.village and self.menu.phase == .closed and self.link.field_state.remaining == 0 and self.link.field_state.dialogue == null) {
                    const point = self.link.field_state;
                    if (point.x >= 224 and point.x < 304 and point.y >= 360 and point.y < 368) {
                        if (self.scene_event != null or self.village_actors == null) return error.UnsupportedConcurrentFieldScene;
                        self.link.field_state.walking = false;
                        self.link.field_state.action_pending = false;
                        self.scene_event = try event_host.Session.beginWorldExit(self.village_access.?.exit, self.link.field_state, std.math.add(u64, self.travel_receipt, 1) catch return error.TravelReceiptOverflow);
                        self.combat.progress = self.link.field_state.progress;
                        return .none;
                    }
                }
                if (self.village_access != null and self.link.field_state.room != before.link.field_state.room) {
                    self.village_actors = null;
                    if (self.link.field_state.room == self.link.village) try self.constructVillage();
                }
                if (!supportedRoom(self.link.package.rooms[self.link.field_state.room].id)) return error.UnimplementedWorldFieldDestination;
                self.combat.progress = self.link.field_state.progress;
                if (self.menu.phase == .closed and !self.menu.pending) self.menu.travel_context = false;
                if (returned) {
                    self.village_actors = null;
                    self.link.travel.speed = if (traits.faster) .stallion else .normal;
                    self.visual.reload(self.art);
                    return .world_returned;
                }
                if (!std.meta.eql(before.menu.preferences, self.menu.preferences)) return .settings_changed;
                return self.menuEvent(self.link.menu_effect);
            },
            .battle => return switch (if (self.adapter.transaction != null) try self.adapter.tickTransactional(&self.link, &self.combat, input.combat, draws, &self.battle_receipt) else try self.adapter.tick(&self.link, &self.combat, input.combat, draws)) {
                .running => .none,
                .defeated => .defeated,
                .returned => block: {
                    self.link.travel.speed = if (traits.faster) .stallion else .normal;
                    self.visual.reload(self.art);
                    break :block .battle_returned;
                },
            },
        }
    }
    pub fn worldDraws(self: *const State, list: *view.List) !void {
        if (self.link.travel.mode != .world and self.link.travel.mode != .field_pending and self.link.travel.mode != .battle_pending) return error.NotInFootWorld;
        try view.compose(self.art, self.link.travel, &self.visual, list);
    }
    pub fn canvasSize(self: *const State) !world.Point {
        if (self.world_menu) return .{ .x = 512, .y = 432 };
        return switch (self.link.travel.mode) {
            .world, .field_pending, .battle_pending => .{ .x = 320, .y = 240 },
            .field => .{ .x = 512, .y = 432 },
            .battle => if (!self.combat.content.presentation_ready) error.SimulationOnlyBattleContent else .{ .x = 640, .y = 480 },
        };
    }
};
