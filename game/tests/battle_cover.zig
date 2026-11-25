const std = @import("std");
const battle = @import("battle");
const field = @import("field");
const host = battle.actor_host;
const vm = battle.actor_program;
const counter = battle.counter;
const allocator = std.testing.allocator;
const Sounds = struct {
    status_actor: ?u16 = null,
    status_count: usize = 0,
    fn command(raw: *anyopaque, actor: u16, request: vm.Command, _: bool) !bool {
        const self: *Sounds = @ptrCast(@alignCast(raw));
        if (request == .status) {
            if (request.status.kind != .poison or request.status.threshold_percent != 20) return error.UnboundCoverCommand;
            self.status_actor = actor;
            self.status_count += 1;
        } else if (request != .sound) return error.UnboundCoverCommand;
        return true;
    }
    fn previous(_: *anyopaque, _: u16) !battle.presentation.ScreenPoint {
        return .{ .x = 0, .y = 0, .depth = 100 };
    }
};

test "Cover lock wait reads owner highlight bits and keeps legacy programs strict" {
    const code = [_]vm.Instruction{ .{ .wait = .{ .highlight_clear = .{ .target = .owner, .bits = 9 } } }, .{ .halt = {} } };
    const program = vm.Program{ .id = "wait", .instructions = &code };
    const packet = vm.Packet{ .schema = "suikoden-actor-programs/8", .programs = &.{program} };
    try packet.validate();
    var invalid = packet;
    invalid.schema = "suikoden-actor-programs/7";
    try std.testing.expectError(error.InvalidActorPrograms, invalid.validate());
    const data = try counter.load(allocator, @embedFile("fixtures/counter_actor_library.json"));
    defer data.deinit();
    const resource = data.value.animations.find("hero").?;
    for ([_]u8{ 1, 8, 9 }) |bits| {
        var actors = [_]host.Actor{ try host.Actor.init(resource, .{ 0, 0, 0 }), try host.Actor.init(resource, .{ 0, 0, 0 }) };
        actors[1].highlights = bits;
        var runtime = host.Runtime{ .actors = &actors };
        try runtime.dispatch(0, 1, program);
        try std.testing.expect(!actors[0].machine.?.halted);
        actors[1].signals = 0;
        try runtime.stepActor(0);
        try std.testing.expect(!actors[0].machine.?.halted);
        actors[1].highlights = 16;
        try runtime.stepActor(0);
        try std.testing.expect(actors[0].machine.?.halted);
    }
}

test "Cover source callbacks complete all 78 protectors in both party orders" {
    const parsed = try counter.load(allocator, @embedFile("fixtures/counter_actor_library.json"));
    defer parsed.deinit();
    const packet = parsed.value;
    var cases: usize = 0;
    for (packet.melee.?.enemies) |enemy| for (packet.melee.?.party_reactions, 0..) |party, index| for (0..2) |order| {
        if (std.mem.eql(u8, enemy.id, "strong_arm")) continue;
        const guard: u8 = @intCast(order);
        const ward: u8 = 1 - guard;
        const other = packet.melee.?.party_reactions[(index + 1) % packet.melee.?.party_reactions.len];
        var actors: [3]host.Actor = undefined;
        actors[guard] = try host.Actor.init(packet.animations.find(party.id).?, .{ 90 * 4096, 80 * 4096, 0 });
        actors[ward] = try host.Actor.init(packet.animations.find(other.id).?, .{ 120 * 4096, 40 * 4096, 0 });
        actors[2] = try host.Actor.init(packet.animations.find(enemy.id).?, .{ -160 * 4096, -20 * 4096, 0 });
        var children: [16]?host.Actor = @splat(null);
        var context = Sounds{};
        var camera = try @import("battle_camera").ActorController.init(@import("battle_camera").standard_battle);
        var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = packet.library(), .camera_controller = &camera, .external = .{ .context = &context, .command = Sounds.command, .previous_screen_position = Sounds.previous } };
        var action = try counter.Action.beginCovered(packet, &runtime, 2, ward, guard);
        var contacts: usize = 0;
        var guard_release: ?usize = null;
        var ward_return: ?usize = null;
        var saw_spin = false;
        for (1..1000) |tick| {
            runtime.beginUpdate();
            if (action.stage == .returning) try action.advance(packet, &runtime);
            for (0..3) |actor| {
                if (action.callbackActor() == @as(u8, @intCast(actor))) {
                    try action.advance(packet, &runtime);
                    if (action.stage == .contact) {
                        contacts += 1;
                        try action.acknowledgeContact(packet, &runtime);
                        if (std.mem.eql(u8, enemy.id, "wild_boar")) {
                            try std.testing.expectEqual(@as(i16, 0), actors[guard].shared_value);
                            try std.testing.expect(actors[guard].reaction_callback == null);
                        } else try std.testing.expectEqual(@as(u16, 1), actors[guard].animation);
                        try std.testing.expectEqualDeep(actors[ward].home_q12, actors[guard].position_q12);
                    }
                    if (action.returnReady(runtime)) try action.beginReturn(packet, &runtime);
                }
                try runtime.stepActor(@intCast(actor));
                if (actor == guard) saw_spin = saw_spin or actors[guard].reaction_callback == .spin;
                if (contacts != 0 and actor == guard and actors[guard].highlights & 9 == 0 and guard_release == null) guard_release = tick;
                if (contacts != 0 and actor == ward and actors[ward].movement != null and ward_return == null) ward_return = tick;
            }
            for (0..children.len) |child| if (children[child] != null) try runtime.stepActor(@intCast(actors.len + child));
            if (action.stage == .released) break;
        }
        try std.testing.expect(action.stage == .released);
        try std.testing.expectEqual(@as(usize, 1), contacts);
        const poison = std.mem.eql(u8, enemy.id, "mosquito");
        try std.testing.expectEqual(@as(usize, @intFromBool(poison)), context.status_count);
        if (poison) try std.testing.expectEqual(@as(?u16, guard), context.status_actor);
        try std.testing.expectEqual(std.mem.eql(u8, enemy.id, "wild_boar"), saw_spin);
        try std.testing.expectEqual(guard_release.? + @intFromBool(guard > ward), ward_return.?);
        for (actors) |actor| {
            try std.testing.expect(actor.machine.?.halted and actor.highlights == 0);
            try std.testing.expectEqualDeep(actor.home_q12, actor.position_q12);
        }
        cases += 1;
    };
    try std.testing.expectEqual(@as(usize, 1248), cases);
}

