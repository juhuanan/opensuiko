const std = @import("std");
const field = @import("field");
const battle = @import("battle");
const journey = @import("journey");
const party_session = @import("party_session");
const pause = @import("pause_menu");
const allocator = std.testing.allocator;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;

test "scripted crossing owns Journey input and arrives before its final movement finishes" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    const blocked: [19200]u8 = @splat('0');
    const land: [1536]u8 = @splat('1');
    var rooms = [_]field.Room{ fixtures.package.value.rooms[0], fixtures.package.value.rooms[0] };
    rooms[0].id = "world_j";
    rooms[0].width = 1280;
    rooms[0].height = 960;
    rooms[0].walkable = &blocked;
    rooms[0].boat_walkable = &blocked;
    rooms[1].id = "vb5i0_room_0";
    rooms[1].width = 256;
    rooms[1].height = 384;
    rooms[1].walkable = &land;
    state.package.rooms = &rooms;
    state.field_state.enterRoom(0, .{ .x = 952, .y = 600 });
    state.field_state.facing = .right;
    state.field_state.auto_route_id = 4;
    state.field_state.progress.story.scenario = .{ .world_mode = 1 };
    state.field_state.progress.story.scenario.?.scenario[12] = 1;
    state.field_state.progress.story.scenario.?.scenario[38] = 8;
    const events = field.game_state.event_runtime;
    const commands = [_]events.Command{ .{ .kind = .world_mode, .code = 12 }, .{ .kind = .world_mode, .code = 20 }, .{ .kind = .auto_route, .value = 4 }, .{ .kind = .world_transition, .destination = "world_j", .x = 119, .y = 75 } };
    const program: events.Program = .{ .id = "crossing", .entity = 21, .entry = .ordinary, .trigger = .interaction, .commands = &commands };
    const origin: journey.travel.SceneSource = .{
        .file = "DATA/02_AREA.B/VB2.BIN",
        .sha256 = journey.travel.source.caller_sha256,
        .room = 0,
        .lba = 0,
        .size = 0,
    };
    var wrong_caller = program;
    wrong_caller.entity = 20;
    try std.testing.expectError(error.UnsupportedCrossingCaller, journey.travel.Active.begin(state.package, state.field_state, origin, wrong_caller));
    state.auto_travel = try journey.travel.Active.begin(state.package, state.field_state, origin, program);
    try std.testing.expectError(error.GameBusy, journey.Snapshot.capture(state));
    const scripted = try state.advanceSimulation(.{ .menu = .{ .menu = true, .field = .{ .direction = .right } } }, null);
    try expect(scripted.crossing == .scripted);
    try equal(@as(f32, 951.5), state.field_state.position(state.package).x);
    for (0..304) |_| _ = try state.tickWithFieldEvents(.{ .menu = true, .field = .{ .direction = .right, .action = true } }, .{});
    try equal(@as(usize, 1), state.field_state.room);
    try equal(field.Point{ .x = 128, .y = 344 }, state.field_state.destination);
    try equal(field.Direction.right, state.field_state.facing);
    try equal(pause.Phase.closed, state.menu.phase);
    try expect(state.auto_travel == null and state.field_state.auto_route_id == null and state.field_state.step_duration == null);
    try equal(@as(u8, 0), state.combat.progress.story.scenario.?.world_mode);
    try equal(@as(u8, 0), state.combat.progress.story.scenario.?.scenario[38] & 8);

    const water = try journey.travel.loadBoatData(allocator, journey.travel.boat_json);
    defer water.deinit();
    const shore: [19200]u8 = @splat('1');
    rooms[1].id = "vb2_room_0";
    rooms[1].width = 1280;
    rooms[1].height = 960;
    rooms[1].walkable = &shore;
    state.package.start_room = rooms[1].id;
    state.boat_data = &water.value;
    state.field_state.enterRoom(0, .{ .x = 800, .y = 600 });
    state.field_state.progress.story.scenario.?.world_mode = 1;
    state.field_state.facing = .right;
    state.boat_travel = try journey.travel.Boat.begin(state.package, state.field_state, .left);
    const boat_rng = state.combat.random;
    const idle = try state.advanceSimulation(.{}, null);
    try expect(idle.crossing == .steered and idle.crossing.steered == null);
    const paused_boat = state.boat_travel.?;
    const pause_open = try state.advanceSimulation(.{ .menu = .{ .menu = true } }, null);
    try expect(pause_open.crossing == .none);
    try equal(pause.Phase.root, state.menu.phase);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .right } }, .{});
    try std.testing.expectEqualDeep(paused_boat, state.boat_travel.?);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
    try equal(pause.Phase.closed, state.menu.phase);
    for (0..18 * 16) |_| {
        const steered = try state.advanceSimulation(.{ .menu = .{ .field = .{ .direction = .right } } }, null);
        try expect(steered.crossing == .steered and steered.crossing.steered == .east);
    }
    try equal(field.Point{ .x = 944, .y = 600 }, state.field_state.destination);
    const boat_save = try journey.Snapshot.capture(state);
    var invalid_boat = boat_save;
    invalid_boat.boat_travel.?.session.vessel.?.camera.x += 1;
    try std.testing.expectError(error.InvalidBoatState, invalid_boat.validate(state));
    invalid_boat = boat_save;
    invalid_boat.schema = "suikoden-journey-save/32";
    try std.testing.expectError(error.InvalidSave, invalid_boat.validate(state));
    const encoded_boat = try std.json.Stringify.valueAlloc(allocator, boat_save, .{});
    defer allocator.free(encoded_boat);
    const decoded_boat = try std.json.parseFromSlice(journey.Snapshot, allocator, encoded_boat, .{});
    defer decoded_boat.deinit();
    state.boat_travel = null;
    try decoded_boat.value.apply(&state);
    try expect(state.boat_travel != null);
    _ = try state.tickWithFieldEvents(.{ .field = .{ .direction = .up } }, .{});
    try std.testing.expectEqualStrings("vb2_room_0", state.package.rooms[state.field_state.room].id);
    try equal(field.Point{ .x = 144, .y = 544 }, state.field_state.destination);
    try equal(field.Direction.left, state.field_state.facing);
    try equal(@as(u8, 0), state.combat.progress.story.scenario.?.world_mode);
    try expect(state.boat_travel == null);
    try std.testing.expectEqualDeep(boat_rng, state.combat.random);
}

test "defeat departure advances behind retry and preserves checkpoint" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    try state.beginEncounter(0);
    const hp = state.combat.hp(0);
    const random = state.combat.random;
    state.combat.progress.party[0].balloons = 3;
    state.combat.beginDeparture(0);
    state.combat.phase = .defeat;
    state.mode = .defeat;
    const start = state.combat.camera_ticks;
    const origin = battle.layout.worldPosition(state.combat, 0);
    for (0..96) |_| _ = state.tick(.{}, .{});
    try expect(battle.layout.worldPosition(state.combat, 0).z < origin.z);
    try equal(start + 96, state.combat.camera_ticks);
    try equal(.defeat, state.mode);
    try equal(hp, state.combat.hp(0));
    try std.testing.expectEqualDeep(random, state.combat.random);
    _ = state.tick(.{}, .{});
    try equal(start + 97, state.combat.camera_ticks);
    try expect(state.combat.departures[0] == null);
    _ = state.tick(.{}, .{ .confirm = true });
    try equal(.battle, state.mode);
    try expect(!state.combat.departed[0] and state.combat.departures[0] == null);
    try equal(@as(u8, 0), state.combat.progress.party[0].balloons);
}

test "journey encounter carries rune pieces into battle and retry" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    state.extras[0] = .{ .member_id = "wrong_member", .weapon_element = .fire, .weapon_fragments = .{ 3, 0, 0, 0, 0 } };
    const before = state.combat.*;
    try std.testing.expectError(error.InvalidExtras, state.beginEncounter(0));
    try expect(state.checkpoint == null and state.mode == .field);
    try std.testing.expectEqualDeep(before, state.combat.*);
    state.extras[0].member_id = "";
    try std.testing.expectError(error.InvalidExtras, state.beginEncounter(0));
    state.extras[0] = .{ .member_id = state.combat.progress.party[0].id, .weapon_element = .wind, .weapon_fragments = .{ 0, 0, 3, 0, 0 } };
    try state.beginEncounter(0);
    try expect(state.combat.weapon_augments[0].rune == .wind);
    try equal(@as(u8, 3), state.combat.weapon_augments[0].fragments);
    state.combat.phase = .defeat;
    state.mode = .defeat;
    _ = state.tick(.{}, .{ .confirm = true });
    try expect(state.combat.weapon_augments[0].rune == .wind);
    try equal(@as(u8, 3), state.combat.weapon_augments[0].fragments);
}

test "journey item menu attaches each weapon rune piece and persists its battle effects" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    const Case = struct { id: field.items.Id, element: @FieldType(party_session.CharacterExtra, "weapon_element"), index: usize };
    const cases = [_]Case{
        .{ .id = .fire_rune_piece, .element = .fire, .index = 0 },
        .{ .id = .water_rune_piece, .element = .water, .index = 1 },
        .{ .id = .wind_rune_piece, .element = .wind, .index = 2 },
        .{ .id = .thunder_rune_piece, .element = .thunder, .index = 3 },
        .{ .id = .earth_rune_piece, .element = .earth, .index = 4 },
    };
    for (cases) |case| {
        var members: [6]battle.Member = undefined;
        var state = try fixtures.session(&members);
        const before = state.combat.stats(1);
        members[0].inventory.slots[0] = .{ .id = case.id, .uses = 0 };
        const next_item = members[0].inventory.slots[1].?;
        state.menu.phase = .item_action;
        state.menu.member = 0;
        state.menu.slot = 0;
        confirm(&state);
        try equal(.item_target, state.menu.phase);
        _ = state.tick(.{ .field = .{ .menu_direction = .down } }, .{});
        confirm(&state);
        try equal(.item_notice, state.menu.phase);
        try equal(next_item.id, members[0].inventory.slots[0].?.id);
        try equal(case.element, state.extras[1].weapon_element);
        try equal(@as(u8, 1), state.extras[1].weapon_fragments[case.index]);
        try equal(@as(u8, 1), state.combat.weapon_augments[1].fragments);
        try equal(before.defense + if (case.element == .wind) @as(u16, 3) else 0, state.combat.stats(1).defense);
        try equal(before.skill + if (case.element == .earth) @as(u16, 2) else 0, state.combat.stats(1).skill);
        var directory = std.testing.tmpDir(.{});
        defer directory.cleanup();
        try journey.save(std.testing.io, allocator, directory.dir, state);
        state.extras[1] = .{ .member_id = "" };
        state.combat.weapon_augments[1] = .{};
        try journey.restore(std.testing.io, allocator, directory.dir, &state);
        try equal(case.element, state.extras[1].weapon_element);
        try equal(@as(u8, 1), state.combat.weapon_augments[1].fragments);
        try equal(before.defense + if (case.element == .wind) @as(u16, 3) else 0, state.combat.stats(1).defense);
        try equal(before.skill + if (case.element == .earth) @as(u16, 2) else 0, state.combat.stats(1).skill);
        try state.beginEncounter(0);
        try equal(@as(u8, 1), state.combat.weapon_augments[1].fragments);
    }
}

test "weapon rune piece replacement requires confirmation and the cap preserves inventory" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    members[0].inventory.slots[0] = .{ .id = .water_rune_piece, .uses = 0 };
    state.extras[1] = .{ .member_id = members[1].id, .weapon_element = .wind, .weapon_fragments = .{ 0, 0, 2, 0, 0 } };
    state.combat.weapon_augments[1] = party_session.weaponAugment(state.extras[1]);
    state.menu.phase = .item_action;
    confirm(&state);
    _ = state.tick(.{ .field = .{ .menu_direction = .down } }, .{});
    confirm(&state);
    try equal(.confirm_weapon_piece, state.menu.phase);
    confirm(&state);
    try equal(.item_target, state.menu.phase);
    try equal(.water_rune_piece, members[0].inventory.slots[0].?.id);
    try equal(@as(u8, 2), state.extras[1].weapon_fragments[2]);
    confirm(&state);
    _ = state.tick(.{ .right = true }, .{});
    confirm(&state);
    try equal(.item_notice, state.menu.phase);
    try equal(.water, state.extras[1].weapon_element);
    try equal([5]u8{ 0, 1, 0, 0, 0 }, state.extras[1].weapon_fragments);
    members[0].inventory.slots[0] = .{ .id = .water_rune_piece, .uses = 0 };
    state.extras[1].weapon_fragments[1] = 9;
    state.combat.weapon_augments[1] = party_session.weaponAugment(state.extras[1]);
    state.menu.phase = .item_action;
    state.menu.slot = 0;
    confirm(&state);
    _ = state.tick(.{ .field = .{ .menu_direction = .down } }, .{});
    confirm(&state);
    try equal(.item_notice, state.menu.phase);
    try equal(@as(u8, 9), state.extras[1].weapon_fragments[1]);
    try equal(.water_rune_piece, members[0].inventory.slots[0].?.id);
}

test "weapon rune piece can target its owner without losing shifted equipment" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    members[0].inventory.slots[1] = .{ .id = .earth_rune_piece, .uses = 0 };
    try expect(state.combat.itemEquipped(0, 2));
    const before_skill = state.combat.stats(0).skill;
    state.menu.phase = .item_action;
    state.menu.slot = 1;
    confirm(&state);
    confirm(&state);
    try equal(.item_notice, state.menu.phase);
    try equal(.earth, state.extras[0].weapon_element);
    try equal(before_skill + 2, state.combat.stats(0).skill);
    try equal(.bandanna, members[0].inventory.slots[1].?.id);
    try expect(state.combat.itemEquipped(0, 1));
    members[0].inventory.slots[2] = .{ .id = .earth_rune_piece, .uses = 0 };
    state.menu.phase = .item_action;
    state.menu.slot = 2;
    confirm(&state);
    confirm(&state);
    try equal(@as(u8, 2), state.extras[0].weapon_fragments[4]);
    try equal(before_skill + 4, state.combat.stats(0).skill);
    try expect(state.combat.itemEquipped(0, 1));
}

test "reserve rune pieces follow their owner through swaps saves and battle" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    var reserve = state.combat.ownedMember(0);
    const profile = state.combat.content.partyProfile("maas").?;
    reserve.member.id = profile.id;
    reserve.member.name = profile.name;
    try state.retainReserve(reserve);
    state.extras[0] = .{ .member_id = members[0].id, .weapon_element = .fire, .weapon_fragments = .{ 2, 0, 0, 0, 0 } };
    state.reserve_extras[0] = .{ .member_id = profile.id, .weapon_element = .wind, .weapon_fragments = .{ 0, 0, 3, 0, 0 } };
    try state.swapReserve("hero", "maas");
    try expect(state.extras[0].weapon_element == .wind);
    try expect(state.reserve_extras[0].?.weapon_element == .fire);
    var neutral = state.combat.*;
    neutral.weapon_augments[0] = .{};
    try equal(neutral.stats(0).defense + 9, state.combat.stats(0).defense);
    const roster = state.buildPartySnapshot();
    try std.testing.expectEqualStrings("hero", roster.members[6].?.member.id);
    try expect(roster.extras[6].?.weapon_element == .fire);
    _ = try party_session.Session.init(state.combat.*, roster, .{});
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try journey.save(std.testing.io, allocator, directory.dir, state);
    try state.swapReserve("maas", "hero");
    try journey.restore(std.testing.io, allocator, directory.dir, &state);
    try equal(state.combat.progress.party[0].id.ptr, state.extras[0].member_id.ptr);
    try equal(state.reserves[0].?.member.id.ptr, state.reserve_extras[0].?.member_id.ptr);
    neutral = state.combat.*;
    neutral.weapon_augments[0] = .{};
    try equal(neutral.stats(0).defense + 9, state.combat.stats(0).defense);
    try state.beginEncounter(0);
    try expect(state.combat.weapon_augments[0].rune == .wind);
    try equal(@as(u8, 3), state.combat.weapon_augments[0].fragments);
    state.combat.phase = .defeat;
    state.mode = .defeat;
    _ = state.tick(.{}, .{ .confirm = true });
    try expect(state.combat.weapon_augments[0].rune == .wind);
    state.mode = .field;
    try state.swapReserve("maas", "hero");
    try expect(state.extras[0].weapon_element == .fire);
    try expect(state.reserve_extras[0].?.weapon_element == .wind);
    const before = try journey.Snapshot.capture(state);
    var bad = before;
    bad.reserve_extras = null;
    try std.testing.expectError(error.MissingReserveExtras, bad.apply(&state));
    bad = before;
    bad.reserve_extras.?[0].?.member_id = "hero";
    try std.testing.expectError(error.InvalidExtras, bad.apply(&state));
    bad = before;
    bad.reserve_extras.?[1] = .{ .member_id = "maas" };
    try std.testing.expectError(error.InvalidExtras, bad.apply(&state));
    try std.testing.expectEqualDeep(before, try journey.Snapshot.capture(state));
    var legacy = before;
    legacy.schema = "suikoden-journey-save/18";
    legacy.auxiliary_party = null;
    legacy.reserve_extras = null;
    try legacy.apply(&state);
    try expect(state.extras[0].weapon_element == .fire);
    try expect(state.reserve_extras[0].?.weapon_element == .none);
}

test "Maas join growth matches original event consumer including raw STR and level cap" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    const state = try fixtures.session(&members);
    const before = try journey.Snapshot.capture(state);
    const Vector = struct {
        level: u8,
        draws: []const u15,
        expected: struct { level: u8, experience: u32, hp: u16, max_hp: u16, stats: [6]u16, charges: [4]u16 },
    };
    const vectors = try std.json.parseFromSlice([]const Vector, allocator, @embedFile("fixtures/maas_recruitment.json"), .{});
    defer vectors.deinit();
    for (vectors.value) |vector| {
        var definition = state.data.recruitment.?;
        definition.seed.level = vector.level;
        const joined = try journey.recruitment.prepare(definition, state.combat.*, vector.draws);
        const weapon = state.combat.content.partyProfile("maas").?.weapon.?;
        try equal(vector.expected.level, joined.level);
        try equal(vector.expected.experience, joined.experience);
        try equal(vector.expected.hp, joined.member.hp);
        try equal(vector.expected.max_hp, joined.member.max_hp);
        try equal(vector.expected.stats, [_]u16{ joined.stats.attack - weapon.powers[weapon.initial_level - 1], joined.stats.skill, joined.stats.defense, joined.stats.speed, joined.stats.magic, joined.stats.luck });
        try equal(vector.expected.charges, joined.member.rune_charges);
        try std.testing.expectEqualDeep(definition.seed.member.inventory, joined.member.inventory);
        try std.testing.expectEqualDeep(definition.seed.loadout, joined.loadout);
        try equal(@as(?usize, null), joined.rune);
        var bad = definition;
        bad.seed.level = 100;
        try std.testing.expectError(error.InvalidMember, journey.recruitment.prepare(bad, state.combat.*, vector.draws));
    }
    try std.testing.expectEqualDeep(before, try journey.Snapshot.capture(state));
}

test "Maas recruitment gates and commits membership ownership and RNG atomically across saves" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    const original = try journey.Snapshot.capture(state);
    try expect(!state.canRecruitMaas());
    try std.testing.expectError(error.RecruitmentUnavailable, state.recruitMaas());
    try std.testing.expectEqualDeep(original, try journey.Snapshot.capture(state));
    state.combat.progress.story.recruitment_tier = 1;
    state.combat.progress.story.maas_recruitment_blocked = true;
    try expect(!state.canRecruitMaas());
    try std.testing.expectError(error.RecruitmentUnavailable, state.recruitMaas());
    state.combat.progress.story.maas_recruitment_blocked = false;
    const before = try journey.Snapshot.capture(state);
    state.menu.phase = .root;
    try std.testing.expectError(error.GameBusy, state.recruitMaas());
    state.menu.phase = .closed;
    try std.testing.expectEqualDeep(before, try journey.Snapshot.capture(state));
    try expect(state.canRecruitMaas());
    var expected_random = state.combat.random;
    var draws: [119]u15 = undefined;
    for (&draws) |*draw| draw.* = expected_random.random().int(u15);
    const expected = try journey.recruitment.prepare(state.data.recruitment.?, state.combat.*, &draws);
    try state.recruitMaas();
    try std.testing.expectEqualDeep(expected, state.reserves[0].?);
    try std.testing.expectEqualDeep(expected_random, state.combat.random);
    try expect(state.combat.progress.story.maas_recruited);
    try expect(!state.canRecruitMaas());
    for (0..6) |i| try std.testing.expectEqualDeep(before.party[i], members[i]);
    const joined = try journey.Snapshot.capture(state);
    try std.testing.expectError(error.RecruitmentUnavailable, state.recruitMaas());
    try std.testing.expectEqualDeep(joined, try journey.Snapshot.capture(state));
    var invalid = joined;
    invalid.reserves = @splat(null);
    try std.testing.expectError(error.MissingRecruitedMember, invalid.apply(&state));
    try std.testing.expectEqualDeep(joined, try journey.Snapshot.capture(state));
    const bytes = try std.json.Stringify.valueAlloc(allocator, joined, .{});
    defer allocator.free(bytes);
    const saved = try std.json.parseFromSlice(journey.Snapshot, allocator, bytes, .{});
    defer saved.deinit();
    try original.apply(&state);
    try saved.value.apply(&state);
    try std.testing.expectEqualDeep(joined, try journey.Snapshot.capture(state));
    try std.testing.expectError(error.RecruitmentUnavailable, state.recruitMaas());
}

test "Maas source-gated conversation supports decline service cancel and one persistent join" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    const room = state.package.roomIndex("vb6_blacksmith").?;
    state.field_state.room = room;
    state.field_state.x = 184;
    state.field_state.y = 112;
    state.field_state.destination = .{ .x = 184, .y = 112 };
    state.field_state.facing = .up;
    // This is an explicit source checkpoint, not a new-game unlock.
    state.combat.progress.story.recruitment_tier = 1;
    state.combat.progress.story.castle_name = .{ 'T', 'o', 'r', 'a', 'n', 0, 0, 0 };
    const before = try journey.Snapshot.capture(state);
    confirm(&state);
    try std.testing.expectEqualStrings("maas", state.package.rooms[room].npcs[state.field_state.dialogue.?.source.npc].id);
    for (0..4) |_| confirm(&state);
    try equal(.recruitment_choices, state.field_state.dialogue.?.phase);
    _ = state.tick(.{ .field = .{ .menu_direction = .down } }, .{});
    confirm(&state);
    try equal(.recruitment_declined, state.field_state.dialogue.?.phase);
    confirm(&state);
    try equal(.service, state.field_state.dialogue.?.phase);
    _ = state.tick(.{}, .{});
    try equal(.blacksmith, state.menu.phase);
    _ = state.tick(.{ .field = .{ .cancel = true } }, .{});
    try expect(!state.combat.progress.story.maas_recruited);
    try std.testing.expectEqualDeep(before.random, state.combat.random);
    try before.apply(&state);
    confirm(&state);
    for (0..4) |_| confirm(&state);
    confirm(&state);
    try equal(.recruitment_accepted, state.field_state.dialogue.?.phase);
    try std.testing.expectError(error.GameBusy, journey.Snapshot.capture(state));
    _ = state.tick(.{ .field = .{ .cancel = true } }, .{});
    try expect(state.reserves[0] == null);
    try std.testing.expectEqualDeep(before.random, state.combat.random);
    confirm(&state);
    for (0..4) |_| confirm(&state);
    confirm(&state);
    confirm(&state);
    try equal(.recruitment_joined, state.field_state.dialogue.?.phase);
    try expect(state.reserves[0] == null);
    confirm(&state);
    try expect(state.field_state.dialogue == null);
    try equal(.closed, state.menu.phase);
    try expect(state.combat.progress.story.maas_recruited);
    try equal(@as(u8, 18), state.reserves[0].?.level);
    try equal(@as(i32, 184), state.field_state.x);
    try equal(@as(i32, 112), state.field_state.y);
    try expect(!state.package.rooms[room].npcs[0].visible(state.combat.progress.story));
    const saved = try journey.Snapshot.capture(state);
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try journey.save(std.testing.io, allocator, directory.dir, state);
    try before.apply(&state);
    try journey.restore(std.testing.io, allocator, directory.dir, &state);
    try std.testing.expectEqualDeep(saved, try journey.Snapshot.capture(state));
    try expect(!state.package.rooms[room].npcs[0].visible(state.combat.progress.story));
    confirm(&state);
    try std.testing.expectEqualStrings("forest_blacksmith", state.package.rooms[room].npcs[state.field_state.dialogue.?.source.npc].id);
    try std.testing.expectEqualDeep(saved.reserves, state.reserves);
    try std.testing.expectEqualDeep(saved.random, state.combat.random);
}

