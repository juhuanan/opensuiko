const std = @import("std");
const battle = @import("battle");
const field = @import("field");
const party = @import("party_session");

test "selector input matches source history intersection across index wrap" {
    const selector = party.selector;
    var sampler: selector.Sampler = .{};
    var history: [256]u8 = @splat(0);
    var index: u8 = 0;
    for (0..520) |update| {
        var held: selector.Controls = .{};
        var mask: u8 = 0;
        inline for (comptime std.meta.fieldNames(selector.Controls), 0..) |name, bit| {
            const down = (update + bit * 11) % 91 < 65;
            @field(held, name) = down;
            if (down) mask |= @as(u8, 1) << bit;
        }
        const previous = history[index];
        index +%= 1;
        history[index] = mask;
        const pressed = (previous ^ mask) & mask;
        var repeated = pressed;
        if (index & 1 == 0) {
            var intersection = mask;
            for (0..30) |age| intersection &= history[index -% @as(u8, @intCast(age))];
            repeated |= intersection;
        }
        const actual = sampler.sample(held);
        inline for (comptime std.meta.fieldNames(selector.Controls), 0..) |name, bit| {
            const flag = @as(u8, 1) << bit;
            try std.testing.expectEqual(pressed & flag != 0, @field(actual.forPhase(.confirmation), name));
            try std.testing.expectEqual(pressed & flag != 0, @field(actual.forPhase(.full), name));
            try std.testing.expectEqual(repeated & flag != 0, @field(actual.forPhase(.list), name));
        }
    }
}

test "selector window countdown and signed outline preserve callback boundaries" {
    var window = try party.selector.Window.init(.{ .x = -64, .y = -20, .w = 128, .h = 36 });
    window.open();
    try std.testing.expect(!window.ready());
    window.tick();
    try std.testing.expectEqual(field.Rect{ .x = -8, .y = -4, .w = 16, .h = 5 }, window.outline().?);
    for (0..7) |_| window.tick();
    try std.testing.expect(window.ready());
    try std.testing.expectEqual(.opening, window.phase);
    try std.testing.expectEqual(window.target, window.outline().?);
    window.tick();
    try std.testing.expectEqual(.open, window.phase);
    window.close();
    window.tick();
    try std.testing.expectEqual(field.Rect{ .x = -56, .y = -17, .w = 112, .h = 31 }, window.outline().?);
    for (0..7) |_| window.tick();
    try std.testing.expect(window.ready());
    try std.testing.expectEqual(field.Rect{ .x = 0, .y = -2, .w = 1, .h = 1 }, window.outline().?);
    window.tick();
    try std.testing.expectEqual(.closed, window.phase);
}

test "selector window owner distinguishes main flags from submenu countdowns" {
    const selector = party.selector;
    const characters = [_]selector.Candidate{
        .{ .id = "hero", .recruited = true, .blocked = false },
        .{ .id = "gremio", .recruited = true, .blocked = false },
    };
    const roster: selector.Roster = .{ .characters = &characters, .active = &.{ "hero", "gremio" }, .forced = &.{} };
    var menu: selector.Selector = .{};
    var windows: selector.Windows = .{};
    for (0..8) |_| try windows.tick(&menu, roster, .{ .confirm = true });
    try std.testing.expectEqual(selector.Phase.main_opening, menu.phase);
    try std.testing.expect(windows.window(.main).?.ready());
    try windows.tick(&menu, roster, .{ .confirm = true });
    try std.testing.expectEqual(selector.Phase.main_opening, menu.phase);
    try windows.tick(&menu, roster, .{});
    try std.testing.expectEqual(selector.Phase.main, menu.phase);
    try std.testing.expect(windows.takeOpenCue());
    try std.testing.expect(!windows.takeOpenCue());
    menu = .{ .phase = .list_creation, .action = .eject };
    windows = .{};
    for (0..8) |_| try windows.tick(&menu, roster, .{});
    try std.testing.expectEqual(selector.Phase.list_opening, menu.phase);
    try std.testing.expectEqual(@as(i32, 72), windows.window(.list).?.target.h);
    try std.testing.expectEqual(@as(i32, 232), windows.window(.confirmation).?.target.w);
    try windows.tick(&menu, roster, .{});
    try std.testing.expectEqual(selector.Phase.list, menu.phase);
    try std.testing.expect(windows.takeOpenCue() and windows.takeOpenCue() and !windows.takeOpenCue());
}