test "Cover live queued hits retain ward HP through protection KO Buddha and reversed order" {
    const base = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer base.deinit();
    const donors = try battle.load(allocator, @embedFile("fixtures/parry_battle.json"));
    defer donors.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const bundle = try host.loadBundle(allocator, @embedFile("fixtures/cover_actor_library.json"));
    defer bundle.deinit();
    const rebound = try host.loadBundle(allocator, @embedFile("fixtures/cover_actor_library.json"));
    defer rebound.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    const enemies = try allocator.dupe(battle.Profile, donors.value.enemies);
    defer allocator.free(enemies);
    const enemy_index = donors.value.enemyIndex("kobold_type_1").?;
    const resource = bundle.value.animations.find("kobold_type_1").?;
    enemies[enemy_index].sprite = base.value.uniteGraphic("kobold_type_1", resource.find(0).?.frames[0].pose).?;
    var content = base.value;
    content.enemies = enemies;
    var encounter = donors.value.encounters[0];
    content.encounters = @as(*const [1]battle.Encounter, &encounter);
    for (0..7) |scenario| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(content, items.value, &members, 17);
        try combat.attachUniteActors(&bundle.value);
        try combat.attachSpellScenes(&scenes.value);
        if (scenario == 4 or scenario == 6) std.mem.swap(battle.Member, &combat.progress.party[0], &combat.progress.party[1]);
        const ward: usize = if (scenario == 4 or scenario == 6) 1 else 0;
        const guard: usize = 1 - ward;
        combat.phase = .resolving;
        combat.acted = @splat(true);
        for (combat.progress.party, 0..) |*member, index| {
            member.max_hp = 5000;
            member.hp = 5000;
            member.inventory.slots = @splat(null);
            combat.actions[index] = .defend;
        }
        combat.progress.party[ward].hp = 1;
        if (scenario == 1) combat.protection[guard] = 2;
        if (scenario == 2 or scenario == 3 or scenario == 6) combat.progress.party[guard].hp = 1;
        if (scenario == 3 or scenario == 6) combat.progress.party[guard].inventory.slots[0] = .{ .id = .sacrificial_buddha, .uses = 0 };
        if (scenario == 5) combat.actions[guard] = .{ .attack = 0 };
        const initial_guard_hp = combat.hp(guard);
        const attacker = combat.partyCount();
        combat.acted[attacker] = false;
        var values: [128]u15 = @splat(12345);
        values[0] = 0;
        for (0..ward) |slot| values[1 + slot] = 0;
        values[1 + ward] = 99;
        values[2 + ward] = 0;
        values[3 + ward] = 24;
        var draws = battle.systems.Draws{ .values = &values };
        try combat.tickReplay(.{}, &draws);
        try std.testing.expect(combat.active != null and combat.active.?.counter_attack);
        try std.testing.expectEqual(@as(usize, 3) + ward, draws.cursor);
        var rollback = false;
        var saw_contact = false;
        var saw_revival = false;
        var source_rebound = false;
        for (0..800) |_| {
            for (combat.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
                try std.testing.expectEqual(counter.Kind.cover, playback.kind);
                try std.testing.expectEqual(@as(u8, @intCast(guard)), playback.victim());
                if (playback.action == null) continue;
                if (!rollback and playback.action.?.stage == .approach and combat.unite_vm.actors[attacker].signals & 2 != 0) {
                    const before = combat;
                    const before_members = members;
                    const cursor = draws.cursor;
                    var corrupt = combat.unite_vm;
                    corrupt.counter_actions[0].?.guard = null;
                    try std.testing.expectError(error.InvalidActorPlayback, corrupt.rebind(&bundle.value));
                    draws.values = values[0..cursor];
                    try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
                    try std.testing.expectEqualDeep(before_members, members);
                    try std.testing.expectEqualDeep(before.unite_vm, combat.unite_vm);
                    try std.testing.expectEqualDeep(before.active, combat.active);
                    try std.testing.expectEqual(cursor, draws.cursor);
                    draws.values = &values;
                    combat.unite_actors = &rebound.value;
                    rollback = true;
                    source_rebound = true;
                }
                if (playback.contact_at != null) {
                    saw_contact = true;
                    if (scenario == 5) try std.testing.expect(combat.actions[guard] != null and combat.actions[guard].? == .attack and combat.actions[guard].?.attack == 0);
                }
            };
            try combat.tickReplay(.{}, &draws);
            try std.testing.expectEqual(@as(u16, 1), combat.hp(ward));
            if (combat.revivalAge(guard)) |age| {
                saw_revival = true;
                if (age < combat.rules.automatic_revival.?.release_delay) {
                    try std.testing.expect(combat.unite_vm.scripted_actors[ward] != null);
                    try std.testing.expect(combat.unite_vm.actors[ward].movement == null);
                }
            }
            if (combat.phase != .resolving) break;
        }
        try std.testing.expect(rollback and source_rebound and saw_contact);
        try std.testing.expectEqual(scenario == 3 or scenario == 6, saw_revival);
        try std.testing.expect(combat.phase == .battle_menu and !combat.unite_vm.hasActors() and !combat.hasPendingRevival());
        try std.testing.expectEqual(@as(usize, 4) + ward, draws.cursor);
        const damage = battle.physicalDamage(combat.stats(attacker).attack, combat.stats(guard).defense, 24, scenario != 5);
        const expected: u16 = if (scenario == 1) initial_guard_hp else if (scenario == 2) 0 else if (scenario == 3 or scenario == 6) 2500 else @intCast(initial_guard_hp - damage);
        try std.testing.expectEqual(expected, combat.hp(guard));
        try std.testing.expectEqual(@as(u16, 0), combat.unite_vm.actors[guard].highlights);
    }
}