test "journey optional-game records round trip and migrate absent legacy fields" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    try expect((try journey.Snapshot.capture(state)).optional_games == null);
    const records: @TypeOf(state.optional_games) = .{ .cup_profit = -420, .card_records = .{ 160, 0, 800, 20 } };
    state.optional_games = records;

    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try journey.save(std.testing.io, allocator, directory.dir, state);
    state.optional_games = .{};
    try journey.restore(std.testing.io, allocator, directory.dir, &state);
    try std.testing.expectEqualDeep(records, state.optional_games);

    var legacy = try journey.Snapshot.capture(state);
    legacy.schema = "suikoden-journey-save/42";
    try std.testing.expectError(error.InvalidSave, legacy.apply(&state));
    try std.testing.expectEqualDeep(records, state.optional_games);
    legacy.optional_games = null;
    try legacy.apply(&state);
    try std.testing.expectEqualDeep(@as(@TypeOf(state.optional_games), .{}), state.optional_games);
}

test "version5 saves without recruitment fields migrate locked and reject invalid tier or castle names" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    const before = try journey.Snapshot.capture(state);
    var legacy = before;
    legacy.schema = "suikoden-journey-save/5";
    legacy.auxiliary_party = null;
    const bytes = try std.json.Stringify.valueAlloc(allocator, legacy, .{});
    defer allocator.free(bytes);
    const document = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer document.deinit();
    const story = &document.value.object.getPtr("story").?.object;
    for ([_][]const u8{ "recruitment_tier", "maas_recruited", "maas_recruitment_blocked", "castle_name" }) |key| _ = story.swapRemove(key);
    const old_bytes = try std.json.Stringify.valueAlloc(allocator, document.value, .{});
    defer allocator.free(old_bytes);
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(std.testing.io, .{ .sub_path = journey.filename, .data = old_bytes });
    try journey.restore(std.testing.io, allocator, directory.dir, &state);
    var migrated = before;
    migrated.auxiliary_party = null;
    try std.testing.expectEqualDeep(migrated, try journey.Snapshot.capture(state));
    try expect(!state.canRecruitMaas());
    document.value.object.getPtr("schema").?.* = .{ .string = "suikoden-journey-save/17" };
    const missing = try std.json.Stringify.valueAlloc(allocator, document.value, .{});
    defer allocator.free(missing);
    try directory.dir.writeFile(std.testing.io, .{ .sub_path = journey.filename, .data = missing });
    try std.testing.expectError(error.MissingRecruitmentState, journey.restore(std.testing.io, allocator, directory.dir, &state));
    var invalid = before;
    invalid.story.recruitment_tier = 5;
    try std.testing.expectError(error.InvalidRecruitmentTier, invalid.apply(&state));
    invalid = before;
    invalid.story.castle_name = .{ 'A', 0, 'B', 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.InvalidCastleName, invalid.apply(&state));
    try std.testing.expectEqualDeep(migrated, try journey.Snapshot.capture(state));
}

test "authored episode initialization is explicit and repeatable without canonical-start claims" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    const baseline = try journey.Snapshot.capture(state);
    try equal(@as(u32, 1200), baseline.money);
    try equal(@as(u32, 900), baseline.experience[0]);
    try equal(@as(u8, 5), baseline.levels[0]);
    try std.testing.expectEqualStrings("vb6_inn", baseline.room);
    state.combat.progress.money = 0;
    state.combat.progress.story.complete(.forest_entered);
    members[0].inventory = .{};
    state.elapsed_ticks = 999;
    state = try fixtures.session(&members);
    try std.testing.expectEqualDeep(baseline, try journey.Snapshot.capture(state));
    var wrong = fixtures.content.value;
    wrong.initial_party = &.{ "maas", "gremio", "pahn", "viktor", "yam_koo", "tai_ho" };
    try std.testing.expectError(error.InvalidEpisodeParty, journey.State.initEpisode(fixtures.package.value, fixtures.data.value, wrong, fixtures.items.value, fixtures.inn.value, &members, try fixtures.combat_storage.allocator().create(battle.State)));
}

test "party metadata and save validation follow identity across all catalogue permutations" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    const saved = try journey.Snapshot.capture(state);
    var profiles: [7]battle.Profile = undefined;
    const original = fixtures.content.value.party;
    state.combat.content.party = &profiles;
    var stats: [6]battle.Stats = undefined;
    // Establish expectations before changing the catalogue order.
    state.combat.content.party = original;
    for (&stats, 0..) |*value, i| value.* = state.combat.stats(i);
    state.combat.content.party = &profiles;
    for (0..5040) |permutation| {
        var remaining = [_]usize{ 0, 1, 2, 3, 4, 5, 6 };
        var count: usize = 7;
        var code = permutation;
        for (&profiles) |*profile| {
            const at = code % count;
            code /= count;
            profile.* = original[remaining[at]];
            std.mem.copyForwards(usize, remaining[at .. count - 1], remaining[at + 1 .. count]);
            count -= 1;
        }
        for (0..6) |i| {
            try std.testing.expectEqualDeep(original[i], state.combat.partyProfile(i));
            try std.testing.expectEqualDeep(stats[i], state.combat.stats(i));
            try std.testing.expectEqualDeep(original[i].sprite, battle.layout.actorLayout(state.combat.*, i).sprite);
            try std.testing.expectEqualDeep(original[i].motion, state.combat.actionMotion(i));
            try equal(original[i].weapon_range.?, state.combat.weaponRange(i));
        }
        try equal(@as(?usize, 2), state.combat.unitePartner(1));
        try equal(@as(?usize, 5), state.combat.unitePartner(4));
        try saved.validate(state);
    }
    try expect(state.combat.content.partyProfile("unknown") == null);
    var restarted_members: [6]battle.Member = undefined;
    const restarted = try battle.State.init(state.combat.content, state.combat.rules, &restarted_members, battle.trial_seed);
    for (restarted.progress.party, 0..) |member, i| try std.testing.expectEqualStrings(original[i].id, member.id);
    var bad = state.combat.content;
    bad.initial_party = null;
    try std.testing.expectError(error.InvalidBattleContent, bad.validate());
    bad.initial_party = &.{ "hero", "hero", "pahn", "viktor", "yam_koo", "tai_ho" };
    try std.testing.expectError(error.DuplicateFighter, bad.validate());
    bad.initial_party = &.{ "hero", "unknown", "pahn", "viktor", "yam_koo", "tai_ho" };
    try std.testing.expectError(error.UnknownPartyMember, bad.validate());
}

test "journey saves restore reordered members and owned preparation atomically by identity" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    for (&members, 0..) |*member, i| member.hp = @intCast(30 + i);
    state.combat.weapon_levels[3] = 2;
    const original = try journey.Snapshot.capture(state);
    var saved = original;
    const order = [_]usize{ 3, 2, 0, 5, 1, 4 };
    for (order, 0..) |old, i| {
        saved.party[i] = original.party[old];
        saved.levels[i] = original.levels[old];
        saved.experience[i] = original.experience[old];
        saved.stats[i] = original.stats[old];
        saved.weapon_levels.?[i] = original.weapon_levels.?[old];
        saved.equipment[i] = original.equipment[old];
        saved.loadouts.?[i] = original.loadouts.?[old];
        saved.runes[i] = original.runes[old];
    }
    const bytes = try std.json.Stringify.valueAlloc(allocator, saved, .{});
    defer allocator.free(bytes);
    {
        const parsed = try std.json.parseFromSlice(journey.Snapshot, allocator, bytes, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        try parsed.value.apply(&state);
    }
    for (order, 0..) |old, i| {
        try std.testing.expectEqualDeep(original.party[old], members[i]);
        try std.testing.expectEqualStrings(original.party[old].id, state.combat.partyProfile(i).id);
        try equal(state.combat.partyProfile(i).id.ptr, members[i].id.ptr);
        try equal(state.combat.partyProfile(i).name.ptr, members[i].name.ptr);
    }
    try std.testing.expectEqualDeep(saved, try journey.Snapshot.capture(state));
    try equal(@as(?usize, 1), state.combat.unitePartner(4));
    try equal(@as(u8, 2), state.combat.weapon_levels[0]);
    try std.testing.expectError(error.RuneLocked, state.combat.detachRune(1));
    var bad = saved;
    bad.party[0].id = "unknown";
    try std.testing.expectError(error.InvalidMember, bad.apply(&state));
    try std.testing.expectEqualDeep(saved, try journey.Snapshot.capture(state));
    bad = saved;
    bad.party[0].id = saved.party[1].id;
    try std.testing.expectError(error.DuplicateMember, bad.apply(&state));
    try std.testing.expectEqualDeep(saved, try journey.Snapshot.capture(state));

    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try journey.saveSlot(std.testing.io, allocator, directory.dir, state, 0, state.save_name);
    var summaries = journey.summaries(std.testing.io, allocator, directory.dir, state);
    try std.testing.expectEqualStrings("Viktor", summaries[0].leader);
    var profiles: [7]battle.Profile = undefined;
    @memcpy(&profiles, fixtures.content.value.party);
    std.mem.reverse(battle.Profile, &profiles);
    state.combat.content.party = &profiles;
    try journey.restore(std.testing.io, allocator, directory.dir, &state);
    try std.testing.expectEqualDeep(saved, try journey.Snapshot.capture(state));
    summaries = journey.summaries(std.testing.io, allocator, directory.dir, state);
    try std.testing.expectEqualStrings("Viktor", summaries[0].leader);
}

test "Pahn starts his duel with his reserve HP and equipment stats" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    defer state.deinitActiveModes();

    const maas = state.combat.content.partyProfile("maas").?;
    var reserve = state.combat.ownedMember(0);
    reserve.member.id = maas.id;
    reserve.member.name = maas.name;
    try state.retainReserve(reserve);

    const pahn = for (state.combat.progress.party, 0..) |member, index| {
        if (std.mem.eql(u8, member.id, "pahn")) break index;
    } else return error.MissingTestMember;
    const before = state.combat.stats(pahn);
    members[pahn].hp = 29;
    state.combat.weapon_levels[pahn] = 8;
    state.extras[pahn] = .{ .member_id = "pahn", .weapon_element = .wind, .weapon_fragments = .{ 0, 0, 3, 0, 0 } };
    state.combat.weapon_augments[pahn] = party_session.weaponAugment(state.extras[pahn]);
    const expected = state.combat.stats(pahn);
    try expect(expected.attack > before.attack);
    try equal(before.defense + 9, expected.defense);
    const expected_hp = members[pahn].max_hp;
    try state.swapReserve("pahn", "maas");

    try state.startDuelById(allocator, "pahn_teo");
    const fighter = state.active_duel.?.state.fighters[0];
    try equal(@as(i32, 29), fighter.hp);
    try equal(@as(i32, expected_hp), fighter.maximum_hp);
    try equal(@as(i32, expected.attack), fighter.attack);
    try equal(@as(i32, expected.defense), fighter.defense);
    try std.testing.expectEqualStrings("maas", members[pahn].id);
}

test "reserve swaps preserve every owned field, formation and inactive progression" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    try equal(@as(usize, 7), state.combat.content.party.len);
    try equal(@as(usize, 6), state.combat.partyCount());
    for (state.reserves) |entry| try expect(entry == null);
    const profile = state.combat.content.partyProfile("maas").?;
    var owned = state.combat.ownedMember(0);
    owned.member.id = profile.id;
    owned.member.name = profile.name;
    owned.member.hp = 55;
    owned.member.max_hp = 333;
    owned.member.status = .poisoned;
    owned.member.balloons = 2;
    owned.level = 13;
    owned.experience = 777;
    owned.weapon_level = 9;
    owned.stats.skill = 81;
    owned.member.inventory.slots[0].?.uses = 3;
    owned.member.inventory.slots[3] = .{ .id = .octopus_urn, .uses = 0, .identified = false };
    owned.member.rune_charges[0] -= 1;
    try state.retainReserve(owned);
    const baseline = try journey.Snapshot.capture(state);
    for (0..6) |i| {
        const before = state.combat.ownedMember(i);
        const id = members[i].id;
        try state.swapReserve(id, "maas");
        try std.testing.expectEqualDeep(owned, state.combat.ownedMember(i));
        try std.testing.expectEqualDeep(before, state.reserves[0].?);
        try std.testing.expectEqualDeep(baseline.formation, state.combat.formation);
        try std.testing.expectEqualStrings("Maas", state.field_state.progress.party[i].name);
        try (try journey.Snapshot.capture(state)).validate(state);
        try state.swapReserve("maas", id);
        try std.testing.expectEqualDeep(baseline, try journey.Snapshot.capture(state));
    }
    try state.beginEncounter(0);
    state.combat.phase = .victory;
    state.combat.enemy_hp = @splat(0);
    state.combat.tick(.{ .confirm = true });
    try std.testing.expectEqualDeep(owned, state.reserves[0].?);
}

test "reserve failures and malformed snapshots are atomic and old saves clear absent reserves" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    const old = try journey.Snapshot.capture(state);
    var owned = state.combat.ownedMember(0);
    const profile = state.combat.content.partyProfile("maas").?;
    owned.member.id = profile.id;
    owned.member.name = profile.name;
    try state.retainReserve(owned);
    const before = try journey.Snapshot.capture(state);
    try std.testing.expectError(error.DuplicateMember, state.retainReserve(owned));
    try std.testing.expectError(error.UnknownReserve, state.swapReserve("hero", "unknown"));
    try std.testing.expectError(error.InvalidMember, state.swapReserve("unknown", "maas"));
    state.menu.phase = .strength;
    try std.testing.expectError(error.GameBusy, state.swapReserve("hero", "maas"));
    state.menu.phase = .closed;
    state.field_state.remaining = 1;
    try std.testing.expectError(error.GameBusy, state.swapReserve("hero", "maas"));
    state.field_state.remaining = 0;
    try std.testing.expectEqualDeep(before, try journey.Snapshot.capture(state));
    var bad = before;
    bad.reserves = null;
    try std.testing.expectError(error.MissingReserves, bad.apply(&state));
    bad = before;
    bad.reserves.?[0].?.member.id = "unknown";
    try std.testing.expectError(error.InvalidMember, bad.apply(&state));
    bad = before;
    bad.reserves.?[0] = state.combat.ownedMember(0);
    try std.testing.expectError(error.DuplicateMember, bad.apply(&state));
    bad = before;
    bad.reserves.?[1] = owned;
    try std.testing.expectError(error.DuplicateMember, bad.apply(&state));
    bad = before;
    bad.reserves.?[0] = null;
    bad.reserves.?[1] = owned;
    try std.testing.expectError(error.InvalidReserves, bad.apply(&state));
    bad = before;
    bad.reserves.?[0].?.weapon_level = 0;
    try std.testing.expectError(error.InvalidWeapon, bad.apply(&state));
    bad = before;
    bad.reserves.?[0].?.rune = 999;
    try std.testing.expectError(error.InvalidRune, bad.apply(&state));
    bad = before;
    bad.reserves.?[0].?.loadout.body = 999;
    try std.testing.expectError(error.InvalidEquipment, bad.apply(&state));
    bad = before;
    bad.reserves.?[0].?.member.inventory.slots[2] = null;
    try std.testing.expectError(error.InvalidEquipment, bad.apply(&state));
    bad = before;
    bad.reserves.?[0].?.member.max_rune_charges[0] += 1;
    try std.testing.expectError(error.InvalidMagicCapacity, bad.apply(&state));
    try std.testing.expectEqualDeep(before, try journey.Snapshot.capture(state));
    for ([_][]const u8{ "suikoden-journey-save/1", "suikoden-journey-save/2", "suikoden-journey-save/3", "suikoden-journey-save/4" }) |version| {
        var legacy = old;
        legacy.schema = version;
        legacy.auxiliary_party = null;
        legacy.reserves = null;
        const bytes = try std.json.Stringify.valueAlloc(allocator, legacy, .{ .emit_null_optional_fields = false });
        defer allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(journey.Snapshot, allocator, bytes, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        try parsed.value.apply(&state);
        for (state.reserves) |entry| try expect(entry == null);
        try state.retainReserve(owned);
    }
}

test "reserve save storage rebinds both sides after parsed memory is released" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    var owned = state.combat.ownedMember(0);
    const profile = state.combat.content.partyProfile("maas").?;
    owned.member.id = profile.id;
    owned.member.name = profile.name;
    try state.retainReserve(owned);
    try state.swapReserve("hero", "maas");
    const expected = try journey.Snapshot.capture(state);
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try journey.save(std.testing.io, allocator, directory.dir, state);
    try state.swapReserve("maas", "hero");
    const profiles = try allocator.dupe(battle.Profile, state.combat.content.party);
    defer allocator.free(profiles);
    std.mem.reverse(battle.Profile, profiles);
    state.combat.content.party = profiles;
    try journey.restore(std.testing.io, allocator, directory.dir, &state);
    try std.testing.expectEqualDeep(expected, try journey.Snapshot.capture(state));
    for (state.reserves) |entry| if (entry) |record| {
        const owner = state.combat.content.partyProfile(record.member.id).?;
        try equal(owner.id.ptr, record.member.id.ptr);
        try equal(owner.name.ptr, record.member.name.ptr);
    };
    try state.swapReserve("maas", "hero");
    try std.testing.expectEqualDeep(owned, state.reserves[0].?);
}

test "BonBon uses exported jump contact and return phases with one physical impact" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    const state = try fixtures.session(&members);
    const combat = state.combat;
    combat.phase = .resolving;
    const actor = combat.partyCount();
    const motion = combat.enemy(0).motion.?;
    try equal(@as(u16, 12), motion.approach.ticks);
    try equal(@as(u16, 30), motion.retreat.ticks);
    const home = battle.layout.homePosition(combat, actor);
    const contact = battle.presentation.offset(battle.layout.homePosition(combat, 0), motion.approach.offset);
    combat.active = .{ .actor = actor, .target = 0, .kind = .attack, .amount = 1 };
    try equal(@as(u16, 12), combat.impactTick());
    try equal(@as(u16, 43), combat.actionDuration());
    try std.testing.expectEqualDeep(home, battle.layout.worldPosition(combat, actor));
    const hp = members[0].hp;
    const framing = battle.layout.framing(combat.*);
    for (1..44) |tick| {
        combat.tick(.{});
        try equal(hp - @as(u16, if (tick >= 12) 1 else 0), members[0].hp);
        if (tick < 43) {
            const expected = if (tick <= 13) battle.presentation.leap(home, contact, motion.approach, @intCast(tick)) else battle.presentation.leap(contact, home, motion.retreat, @intCast(tick - 13));
            try std.testing.expectEqualDeep(expected, battle.layout.worldPosition(combat, actor));
            try std.testing.expectEqualDeep(framing, battle.layout.framing(combat.*));
        }
    }
    try expect(combat.active == null);
    try std.testing.expectEqualDeep(home, battle.layout.worldPosition(combat, actor));
    var bad = fixtures.content.value;
    const profiles = try allocator.dupe(battle.Profile, bad.enemies);
    defer allocator.free(profiles);
    bad.enemies = profiles;
    profiles[0].motion.?.duration += 1;
    try std.testing.expectError(error.InvalidBattleAssets, bad.validate());
    profiles[0].motion.?.duration -= 1;
    profiles[0].motion.?.approach.acceleration_step = -0.01;
    try std.testing.expectError(error.InvalidBattleAssets, bad.validate());
    profiles[0].motion.?.approach.acceleration_step = std.math.floatTrueMin(f32);
    try std.testing.expectError(error.InvalidBattleAssets, bad.validate());
}

test "Spark ordinary attack drains remaining allies in party order after priority rolls" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    const state = try fixtures.session(&members);
    const combat = state.combat;
    combat.runes[0] = combat.content.systems.?.runeIndex("spark").?;
    try std.testing.expectEqualStrings("Passive: allies follow an ordinary attack.", combat.runeHint(0));
    combat.phase = .resolving;
    combat.enemy_hp = @splat(1000);
    combat.actions = @splat(.defend);
    combat.actions[0] = .{ .attack = 0 };
    combat.acted = @splat(true);
    combat.acted[0] = false;
    const charges = members[0].rune_charges;
    combat.tick(.{});
    try expect(combat.spark_pending);
    while (combat.active != null) combat.tick(.{});
    // Make every enemy faster than every ally; Spark still selects party identity order.
    var enemies: [4]battle.Profile = undefined;
    @memcpy(&enemies, combat.content.enemies);
    for (&enemies) |*enemy| enemy.stats.speed = 9999;
    combat.content.enemies = &enemies;
    for (combat.base_stats[0..6]) |*stats| stats.speed = 1;
    for (combat.acted[1 .. 6 + combat.enemyCount()]) |*acted| acted.* = false;
    for (1..6) |wanted| {
        var expected = combat.random;
        for (0..6 - wanted + combat.enemyCount()) |_| _ = expected.random().int(u15);
        combat.tick(.{});
        try equal(wanted, combat.active.?.actor);
        try equal(.defend, combat.active.?.kind);
        try std.testing.expectEqualDeep(expected, combat.random);
        while (combat.active != null) combat.tick(.{});
    }
    combat.tick(.{});
    try expect(combat.active.?.actor >= 6);
    try expect(!combat.spark_pending);
    try std.testing.expectEqualDeep(charges, members[0].rune_charges);

    combat.active = null;
    combat.spark_pending = true;
    combat.acted = @splat(false);
    combat.acted[0] = true;
    members[1].hp = 0;
    combat.departed[2] = true;
    combat.actor_conditions[3].sleep_turns = 1;
    combat.actions[4] = .{ .assist = 0 };
    combat.tick(.{});
    try equal(@as(usize, 5), combat.active.?.actor);
    combat.clearTemporaryStats();
    try expect(!combat.spark_pending);

    combat.active = null;
    combat.acted = @splat(true);
    combat.acted[0] = false;
    combat.actions[0] = .defend;
    combat.tick(.{});
    try expect(!combat.spark_pending);
    combat.active = null;
    combat.acted[3] = false;
    combat.actor_conditions[3].sleep_turns = 0;
    combat.runes[3] = combat.runes[0];
    combat.actions[3] = .{ .attack = 0 };
    combat.tick(.{});
    try equal(.unavailable, combat.active.?.kind);
    try expect(!combat.spark_pending);
}