test "headquarters selector confirmation ownership and forced ejection" {
    const selector = party.selector;
    const characters = [_]selector.Candidate{
        .{ .id = "hero", .recruited = true, .blocked = false },
        .{ .id = "gremio", .recruited = true, .blocked = false },
        .{ .id = "cleo", .recruited = true, .blocked = false },
        .{ .id = "ted", .recruited = true, .blocked = false, .guest = true },
        .{ .id = "pahn", .recruited = true, .blocked = true },
    };
    var roster: selector.Roster = .{ .characters = &characters, .active = &.{ "hero", "gremio" }, .forced = &.{"gremio"} };
    var menu: selector.Selector = .{ .phase = .list };
    var buffer: [78][]const u8 = undefined;
    try std.testing.expectEqualStrings("cleo", menu.list(roster, &buffer)[0]);
    try std.testing.expectEqual(@as(usize, 1), menu.list(roster, &buffer).len);
    try menu.tick(roster, .{ .confirm = true, .cancel = true }, true);
    try std.testing.expectEqual(selector.Phase.confirmation_opening, menu.phase);
    try menu.tick(roster, .{ .confirm = true }, false);
    try std.testing.expectEqual(selector.Phase.confirmation_opening, menu.phase);
    try menu.tick(roster, .{}, true);
    try menu.tick(roster, .{ .confirm = true }, true);
    try menu.tick(roster, .{}, true);
    try std.testing.expect(menu.pending == null);
    try menu.tick(roster, .{}, true);
    try std.testing.expectEqualStrings("cleo", menu.pending.?.character);
    try std.testing.expectError(error.StaleSelectorRoster, menu.acknowledge(roster));
    roster.active = &.{ "hero", "gremio", "cleo" };
    try menu.acknowledge(roster);
    menu.action = .eject;
    menu.cursor = 1;
    try menu.tick(roster, .{ .confirm = true, .cancel = true }, true);
    try std.testing.expectEqual(selector.Phase.list, menu.phase);
    menu.phase = .main;
    menu.action = .admit;
    try menu.tick(roster, .{ .up = true }, true);
    try std.testing.expectEqual(selector.Action.no_change, menu.action);
    try menu.tick(roster, .{ .down = true }, true);
    try std.testing.expectEqual(selector.Action.admit, menu.action);
    try menu.tick(roster, .{ .cancel = true }, true);
    try menu.tick(roster, .{}, true);
    try menu.tick(roster, .{}, true);
    try menu.tick(roster, .{}, true);
    for (0..32) |_| try menu.tick(roster, .{}, true);
    try std.testing.expectEqual(selector.Phase.fading, menu.phase);
    try menu.tick(roster, .{}, true);
    try std.testing.expectEqual(selector.Phase.cleanup, menu.phase);
    try menu.tick(roster, .{}, true);
    try std.testing.expectEqual(selector.Phase.done, menu.phase);
}

