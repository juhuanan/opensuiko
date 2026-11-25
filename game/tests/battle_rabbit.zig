const std = @import("std");
const battle = @import("battle");
const field = @import("field");
const world = @import("world");
const overlay = @import("world_battle");
const a = std.testing.allocator;

fn rabbitActors(alloc: std.mem.Allocator) !battle.actor_host.Bundle {
    return (try battle.actor_host.loadBundle(alloc, @embedFile("fixtures/journey_unites_actor_library.json"))).value;
}

fn rabbitContent(alloc: std.mem.Allocator) !battle.Content {
    const base = try battle.load(alloc, @embedFile("fixtures/journey_battle.json"));
    const map = try world.load(alloc, world.json);
    const data = try overlay.load(alloc, overlay.json);
    var content = try data.value.view(map.value, base.value);
    content.encounters = content.encounters[4..5];
    return content;
}

fn normalScenes(alloc: std.mem.Allocator) !battle.spell_scene.Packet {
    var base = try std.json.parseFromSlice(std.json.Value, alloc, @embedFile("fixtures/spell_scene_library.json"), .{});
    const patch = try std.json.parseFromSlice(std.json.Value, alloc, @embedFile("fixtures/journey_unite_scenes_patch.json"), .{});
    var fields = patch.value.object.iterator();
    while (fields.next()) |entry| try base.value.object.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
    return (try battle.spell_scene.load(alloc, try std.json.Stringify.valueAlloc(alloc, base.value, .{}))).value;
}

test "Rabbit source admission composes both branches in all three normal B formations" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const base = try battle.load(alloc, @embedFile("fixtures/journey_unites_battle.json"));
    const library = try rabbitActors(alloc);
    const scenes = try normalScenes(alloc);
    const items = try field.items.load(alloc, field.items.json);
    for ([_][]const u8{ "area_b_5", "area_b_7", "area_b_8" }) |id| for ([_]bool{ false, true }) |projectile| {
        var content = base.value;
        const index = for (content.encounters, 0..) |encounter, ordinal| {
            if (std.mem.eql(u8, encounter.id, id)) break ordinal;
        } else return error.MissingRabbitFormation;
        content.encounters = content.encounters[index..][0..1];
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(content, items.value, &members, 1234);
        try state.attachUniteActors(&library);
        try state.attachSpellScenes(&scenes);
        state.phase = .resolving;
        state.acted = @splat(true);
        for (&members, 0..) |*member, slot| {
            member.hp = 9999;
            member.max_hp = 9999;
            state.actions[slot] = .defend;
        }
        const owner = for (0..state.enemyCount()) |enemy| {
            if (std.mem.eql(u8, state.enemy(enemy).id, "killer_rabbit")) break state.partyCount() + enemy;
        } else return error.MissingRabbitFormation;
        state.coordinator = .{ .stage = .dispatch, .current_actor = owner };
        var values: [16]u15 = @splat(32767);
        if (!projectile) values[0] = 0;
        var draws = battle.systems.Draws{ .values = &values };
        var contact: ?usize = null;
        var saw_projectile = false;
        for (1..180) |update| {
            try state.tickReplay(.{}, &draws);
            for (state.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
                if (playback.contact_at != null and contact == null) contact = update;
            };
            for (state.unite_vm.auxiliary, 0..) |maybe, slot| if (maybe) |child| {
                if (child.resource != null and std.mem.eql(u8, child.resource.?.id, "killer_rabbit") and child.visible) {
                    try std.testing.expect(battle.layout.uniteAuxiliary(state, slot) != null);
                    saw_projectile = true;
                }
            };
            if (state.active == null and !state.unite_vm.hasActors()) break;
        }
        try std.testing.expectEqual(@as(?usize, if (projectile) 64 else 79), contact);
        try std.testing.expectEqual(projectile, saw_projectile);
        try std.testing.expect(!state.unite_vm.hasActors() and state.active == null);
        try std.testing.expectEqual(@as(usize, if (projectile) 3 else 4), draws.cursor);
        try std.testing.expect(members[if (projectile) 4 else 0].hp < 9999);
    };
}