test "Double-beat preserves native target scan, latch, impact and continuous follow-up motion" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    const vectors = try std.json.parseFromSlice([]const struct { usize, u6, usize, ?usize }, allocator, @embedFile("fixtures/double_beat_targets.json"), .{});
    defer vectors.deinit();
    var members: [6]battle.Member = undefined;
    const state = try fixtures.session(&members);
    const combat = state.combat;
    combat.runes[0] = combat.content.systems.?.runeIndex("double-beat").?;
    const encounters = try allocator.dupe(battle.Encounter, combat.content.encounters);
    defer allocator.free(encounters);
    combat.content.encounters = encounters;
    combat.encounter = 0;
    const ids: [6][]const u8 = @splat("bonbon");
    const rows: [6]battle.Row = @splat(.front);
    for (vectors.value) |row| {
        const count, const dead, const current, const wanted = row;
        encounters[0].enemies = ids[0..count];
        encounters[0].positions = combat.content.formation_slots[0..count];
        encounters[0].enemy_rows = rows[0..count];
        combat.double_beat_pending[0] = true;
        for (0..count) |i| combat.enemy_hp[i] = if (dead & (@as(u6, 1) << @intCast(i)) != 0) 0 else 1000;
        try equal(wanted, combat.nextDoubleBeatTarget(0, current));
    }
    encounters[0].enemies = ids[0..3];
    encounters[0].positions = combat.content.formation_slots[0..3];
    encounters[0].enemy_rows = rows[0..3];
    combat.enemy_hp = @splat(1000);
    combat.double_beat_pending = @splat(false);
    combat.phase = .resolving;
    combat.actions[0] = .{ .attack = 0 };
    combat.acted = @splat(true);
    combat.acted[0] = false;
    const charges = members[0].rune_charges;
    combat.tick(.{});
    try expect(combat.double_beat_pending[0]);
    const first = combat.active.?;
    const ready = combat.content.party[0].motion.?.ready_tick.?;
    try equal(ready, combat.actionDuration());
    while (combat.action_ticks < combat.impactTick() - 1) combat.tick(.{});
    try equal(@as(u16, 1000), combat.enemy_hp[0]);
    combat.tick(.{});
    try equal(@as(u16, 1000) - @as(u16, @intCast(first.amount)), combat.enemy_hp[0]);
    while (combat.action_ticks < ready - 1) combat.tick(.{});
    const contact = battle.layout.worldPosition(combat, 0);
    combat.tick(.{});
    const second = combat.active.?;
    try equal(@as(?usize, combat.partyCount()), second.followup_from);
    try equal(combat.partyCount() + 1, second.target);
    try equal(@as(u16, 0), combat.action_ticks);
    try std.testing.expectEqualDeep(contact, battle.layout.worldPosition(combat, 0));
    try expect(!combat.double_beat_pending[0]);
    const frame = battle.layout.framing(combat.*);
    try expect(frame.zoom > 0 and frame.zoom <= 1);
    while (combat.action_ticks < combat.impactTick()) combat.tick(.{});
    const hp = @as(u16, 1000) - @as(u16, @intCast(second.amount));
    try equal(hp, combat.enemy_hp[1]);
    combat.tick(.{});
    try equal(hp, combat.enemy_hp[1]);
    while (combat.active != null) combat.tick(.{});
    try std.testing.expectEqualDeep(combat.content.party_positions[0], battle.layout.homePosition(combat, 0));
    try std.testing.expectEqualDeep(charges, members[0].rune_charges);
    // The stop-before-wrap case retains the latch; the following turn clears it.
    combat.enemy_hp = .{ 0, 1000, 0, 0, 0, 0 };
    combat.actions[0] = .{ .attack = 1 };
    combat.acted[0] = false;
    combat.tick(.{});
    try expect(combat.double_beat_pending[0]);
    try equal(combat.content.party[0].motion.?.duration, combat.actionDuration());
    while (combat.active != null) combat.tick(.{});
    combat.acted[0] = false;
    combat.tick(.{});
    try expect(!combat.double_beat_pending[0]);
    try equal(@as(?usize, null), combat.active.?.followup_from);
    combat.clearTemporaryStats();
    for (combat.double_beat_pending) |pending| try expect(!pending);
    var bad = fixtures.content.value;
    const profiles = try allocator.dupe(battle.Profile, bad.party);
    defer allocator.free(profiles);
    bad.party = profiles;
    var motion = profiles[0].motion.?;
    motion.ready_tick = null;
    profiles[0].motion = motion;
    try std.testing.expectError(error.MissingAttackReady, bad.validate());
    motion.ready_tick = motion.impact_tick - 1;
    profiles[0].motion = motion;
    try std.testing.expectError(error.InvalidBattleAssets, bad.validate());
}

test "ordinary attacks consume hit then eligible party critical then impact rolls" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var enemies: [4]battle.Profile = undefined;
    @memcpy(&enemies, fixtures.content.value.enemies);
    enemies[0].stats.skill = 20;
    for ([_]bool{ false, true }) |dodges| {
        enemies[0].dodges_attacks = dodges;
        for (0..64) |seed| {
            var members: [6]battle.Member = undefined;
            var state = try fixtures.session(&members);
            state.combat.content.enemies = &enemies;
            try state.beginEncounter(0);
            const combat = state.combat;
            combat.base_stats[0].skill = 20;
            combat.base_stats[0].luck = 20;
            combat.random = .init(seed);
            combat.phase = .resolving;
            combat.actions[0] = .{ .attack = 0 };
            combat.acted = @splat(true);
            combat.acted[0] = false;
            var expected = combat.random;
            _ = expected.random().int(u15); // Sole eligible actor's priority.
            const hit = expected.random().int(u15) % 100 < 80 or !dodges;
            const critical = hit and expected.random().int(u15) % 100 < 5;
            if (hit) _ = expected.random().int(u15); // Physical impact amount.
            combat.tick(.{});
            if (hit) try equal(.attack, combat.active.?.kind) else try equal(.miss, combat.active.?.kind);
            try equal(critical, combat.active.?.critical);
            try std.testing.expectEqualDeep(expected, combat.random);
        }
    }
}

test "Crow can target surviving rear members and Ant special hits once with source roll boundaries" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    const vectors = try std.json.parseFromSlice([]const struct { u15, bool }, allocator, @embedFile("fixtures/ant_special.json"), .{});
    defer vectors.deinit();
    for (vectors.value) |row| try equal(row[1], battle.antSpecial(row[0]));
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    try state.beginEncounter(1);
    try std.testing.expectEqualStrings("crow", state.combat.enemy(0).id);
    for (members[0..3]) |*member| {
        member.hp = 0;
        member.status = .unconscious;
    }
    for (0..32) |_| {
        const target = state.combat.chooseEnemyTarget(0).?;
        try expect(target >= 3);
        try equal(.back, state.combat.partyRow(target));
    }
    var special_count: usize = 0;
    var normal_count: usize = 0;
    for (0..64) |_| {
        state.combat.restart();
        state.mode = .field;
        try state.beginEncounter(2);
        const combat = state.combat;
        // Advance the retained generator so both branches execute across trials.
        for (0..special_count + normal_count) |_| _ = combat.random.random().int(u15);
        try std.testing.expectEqualStrings("red_soldier_ant", combat.enemy(0).id);
        combat.phase = .resolving;
        combat.actions = @splat(.defend);
        combat.acted = @splat(true);
        combat.acted[combat.partyCount()] = false;
        combat.tick(.{});
        const effect = combat.active.?;
        if (effect.enemy_special) {
            special_count += 1;
            try expect(!effect.critical);
            try equal(.attack, effect.kind);
            const before = members[effect.target].hp;
            while (combat.action_ticks < combat.impactTick()) combat.tick(.{});
            const after = before -| @as(u16, @intCast(effect.amount));
            try equal(after, members[effect.target].hp);
            combat.tick(.{});
            try equal(after, members[effect.target].hp);
        } else normal_count += 1;
    }
    try expect(special_count > 0 and normal_count > 0);
}

test "three balloons depart at the boundary, retain HP, skip actions and EXP, and allow group revival" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    try state.beginEncounter(0);
    const combat = state.combat;
    const hp = members[0].hp;
    members[0].status = .poisoned;
    for (0..3) |_| try expect(combat.inflictStatus(0, .balloon));
    try expect(combat.participates(0));
    combat.phase = .resolving;
    combat.acted = @splat(true);
    combat.tick(.{});
    try expect(combat.departed[0]);
    try expect(!combat.participates(0));
    try equal(hp, members[0].hp);
    try equal(.poisoned, members[0].status);
    try equal(@as(u32, 0), combat.experienceAward(0));
    try equal(@as(u8, 3), members[0].balloons);
    try expect(!combat.canAttackTarget(0, 0));
    try expect(!combat.canPhysicalRune(0));
    try equal(.back, combat.partyRow(0));
    try equal(.front, combat.partyRow(3));
    try expect(combat.actor != 0);
    for (0..10) |_| try expect(combat.chooseEnemyTarget(0).? != 0);
    const drops = spellIndex(combat.*, "spell_9");
    const mother = spellIndex(combat.*, "spell_30");
    try expect(!combat.spellValid(combat.content.systems.?.spells[drops], 0));
    try expect(combat.spellValid(combat.content.systems.?.spells[mother], 0));
    combat.runes[1] = combat.content.systems.?.runeIndex("flowing");
    combat.refillMagic(1);
    try combat.castFieldSpell(1, mother, 0);
    try expect(combat.participates(0));
    try expect(!combat.departed[0]);
    try equal(@as(u8, 0), members[0].balloons);
    try equal(.healthy, members[0].status);
    try equal(members[0].max_hp, members[0].hp);
    const hat = combat.gearIndex(.pointed_hat).?;
    try combat.equip(0, hat);
    try expect(!combat.inflictStatus(0, .balloon));
    try combat.equip(0, null);
    members[0].inventory.slots[2] = .{ .id = .pointed_hat, .uses = 0 };
    try expect(combat.inflictStatus(0, .balloon));

    // One or two balloons do not depart; Needle can prevent the pending third.
    for (1..4) |count| {
        combat.departed = @splat(false);
        members[0].balloons = @intCast(count);
        if (count == 3) {
            members[1].inventory.slots[0] = .{ .id = .needle, .uses = 4 };
            try combat.progress.useItem(combat.rules, 1, 0, 0);
        }
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.tick(.{});
        try expect(combat.participates(0));
    }
    for (&members) |*member| member.balloons = 3;
    combat.phase = .resolving;
    combat.acted = @splat(true);
    combat.tick(.{});
    try equal(.defeat, combat.phase);
    for (members) |member| try expect(member.hp > 0);
    combat.clearTemporaryStats();
    for (combat.departed) |departed| try expect(!departed);
}

test "two hundred scene battle menu and save cycles preserve owned state and clean parsed data" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    const baseline = try journey.Snapshot.capture(state);
    var directory = std.testing.tmpDir(.{ .iterate = true });
    defer directory.cleanup();
    for (0..200) |iteration| {
        try baseline.apply(&state);
        state.bind();
        state.menu.phase = .root;
        state.menu.selected = .setup;
        confirm(&state);
        try equal(.setup, state.menu.phase);
        _ = state.tick(.{ .field = .{ .cancel = true } }, .{});
        _ = state.tick(.{ .field = .{ .cancel = true } }, .{});
        try equal(.closed, state.menu.phase);
        try state.beginEncounter(iteration % state.data.encounters.len);
        if (iteration % 2 == 0) {
            try finishBattle(&state);
        } else {
            for (&members) |*member| member.hp = 0;
            state.combat.phase = .defeat;
            _ = state.tick(.{}, .{});
            try equal(.defeat, state.mode);
            confirm(&state);
            try equal(.battle, state.mode);
            for (members) |member| try expect(member.hp > 0);
            try finishBattle(&state);
        }
        const saved = try journey.Snapshot.capture(state);
        const slot = iteration % pause.save_slots.count;
        try journey.saveSlot(std.testing.io, allocator, directory.dir, state, slot, pause.save_slots.defaultLabel(slot));
        try baseline.apply(&state);
        _ = try journey.restoreSlotWithSource(std.testing.io, allocator, directory.dir, &state, slot);
        try equal(saved.money, state.combat.progress.money);
        try std.testing.expectEqualDeep(saved.party, members);
        try equal(@as(?battle.Effect, null), state.combat.active);
        try equal(.field, state.mode);
        try state.combat.progress.validate();
    }
}

test "storage caps each named item, restores full supplies and never loses items on failed transfers" {
    const Storage = field.game_state.storage.Storage;
    for (std.enums.values(field.items.Id)) |id| {
        var store = Storage{};
        var inventory = field.items.Inventory{};
        inventory.slots[0] = .{ .id = id, .uses = @min(1, id.maxUses()) };
        try store.deposit(&inventory, 0);
        try equal(@as(u16, 1), store.quantity(id));
        try equal(@as(?field.items.Id, id), store.itemAt(0));
        try store.withdraw(&inventory, id);
        try equal(id.maxUses(), inventory.slots[0].?.uses);
        try equal(@as(usize, 0), store.count());
    }
    var store = Storage{};
    store.counts.medicine = 254;
    var inventory = field.items.Inventory{};
    inventory.slots[0] = .{ .id = .medicine, .uses = 2 };
    const before = inventory;
    try std.testing.expectError(error.StorageFull, store.deposit(&inventory, 0));
    try std.testing.expectEqualDeep(before, inventory);
    inventory.slots = @splat(.{ .id = .medicine, .uses = 1 });
    try std.testing.expectError(error.InventoryFull, store.withdraw(&inventory, .medicine));
    try equal(@as(u16, 254), store.quantity(.medicine));
    store.counts.medicine = 255;
    try std.testing.expectError(error.InvalidStorage, store.validate());
}

test "pause storage confirmations, worn protection and version4 saves preserve ownership" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    defer state.releaseRestoredSave();
    state.menu.phase = .root;
    state.menu.selected = .storage;
    confirm(&state);
    try equal(.storage, state.menu.phase);
    confirm(&state);
    try equal(.storage_items, state.menu.phase);
    members[0].inventory.slots[0].?.uses = 2;
    const before = try journey.Snapshot.capture(state);
    confirm(&state);
    try equal(.confirm_storage, state.menu.phase);
    try expect(!state.menu.yes);
    confirm(&state);
    try std.testing.expectEqualDeep(before, try journey.Snapshot.capture(state));
    confirm(&state);
    _ = state.tick(.{ .field = .{ .menu_direction = .up } }, .{});
    confirm(&state);
    try equal(.storage_notice, state.menu.phase);
    try equal(@as(u16, 1), state.combat.progress.storage.quantity(.medicine));
    confirm(&state);
    state.menu.slot = 1;
    confirm(&state);
    _ = state.tick(.{ .field = .{ .menu_direction = .up } }, .{});
    const protected = try journey.Snapshot.capture(state);
    confirm(&state);
    try equal(.storage_notice, state.menu.phase);
    try std.testing.expectEqualDeep(protected, try journey.Snapshot.capture(state));
    state.menu.phase = .storage_items;
    state.menu.storage_withdraw = true;
    state.menu.member = 1;
    state.menu.slot = 0;
    confirm(&state);
    _ = state.tick(.{ .field = .{ .menu_direction = .up } }, .{});
    confirm(&state);
    try equal(@as(u16, 0), state.combat.progress.storage.quantity(.medicine));
    try equal(@as(u16, 6), members[1].inventory.slots[2].?.uses);
    state.combat.progress.storage.counts.clone_crystal = 3;
    state.menu.phase = .closed;
    state.opening_event = "{\"stage\":\"first_town\"}";
    state.route = .{ .stage = .palace, .completed = 2 };
    {
        const original_package = state.package;
        const prop_rooms = try allocator.dupe(field.Room, state.package.rooms);
        defer allocator.free(prop_rooms);
        prop_rooms[state.field_state.room].draws = &.{.{ .rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .x = 0, .y = 0, .depth = 0, .prop = 0 }};
        state.package.schema = field.Package.prop_schema;
        state.package.rooms = prop_rooms;
        state.field_state.shown_props = 1;
        const prop_saved = try journey.Snapshot.capture(state);
        state.field_state.shown_props = 0;
        try prop_saved.apply(&state);
        try std.testing.expectEqual(@as(u64, 1), state.field_state.shown_props);
        var unknown_prop = prop_saved;
        unknown_prop.shown_props = 2;
        try std.testing.expectError(error.InvalidSave, unknown_prop.validate(state));
        state.field_state.shown_props = 0;
        state.package = original_package;
    }
    const saved = try journey.Snapshot.capture(state);
    try std.testing.expectEqual(.palace, saved.route.?.stage);
    try std.testing.expectEqualStrings("suikoden-journey-save/43", saved.schema);
    var older_stream = saved;
    older_stream.schema = "suikoden-journey-save/33";
    older_stream.field_music = .infiltration;
    try std.testing.expectError(error.InvalidSave, older_stream.validate(state));
    var current_wheel = saved;
    current_wheel.field_music = .wheel;
    try current_wheel.validate(state);
    var older_wheel = saved;
    older_wheel.schema = "suikoden-journey-save/36";
    older_wheel.field_music = .wheel;
    try std.testing.expectError(error.InvalidSave, older_wheel.validate(state));
    var older_mansion = saved;
    older_mansion.schema = "suikoden-journey-save/35";
    older_mansion.field_music = .mansion;
    try std.testing.expectError(error.InvalidSave, older_mansion.validate(state));
    var older_prop = saved;
    older_prop.schema = "suikoden-journey-save/34";
    older_prop.shown_props = 1;
    try std.testing.expectError(error.InvalidSave, older_prop.validate(state));
    try std.testing.expectEqualStrings("{\"stage\":\"first_town\"}", saved.opening_event.?);
    state.opening_event = null;
    state.route = .{};
    try saved.apply(&state);
    try std.testing.expectEqualStrings("{\"stage\":\"first_town\"}", state.opening_event.?);
    try std.testing.expectEqual(.palace, state.route.stage);
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try journey.save(std.testing.io, allocator, directory.dir, state);
    state.combat.progress.storage = .{};
    try journey.restore(std.testing.io, allocator, directory.dir, &state);
    try equal(@as(u16, 3), state.combat.progress.storage.quantity(.clone_crystal));
    try std.testing.expectEqualStrings(saved.opening_event.?, state.opening_event.?);
    try journey.save(std.testing.io, allocator, directory.dir, state);
    try journey.restore(std.testing.io, allocator, directory.dir, &state);
    try std.testing.expectEqualStrings(saved.opening_event.?, state.opening_event.?);
    var bad = saved;
    bad.storage.?.counts.clone_crystal = 255;
    try std.testing.expectError(error.InvalidStorage, bad.apply(&state));
    bad = saved;
    bad.storage = null;
    try std.testing.expectError(error.MissingStorage, bad.apply(&state));
    bad.schema = "suikoden-journey-save/3";
    bad.auxiliary_party = null;
    try bad.apply(&state);
    try equal(@as(usize, 0), state.combat.progress.storage.count());
}

test "appraisal keeps urn identities hidden across saves and charges exactly once after confirmation" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    state.combat.loadouts[0] = .{};
    members[0].inventory.slots[2] = .{ .id = .celadon_urn, .uses = 0, .identified = false };
    try std.testing.expectEqualStrings("? pot", members[0].inventory.slots[2].?.name());
    try std.testing.expectError(error.AppraisalRequired, state.combat.depositToStorage(&state.field_state.progress.storage, 0, 2));
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try journey.save(std.testing.io, allocator, directory.dir, state);
    members[0].inventory.slots[2].?.identified = true;
    try journey.restore(std.testing.io, allocator, directory.dir, &state);
    try expect(!members[0].inventory.slots[2].?.identified);
    state.combat.progress.money = 499;
    const unknown = members[0].inventory;
    try std.testing.expectError(error.InsufficientFunds, state.combat.progress.appraise(fixtures.items.value, 0, 2));
    try std.testing.expectEqualDeep(unknown, members[0].inventory);
    try equal(@as(u32, 499), state.combat.progress.money);
    state.combat.progress.money = 1200;
    state.menu.phase = .root;
    state.menu.selected = .appraisal;
    confirm(&state);
    try equal(.appraisal, state.menu.phase);
    state.menu.slot = 2;
    confirm(&state);
    try equal(.confirm_appraisal, state.menu.phase);
    try expect(!state.menu.yes);
    confirm(&state);
    try equal(@as(u32, 1200), state.combat.progress.money);
    try expect(!members[0].inventory.slots[2].?.identified);
    confirm(&state);
    _ = state.tick(.{ .field = .{ .menu_direction = .up } }, .{});
    confirm(&state);
    try equal(.appraisal_notice, state.menu.phase);
    try equal(@as(u32, 700), state.combat.progress.money);
    try std.testing.expectEqualStrings("Celadon urn", members[0].inventory.slots[2].?.name());
    try std.testing.expectError(error.AlreadyIdentified, state.combat.progress.appraise(fixtures.items.value, 0, 2));
    try equal(@as(u32, 700), state.combat.progress.money);
    state.menu.phase = .closed;
    try state.combat.depositToStorage(&state.combat.progress.storage, 0, 2);
    try state.combat.progress.storage.withdraw(&members[1].inventory, .celadon_urn);
    try expect(members[1].inventory.slots[2].?.identified);
    try journey.save(std.testing.io, allocator, directory.dir, state);
    members[1].inventory.remove(2);
    try journey.restore(std.testing.io, allocator, directory.dir, &state);
    try expect(members[1].inventory.slots[2].?.identified);
    try equal(@as(u32, 700), state.combat.progress.money);
}

test "new decoration drops retain their hidden identity through the reward ledger" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    var enemies: [4]battle.Profile = undefined;
    @memcpy(&enemies, state.combat.content.enemies);
    for (&enemies) |*enemy| enemy.drops = @splat(.{ .item = .octopus_urn, .uses = 0, .rate = 255, .identified = false });
    state.combat.content.enemies = &enemies;
    try state.beginEncounter(0);
    state.combat.enemy_hp = @splat(0);
    state.combat.phase = .resolving;
    state.combat.active = .{ .actor = 0, .target = 6, .kind = .defend };
    state.combat.action_ticks = state.combat.actionDuration() - 1;
    state.combat.tick(.{});
    try equal(.victory, state.combat.phase);
    try equal(field.items.Id.octopus_urn, state.combat.dropped_item.?.id);
    try expect(!state.combat.dropped_item.?.identified);
    try expect(!members[state.combat.loot_recipient.?].inventory.slots[3].?.identified);
    try std.testing.expectEqualStrings("? pot", state.combat.dropped_item.?.name());
}

test "Turtle blocks new status changes and individual Unite recovery without clearing existing ailments" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    try state.beginEncounter(0);
    const combat = state.combat;
    try expect(combat.inflictStatus(0, .poison));
    try expect(!combat.inflictStatus(0, .poison));
    for (0..3) |_| try expect(combat.inflictStatus(0, .balloon));
    try expect(!combat.inflictStatus(0, .balloon));
    try expect(combat.inflictStatus(0, .sleep));
    try expect(!combat.inflictStatus(0, .sleep));
    try equal(@as(u8, 3), members[0].balloons);
    const turtle = combat.content.systems.?.runeIndex("turtle").?;
    combat.runes[0] = turtle;
    const existing = members[0];
    for (std.enums.values(battle.Ailment)) |ailment| try expect(!combat.inflictStatus(0, ailment));
    try std.testing.expectEqualDeep(existing, members[0]);
    try equal(@as(u8, 1), combat.actor_conditions[0].sleep_turns);
    combat.runes[5] = turtle;
    combat.active = .{ .actor = 4, .partner = 5, .target = 6, .kind = .unite, .amount = 0 };
    combat.phase = .resolving;
    combat.action_ticks = combat.actionDuration() - 1;
    combat.tick(.{});
    try equal(@as(u8, 2), combat.unbalanced[4]);
    try equal(@as(u8, 0), combat.unbalanced[5]);
    combat.runes[3] = turtle;
    combat.runes[0] = combat.content.systems.?.runeIndex("earth").?;
    combat.actor_conditions[0].sleep_turns = 0;
    combat.base_stats[0].magic = 200;
    combat.refillMagic(0);
    const protection = spellIndex(combat.*, "spell_23");
    const tier = combat.spellTier(0, protection).?;
    const charges = members[0].rune_charges[tier];
    combat.active = .{ .actor = 0, .target = 3, .kind = .cast, .spell = protection };
    combat.action_ticks = combat.impactTick() - 1;
    combat.tick(.{});
    // Copper Flesh calls the direct setter, bypassing Turtle's acquisition gate.
    try equal(@as(u8, 3), combat.actor_conditions[3].protection_rounds);
    try equal(charges - 1, members[0].rune_charges[tier]);
    try expect(!combat.inflictStatus(99, .sleep));
    members[1].hp = 0;
    try expect(!combat.inflictStatus(1, .poison));
}