test "headquarters selector list pages reset to their first row" {
    const selector = party.selector;
    var characters: [24]selector.Candidate = undefined;
    var names: [23][8]u8 = undefined;
    characters[0] = .{ .id = "hero", .recruited = true, .blocked = false };
    for (characters[1..], &names, 0..) |*character, *name, index| {
        character.* = .{ .id = try std.fmt.bufPrint(name, "m{d}", .{index}), .recruited = true, .blocked = false };
    }
    const roster: selector.Roster = .{ .characters = &characters, .active = &.{"hero"}, .forced = &.{} };
    var menu: selector.Selector = .{ .phase = .list, .cursor = 9 };
    try menu.tick(roster, .{ .down = true }, true);
    try std.testing.expectEqual(@as(usize, 9), menu.cursor);
    try menu.tick(roster, .{ .right = true }, true);
    try std.testing.expectEqual(@as(usize, 10), menu.cursor);
    try menu.tick(roster, .{ .up = true }, true);
    try std.testing.expectEqual(@as(usize, 10), menu.cursor);
    menu.cursor = 19;
    try menu.tick(roster, .{ .right = true }, true);
    try std.testing.expectEqual(@as(usize, 20), menu.cursor);
    try menu.tick(roster, .{ .left = true, .down = true }, true);
    try std.testing.expectEqual(@as(usize, 20), menu.cursor);
    try menu.tick(roster, .{ .left = true }, true);
    try std.testing.expectEqual(@as(usize, 10), menu.cursor);
}
const Sink = struct {
    count: *usize,
    pub fn text(self: @This(), _: i32, _: i32, _: []const u8, _: bool) void {
        self.count.* += 1;
    }
};

