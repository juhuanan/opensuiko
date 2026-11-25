//! Field populations focused checks: one ordinary-population constructor over
//! three source scenes, compact slots distinct from entity indices, conditional
//! construction with retained identity, real rebuild, typed selector rejection
//! and genuine loaded-party resources (no fake Kirkis preload).
//!
//! No original instruction is executed.  The populations asset is generated
//! from static source facts.

const std = @import("std");
const constructor_mod = @import("travel").constructor;
const data = @import("travel_data").populations;
const event = @import("event_runtime");

const hero_entries = [_]constructor_mod.LoadedEntry{
    .{ .character_id = 8, .resource = "party_character_008", .graphic = "hero" },
};
const hero_loaded = constructor_mod.Loaded{ .entries = &hero_entries };

const empty_entries = [_]constructor_mod.LoadedEntry{};
const empty_loaded = constructor_mod.Loaded{ .entries = &empty_entries };

const fake_kirkis_entries = [_]constructor_mod.LoadedEntry{
    .{ .character_id = 8, .resource = "party_character_008", .graphic = "hero" },
    .{ .character_id = 4, .resource = "party_character_004", .graphic = "kirkis" },
    .{ .character_id = 153, .resource = "party_character_153", .graphic = "kirkis_npc" },
};
const fake_kirkis_loaded = constructor_mod.Loaded{ .entries = &fake_kirkis_entries };

const fake_only_entries = [_]constructor_mod.LoadedEntry{
    .{ .character_id = 4, .resource = "party_character_004", .graphic = "kirkis" },
    .{ .character_id = 153, .resource = "party_character_153", .graphic = "kirkis_npc" },
};
const fake_only_loaded = constructor_mod.Loaded{ .entries = &fake_only_entries };

const wrong_hero_entries = [_]constructor_mod.LoadedEntry{
    .{ .character_id = 8, .resource = "party_character_153", .graphic = "kirkis_npc" },
};
const wrong_hero_loaded = constructor_mod.Loaded{ .entries = &wrong_hero_entries };

const duplicate_hero_entries = [_]constructor_mod.LoadedEntry{
    .{ .character_id = 8, .resource = "party_character_008", .graphic = "hero" },
    .{ .character_id = 8, .resource = "party_character_008", .graphic = "hero" },
};
const duplicate_hero_loaded = constructor_mod.Loaded{ .entries = &duplicate_hero_entries };

fn baseline() event.StoryState {
    return .{};
}

fn withFlag(index: u8, value: u8) event.StoryState {
    var story: event.StoryState = .{};
    story.scenario[index] = value;
    return story;
}

fn openScene(scene_id: []const u8, loaded: constructor_mod.Loaded, story: event.StoryState) !constructor_mod.Opened {
    return constructor_mod.open(std.testing.allocator, data.json, scene_id, loaded, story);
}

fn expectSame(a: [32]u8, b: [32]u8) !void {
    try std.testing.expectEqualSlices(u8, &a, &b);
}