test "accuracy and Rune blocking are distinct, cure at full HP and leave recovery/protection intact" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    try state.beginEncounter(0);
    const combat = state.combat;
    const fire = spellIndex(combat.*, "spell_1");
    try expect(combat.canCast(0, fire));
    try expect(combat.inflictStatus(0, .rune_blocked));
    try expect(!combat.canCast(0, fire));
    try expect(!combat.hasMagic(0));
    try expect(combat.canAttackTarget(0, 0));
    try expect(combat.inflictStatus(0, .accuracy_reduced));
    try expect(!combat.inflictStatus(0, .accuracy_reduced));
    try expect(combat.inflictStatus(0, .sleep));
    try expect(!combat.canAttackTarget(0, 0));
    try expect(combat.canPhysicalRune(2));
    try expect(combat.inflictStatus(2, .rune_blocked));
    try expect(!combat.canPhysicalRune(2));
    combat.unbalanced[0] = 2;
    combat.actor_conditions[0].protection_rounds = 3;
    combat.runes[1] = combat.content.systems.?.runeIndex("water").?;
    combat.refillMagic(1);
    const heal = spellIndex(combat.*, "spell_9");
    const tier = combat.spellTier(1, heal).?;
    const before = members[1].rune_charges[tier];
    try equal(members[0].max_hp, members[0].hp);
    try combat.castFieldSpell(1, heal, 0);
    try expect(!combat.actor_conditions[0].rune_blocked);
    try expect(!combat.actor_conditions[0].accuracy_reduced);
    try equal(@as(u8, 0), combat.actor_conditions[0].sleep_turns);
    try equal(@as(u8, 2), combat.unbalanced[0]);
    try equal(@as(u8, 3), combat.actor_conditions[0].protection_rounds);
    try equal(before - 1, members[1].rune_charges[tier]);
    try expect(combat.actor_conditions[2].rune_blocked);
    combat.unbalanced[0] = 0;
    try expect(combat.canCast(0, fire));
    combat.actor_conditions[0].accuracy_reduced = true;
    combat.phase = .escaped;
    confirm(&state);
    try equal(.field, state.mode);
    try expect(!combat.actor_conditions[2].rune_blocked and !combat.actor_conditions[0].accuracy_reduced);
}
const Fixtures = struct {
    combat_storage: *std.heap.ArenaAllocator,
    package: std.json.Parsed(field.Package),
    content: std.json.Parsed(battle.Content),
    data: std.json.Parsed(journey.Data),
    items: std.json.Parsed(field.items.Rules),
    inn: std.json.Parsed(field.inn.Rules),
    fn init() !Fixtures {
        const package = try field.load(allocator, @embedFile("fixtures/journey_room.json"));
        errdefer package.deinit();
        const content = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
        errdefer content.deinit();
        const data = try journey.load(allocator, @embedFile("fixtures/journey.json"), package.value, content.value);
        errdefer data.deinit();
        const items = try field.items.load(allocator, field.items.json);
        errdefer items.deinit();
        const inn = try field.inn.load(allocator, field.inn.json);
        errdefer inn.deinit();
        const combat_storage = try allocator.create(std.heap.ArenaAllocator);
        combat_storage.* = .init(allocator);
        return .{ .combat_storage = combat_storage, .package = package, .content = content, .data = data, .items = items, .inn = inn };
    }
    fn deinit(self: Fixtures) void {
        self.combat_storage.deinit();
        allocator.destroy(self.combat_storage);
        self.inn.deinit();
        self.items.deinit();
        self.data.deinit();
        self.content.deinit();
        self.package.deinit();
    }
    fn session(self: Fixtures, members: []battle.Member) !journey.State {
        return journey.State.initEpisode(self.package.value, self.data.value, self.content.value, self.items.value, self.inn.value, members, try self.combat_storage.allocator().create(battle.State));
    }
};
fn confirm(state: *journey.State) void {
    if (state.field_state.dialogue) |*dialogue| dialogue.reveal_complete = true;
    _ = state.tick(.{ .field = .{ .action = true } }, .{ .confirm = true });
}
fn finishBattle(state: *journey.State) !void {
    for (0..40000) |_| {
        if (state.mode != .battle) break;
        if (state.combat.phase == .battle_menu) {
            for (0..3) |_| _ = state.tick(.{}, .{ .down = true });
            _ = state.tick(.{}, .{ .confirm = true });
        } else if (state.combat.phase == .victory or state.combat.phase == .escaped) confirm(state) else _ = state.tick(.{}, .{});
    }
    try equal(.field, state.mode);
}

test "connected encounter returns to the same origin with persistent HP, items, money, XP and one reward" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    try expect(state.combat.canCast(1, spellIndex(state.combat.*, "spell_30")));
    state.menu.phase = .root;
    state.menu.selected = .rune;
    state.menu.member = 1;
    confirm(&state);
    try equal(.rune, state.menu.phase);
    try equal(@as(usize, 1), state.menu.slot);
    state.menu.phase = .closed;
    const x = state.field_state.x;
    const y = state.field_state.y;
    const room = state.field_state.room;
    try state.combat.swapFormation(0, 3);
    members[1].inventory.slots[0].?.uses = 2;
    const money = state.combat.progress.money;
    try state.beginEncounter(0);
    try finishBattle(&state);
    try equal(room, state.field_state.room);
    try equal(x, state.field_state.x);
    try equal(y, state.field_state.y);
    try expect(state.combat.progress.money > money);
    try expect(state.combat.progress.story.forest_battle_one_won);
    try equal(@as(usize, 3), state.combat.formationSlot(0));
    try equal(@as(u16, 2), members[1].inventory.slots[0].?.uses);
    try equal(@as(u8, 6), state.combat.levels[0]);
    for (0..6) |i| try expect(state.combat.award_exp[i] > 0);
    const final_money = state.combat.progress.money;
    const xp = state.combat.experience;
    const rng = state.combat.random;
    state.combat.commitRewards();
    for (0..60) |_| _ = state.tick(.{}, .{});
    try equal(final_money, state.combat.progress.money);
    try equal(xp, state.combat.experience);
    try std.testing.expectEqualDeep(rng, state.combat.random);
    try equal(members[0].hp, state.field_state.progress.party[0].hp);
}

test "field character pages transact owned gear and formation without changing identities" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    state.bind();
    state.menu.phase = .root;
    state.menu.selected = .formation;
    confirm(&state);
    try equal(.formation, state.menu.phase);
    const before = members;
    confirm(&state);
    for (0..3) |_| _ = state.tick(.{ .field = .{ .menu_direction = .down } }, .{});
    confirm(&state);
    try equal(@as(usize, 3), state.combat.formationSlot(0));
    try std.testing.expectEqualDeep(before, members);
    state.menu.phase = .equipment_items;
    state.menu.member = 0;
    state.menu.slot = 3;
    const defense = state.combat.stats(0).defense;
    confirm(&state);
    try equal(.character_notice, state.menu.phase);
    try equal(@as(?usize, 0), state.combat.loadouts[0].head);
    try equal(defense, state.combat.stats(0).defense);
    state.menu.phase = .equipment_items;
    state.menu.slot = 0;
    confirm(&state);
    try equal(@as(?usize, null), state.combat.loadouts[0].head);
    try equal(defense - 1, state.combat.stats(0).defense);
    state.menu.phase = .equipment_items;
    state.menu.slot = 3;
    confirm(&state);
    try equal(@as(?usize, 0), state.combat.loadouts[0].head);
    try equal(@as(usize, 1), state.combat.gearCount(0, 0));
    state.combat.runes[0] = fixtures.content.value.systems.?.runeIndex("water").?;
    state.combat.base_stats[0].magic = 85;
    state.combat.refillMagic(0);
    members[1].hp = 20;
    state.menu.phase = .rune;
    state.menu.member = 0;
    state.menu.slot = 0;
    const charges = members[0].rune_charges[0];
    confirm(&state);
    try equal(.rune_target, state.menu.phase);
    _ = state.tick(.{ .field = .{ .menu_direction = .down } }, .{});
    confirm(&state);
    try equal(.character_notice, state.menu.phase);
    try expect(members[1].hp > 20);
    try equal(charges - 1, members[0].rune_charges[0]);
    try equal(members[1].hp, state.field_state.progress.party[1].hp);
}

test "journey save owns restored strings, retains all party data and rejects damaged state before mutation" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    members[0].hp = 44;
    state.combat.progress.story.forest_elf_seen = true;
    state.combat.levels[2] = 9;
    state.combat.experience[2] = 987;
    try state.combat.swapFormation(0, 3);
    const before = try journey.Snapshot.capture(state);
    var directory = std.testing.tmpDir(.{ .iterate = true });
    defer directory.cleanup();
    try journey.save(std.testing.io, allocator, directory.dir, state);
    members[0].hp = 1;
    state.combat.progress.money = 0;
    try journey.restore(std.testing.io, allocator, directory.dir, &state);
    try std.testing.expectEqualDeep(before, try journey.Snapshot.capture(state));
    try std.testing.expectEqualStrings("Hero", members[0].name);
    var bad = before;
    bad.formation[1] = bad.formation[0];
    try std.testing.expectError(error.InvalidFormation, bad.apply(&state));
    bad = before;
    bad.equipment[1] = 1;
    try std.testing.expectError(error.InvalidEquipment, bad.apply(&state));
    bad = before;
    bad.runes[0] = 999;
    try std.testing.expectError(error.InvalidRune, bad.apply(&state));
    try std.testing.expectEqualDeep(before, try journey.Snapshot.capture(state));
    var vtable = std.testing.io.vtable.*;
    vtable.fileSync = struct {
        fn fail(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
            return error.NoSpaceLeft;
        }
    }.fail;
    var failing = std.testing.io;
    failing.vtable = &vtable;
    state.combat.progress.money = 5;
    try std.testing.expectError(error.NoSpaceLeft, journey.save(failing, allocator, directory.dir, state));
    try journey.restore(std.testing.io, allocator, directory.dir, &state);
    try equal(before.money, state.combat.progress.money);
    try state.beginEncounter(0);
    try std.testing.expectError(error.GameBusy, journey.Snapshot.capture(state));
}

// Search the actual scene graph: separate forest branches reconnect through doorways.
fn walkToRoom(session: *journey.State, room_id: []const u8, target_x: i32, target_y: i32) !void {
    try settle(session);
    const package = session.package;
    var offsets: [33]usize = @splat(0);
    for (package.rooms, 0..) |room, i| offsets[i + 1] = offsets[i] + room.walkable.len;
    const count = offsets[package.rooms.len];
    const Step = struct { previous: usize, direction: field.Direction };
    const previous = try allocator.alloc(?Step, count);
    defer allocator.free(previous);
    @memset(previous, null);
    const queue = try allocator.alloc(usize, count);
    defer allocator.free(queue);
    const state = &session.field_state;
    const start = node(package, &offsets, state.room, state.x, state.y);
    const target = node(package, &offsets, package.roomIndex(room_id).?, target_x, target_y);
    previous[start] = .{ .previous = start, .direction = .down };
    queue[0] = start;
    var head: usize = 0;
    var tail: usize = 1;
    while (head < tail and previous[target] == null) : (head += 1) {
        const index = queue[head];
        var room_index: usize = 0;
        while (index >= offsets[room_index + 1]) room_index += 1;
        const room = package.rooms[room_index];
        const width: usize = @intCast(@divTrunc(room.width, 8));
        const local = index - offsets[room_index];
        const x: i32 = @intCast(local % width * 8);
        const y: i32 = @intCast(local / width * 8);
        for ([_]field.Point{ .{ .x = x, .y = y - 8 }, .{ .x = x, .y = y + 8 }, .{ .x = x - 8, .y = y }, .{ .x = x + 8, .y = y } }) |point| {
            if (!room.canStand(point.x, point.y)) continue;
            const direction: field.Direction = if (point.x < x) .left else if (point.x > x) .right else if (point.y < y) .up else .down;
            var next_room = room_index;
            var destination = point;
            for (room.exits) |exit| {
                if (exit.direction != null and exit.direction.? != direction) continue;
                if (point.x >= exit.x and point.x < exit.x + exit.w and point.y >= exit.y and point.y < exit.y + exit.h) {
                    next_room = package.roomIndex(exit.room).?;
                    destination = .{ .x = exit.spawn_x, .y = exit.spawn_y };
                    break;
                }
            }
            const next = node(package, &offsets, next_room, destination.x, destination.y);
            if (previous[next] != null) continue;
            previous[next] = .{ .previous = index, .direction = direction };
            queue[tail] = next;
            tail += 1;
        }
    }
    if (previous[target] == null) return error.NoRoute;
    var length: usize = 0;
    var cursor = target;
    while (cursor != start) : (cursor = previous[cursor].?.previous) {
        queue[length] = cursor;
        length += 1;
    }
    while (length > 0) {
        length -= 1;
        const next = queue[length];
        for (0..package.step_ticks) |_| _ = session.tick(.{ .field = .{ .direction = previous[next].?.direction } }, .{});
        try settle(session);
        try equal(next, node(package, &offsets, state.room, state.x, state.y));
    }
}
fn node(package: field.Package, offsets: []const usize, room: usize, x: i32, y: i32) usize {
    return offsets[room] + @as(usize, @intCast(@divTrunc(y, 8) * @divTrunc(package.rooms[room].width, 8) + @divTrunc(x, 8)));
}
fn walkTo(state: *journey.State, x: i32, y: i32) !void {
    return walkToRoom(state, state.package.rooms[state.field_state.room].id, x, y);
}

fn settle(state: *journey.State) !void {
    var idle_checked = false;
    for (0..100) |_| {
        if (state.mode == .battle) {
            try finishBattle(state);
            continue;
        }
        if (state.field_state.dialogue != null) {
            confirm(state);
            continue;
        }
        if (state.field_state.rest_ticks > 0) {
            _ = state.tick(.{}, .{});
            continue;
        }
        if (!idle_checked) {
            _ = state.tick(.{}, .{});
            idle_checked = true;
            continue;
        }
        return;
    }
    return error.DidNotSettle;
}
fn talkTo(state: *journey.State, npc_id: []const u8) !void {
    const room = state.package.rooms[state.field_state.room];
    for (room.npcs) |npc| if (std.mem.eql(u8, npc.id, npc_id)) {
        for (state.package.interaction_offsets, 0..) |offset, facing| {
            const x = npc.x - offset.x;
            const y = npc.y - offset.y;
            if (!room.canStand(x, y)) continue;
            try walkTo(state, x, y);
            state.field_state.facing = @fromBackingInt(@as(u2, @intCast(facing)));
            confirm(state);
            try expect(state.field_state.dialogue != null);
            try settle(state);
            return;
        }
    };
    return error.NoNpcApproach;
}

test "complete eight-scene episode walks the source route, conversations, encounters, treasure, return, rest and save" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    for (0..8) |seed| {
        var members: [6]battle.Member = undefined;
        var state = try fixtures.session(&members);
        state.combat.random = .init(seed);
        try walkToRoom(&state, "vb6_village", 264, 296);
        try talkTo(&state, "forest_villager");
        try expect(state.combat.progress.story.heard_forest_warning);
        try walkTo(&state, 264, 296);
        try expect(state.combat.progress.story.forest_elf_seen);
        try walkToRoom(&state, "vb6_forest_paths", 136, 160);
        try talkTo(&state, "forest_chest_needle");
        try expect(state.combat.progress.story.forest_treasure_needle);
        try talkTo(&state, "forest_chest_water");
        try expect(state.combat.progress.story.forest_treasure_water);
        try walkToRoom(&state, "vb6_forest_clearing", 200, 192);
        try expect(state.combat.progress.story.forest_battle_one_won);
        try expect(state.combat.progress.story.forest_battle_two_won);
        try expect(state.combat.progress.story.forest_battle_three_won);
        try walkToRoom(&state, "vb6_village", 400, 256);
        try expect(state.combat.progress.story.forest_returned);
        const rewards = state.combat.progress.money;
        try walkToRoom(&state, "vb6_inn", 288, 120);
        state.field_state.facing = .up;
        confirm(&state);
        confirm(&state);
        confirm(&state);
        try equal(@as(u16, 60), state.field_state.rest_ticks);
        try settle(&state);
        try equal(rewards - 600, state.combat.progress.money);
        for (members) |member| {
            try equal(member.max_hp, member.hp);
            try equal(.healthy, member.status);
        }
        var temp = std.testing.tmpDir(.{});
        defer temp.cleanup();
        try journey.save(std.testing.io, allocator, temp.dir, state);
        const saved = try journey.Snapshot.capture(state);
        state.combat.progress.story = .initial;
        state.combat.progress.money = 0;
        try journey.restore(std.testing.io, allocator, temp.dir, &state);
        try std.testing.expectEqualDeep(saved, try journey.Snapshot.capture(state));
    }
}

fn spellIndex(state: battle.State, id: []const u8) usize {
    for (state.content.systems.?.spells, 0..) |spell, i| if (std.mem.eql(u8, spell.id, id)) return i;
    unreachable;
}
fn castNow(combat: *battle.State, actor: usize, spell: usize, target: usize) void {
    combat.phase = .resolving;
    combat.active = .{ .actor = actor, .target = target, .kind = .cast, .spell = spell };
    combat.action_ticks = combat.impactTick() - 1;
    combat.tick(.{});
}

test "shop purchase uses one progress owner through field battle and restore" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    const progress_before = state.progress();
    try expect(progress_before == state.field_state.progress);
    state.bind();
    members[0].inventory.slots[0] = .{ .id = .needle, .uses = 1 };
    members[1].balloons = 2;
    members[1].status = .poisoned;
    state.menu.phase = .item_action;
    state.menu.member = 0;
    state.menu.slot = 0;
    confirm(&state);
    try equal(.item_target, state.menu.phase);
    _ = state.tick(.{ .field = .{ .menu_direction = .down } }, .{});
    confirm(&state);
    try equal(.item_notice, state.menu.phase);
    try equal(@as(u8, 1), members[1].balloons);
    try equal(.poisoned, members[1].status);
    try equal(.medicine, members[0].inventory.slots[0].?.id);
    state.combat.progress.money = 500;
    state.menu.phase = .buy_member;
    state.menu.member = 1;
    _ = state.tick(.{ .field = .{ .menu_direction = .down } }, .{});
    try equal(.mega_medicine, fixtures.items.value.stock[state.menu.stock_slot]);
    const money = state.combat.progress.money;
    const count = members[1].inventory.count();
    confirm(&state);
    try expect(!state.menu.yes);
    _ = state.tick(.{ .right = true }, .{});
    confirm(&state);
    try equal(.shop_notice, state.menu.phase);
    try equal(money - 500, state.combat.progress.money);
    const purchased = field.items.Stack{ .id = .mega_medicine, .uses = 3 };
    try std.testing.expectEqualDeep(purchased, members[1].inventory.slots[count].?);

    const before_rejection = members[1].inventory;
    confirm(&state);
    confirm(&state);
    confirm(&state);
    _ = try state.tickWithFieldEvents(.{ .right = true }, .{});
    confirm(&state);
    try equal(.shop_notice, state.menu.phase);
    try std.testing.expectEqualStrings("You do not have enough bits.", state.menu.message);
    try equal(@as(u32, 0), state.progress().money);
    try std.testing.expectEqualDeep(before_rejection, state.progress().party[1].inventory);

    for (0..2) |_| _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
    try equal(.closed, state.menu.phase);
    try state.beginEncounter(0);
    try equal(@as(u32, 0), state.combat.progress.money);
    try std.testing.expectEqualDeep(purchased, state.combat.progress.party[1].inventory.slots[count].?);
    try finishBattle(&state);
    try equal(.field, state.mode);
    try std.testing.expectEqualDeep(purchased, state.progress().party[1].inventory.slots[count].?);
    members[1].inventory.slots[count + 1] = .{ .id = .antitoxin, .uses = 2 };
    state.menu.phase = .closed;
    const before = try journey.Snapshot.capture(state);
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try journey.save(std.testing.io, allocator, temp.dir, state);
    members[1].balloons = 0;
    members[1].inventory.slots[count + 1] = null;
    try journey.restore(std.testing.io, allocator, temp.dir, &state);
    try std.testing.expectEqualDeep(before, try journey.Snapshot.capture(state));
    try expect(state.field_state.progress == progress_before);
    try expect(state.progress() == progress_before);
}

test "battle selects exact item and rechecks target and item identity at a single impact" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    for ([_]field.items.Id{ .medicine, .mega_medicine, .antitoxin, .needle }) |id| {
        for (0..4) |failure| {
            var members: [6]battle.Member = undefined;
            var state = try fixtures.session(&members);
            const combat = state.combat;
            try state.beginEncounter(0);
            members[0].inventory.slots[0] = .{ .id = id, .uses = 2 };
            members[1].hp = 1;
            members[1].status = .poisoned;
            members[1].balloons = 2;
            combat.actor_conditions[1].sleep_turns = 1;
            combat.unbalanced[1] = 1;
            combat.choose(0);
            combat.picker.selected = .item;
            combat.tick(.{ .confirm = true });
            combat.tick(.{ .confirm = true });
            try equal(.item_target, combat.phase);
            combat.tick(.{ .down = true });
            combat.tick(.{ .confirm = true });
            try equal(id, combat.actions[0].?.item.id);
            try equal(@as(usize, 1), combat.actions[0].?.item.target);
            if (failure == 1) {
                members[1].hp = 0;
                members[1].status = .unconscious;
            } else if (failure == 2) members[0].inventory.slots[0] = .{ .id = .water_rune_piece, .uses = 0 } else if (failure == 3) {
                members[1].hp = members[1].max_hp;
                members[1].status = .healthy;
                members[1].balloons = 0;
            }
            combat.phase = .resolving;
            combat.active = .{ .actor = 0, .target = 1, .kind = .item, .item_id = id };
            combat.action_ticks = combat.impactTick() - 1;
            combat.tick(.{});
            try equal(@as(u8, 1), combat.actor_conditions[1].sleep_turns);
            try equal(@as(u8, 1), combat.unbalanced[1]);
            if (failure == 0) {
                const impact = combat.recentItemImpact(1).?;
                try equal(members[1].hp - 1, impact.recovered_hp);
                try equal(id == .antitoxin, impact.cured_poison);
                try equal(id == .needle, impact.removed_balloon);
            } else try expect(combat.recentItemImpact(1) == null);
            if (failure == 1 or failure == 2) {
                try equal(.unavailable, combat.active.?.kind);
                try equal(@as(u16, if (failure == 2) 0 else 2), members[0].inventory.slots[0].?.uses);
            } else {
                try equal(.item, combat.active.?.kind);
                try equal(@as(u16, 1), members[0].inventory.slots[0].?.uses);
                const definition = fixtures.items.value.consumable(id).?;
                try equal(if (failure == 3) members[1].max_hp else @min(members[1].max_hp, 1 + definition.heal_hp), members[1].hp);
                try equal(if (failure == 3 or id == .antitoxin) field.game_state.Status.healthy else .poisoned, members[1].status);
                try equal(@as(u8, if (failure == 3) 0 else if (id == .needle) 1 else 2), members[1].balloons);
                const after = members;
                for (0..10) |_| combat.tick(.{});
                try std.testing.expectEqualDeep(after, members);
            }
        }
    }
}

test "shop sell confirms full bundles, cancels safely, protects worn gear and freezes field movement" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    state.bind();
    state.menu.phase = .shop;
    const before = try journey.Snapshot.capture(state);
    _ = state.tick(.{ .field = .{ .menu_direction = .down } }, .{});
    confirm(&state);
    try equal(.sell_items, state.menu.phase);
    confirm(&state);
    try equal(.confirm_sell, state.menu.phase);
    try expect(!state.menu.yes);
    confirm(&state);
    try equal(.sell_items, state.menu.phase);
    try std.testing.expectEqualDeep(before, try journey.Snapshot.capture(state));
    confirm(&state);
    _ = state.tick(.{ .right = true }, .{});
    confirm(&state);
    try equal(.shop_notice, state.menu.phase);
    try equal(before.money + 50, state.combat.progress.money);
    try equal(@as(usize, 2), members[0].inventory.count());
    const after = try journey.Snapshot.capture(state);
    for (0..40) |_| _ = state.tick(.{ .field = .{ .direction = .down } }, .{});
    try std.testing.expectEqualDeep(after, try journey.Snapshot.capture(state));
    confirm(&state);
    confirm(&state);
    try equal(.sell_items, state.menu.phase);
    state.menu.slot = 1;
    confirm(&state);
    try equal(.shop_notice, state.menu.phase);
    try std.testing.expectEqualDeep(after, try journey.Snapshot.capture(state));
    try expect(std.mem.indexOf(u8, state.menu.message, "Equipment") != null);
}