test "Rabbit source admission refuses older missing bindings and missing rotated projectile pieces" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const base = try battle.load(alloc, @embedFile("fixtures/journey_unites_battle.json"));
    const library = try rabbitActors(alloc);
    const items = try field.items.load(alloc, field.items.json);
    var older = base.value;
    older.schema = "suikoden-battle-trial/36";
    try std.testing.expectError(error.UnsupportedEnemyPresentation, older.validate());
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(base.value, items.value, &members, 1234);
    const graphics = try alloc.dupe(battle.UniteGraphic, base.value.unite_graphics);
    for (graphics) |*graphic| if (std.mem.eql(u8, graphic.id, "killer_rabbit")) {
        const poses = try alloc.dupe(battle.UniteGraphicPose, graphic.poses);
        for (poses) |*pose| if (pose.id == 8) {
            pose.pieces = &.{};
        };
        graphic.poses = poses;
    };
    state.content.unite_graphics = graphics;
    try std.testing.expectError(error.MissingPhysicalArt, state.attachUniteActors(&library));
    try std.testing.expect(state.unite_actors == null and !state.unite_vm.hasActors());
    state.content = base.value;
    var missing = library;
    missing.schema = "suikoden-unite-actors/32";
    missing.group_orders = null;
    missing.enemy_wave = null;
    missing.enemy_area_magic = null;
    missing.enemy_regional = null;
    const missing_reactions = try alloc.dupe(battle.counter.PartyReaction, library.counter.?.melee.?.party_reactions);
    for (missing_reactions) |*reaction| reaction.return_program = null;
    missing.counter.?.melee.?.party_reactions = missing_reactions;
    var bindings: std.ArrayList(battle.counter.MeleeEnemy) = .empty;
    for (library.counter.?.melee.?.enemies) |binding| if (binding.projectile == null and (binding.special == null or binding.special.?.return_program == null)) try bindings.append(alloc, binding);
    missing.counter.?.melee.?.enemies = bindings.items;
    try std.testing.expectError(error.MissingRabbitBinding, state.attachUniteActors(&missing));
    try std.testing.expect(state.unite_actors == null and !state.unite_vm.hasActors());
}

test "Rabbit source admission completes the three original formations through round two" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const base = try battle.load(alloc, @embedFile("fixtures/journey_unites_battle.json"));
    const library = try rabbitActors(alloc);
    const scenes = try normalScenes(alloc);
    const items = try field.items.load(alloc, field.items.json);
    for ([_][]const u8{ "area_b_5", "area_b_7", "area_b_8" }) |id| for ([_]bool{ false, true }) |mixed| {
        var content = base.value;
        const index = for (content.encounters, 0..) |encounter, ordinal| {
            if (std.mem.eql(u8, encounter.id, id)) break ordinal;
        } else return error.MissingRabbitFormation;
        content.encounters = content.encounters[index..][0..1];
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(content, items.value, &members, 1234);
        try state.attachUniteActors(&library);
        try state.attachSpellScenes(&scenes);
        for (&members, 0..) |*member, slot| {
            member.hp = 9999;
            member.max_hp = 9999;
            state.actions[slot] = .defend;
        }
        state.acted = @splat(true);
        for (state.partyCount()..state.partyCount() + state.enemyCount()) |actor| state.acted[actor] = false;
        state.phase = .resolving;
        state.coordinator = .{ .stage = .dispatch, .current_actor = state.partyCount() };
        var values: [2048]u15 = @splat(32767);
        if (mixed) values[0] = 0;
        var draws = battle.systems.Draws{ .values = &values };
        for (0..1800) |update| {
            state.tickReplay(.{}, &draws) catch |failure| {
                std.debug.print("Rabbit formation {s} mixed={} update={}: {s}\n", .{ id, mixed, update, @errorName(failure) });
                return failure;
            };
            if (state.round >= 2 and state.phase == .battle_menu and !state.unite_vm.hasActors()) break;
        }
        try std.testing.expectEqual(@as(u32, 2), state.round);
        try std.testing.expect(state.phase == .battle_menu and !state.unite_vm.hasActors() and state.active == null);
        try std.testing.expect(for (members) |member| {
            if (member.hp < 9999) break true;
        } else false);
    };
}

