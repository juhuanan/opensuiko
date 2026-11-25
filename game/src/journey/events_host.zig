//! Room-event binding, scripted battle/party/inventory mutations, and active event ticking.
const std = @import("std");
const item_ledger = @import("item_ledger");
const roster = @import("journey_roster");
const battle_flow = @import("journey_battle");
const party_session = @import("party_session");
const field = @import("field");
const field_events = @import("field_events");
const battle = @import("battle");
const pause = @import("pause_menu");
const journey = @import("../journey.zig");
const exploration = @import("exploration.zig");
const modes = @import("modes.zig");

pub fn roomEventBinding(state: *journey.State, rooms: *field_events.BattleRooms, binding: field_events.Binding) !field_events.Binding {
    const host = (state.combat.integration orelse return error.MissingBattleIntegration).host;
    for (state.field_state.progress.party, rooms.party[0..state.field_state.progress.party.len]) |member, *id| {
        id.* = host.characterId(member.id) orelse return error.UnknownFieldEventPartyMember;
    }
    @memset(&rooms.character_levels, 0);
    if (state.party_catalog) |catalog| for (catalog.characters) |character| {
        if (character.source_character_id >= rooms.character_levels.len) return error.UnknownFieldEventPartyMember;
        rooms.character_levels[character.source_character_id] = character.seed.level;
    };
    for (rooms.party[0..state.field_state.progress.party.len], 0..) |id, index|
        rooms.character_levels[id] = state.combat.levels[index];
    for (state.reserves) |entry| if (entry) |owned| {
        const id = host.characterId(owned.member.id) orelse return error.UnknownFieldEventPartyMember;
        rooms.character_levels[id] = owned.level;
    };
    var carried_count: usize = 0;
    var equipped_count: usize = 0;
    for (state.field_state.progress.party, 0..) |member, index| {
        for (member.inventory.slots) |entry| if (entry) |item| {
            rooms.carried_items[carried_count] = item.id.sourceId();
            carried_count += 1;
        };
        inline for (comptime std.meta.fieldNames(@TypeOf(state.combat.loadouts[0]))) |slot| {
            if (@field(state.combat.loadouts[index], slot)) |gear| {
                const rules = state.combat.content.systems orelse return error.InvalidEquipment;
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
    if (state.shared_item_catalogue) |catalogue| {
        for (state.shared_items) |entry| if (entry) |id| {
            const item = item_ledger.catalogue.findById(catalogue, id) orelse return error.SharedItemContentMismatch;
            rooms.carried_items[carried_count] = item.source_item_id;
            carried_count += 1;
        };
    }
    var result = binding;
    result.item_presence = .{ .carried = rooms.carried_items[0..carried_count], .equipped = rooms.equipped_items[0..equipped_count] };
    result.character_levels = &rooms.character_levels;
    result.player_name = if (state.combat.content.partyProfile("hero")) |profile| profile.name else null;
    result.party = rooms.party[0..state.field_state.progress.party.len];
    return result;
}

pub fn initializeRoomVisit(state: *journey.State) !void {
    const rooms = state.room_battles orelse return;
    const world = &state.field_state;
    if (state.mode != .field or state.initialized_room_visit == world.room_entries) return;
    if (rooms.bindingFor(journey.roomId(state.package, world.room))) |binding| {
        var story = world.progress.story.scenario orelse rooms.initial_story;
        if (try rooms.initializeStory(try roomEventBinding(state, rooms, binding), world, &story)) {
            state.setScenarioStory(story);
            state.enterEncounterRoom();
        }
    }
    state.initialized_room_visit = world.room_entries;
}

pub fn attachFieldEvent(state: *journey.State, session: *field_events.Session, binding: *const field_events.Binding) !void {
    const world = &state.field_state;
    if (state.mode != .field or state.field_event != null or state.menu.phase != .closed or
        world.remaining != 0 or world.dialogue != null or world.rest_ticks != 0) return error.GameBusy;
    try session.validate(binding.*);
    if (!session.busy()) return error.InactiveFieldEvent;
    if (session.instance) |*instance| {
        if (instance.pendingBattle() != null and session.queuedBattle() == null) return error.InvalidFieldBattleReceipt;
    }
    try checkScriptedBattleField(state, session, binding.*);
    state.field_event = .{ .session = session, .binding = binding };
}

fn checkScriptedBattleField(state: *const journey.State, event: *const field_events.Session, binding: field_events.Binding) !void {
    if (!std.mem.eql(u8, binding.room, state.package.rooms[state.field_state.room].id) or
        event.hero.x != state.field_state.x or event.hero.y != state.field_state.y) return error.ScriptedBattleFieldMismatch;
}

pub fn beginScriptedBattle(state: *journey.State, event: *field_events.Session, binding: field_events.Binding) !void {
    if (state.field_event) |owner| if (owner.session != event) return error.ScriptedBattleFieldMismatch;
    try event.validate(binding);
    const request = event.queuedBattle() orelse return error.MissingScriptedBattleRequest;
    try checkScriptedBattleField(state, event, binding);
    if (std.mem.startsWith(u8, request.id, "war:")) {
        const seed: u32 = @truncate(state.elapsed_ticks +% 1);
        try modes.startWarById(state, std.heap.page_allocator, request.id["war:".len..], if (seed == 0) 1 else seed);
        state.scripted_battle = .{ .owner = event, .request = event.takeBattle().?, .opening = false };
        return;
    }
    if (std.mem.startsWith(u8, request.id, "duel:")) {
        try modes.startDuelById(state, std.heap.page_allocator, request.id["duel:".len..]);
        state.scripted_battle = .{ .owner = event, .request = event.takeBattle().?, .opening = false };
        return;
    }
    if (std.mem.startsWith(u8, request.id, "ending:")) {
        try modes.startEnding(state, std.heap.page_allocator);
        state.scripted_battle = .{ .owner = event, .request = event.takeBattle().?, .opening = false };
        return;
    }
    const encounter = battle_flow.encounterIndex(state.combat.content, request.id) orelse return error.UnknownEncounter;
    const opening_battle = if (state.room_battles) |rooms|
        event == &rooms.session and rooms.isOpeningBattle(binding.room, request.receipt.program)
    else
        false;
    try battle_flow.beginCombat(state, encounter);
    state.scripted_battle = .{ .owner = event, .request = event.takeBattle().?, .opening = opening_battle };
}

pub fn resumeScriptedBattle(state: *journey.State, event: *field_events.Session, binding: field_events.Binding) !void {
    const active = state.scripted_battle orelse return error.MissingScriptedBattleRequest;
    const result = active.confirmed orelse return error.ScriptedBattleNotReady;
    if (active.owner != event) return error.ScriptedBattleFieldMismatch;
    const special_mode: ?journey.Mode = if (std.mem.startsWith(u8, active.request.id, "war:"))
        .war
    else if (std.mem.startsWith(u8, active.request.id, "duel:"))
        .duel
    else if (std.mem.startsWith(u8, active.request.id, "ending:"))
        .ending
    else
        null;
    if (special_mode) |mode| {
        const has_active = switch (mode) {
            .war => state.active_war != null,
            .duel => state.active_duel != null,
            .ending => state.active_ending != null,
            else => unreachable,
        };
        if (state.mode != mode or !has_active) return error.ScriptedBattleNotReady;
        try checkScriptedBattleField(state, event, binding);
        const story = try event.resumeBattleStory(binding, state.progress().story.scenario, active.request, result);
        modes.deinitActiveModes(state);
        state.setScenarioStory(story);
        state.scripted_battle = null;
        state.mode = .field;
        return;
    }
    const phase: battle.Phase = switch (result) {
        .victory => .victory,
        .escape => .escaped,
        .defeat => .defeat,
    };
    if (state.mode != (if (result == .defeat) journey.Mode.defeat else journey.Mode.battle) or state.combat.phase != phase) return error.ScriptedBattleNotReady;
    try checkScriptedBattleField(state, event, binding);
    const story = try event.resumeBattleStory(binding, state.progress().story.scenario, active.request, result);
    state.setScenarioStory(story);
    if (result == .victory and active.opening) state.route.noteOpeningBattle(.victory_returned);
    state.scripted_battle = null;
    battle_flow.returnFromBattle(state, result == .victory);
}

pub noinline fn admitRoomEvent(state: *journey.State, input: field.Input, selection: enum { automatic, all }) !bool {
    const rooms = state.room_battles orelse return false;
    const world = &state.field_state;
    if (state.mode != .field or state.field_event != null or state.menu.phase != .closed or
        world.remaining != 0 or world.dialogue != null or world.rest_ticks != 0) return false;
    const binding = rooms.bindingFor(state.package.rooms[world.room].id) orelse return false;
    if (world.progress.story.scenario == null) {
        state.setScenarioStory(rooms.initial_story);
    }
    rooms.active_binding = try roomEventBinding(state, rooms, binding);
    const construction = try rooms.constructActorsForVisit(rooms.active_binding, world.progress.story.scenario.?, world.room_entries);
    const actors = if (construction) |*value| value else null;
    const serial = try std.math.add(u64, rooms.serial, 1);
    var entry = world.*;
    // The completed cell owns event selection even while direction is held.
    entry.walking = false;
    const arrival = state.checked_arrival_visit != world.room_entries and
        try rooms.session.beginRoomEvent(rooms.active_binding, entry, serial, actors, .area_entry, null);
    if (!arrival) state.checked_arrival_visit = world.room_entries;
    const ordinary = !arrival and try rooms.session.beginRoomEvent(rooms.active_binding, entry, serial, actors, .ordinary, input.direction);
    if (!arrival and !ordinary) {
        if (selection == .automatic or input.cancel or (!input.action and !world.action_pending)) return false;
        entry.facing = input.direction orelse world.facing;
        for (binding.population.entities) |entity| {
            if (entity.trigger != .interaction or entity.event.status != .resolved) continue;
            const point = binding.interactionPosition(entity.source_order, actors) orelse continue;
            if (!field.interactionReaches(entry, state.package, point.x, point.y)) continue;
            rooms.session = field_events.Session.beginInteraction(rooms.active_binding, entry, serial, entity.source_order, construction) catch |err| switch (err) {
                error.IneligibleFieldInteraction, error.UnavailableFieldInteraction, error.EventConditionFalse => continue,
                else => return err,
            };
            break;
        } else return false;
    }
    try attachFieldEvent(state, &rooms.session, &rooms.active_binding);
    state.checked_arrival_visit = world.room_entries;
    world.walking = false;
    if (!ordinary) {
        world.facing = entry.facing;
        world.action_pending = false;
    }
    rooms.serial = serial;
    return !ordinary;
}

pub fn validateScenePartyChanges(state: *const journey.State) !void {
    const rooms = state.room_battles orelse return;
    for (rooms.bindings) |binding| for (binding.population.entities) |entity| {
        if (entity.event.status != .resolved) continue;
        const program = binding.content.program(entity.event.program_id.?) orelse return error.UnknownEventProgram;
        for (program.commands) |command| {
            if (command.kind == .party_select) {
                if (state.party_catalog == null or state.party_bindings == null) return error.MissingPartyCatalogue;
                if (state.party_backing == null or state.party_backing.?.len < 6) return error.MissingPartyBacking;
                if (state.combat.integrationHost() == null) return error.MissingBattleIntegration;
                continue;
            }
            if (command.kind != .party_join and command.kind != .party_load and command.kind != .advance_character and command.kind != .party_leave) continue;
            const host = state.combat.integrationHost() orelse return error.MissingBattleIntegration;
            const id = command.character.?;
            if (host.characterId(id) == null or ((command.kind == .party_load or command.kind == .advance_character) and host.characterId(id).? >= 108) or state.combat.content.partyProfile(id) == null) return error.UnknownFieldEventPartyMember;
            if (command.kind == .party_join or command.kind == .party_load or command.kind == .advance_character) {
                const catalog = state.party_catalog orelse return error.MissingPartyCatalogue;
                _ = try party_session.catalogue.materializeBound(state.combat.*, catalog, id, state.party_bindings);
            }
        }
    };
}

fn prepareSceneInventory(combat: *const battle.State, member: usize, edit: field.game_state.event_runtime.InventoryEdit) !?field.items.Inventory {
    var inventory = combat.progress.party[member].inventory;
    if (edit.take) |name| {
        const id = std.meta.stringToEnum(field.items.Id, name) orelse return error.InvalidItem;
        const slot = for (inventory.slots[0..inventory.count()], 0..) |item, index| {
            if (item.?.id == id and !combat.itemEquipped(member, index)) break index;
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

pub fn bindSharedItems(state: *const journey.State, slots: journey.SharedItems) !journey.SharedItems {
    var bound = slots;
    var ended = false;
    for (&bound) |*slot| {
        if (slot.*) |name| {
            if (ended) return error.InvalidSharedItems;
            const catalogue = state.shared_item_catalogue orelse return error.MissingSharedItemCatalogue;
            const item = item_ledger.catalogue.sharedKey(catalogue, name) catch return error.SharedItemContentMismatch;
            slot.* = item.id;
        } else ended = true;
    }
    return bound;
}

pub fn sharedItemNames(state: *const journey.State) journey.SharedItems {
    var names: journey.SharedItems = @splat(null);
    const catalogue = state.shared_item_catalogue orelse return names;
    for (state.shared_items, &names) |entry, *label| {
        const id = entry orelse break;
        if (item_ledger.catalogue.findById(catalogue, id)) |item| label.* = item.label;
    }
    return names;
}

fn prepareSharedInventory(state: *const journey.State, edit: field.game_state.event_runtime.InventoryEdit) !?journey.SharedItems {
    const catalogue = state.shared_item_catalogue orelse return error.MissingSharedItemCatalogue;
    var view = try item_ledger.ledger.viewOf(catalogue, state.shared_items, 0);
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

fn collectFacilityItems(state: *journey.State, ids: []const field.items.Id) !u8 {
    const catalogue = state.shared_item_catalogue orelse return error.MissingSharedItemCatalogue;
    var view = try item_ledger.ledger.viewOf(catalogue, state.shared_items, 0);
    var inventories: [6]field.items.Inventory = undefined;
    for (state.field_state.progress.party, inventories[0..state.field_state.progress.party.len]) |member, *inventory| inventory.* = member.inventory;
    var collected: u8 = 0;
    for (ids, 0..) |id, index| {
        const source = try item_ledger.catalogue.sharedKey(catalogue, @tagName(id));
        const bit = @as(u8, 1) << @as(u3, @intCast(index));
        while (view.find(source.source_item_id) != null) {
            view = (try item_ledger.ledger.apply(view, .remove, source.source_item_id)).view;
            collected |= bit;
        }
        for (inventories[0..state.field_state.progress.party.len]) |*inventory| {
            var slot: usize = 0;
            while (slot < inventory.count()) {
                if (inventory.slots[slot].?.id == id) {
                    inventory.remove(slot);
                    collected |= bit;
                } else slot += 1;
            }
        }
    }
    state.shared_items = try item_ledger.ledger.slotsOf(catalogue, view);
    for (state.field_state.progress.party, inventories[0..state.field_state.progress.party.len]) |*member, inventory| member.inventory = inventory;
    return collected;
}

noinline fn commitScenePartyEffect(state: *journey.State, owner: journey.ActiveFieldEvent) !void {
    const rooms = state.room_battles orelse return error.FieldEventBlocked;
    if (owner.session != &rooms.session or owner.binding != &rooms.active_binding) return error.FieldEventBlocked;
    const binding = owner.binding.*;
    if (try owner.session.pendingPartyEdit(binding)) |effect| {
        var story = state.field_state.progress.story.scenario orelse return error.MissingSourceStoryState;
        if (effect.kind == .party_gain_experience or effect.kind == .party_lose_experience) {
            if (state.combat.replay_draws != null) return error.InvalidCharacterGrowth;
            var members: [6]battle.Member = undefined;
            const count = state.combat.partyCount();
            @memcpy(members[0..count], state.combat.progress.party);
            var next = state.combat.*;
            next.progress.party = members[0..count];
            try next.sceneExperience(effect.kind == .party_gain_experience);
            try owner.session.acknowledgePartyEdit(binding, true, &story);
            for (0..count) |index| state.combat.setOwnedMember(index, next.ownedMember(index));
            state.combat.random = next.random;
        } else if (effect.kind == .advance_character) {
            var advances = effect.level_advances.?;
            if (effect.add_hero_level == true) {
                const hero_level = for (state.combat.progress.party, 0..) |member, index| {
                    if (std.mem.eql(u8, member.id, "hero")) break state.combat.levels[index];
                } else return error.InvalidCharacterGrowth;
                advances = @min(advances +| hero_level, 99);
            }
            const growth = try roster.prepareGrowth(state, effect.character.?, advances);
            try owner.session.acknowledgePartyEdit(binding, true, &story);
            roster.commitGrowth(state, growth);
        } else if (effect.kind == .warehouse_deposit) {
            const id = effect.character.?;
            const equipment = (state.combat.content.systems orelse return error.InvalidSystems).equipment;
            const catalogue = state.shared_item_catalogue orelse return error.MissingSharedItemCatalogue;
            const active = for (state.combat.progress.party, 0..) |member, index| {
                if (std.mem.eql(u8, member.id, id)) break @as(?usize, index);
            } else null;
            const reserve = if (active == null) for (&state.reserves) |*entry| {
                const member = if (entry.*) |*owned| owned else break null;
                if (std.mem.eql(u8, member.member.id, id)) break member;
            } else null else null;
            if (active != null or reserve != null) {
                const owned = if (active) |index| state.combat.ownedMember(index) else reserve.?.*;
                var inventory = owned.member.inventory;
                var storage = state.combat.progress.storage;
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
                    state.combat.progress.party[index].inventory = inventory;
                } else {
                    reserve.?.member.inventory = inventory;
                }
                state.combat.progress.storage = storage;
            } else try owner.session.acknowledgePartyEdit(binding, true, &story);
        } else if (effect.kind == .shared_inventory_edit) {
            const inventory = try prepareSharedInventory(state, effect.inventory.?);
            try owner.session.acknowledgePartyEdit(binding, inventory != null, &story);
            if (inventory) |next| state.shared_items = next;
        } else {
            const member = for (state.combat.progress.party, 0..) |character, index| {
                if (std.mem.eql(u8, character.id, effect.character.?)) break @as(?usize, index);
            } else null;
            if (effect.inventory) |edit| {
                const inventory = if (member) |index| try prepareSceneInventory(state.combat, index, edit) else null;
                try owner.session.acknowledgePartyEdit(binding, inventory != null, &story);
                if (inventory) |next| state.combat.progress.party[member.?].inventory = next;
            } else {
                const rules = state.combat.content.systems orelse return error.InvalidRune;
                const rune = rules.runeIndex(effect.rune.?) orelse return error.InvalidRune;
                const slot: *?usize, var owned: battle.OwnedMember = if (member) |index|
                    .{ &state.combat.runes[index], state.combat.ownedMember(index) }
                else reserve: {
                    for (&state.reserves) |*entry| {
                        const record = if (entry.*) |*record| record else break;
                        if (std.mem.eql(u8, record.member.id, effect.character.?)) break :reserve .{ &record.rune, record.* };
                    }
                    return error.InvalidMember;
                };
                const was_empty = slot.* == null;
                owned.rune = rune;
                try state.combat.validateOwnedMember(owned);
                try owner.session.acknowledgePartyEdit(binding, true, &story);
                slot.* = rune;
                if (was_empty and member != null) {
                    const party_member = &state.combat.progress.party[member.?];
                    if (std.mem.allEqual(u16, &party_member.rune_charges, 0)) {
                        party_member.rune_charges = party_member.max_rune_charges;
                    }
                }
            }
        }
        state.setScenarioStory(story);
        return;
    }
    const change = (try owner.session.pendingPartyChange(binding)) orelse return error.FieldEventBlocked;
    if (change.kind == .party_dismiss) {
        if (binding.party.len != state.combat.partyCount()) return error.FieldEventPartyMismatch;
        const dismissal = try roster.preparePartyDismiss(state);
        const keep = binding.party[dismissal.keep];
        const party_ids: [6]u8 = .{ keep, 255, 255, 255, 255, 255 };
        var story = state.field_state.progress.story.scenario orelse return error.MissingSourceStoryState;
        var auxiliary = state.field_state.auxiliary_party;
        if (auxiliary) |*list| for (binding.party, 0..) |departing, index| {
            if (index != dismissal.keep) field.editAuxiliaryParty(list, false, departing);
        };
        try owner.session.acknowledgePartyChange(binding, dismissal.keep, party_ids[0..1], &story);
        roster.commitPartyDismiss(state, dismissal);
        state.field_state.auxiliary_party = auxiliary;
        rooms.party = party_ids;
        rooms.active_binding.party = rooms.party[0..1];
        state.setScenarioStory(story);
        return;
    }
    const id = change.character.?;
    const host = state.combat.integrationHost() orelse return error.MissingBattleIntegration;
    const source_id = host.characterId(id) orelse return error.UnknownFieldEventPartyMember;
    var party_ids = rooms.party;
    var count = binding.party.len;
    var story = state.field_state.progress.story.scenario orelse return error.MissingSourceStoryState;
    if (change.kind == .party_load and (count == 6 or std.mem.indexOfScalar(u8, binding.party, source_id) != null)) {
        try owner.session.acknowledgePartyLoad(binding, source_id, party_ids[0..count], &story);
    } else if (change.kind == .party_join or change.kind == .party_load) {
        const catalog = state.party_catalog orelse return error.MissingPartyCatalogue;
        const backing = state.party_backing orelse return error.InvalidParty;
        const join = try roster.preparePartyJoin(state, backing, catalog, state.party_bindings, id);
        party_ids[count] = source_id;
        if (change.kind == .party_load) {
            try owner.session.acknowledgePartyLoad(binding, source_id, party_ids[0 .. count + 1], &story);
        } else try owner.session.acknowledgePartyChange(binding, count, party_ids[0 .. count + 1], &story);
        roster.commitPartyJoin(state, backing, join);
        if (change.level_advances) |advances| {
            for (0..advances) |_| {
                var rolls: [7]u15 = undefined;
                for (&rolls) |*roll| roll.* = state.combat.roll();
                state.combat.levelUp(count, rolls);
            }
        }
        count += 1;
    } else if (change.value == 1 and std.mem.indexOfScalar(u8, binding.party, source_id) == null) {
        try owner.session.acknowledgePartyChange(binding, count, party_ids[0..count], &story);
    } else {
        const leave = try roster.preparePartyLeave(state, id);
        if (party_ids[leave.member] != source_id) return error.FieldEventPartyMismatch;
        count -= 1;
        std.mem.copyForwards(u8, party_ids[leave.member..count], party_ids[leave.member + 1 .. count + 1]);
        party_ids[count] = 255;
        var auxiliary = state.field_state.auxiliary_party;
        if (auxiliary) |*list| field.editAuxiliaryParty(list, false, source_id);
        try owner.session.acknowledgePartyChange(binding, leave.member, party_ids[0..count], &story);
        roster.commitPartyLeave(state, leave);
        state.field_state.auxiliary_party = auxiliary;
    }
    rooms.party = party_ids;
    rooms.active_binding.party = rooms.party[0..count];
    if (story.castle_tier != state.combat.progress.story.scenario.?.castle_tier)
        state.combat.progress.story.recruitment_tier = story.castle_tier;
    state.setScenarioStory(story);
}

pub fn tickActiveFieldEvent(state: *journey.State, owner: journey.ActiveFieldEvent, input: pause.Input, consumed_action: bool) !pause.Effect {
    const binding = owner.binding.*;
    state.elapsed_ticks +|= 1;
    const before_entry = state.field_state.room_entries;
    if (owner.session.queuedBattle() == null) {
        const old_entry = state.field_state.room_entries;
        const saved_field_facing = state.field_state.facing;
        var field_input = input.field;
        if (consumed_action) field_input.action = false;
        const result = try owner.session.tickField(binding, &state.field_state, field_input);
        if (owner.session.inn_payment_refused) {
            owner.session.inn_payment_refused = false;
            const message = if (state.field_state.inn_rules) |rules| rules.insufficient_funds else "Not enough bits to stay.";
            state.menu.notify(message);
        }
        if (result == .blocked) {
            if (try owner.session.pendingWheelSpin(binding)) {
                if (state.combat.replay_draws != null) return error.InvalidBattleReplay;
                var random = state.combat.random;
                // shortcut: shared prototype PRNG; qualify BIOS sequence before claiming RNG parity.
                const roll = random.random().int(u15);
                const wheel = state.field_state.wheel_state orelse field.wheel.Room{};
                if (wheel.startDraws() == 2) _ = random.random().int(u15);
                try owner.session.acknowledgeWheelSpin(binding, &state.field_state, roll);
                state.combat.random = random;
            } else try commitScenePartyEffect(state, owner);
        }
        if (old_entry == state.field_state.room_entries) {
            if (state.field_state.wheel_state) |*wheel| wheel.advance();
            try owner.session.advanceWheelGraphics(binding, state.field_state);
        }
        state.field_state.scene_ticks +%= 1;
        if (old_entry != state.field_state.room_entries) {
            if (state.field_state.auto_route_id != null) {
                if (owner.session.busy()) return error.PendingCrossingDeparture;
                const receipt = owner.session.receipt orelse return error.MissingCrossingReceipt;
                const program = binding.content.program(receipt.program) orelse return error.UnknownEventProgram;
                state.auto_travel = try journey.travel.Active.begin(state.package, state.field_state, binding, program);
            } else if (std.mem.eql(u8, state.package.rooms[state.field_state.room].id, journey.travel.source.world_room) and
                state.field_state.progress.story.scenario.?.world_mode == 1)
            {
                if (state.boat_data == null or owner.session.busy()) return error.MissingBoatOwner;
                state.boat_travel = try journey.travel.Boat.begin(state.package, state.field_state, saved_field_facing);
                state.field_state.facing = .right;
            }
            const scripted_world_exit = if (state.room_battles) |rooms|
                if (owner.session.receipt) |receipt|
                    owner.session == &rooms.session and rooms.isOpeningWorldExit(binding.room, receipt.program)
                else
                    false
            else
                false;
            try exploration.onRoomChange(state, scripted_world_exit);
        }
    }
    if (owner.session.queuedBattle() != null) try beginScriptedBattle(state, owner.session, binding);
    if (owner.session.queuedFixedDice() != null) try journey.dice.begin(state);
    if (owner.session.queuedPartySelect() != null) try journey.party_selection.begin(state);
    if (owner.session.queuedItemOverload() != null) try journey.overload.begin(state);
    if (!owner.session.busy()) {
        if (state.room_battles) |rooms| if (before_entry == state.field_state.room_entries and owner.session == &rooms.session and
            std.mem.eql(u8, binding.room, state.package.rooms[state.field_state.room].id))
        {
            try rooms.retainSettledActors(binding, owner.session, state.field_state.room_entries, state.field_state.progress.story.scenario);
        };
        state.field_event = null;
    }
    if (state.field_event == null and state.menu.phase == .closed and state.field_state.pending_service != null) {
        const service = state.field_state.pending_service.?.kind;
        if (service == .cup_game or service == .card_game) {
            try journey.side_games.begin(state, binding, owner.session.receipt orelse return error.MissingFieldGameRequest, service);
            state.field_state.pending_service = null;
            return .none;
        }
        if (service == .teleport) {
            const catalogue = state.teleport_catalogue orelse return error.MissingTeleportCatalogue;
            const story = state.combat.progress.story.scenario orelse return error.MissingSourceStoryState;
            const receipt = owner.session.receipt orelse return error.MissingFieldTeleportRequest;
            state.teleport_session = try journey.travel.beginTeleport(catalogue, story, state.combat.progress.money, receipt.batch);
            state.field_state.pending_service = null;
            return .none;
        }
        if (service == .library or service == .window_styles or service == .sound_themes) {
            const story = if (state.field_state.progress.story.scenario) |*story| story else return error.MissingSourceStoryState;
            switch (service) {
                .library => story.library_books |= try collectFacilityItems(state, &.{ .old_book_vol_1, .old_book_vol_2, .old_book_vol_3, .old_book_vol_4, .old_book_vol_5, .old_book_vol_6, .old_book_vol_7, .old_book_vol_8 }),
                .window_styles => story.scenario[36] |= try collectFacilityItems(state, &.{ .window_setting_0, .window_setting_1, .window_setting_2, .window_setting_3 }),
                .sound_themes => story.scenario[36] |= (try collectFacilityItems(state, &.{ .sound_setting_0, .sound_setting_1, .sound_setting_2, .sound_setting_3 })) << 4,
                else => unreachable,
            }
        }
        const effect = state.menu.tickWithArrival(state.package, &state.field_state, .{}, .immediate);
        return effect;
    }
    return .none;
}