test "five equipment slots enforce compatibility, owned copies and protect every worn instance" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    const state = try fixtures.session(&members);
    const combat = state.combat;
    members[0].inventory.slots = .{ .{ .id = .bandanna, .uses = 0 }, .{ .id = .tunic, .uses = 0 }, .{ .id = .gloves, .uses = 0 }, null, null, null, null, null, null };
    const base = combat.base_stats[0].defense;
    try combat.equipSlotOwned(0, .head, combat.gearIndex(.bandanna));
    try combat.equipSlotOwned(0, .body, combat.gearIndex(.tunic));
    try combat.equipSlotOwned(0, .accessory_one, combat.gearIndex(.gloves));
    try std.testing.expectError(error.ItemUnavailable, combat.equipSlotOwned(0, .accessory_two, combat.gearIndex(.gloves)));
    members[0].inventory.slots[3] = .{ .id = .gloves, .uses = 0 };
    try combat.equipSlotOwned(0, .accessory_two, combat.gearIndex(.gloves));
    try equal(base + 7, combat.stats(0).defense);
    for (0..4) |slot| try expect(combat.itemEquipped(0, slot));
    const before = combat.loadouts;
    try std.testing.expectError(error.InvalidEquipment, combat.equipSlotOwned(0, .shield, combat.gearIndex(.gloves)));
    members[0].inventory.slots[4] = .{ .id = .wooden_shield, .uses = 0 };
    try std.testing.expectError(error.InvalidEquipment, combat.equipSlotOwned(0, .shield, combat.gearIndex(.wooden_shield)));
    try std.testing.expectEqualDeep(before, combat.loadouts);
    try combat.equipSlotOwned(0, .accessory_two, null);
    try expect(combat.itemEquipped(0, 2));
    try expect(!combat.itemEquipped(0, 3));
    try equal(base + 5, combat.stats(0).defense);
}

test "equipment menu chooses slot then carried item and updated magic capacity never grants free charges" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    state.bind();
    members[0].inventory.slots[3] = .{ .id = .emblem, .uses = 0 };
    const charges = members[0].rune_charges;
    state.menu.phase = .equipment;
    for (0..3) |_| _ = state.tick(.{ .field = .{ .menu_direction = .down } }, .{});
    try equal(.accessory_one, state.menu.equipment_slot);
    confirm(&state);
    try equal(.equipment_items, state.menu.phase);
    for (0..4) |_| _ = state.tick(.{ .field = .{ .menu_direction = .down } }, .{});
    confirm(&state);
    try equal(.character_notice, state.menu.phase);
    try equal(state.combat.gearIndex(.emblem), state.combat.loadouts[0].accessory_one);
    try equal(state.combat.base_stats[0].magic + 10, state.combat.stats(0).magic);
    try equal(charges, members[0].rune_charges);
    try expect(members[0].max_rune_charges[0] > charges[0]);
    state.combat.levelUp(0, @splat(0));
    try equal(charges, members[0].rune_charges);
    try state.combat.validateOwnedMember(state.combat.ownedMember(0));
    state.combat.refillMagic(0);
    try state.combat.equipSlotOwned(0, .accessory_one, null);
    try equal(state.combat.content.systems.?.magicCapacity(state.combat.base_stats[0].magic), members[0].rune_charges);
}

test "journey saves restore all slots and migrate legacy headgear while rejecting missing owned copies" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    members[0].inventory.slots[3] = .{ .id = .gloves, .uses = 0 };
    members[0].inventory.slots[4] = .{ .id = .tunic, .uses = 0 };
    try state.combat.equipSlotOwned(0, .body, state.combat.gearIndex(.tunic));
    try state.combat.equipSlotOwned(0, .accessory_one, state.combat.gearIndex(.gloves));
    const saved = try journey.Snapshot.capture(state);
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try journey.save(std.testing.io, allocator, temp.dir, state);
    state.combat.loadouts = @splat(.{});
    try journey.restore(std.testing.io, allocator, temp.dir, &state);
    try std.testing.expectEqualDeep(saved, try journey.Snapshot.capture(state));
    var bad = saved;
    bad.loadouts.?[0].accessory_two = bad.loadouts.?[0].accessory_one;
    try std.testing.expectError(error.InvalidEquipment, bad.apply(&state));
    try std.testing.expectEqualDeep(saved, try journey.Snapshot.capture(state));
    var legacy = saved;
    legacy.schema = "suikoden-journey-save/1";
    legacy.auxiliary_party = null;
    legacy.loadouts = null;
    try legacy.apply(&state);
    try equal(saved.equipment, state.combat.headEquipment());
    try equal(@as(?usize, null), state.combat.loadouts[0].body);
    try equal(@as(?usize, null), state.combat.loadouts[0].accessory_one);
}

test "visit source blacksmith, cancel, reject insufficient funds, sharpen and save the result" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    try walkToRoom(&state, "vb6_blacksmith", 184, 112);
    state.field_state.facing = .up;
    confirm(&state);
    try expect(state.field_state.dialogue != null);
    confirm(&state);
    _ = state.tick(.{}, .{});
    try equal(.blacksmith, state.menu.phase);
    try equal(@as(u8, 5), state.menu.service_limit);
    const level = state.combat.weapon_levels[0];
    const attack = state.combat.stats(0).attack;
    const money = state.combat.progress.money;
    confirm(&state);
    try equal(.confirm_blacksmith, state.menu.phase);
    try expect(!state.menu.yes);
    confirm(&state);
    try equal(level, state.combat.weapon_levels[0]);
    try equal(money, state.combat.progress.money);
    state.combat.progress.money = 0;
    confirm(&state);
    _ = state.tick(.{ .right = true }, .{});
    confirm(&state);
    try equal(.character_notice, state.menu.phase);
    try equal(level, state.combat.weapon_levels[0]);
    try equal(@as(u32, 0), state.combat.progress.money);
    confirm(&state);
    const price = try state.combat.sharpenPrice(0, state.menu.service_limit);
    state.combat.progress.money = price;
    confirm(&state);
    _ = state.tick(.{ .right = true }, .{});
    confirm(&state);
    try equal(level + 1, state.combat.weapon_levels[0]);
    try equal(@as(u32, 0), state.combat.progress.money);
    const weapon = state.combat.content.party[0].weapon.?;
    try equal(attack + weapon.powers[level] - weapon.powers[level - 1], state.combat.stats(0).attack);
    state.menu.phase = .closed;
    const saved = try journey.Snapshot.capture(state);
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try journey.save(std.testing.io, allocator, temp.dir, state);
    state.combat.weapon_levels[0] = level;
    try journey.restore(std.testing.io, allocator, temp.dir, &state);
    try std.testing.expectEqualDeep(saved, try journey.Snapshot.capture(state));
    state.menu.phase = .strength;
    _ = state.tick(.{ .field = .{ .menu_direction = .down } }, .{});
    try expect(state.menu.strength_details);
    _ = state.tick(.{ .right = true }, .{});
    try equal(@as(usize, 1), state.menu.member);
}

test "sharpening respects every exported price, cumulative power and shop cap without partial mutations" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    const combat = state.combat;
    for (0..combat.partyCount()) |i| {
        const profile = combat.partyProfile(i);
        const weapon = profile.weapon.?;
        const attack = combat.stats(i).attack;
        var money: u32 = 1000000;
        while (combat.weapon_levels[i] < 5) {
            const level = combat.weapon_levels[i];
            const before = money;
            try equal(weapon.upgrade_costs[level], try combat.sharpenPrice(i, 5));
            try combat.sharpen(i, 5, &money);
            try equal(before - weapon.upgrade_costs[level], money);
            try equal(attack + weapon.powers[level] - weapon.powers[weapon.initial_level - 1], combat.stats(i).attack);
        }
        const before = money;
        try std.testing.expectError(error.WeaponLimit, combat.sharpen(i, 5, &money));
        try equal(before, money);
        try equal(@as(u8, 5), combat.weapon_levels[i]);
    }
    var bad = try journey.Snapshot.capture(state);
    bad.weapon_levels.?[0] = 0;
    try std.testing.expectError(error.InvalidWeapon, bad.apply(&state));
    bad.weapon_levels.?[0] = 17;
    try std.testing.expectError(error.InvalidWeapon, bad.apply(&state));
}

test "rune crystals respect native character permissions, locked runes and atomic inventory return" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    const combat = state.combat;
    const money = combat.progress.money;
    members[0].inventory.slots[3] = .{ .id = .clone_crystal, .uses = 0 };
    const charges = members[3].rune_charges;
    try std.testing.expectError(error.IncompatibleRune, combat.attachRune(5, 0, 3));
    try equal(.clone_crystal, members[0].inventory.slots[3].?.id);
    try equal(@as(?usize, null), combat.runes[5]);
    try combat.attachRune(3, 0, 3);
    try std.testing.expectEqualStrings("clone", combat.rune(3).?.id);
    try equal(@as(usize, 3), members[0].inventory.count());
    try equal(charges, members[3].rune_charges);
    try equal(money, combat.progress.money);
    const before = try journey.Snapshot.capture(state);
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try journey.save(std.testing.io, allocator, directory.dir, state);
    combat.runes[3] = null;
    try journey.restore(std.testing.io, allocator, directory.dir, &state);
    try std.testing.expectEqualDeep(before, try journey.Snapshot.capture(state));
    members[3].inventory.slots = @splat(.{ .id = .medicine, .uses = 6 });
    try std.testing.expectError(error.InventoryFull, combat.detachRune(3));
    try std.testing.expectEqualStrings("clone", combat.rune(3).?.id);
    members[3].inventory.remove(8);
    try combat.detachRune(3);
    try equal(.clone_crystal, members[3].inventory.slots[8].?.id);
    try equal(@as(?usize, null), combat.runes[3]);
    try equal(charges, members[3].rune_charges);
    try std.testing.expectError(error.RuneLocked, combat.detachRune(2));
    try std.testing.expectError(error.RuneLocked, combat.attachRune(2, 3, 8));
    try std.testing.expectError(error.RuneOccupied, combat.attachRune(0, 3, 8));
    try equal(money, combat.progress.money);
    var bad = try journey.Snapshot.capture(state);
    bad.runes[2] = null;
    try std.testing.expectError(error.RuneLocked, bad.apply(&state));
}

test "village stock includes its native Counter crystal with durable-item purchase and sale rules" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    state.bind();
    const rules = fixtures.items.value;
    try equal(@as(usize, 4), rules.stock.len);
    try equal(.counter_crystal, rules.stock[3]);
    const crystal = rules.good(.counter_crystal).?;
    state.combat.progress.money = crystal.price;
    state.menu.phase = .buy_member;
    state.menu.stock_slot = 3;
    confirm(&state);
    _ = state.tick(.{ .right = true }, .{});
    confirm(&state);
    try equal(.shop_notice, state.menu.phase);
    try equal(@as(u32, 0), state.combat.progress.money);
    try equal(.counter_crystal, members[0].inventory.slots[3].?.id);
    try equal(@as(u16, 0), members[0].inventory.slots[3].?.uses);
    try equal(crystal.price / 2, try state.combat.progress.salePrice(rules, 0, 3));
    members[0].inventory.slots[3] = .{ .id = .boar_crystal, .uses = 0 };
    try std.testing.expectError(error.CannotSell, state.combat.progress.sellItem(rules, 0, 3));
    try equal(.boar_crystal, members[0].inventory.slots[3].?.id);
}

test "rune service confirmation cancels safely, consumes chosen owner's crystal and returns a detached rune" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    state.bind();
    members[0].inventory.slots[3] = .{ .id = .clone_crystal, .uses = 0 };
    state.menu.phase = .rune_service;
    state.menu.member = 3;
    confirm(&state);
    try equal(.rune_attach, state.menu.phase);
    for (0..3) |_| _ = state.tick(.{ .left = true }, .{});
    for (0..3) |_| _ = state.tick(.{ .field = .{ .menu_direction = .down } }, .{});
    try equal(@as(usize, 0), state.menu.member);
    try equal(@as(usize, 3), state.menu.slot);
    confirm(&state);
    try equal(.confirm_rune_attach, state.menu.phase);
    try expect(!state.menu.yes);
    confirm(&state);
    try equal(@as(?usize, null), state.combat.runes[3]);
    try equal(.clone_crystal, members[0].inventory.slots[3].?.id);
    confirm(&state);
    _ = state.tick(.{ .right = true }, .{});
    confirm(&state);
    try equal(.character_notice, state.menu.phase);
    try std.testing.expectEqualStrings("clone", state.combat.rune(3).?.id);
    try equal(@as(usize, 3), members[0].inventory.count());
    confirm(&state);
    try equal(.rune_service, state.menu.phase);
    _ = state.tick(.{ .field = .{ .menu_direction = .down } }, .{});
    confirm(&state);
    try equal(.confirm_rune_remove, state.menu.phase);
    try expect(!state.menu.yes);
    _ = state.tick(.{ .right = true }, .{});
    confirm(&state);
    try equal(@as(?usize, null), state.combat.runes[3]);
    try equal(.clone_crystal, members[3].inventory.slots[3].?.id);
}
test "connected spells match static source semantic vectors and preserve rune ownership and charges" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    const Vectors = struct { damage: []const struct { power: u16, magic: u16, affinity: battle.systems.Affinity, damage: u32 }, status: []const struct { roll: u15, sleep: bool, recover: bool } };
    const vectors = try std.json.parseFromSlice(Vectors, allocator, @embedFile("fixtures/journey_rules.json"), .{});
    defer vectors.deinit();
    for (vectors.value.damage) |row| try equal(row.damage, battle.systems.elementalDamage(row.power, row.magic, row.affinity));
    for (vectors.value.status) |row| {
        try equal(row.sleep, battle.systems.statusPercent(row.roll) >= 30);
        try equal(row.recover, @as(u32, row.roll) * 100 / 32767 < 50);
    }
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    const combat = state.combat;
    try state.beginEncounter(0);
    const arrows = spellIndex(combat.*, "spell_1");
    const before = members[0].rune_charges[0];
    castNow(combat, 0, arrows, 8);
    try equal(@as(u32, 264), combat.active.?.amounts[8]);
    try equal(@as(u16, 18), combat.enemy_hp[0]);
    try equal(@as(u16, 18), combat.enemy_hp[1]);
    try equal(@as(u16, 0), combat.enemy_hp[2]);
    try equal(before - 1, members[0].rune_charges[0]);
    const charges = members[1].rune_charges;
    castNow(combat, 1, arrows, 6);
    try equal(.unavailable, combat.active.?.kind);
    try equal(charges, members[1].rune_charges);
    combat.runes[1] = combat.content.systems.?.runeIndex("water").?;
    combat.refillMagic(1);
    members[2].hp = 3;
    members[2].status = .poisoned;
    combat.actor_conditions[2].sleep_turns = 1;
    castNow(combat, 1, spellIndex(combat.*, "spell_9"), 2);
    try equal(members[2].max_hp, members[2].hp);
    try equal(.healthy, members[2].status);
    try equal(@as(u8, 0), combat.actor_conditions[2].sleep_turns);
    for (&members) |*member| member.hp = 1;
    const group_charges = members[1].rune_charges[2];
    castNow(combat, 1, spellIndex(combat.*, "spell_11"), 0);
    for (members) |member| try equal(member.max_hp, member.hp);
    try equal(group_charges - 1, members[1].rune_charges[2]);
    combat.runes[1] = combat.content.systems.?.runeIndex("flowing").?;
    combat.base_stats[1].magic = 255;
    combat.refillMagic(1);
    members[0].hp = 0;
    members[0].status = .unconscious;
    members[3].hp = 1;
    castNow(combat, 1, spellIndex(combat.*, "spell_30"), 0);
    for (members) |member| {
        try equal(member.max_hp, member.hp);
        try equal(.healthy, member.status);
    }
    const no_effect = members[1].rune_charges;
    castNow(combat, 1, spellIndex(combat.*, "spell_30"), 0);
    try equal(.unavailable, combat.active.?.kind);
    try equal(no_effect, members[1].rune_charges);
    members[2].balloons = 3;
    combat.unbalanced[2] = 1;
    castNow(combat, 1, spellIndex(combat.*, "spell_30"), 0);
    try equal(@as(u8, 0), members[2].balloons);
    try equal(@as(u8, 1), combat.unbalanced[2]);
    try equal(no_effect[3] - 1, members[1].rune_charges[3]);
}

test "both connected Unites use distinct native tracks, exact chosen target and one combined hit" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    for ([_][2]usize{ .{ 1, 2 }, .{ 2, 1 }, .{ 4, 5 }, .{ 5, 4 } }) |pair| {
        var members: [6]battle.Member = undefined;
        var state = try fixtures.session(&members);
        try state.beginEncounter(0);
        const combat = state.combat;
        combat.actions = @splat(.defend);
        combat.actions[pair[1]] = null;
        combat.choose(pair[0]);
        combat.queue(.{ .unite = 2 });
        try equal(pair[0], combat.actions[pair[1]].?.assist);
        combat.base_stats[pair[0]].speed = 999;
        combat.phase = .resolving;
        combat.tick(.{});
        try equal(.unite, combat.active.?.kind);
        try equal(@as(usize, 8), combat.active.?.target);
        const motion = combat.actionMotion(pair[0]).?;
        try expect(motion.stages.len == (if (pair[0] >= 4) @as(usize, 2) else 1));
        try expect(combat.attackFrames(pair[0]).ptr != fixtures.content.value.party[pair[0]].attack.ptr);
        const home = combat.content.formation_slots[combat.formationSlot(pair[0])];
        const target = combat.content.encounters[combat.encounter].positions[2];
        try std.testing.expectEqualDeep(home, battle.presentation.actorPosition(home, target, motion, motion.duration));
        for (0..motion.duration + 1) |tick| {
            const pos = battle.presentation.actorPosition(home, target, motion, @intCast(tick));
            const projected = battle.presentation.project(combat.content.camera, pos);
            try expect(std.math.isFinite(projected.x) and std.math.isFinite(projected.y) and projected.depth > 0);
        }
        combat.action_ticks = combat.impactTick() - 1;
        combat.tick(.{});
        try equal(@as(u16, 18), combat.enemy_hp[0]);
        try equal(@as(u16, 18), combat.enemy_hp[1]);
        try equal(@as(u16, 0), combat.enemy_hp[2]);
        const after = combat.enemy_hp;
        while (combat.active != null) combat.tick(.{});
        try equal(after, combat.enemy_hp);
    }
}

test "owned equipment cannot be given or discarded, spare items transfer atomically, discard requires confirmation" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    state.bind();
    state.menu.phase = .items;
    state.menu.member = 0;
    state.menu.slot = 2;
    confirm(&state);
    try equal(.item_action, state.menu.phase);
    _ = state.tick(.{ .field = .{ .menu_direction = .down } }, .{});
    confirm(&state);
    try equal(.item_notice, state.menu.phase);
    try expect(state.combat.itemEquipped(0, 2));
    state.menu.phase = .items;
    state.menu.member = 3;
    state.menu.slot = 2;
    confirm(&state);
    _ = state.tick(.{ .field = .{ .menu_direction = .down } }, .{});
    confirm(&state);
    try equal(.item_transfer, state.menu.phase);
    _ = state.tick(.{ .field = .{ .menu_direction = .down } }, .{});
    confirm(&state);
    try equal(@as(usize, 2), members[3].inventory.count());
    try equal(.headband, members[4].inventory.slots[2].?.id);
    try state.combat.equipOwned(4, 1);
    state.menu.phase = .items;
    state.menu.member = 4;
    state.menu.slot = 2;
    confirm(&state);
    for (0..2) |_| _ = state.tick(.{ .field = .{ .menu_direction = .down } }, .{});
    confirm(&state);
    try equal(.item_notice, state.menu.phase);
    try state.combat.equipOwned(4, null);
    state.menu.phase = .items;
    confirm(&state);
    for (0..2) |_| _ = state.tick(.{ .field = .{ .menu_direction = .down } }, .{});
    confirm(&state);
    try equal(.confirm_discard, state.menu.phase);
    confirm(&state);
    try equal(.item_action, state.menu.phase);
    try equal(@as(usize, 3), members[4].inventory.count());
    confirm(&state);
    _ = state.tick(.{ .field = .{ .menu_direction = .down } }, .{});
    confirm(&state);
    try equal(.item_notice, state.menu.phase);
    try equal(@as(usize, 2), members[4].inventory.count());
}

test "full battle bags require explicit reward placement or leaving, preserve worn gear and never award twice" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    try state.beginEncounter(0);
    for (&members) |*member| for (&member.inventory.slots) |*slot| {
        slot.* = .{ .id = .medicine, .uses = 6 };
    };
    members[0].inventory.slots[2] = .{ .id = .bandanna, .uses = 0 };
    const combat = state.combat;
    combat.phase = .victory;
    combat.dropped_item = .{ .id = .failure_urn, .uses = 0 };
    combat.drop_received = false;
    confirm(&state);
    try equal(.loot, combat.phase);
    try equal(.battle, state.mode);
    confirm(&state);
    try equal(.loot_replace, combat.phase);
    combat.selection = 2;
    confirm(&state);
    try equal(.loot_replace, combat.phase);
    combat.selection = 0;
    confirm(&state);
    try equal(.confirm_loot_replace, combat.phase);
    try expect(!combat.yes);
    confirm(&state);
    try equal(.loot_replace, combat.phase);
    try equal(.medicine, members[0].inventory.slots[0].?.id);
    confirm(&state);
    _ = state.tick(.{}, .{ .left = true });
    confirm(&state);
    try equal(.failure_urn, members[0].inventory.slots[0].?.id);
    try equal(.victory, combat.phase);
    const money = combat.progress.money;
    confirm(&state);
    try equal(.field, state.mode);
    try equal(money, combat.progress.money);
    try equal(.bandanna, members[0].inventory.slots[2].?.id);
    try state.beginEncounter(1);
    combat.phase = .victory;
    combat.dropped_item = .{ .id = .celadon_urn, .uses = 0 };
    combat.drop_received = false;
    confirm(&state);
    _ = state.tick(.{}, .{ .cancel = true });
    try equal(.confirm_leave_loot, combat.phase);
    try expect(!combat.yes);
    confirm(&state);
    try equal(.loot, combat.phase);
    _ = state.tick(.{}, .{ .cancel = true });
    _ = state.tick(.{}, .{ .left = true });
    confirm(&state);
    try expect(combat.loot_declined);
    confirm(&state);
    try equal(.field, state.mode);
    try equal(money, combat.progress.money);
}

test "escape keeps the event pending, defeat restores the complete checkpoint and menus cannot advance the field" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    state.field_state.enterRoom(state.package.roomIndex("vb6_forest_edge").?, .{ .x = 192, .y = 48 });
    for (0..state.package.step_ticks) |_| _ = state.tick(.{ .field = .{ .direction = .right } }, .{});
    try equal(.battle, state.mode);
    const battle_scene = state.audioScene();
    try equal(.battle, battle_scene);
    state.combat.phase = .escaped;
    confirm(&state);
    try equal(.field, state.mode);
    try equal(.field, state.audioScene());
    try expect(!state.combat.progress.story.forest_battle_one_won);
    const checkpoint = try journey.Snapshot.capture(state);
    try state.beginEncounter(0);
    for (&members) |*member| {
        member.hp = 0;
        member.status = .unconscious;
    }
    state.combat.progress.money = 0;
    state.combat.phase = .defeat;
    _ = state.tick(.{}, .{});
    try equal(.defeat, state.mode);
    try equal(.defeat, state.audioScene());
    try equal(.defeat, state.audioScene().track(state.package.rooms[state.field_state.room].id, true, true));
    confirm(&state);
    try equal(.battle, state.mode);
    try equal(battle_scene, state.audioScene());
    try equal(checkpoint.money, state.combat.progress.money);
    try std.testing.expectEqualDeep(checkpoint.party, members);
    state.combat.phase = .escaped;
    confirm(&state);
    var saves = std.testing.tmpDir(.{});
    defer saves.cleanup();
    try journey.save(std.testing.io, allocator, saves.dir, state);
    state = try fixtures.session(&members);
    try journey.restore(std.testing.io, allocator, saves.dir, &state);
    for (0..state.package.step_ticks) |_| _ = state.tick(.{ .field = .{ .direction = .right } }, .{});
    try equal(@as(i32, 208), state.field_state.x);
    try equal(.field, state.mode);
    for (0..state.package.step_ticks) |_| _ = state.tick(.{ .field = .{ .direction = .right } }, .{});
    for (0..state.package.step_ticks) |_| _ = state.tick(.{ .field = .{ .direction = .left } }, .{});
    try equal(.battle, state.mode);
    state.combat.phase = .escaped;
    confirm(&state);
    const before = try journey.Snapshot.capture(state);
    _ = state.tick(.{ .menu = true }, .{});
    for (0..60) |_| _ = state.tick(.{ .field = .{ .direction = .left } }, .{});
    try equal(.root, state.menu.phase);
    try equal(before.x, state.field_state.x);
    try equal(before.y, state.field_state.y);
    try std.testing.expectEqualDeep(before.party, members);
}