test "Rabbit source admission receives ordinary critical missed and lethal party attacks" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const base = try battle.load(alloc, @embedFile("fixtures/journey_unites_battle.json"));
    const library = try rabbitActors(alloc);
    const scenes = try normalScenes(alloc);
    const items = try field.items.load(alloc, field.items.json);
    var content = base.value;
    const index = for (content.encounters, 0..) |encounter, ordinal| {
        if (std.mem.eql(u8, encounter.id, "area_b_5")) break ordinal;
    } else return error.MissingRabbitFormation;
    content.encounters = content.encounters[index..][0..1];
    for (0..4) |scenario| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(content, items.value, &members, 1234);
        try state.attachUniteActors(&library);
        try state.attachSpellScenes(&scenes);
        state.phase = .battle_menu;
        state.acted = @splat(true);
        state.enemy_hp[0] = if (scenario == 3) 1 else 9999;
        const initial = state.enemy_hp[0];
        const amount = if (scenario == 2) 0 else state.resolvePhysicalDamage(0, state.partyCount(), 0, false) * @as(u32, if (scenario == 1) 3 else 1);
        try state.beginPartyMelee(0, state.partyCount(), scenario != 2, scenario == 1);
        const values = [_]u15{0};
        var draws = battle.systems.Draws{ .values = &values };
        for (0..320) |_| {
            try state.tickReplay(.{}, &draws);
            if (!state.unite_vm.hasActors() and state.active == null) break;
        }
        try std.testing.expect(!state.unite_vm.hasActors() and state.active == null);
        try std.testing.expectEqual(@as(u16, @intCast(@as(u32, initial) -| amount)), state.enemy_hp[0]);
        try std.testing.expectEqual(@as(usize, if (scenario == 2) 0 else 1), draws.cursor);
    }
}

test "Rabbit live projectile owns damage protection reaction and source release clocks" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const content = try rabbitContent(alloc);
    const library = try rabbitActors(alloc);
    const items = try field.items.load(alloc, field.items.json);
    for (0..5) |scenario| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(content, items.value, &members, 1234);
        try state.attachUniteActors(&library);
        state.phase = .battle_menu;
        state.acted = @splat(true);
        for (&members) |*member| {
            member.hp = 9999;
            member.max_hp = 9999;
        }
        if (scenario == 1) state.actions[0] = .defend;
        if (scenario == 2) state.protection[0] = 2;
        if (scenario >= 3) members[0].hp = 1;
        if (scenario == 4) {
            state.phase = .resolving;
            members[0].max_hp = 100;
            members[0].inventory.slots = @splat(null);
            members[0].inventory.slots[0] = .{ .id = .sacrificial_buddha, .uses = 0 };
        }
        const initial = members[0].hp;
        const owner = state.partyCount();
        const damage = if (scenario == 2) 0 else state.resolvePhysicalDamage(owner, 0, 0, scenario == 1);
        try std.testing.expect(try state.beginRabbitProjectile(owner, 0));
        const values = [_]u15{0};
        var draws = battle.systems.Draws{ .values = &values };
        var contact: ?u32 = null;
        var released: ?u32 = null;
        var revived = false;
        for (1..360) |update| {
            state.tickReplay(.{}, &draws) catch |failure| {
                std.debug.print("Rabbit scenario={} update={}: {s}\n", .{ scenario, update, @errorName(failure) });
                return failure;
            };
            if (contact == null and draws.cursor != 0) contact = @intCast(update);
            if (released == null and state.active == null) released = @intCast(update);
            if (update < 64) try std.testing.expectEqual(initial, members[0].hp);
            if (update >= 64 and scenario < 4) try std.testing.expectEqual(@as(u16, @intCast(@as(u32, initial) -| damage)), members[0].hp);
            if (scenario == 4 and update >= 64 and members[0].hp > 0) revived = true;
            if (update >= 117 and !state.unite_vm.hasActors() and !state.hasPendingRevival()) break;
        }
        try std.testing.expectEqual(@as(?u32, 64), contact);
        try std.testing.expectEqual(@as(?u32, 117), released);
        try std.testing.expectEqual(@as(usize, 1), draws.cursor);
        try std.testing.expect(!state.unite_vm.hasActors() and state.active == null);
        if (scenario == 3) try std.testing.expect(members[0].status == .unconscious and !state.knockout_pending[0]);
        if (scenario == 4) {
            try std.testing.expect(revived and members[0].status == .healthy and !state.knockout_pending[0]);
            try std.testing.expectEqual(@as(u16, 50), members[0].hp);
            try std.testing.expectEqual(@as(usize, 0), members[0].inventory.count());
        }
        for (members[1..]) |member| try std.testing.expectEqual(@as(u16, 9999), member.hp);
    }
}

