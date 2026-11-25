//! Field exploration, encounters, room transitions, crossings, and episode objectives.
const std = @import("std");
const roster = @import("journey_roster");
const battle_flow = @import("journey_battle");
const field = @import("field");
const pause = @import("pause_menu");
const journey = @import("../journey.zig");
const events_host = @import("events_host.zig");

pub fn handleReadyFieldEncounter(state: *journey.State) bool {
    return battle_flow.beginReadyFieldEncounter(state) catch |err| {
        state.field_encounter_clock.ready = false;
        std.log.warn("Field encounter could not start: {s}", .{@errorName(err)});
        state.menu.notify("The field encounter could not start.");
        return true;
    };
}

pub fn clearWorldEncounterSuppression(state: *journey.State) !void {
    const encounters = state.data.field_encounters orelse return;
    if (!encounters.clear_suppression_on_world_entry) return;
    var story = state.field_state.progress.story.scenario orelse if (state.room_battles) |rooms| rooms.initial_story else return;
    try story.clear(encounters.suppress_when.?.flag);
    state.setScenarioStory(story);
}

pub fn onRoomChange(state: *journey.State, scripted_world_exit: bool) !void {
    state.field_state.reconcileWorldEntry(state.package, null);
    if (state.room_battles) |rooms| {
        rooms.settled_actors = null;
    }
    const world_entry = scripted_world_exit or state.field_state.crossed_world_exit;
    if (world_entry) try clearWorldEncounterSuppression(state);
    if (world_entry and state.route.stage == .first_town) {
        _ = state.route.complete(.first_town) catch unreachable;
    } else state.syncRoute();
    state.join_failure_room = null;
    const new_id = journey.roomId(state.package, state.field_state.room);
    if (!std.mem.eql(u8, new_id, "va1_room_0")) state.town_home_ticks = 0;
    if (!std.mem.eql(u8, new_id, "va1_room_1")) state.town_room_ticks = 0;
    if (!std.mem.eql(u8, new_id, "va1_room_2")) state.town_world_ticks = 0;
    if (!std.mem.eql(u8, new_id, "world_a")) state.world_battle_ticks = 0;
    state.enterEncounterRoom();
    try events_host.initializeRoomVisit(state);
}

fn usesDerivedRoomExit(state: *const journey.State, room: []const u8) bool {
    const current = state.package.rooms[state.field_state.room];
    if (!std.mem.eql(u8, current.id, room) or current.hasWorldExit()) return false;
    if (state.room_battles) |rooms| return rooms.opening_route == null and !rooms.ownsRoomExit(room);
    return true;
}

pub fn tickAutomaticTravel(state: *journey.State) !void {
    if (state.mode != .field or state.menu.phase != .closed) return error.InvalidCrossingOwner;
    const arrived = try state.auto_travel.?.tick(state.package, &state.field_state);
    state.elapsed_ticks +|= 1;
    state.syncProgressFromField();
    if (arrived) {
        state.auto_travel = null;
        state.field_event = null;
        try onRoomChange(state, false);
    }
}

pub fn shouldTickBoat(state: *const journey.State, input: pause.Input) bool {
    return state.boat_travel != null and state.mode == .field and state.menu.phase == .closed and
        !(input.menu and state.field_state.remaining == 0);
}

pub fn tickBoat(state: *journey.State, direction: ?field.Direction) !void {
    const packet = state.boat_data orelse return error.MissingBoatOwner;
    const arrived = try state.boat_travel.?.tick(packet.*, state.package, &state.field_state, direction);
    state.elapsed_ticks +|= 1;
    state.syncProgressFromField();
    if (arrived) {
        state.boat_travel = null;
        state.field_event = null;
        try onRoomChange(state, false);
    }
}