test "RNG sequence survives save reload and defeat retry" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    try journey.save(std.testing.io, allocator, directory.dir, state);
    try state.beginEncounter(0);
    var saved_rolls: [8]u15 = undefined;
    for (&saved_rolls) |*roll| roll.* = state.combat.roll();
    try journey.restore(std.testing.io, allocator, directory.dir, &state);
    try state.beginEncounter(0);
    var reloaded_rolls: [8]u15 = undefined;
    for (&reloaded_rolls) |*roll| roll.* = state.combat.roll();
    try std.testing.expectEqualDeep(saved_rolls, reloaded_rolls);

    for (&members) |*member| {
        member.hp = 0;
        member.status = .unconscious;
    }
    state.combat.phase = .defeat;
    _ = state.tick(.{}, .{});
    try equal(.defeat, state.mode);
    confirm(&state);
    try equal(.battle, state.mode);
    var retried_rolls: [8]u15 = undefined;
    for (&retried_rolls) |*roll| roll.* = state.combat.roll();
    try std.testing.expectEqualDeep(reloaded_rolls, retried_rolls);
}

test "treasure stays closed with full bags, grants the exact source item once and persists after reload" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    state.combat.loadouts = @splat(.{});
    for (&members) |*member| for (&member.inventory.slots) |*slot| {
        slot.* = .{ .id = .medicine, .uses = 6 };
    };
    const room = state.package.roomIndex("vb6_forest_paths").?;
    const npc = state.package.rooms[room].npcs[0];
    for (state.package.interaction_offsets, 0..) |offset, facing| {
        const x = npc.x - offset.x;
        const y = npc.y - offset.y;
        if (!state.package.rooms[room].canStand(x, y)) continue;
        state.field_state.room = room;
        state.field_state.x = x;
        state.field_state.y = y;
        state.field_state.facing = @fromBackingInt(@as(u2, @intCast(facing)));
        break;
    }
    confirm(&state);
    try equal(.notice, state.menu.phase);
    try expect(!state.combat.progress.story.forest_treasure_needle);
    for (members) |member| try equal(@as(usize, 9), member.inventory.count());
    state.menu.phase = .closed;
    members[2].inventory.remove(0);
    confirm(&state);
    try expect(state.combat.progress.story.forest_treasure_needle);
    try equal(.needle, members[2].inventory.slots[8].?.id);
    try equal(@as(u16, 4), members[2].inventory.slots[8].?.uses);
    try settle(&state);
    confirm(&state);
    try equal(@as(?field.Dialogue, null), state.field_state.dialogue);
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try journey.save(std.testing.io, allocator, directory.dir, state);
    state.combat.progress.story.forest_treasure_needle = false;
    members[2].inventory.remove(8);
    try journey.restore(std.testing.io, allocator, directory.dir, &state);
    confirm(&state);
    try equal(@as(?field.Dialogue, null), state.field_state.dialogue);
    try equal(.needle, members[2].inventory.slots[8].?.id);
}

test "source enemy policy honors formation, excludes KO and remains usable after the front falls" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    try state.combat.swapFormation(0, 3);
    for (0..128) |_| {
        const target = state.combat.chooseEnemyTarget(0).?;
        try equal(.front, state.combat.partyRow(target));
        try expect(target != 0);
    }
    for (0..3) |slot| {
        const member = state.combat.formation[slot];
        members[member].hp = 0;
        members[member].status = .unconscious;
    }
    state.combat.encounter = 2;
    try equal(@as(?usize, null), state.combat.chooseEnemyTarget(1));
    try equal(@as(?usize, null), state.combat.chooseEnemyTarget(0));
    state.combat.promoteRearMembers();
    for (0..32) |_| {
        const target = state.combat.chooseEnemyTarget(0).?;
        try expect(members[target].hp > 0);
        try equal(.front, state.combat.partyRow(target));
    }
}

test "forest scenery advances at exported frame boundaries while field menus pause its clock" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    const room = fixtures.package.value.rooms[fixtures.package.value.roomIndex("vb6_forest_crossing").?];
    var animated: usize = 0;
    for (room.draws) |piece| {
        if (piece.frames.len == 0) continue;
        animated += 1;
        try equal(@as(usize, 4), piece.frames.len);
        for ([_]u32{ 0, 7, 8, 15, 16, 23, 24, 31, 32, 0xFFFFFFFF }) |tick| {
            const expected = piece.frames[(tick % 32) / 8];
            const actual = piece.sample(tick);
            try std.testing.expectEqualDeep(expected.rect, actual.rect);
            try equal(expected.x, actual.x);
            try equal(expected.y, actual.y);
        }
    }
    try expect(animated > 0);
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    _ = state.tick(.{ .menu = true }, .{});
    const before = state.field_state.scene_ticks;
    for (0..60) |_| _ = state.tick(.{}, .{});
    try equal(before, state.field_state.scene_ticks);
}

test "Fisherman recovery restricts Attack, Rune and Unite for one following round while Item and Defend remain available" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    try state.beginEncounter(0);
    const combat = state.combat;
    combat.actions = @splat(.defend);
    combat.actions[5] = null;
    combat.choose(4);
    combat.queue(.{ .unite = 2 });
    combat.base_stats[4].speed = 999;
    combat.phase = .resolving;
    combat.tick(.{});
    try equal(.unite, combat.active.?.kind);
    combat.action_ticks = combat.impactTick() - 1;
    combat.tick(.{});
    while (combat.active != null) combat.tick(.{});
    try equal(@as(u8, 2), combat.unbalanced[4]);
    try equal(@as(u8, 2), combat.unbalanced[5]);
    for (0..20000) |_| {
        if (combat.phase != .resolving) break;
        combat.tick(.{});
    }
    try equal(.battle_menu, combat.phase);
    try equal(@as(u8, 1), combat.unbalanced[4]);
    try expect(!combat.canAttackTarget(4, 0));
    try expect(!combat.canCast(4, spellIndex(combat.*, "spell_13")));
    try expect(!combat.canUnite(4));
    combat.choose(4);
    try equal(.defend, combat.picker.selected);
    try expect(combat.progress.party[4].inventory.count() > 0);
    members[4].hp = 1;
    castNow(combat, 1, spellIndex(combat.*, "spell_11"), 4);
    try equal(members[4].max_hp, members[4].hp);
    try equal(@as(u8, 1), combat.unbalanced[4]);
    combat.active = null;
    combat.actions = @splat(.defend);
    combat.acted = @splat(false);
    combat.phase = .resolving;
    for (0..20000) |_| {
        if (combat.phase != .resolving) break;
        combat.tick(.{});
    }
    try equal(.battle_menu, combat.phase);
    try equal(@as(u8, 0), combat.unbalanced[4]);
    try equal(@as(u8, 0), combat.unbalanced[5]);
    try expect(combat.canCast(4, spellIndex(combat.*, "spell_13")));
    try expect(combat.canUnite(4));
}

test "expanded damage magic resolves each source element and consumes the owning rune tier once" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    const state = try fixtures.session(&members);
    const combat = state.combat;
    const cases = .{
        .{ "fire", "spell_3", @as(u16, 400), true },
        .{ "fire", "spell_4", @as(u16, 700), true },
        .{ "wind", "spell_14", @as(u16, 400), false },
        .{ "wind", "spell_16", @as(u16, 500), true },
        .{ "lightning", "spell_17", @as(u16, 150), false },
        .{ "lightning", "spell_18", @as(u16, 100), true },
        .{ "lightning", "spell_19", @as(u16, 600), false },
        .{ "lightning", "spell_20", @as(u16, 1000), false },
        .{ "earth", "spell_22", @as(u16, 300), true },
        .{ "earth", "spell_24", @as(u16, 700), true },
    };
    inline for (cases) |row| {
        combat.encounter = 0;
        combat.startEncounter();
        combat.base_stats[0].magic = 255;
        combat.runes[0] = combat.content.systems.?.runeIndex(row[0]).?;
        combat.refillMagic(0);
        const spell = spellIndex(combat.*, row[1]);
        const tier = combat.spellTier(0, spell).?;
        const charge = members[0].rune_charges[tier];
        combat.enemy_hp = @splat(5000);
        castNow(combat, 0, spell, combat.partyCount());
        const expected = battle.systems.elementalDamage(row[2], combat.stats(0).magic, combat.enemyAffinity(0, combat.content.systems.?.spells[spell].element.?));
        try equal(expected, combat.active.?.amounts[combat.partyCount()]);
        try equal(charge - 1, members[0].rune_charges[tier]);
        try equal(row[3], combat.content.systems.?.spells[spell].group);
        const hp = combat.enemy_hp;
        combat.tick(.{});
        try equal(hp, combat.enemy_hp);
        try equal(charge - 1, members[0].rune_charges[tier]);
        try std.testing.expectError(error.InvalidSpell, combat.castFieldSpell(0, spell, 1));
    }
}

test "Rain of Kindness heals living allies by300 with cures while preserving recovery and knockouts" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    const state = try fixtures.session(&members);
    const combat = state.combat;
    combat.runes[1] = combat.content.systems.?.runeIndex("flowing").?;
    combat.refillMagic(1);
    for (&members, 0..) |*member, i| {
        member.hp = if (i == 2) 0 else 1;
        member.status = if (i == 2) .unconscious else .poisoned;
        member.balloons = if (i == 2) 0 else 2;
    }
    combat.unbalanced[0] = 1;
    combat.actor_conditions[0].sleep_turns = 1;
    const before = members[1].rune_charges[2];
    try combat.castFieldSpell(1, spellIndex(combat.*, "spell_12"), 0);
    for (members, 0..) |member, i| {
        try equal(if (i == 2) @as(u16, 0) else @min(member.max_hp, 301), member.hp);
        try equal(if (i == 2) field.game_state.Status.unconscious else field.game_state.Status.healthy, member.status);
        try equal(@as(u8, 0), member.balloons);
    }
    try equal(@as(u8, 0), combat.actor_conditions[0].sleep_turns);
    try equal(@as(u8, 1), combat.unbalanced[0]);
    try equal(before - 1, members[1].rune_charges[2]);
}

test "journey backup recovers damaged or missing primary and never replaces a good backup with corruption" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    state.field_state.progress.money = 1500;
    state.combat.progress.money = 1500;
    try journey.save(io, allocator, temp.dir, state);
    state.field_state.progress.money = 1700;
    state.combat.progress.money = 1700;
    try journey.save(io, allocator, temp.dir, state);
    try equal(journey.RestoreSource.primary, try journey.restoreWithSource(io, allocator, temp.dir, &state));
    try equal(@as(u32, 1700), state.combat.progress.money);
    var malformed = try journey.Snapshot.capture(state);
    malformed.party_count = 1;
    std.mem.swap(u8, &malformed.formation[0], &malformed.formation[5]);
    const bytes = try std.json.Stringify.valueAlloc(allocator, malformed, .{});
    defer allocator.free(bytes);
    try temp.dir.writeFile(io, .{ .sub_path = journey.filename, .data = bytes });
    try equal(.backup, journey.summaries(io, allocator, temp.dir, state)[0].status);
    try equal(journey.RestoreSource.backup, try journey.restoreWithSource(io, allocator, temp.dir, &state));
    try equal(@as(u32, 1500), state.combat.progress.money);
    // Saving after recovery preserves the good backup, rather than copying the corrupt primary.
    try journey.save(io, allocator, temp.dir, state);
    try temp.dir.deleteFile(io, journey.filename);
    try equal(journey.RestoreSource.backup, try journey.restoreWithSource(io, allocator, temp.dir, &state));
    try equal(@as(u32, 1500), state.combat.progress.money);
    try temp.dir.writeFile(io, .{ .sub_path = journey.backup_filename, .data = "invalid" });
    const before = try journey.Snapshot.capture(state);
    try equal(.damaged, journey.summaries(io, allocator, temp.dir, state)[0].status);
    try std.testing.expectError(error.SyntaxError, journey.restore(io, allocator, temp.dir, &state));
    try std.testing.expectEqualDeep(before, try journey.Snapshot.capture(state));
}

test "journey backup replacement failure preserves primary and future schemas cannot be overwritten" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    try journey.save(io, allocator, temp.dir, state);
    const old = try temp.dir.readFileAlloc(io, journey.filename, allocator, .limited(65536));
    defer allocator.free(old);
    try temp.dir.createDir(io, journey.backup_filename, .default_dir);
    if (journey.save(io, allocator, temp.dir, state)) |_| return error.ExpectedWriteFailure else |_| {}
    const kept = try temp.dir.readFileAlloc(io, journey.filename, allocator, .limited(65536));
    defer allocator.free(kept);
    try std.testing.expectEqualStrings(old, kept);
    var future = try journey.Snapshot.capture(state);
    future.schema = "suikoden-journey-save/179";
    const bytes = try std.json.Stringify.valueAlloc(allocator, future, .{});
    defer allocator.free(bytes);
    try temp.dir.writeFile(io, .{ .sub_path = journey.filename, .data = bytes });
    try std.testing.expectError(error.UnsupportedSaveVersion, journey.save(io, allocator, temp.dir, state));
    try std.testing.expectError(error.UnsupportedSaveVersion, journey.restore(io, allocator, temp.dir, &state));
    try temp.dir.writeFile(io, .{ .sub_path = journey.filename, .data = "{\"schema\":\"suikoden-journey-save/179\",\"future_state\":true}" });
    try std.testing.expectError(error.UnsupportedSaveVersion, journey.save(io, allocator, temp.dir, state));
    try std.testing.expectError(error.UnsupportedSaveVersion, journey.restore(io, allocator, temp.dir, &state));

    try temp.dir.deleteDir(io, journey.backup_filename);
    var shared = try journey.Snapshot.capture(state);
    shared.shared_items = @splat(null);
    shared.shared_items.?[0] = "fire_crystal";
    const keyed = try std.json.Stringify.valueAlloc(allocator, shared, .{});
    defer allocator.free(keyed);
    const names = [_][]const u8{ journey.filename, journey.backup_filename };
    for (0..names.len) |protected| {
        for (names, 0..) |name, index| try temp.dir.writeFile(io, .{ .sub_path = name, .data = if (index == protected) keyed else old });
        try std.testing.expectError(error.MissingSharedItemCatalogue, journey.save(io, allocator, temp.dir, state));
        for (names, 0..) |name, index| {
            const saved = try temp.dir.readFileAlloc(io, name, allocator, .limited(65536));
            defer allocator.free(saved);
            try std.testing.expectEqualStrings(if (index == protected) keyed else old, saved);
        }
    }
}

test "Setup persists independently and campaign restoration preserves current preferences" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    const settings = @import("pause_menu").settings;
    state.menu.phase = .root;
    state.menu.selected = .setup;
    confirm(&state);
    try equal(.setup, state.menu.phase);
    try equal(@import("pause_menu").Effect.settings_changed, state.tick(.{ .left = true }, .{}));
    try equal(@as(u8, 7), state.menu.preferences.music);
    _ = state.tick(.{ .field = .{ .menu_direction = .down } }, .{});
    _ = state.tick(.{ .right = true }, .{});
    try equal(@as(u8, 9), state.menu.preferences.effects);
    try settings.write(io, allocator, temp.dir, state.menu.preferences);
    const loaded = try settings.read(io, allocator, temp.dir);
    try equal(@as(f32, 0.7), loaded.musicVolume());
    try equal(@as(f32, 0.9), loaded.effectsVolume());
    for (0..20) |_| state.menu.preferences.adjust(0, false);
    try equal(@as(u8, 0), state.menu.preferences.music);
    for (0..20) |_| state.menu.preferences.adjust(1, true);
    try equal(@as(u8, 10), state.menu.preferences.effects);
    state.menu.preferences.adjust(2, true);
    state.menu.preferences.adjust(3, true);
    try expect(state.menu.preferences.fullscreen);
    try expect(!state.menu.preferences.vsync);
    const before = state.menu.preferences;
    state.menu.phase = .closed;
    const campaign = try journey.Snapshot.capture(state);
    try campaign.apply(&state);
    try std.testing.expectEqualDeep(before, state.menu.preferences);
    var bad = loaded;
    bad.music = 11;
    try std.testing.expectError(error.InvalidVolume, settings.write(io, allocator, temp.dir, bad));
    const retained = try settings.read(io, allocator, temp.dir);
    try equal(loaded.music, retained.music);
    try temp.dir.writeFile(io, .{ .sub_path = settings.filename, .data = "{" });
    try std.testing.expectError(error.ParseZon, settings.read(io, allocator, temp.dir));
}

test "controller neutral gate, edges, repeat and disconnect keep navigation predictable" {
    const controller = @import("pause_menu").controller;
    var input = controller.State{};
    try equal(controller.Output{}, input.update(.{ .connected = true, .confirm = true, .x = 0.9 }, 1.0 / 60.0));
    try expect(!input.ready);
    _ = input.update(.{ .connected = true }, 1.0 / 60.0);
    try expect(input.ready);
    var result = input.update(.{ .connected = true, .confirm = true, .dpad = .down }, 1.0 / 60.0);
    try expect(result.confirm);
    try equal(@as(?field.Direction, .down), result.navigation);
    result = input.update(.{ .connected = true, .confirm = true, .dpad = .down }, 0.1);
    try expect(!result.confirm);
    try equal(@as(?field.Direction, null), result.navigation);
    for (0..3) |_| result = input.update(.{ .connected = true, .dpad = .down }, 0.1);
    try equal(@as(?field.Direction, .down), result.navigation);
    try equal(@as(?field.Direction, .down), result.direction);
    result = input.update(.{}, 0.1);
    try equal(controller.Output{}, result);
    try expect(!input.ready);
    try equal(controller.Output{}, input.update(.{ .connected = true, .menu = true }, 0.1));
    _ = input.update(.{ .connected = true }, 0.1);
    result = input.update(.{ .connected = true, .cancel = true, .menu = true, .x = -0.8, .y = 0.2 }, 0.01);
    try expect(result.cancel and result.menu);
    try equal(@as(?field.Direction, .left), result.direction);
    result = input.update(.{ .connected = true, .x = std.math.nan(f32), .y = 0.29 }, std.math.nan(f32));
    try equal(@as(?field.Direction, null), result.direction);
    result = input.update(.{ .connected = true, .x = 0.4, .y = -0.9 }, 0.01);
    try equal(@as(?field.Direction, .up), result.navigation);
}

test "controller outputs drive the connected field, Setup and battle command menu" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    var controller = @import("pause_menu").controller.State{};
    _ = controller.update(.{ .connected = true }, 0.01);
    var pad = controller.update(.{ .connected = true, .menu = true }, 0.01);
    _ = state.tick(.{ .menu = pad.menu }, .{});
    try equal(.root, state.menu.phase);
    state.menu.selected = .setup;
    pad = controller.update(.{ .connected = true, .confirm = true }, 0.01);
    _ = state.tick(.{ .field = .{ .action = pad.confirm } }, .{});
    try equal(.setup, state.menu.phase);
    state.menu.phase = .closed;
    try state.beginEncounter(0);
    _ = controller.update(.{ .connected = true }, 0.01);
    pad = controller.update(.{ .connected = true, .confirm = true }, 0.01);
    _ = state.tick(.{}, .{ .confirm = pad.confirm });
    try equal(.command, state.combat.phase);
}

test "native poison costs five percent at one battle boundary and a cure prevents the next tick" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    const combat = state.combat;
    try state.beginEncounter(0);
    members[1].hp = 1;
    members[1].status = .poisoned;
    members[0].status = .poisoned;
    const before = members[0].hp;
    combat.phase = .resolving;
    combat.active = null;
    combat.acted = @splat(true);
    combat.tick(.{});
    try equal(before - members[0].max_hp / 20, members[0].hp);
    try equal(@as(u16, 0), members[1].hp);
    try equal(field.game_state.Status.unconscious, members[1].status);
    const after = members[0].hp;
    combat.tick(.{});
    try equal(after, members[0].hp);
    members[0].inventory.slots[0] = .{ .id = .antitoxin, .uses = 4 };
    try combat.progress.useItem(combat.rules, 0, 0, 0);
    combat.phase = .resolving;
    combat.active = null;
    combat.acted = @splat(true);
    combat.tick(.{});
    try equal(after, members[0].hp);
    try equal(@as(u16, 0), battle.systems.battlePoison(19));
    try equal(battle.systems.FieldPoison{ .cured = false, .damage = 0 }, battle.systems.fieldPoison(20, 100, 255));
    try equal(battle.systems.FieldPoison{ .cured = true, .damage = 0 }, battle.systems.fieldPoison(100, 100, 0));
}