test "Rabbit live source packet versions and full auxiliary pool refuse without mutation" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const content = try rabbitContent(alloc);
    const library = try rabbitActors(alloc);
    var older = library;
    older.schema = "suikoden-unite-actors/32";
    try std.testing.expectError(error.InvalidUniteBindings, older.validate());
    older.schema = "suikoden-unite-actors/33";
    try std.testing.expectError(error.InvalidUniteBindings, older.validate());
    var packet = library.counterPacket().?;
    packet.schema = "suikoden-counter-actors/9";
    try std.testing.expectError(error.InvalidCounterBindings, packet.validate());
    packet.schema = "suikoden-counter-actors/10";
    try std.testing.expectError(error.InvalidCounterBindings, packet.validate());
    var legacy = library;
    legacy.schema = "suikoden-unite-actors/33";
    legacy.group_orders = null;
    legacy.enemy_wave = null;
    legacy.enemy_area_magic = null;
    legacy.enemy_regional = null;
    const reactions = try alloc.dupe(battle.counter.PartyReaction, library.counter.?.melee.?.party_reactions);
    for (reactions) |*reaction| reaction.return_program = null;
    legacy.counter.?.melee.?.party_reactions = reactions;
    var legacy_melee: std.ArrayList(battle.counter.MeleeEnemy) = .empty;
    for (library.counter.?.melee.?.enemies) |binding| if (binding.special == null or binding.special.?.return_program == null) try legacy_melee.append(alloc, binding);
    const bindings = legacy_melee.items;
    for (bindings) |*binding| if (binding.projectile != null) {
        binding.projectile.?.camera = null;
        const bytes = try std.json.Stringify.valueAlloc(alloc, binding.projectile.?, .{});
        try std.testing.expect(std.mem.indexOf(u8, bytes, "camera") == null);
    };
    legacy.counter.?.melee.?.enemies = bindings;
    try legacy.validate();
    try std.testing.expectEqualStrings("suikoden-counter-actors/10", legacy.counterPacket().?.schema);
    const items = try field.items.load(alloc, field.items.json);
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(content, items.value, &members, 1234);
    try state.attachUniteActors(&library);
    const capacity = 19 - state.partyCount() - state.enemyCount();
    for (state.unite_vm.auxiliary[0..capacity]) |*slot| slot.* = battle.actor_host.Actor.anchor(.{ 0, 0, 0 }, .{ 0, 0, 0 }, null);
    const before = state;
    try std.testing.expect(!try state.beginRabbitProjectile(state.partyCount(), 0));
    try std.testing.expectEqualDeep(before, state);
}

test "Rabbit live launch camera replaces moving channels before the same frame integration" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const content = try rabbitContent(alloc);
    const library = try rabbitActors(alloc);
    const items = try field.items.load(alloc, field.items.json);
    const request = library.counterPacket().?.meleeEnemy("killer_rabbit").?.projectile.?.camera.?;
    for ([_]bool{ false, true }) |moving| for ([_]bool{ false, true }) |scheduled| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(content, items.value, &members, 1234);
        try state.attachUniteActors(&library);
        state.phase = if (scheduled) .resolving else .battle_menu;
        state.acted = @splat(true);
        state.actor_camera = try @TypeOf(state.actor_camera.?).init(.{ .position = .{ -83, 17, -9 }, .angles = .{ -700, 13, 501 }, .c = .{ 3, -5, 1024 }, .d = .{ 3840, 3841, 3839 } });
        if (moving) {
            try state.actor_camera.?.requestQ12(request.target, 8);
        }
        const initial = state.actor_camera.?.current;
        if (scheduled) state.coordinator = .{ .stage = .dispatch, .current_actor = state.partyCount() } else try std.testing.expect(try state.beginRabbitProjectile(state.partyCount(), 0));
        const values = [_]u15{ 32767, 0 };
        var draws = battle.systems.Draws{ .values = &values };
        for (1..22) |update| {
            try state.tickReplay(.{}, &draws);
            inline for (.{ "position", "angles", "c", "d" }, 0..) |name, channel| {
                for (0..3) |axis| {
                    const destination = @field(request.target, name)[axis];
                    const velocity = @divTrunc(destination - initial[channel][axis], 20);
                    const expected = if (update <= 20) initial[channel][axis] + velocity * @as(i32, @intCast(update)) else destination;
                    try std.testing.expectEqual(expected, state.actor_camera.?.current[channel][axis]);
                }
            }
            try std.testing.expectEqual(@as(u16, @intCast(20 - @min(update, 20))), state.actor_camera.?.remaining[0]);
        }
    };
}