test "Cover admission refuses missing scripts or body art before claiming actors" {
    const data = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer data.deinit();
    const donors = try battle.load(allocator, @embedFile("fixtures/parry_battle.json"));
    defer donors.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const parsed = try host.loadBundle(allocator, @embedFile("fixtures/cover_actor_library.json"));
    defer parsed.deinit();
    var invalid = parsed.value;
    invalid.counter.?.cover = null;
    try std.testing.expectError(error.InvalidUniteBindings, invalid.validate());
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(data.value, items.value, &members, 17);
    try combat.attachUniteActors(&parsed.value);
    var content = combat.content;
    content.unite_graphics = &.{};
    combat.content = content;
    // Bonbon has no shared melee binding; no actors may be claimed on refusal.
    try std.testing.expectError(error.MissingCounterProgram, combat.beginCover(combat.partyCount(), 0, 1));
    try std.testing.expect(!combat.unite_vm.hasActors() and combat.active == null);
    combat.content.enemies = donors.value.enemies;
    combat.content.encounters = donors.value.encounters;
    try std.testing.expectError(error.MissingPhysicalArt, combat.beginCover(combat.partyCount(), 0, 1));
    try std.testing.expect(!combat.unite_vm.hasActors() and combat.active == null);
    try std.testing.expectError(error.InvalidActorBinding, combat.beginCover(combat.partyCount(), 0, 0));
}