test "room movement encounters charge actual movement and use ordered draws through battle return" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var package = fixtures.package.value;
    const rooms = try allocator.dupe(field.Room, package.rooms);
    defer allocator.free(rooms);
    package.rooms = rooms;
    package.step_ticks = 2;
    const room = &rooms[package.roomIndex(package.start_room).?];
    room.exits = &.{};
    room.events = &.{};
    const direction: field.Direction = if (room.canStand(package.start_x + 8, package.start_y)) .right else .left;
    const back: field.Direction = if (direction == .right) .left else .right;

    var data = fixtures.data.value;
    data.field_encounters = .{
        .schema = "suikoden-field-movement-encounters/2",
        .suppress_when = .{ .kind = .story_mask_set, .flag = .{ .id = "scenario_0001", .mask = 1 } },
        .rooms = &.{.{
            .room = room.id,
            .rate = 2,
            .counter_threshold = 2,
            .candidates = &.{
                .{ .id = "area_a_1", .enemy_level_sum = 5 },
                .{ .id = "area_a_2", .enemy_level_sum = 15 },
            },
        }},
    };
    const bytes = try std.json.Stringify.valueAlloc(allocator, data, .{});
    defer allocator.free(bytes);
    const admitted = try journey.load(allocator, bytes, package, fixtures.content.value);
    defer admitted.deinit();
    var members: [6]battle.Member = undefined;
    var state = try journey.State.initEpisode(package, admitted.value, fixtures.content.value, fixtures.items.value, fixtures.inn.value, &members, try fixtures.combat_storage.allocator().create(battle.State));
    state.combat.random = std.Random.DefaultPrng.init(17);
    var after_rate_miss = state.combat.random;
    try equal(@as(u15, 24127), after_rate_miss.random().int(u15));

    const move = struct {
        fn step(s: *journey.State, heading: field.Direction) !void {
            _ = try s.tickWithFieldEvents(.{ .field = .{ .direction = heading } }, .{});
            try equal(@as(u16, 1), s.field_state.remaining);
            _ = try s.tickWithFieldEvents(.{}, .{});
            try equal(@as(u16, 0), s.field_state.remaining);
            try equal(.field, s.mode);
        }
    }.step;
    const initial_random = state.combat.random;
    for (0..4) |_| _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqualDeep(initial_random, state.combat.random);
    try move(&state, direction);
    try equal(@as(u16, 2), state.field_encounter_clock.updates);
    _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqualDeep(initial_random, state.combat.random);
    try move(&state, back);
    try equal(@as(u16, 4), state.field_encounter_clock.updates);
    _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqualDeep(after_rate_miss, state.combat.random);
    _ = try state.tickWithFieldEvents(.{}, .{});
    try std.testing.expectEqualDeep(after_rate_miss, state.combat.random);

    const pass_seed = std.Random.DefaultPrng.init(181);
    var after_selection = pass_seed;
    try equal(@as(u15, 32593), after_selection.random().int(u15));
    try equal(@as(u15, 30100), after_selection.random().int(u15));
    state.combat.random = pass_seed;
    const original_rune = state.combat.runes[0];
    const original_level = state.combat.levels[0];
    state.combat.runes[0] = state.combat.content.systems.?.runeIndex("champion's").?;
    state.combat.levels[0] = 99;
    try move(&state, direction);
    _ = try state.tickWithFieldEvents(.{}, .{});
    try equal(.field, state.mode);
    try std.testing.expectEqualDeep(after_selection, state.combat.random);
    state.combat.runes[0] = original_rune;
    state.combat.levels[0] = original_level;

    state.combat.random = pass_seed;
    try move(&state, back);
    state.menu.phase = .root;
    _ = try state.tickWithFieldEvents(.{}, .{});
    try expect(state.field_encounter_clock.ready);
    try std.testing.expectEqualDeep(pass_seed, state.combat.random);
    var saves = std.testing.tmpDir(.{});
    defer saves.cleanup();
    const saved_clock = state.field_encounter_clock;
    try journey.save(std.testing.io, allocator, saves.dir, state);
    state = try journey.State.initEpisode(package, admitted.value, fixtures.content.value, fixtures.items.value, fixtures.inn.value, &members, try fixtures.combat_storage.allocator().create(battle.State));
    try journey.restore(std.testing.io, allocator, saves.dir, &state);
    try std.testing.expectEqualDeep(saved_clock, state.field_encounter_clock);
    try std.testing.expectEqualDeep(pass_seed, state.combat.random);
    state.extras[0].member_id = "mismatched_member";
    _ = try state.tickWithFieldEvents(.{}, .{});
    try equal(.field, state.mode);
    try equal(.notice, state.menu.phase);
    try expect(!state.field_encounter_clock.ready);
    try std.testing.expectEqualDeep(pass_seed, state.combat.random);
    state.extras[0].member_id = "";
    _ = try state.tickWithFieldEvents(.{ .field = .{ .action = true } }, .{});
    _ = try state.tickWithFieldEvents(.{ .field = .{ .cancel = true } }, .{});
    try move(&state, direction);
    const return_x = state.field_state.x;
    _ = try state.tickWithFieldEvents(.{}, .{});
    try equal(.battle, state.mode);
    try std.testing.expectEqualStrings("area_a_2", state.combat.content.encounters[state.combat.encounter].id);
    try expect(state.encounter_trigger == null);
    try std.testing.expectEqualDeep(after_selection, state.checkpoint.?.random);
    const field_scene_ticks = state.field_state.scene_ticks;
    const field_movement_updates = state.field_state.movement_updates;
    state.mode = .defeat;
    _ = try state.tickWithFieldEvents(.{}, .{ .confirm = true });
    try equal(.battle, state.mode);
    try std.testing.expectEqualStrings("area_a_2", state.combat.content.encounters[state.combat.encounter].id);
    try std.testing.expectEqualDeep(after_selection, state.combat.random);
    try equal(field_scene_ticks, state.field_state.scene_ticks);
    try equal(field_movement_updates, state.field_state.movement_updates);
    state.combat.phase = .escaped;
    _ = try state.tickWithFieldEvents(.{}, .{ .confirm = true });
    try equal(.field, state.mode);
    try expect(state.checkpoint == null);
    try equal(@as(u16, 0), state.field_encounter_clock.updates);
    try expect(!state.field_encounter_clock.ready);
    try equal(return_x, state.field_state.x);
    try equal(package.start_y, state.field_state.y);
    try journey.save(std.testing.io, allocator, saves.dir, state);
    state = try journey.State.initEpisode(package, admitted.value, fixtures.content.value, fixtures.items.value, fixtures.inn.value, &members, try fixtures.combat_storage.allocator().create(battle.State));
    try journey.restore(std.testing.io, allocator, saves.dir, &state);
    try equal(return_x, state.field_state.x);
    try equal(package.start_y, state.field_state.y);
    try expect(!state.field_encounter_clock.ready);
    try std.testing.expectEqualDeep(after_selection, state.combat.random);

    var suppressed = try journey.Snapshot.capture(state);
    suppressed.schema = "suikoden-journey-save/21";
    suppressed.auxiliary_party = null;
    suppressed.field_encounter_clock = null;
    suppressed.story.scenario = .{};
    suppressed.story.scenario.?.scenario[1] = 1;
    suppressed.random = pass_seed;
    try suppressed.apply(&state);
    state.combat.progress.story.scenario.?.scenario[1] = 0;
    const reopened = try journey.Snapshot.capture(state);
    try reopened.apply(&state);
    try move(&state, back);
    try move(&state, direction);
    _ = try state.tickWithFieldEvents(.{}, .{});
    try equal(.field, state.mode);
    try std.testing.expectEqualDeep(pass_seed, state.combat.random);
}

test "field poison advances on every moving update and settings survive battle return" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    members[0].status = .poisoned;
    members[0].balloons = 2;
    var expected_members = members;
    var expected = state.combat.*;
    expected.progress.party = &expected_members;
    for (0..20) |_| _ = state.tick(.{}, .{});
    try equal(members[0].max_hp, members[0].hp);
    const room = state.package.rooms[state.field_state.room];
    var movement: ?field.Direction = null;
    for ([_]field.Direction{ .up, .down, .left, .right }) |direction_value| {
        const x = state.field_state.x + @as(i32, if (direction_value == .left) -8 else if (direction_value == .right) 8 else 0);
        const y = state.field_state.y + @as(i32, if (direction_value == .up) -8 else if (direction_value == .down) 8 else 0);
        if (room.canStand(x, y)) {
            movement = direction_value;
            break;
        }
    }
    try expect(movement != null);
    _ = state.tick(.{ .field = .{ .direction = movement } }, .{});
    expected.applyFieldStatuses();
    try equal(expected_members[0].hp, members[0].hp);
    try std.testing.expectEqualDeep(expected.random, state.combat.random);
    for (1..state.package.step_ticks) |_| {
        _ = state.tick(.{}, .{});
        expected.applyFieldStatuses();
        try equal(expected_members[0].hp, members[0].hp);
        try equal(expected_members[0].status, members[0].status);
        try std.testing.expectEqualDeep(expected.random, state.combat.random);
    }
    for (0..20) |_| _ = state.tick(.{}, .{});
    try equal(expected_members[0].hp, members[0].hp);
    try equal(expected_members[0].status, members[0].status);
    try equal(@as(u8, 2), members[0].balloons);
    try std.testing.expectEqualDeep(expected.random, state.combat.random);
    state.menu.preferences.music = 3;
    state.menu.preferences.effects = 5;
    try state.beginEncounter(0);
    try finishBattle(&state);
    try equal(@as(u8, 3), state.menu.preferences.music);
    try equal(@as(u8, 5), state.menu.preferences.effects);
}

test "field poison agrees with original consumers including nonlethal thresholds and zero HP" {
    const Vector = struct { maximum: u16, hp: u16, roll: u15, result_hp: u16, poisoned: bool, draws: usize };
    const rows = try std.json.parseFromSlice([]const Vector, allocator, @embedFile("fixtures/field_poison.json"), .{});
    defer rows.deinit();
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    for (rows.value) |row| {
        var members: [6]battle.Member = undefined;
        var state = try fixtures.session(&members);
        members[0].max_hp = row.maximum;
        members[0].hp = row.hp;
        members[0].status = .poisoned;
        const others = members[1..].*;
        var draws: battle.systems.Draws = .{ .values = &.{row.roll} };
        state.combat.replay_draws = &draws;
        state.combat.applyFieldStatuses();
        state.combat.replay_draws = null;
        try equal(row.result_hp, members[0].hp);
        try equal(row.poisoned, members[0].status == .poisoned);
        try equal(row.draws, draws.cursor);
        try std.testing.expectEqualDeep(others, members[1..].*);
    }
}

test "idle blocked and paused movement preserve poison draws and save restores the next moving update" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    members[0].status = .poisoned;
    members[0].balloons = 2;
    state.field_state.x = 0;
    state.field_state.y = 0;
    state.field_state.destination = .{ .x = 0, .y = 0 };
    const random = state.combat.random;
    const owned = members;
    for (0..8) |_| _ = state.tick(.{ .field = .{ .direction = .left } }, .{});
    try equal(@as(u64, 0), state.field_state.movement_updates);
    try std.testing.expectEqualDeep(owned, members);
    try std.testing.expectEqualDeep(random, state.combat.random);
    // Pause in the middle of an existing step; remaining interpolation is not a moving update.
    state.field_state.remaining = 2;
    state.field_state.destination = .{ .x = 8, .y = 0 };
    state.menu.phase = .root;
    for (0..8) |_| _ = state.tick(.{}, .{});
    try equal(@as(u16, 2), state.field_state.remaining);
    try equal(@as(u64, 0), state.field_state.movement_updates);
    try std.testing.expectEqualDeep(owned, members);
    try std.testing.expectEqualDeep(random, state.combat.random);
    state = try fixtures.session(&members);
    members[0].status = .poisoned;
    const snapshot = try journey.Snapshot.capture(state);
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try journey.save(std.testing.io, allocator, directory.dir, state);
    members[0].hp = 1;
    members[0].status = .healthy;
    try journey.restore(std.testing.io, allocator, directory.dir, &state);
    try std.testing.expectEqualDeep(snapshot, try journey.Snapshot.capture(state));
    // Snapshot application is the same validated state boundary used by disk restore.
    try snapshot.apply(&state);
    const saved_random = state.combat.random;
    const hp = members[0].hp;
    const room = state.package.rooms[state.field_state.room];
    const direction: field.Direction = if (room.canStand(state.field_state.x, state.field_state.y - 8)) .up else .down;
    _ = state.tick(.{ .field = .{ .direction = direction } }, .{});
    try equal(@as(u64, 1), state.field_state.movement_updates);
    try expect(members[0].hp <= hp);
    try expect(!std.meta.eql(saved_random, state.combat.random));
}

test "Fog and Clay scale additive bonuses and Copper Flesh preserves unrelated effects" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    const combat = state.combat;
    try state.beginEncounter(0);
    combat.runes[1] = combat.content.systems.?.runeIndex("water").?;
    combat.refillMagic(1);
    combat.actor_conditions[6].stat_modifiers.skill_bonus = 100;
    const base_skill = combat.stats(6).skill - 100;
    castNow(combat, 1, spellIndex(combat.*, "spell_10"), 6);
    try equal(@as(i16, 80), combat.actor_conditions[6].stat_modifiers.skill_bonus);
    try equal(base_skill + 80, combat.stats(6).skill);
    castNow(combat, 1, spellIndex(combat.*, "spell_10"), 6);
    try equal(@as(i16, 64), combat.actor_conditions[6].stat_modifiers.skill_bonus);
    combat.runes[1] = combat.content.systems.?.runeIndex("earth").?;
    combat.refillMagic(1);
    combat.actor_conditions[0].stat_modifiers.defense_bonus = 100;
    const defense = combat.stats(0).defense - 100;
    castNow(combat, 1, spellIndex(combat.*, "spell_21"), 0);
    try equal(@as(i16, 150), combat.actor_conditions[0].stat_modifiers.defense_bonus);
    try equal(defense + 150, combat.stats(0).defense);
    members[0].status = .poisoned;
    members[0].balloons = 2;
    combat.unbalanced[0] = 1;
    castNow(combat, 1, spellIndex(combat.*, "spell_23"), 0);
    try equal(@as(u8, 3), combat.actor_conditions[0].protection_rounds);
    try equal(field.game_state.Status.poisoned, members[0].status);
    try equal(@as(u8, 2), members[0].balloons);
    try equal(@as(u8, 1), combat.unbalanced[0]);
    const hp = members[0].hp;
    combat.active = .{ .actor = 6, .target = 0, .kind = .attack, .amount = 50 };
    combat.action_ticks = combat.impactTick() - 1;
    combat.tick(.{});
    try equal(hp, members[0].hp);
    try equal(@as(u32, 0), combat.active.?.amount);
    for ([_]u8{ 2, 1, 0 }) |rounds| {
        combat.phase = .resolving;
        combat.active = null;
        combat.acted = @splat(true);
        combat.tick(.{});
        try equal(rounds, combat.actor_conditions[0].protection_rounds);
    }
    combat.startEncounter();
    try equal(@as(i16, 0), combat.actor_conditions[0].stat_modifiers.defense_bonus);
    try equal(@as(i16, 0), combat.actor_conditions[6].stat_modifiers.skill_bonus);
}

test "Copper Flesh blocks healing HP changes and leaves cures and item consumption intact" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    const combat = state.combat;
    try state.beginEncounter(0);
    members[0].hp = 10;
    members[0].status = .poisoned;
    members[0].balloons = 1;
    combat.actor_conditions[0].protection_rounds = 3;
    combat.runes[1] = combat.content.systems.?.runeIndex("water").?;
    combat.refillMagic(1);
    castNow(combat, 1, spellIndex(combat.*, "spell_9"), 0);
    try equal(@as(u16, 10), members[0].hp);
    try equal(field.game_state.Status.healthy, members[0].status);
    try equal(@as(u8, 0), members[0].balloons);
    try equal(@as(u8, 3), combat.actor_conditions[0].protection_rounds);
    var expected = members[1].inventory;
    expected.slots[0].?.uses -= 1;
    combat.actions[1] = .{ .item = .{ .slot = 0, .target = 0, .id = .medicine } };
    combat.active = .{ .actor = 1, .target = 0, .kind = .item, .item_id = .medicine };
    combat.action_ticks = combat.impactTick() - 1;
    combat.tick(.{});
    try equal(.item, combat.active.?.kind);
    try std.testing.expectEqualDeep(expected, members[1].inventory);
    try equal(@as(u16, 10), members[0].hp);
}

test "round end promotes living rear identities into front vacancies and short weapons follow the new rows" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    const combat = state.combat;
    try state.beginEncounter(0);
    const hero_inventory = members[0].inventory;
    try equal(.back, combat.partyRow(3));
    try expect(!combat.canAttackTarget(3, 0));
    members[0].hp = 0;
    members[0].status = .unconscious;
    combat.phase = .resolving;
    combat.active = null;
    combat.acted = @splat(true);
    combat.tick(.{});
    try equal(.front, combat.partyRow(3));
    try equal(.back, combat.partyRow(0));
    try expect(combat.canAttackTarget(3, 0));
    try std.testing.expectEqualDeep(hero_inventory, members[0].inventory);
    try std.testing.expectEqualStrings("viktor", members[3].id);
    members[0].hp = 1;
    members[0].status = .healthy;
    // Revival preserves the occupied front slot rather than pushing another member out.
    combat.promoteRearMembers();
    try equal(.back, combat.partyRow(0));
    state.mode = .field;
    combat.phase = .battle_menu;
    const saved = try journey.Snapshot.capture(state);
    combat.formation = .{ 0, 1, 2, 3, 4, 5 };
    try saved.apply(&state);
    try equal(.front, state.combat.partyRow(3));
    try equal(.back, state.combat.partyRow(0));
}

test "front promotion handles every KO mask without duplicating identities or moving conscious front members" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    for (0..64) |mask| {
        state.combat.formation = .{ 0, 1, 2, 3, 4, 5 };
        for (&members, 0..) |*member, i| {
            member.hp = if (mask & (@as(usize, 1) << @intCast(i)) != 0) 0 else member.max_hp;
            member.status = if (member.hp == 0) .unconscious else .healthy;
        }
        state.combat.promoteRearMembers();
        var seen: u8 = 0;
        for (state.combat.formation) |member| seen |= @as(u8, 1) << @intCast(member);
        try equal(@as(u8, 63), seen);
        for (0..3) |i| if (members[i].hp > 0) try equal(.front, state.combat.partyRow(i));
        var vacancy = false;
        var rear_alive = false;
        for (0..6) |i| {
            vacancy = vacancy or (state.combat.partyRow(i) == .front and members[i].hp == 0);
            rear_alive = rear_alive or (state.combat.partyRow(i) == .back and members[i].hp > 0);
        }
        try expect(!vacancy or !rear_alive);
    }
}

test "Gale, Fortune, Sunbeam and stacked Prosperity use live rune ownership" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    const state = try fixtures.session(&members);
    const combat = state.combat;
    const rules = combat.content.systems.?;
    combat.runes[0] = null;
    const speed = combat.stats(0).speed;
    combat.runes[0] = rules.runeIndex("gale").?;
    try equal(speed * 2, combat.stats(0).speed);
    combat.runes[0] = null;
    const award = combat.experienceAward(0);
    combat.runes[0] = rules.runeIndex("fortune").?;
    try equal(award * 2, combat.experienceAward(0));
    members[0].hp = 0;
    try equal(@as(u32, 0), combat.experienceAward(0));
    members[0].hp = members[0].max_hp;
    combat.runes[0] = rules.runeIndex("sunbeam").?;
    members[0].status = .poisoned;
    combat.phase = .resolving;
    combat.active = null;
    combat.acted = @splat(true);
    const hp = members[0].hp;
    combat.tick(.{});
    try equal(hp + 5 - members[0].max_hp / 20, members[0].hp);
    members[0].status = .healthy;
    members[0].hp = 1;
    combat.phase = .resolving;
    combat.active = null;
    combat.acted = @splat(true);
    combat.tick(.{});
    try equal(@as(u16, 6), members[0].hp);
    combat.runes[0] = rules.runeIndex("prosperity").?;
    combat.runes[1] = rules.runeIndex("prosperity").?;
    members[1].hp = 0;
    members[1].status = .unconscious;
    var money: u32 = 0;
    for (0..combat.enemyCount()) |i| money += combat.enemy(i).money;
    const before = combat.progress.money;
    combat.enemy_hp = @splat(0);
    combat.phase = .resolving;
    combat.active = .{ .actor = 0, .target = combat.partyCount(), .kind = .defend };
    combat.action_ticks = combat.actionDuration() - 1;
    combat.tick(.{});
    try equal(money * 4, combat.reward_money);
    try equal(before + money * 4, combat.progress.money);
    try expect(!combat.hasMagic(0));
    try std.testing.expectEqualStrings("Passive: doubles battle money.", combat.runeHint(0));
}

test "passive round HP and unconscious Prosperity owner matrices retain source semantics" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    for ([_]u16{ 19, 100, 120, 999 }) |maximum| {
        for ([_]bool{ false, true }) |sunbeam| for ([_]bool{ false, true }) |poisoned| {
            for ([_]u16{ 1, maximum - 1, maximum }) |hp| for ([_]u8{ 0, 1, 2 }) |protection| {
                var members: [6]battle.Member = undefined;
                const state = try fixtures.session(&members);
                const combat = state.combat;
                combat.runes[0] = if (sunbeam) combat.content.systems.?.runeIndex("sunbeam").? else null;
                members[0].max_hp = maximum;
                members[0].hp = hp;
                members[0].status = if (poisoned) .poisoned else .healthy;
                combat.actor_conditions[0].protection_rounds = protection;
                combat.applyRoundBoundaryStatuses();
                const regeneration: i32 = if (sunbeam) 5 else 0;
                const poison: i32 = if (poisoned) maximum / 20 else 0;
                const expected: u16 = if (protection == 2) hp else @intCast(std.math.clamp(@as(i32, hp) + regeneration - poison, 0, maximum));
                try equal(expected, members[0].hp);
                try equal(protection -| 1, combat.actor_conditions[0].protection_rounds);
                try equal(expected == 0, members[0].status == .unconscious);
            };
        };
    }
    for (0..64) |mask| {
        var members: [6]battle.Member = undefined;
        const state = try fixtures.session(&members);
        const combat = state.combat;
        const rune = combat.content.systems.?.runeIndex("prosperity").?;
        var owners: u5 = 0;
        for (&members, 0..) |*member, i| {
            const owns = mask & (@as(usize, 1) << @intCast(i)) != 0;
            combat.runes[i] = if (owns) rune else null;
            owners += @intFromBool(owns);
            member.hp = 0;
            member.status = .unconscious;
        }
        var base_money: u32 = 0;
        for (0..combat.enemyCount()) |i| base_money += combat.enemy(i).money;
        combat.progress.money = 0;
        combat.commitRewards();
        try equal(base_money << owners, combat.reward_money);
        try equal(@min(field.game_state.max_money, combat.reward_money), combat.progress.money);
        for (combat.award_exp) |award| try equal(@as(u32, 0), award);
    }
}

test "the source forest exit reaches Kobold village and returns with party and saved room intact" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    try walkToRoom(&state, "vb6_kobold_village", 24, 176);
    try std.testing.expectEqualStrings("vb6_kobold_village", state.package.rooms[state.field_state.room].id);
    try equal(@as(usize, 0), state.package.rooms[state.field_state.room].npcs.len);
    const money = state.combat.progress.money;
    const levels = state.combat.levels;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try journey.save(std.testing.io, allocator, temp.dir, state);
    try walkToRoom(&state, "vb6_forest_clearing", 352, 144);
    try journey.restore(std.testing.io, allocator, temp.dir, &state);
    try std.testing.expectEqualStrings("vb6_kobold_village", state.package.rooms[state.field_state.room].id);
    try equal(money, state.combat.progress.money);
    try equal(levels, state.combat.levels);
    try walkToRoom(&state, "vb6_inn", 168, 192);
    try std.testing.expectEqualStrings("vb6_inn", state.package.rooms[state.field_state.room].id);
}

test "pause Rune management is reachable with no rune, preserves stock on cancel and returns to Rune page" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    state.menu.phase = .root;
    state.menu.selected = .rune;
    state.menu.member = 3;
    members[3].inventory.slots[members[3].inventory.count()] = .{ .id = .clone_crystal, .uses = 0 };
    const money = state.combat.progress.money;
    confirm(&state);
    try equal(.rune, state.menu.phase);
    try equal(@as(usize, 4), state.menu.slot);
    confirm(&state);
    try equal(.rune_service, state.menu.phase);
    try expect(state.menu.rune_from_menu);
    confirm(&state);
    try equal(.rune_attach, state.menu.phase);
    state.menu.slot = members[3].inventory.count() - 1;
    confirm(&state);
    try equal(.confirm_rune_attach, state.menu.phase);
    try expect(!state.menu.yes);
    confirm(&state);
    try equal(.rune_attach, state.menu.phase);
    try equal(@as(?usize, null), state.combat.runes[3]);
    confirm(&state);
    _ = state.tick(.{ .right = true }, .{});
    confirm(&state);
    try equal(state.combat.content.systems.?.runeIndex("clone"), state.combat.runes[3]);
    confirm(&state);
    try equal(.rune_service, state.menu.phase);
    _ = state.tick(.{ .field = .{ .cancel = true } }, .{});
    try equal(.rune, state.menu.phase);
    try equal(@as(usize, 4), state.menu.slot);
    try equal(money, state.combat.progress.money);
}