pub fn tickFieldExploration(state: *journey.State, input: pause.Input, room_events: journey.RoomEventMode) !pause.Effect {
    state.syncProgressToField();
    const old_room = state.field_state.room;
    const old_entry = state.field_state.room_entries;
    const old_x = state.field_state.x;
    const old_y = state.field_state.y;
    const old_dialogue = state.field_state.dialogue;
    const old_movement_updates = state.field_state.movement_updates;
    const can_arm = state.menu.phase == .closed and !state.menu.pending and !input.menu and
        old_dialogue == null and state.field_state.rest_ticks == 0 and state.field_state.remaining == 0 and input.field.direction != null;
    var menu_input = input;
    menu_input.weapon_pieces = true;
    menu_input.has_shared_items = state.shared_items[0] != null;
    menu_input.travel_tools = state.teleport_catalogue != null;
    const arrival: field.StepArrival = if (room_events == .enabled and state.room_battles != null and
        state.room_battles.?.bindingFor(state.package.rooms[old_room].id) != null) .deferred else .immediate;
    const ground_ctx: BoundaryGroundContext = .{ .state = state, .direction = input.field.direction };
    const ground: ?field.Ground = if (arrival == .deferred) .{
        .context = &ground_ctx,
        .query = roomBoundaryGroundQuery,
        .authoritative = true,
    } else null;
    var effect = state.menu.tickWithArrivalAndGround(state.package, &state.field_state, menu_input, arrival, ground);
    state.syncProgressFromField();
    if (effect == .blinking_mirror) {
        journey.travel.useMirror(state.teleport_catalogue.?, state.package, &state.field_state, state.menu.member, state.menu.slot) catch |err| {
            if (err != error.OutsideRequired) return err;
            state.menu.message = "Use the Blinking Mirror on the world map.";
            state.menu.phase = .item_notice;
            return .none;
        };
        state.boat_travel = null;
        state.syncProgressFromField();
        state.menu.phase = .closed;
        try onRoomChange(state, false);
        return .none;
    }
    if (effect == .weapon_piece) {
        roster.useWeaponPiece(state, state.menu.member, state.menu.slot, state.menu.target, state.menu.weapon_piece_replace) catch |err| {
            if (err == error.ReplacementConfirmationRequired) {
                state.menu.phase = .confirm_weapon_piece;
                state.menu.yes = false;
            } else {
                state.menu.message = if (err == error.WeaponPieceLimit) "This weapon already has nine pieces." else "The rune piece could not be used.";
            }
            effect = .none;
            return effect;
        };
        state.menu.message = "Rune piece attached to weapon.";
        state.menu.slot = @min(state.menu.slot, state.combat.progress.party[state.menu.member].inventory.count() -| 1);
        effect = .none;
    }
    const moved = old_movement_updates != state.field_state.movement_updates;
    if (arrival == .deferred and moved and state.field_state.remaining == 0) {
        _ = try events_host.admitRoomEvent(state, .{ .direction = input.field.direction }, .automatic);
        if (state.field_event == null) {
            state.field_state.finishStepArrival(state.package);
            state.menu.finishPending(&state.field_state);
            state.syncProgressFromField();
        } else state.menu.pending = false;
    }
    if (old_entry != state.field_state.room_entries) try onRoomChange(state, false);
    if (moved) {
        state.combat.applyFieldStatuses();
        state.syncProgressToField();
    }
    if (state.field_event != null) {
        if (state.data.field_encounters) |configured| {
            if (configured.forRoom(state.package.rooms[old_room].id) != null) state.field_encounter_clock.updates +|= @intFromBool(moved);
        }
        return effect;
    }
    const has_world_movement = if (state.data.field_encounters) |configured| configured.forRoom("world_a") != null else false;
    if (!has_world_movement and state.world_battle_enabled and !state.world_battle_started and !state.combat.progress.story.world_patrol_won and std.mem.eql(u8, state.package.rooms[state.field_state.room].id, "world_a")) {
        var in_patrol_region = false;
        for (state.data.encounters) |trigger| {
            if (std.mem.eql(u8, trigger.room, "world_a") and state.containsLegacyTrigger(trigger)) in_patrol_region = true;
        }
        if (!in_patrol_region) state.world_battle_ticks = 0;
        state.world_battle_ticks +|= if (in_patrol_region) 1 else 0;
        if (state.world_battle_ticks >= 30 and in_patrol_region) {
            for (state.data.encounters, 0..) |trigger, i| {
                if (!std.mem.eql(u8, trigger.room, "world_a") or !state.containsLegacyTrigger(trigger)) continue;
                state.beginEncounter(i) catch continue;
                state.world_battle_started = true;
                break;
            }
        }
    }
    if (state.party_catalog) |catalog| {
        if (state.derived_scene_cadence and state.menu.phase == .closed and state.field_state.dialogue == null) {
            if (usesDerivedRoomExit(state, "va1_room_0")) {
                state.town_home_ticks +|= 1;
                if (state.town_home_ticks >= 30 and state.field_state.remaining == 0) {
                    if (state.package.roomIndex("va1_room_1")) |next| {
                        state.field_state.enterRoom(next, .{ .x = 184, .y = 352 });
                        state.town_room_ticks = 0;
                        try onRoomChange(state, false);
                    }
                }
            }
            if (usesDerivedRoomExit(state, "va1_room_1")) {
                state.town_room_ticks +|= 1;
                if (state.town_room_ticks >= 30 and state.field_state.remaining == 0) {
                    if (state.package.roomIndex("va1_room_2")) |next| {
                        state.field_state.enterRoom(next, .{ .x = 152, .y = 264 });
                        try onRoomChange(state, false);
                    }
                }
            }
            if (state.usesPrototypeWorldExit() and usesDerivedRoomExit(state, "va1_room_2")) {
                state.town_world_ticks +|= 1;
                if (state.town_world_ticks >= 30 and state.field_state.remaining == 0) {
                    if (state.package.roomIndex("world_a")) |next| {
                        state.field_state.enterRoom(next, .{ .x = 640, .y = 480 });
                        try onRoomChange(state, false);
                    }
                }
            }
        }
        state.joinOnRoomEntry(state.party_backing.?, catalog, state.party_bindings, state.package.rooms[state.field_state.room].id) catch {
            const room: u16 = @intCast(state.field_state.room);
            if (state.join_failure_room != room) {
                state.join_failure_room = room;
                state.menu.notify("Party join could not complete.\nParty and story state were preserved.");
            }
        };
    }
    const movement_encounters = if (state.data.field_encounters) |configured|
        configured.forRoom(journey.roomId(state.package, state.field_state.room)) != null
    else
        false;
    if (old_entry == state.field_state.room_entries and movement_encounters) {
        state.field_encounter_clock.updates +|= @intFromBool(moved);
        if (can_arm and state.menu.phase == .closed and state.field_state.dialogue == null) state.field_encounter_clock.ready = true;
    }
    if (old_dialogue != null and state.field_state.dialogue == null and input.field.action and old_dialogue.?.source == .npc) {
        const npc = state.package.rooms[old_room].npcs[old_dialogue.?.source.npc];
        if (!input.field.cancel and old_dialogue.?.phase == .recruitment_joined and std.mem.eql(u8, npc.id, "maas")) {
            state.recruitMaas() catch {
                state.menu.notify("Recruitment could not complete.\nParty and story state were preserved.");
            };
        }
    }
    applyFieldInteractions(state, old_room, old_dialogue, input.field);
    if (state.suppressed_trigger) |i| if (!state.containsLegacyTrigger(state.data.encounters[i])) {
        state.suppressed_trigger = null;
    };
    if (!movement_encounters and effect == .none and state.menu.phase == .closed and state.field_state.dialogue == null and state.field_state.remaining == 0 and (old_room != state.field_state.room or old_x != state.field_state.x or old_y != state.field_state.y)) {
        for (state.data.encounters, 0..) |trigger, i| if (!std.mem.eql(u8, trigger.room, "world_a") and state.suppressed_trigger != i and !state.combat.progress.story.has(trigger.flag) and state.containsLegacyTrigger(trigger)) {
            if (room_events == .enabled) {
                _ = try events_host.admitRoomEvent(state, .{ .direction = input.field.direction }, .automatic);
                if (state.field_event != null) break;
            }
            state.beginEncounter(i) catch unreachable;
            break;
        };
    }
    return effect;
}