fn expectDifferent(a: [32]u8, b: [32]u8) !void {
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "one constructor opens three source scenes with compact slots, not entity indices" {
    var vaa = try openScene("vaa_room2", empty_loaded, baseline());
    defer vaa.deinit();
    var room0 = try openScene("vb6_room0", empty_loaded, baseline());
    defer room0.deinit();
    var room6 = try openScene("vb6_room6", hero_loaded, baseline());
    defer room6.deinit();

    try std.testing.expectEqualStrings("vaa_room2", vaa.scene().id);
    try std.testing.expectEqualStrings("vb6_room0", room0.scene().id);
    try std.testing.expectEqualStrings("vb6_room6", room6.scene().id);
    try std.testing.expectEqual(@as(u16, 14), vaa.scene().capacity);
    try std.testing.expectEqual(@as(u16, 3), room0.scene().capacity);
    try std.testing.expectEqual(@as(u16, 26), room6.scene().capacity);
    try std.testing.expectEqual(@as(u8, 14), vaa.state.count);
    try std.testing.expectEqual(@as(u8, 3), room0.state.count);
    try std.testing.expectEqual(@as(u8, 26), room6.state.count);

    // VAA: the first actor is source entity 2 at compact slot 0; the last is
    // entity 25 at slot 13.  Every slot differs from its entity index.
    try std.testing.expectEqual(@as(u16, 2), vaa.scene().packet.actors[0].entity);
    try std.testing.expectEqual(@as(u16, 25), vaa.scene().packet.actors[13].entity);
    try std.testing.expectEqual(@as(u16, 7), room6.scene().packet.actors[0].entity);
    try std.testing.expectEqual(@as(u16, 35), room6.scene().packet.actors[25].entity);
    try std.testing.expectEqual(@as(u16, 9), room0.scene().packet.actors[2].entity);
    for (vaa.scene().packet.actors, 0..) |definition, slot| {
        try std.testing.expectEqual(@as(u16, @intCast(slot)), definition.slot);
        try std.testing.expect(definition.entity != definition.slot);
    }

    // A null-classified source record does not consume a slot; it aliases the
    // preceding compact slot.  Source entity 7 aliases slot 4, entity 19 slot 11.
    const alias7 = vaa.recordForEntity(7).?;
    try std.testing.expectEqual(.alias, alias7.kind);
    try std.testing.expectEqual(@as(u16, 4), alias7.alias_slot.?);
    try std.testing.expectEqual(error.NullClassificationAlias, vaa.slotForEntity(7));
    try std.testing.expectEqual(@as(u16, 11), vaa.recordForEntity(19).?.alias_slot.?);
    try std.testing.expectEqual(@as(u16, 5), try vaa.slotForEntity(8));
    try std.testing.expectEqual(@as(u16, 12), try vaa.slotForEntity(22));

    // Baseline construction: VAA and room6 conditional records are active, but
    // VB6 room0 entity 7 is false and therefore a reserved (unconstructed) slot.
    try std.testing.expectEqual(constructor_mod.SlotState.active, vaa.slotState(11));
    try std.testing.expectEqual(constructor_mod.SlotState.active, vaa.slotState(13));
    try std.testing.expectEqual(constructor_mod.SlotState.reserved, room0.slotState(0));
    try std.testing.expectEqual(constructor_mod.SlotState.active, room0.slotState(1));
    try std.testing.expectEqual(constructor_mod.SlotState.reserved, room6.slotState(23));
    try std.testing.expectEqual(error.SelectorNotConstructed, room0.resolveSelector(0));
    try std.testing.expectEqual(error.SelectorNotConstructed, room6.resolveSelector(23));
}

test "flag change retains constructed identity; real rebuild applies the new snapshot" {
    var vaa = try openScene("vaa_room2", empty_loaded, baseline());
    defer vaa.deinit();
    const before = vaa.fingerprint();
    const changed = withFlag(0, 32); // scenario_0000 bit 32 makes VAA entity16 false
    const retained = try vaa.retainAfterStoryChange(changed);
    try expectSame(before, retained.fingerprint);
    try std.testing.expect(retained.would_rebuild_change);
    try std.testing.expectEqual(constructor_mod.SlotState.active, vaa.slotState(11));
    switch (try vaa.resolveSelector(11)) {
        .slot => |actor| {
            try std.testing.expectEqual(@as(u16, 16), actor.entity);
            try std.testing.expectEqualStrings("vaa_room2_character_016", actor.resource);
        },
        .hero => return error.UnexpectedHero,
    }

    try vaa.rebuild(changed);
    const after = vaa.fingerprint();
    try expectDifferent(before, after);
    try std.testing.expectEqual(constructor_mod.SlotState.reserved, vaa.slotState(11));
    try std.testing.expectEqual(error.SelectorNotConstructed, vaa.resolveSelector(11));
    // Reserved slots keep consuming their index: entities 22 and 25 stay at
    // slots 12 and 13 after the rebuild.
    try std.testing.expectEqual(@as(u16, 22), vaa.scene().packet.actors[12].entity);
    try std.testing.expectEqual(@as(u16, 25), vaa.scene().packet.actors[13].entity);
    try std.testing.expectEqual(constructor_mod.SlotState.active, vaa.slotState(12));

    // A real rebuild with the original snapshot reconstructs the same identity.
    try vaa.rebuild(baseline());
    try expectSame(before, vaa.fingerprint());
    try std.testing.expectEqual(constructor_mod.SlotState.active, vaa.slotState(11));

    // VB6 room6: three elf records are reserved at baseline and become active
    // only after a real rebuild with scenario_0019 bit 8.
    var room6 = try openScene("vb6_room6", hero_loaded, baseline());
    defer room6.deinit();
    const room6_before = room6.fingerprint();
    try std.testing.expectEqual(constructor_mod.SlotState.reserved, room6.slotState(23));
    try std.testing.expectEqual(constructor_mod.SlotState.reserved, room6.slotState(25));
    const activated = withFlag(19, 8);
    const room6_retained = try room6.retainAfterStoryChange(activated);
    try expectSame(room6_before, room6_retained.fingerprint);
    try std.testing.expect(room6_retained.would_rebuild_change);
    try room6.rebuild(activated);
    try expectDifferent(room6_before, room6.fingerprint());
    try std.testing.expectEqual(constructor_mod.SlotState.active, room6.slotState(23));
    try std.testing.expectEqual(constructor_mod.SlotState.active, room6.slotState(25));
    switch (try room6.resolveSelector(25)) {
        .slot => |actor| {
            try std.testing.expectEqual(@as(u16, 35), actor.entity);
            try std.testing.expectEqual(@as(u16, 153), actor.character_id);
            try std.testing.expectEqual(constructor_mod.Domain.area_character_context, actor.domain);
            try std.testing.expectEqualStrings("vb6_room6_character_153", actor.resource);
        },
        .hero => return error.UnexpectedHero,
    }

    // Event-selection-only flag changes do not vote on construction: setting
    // VB6 scenario_0015 bit 64 changes no classification condition.
    var event_only = withFlag(19, 8);
    event_only.scenario[15] = 64;
    const event_retained = try room6.retainAfterStoryChange(event_only);
    try expectSame(room6.fingerprint(), event_retained.fingerprint);
    try std.testing.expect(!event_retained.would_rebuild_change);

    // VB6 room0 flips its one odd-job villager with scenario_0020 bit 2.
    var room0 = try openScene("vb6_room0", empty_loaded, baseline());
    defer room0.deinit();
    const room0_before = room0.fingerprint();
    try std.testing.expectEqual(constructor_mod.SlotState.reserved, room0.slotState(0));
    try room0.rebuild(withFlag(20, 2));
    try expectDifferent(room0_before, room0.fingerprint());
    try std.testing.expectEqual(constructor_mod.SlotState.active, room0.slotState(0));

    // Reopening the same bytes and story is a deterministic fresh-process
    // restart: identical construction identity.
    var reopened = try openScene("vaa_room2", empty_loaded, baseline());
    defer reopened.deinit();
    try expectSame(before, reopened.fingerprint());
}

test "missing, reserved, released and out-of-scope selectors reject" {
    var vaa = try openScene("vaa_room2", empty_loaded, baseline());
    defer vaa.deinit();
    try std.testing.expectEqual(error.SelectorNotConstructed, vaa.resolveSelector(14));
    try std.testing.expectEqual(error.SelectorNotConstructed, vaa.resolveSelector(39));
    try std.testing.expectEqual(error.UnsupportedSelectorForm, vaa.resolveSelector(0x40));
    try std.testing.expectEqual(error.UnsupportedSelectorForm, vaa.resolveSelector(0x7F));
    switch (try vaa.resolveSelector(0x80)) {
        .hero => |hero| try std.testing.expectEqual(@as(u8, 8), hero.character_id),
        .slot => return error.UnexpectedSlot,
    }

    try vaa.release("scene_actor_5");
    try std.testing.expectEqual(constructor_mod.SlotState.released, vaa.slotState(5));
    try std.testing.expectEqual(error.SelectorReleased, vaa.resolveSelector(5));
    try std.testing.expectEqual(error.ActorAlreadyReleased, vaa.release("scene_actor_5"));
    try std.testing.expectEqual(error.UnknownPopulationActor, vaa.release("no_such_actor"));
    // Releasing one slot leaves the ordered neighbours constructed.
    try std.testing.expectEqual(constructor_mod.SlotState.active, vaa.slotState(4));
    try std.testing.expectEqual(constructor_mod.SlotState.active, vaa.slotState(6));

    // A real rebuild constructs the actor again; release markers do not survive.
    try vaa.rebuild(baseline());
    try std.testing.expectEqual(constructor_mod.SlotState.active, vaa.slotState(5));
    switch (try vaa.resolveSelector(5)) {
        .slot => |actor| try std.testing.expectEqualStrings("scene_actor_5", actor.id),
        .hero => return error.UnexpectedHero,
    }
}

test "loaded party is genuine; a fake Kirkis preload is inert" {
    var with_hero = try openScene("vb6_room6", hero_loaded, baseline());
    defer with_hero.deinit();
    var with_fake = try openScene("vb6_room6", fake_kirkis_loaded, baseline());
    defer with_fake.deinit();

    // The fake loaded entries do not create actors or change construction.
    try std.testing.expectEqual(with_hero.state.count, with_fake.state.count);
    try expectSame(with_hero.fingerprint(), with_fake.fingerprint());
    try std.testing.expectEqual(constructor_mod.SlotState.reserved, with_fake.slotState(25));
    try with_fake.rebuild(withFlag(19, 8));
    switch (try with_fake.resolveSelector(25)) {
        .slot => |actor| {
            try std.testing.expectEqualStrings("vb6_room6_character_153", actor.resource);
            try std.testing.expectEqual(constructor_mod.Domain.area_character_context, actor.domain);
        },
        .hero => return error.UnexpectedHero,
    }
    // A fake entry for the Hero's character id is not a substitute for the
    // genuine loaded Hero resource.
    try std.testing.expectEqual(error.MissingLoadedPartyResource, openScene("vb6_room6", fake_only_loaded, baseline()));
    try std.testing.expectEqual(error.MissingLoadedPartyResource, openScene("vb6_room6", wrong_hero_loaded, baseline()));
    try std.testing.expectEqual(error.MissingLoadedPartyResource, openScene("vb6_room6", empty_loaded, baseline()));
    try std.testing.expectEqual(error.DuplicateLoadedPartyResource, openScene("vb6_room6", duplicate_hero_loaded, baseline()));

    // Scenes that use only area-section resources need no loaded party at all.
    var vaa = try openScene("vaa_room2", empty_loaded, baseline());
    defer vaa.deinit();
    var room0 = try openScene("vb6_room0", empty_loaded, baseline());
    defer room0.deinit();
    try std.testing.expectEqual(@as(u8, 14), vaa.state.count);
    try std.testing.expectEqual(@as(u8, 3), room0.state.count);
}

test "asset validation rejects cross-scene, resource, capacity and animation substitution" {
    var parsed = try constructor_mod.parseAsset(std.testing.allocator, data.json);
    defer parsed.deinit();
    const scenes = @constCast(parsed.value.scenes);

    const saved_population = scenes[0].population_sha256;
    scenes[0].population_sha256 = scenes[2].population_sha256;
    try std.testing.expectEqual(error.PopulationBindingMismatch, constructor_mod.validateAsset(&parsed.value));
    scenes[0].population_sha256 = saved_population;

    const saved_capacity = scenes[0].capacity;
    scenes[0].capacity = 15;
    try std.testing.expectEqual(error.InvalidPopulationCapacity, constructor_mod.validateAsset(&parsed.value));
    scenes[0].capacity = saved_capacity;

    const records = @constCast(scenes[0].records);
    const saved_slot = records[0].slot;
    records[0].slot = 1;
    try std.testing.expectEqual(error.InvalidPopulationRecord, constructor_mod.validateAsset(&parsed.value));
    records[0].slot = saved_slot;

    const resources = @constCast(scenes[0].area_resources);
    const saved_resource = resources[0].id;
    resources[0].id = "vaa_room2_character_999";
    try std.testing.expectEqual(error.UnknownAreaResource, constructor_mod.validateAsset(&parsed.value));
    resources[0].id = saved_resource;

    const animations = @constCast(scenes[0].animations);
    const saved_graphic = animations[0].graphic;
    animations[0].graphic = "unknown_graphic";
    try std.testing.expectEqual(error.MissingFieldActorResource, constructor_mod.validateAsset(&parsed.value));
    animations[0].graphic = saved_graphic;

    // Restored bytes validate and open again.
    try constructor_mod.validateAsset(&parsed.value);
    var reopened = try openScene("vaa_room2", empty_loaded, baseline());
    defer reopened.deinit();
    try std.testing.expectEqual(@as(u8, 14), reopened.state.count);
}