test "three named slots have independent backups and scene party playtime summaries" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    const names = [_][]const u8{ "Inn camp", "Forest Z X", "../Kobold" };
    for (names, 0..) |name, i| {
        state.combat.progress.money = @intCast(2000 + i);
        state.elapsed_ticks = @as(u64, @intCast(i + 1)) * 3600;
        try journey.saveSlot(io, allocator, temp.dir, state, i, try pause.save_slots.Label.init(name));
    }
    var summaries = journey.summaries(io, allocator, temp.dir, state);
    for (summaries, 0..) |entry, i| {
        try equal(.ready, entry.status);
        try std.testing.expectEqualStrings(names[i], entry.name.text());
        try std.testing.expectEqualStrings(state.package.rooms[state.field_state.room].title, entry.scene);
        try std.testing.expectEqualStrings("Hero", entry.leader);
        try equal(@as(u64, @intCast((i + 1) * 60)), entry.seconds);
        try equal(journey.RestoreSource.primary, try journey.restoreSlotWithSource(io, allocator, temp.dir, &state, i));
        try equal(@as(u32, @intCast(2000 + i)), state.combat.progress.money);
        try std.testing.expectEqualStrings(names[i], state.save_name.text());
    }
    state.combat.progress.money = 5000;
    try journey.saveSlot(io, allocator, temp.dir, state, 1, try pause.save_slots.Label.init("Second visit"));
    try temp.dir.writeFile(io, .{ .sub_path = try journey.slotFilename(1, false), .data = "{" });
    summaries = journey.summaries(io, allocator, temp.dir, state);
    try equal(.backup, summaries[1].status);
    try std.testing.expectEqualStrings(names[1], summaries[1].name.text());
    try equal(journey.RestoreSource.backup, try journey.restoreSlotWithSource(io, allocator, temp.dir, &state, 1));
    try equal(@as(u32, 2001), state.combat.progress.money);
    try equal(journey.RestoreSource.primary, try journey.restoreSlotWithSource(io, allocator, temp.dir, &state, 0));
    try equal(@as(u32, 2000), state.combat.progress.money);
    try std.testing.expectError(error.InvalidSaveSlot, journey.saveSlot(io, allocator, temp.dir, state, 3, try pause.save_slots.Label.init("Invalid")));
    try std.testing.expectError(error.InvalidSaveName, pause.save_slots.Label.init("\n"));
    try std.testing.expectError(error.InvalidSaveName, pause.save_slots.Label.init("   "));
    var invalid = pause.save_slots.Label{};
    invalid.len = 255;
    try std.testing.expectError(error.InvalidSaveName, journey.saveSlot(io, allocator, temp.dir, state, 0, invalid));
}

test "legacy journey versions migrate metadata while future backups and missing version3 fields are protected" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    for ([_][]const u8{ "suikoden-journey-save/1", "suikoden-journey-save/2" }) |version| {
        var legacy = try journey.Snapshot.capture(state);
        legacy.schema = version;
        legacy.auxiliary_party = null;
        legacy.save_name = null;
        legacy.elapsed_ticks = null;
        if (std.mem.endsWith(u8, version, "/1")) {
            legacy.loadouts = null;
            legacy.weapon_levels = null;
        }
        const bytes = try std.json.Stringify.valueAlloc(allocator, legacy, .{ .emit_null_optional_fields = false });
        defer allocator.free(bytes);
        try temp.dir.writeFile(io, .{ .sub_path = journey.filename, .data = bytes });
        state.elapsed_ticks = 999;
        state.save_name = try pause.save_slots.Label.init("Discard this metadata");
        try journey.restore(io, allocator, temp.dir, &state);
        try equal(@as(u64, 0), state.elapsed_ticks);
        try std.testing.expectEqualStrings("Adventure 1", state.save_name.text());
        try equal(@as(?usize, 0), state.combat.loadouts[0].head);
    }
    var missing = try journey.Snapshot.capture(state);
    missing.save_name = null;
    try std.testing.expectError(error.MissingSaveMetadata, missing.apply(&state));
    try temp.dir.writeFile(io, .{ .sub_path = journey.backup_filename, .data = "{\"schema\":\"suikoden-journey-save/179\",\"new_fields\":true}" });
    const before = try temp.dir.readFileAlloc(io, journey.filename, allocator, .limited(65536));
    defer allocator.free(before);
    try std.testing.expectError(error.UnsupportedSaveVersion, journey.save(io, allocator, temp.dir, state));
    const after = try temp.dir.readFileAlloc(io, journey.filename, allocator, .limited(65536));
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "named save menu requires slot name and final confirmation while load rejects empty slots" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    state.menu.phase = .root;
    state.menu.selected = .save;
    try equal(pause.Effect.inspect_saves, state.tick(.{ .field = .{ .action = true } }, .{}));
    try equal(.save_slots, state.menu.phase);
    _ = state.tick(.{ .field = .{ .menu_direction = .down } }, .{});
    confirm(&state);
    try equal(.name_save, state.menu.phase);
    for (0..32) |_| _ = state.tick(.{ .erase = true }, .{});
    _ = state.tick(.{ .text = "Camp Z X" }, .{});
    try std.testing.expectEqualStrings("Camp Z X", state.menu.save_label.text());
    confirm(&state);
    try equal(.confirm_save, state.menu.phase);
    try expect(!state.menu.yes);
    confirm(&state);
    try equal(.root, state.menu.phase);
    try equal(@as(u64, 0), state.elapsed_ticks);
    try equal(pause.Effect.inspect_saves, state.tick(.{ .field = .{ .action = true } }, .{}));
    confirm(&state);
    confirm(&state);
    _ = state.tick(.{ .right = true }, .{});
    try equal(pause.Effect.save, state.tick(.{ .field = .{ .action = true } }, .{}));
    try equal(@as(usize, 1), state.menu.save_slot);
    state.menu.phase = .root;
    state.menu.selected = .load;
    try equal(pause.Effect.inspect_saves, state.tick(.{ .field = .{ .action = true } }, .{}));
    confirm(&state);
    try equal(.notice, state.menu.phase);
    try std.testing.expectEqualStrings("This slot is empty.", state.menu.message);
    state.menu.phase = .load_slots;
    state.menu.summaries[1].status = .ready;
    confirm(&state);
    try equal(.confirm_load, state.menu.phase);
    try expect(!state.menu.yes);
    _ = state.tick(.{ .right = true }, .{});
    try equal(pause.Effect.load, state.tick(.{ .field = .{ .action = true } }, .{}));
}

test "battle result ledger keeps each award once, records loot owner and reports the money ceiling" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    const combat = state.combat;
    try state.beginEncounter(0);
    combat.progress.money = field.game_state.max_money - 1;
    combat.reward_drop = true;
    combat.loadouts[0] = .{};
    members[0].inventory.slots = @splat(.{ .id = .medicine, .uses = 6 });
    combat.enemy_hp = @splat(0);
    combat.phase = .resolving;
    combat.active = .{ .actor = 0, .target = combat.partyCount(), .kind = .defend };
    combat.action_ticks = combat.actionDuration() - 1;
    combat.tick(.{});
    try equal(.victory, combat.phase);
    try equal(@as(u32, 1), combat.reward_received);
    try expect(combat.reward_money > combat.reward_received);
    try equal(field.game_state.max_money, combat.progress.money);
    try equal(@as(?usize, 1), combat.loot_recipient);
    const inventories = members;
    const awards = combat.award_exp;
    const xp = combat.experience;
    const levels = combat.levels;
    for (0..60) |_| combat.tick(.{});
    try std.testing.expectEqualDeep(inventories, members);
    try equal(awards, combat.award_exp);
    try equal(xp, combat.experience);
    try equal(levels, combat.levels);
    try equal(field.game_state.max_money, combat.progress.money);
    for (0..6) |i| try expect(combat.award_exp[i] > 0);
}

test "Boar and Clone choose exact targets without charges then reserve one recovery turn" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    for ([_]usize{ 2, 3 }) |actor| {
        var members: [6]battle.Member = undefined;
        var state = try fixtures.session(&members);
        const combat = state.combat;
        try state.beginEncounter(0);
        if (actor == 3) {
            const slot = members[3].inventory.count();
            members[3].inventory.slots[slot] = .{ .id = .clone_crystal, .uses = 0 };
            try combat.attachRune(3, 3, slot);
            try expect(!combat.canAttackTarget(3, 2));
        }
        members[actor].rune_charges = @splat(0);
        try expect(combat.canUseRune(actor));
        combat.choose(actor);
        combat.picker.selected = .rune;
        combat.tick(.{ .confirm = true });
        try equal(.rune_target, combat.phase);
        combat.tick(.{ .down = true });
        combat.tick(.{ .down = true });
        try equal(@as(usize, 2), combat.selection);
        combat.tick(.{ .confirm = true });
        try equal(@as(usize, 2), combat.actions[actor].?.rune_attack);
        combat.acted = @splat(true);
        combat.acted[actor] = false;
        combat.phase = .resolving;
        combat.active = null;
        combat.tick(.{});
        try expect(combat.active.?.rune_attack);
        try equal(combat.partyCount() + 2, combat.active.?.target);
        const first = combat.enemy_hp[0];
        const second = combat.enemy_hp[1];
        const third = combat.enemy_hp[2];
        const damage = combat.active.?.amount;
        try expect(damage > 0 and damage % 2 == 0);
        combat.action_ticks = combat.impactTick() - 1;
        combat.tick(.{});
        try equal(first, combat.enemy_hp[0]);
        try equal(second, combat.enemy_hp[1]);
        try equal(@as(u16, @intCast(@as(u32, third) -| damage)), combat.enemy_hp[2]);
        try equal([4]u16{ 0, 0, 0, 0 }, members[actor].rune_charges);
        const hit = combat.enemy_hp;
        combat.tick(.{});
        try equal(hit, combat.enemy_hp);
        combat.action_ticks = combat.actionDuration() - 1;
        combat.tick(.{});
        try equal(@as(u8, 2), combat.unbalanced[actor]);
        combat.tick(.{});
        try equal(@as(u8, 1), combat.unbalanced[actor]);
        try expect(!combat.canUseRune(actor));
        try expect(!combat.canAttackTarget(actor, 0));
        combat.phase = .resolving;
        combat.active = null;
        combat.acted = @splat(true);
        combat.tick(.{});
        try equal(@as(u8, 0), combat.unbalanced[actor]);
        try expect(combat.canUseRune(actor));
    }
}

test "an interrupted physical rune causes no damage, charge cost or recovery" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    const combat = state.combat;
    try state.beginEncounter(0);
    combat.choose(2);
    combat.queue(.{ .rune_attack = 2 });
    combat.acted = @splat(true);
    combat.acted[2] = false;
    combat.phase = .resolving;
    combat.active = null;
    combat.tick(.{});
    const before = combat.enemy_hp;
    const charges = members[2].rune_charges;
    combat.actor_conditions[2].sleep_turns = 1;
    combat.action_ticks = combat.impactTick() - 1;
    combat.tick(.{});
    try equal(.unavailable, combat.active.?.kind);
    try equal(before, combat.enemy_hp);
    try equal(charges, members[2].rune_charges);
    try equal(@as(u8, 0), combat.unbalanced[2]);
}

test "canonical palace start seeds the completed opening milestones" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var package = fixtures.package.value;
    package.start_room = "vaa_room_1";
    const route = journey.initialRoute(package);
    try equal(.palace, route.stage);
    try equal(@as(u8, 2), route.completed);
    try expect(!route.milestones.opening_battles);
    try expect(!route.milestones.initial_party);
}

test "journey party snapshot preserves all six owned members" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    const snapshot = state.buildPartySnapshot();
    var session = try party_session.Session.init(state.combat.*, snapshot, .{});
    try session.validate();
    try std.testing.expectEqualStrings("hero", snapshot.active[0].?);
    try std.testing.expectEqualStrings("gremio", snapshot.active[1].?);
    for (0..6) |i| {
        try std.testing.expect(snapshot.members[i] != null);
        try std.testing.expect(snapshot.eligible[i]);
        try std.testing.expectEqualStrings(snapshot.members[i].?.member.id, snapshot.active[i].?);
    }
}

test "auxiliary party preserves holes and duplicates across rooms and saves" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    try equal(@as(?[6]u8, @as([6]u8, @splat(255))), state.field_state.auxiliary_party);
    var list: [6]u8 = .{ 2, 255, 2, 35, 255, 255 };
    field.editAuxiliaryParty(&list, true, 1);
    field.editAuxiliaryParty(&list, false, 2);
    try equal([6]u8{ 255, 1, 2, 35, 255, 255 }, list);
    state.field_state.auxiliary_party = list;
    state.field_state.enterRoom(state.field_state.room, .{ .x = state.field_state.x, .y = state.field_state.y });
    const saved = try journey.Snapshot.capture(state);
    const bytes = try std.json.Stringify.valueAlloc(allocator, saved, .{});
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(journey.Snapshot, allocator, bytes, .{});
    defer parsed.deinit();
    state.field_state.auxiliary_party = null;
    try parsed.value.apply(&state);
    try equal(@as(?[6]u8, list), state.field_state.auxiliary_party);
    var legacy = saved;
    legacy.schema = "suikoden-journey-save/31";
    try std.testing.expectError(error.InvalidSave, legacy.validate(state));
    legacy.auxiliary_party = null;
    try legacy.apply(&state);
    try expect(state.field_state.auxiliary_party == null);
}

test "save counter persists with wrapping and rejects a forged older save" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    state.combat.progress.story.scenario = .{};
    state.combat.progress.story.scenario.?.save_counter = std.math.maxInt(u32) - 1;
    state.combat.progress.story.scenario.?.advanceSaveCounter(4);
    var snapshot = try journey.Snapshot.capture(state);
    try equal(@as(u32, 2), snapshot.story.scenario.?.save_counter);
    const encoded = try std.json.Stringify.valueAlloc(allocator, snapshot, .{});
    defer allocator.free(encoded);
    const decoded = try std.json.parseFromSlice(journey.Snapshot, allocator, encoded, .{});
    defer decoded.deinit();
    try decoded.value.validate(state);
    try equal(@as(u32, 2), decoded.value.story.scenario.?.save_counter);
    snapshot.schema = "suikoden-journey-save/27";
    snapshot.auxiliary_party = null;
    try std.testing.expectError(error.InvalidSave, snapshot.validate(state));
    snapshot.story.scenario.?.save_counter = 0;
    try snapshot.validate(state);
}

test "Journey dice and party selection refuse input without a source request" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    try std.testing.expectError(error.MissingFieldPartySelectRequest, state.tickPartySelection(.{}));
    try std.testing.expectError(error.MissingFieldPartySelectRequest, journey.party_selection.begin(&state));
    const before = try journey.Snapshot.capture(state);
    _ = try journey.party_selection.inspect(&state, "hero");
    try std.testing.expectError(error.MissingFieldDiceRequest, journey.dice.begin(&state));
    try std.testing.expectError(error.MissingFieldDiceRequest, journey.dice.tick(&state, .start));
    try std.testing.expectError(error.MissingFieldDiceRequest, journey.dice.finish(&state));
    try std.testing.expectEqualDeep(before, try journey.Snapshot.capture(state));
    state.party_selection = .{ .receipt = .{ .content_sha256 = "", .program = "", .instance = 0, .batch = 0 } };
    try std.testing.expectError(error.GameBusy, journey.Snapshot.capture(state));
    const field_ticks = state.field_state.scene_ticks;
    const headless_ticks = state.elapsed_ticks;
    try equal(.none, try state.tickWithFieldEvents(.{ .menu = true }, .{}));
    try equal(headless_ticks + 1, state.elapsed_ticks);
    try equal(field_ticks, state.field_state.scene_ticks);
    try equal(.closed, state.menu.phase);
    const ticks = state.elapsed_ticks;
    try std.testing.expectError(error.MissingFieldPartySelectRequest, state.advanceSimulation(.{ .party = .{} }, null));
    try equal(ticks, state.elapsed_ticks);
}

test "dice entry waits for text closure and permits repeated instructions" {
    const Result = journey.dice.Result;
    try equal(Result.Message.straight_pay, try Result.report(.player, .{ .faces = .{ 4, 5, 6 }, .score = 32 }));
    try equal(Result.Message.player_straight_receive, try Result.report(.player, .{ .faces = .{ 4, 5, 6 }, .score = 32, .forced = true }));
    try equal(Result.Message.storm_pay, try Result.report(.dealer, .{ .faces = .{ 2, 2, 2 }, .score = 8, .forced = true }));
    try expect(Result.afterPayout(1000).finished());
    try equal(@as(u3, 2), Result.afterPayout(0).length);
    var sampler: journey.dice.Entry.Sampler = .{};
    try std.testing.expect(!sampler.sample(.{ .confirm = true }, true, null).pressed.any());
    _ = sampler.sample(.{}, true, null);
    const simultaneous = sampler.sample(.{ .confirm = true, .cancel = true, .up = true }, true, null);
    try std.testing.expect(simultaneous.pressed.confirm and simultaneous.pressed.cancel and simultaneous.pressed.up);
    try std.testing.expect(!sampler.sample(.{ .confirm = true, .cancel = true, .up = true }, true, null).pressed.any());
    _ = sampler.sample(.{}, false, null);
    try std.testing.expect(!sampler.sample(.{ .confirm = true }, true, null).pressed.any());
    var entry: journey.dice.Entry = .{};
    try entry.update(.confirm);
    try std.testing.expectError(error.PendingDiceText, entry.update(.text_closed));
    try entry.update(.text_ready);
    try entry.update(.text_closed);
    try equal(journey.dice.Entry.Message.rules, entry.message);
    try entry.update(.confirm);
    try std.testing.expect(!entry.close_requested);
    try entry.update(.text_ready);
    try entry.update(.up);
    try entry.update(.confirm);
    try entry.update(.text_closed);
    try equal(journey.dice.Entry.Message.rules, entry.message);
    try entry.update(.text_ready);
    try entry.update(.cancel);
    try entry.update(.text_closed);
    try equal(journey.dice.Entry.Message.fixed_notice, entry.message);
    try entry.update(.confirm);
    try entry.update(.text_ready);
    try entry.update(.text_closed);
    try equal(journey.dice.Entry.Message.ready, entry.message);
}

test "overload replacement stages compact bags and unequips only the selected worn copy" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    const Packet = @typeInfo(@FieldType(journey.State, "shared_item_catalogue")).optional.child;
    const parsed = try std.json.parseFromSlice(Packet, allocator, @import("campaign_policies_data").item_ledger.json, .{});
    defer parsed.deinit();
    state.shared_item_catalogue = parsed.value;
    state.combat.progress.party[0].inventory = .{};
    for (0..9) |_| _ = try state.combat.progress.party[0].inventory.receive(.medicine);
    state.combat.progress.party[0].inventory.slots[0] = .{ .id = .bandanna, .uses = 0 };
    const gear = state.combat.gearIndex(.bandanna).?;
    try state.combat.equipSlotOwned(0, .head, gear);
    const before = state.combat.ownedMember(0);
    const prepared = try journey.overload.prepareReplacement(&state, 0, 0, .fortune_rune_piece);
    try std.testing.expect(prepared.loadout.head == null);
    try std.testing.expectEqual(@as(usize, 9), prepared.member.inventory.count());
    try std.testing.expectEqual(field.items.Id.medicine, prepared.member.inventory.slots[0].?.id);
    try std.testing.expectEqual(field.items.Id.fortune_rune_piece, prepared.member.inventory.slots[8].?.id);
    try std.testing.expectEqual(@as(u16, 1), prepared.member.inventory.slots[8].?.uses);
    try std.testing.expectEqualDeep(before, state.combat.ownedMember(0));
    state.combat.progress.party[0].inventory.slots[1] = .{ .id = .bandanna, .uses = 0 };
    const unworn_copy = try journey.overload.prepareReplacement(&state, 0, 1, .medicine);
    try std.testing.expectEqual(gear, unworn_copy.loadout.head.?);
    state.extras[0].locked_equipment[0] = true;
    try std.testing.expectError(error.ItemCannotBeDiscarded, journey.overload.prepareReplacement(&state, 0, 0, .medicine));
    state.extras[0].locked_equipment[0] = false;
    state.combat.progress.party[0].inventory.slots[1] = .{ .id = .dragon_seal_incense, .uses = 0 };
    try std.testing.expect(!try journey.overload.canDrop(&state, 0, 1));
    state.combat.progress.party[0].inventory.slots[1] = .{ .id = .failure_urn, .uses = 0, .identified = false };
    try std.testing.expect(try journey.overload.canDrop(&state, 0, 1));
}

test "journey modalOwner follows strict modal and traversal priority" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);

    try expect(state.modalOwner(.{}) == .world_or_event);

    state.menu.phase = .root;
    try expect(state.modalOwner(.{}) == .field_menu);

    state.party_selection = @as(journey.party_selection.Active, undefined);
    try expect(state.modalOwner(.{}) == .party_selection);

    state.dice_game = @as(journey.dice.Active, undefined);
    try expect(state.modalOwner(.{}) == .dice);

    state.boat_travel = @as(journey.travel.Boat, undefined);
    state.menu.phase = .closed;
    try expect(state.modalOwner(.{}) == .boat_travel);
    try expect(state.modalOwner(.{ .menu = true }) == .dice);

    state.auto_travel = @as(journey.travel.Active, undefined);
    try expect(state.modalOwner(.{}) == .auto_travel);

    state.item_overload = @as(journey.overload.Active, undefined);
    try expect(state.modalOwner(.{}) == .item_overload);

    state.side_game = @as(journey.side_games.Active, undefined);
    try expect(state.modalOwner(.{}) == .side_game);

    state.teleport_session = @as(journey.travel.teleport.Session, undefined);
    try expect(state.modalOwner(.{}) == .teleport);
}

test "journey simulation cancels teleport ahead of a pending party selector" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);
    state.party_selection = @as(journey.party_selection.Active, undefined);
    var teleport: journey.travel.teleport.Session = undefined;
    teleport.phase = .selecting;
    teleport.entry.entry_id = "test_entry";
    teleport.entry.receipt = 1;
    teleport.settled = 0;
    state.teleport_session = teleport;
    const input = pause.Input{ .field = .{ .cancel = true } };
    const owner = state.modalOwner(input);
    try equal(.teleport, owner);
    try equal(.none, (try state.advanceSimulation(.{ .menu = input }, null)).effect);
    try expect(state.teleport_session == null);
    try expect(state.party_selection != null);
}

test "journey progress stages detached party edits and commits into live storage" {
    const fixtures = try Fixtures.init();
    defer fixtures.deinit();
    var members: [6]battle.Member = undefined;
    var state = try fixtures.session(&members);

    const progress = state.progress();
    const balance = progress.money;
    try expect(state.field_state.progress == progress);
    state.field_state.progress.money += 250;
    try equal(balance + 250, state.combat.progress.money);

    state.completeStoryFlag(.forest_entered);
    try expect(state.field_state.progress.story.has(.forest_entered));

    var story: field.game_state.event_runtime.StoryState = .{};
    story.scenario[10] = 0x55;
    state.setScenarioStory(story);
    try equal(@as(u8, 0x55), state.field_state.progress.story.scenario.?.scenario[10]);

    var staged_members: [6]battle.Member = undefined;
    var draft: field.game_state.Progress = undefined;
    const live_party = state.progress().party;
    const original_member = live_party[0];
    var staged = state.stageField(&draft, &staged_members);
    staged.progress.party[0].hp = if (original_member.hp == 0) 1 else 0;
    staged.progress.party[0].inventory = .{};
    if (original_member.inventory.count() == 0) _ = try staged.progress.party[0].inventory.receive(.medicine);
    staged.progress.party[0].max_hp = 0;
    try std.testing.expectError(error.InvalidMember, staged.progress.validate());
    try std.testing.expectEqualDeep(original_member, live_party[0]);

    staged = state.stageField(&draft, &staged_members);
    staged.progress.party[0].hp = original_member.max_hp - 1;
    staged.progress.money += 75;
    staged.progress.story.complete(.forest_returned);
    state.commitFieldTransaction(staged);
    try expect(state.field_state.progress == progress);
    try expect(state.progress().party.ptr == live_party.ptr);
    try equal(original_member.max_hp - 1, live_party[0].hp);
    try expect(state.progress().story.has(.forest_returned));
    try equal(staged.progress.money, state.progress().money);

    state.field_state.progress.story.complete(.vaa_dungeon_rumor);
    try expect(state.progress().story.has(.vaa_dungeon_rumor));

    state.recordPahnDuel(2);
    try equal(@as(u8, 2), state.progress().story.scenario.?.scenario[34] & 2);

    const prior_slice = state.progress().party;
    state.replacePartySlice(prior_slice[0..1]);
    try equal(@as(usize, 1), state.progress().party.len);
    state.replacePartySlice(prior_slice);
    try equal(prior_slice.len, state.progress().party.len);
}