test "Rabbit live AI selects all six projectile targets and its ordinary fallback" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const content = try rabbitContent(alloc);
    const library = try rabbitActors(alloc);
    const items = try field.items.load(alloc, field.items.json);
    for (0..7) |scenario| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(content, items.value, &members, 1234);
        try state.attachUniteActors(&library);
        for (&members) |*member| {
            member.hp = 9999;
            member.max_hp = 9999;
        }
        state.acted = @splat(true);
        state.phase = .resolving;
        const owner = state.partyCount();
        const projectile = scenario < 6;
        const target = if (projectile) scenario else 0;
        state.coordinator = .{ .stage = .dispatch, .current_actor = owner };
        const values = [_]u15{ if (projectile) 32767 else 0, if (projectile) @intCast((target * 32767 + 99) / 100) else 32767, 0, 0 };
        var draws = battle.systems.Draws{ .values = &values };
        const expected = state.resolvePhysicalDamage(owner, target, 0, false);
        var contact: ?usize = null;
        var released: ?usize = null;
        for (1..180) |update| {
            try state.tickReplay(.{}, &draws);
            for (state.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
                try std.testing.expectEqual(@as(u8, @intCast(target)), playback.defender);
                try std.testing.expectEqual(if (projectile) battle.counter.Kind.projectile else .ordinary_hit, playback.kind);
                if (playback.contact_at != null and contact == null) contact = update;
            };
            if (state.active == null and released == null) released = update;
            if (released != null and !state.unite_vm.hasActors()) break;
        }
        try std.testing.expectEqual(@as(?usize, if (projectile) 64 else 79), contact);
        try std.testing.expectEqual(@as(?usize, if (projectile) 117 else 99), released);
        try std.testing.expectEqual(@as(usize, if (projectile) 3 else 4), draws.cursor);
        try std.testing.expectEqual(@as(u16, @intCast(9999 - expected)), members[target].hp);
        try std.testing.expect(!state.unite_vm.hasActors());
    }
}

test "Rabbit live contact rolls back and checkpoints restore projectile and hurt actors" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const content = try rabbitContent(alloc);
    const library = try rabbitActors(alloc);
    const other_library = try rabbitActors(alloc);
    const items = try field.items.load(alloc, field.items.json);
    const session = @import("combat_session");
    for ([_]u32{ 20, 50, 63, 64, 94, 110 }) |at| {
        var members: [6]battle.Member = undefined;
        var source = try battle.State.init(content, items.value, &members, 1234);
        try source.attachUniteActors(&library);
        const values = [_]u15{0};
        var draws = battle.systems.Draws{ .values = &values };
        const fingerprint = try session.fingerprint(source);
        const entry = session.Entry{ .id = "rabbit", .receipt = "rabbit-1", .content_id = "source-b", .encounter_id = content.encounters[0].id, .content_fingerprint = &fingerprint };
        var scratch: [6]battle.Member = undefined;
        var original = try session.Session.begin(entry, source, &scratch, draws);
        original.state.phase = .battle_menu;
        original.state.acted = @splat(true);
        try std.testing.expect(try original.state.beginRabbitProjectile(source.partyCount(), 0));
        for (0..at) |_| try original.tick(.{}, &draws);
        if (at == 63) {
            const before = original.state;
            const before_members = original.state.progress.party[0..6].*;
            var short = battle.systems.Draws{ .values = &.{} };
            try std.testing.expectError(error.RandomInputExhausted, original.state.tickReplay(.{}, &short));
            try std.testing.expectEqual(@as(usize, 0), short.cursor);
            try std.testing.expectEqual(before.camera_ticks, original.state.camera_ticks);
            try std.testing.expectEqualDeep(before.unite_vm, original.state.unite_vm);
            try std.testing.expectEqualDeep(before_members, original.state.progress.party[0..6].*);
        }
        var checkpoint = try original.capture(draws);
        const bytes = try std.json.Stringify.valueAlloc(alloc, checkpoint.state.unite_vm, .{});
        checkpoint.state.unite_vm = (try std.json.parseFromSlice(battle.unite_playback.State, alloc, bytes, .{})).value;
        var other_source = source;
        other_source.unite_actors = &other_library;
        var other_scratch: [6]battle.Member = undefined;
        var other_draws = battle.systems.Draws{ .values = &values };
        var resumed = try session.Session.begin(entry, other_source, &other_scratch, other_draws);
        try resumed.restore(checkpoint, &other_draws);
        for (at..170) |_| {
            try original.tick(.{}, &draws);
            try resumed.tick(.{}, &other_draws);
            try std.testing.expectEqual(draws.cursor, other_draws.cursor);
            try std.testing.expectEqualDeep(original.state.unite_vm, resumed.state.unite_vm);
            try std.testing.expectEqualDeep(original.state.progress.party, resumed.state.progress.party);
        }
        try std.testing.expect(!resumed.state.unite_vm.hasActors());
    }
}