// Shared episode effects; canonical script execution and encounter selection remain separate.
pub fn applyFieldInteractions(state: *journey.State, old_room: usize, old_dialogue: ?field.Dialogue, input: field.Input) void {
    if (old_dialogue != null and state.field_state.dialogue == null and input.action and old_dialogue.?.source == .npc) {
        const npc = state.package.rooms[old_room].npcs[old_dialogue.?.source.npc];
        if (std.mem.eql(u8, npc.id, "forest_villager")) state.combat.progress.story.complete(.heard_forest_warning);
    }
    if (state.field_state.dialogue) |dialogue| if (dialogue.source == .npc) {
        const room = state.package.rooms[state.field_state.room];
        const npc = room.npcs[dialogue.source.npc];
        for (state.data.treasures) |treasure| if (std.mem.eql(u8, treasure.room, room.id) and std.mem.eql(u8, treasure.npc, npc.id) and !state.combat.progress.story.has(treasure.flag)) {
            var recipient: ?usize = null;
            for (state.combat.progress.party, 0..) |member, i| if (member.inventory.count() < 9) {
                recipient = i;
                break;
            };
            if (recipient) |i| {
                const inventory = &state.combat.progress.party[i].inventory;
                inventory.slots[inventory.count()] = .{ .id = treasure.item, .uses = treasure.uses };
                state.combat.progress.story.complete(treasure.flag);
            } else {
                state.field_state.dialogue = null;
                state.menu.notify("All inventories are full.\nThe chest remains closed.");
            }
        };
    };
    const story = &state.combat.progress.story;
    if (story.heard_forest_warning and story.forest_elf_seen and story.forest_treasure_needle and story.forest_treasure_water and story.forest_battle_one_won and story.forest_battle_two_won and story.forest_battle_three_won and std.mem.eql(u8, state.package.rooms[state.field_state.room].id, "vb6_village")) story.complete(.forest_returned);
    state.syncProgressToField();
}

pub fn episodeObjective(state: *const journey.State) ?[]const u8 {
    if (journey.usesOpeningSeed(state.package.start_room) or state.packagedOpeningRoute() != null) return null;
    const story = state.combat.progress.story;
    if (story.forest_returned) return "Episode complete. Rest, shop, explore or save your party.";
    if (!story.heard_forest_warning) return "Speak to the villager northeast of the inn about the Great Forest.";
    if (!story.forest_elf_seen) return "Visit the central village path to see the elf encounter.";
    if (!story.forest_entered) return "Follow the eastern path from the village into the Great Forest.";
    if (!story.forest_treasure_needle or !story.forest_treasure_water) return "Explore the branching forest paths and open both chests.";
    if (!story.forest_battle_one_won or !story.forest_battle_two_won or !story.forest_battle_three_won) return "Clear the encounters along the forest route.";
    return "Return west to the village. Party progress carries with you.";
}

const BoundaryGroundContext = struct {
    state: *const journey.State,
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