test "journal replay validates selection, storage, restart and stale baseline" {
    const allocator = std.testing.allocator;
    const content = try battle.load(allocator, @embedFile("demo_batch.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    const facts = try party.catalogue.decode(allocator, @import("party_data").json);
    defer facts.deinit();
    const bindings = try party.catalogue.decodeBindings(allocator, @embedFile("ownership_bindings.json"), @import("party_data").json);
    defer bindings.deinit();
    try std.testing.expectEqualStrings("masked_rune_32", bindings.value.ted.rune_id);
    var tampered = try allocator.dupe(u8, @embedFile("ownership_bindings.json"));
    defer allocator.free(tampered);
    tampered[0] ^= 1;
    try std.testing.expectError(error.InvalidBindings, party.catalogue.decodeBindings(allocator, tampered, @import("party_data").json));

    try std.testing.expectEqual(@as(usize, 78), facts.value.characters.len);
    var members: [6]battle.Member = undefined;
    const combat = try battle.State.init(content.value, rules.value, &members, 17);
    try std.testing.expectError(error.WeaponUnavailable, party.catalogue.materialize(combat.content.characterRules(), facts.value, "hero"));
    // Construct a named source-matching host profile to exercise materialization;
    // the synthetic zero-bonus equipment is only a local fixture.
    var profiles = try allocator.dupe(battle.Profile, combat.content.party);
    defer allocator.free(profiles);
    const seed = facts.value.characters[0].seed;
    var weapon_names: [16][]const u8 = undefined;
    for (seed.weapon.names, 0..) |name, i| weapon_names[i] = name.?;
    profiles[0].weapon = .{ .initial_level = seed.weapon.level, .names = weapon_names, .powers = seed.weapon.powers, .upgrade_costs = @splat(0) };
    const equipment = [_]battle.systems.Equipment{
        .{ .id = "bandanna", .name = "Bandanna", .bonuses = @splat(0), .category = .head },
        .{ .id = "tunic", .name = "Tunic", .bonuses = @splat(0), .category = .body },
        .{ .id = "gloves", .name = "Gloves", .bonuses = @splat(0), .category = .accessory },
        .{ .id = "boots", .name = "Boots", .bonuses = @splat(0), .category = .accessory },
    };
    var systems = combat.content.systems.?;
    systems.equipment = &equipment;
    var source_combat = combat;
    source_combat.content.party = profiles;
    source_combat.content.systems = systems;
    const hero = try party.catalogue.materialize(source_combat.content.characterRules(), facts.value, "hero");
    try std.testing.expectEqual(@as(u16, 17), hero.owned.hp);
    try std.testing.expectEqual(@as(usize, 5), hero.owned.inventory.count());
    try std.testing.expectEqualStrings("hero", hero.extra.member_id);
    // The D binding maps Ted's locked source rune distinctly from Soul Eater.
    const ted = for (facts.value.characters) |character| {
        if (std.mem.eql(u8, character.id, "ted")) break character;
    } else unreachable;
    var ted_profiles = try allocator.alloc(battle.Profile, profiles.len + 1);
    defer allocator.free(ted_profiles);
    @memcpy(ted_profiles[0..profiles.len], profiles);
    var ted_profile = profiles[0];
    ted_profile.id = ted.id;
    ted_profile.name = ted.name;
    ted_profile.growth = ted.growth;
    ted_profile.rune = "masked_rune_32";
    ted_profile.rune_locked = true;
    var ted_weapon_names: [16][]const u8 = undefined;
    for (ted.seed.weapon.names, 0..) |name, i| ted_weapon_names[i] = name.?;
    ted_profile.weapon = .{ .initial_level = ted.seed.weapon.level, .names = ted_weapon_names, .powers = ted.seed.weapon.powers, .upgrade_costs = @splat(0) };
    ted_profiles[profiles.len] = ted_profile;
    const ted_equipment = [_]battle.systems.Equipment{
        .{ .id = "robe", .name = "Robe", .bonuses = @splat(0), .category = .body },
    };
    var ted_runes = try allocator.alloc(battle.systems.Rune, systems.runes.len + 1);
    defer allocator.free(ted_runes);
    @memcpy(ted_runes[0..systems.runes.len], systems.runes);
    ted_runes[systems.runes.len] = .{ .id = "masked_rune_32", .name = "??????", .spell_names = @splat("unavailable"), .spells = @splat(null) };
    var ted_systems = systems;
    ted_systems.equipment = &ted_equipment;
    ted_systems.runes = ted_runes;
    var ted_combat = combat;
    ted_combat.content.party = ted_profiles;
    ted_combat.content.systems = ted_systems;
    try std.testing.expectError(error.UnsupportedSeed, party.catalogue.materialize(ted_combat.content.characterRules(), facts.value, "ted"));
    const ted_owned = try party.catalogue.materializeBound(ted_combat.content.characterRules(), facts.value, "ted", bindings.value);
    try std.testing.expectEqual(@as(?usize, systems.runes.len), ted_owned.owned.rune);
    try std.testing.expectEqualStrings("ted", ted_owned.extra.member_id);
    var hero_entry = party.Snapshot{ .entry_id = "hero-entry", .content_id = "source-fixture", .receipt = "hero-receipt", .baseline_revision = 1 };
    hero_entry.members[0] = hero.owned;
    hero_entry.extras[0] = hero.extra;
    hero_entry.eligible[0] = true;
    hero_entry.active[0] = "hero";
    var hero_session = try party.Session.init(source_combat.content.characterRules(), hero_entry, .{});
    try hero_session.execute(.{ .equip = .{ .member = "hero", .slot = .head, .equipment = null } });
    try std.testing.expectEqual(@as(?usize, null), hero_session.current.members[0].?.loadout.head);
    try hero_session.execute(.{ .equip = .{ .member = "hero", .slot = .head, .equipment = 0 } });
    try std.testing.expectEqual(@as(?usize, 0), hero_session.current.members[0].?.loadout.head);

    var initial = party.Snapshot{ .entry_id = "test-entry", .content_id = "demo-batch", .receipt = "receipt-1", .baseline_revision = 42 };
    for (0..6) |i| {
        initial.members[i] = combat.ownedMember(i);
        initial.extras[i] = .{ .member_id = members[i].id };
        initial.eligible[i] = true;
        initial.active[i] = members[i].id;
    }
    initial.members[0].?.inventory.slots[0].?.uses = 5;
    initial.members[0].?.inventory.slots[2] = .{ .id = .water_rune_piece, .uses = 0 };
    initial.forced[0] = members[0].id;
    initial.followers[0] = "scene-follower";
    const operations = [_]party.SharedOperation{.{ .id = "event-grant", .source = "event-50/0", .item = "named-key", .kind = .acquire, .unique = true }};
    const scenes = [_]party.SceneOperation{ party.story.vb6_arrival, .{ .id = "test-scene", .source = "fixture-scene", .scope = .area_transient, .active = .{ members[1].id, members[0].id, null, null, null, null }, .followers = .{ "scene-follower", null, null, null, null, null } } };
    const sources = party.Sources{ .shared = &operations, .scenes = &scenes };
    var s = try party.Session.init(combat.content.characterRules(), initial, sources);
    try s.execute(.{ .scene = "vb6_r06_first_arrival_prefix" });
    try std.testing.expectEqualStrings("kirkis", s.current.scene_order[2].?);
    try std.testing.expectEqualStrings(members[0].id, s.current.active[0].?);
    try s.execute(.{ .scene = "test-scene" });
    try std.testing.expectEqualStrings(members[0].id, s.current.active[0].?);
    try std.testing.expectEqualStrings(members[1].id, s.current.scene_order[0].?);
    try s.execute(.{ .weapon_piece = .{ .owner = members[0].id, .slot = 2, .target = members[1].id } });
    try std.testing.expectEqual(@as(u8, 1), s.current.extras[1].?.weapon_fragments[1]);
    try s.execute(.{ .shared = "event-grant" });
    try std.testing.expectError(error.AlreadyOwned, s.execute(.{ .shared = "event-grant" }));
    try s.execute(.{ .select = .{ members[0].id, null, null, null, null, null } });
    try std.testing.expectError(error.MemberNotActive, s.execute(.{ .give = .{ .from = members[0].id, .slot = 0, .to = members[1].id } }));
    try s.execute(.{ .select = .{ members[0].id, members[1].id, members[2].id, null, null, null } });
    try std.testing.expectError(error.ForcedMemberMissing, s.execute(.{ .select = .{ members[1].id, null, null, null, null, null } }));
    try std.testing.expectError(error.DuplicateMember, s.execute(.{ .select = .{ members[0].id, members[0].id, null, null, null, null } }));
    try s.execute(.{ .deposit = .{ .member = members[0].id, .slot = 0 } });
    try s.execute(.{ .withdraw = .{ .member = members[0].id, .item = .medicine } });
    try std.testing.expectEqual(@as(u16, 6), s.current.members[0].?.inventory.slots[1].?.uses);
    try s.execute(.{ .give = .{ .from = members[0].id, .slot = 0, .to = members[1].id } });
    var view = party.view.View{};
    view.input(&s, .right);
    try std.testing.expectEqualStrings("Choose member", view.title());
    view.input(&s, .confirm);
    try std.testing.expectEqualStrings("Inventory", view.title());
    try std.testing.expect(view.row(s, 0) != null);
    var lines: usize = 0;
    view.draw(s, Sink{ .count = &lines });
    try std.testing.expect(lines > 0);
    const transaction = s.result();
    const bytes = try std.json.Stringify.valueAlloc(allocator, transaction, .{});
    defer allocator.free(bytes);
    const saved = try party.decodeResult(allocator, bytes);
    defer saved.deinit();
    const restored = try party.replay(combat.content.characterRules(), initial, sources, saved.value);
    try std.testing.expectEqualStrings("scene-follower", restored.current.followers[0].?);
    try std.testing.expectEqual(@as(u8, 1), restored.current.extras[1].?.weapon_fragments[1]);
    try std.testing.expectEqualStrings("named-key", restored.current.shared[0].?);
    try std.testing.expectEqualStrings(members[0].id, restored.current.active[0].?);
    try std.testing.expectEqual(@as(usize, 3), restored.current.members[1].?.inventory.count());
    // Restart must retain small and full parties, reserve records and context.
    for ([_]usize{ 1, 3, 6 }) |count| {
        var baseline = initial;
        for (count..6) |i| baseline.active[i] = null;
        var small = try party.Session.init(combat.content.characterRules(), baseline, sources);
        try small.execute(.{ .select = baseline.active });
        const encoded = try std.json.Stringify.valueAlloc(allocator, small.result(), .{});
        defer allocator.free(encoded);
        const document = try party.decodeResult(allocator, encoded);
        defer document.deinit();
        const resumed = try party.replay(combat.content.characterRules(), baseline, sources, document.value);
        for (0..count) |i| try std.testing.expectEqualStrings(members[i].id, resumed.current.active[i].?);
        try std.testing.expectEqualStrings(members[5].id, resumed.current.members[5].?.id);
        try std.testing.expectEqualStrings(members[0].id, resumed.current.forced[0].?);
        try std.testing.expectEqualStrings("scene-follower", resumed.current.followers[0].?);
    }
    // Rune transfer uses the existing detach/attach checks as one transaction.
    const runes = try allocator.dupe(battle.systems.Rune, combat.content.systems.?.runes);
    defer allocator.free(runes);
    var boar: ?usize = null;
    for (runes, 0..) |*rune, i| if (std.mem.eql(u8, rune.id, "boar")) {
        rune.crystal = "boar_crystal";
        boar = i;
    };
    var rune_rules = combat.content.systems.?;
    rune_rules.runes = runes;
    var rune_combat = combat;
    rune_combat.content.systems = rune_rules;
    var rune_state = try party.Session.init(rune_combat.content.characterRules(), initial, sources);
    const source_charges = rune_state.current.members[2].?.rune_charges;
    const target_charges = rune_state.current.members[0].?.rune_charges;
    try rune_state.execute(.{ .transfer_rune = .{ .from = members[2].id, .to = members[0].id } });
    try std.testing.expectEqual(@as(?usize, null), rune_state.current.members[2].?.rune);
    try std.testing.expectEqual(boar, rune_state.current.members[0].?.rune);
    try std.testing.expectEqual(source_charges, rune_state.current.members[2].?.rune_charges);
    try std.testing.expectEqual(target_charges, rune_state.current.members[0].?.rune_charges);
    var occupied = initial;
    occupied.members[0].?.rune = boar;
    var blocked = try party.Session.init(rune_combat.content.characterRules(), occupied, sources);
    try std.testing.expectError(error.RuneOccupied, blocked.execute(.{ .transfer_rune = .{ .from = members[2].id, .to = members[0].id } }));
    try std.testing.expectEqual(boar, blocked.current.members[2].?.rune);
    try std.testing.expect(blocked.commands[0] == null);
    var full = initial;
    for (&full.members[1].?.inventory.slots) |*slot| slot.* = .{ .id = .medicine, .uses = 6 };
    var rejected = try party.Session.init(combat.content.characterRules(), full, sources);
    try std.testing.expectError(error.InventoryFull, rejected.execute(.{ .give = .{ .from = members[0].id, .slot = 0, .to = members[1].id } }));
    try std.testing.expectEqual(@as(usize, 3), rejected.current.members[0].?.inventory.count());
    try std.testing.expect(rejected.commands[0] == null);
    try std.testing.expectError(error.InvalidParty, rejected.execute(.{ .select = @splat(null) }));
    try std.testing.expect(rejected.commands[0] == null);
    var unavailable = party.view.View{};
    unavailable.input(&rejected, .confirm);
    try std.testing.expectEqualStrings("PartyChangeUnavailable", unavailable.last_error.?);
    try std.testing.expect(rejected.commands[0] == null);
    unavailable.input(&rejected, .finish);
    try std.testing.expectEqual(party.view.Outcome.accepted, unavailable.outcome);
    var selectable = party.view.View{ .allow_party_selection = true };
    var selection_state = try party.Session.init(combat.content.characterRules(), initial, sources);
    selectable.input(&selection_state, .down);
    selectable.input(&selection_state, .confirm);
    try std.testing.expectEqualStrings(members[2].id, selection_state.current.active[1].?);
    var cancelled = party.view.View{};
    cancelled.input(&rejected, .cancel);
    try std.testing.expectEqual(party.view.Outcome.cancelled, cancelled.outcome);
    var controller = party.view.View{};
    controller.input(&rejected, .right);
    controller.input(&rejected, .confirm);
    controller.input(&rejected, .cancel);
    try std.testing.expectEqualStrings("Choose member", controller.title());
    try std.testing.expect(rejected.commands[0] == null);
    controller.input(&rejected, .confirm);
    controller.input(&rejected, .confirm);
    controller.input(&rejected, .down);
    controller.input(&rejected, .down);
    controller.input(&rejected, .confirm);
    try std.testing.expectEqualStrings("Discard this item?", controller.title());
    controller.input(&rejected, .confirm); // Default "No" must leave ownership untouched.
    try std.testing.expectEqual(@as(usize, 3), rejected.current.members[0].?.inventory.count());
    try std.testing.expect(rejected.commands[0] == null);
    try rejected.execute(.{ .swap = .{ .first = members[0].id, .first_slot = 0, .second = members[1].id, .second_slot = 0 } });
    try std.testing.expectEqual(@as(u16, 6), rejected.current.members[0].?.inventory.slots[0].?.uses);
    try std.testing.expectEqual(@as(u16, 5), rejected.current.members[1].?.inventory.slots[0].?.uses);
    try std.testing.expectEqual(@as(usize, 9), rejected.current.members[1].?.inventory.count());
    var stale = initial;
    stale.baseline_revision += 1;
    try std.testing.expectError(error.StaleTransaction, party.replay(combat.content.characterRules(), stale, sources, saved.value));
}

test "canonical Cleo and Ted profiles materialize with selector details and source rune binding" {
    const allocator = std.testing.allocator;
    const content = try battle.load(allocator, @embedFile("../fixtures/opening_trial.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    const facts = try party.catalogue.decode(allocator, @import("party_data").json);
    defer facts.deinit();
    const bindings = try party.catalogue.decodeBindings(allocator, @embedFile("ownership_bindings.json"), @import("party_data").json);
    defer bindings.deinit();
    var members: [6]battle.Member = undefined;
    const combat = try battle.State.init(content.value, rules.value, &members, 17);
    const cleo = try party.catalogue.materialize(combat.content.characterRules(), facts.value, "cleo");
    try std.testing.expectEqual(@as(u16, 20), cleo.owned.max_hp);
    try std.testing.expect(combat.content.partyProfile("cleo").?.attack.len > 0);
    try std.testing.expect(combat.content.partyProfile("ted").?.attack.len > 0);
    const ted = try party.catalogue.materializeBound(combat.content.characterRules(), facts.value, "ted", bindings.value);
    try std.testing.expectEqual(@as(u16, 18), ted.owned.max_hp);
    try std.testing.expect(ted.owned.rune != null);
    const equipped = try party.selector.Details.derive(combat.content.characterRules(), cleo.owned, cleo.extra);
    try std.testing.expectEqual(@as(u16, 15), equipped.defense);
    try std.testing.expectEqual(@as(u16, 20), equipped.armour);
    var preview = try party.catalogue.materialize(combat.content.characterRules(), facts.value, "hero");
    const weapon = combat.content.partyProfile("hero").?.weapon.?;
    preview.owned.base_stats = .{ .attack = 11 + weapon.powers[weapon.initial_level - 1], .skill = 12, .defense = 13, .speed = 14, .magic = 15, .luck = 16 };
    preview.owned.loadout = .{};
    preview.owned.rune = null;
    preview.owned.weapon_level = 2;
    preview.owned.rune_charges = @splat(0);
    preview.owned.max_rune_charges = combat.content.systems.?.magicCapacity(15);
    const plain = try party.selector.Details.derive(combat.content.characterRules(), preview.owned, preview.extra);
    try std.testing.expectEqual(@as(u16, 11), plain.power);
    try std.testing.expectEqual(@as(u16, 11 + weapon.powers[1]), plain.attack);
    preview.owned.rune = combat.content.systems.?.runeIndex("gale") orelse return error.MissingFixtureRune;
    preview.extra.weapon_element = .wind;
    preview.extra.weapon_fragments[2] = 3;
    const augmented = try party.selector.Details.derive(combat.content.characterRules(), preview.owned, preview.extra);
    try std.testing.expectEqual(@as(u16, 28), augmented.speed);
    try std.testing.expectEqual(@as(u16, 22), augmented.defense);
    try std.testing.expectEqual(@as(u16, 22), augmented.armour);
}
