const std = @import("std");
const battle = @import("battle");
const counter = battle.counter;
const host = battle.actor_host;
const vm = battle.actor_program;
const allocator = std.testing.allocator;
const field = @import("field");

fn scenesWithOrdinaryDust(alloc: std.mem.Allocator, base: battle.spell_scene.Packet) !battle.spell_scene.Packet {
    const Dust = struct { entries: @TypeOf(base.entries), frames: @TypeOf(base.unite_impacts[0].frames) };
    const dust = try std.json.parseFromSlice(Dust, alloc, @embedFile("fixtures/ordinary_dust.json"), .{ .ignore_unknown_fields = true });
    defer dust.deinit();
    var packet = base;
    const entries = try alloc.alloc(@TypeOf(base.entries[0]), base.entries.len + dust.value.entries.len);
    errdefer alloc.free(entries);
    @memcpy(entries[0..base.entries.len], base.entries);
    @memcpy(entries[base.entries.len..], dust.value.entries);
    const frames = try alloc.dupe(@TypeOf(dust.value.frames[0]), dust.value.frames);
    errdefer alloc.free(frames);
    for (frames) |*frame| frame.entry += @intCast(base.entries.len);
    const impacts = try alloc.alloc(@TypeOf(base.unite_impacts[0]), base.unite_impacts.len + 1);
    errdefer alloc.free(impacts);
    @memcpy(impacts[0..base.unite_impacts.len], base.unite_impacts);
    impacts[base.unite_impacts.len] = .{ .id = 13, .frames = frames };
    packet.entries = entries;
    packet.unite_impacts = impacts;
    packet.schema = "suikoden-spell-scenes/51";
    try packet.validate(4096, 4096);
    return packet;
}

const Sounds = struct {
    count: u16 = 0,
    status_actor: ?u16 = null,
    status_count: usize = 0,
    fn command(raw: *anyopaque, actor: u16, request: vm.Command, _: bool) !bool {
        const self: *Sounds = @ptrCast(@alignCast(raw));
        if (request == .status) {
            if (request.status.kind != .poison or request.status.threshold_percent != 20) return error.UnboundCounterCommand;
            self.status_actor = actor;
            self.status_count += 1;
        } else if (request == .sound) self.count += 1 else return error.UnboundCounterCommand;
        return true;
    }
    fn previous(_: *anyopaque, _: u16) !battle.presentation.ScreenPoint {
        return .{ .x = 0, .y = 0, .depth = 100 };
    }
};

test "ranged source programs deliver hits and begin dodges before contact" {
    const Fixture = struct { programs: vm.Packet, animations: host.Resources, bindings: []const counter.RangedAttacker, dodges: []const counter.PartyReaction, critical_camera: counter.RangedCamera };
    const parsed = try std.json.parseFromSlice(Fixture, allocator, @embedFile("fixtures/party_ranged_actor_library.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const data = parsed.value;
    const packet = counter.Packet{ .schema = "suikoden-counter-actors/7", .programs = data.programs, .animations = data.animations, .defenders = &.{}, .enemies = &.{}, .ranged = .{ .attackers = data.bindings, .dodges = data.dodges, .critical_camera = data.critical_camera } };
    for ([_][]const u8{ "cleo", "ted", "juppo" }) |name| for ([_]struct { kind: counter.Kind, critical: bool }{
        .{ .kind = .ranged_hit, .critical = false },
        .{ .kind = .ranged_miss, .critical = false },
        .{ .kind = .ranged_hit, .critical = true },
    }) |case| {
        const kind = case.kind;
        var actors = [_]host.Actor{
            try host.Actor.init(data.animations.find(name).?, .{ 120 * 4096, 40 * 4096, 0 }),
            try host.Actor.init(data.animations.find("crow").?, .{ -128 * 4096, 0, 0 }),
        };
        var children: [4]?host.Actor = @splat(null);
        var sounds = Sounds{};
        var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = packet.library(), .external = .{ .context = &sounds, .command = Sounds.command, .previous_screen_position = Sounds.previous } };
        var action = try counter.Action.beginFor(packet, &runtime, 0, 1, kind);
        action.critical = case.critical;
        var contact: ?usize = null;
        var response: ?usize = null;
        var signal_two: ?usize = null;
        var critical_impact = false;
        var white = false;
        for (1..301) |tick| {
            if (action.stage == .returning) try action.advance(packet, &runtime);
            for (0..2) |actor| {
                if (action.callbackActor() == @as(u8, @intCast(actor))) {
                    const before = action.stage;
                    try action.advance(packet, &runtime);
                    if (before == .approach and action.stage == .hurt) response = tick;
                    if (action.stage == .contact) {
                        contact = tick;
                        try action.acknowledgeContact(packet, &runtime);
                        const binding = packet.rangedAttacker(name).?;
                        const selected = if (case.critical) binding.critical_hurt_program.? else binding.hurt_program;
                        try std.testing.expect(actors[1].machine.?.instructions.ptr == packet.programs.find(selected).?.instructions.ptr);
                    }
                    if (action.returnReady(runtime)) try action.beginReturn(packet, &runtime);
                }
                try runtime.stepActor(@intCast(actor));
            }
            for (0..children.len) |child| if (children[child] != null) {
                const expected_impact: u16 = if (std.mem.eql(u8, name, "juppo")) 3 else 19;
                if (children[child].?.resource != null and std.mem.eql(u8, children[child].?.resource.?.id, "shared_impacts") and children[child].?.animation == expected_impact) critical_impact = true;
                try runtime.stepActor(@intCast(actors.len + child));
            };
            if (actors[1].palette == .shared and actors[1].palette.shared == 0) white = true;
            if (signal_two == null and actors[0].signals & 2 != 0) signal_two = tick;
            if (action.stage == .released) break;
        }
        try std.testing.expect(action.stage == .released);
        try std.testing.expectEqual(kind == .ranged_hit and (case.critical or std.mem.eql(u8, name, "juppo")), critical_impact);
        if (kind == .ranged_hit) try std.testing.expect(white);
        if (kind == .ranged_hit) {
            try std.testing.expect(contact != null and response == null);
            try std.testing.expect(actors[0].signals & 16 != 0);
        } else {
            try std.testing.expect(contact == null and response != null and signal_two != null);
            try std.testing.expect(response.? <= signal_two.?);
        }
        for (actors) |actor| try std.testing.expect(actor.machine.?.halted and actor.highlights == 0);
    };
}

test "ranged attacks use the live battle scheduler for hit miss protection and knockout" {
    const Fixture = struct { programs: vm.Packet, animations: host.Resources, bindings: []const counter.RangedAttacker, dodges: []const counter.PartyReaction, critical_camera: counter.RangedCamera };
    const ranged = try std.json.parseFromSlice(Fixture, allocator, @embedFile("fixtures/party_ranged_actor_library.json"), .{ .ignore_unknown_fields = true });
    defer ranged.deinit();
    const content = try battle.load(allocator, @embedFile("fixtures/parry_battle.json"));
    defer content.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/parry_spell_scene_library.json"));
    defer scenes.deinit();
    var scene_packet = scenes.value;
    const impacts = try allocator.alloc(@TypeOf(scene_packet.unite_impacts[0]), scene_packet.unite_impacts.len + 1);
    defer allocator.free(impacts);
    @memcpy(impacts[0..scene_packet.unite_impacts.len], scene_packet.unite_impacts);
    impacts[impacts.len - 1] = impacts[0];
    impacts[impacts.len - 1].id = 3;
    scene_packet.unite_impacts = impacts;
    scene_packet.schema = "suikoden-spell-scenes/46";
    const bundle = host.Bundle{ .schema = "suikoden-unite-actors/21", .programs = ranged.value.programs, .animations = ranged.value.animations, .unites = &.{}, .counter = .{ .defenders = &.{}, .enemies = &.{}, .ranged = .{ .attackers = ranged.value.bindings, .dodges = ranged.value.dodges, .critical_camera = ranged.value.critical_camera } } };
    for ([_][]const u8{ "cleo", "ted", "juppo" }) |name| for (0..10) |scenario| for ([_]bool{ false, true }) |coordinated| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(content.value, items.value, &members, 17);
        var profiles = try allocator.dupe(battle.Profile, content.value.party);
        defer allocator.free(profiles);
        profiles[0].id = name;
        combat.content.party = profiles;
        combat.progress.party[0].id = name;
        var encounters = try allocator.dupe(battle.Encounter, content.value.encounters);
        defer allocator.free(encounters);
        encounters[0].enemies = &.{"crow"};
        if (scenario == 8) {
            encounters[0].enemies = &.{ "crow", "crow" };
            encounters[0].positions = &.{ .{ .x = -100, .y = 0, .z = 0 }, .{ .x = -160, .y = 0, .z = 0 } };
            encounters[0].enemy_rows = null;
            encounters[0].source_slots = null;
        }
        combat.content.encounters = encounters;
        const enemies = try allocator.dupe(battle.Profile, content.value.enemies);
        defer allocator.free(enemies);
        for (enemies) |*enemy| if (std.mem.eql(u8, enemy.id, "crow")) {
            enemy.max_hp = 5000;
            if (scenario == 0) enemy.affinities = .{ .fire = .weak };
        };
        combat.content.enemies = enemies;
        const piece = [_]battle.Pose{profiles[0].sprite};
        const owner_poses = try allocator.alloc(battle.UniteGraphicPose, ranged.value.animations.find(name).?.pose_count);
        defer allocator.free(owner_poses);
        for (owner_poses, 0..) |*pose, index| pose.* = .{ .id = @intCast(index), .sprite = piece[0], .pieces = &piece };
        const target_poses = try allocator.alloc(battle.UniteGraphicPose, ranged.value.animations.find("crow").?.pose_count);
        defer allocator.free(target_poses);
        for (target_poses, 0..) |*pose, index| pose.* = .{ .id = @intCast(index), .sprite = piece[0] };
        const graphics = [_]battle.UniteGraphic{ .{ .id = name, .poses = owner_poses }, .{ .id = "crow", .poses = target_poses } };
        combat.content.unite_graphics = &graphics;
        combat.startEncounter();
        if (scenario == 0) combat.weapon_augments[0] = .{ .rune = .fire, .fragments = 3 };
        combat.unite_actors = &bundle;
        try combat.attachSpellScenes(&scene_packet);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.acted[0] = false;
        combat.actions[0] = .{ .attack = 0 };
        if (coordinated) combat.coordinator = .{ .stage = .dispatch, .current_actor = 0 };
        if (scenario >= 5) combat.runes[0] = for (combat.content.systems.?.runes, 0..) |rune, index| {
            if (std.mem.eql(u8, rune.id, "double-beat")) break index;
        } else return error.MissingRune;
        if (scenario == 2) combat.protection[combat.partyCount()] = 1;
        if (scenario == 3 or scenario >= 8) combat.enemy_hp[0] = 1;
        const before_hp = combat.enemy_hp[0];
        var values: [256]u15 = @splat(99);
        const offset: usize = @intFromBool(!coordinated);
        values[0] = 0;
        values[offset] = if (scenario == 1 or scenario == 6) 99 else 0;
        values[offset + 1] = if (scenario == 4) 0 else 99;
        values[offset + 2] = 24;
        if (scenario == 5 or scenario == 8) {
            values[offset + 3] = 0;
            values[offset + 4] = 99;
            values[offset + 5] = 24;
        } else if (scenario == 6) {
            values[offset + 1] = 0;
            values[offset + 2] = 99;
            values[offset + 3] = 24;
        } else if (scenario == 7) values[offset + 3] = 99;
        var draws = battle.systems.Draws{ .values = &values };
        var projectile = false;
        var projectile_live = false;
        var projectile_births: usize = 0;
        var reaction = false;
        var hit_count: usize = 0;
        var previous_hp = before_hp;
        var previous_second_hp: u16 = if (scenario == 8) combat.enemy_hp[1] else 0;
        var rolled_back = false;
        var repeat_rollback = false;
        var repeat_origin: ?[3]i32 = null;
        var origin_verified = false;
        var retained_no_target = false;
        var critical_camera = false;
        var critical_impact = false;
        var critical_white = false;
        for (0..500) |_| {
            if (scenario == 0 and !rolled_back) for (combat.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
                if (playback.action == null or playback.action.?.stage != .approach or combat.unite_vm.actors[0].signals & 2 == 0) continue;
                const before = combat.unite_vm;
                const cursor = draws.cursor;
                draws.values = values[0..cursor];
                try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
                try std.testing.expectEqualDeep(before, combat.unite_vm);
                try std.testing.expectEqual(before_hp, combat.enemy_hp[0]);
                try std.testing.expectEqual(cursor, draws.cursor);
                draws.values = &values;
                rolled_back = true;
                break;
            };
            if (scenario == 5 and !repeat_rollback) for (combat.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
                const target = combat.partyCount();
                if (playback.action == null or playback.action.?.stage != .hurt or combat.unite_vm.actors[0].signals & 4 == 0 or combat.coordinatorLocked(target) or combat.unite_vm.ownsActor(target)) continue;
                repeat_origin = combat.unite_vm.actors[0].position_q12;
                const before = combat.unite_vm;
                const effect = combat.active;
                const cursor = draws.cursor;
                draws.values = values[0..cursor];
                try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
                try std.testing.expectEqualDeep(before, combat.unite_vm);
                try std.testing.expectEqualDeep(effect, combat.active);
                try std.testing.expect(combat.double_beat_pending[0]);
                try std.testing.expectEqual(cursor, draws.cursor);
                draws.values = &values;
                repeat_rollback = true;
                break;
            };
            try combat.tickReplay(.{}, &draws);
            if (scenario == 4) {
                if (combat.actor_camera) |camera_state| {
                    if (!critical_camera) {
                        const anchor = battle.layout.worldPosition(&combat, combat.partyCount());
                        try std.testing.expectEqualDeep([3]i32{ @intFromFloat(@round(anchor.x * 4096)), @intFromFloat(@round(anchor.y * 4096)), -81920 }, camera_state.target[0]);
                        try std.testing.expectEqualDeep(ranged.value.critical_camera.target.angles, camera_state.target[1]);
                        try std.testing.expectEqualDeep(ranged.value.critical_camera.target.translation, camera_state.target[2]);
                        try std.testing.expectEqualDeep(ranged.value.critical_camera.target.scale, camera_state.target[3]);
                        try std.testing.expectEqualDeep([4]u16{ 19, 19, 19, 19 }, camera_state.remaining);
                        critical_camera = true;
                    }
                }
                const expected_impact: u16 = if (std.mem.eql(u8, name, "juppo")) 3 else 19;
                for (combat.unite_vm.auxiliary) |child| if (child != null and child.?.resource != null and std.mem.eql(u8, child.?.resource.?.id, "shared_impacts") and child.?.animation == expected_impact) {
                    critical_impact = true;
                };
                const recipient = combat.unite_vm.actors[combat.partyCount()];
                if (recipient.palette == .shared and recipient.palette.shared == 0) critical_white = true;
            }
            if (scenario == 9 and combat.enemy_hp[0] == 0 and combat.double_beat_pending[0]) retained_no_target = true;
            if (repeat_rollback and !combat.double_beat_pending[0] and !origin_verified) {
                try std.testing.expectEqualDeep(repeat_origin.?, combat.unite_vm.actors[0].position_q12);
                origin_verified = true;
            }
            const current_projectile = for (combat.unite_vm.auxiliary) |child| {
                if (child != null and child.?.resource != null and std.mem.eql(u8, child.?.resource.?.id, name)) break true;
            } else false;
            if (current_projectile and !projectile_live) projectile_births += 1;
            projectile_live = current_projectile;
            projectile = projectile or current_projectile;
            if (combat.unite_vm.scripted_actors[combat.partyCount()] != null and combat.unite_vm.actors[combat.partyCount()].machine != null) reaction = true;
            if (combat.enemy_hp[0] != previous_hp) {
                hit_count += 1;
                previous_hp = combat.enemy_hp[0];
            }
            if (scenario == 8 and combat.enemy_hp[1] != previous_second_hp) {
                hit_count += 1;
                previous_second_hp = combat.enemy_hp[1];
            }
            if (combat.phase != .resolving) break;
        }
        if (!projectile or !reaction or combat.unite_vm.hasActors()) std.debug.print("ranged {s} scenario={d} coordinated={} phase={s} projectile={} reaction={} actors={} active={any} counter={any} clock={any}\n", .{ name, scenario, coordinated, @tagName(combat.phase), projectile, reaction, combat.unite_vm.hasActors(), combat.active, combat.unite_vm.counter_actions, combat.coordinator });
        try std.testing.expect(projectile and reaction and !combat.unite_vm.hasActors());
        try std.testing.expectEqual(scenario == 0, rolled_back);
        try std.testing.expectEqual(scenario == 5, repeat_rollback);
        try std.testing.expectEqual(scenario == 5, origin_verified);
        try std.testing.expectEqual(scenario == 9, retained_no_target);
        try std.testing.expectEqual(scenario == 4, critical_camera);
        try std.testing.expectEqual(scenario == 4, critical_impact);
        try std.testing.expectEqual(scenario == 4, critical_white);
        try std.testing.expectEqual(@as(usize, if (scenario == 5 or scenario == 8) 2 else if (scenario == 1 or scenario == 2) 0 else 1), hit_count);
        try std.testing.expectEqual(@as(usize, if (scenario >= 5 and scenario <= 8) 2 else 1), projectile_births);
        if (scenario >= 5 and scenario <= 8) try std.testing.expect(!combat.double_beat_pending[0]);
        if (scenario == 3 or scenario == 9) {
            try std.testing.expectEqual(@as(u16, 0), combat.enemy_hp[0]);
            try std.testing.expect(combat.phase == .victory);
        } else {
            if (combat.phase != .battle_menu) std.debug.print("ranged {s} scenario={d} coordinated={} phase={s} hp={d} actors={any} active={any} draws={d}\n", .{ name, scenario, coordinated, @tagName(combat.phase), combat.enemy_hp[0], combat.unite_vm.hasActors(), combat.active, draws.cursor });
            try std.testing.expect(combat.phase == .battle_menu);
            if (scenario == 1 or scenario == 2) try std.testing.expectEqual(before_hp, combat.enemy_hp[0]);
            if (scenario == 0) {
                const raw = battle.physicalDamage(combat.stats(0).attack, combat.stats(combat.partyCount()).defense, 24, false);
                const weakness = raw + raw / 2;
                try std.testing.expectEqual(weakness + (weakness / 20) * 3, @as(u32, before_hp - combat.enemy_hp[0]));
            }
            if (scenario == 4) try std.testing.expectEqual(battle.physicalDamage(combat.stats(0).attack, combat.stats(combat.partyCount()).defense, 24, false) * 3, @as(u32, before_hp - combat.enemy_hp[0]));
        }
    };
}

test "BonBon source actor keeps the attack and return clocks" {
    const parsed = try counter.load(allocator, @embedFile("fixtures/counter_actor_library.json"));
    defer parsed.deinit();
    const packet = parsed.value;
    const binding = packet.meleeEnemy("bonbon").?;
    var actors = [_]host.Actor{
        try host.Actor.init(packet.animations.find("bonbon").?, .{ -128 * 4096, 0, 0 }),
        try host.Actor.init(packet.animations.find("hero").?, .{ 120 * 4096, 0, 0 }),
    };
    var sounds = Sounds{};
    var runtime = host.Runtime{ .actors = &actors, .library = packet.library(), .external = .{ .context = &sounds, .command = Sounds.command, .previous_screen_position = Sounds.previous } };
    try runtime.dispatch(0, 1, packet.programs.find(binding.attack_program).?);
    var first: [3]?usize = @splat(null);
    for (1..15) |age| {
        try runtime.stepActor(0);
        for ([_]u16{ 1, 2, 4 }, 0..) |mask, i| if (first[i] == null and actors[0].signals & mask != 0) {
            first[i] = age;
        };
    }
    try std.testing.expectEqualDeep([3]?usize{ 2, 13, 14 }, first);
    try runtime.dispatch(0, 1, packet.programs.find(binding.return_program).?);
    for (0..30) |_| try runtime.stepActor(0);
    try std.testing.expectEqualDeep(actors[0].home_q12, actors[0].position_q12);
}

test "Melee source hit and miss callbacks complete against all 78 party resources" {
    const parsed = try counter.load(allocator, @embedFile("fixtures/counter_actor_library.json"));
    defer parsed.deinit();
    const packet = parsed.value;
    var cases: usize = 0;
    for (packet.melee.?.enemies) |enemy| for (packet.melee.?.party_reactions) |party| for ([_]counter.Kind{ .ordinary_hit, .ordinary_miss }) |kind| {
        if (std.mem.eql(u8, enemy.id, "strong_arm") or std.mem.eql(u8, enemy.id, "wild_boar")) continue; // Cooperation and camera/spin paths have separate checks.
        var actors = [_]host.Actor{
            try host.Actor.init(packet.animations.find(party.id).?, .{ 120 * 4096, 40 * 4096, 0 }),
            try host.Actor.init(packet.animations.find(enemy.id).?, .{ -160 * 4096, -20 * 4096, 0 }),
        };
        var children: [4]?host.Actor = @splat(null);
        var sounds = Sounds{};
        var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = packet.library(), .external = .{ .context = &sounds, .command = Sounds.command, .previous_screen_position = Sounds.previous } };
        var action = try counter.Action.beginFor(packet, &runtime, 1, 0, kind);
        var contacts: usize = 0;
        var returning = false;
        for (0..1000) |_| {
            try action.advance(packet, &runtime);
            if (action.stage == .contact) {
                try std.testing.expectEqual(counter.Kind.ordinary_hit, kind);
                contacts += 1;
                try action.acknowledgeContact(packet, &runtime);
                try std.testing.expectEqual(@as(u16, 1), actors[0].animation);
                try std.testing.expect(actors[1].signals & 16 != 0);
            }
            if (action.returnReady(runtime)) {
                try action.beginReturn(packet, &runtime);
                returning = true;
            }
            for (0..2) |actor| try runtime.stepActor(@intCast(actor));
            for (0..children.len) |child| if (children[child] != null) try runtime.stepActor(@intCast(actors.len + child));
            if (action.stage == .released) break;
        }
        if (action.stage != .released) std.debug.print("melee did not finish: {s} {s}, stage={s}\n", .{ party.id, @tagName(kind), @tagName(action.stage) });
        try std.testing.expect(returning and action.stage == .released);
        try std.testing.expectEqual(@as(usize, @intFromBool(kind == .ordinary_hit)), contacts);
        const poison = std.mem.eql(u8, enemy.id, "mosquito") and kind == .ordinary_hit;
        try std.testing.expectEqual(@as(usize, @intFromBool(poison)), sounds.status_count);
        if (poison) try std.testing.expectEqual(@as(?u16, 0), sounds.status_actor);
        for (actors) |actor| {
            try std.testing.expect(actor.machine.?.halted and actor.highlights == 0 and !actor.blue_trail_active);
            try std.testing.expectEqualDeep(actor.home_q12, actor.position_q12);
        }
        cases += 1;
    };
    try std.testing.expectEqual(@as(usize, 1092), cases);
}

test "Wild boar source attack dust spin camera and return complete for all party resources" {
    const parsed = try counter.load(allocator, @embedFile("fixtures/counter_actor_library.json"));
    defer parsed.deinit();
    const packet = parsed.value;
    var cases: usize = 0;
    for (packet.melee.?.party_reactions) |party| for ([_]counter.Kind{ .ordinary_hit, .ordinary_miss }) |kind| {
        var actors = [_]host.Actor{
            try host.Actor.init(packet.animations.find(party.id).?, .{ 120 * 4096, 40 * 4096, 0 }),
            try host.Actor.init(packet.animations.find("wild_boar").?, .{ -160 * 4096, -20 * 4096, 0 }),
        };
        var children: [17]?host.Actor = @splat(null);
        var sounds = Sounds{};
        var camera = try @import("battle_camera").ActorController.init(@import("battle_camera").standard_battle);
        var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = packet.library(), .camera_controller = &camera, .external = .{ .context = &sounds, .command = Sounds.command, .previous_screen_position = Sounds.previous } };
        var action = try counter.Action.beginFor(packet, &runtime, 1, 0, kind);
        var contacts: usize = 0;
        var spinning = false;
        var dust = false;
        var returning = false;
        for (0..1000) |_| {
            runtime.beginUpdate();
            try action.advance(packet, &runtime);
            if (action.stage == .contact) {
                contacts += 1;
                try action.acknowledgeContact(packet, &runtime);
            }
            if (action.returnReady(runtime)) {
                try action.beginReturn(packet, &runtime);
                returning = true;
            }
            for (0..2) |actor| try runtime.stepActor(@intCast(actor));
            var active_children = false;
            for (0..children.len) |child| if (children[child] != null) {
                dust = true;
                try runtime.stepActor(@intCast(actors.len + child));
                active_children = active_children or children[child] != null;
            };
            spinning = spinning or actors[0].reaction_callback == .spin;
            if (action.stage == .released and !active_children) break;
        }
        try std.testing.expect(returning and action.stage == .released and dust);
        try std.testing.expectEqual(@as(usize, @intFromBool(kind == .ordinary_hit)), contacts);
        try std.testing.expectEqual(kind == .ordinary_hit, spinning);
        try std.testing.expect(sounds.count > 0);
        for (actors) |actor| {
            try std.testing.expect(actor.machine.?.halted and actor.highlights == 0 and actor.reaction_callback == null);
            try std.testing.expectEqualDeep(actor.home_q12, actor.position_q12);
            try std.testing.expectEqual(@as(i16, 0), actor.draw_angles[2]);
        }
        cases += 1;
    };
    try std.testing.expectEqual(@as(usize, 156), cases);
}

test "Ant special source attack and recipient complete for all party resources" {
    const parsed = try counter.load(allocator, @embedFile("fixtures/counter_actor_library.json"));
    defer parsed.deinit();
    const packet = parsed.value;
    for (packet.melee.?.party_reactions) |party| {
        var actors = [_]host.Actor{
            try host.Actor.init(packet.animations.find(party.id).?, .{ 120 * 4096, 40 * 4096, 0 }),
            try host.Actor.init(packet.animations.find("red_soldier_ant").?, .{ -160 * 4096, -20 * 4096, 0 }),
        };
        var children: [4]?host.Actor = @splat(null);
        var sounds = Sounds{};
        var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = packet.library(), .external = .{ .context = &sounds, .command = Sounds.command, .previous_screen_position = Sounds.previous } };
        var action = try counter.Action.beginFor(packet, &runtime, 1, 0, .special);
        var contacts: usize = 0;
        var released = false;
        for (0..1000) |_| {
            try action.advance(packet, &runtime);
            if (action.stage == .contact) {
                contacts += 1;
                try action.acknowledgeContact(packet, &runtime);
                try std.testing.expectEqual(@as(u16, 0), actors[1].signals & 16);
            }
            if (action.returnReady(runtime)) {
                try std.testing.expect(actors[1].released);
                try action.beginReturn(packet, &runtime);
                released = true;
            }
            for (0..2) |actor| try runtime.stepActor(@intCast(actor));
            for (0..children.len) |child| if (children[child] != null) try runtime.stepActor(@intCast(actors.len + child));
            if (action.stage == .released) break;
        }
        if (action.stage != .released) std.debug.print("Ant special did not finish against {s}, stage={s}\n", .{ party.id, @tagName(action.stage) });
        try std.testing.expect(released and action.stage == .released);
        try std.testing.expectEqual(@as(usize, 1), contacts);
        for (actors) |actor| {
            try std.testing.expect(actor.machine.?.halted and actor.highlights == 0);
            try std.testing.expectEqualDeep(actor.home_q12, actor.position_q12);
        }
    }
}

test "C archer shared actor timeline agrees with retained source boundaries" {
    const Source = struct { impact_tick: usize, target_release_tick: usize, owner_release_tick: usize };
    const source = try std.json.parseFromSlice(Source, allocator, @embedFile("fixtures/world_c_archer.json"), .{ .ignore_unknown_fields = true });
    defer source.deinit();
    const Miss = struct { target_release_ticks: []const usize, owner_release_tick: usize };
    const miss = try std.json.parseFromSlice(Miss, allocator, @embedFile("fixtures/world_c_archer_misses_defend.json"), .{ .ignore_unknown_fields = true });
    defer miss.deinit();
    const Visual = struct { position: battle.Position, pose: u16, offset: [2]i8, visible: bool };
    const Projectile = struct { owner: u8, position: battle.Position, pose: u16, offset: [2]i8, visible: bool };
    const Rows = struct { rows: []const struct { visuals: []const Visual, projectiles: []const Projectile } };
    const visuals = try std.json.parseFromSlice(Rows, allocator, @embedFile("fixtures/world_c_archer_two_round_visual.json"), .{ .ignore_unknown_fields = true });
    defer visuals.deinit();
    const parsed = try counter.load(allocator, @embedFile("fixtures/counter_actor_library.json"));
    defer parsed.deinit();
    const packet = parsed.value;
    for ([_]struct { id: []const u8, kind: counter.Kind, release: usize }{
        .{ .id = "hero", .kind = .ordinary_hit, .release = source.value.target_release_tick },
        .{ .id = "hero", .kind = .ordinary_miss, .release = miss.value.target_release_ticks[0] },
        .{ .id = "gremio", .kind = .ordinary_miss, .release = miss.value.target_release_ticks[1] },
    }) |case| {
        var actors = [_]host.Actor{
            try host.Actor.init(packet.animations.find(case.id).?, .{ 120 * 4096, 50 * 4096, 0 }),
            try host.Actor.init(packet.animations.find("kobold_type_2").?, .{ -128 * 4096, 0, 0 }),
        };
        var children: [4]?host.Actor = @splat(null);
        var sounds = Sounds{};
        var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = packet.library(), .external = .{ .context = &sounds, .command = Sounds.command, .previous_screen_position = Sounds.previous } };
        var action = try counter.Action.beginFor(packet, &runtime, 1, 0, case.kind);
        var born: ?usize = null;
        var contact: ?usize = null;
        var target_release: ?usize = null;
        var owner_release: ?usize = null;
        for (1..200) |tick| {
            if (action.stage == .returning) try action.advance(packet, &runtime);
            for (0..2) |actor| {
                if (action.callbackActor() == @as(u8, @intCast(actor))) {
                    try action.advance(packet, &runtime);
                    if (action.stage == .contact) {
                        contact = tick;
                        try action.acknowledgeContact(packet, &runtime);
                    }
                    if (action.returnReady(runtime)) try action.beginReturn(packet, &runtime);
                }
            }
            for (0..2) |actor| {
                try runtime.stepActor(@intCast(actor));
                if (actor == 0 and actors[0].machine != null and actors[0].highlights == 0 and target_release == null) target_release = tick;
                if (actor == 1 and actors[1].highlights == 0 and owner_release == null) owner_release = tick;
            }
            for (0..children.len) |index| if (children[index] != null) {
                if (born == null) born = tick;
                try runtime.stepActor(@intCast(actors.len + index));
            };
            if (case.kind == .ordinary_hit and tick <= source.value.owner_release_tick) {
                const row = visuals.value.rows[tick - 1];
                const target = row.visuals[0];
                try std.testing.expect(target.visible);
                if (target.pose != actors[0].currentFrame().pose) std.debug.print("target pose mismatch on {d}: expected {d}, actual {d}\n", .{ tick, target.pose, actors[0].currentFrame().pose });
                try std.testing.expectEqual(target.pose, actors[0].currentFrame().pose);
                try std.testing.expectEqualDeep(target.offset, actors[0].screen_offset);
                try std.testing.expectEqualDeep([3]i32{ @intFromFloat(@round(target.position.x * 4096)), @intFromFloat(@round(target.position.y * 4096)), @intFromFloat(@round(target.position.z * 4096)) }, actors[0].position_q12);
                const expected = for (row.projectiles) |projectile| {
                    if (projectile.owner == 6) break @as(?Projectile, projectile);
                } else null;
                const actual = for (children) |maybe| {
                    if (maybe) |child| if (std.mem.eql(u8, child.resource.?.id, "kobold_type_2")) break @as(?host.Actor, child);
                } else null;
                try std.testing.expectEqual(expected != null, actual != null);
                if (expected) |arrow| {
                    const child = actual.?;
                    try std.testing.expectEqual(arrow.pose, child.currentFrame().pose);
                    try std.testing.expectEqualDeep(arrow.offset, child.screen_offset);
                    try std.testing.expectEqualDeep([3]i32{ @intFromFloat(@round(arrow.position.x * 4096)), @intFromFloat(@round(arrow.position.y * 4096)), @intFromFloat(@round(arrow.position.z * 4096)) }, child.position_q12);
                }
            }
            if (action.stage == .released) break;
        }
        const expected_contact: ?usize = if (case.kind == .ordinary_hit) source.value.impact_tick else null;
        if (contact != expected_contact or target_release != case.release or owner_release != source.value.owner_release_tick)
            std.debug.print("archer {s} {s} actual birth/contact/target/owner: {any}/{any}/{any}/{any}\n", .{ case.id, @tagName(case.kind), born, contact, target_release, owner_release });
        try std.testing.expectEqual(@as(?usize, 41), born);
        try std.testing.expectEqual(expected_contact, contact);
        try std.testing.expectEqual(@as(?usize, case.release), target_release);
        try std.testing.expectEqual(@as(?usize, source.value.owner_release_tick), owner_release);
        try std.testing.expectEqual(source.value.owner_release_tick, miss.value.owner_release_tick);
    }
}

test "BonBon journey source attack handles hit miss and protection" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_unites_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const bundle = try host.loadBundle(allocator, @embedFile("fixtures/journey_unites_actor_library.json"));
    defer bundle.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    for (0..3) |scenario| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(parsed.value, items.value, &members, 17);
        try combat.attachUniteActors(&bundle.value);
        try combat.attachSpellScenes(&scenes.value);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.actions = @splat(.defend);
        combat.runes = @splat(null);
        combat.progress.party[0].inventory.slots = @splat(null);
        combat.progress.party[0].max_hp = 5000;
        combat.progress.party[0].hp = 5000;
        if (scenario == 1) combat.protection[0] = 2;
        const enemy = combat.partyCount();
        combat.acted[enemy] = false;
        var values: [128]u15 = @splat(12345);
        values[0] = 0;
        values[1] = 99;
        values[2] = if (scenario == 2) 99 else 0;
        values[3] = 24;
        var draws = battle.systems.Draws{ .values = &values };
        try combat.tickReplay(.{}, &draws);
        try std.testing.expect(combat.active != null and combat.active.?.counter_attack);
        try std.testing.expectEqual(@as(u16, 5000), combat.hp(0));
        var rollback = false;
        var saw_miss_feedback = false;
        var saw_white = false;
        var moved = false;
        for (0..700) |_| {
            for (combat.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
                if (playback.action == null or rollback or playback.action.?.stage != .approach or combat.unite_vm.actors[enemy].signals & 2 == 0 or scenario == 2) continue;
                const before = combat;
                const before_member = combat.progress.party[0];
                const cursor = draws.cursor;
                draws.values = values[0..cursor];
                try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
                try std.testing.expectEqualDeep(before_member, combat.progress.party[0]);
                try std.testing.expectEqualDeep(before.unite_vm, combat.unite_vm);
                try std.testing.expectEqualDeep(before.active, combat.active);
                try std.testing.expectEqual(cursor, draws.cursor);
                draws.values = &values;
                rollback = true;
            };
            try combat.tickReplay(.{}, &draws);
            for (combat.unite_vm.counter_actions) |maybe| {
                const playback = maybe orelse continue;
                if (playback.showsMiss(0, combat.camera_ticks) and !saw_miss_feedback) {
                    try std.testing.expectEqual(.ordinary_miss, playback.kind);
                    try std.testing.expectEqual(@as(?u32, combat.camera_ticks), playback.miss_at);
                    try std.testing.expectEqual(@as(?u32, null), playback.contact_at);
                    try std.testing.expect(!playback.showsMiss(enemy, combat.camera_ticks));
                    try std.testing.expect(playback.showsMiss(0, combat.camera_ticks + 29));
                    try std.testing.expect(!playback.showsMiss(0, combat.camera_ticks + 30));
                    saw_miss_feedback = true;
                }
            }
            if (combat.unite_vm.scripted_actors[enemy] != null) moved = moved or combat.unite_vm.actors[enemy].position_q12[0] != combat.unite_vm.actors[enemy].home_q12[0];
            if (combat.unite_vm.scripted_actors[0] != null) {
                const actor = combat.unite_vm.actors[0];
                saw_white = saw_white or (actor.palette == .shared and actor.palette.shared == 0);
            }
            if (combat.phase != .resolving) break;
        }
        try std.testing.expect(moved and combat.phase == .battle_menu and !combat.unite_vm.hasActors());
        try std.testing.expectEqual(scenario == 2, saw_miss_feedback);
        try std.testing.expectEqual(scenario != 2, rollback);
        try std.testing.expectEqual(scenario != 2, saw_white);
        const amount: u16 = @intCast(battle.physicalDamage(combat.stats(enemy).attack, combat.stats(0).defense, 24, true));
        try std.testing.expectEqual(@as(u16, if (scenario == 0) 5000 - amount else 5000), combat.hp(0));
        try std.testing.expectEqual(@as(usize, if (scenario == 2) 3 else 4), draws.cursor);
    }
}

test "Wild boar journey source attack retains queued items damage protection misses knockout and rollback" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_unites_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const bundle = try host.loadBundle(allocator, @embedFile("fixtures/journey_unites_actor_library.json"));
    defer bundle.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scene_packet = try scenesWithOrdinaryDust(arena.allocator(), scenes.value);
    var legacy = scene_packet;
    legacy.schema = "suikoden-spell-scenes/50";
    try std.testing.expectError(error.InvalidSpellScenes, legacy.validate(4096, 4096));
    var cases: usize = 0;
    for ([_]?field.items.Id{ null, .medicine, .mega_medicine, .antitoxin, .needle }) |queued_item| for ([_]bool{ false, true }) |low_hp| for ([_]bool{ false, true }) |party_first| for (0..4) |scenario| {
        if (queued_item == null and (low_hp or party_first)) continue;
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(parsed.value, items.value, &members, 17);
        combat.encounter = for (combat.content.encounters, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.id, "area_a_5")) break i;
        } else return error.MissingBoarEncounter;
        combat.startEncounter();
        try combat.attachUniteActors(&bundle.value);
        try combat.attachSpellScenes(&scene_packet);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.actions = @splat(.defend);
        combat.runes = @splat(null);
        combat.progress.party[0].inventory.slots = @splat(null);
        const initial_hp: u16 = if (scenario == 3) 1 else if (queued_item != null) (if (low_hp) @as(u16, 1000) else 2500) else 5000;
        combat.progress.party[0].max_hp = if (scenario == 3) 1 else 5000;
        combat.progress.party[0].hp = initial_hp;
        if (queued_item) |id| {
            combat.actions[1] = .{ .item = .{ .slot = 0, .target = 0, .id = id } };
            combat.acted[1] = false;
            combat.progress.party[1].inventory.slots = @splat(null);
            combat.progress.party[1].inventory.slots[0] = .{ .id = id, .uses = items.value.consumable(id).?.uses };
            if (id == .antitoxin) combat.progress.party[0].status = .poisoned;
            if (id == .needle) combat.progress.party[0].balloons = 2;
        }
        if (party_first) {
            // Keep one living front target so the enemy must wait for the item lock.
            for (combat.progress.party[2..]) |*member| {
                member.hp = 0;
                member.status = .unconscious;
            }
            try combat.swapFormation(1, 3);
        }
        if (scenario == 1) {
            combat.protection[0] = 2;
            combat.protection[1] = 2;
        }
        const enemy = combat.partyCount();
        combat.acted[enemy] = false;
        var item_completed = false;
        var values: [128]u15 = @splat(24);
        values[0] = 0;
        values[1] = 99;
        values[2] = if (scenario == 2) 99 else 0;
        values[3] = 24;
        if (queued_item != null) {
            values[1] = 9; // The equal-speed boar wins priority over Gremio.
            values[2] = 99;
            values[3] = if (scenario == 2) 99 else 0;
        }
        if (party_first) {
            values[0] = 9;
            values[1] = 0;
            values[2] = 0; // Next enemy priority, before its locked-target wait.
            values[3] = 99;
            values[4] = if (scenario == 2) 99 else 0;
        }
        const healing: u16 = if (queued_item != null and scenario != 1 and scenario != 3) items.value.consumable(queued_item.?).?.heal_hp else 0;
        const hp_at_attack = initial_hp + @as(u16, if (party_first) healing else 0);
        const guard: ?u8 = if (queued_item != null and scenario < 2 and hp_at_attack < combat.progress.party[0].max_hp / 4) 1 else null;
        const victim = guard orelse 0;
        var draws = battle.systems.Draws{ .values = &values };
        const initial_guard_hp = combat.hp(1);
        try combat.tickReplay(.{}, &draws);
        if (party_first) try std.testing.expect(combat.medicine_action != null and combat.coordinator != null) else try std.testing.expect(combat.active != null and combat.active.?.counter_attack);
        try std.testing.expectEqual(initial_hp, combat.hp(0));
        var rollback = false;
        var saw_spin = false;
        var moved = false;
        var item_waited = false;
        var item_started = false;
        var attack_started = false;
        for (0..700) |_| {
            for (combat.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
                attack_started = true;
                try std.testing.expectEqual(guard, playback.guard);
                if (playback.action == null or rollback or playback.action.?.stage != .approach or combat.unite_vm.actors[enemy].signals & 2 == 0 or scenario == 2) continue;
                const before = combat;
                const before_members = members;
                const cursor = draws.cursor;
                draws.values = values[0..cursor];
                try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
                try std.testing.expectEqualDeep(before_members, members);
                try std.testing.expectEqualDeep(before.unite_vm, combat.unite_vm);
                try std.testing.expectEqualDeep(before.active, combat.active);
                try std.testing.expectEqual(cursor, draws.cursor);
                draws.values = &values;
                rollback = true;
            };
            try combat.tickReplay(.{}, &draws);
            if (queued_item != null) {
                if (party_first and combat.pending_enemy_actor == enemy and combat.medicine_action != null and !combat.medicine_action.?.target_released) item_waited = true;
                if (combat.coordinator) |clock| if (clock.stage == .dispatch and clock.current_actor == 1 and combat.coordinatorLocked(enemy)) {
                    item_waited = true;
                };
                if (combat.medicine_action != null and !item_started) {
                    item_started = true;
                    try std.testing.expect(!combat.coordinatorLocked(enemy));
                    try std.testing.expectEqual(@as(i16, 0), combat.unite_vm.actors[victim].draw_angles[2]);
                }
            }
            if (combat.unite_vm.scripted_actors[enemy] != null) moved = moved or combat.unite_vm.actors[enemy].position_q12[0] != combat.unite_vm.actors[enemy].home_q12[0];
            if (combat.unite_vm.scripted_actors[victim] != null) {
                const actor = combat.unite_vm.actors[victim];
                saw_spin = saw_spin or actor.reaction_callback == .spin;
            }
            if (combat.medicine_action) |item_state| item_completed = item_completed or (item_state.owner_released and item_state.target_released);
            if (combat.phase != .resolving) break;
        }
        try std.testing.expect(attack_started and moved and combat.phase == .battle_menu and !combat.unite_vm.hasActors());
        try std.testing.expectEqual(scenario != 2, rollback);
        try std.testing.expectEqual(scenario != 2, saw_spin);
        const amount: u16 = @intCast(battle.physicalDamage(combat.stats(enemy).attack, combat.stats(0).defense, 24, true));
        const damage: u16 = if (scenario == 0 and guard == null) amount else 0;
        try std.testing.expectEqual(@as(u16, if (scenario == 3) 0 else initial_hp - damage + healing), combat.hp(0));
        try std.testing.expectEqual(@as(usize, if (scenario == 2) 3 else 4) + @as(usize, if (queued_item != null) 2 else 0), draws.cursor);
        if (queued_item) |id| {
            const guard_damage: u16 = if (guard != null and scenario == 0) @intCast(battle.physicalDamage(combat.stats(enemy).attack, combat.stats(1).defense, 24, false)) else 0;
            try std.testing.expectEqual(initial_guard_hp - guard_damage, combat.hp(1));
            try std.testing.expect(combat.acted[1]);
            if (item_started != (party_first or scenario != 3)) std.debug.print("Wild boar item={s} low_hp={any} party_first={any} scenario={d} owner_hp={d} target_hp={d} status={s}\n", .{ @tagName(id), low_hp, party_first, scenario, combat.hp(1), combat.hp(0), @tagName(combat.progress.party[0].status) });
            try std.testing.expectEqual(party_first or scenario != 3, item_started);
            if (party_first or scenario != 3) {
                try std.testing.expect(item_waited);
                try std.testing.expect(item_completed);
            }
            if (scenario != 3) {
                try std.testing.expectEqual(field.game_state.Status.healthy, combat.progress.party[0].status);
                if (id == .needle) try std.testing.expectEqual(@as(u8, 1), combat.progress.party[0].balloons);
            }
            const uses = items.value.consumable(id).?.uses - @as(u16, if (scenario == 3 and !party_first) 0 else 1);
            if (uses == 0) try std.testing.expect(combat.progress.party[1].inventory.slots[0] == null) else {
                try std.testing.expectEqual(id, combat.progress.party[1].inventory.slots[0].?.id);
                try std.testing.expectEqual(uses, combat.progress.party[1].inventory.slots[0].?.uses);
            }
        }
        cases += 1;
    };
    try std.testing.expectEqual(@as(usize, 68), cases);
}

test "opening journey source encounters complete mixed rounds with queued healing and statuses" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_unites_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const bundle = try host.loadBundle(allocator, @embedFile("fixtures/journey_unites_actor_library.json"));
    defer bundle.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const packet = try scenesWithOrdinaryDust(arena.allocator(), scenes.value);
    var cases: usize = 0;
    for ([_][]const u8{ "area_a_1", "area_a_2", "area_a_4", "area_a_5", "area_a_6", "area_a_9" }) |encounter| for ([_]u15{ 51, 99 }) |roll| for (0..4) |condition| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(parsed.value, items.value, &members, 17);
        combat.encounter = for (combat.content.encounters, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.id, encounter)) break index;
        } else return error.MissingSourceEncounter;
        combat.startEncounter();
        try combat.attachUniteActors(&bundle.value);
        try combat.attachSpellScenes(&packet);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.actions = @splat(.defend);
        combat.runes = @splat(null);
        for (combat.progress.party, 0..) |*member, actor| {
            member.inventory.slots = @splat(null);
            member.max_hp = 5000;
            member.hp = if (actor == 0) 3000 else 5000;
            if (condition == 1) combat.protection[actor] = 2;
        }
        if (condition == 2) {
            combat.progress.party[0].status = .poisoned;
            combat.progress.party[0].balloons = 2;
            combat.asleep[0] = 1;
            combat.actions[0] = null;
        }
        if (condition == 3) {
            combat.progress.party[0].hp = 1;
            combat.progress.party[0].max_hp = 1;
        }
        const initial = members;
        combat.progress.party[5].inventory.slots[0] = .{ .id = .medicine, .uses = 6 };
        combat.actions[5] = .{ .item = .{ .id = .medicine, .slot = 0, .target = 0 } };
        combat.acted[5] = false;
        for (combat.partyCount()..combat.partyCount() + combat.enemyCount()) |enemy| combat.acted[enemy] = false;
        var values: [2048]u15 = @splat(roll);
        var draws = battle.systems.Draws{ .values = &values };
        var started: [6]bool = @splat(false);
        var contacted: [6]bool = @splat(false);
        var damage: [6]u16 = @splat(0);
        var overlap = false;
        var saw_item = false;
        var rollback = false;
        for (0..2500) |_| {
            for (combat.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
                if (roll == 99 or rollback or playback.action == null or playback.action.?.stage != .approach or combat.unite_vm.actors[playback.attacker].signals & 2 == 0) continue;
                const before = combat;
                const before_members = members;
                const cursor = draws.cursor;
                draws.values = values[0..cursor];
                try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
                try std.testing.expectEqualDeep(before_members, members);
                try std.testing.expectEqualDeep(before.unite_vm, combat.unite_vm);
                try std.testing.expectEqualDeep(before.active, combat.active);
                try std.testing.expectEqualDeep(before.medicine_action, combat.medicine_action);
                try std.testing.expectEqualDeep(before.coordinator, combat.coordinator);
                try std.testing.expectEqualDeep(before.actor_camera, combat.actor_camera);
                try std.testing.expectEqual(cursor, draws.cursor);
                draws.values = &values;
                rollback = true;
            };
            try combat.tickReplay(.{}, &draws);
            var actors: usize = 0;
            for (combat.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
                actors += 1;
                const enemy = playback.attacker - combat.partyCount();
                started[enemy] = true;
                const expected_kind: counter.Kind = if (roll == 51) .ordinary_hit else .ordinary_miss;
                try std.testing.expectEqual(expected_kind, playback.kind);
                if (playback.contact_at != null and !contacted[enemy]) {
                    contacted[enemy] = true;
                    const victim = playback.victim();
                    const expected = if (condition == 1) 0 else battle.physicalDamage(combat.stats(playback.attacker).attack, combat.stats(victim).defense, roll, victim != 5 and !(condition == 2 and victim == 0));
                    try std.testing.expectEqual(expected, playback.amount);
                    damage[victim] += @intCast(expected);
                }
            };
            overlap = overlap or actors > 1;
            if (combat.medicine_action) |item| {
                saw_item = true;
                if (item.ticks >= item.timing.pending_tick) try std.testing.expectEqual(@as(u16, if (condition == 1 or condition == 3) 0 else 100), item.amount);
            }
            if (combat.phase != .resolving) break;
        }
        if (combat.phase != .battle_menu) std.debug.print("mixed round failed {s} roll={d} condition={d} phase={s}\n", .{ encounter, roll, condition, @tagName(combat.phase) });
        try std.testing.expect(combat.phase == .battle_menu and combat.round == 2 and !combat.unite_vm.hasActors());
        try std.testing.expect(saw_item);
        try std.testing.expectEqual(roll == 51, rollback);
        try std.testing.expectEqual(combat.enemyCount() > 1, overlap);
        try std.testing.expectEqual(@as(u16, 5), combat.progress.party[5].inventory.slots[0].?.uses);
        for (0..combat.enemyCount()) |enemy| {
            try std.testing.expect(started[enemy]);
            try std.testing.expectEqual(roll == 51, contacted[enemy]);
        }
        for (0..combat.partyCount()) |actor| {
            const healing: u16 = if (actor == 0 and condition != 1 and condition != 3) 100 else 0;
            const poison: u16 = if (actor == 0 and condition == 2) 250 else 0;
            const expected = (initial[actor].hp -| damage[actor]) + healing - poison;
            try std.testing.expectEqual(expected, combat.hp(actor));
        }
        if (condition == 2) {
            try std.testing.expectEqual(field.game_state.Status.poisoned, combat.progress.party[0].status);
            try std.testing.expectEqual(@as(u8, 2), combat.progress.party[0].balloons);
            try std.testing.expectEqual(@as(u8, 1), combat.asleep[0]);
        }
        cases += 1;
    };
    try std.testing.expectEqual(@as(usize, 48), cases);
}

test "opening journey source rounds mix spells healing items and enemy returns" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_unites_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const bundle = try host.loadBundle(allocator, @embedFile("fixtures/journey_unites_actor_library.json"));
    defer bundle.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    const integration = try battle.IntegrationHost.init(allocator);
    defer integration.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const packet = try scenesWithOrdinaryDust(arena.allocator(), scenes.value);
    const enemies = try arena.allocator().dupe(battle.Profile, parsed.value.enemies);
    for (enemies) |*enemy| enemy.max_hp = 5000;
    var content = parsed.value;
    content.enemies = enemies;
    var cases: usize = 0;
    for ([_][]const u8{ "area_a_1", "area_a_2", "area_a_4", "area_a_5", "area_a_6", "area_a_9" }) |encounter| for ([_]usize{ 0, 5 }) |caster| for ([_]bool{ false, true }) |healing| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(content, items.value, &members, 17);
        combat.encounter = for (content.encounters, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.id, encounter)) break index;
        } else return error.MissingSourceEncounter;
        combat.startEncounter();
        combat.integration = .{ .host = integration };
        try combat.attachUniteActors(&bundle.value);
        try combat.attachSpellScenes(&packet);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.actions = @splat(.defend);
        combat.runes = @splat(null);
        for (combat.progress.party) |*member| {
            member.inventory.slots = @splat(null);
            member.max_hp = 5000;
            member.hp = 3000;
            member.rune_charges = .{ 9, 9, 9, 9 };
            member.max_rune_charges = .{ 9, 9, 9, 9 };
        }
        const item_owner = 5 - caster;
        combat.progress.party[item_owner].inventory.slots[0] = .{ .id = .medicine, .uses = 6 };
        combat.actions[item_owner] = .{ .item = .{ .id = .medicine, .slot = 0, .target = 1 } };
        const spell = for (content.systems.?.spells, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.id, if (healing) "spell_9" else "spell_1")) break index;
        } else return error.MissingSpell;
        combat.runes[caster] = content.systems.?.runeIndex(if (healing) "water" else "fire");
        try std.testing.expect(combat.canCast(caster, spell));
        combat.actions[caster] = .{ .spell = .{ .index = spell, .target = if (healing) 1 else 0 } };
        combat.acted[caster] = false;
        combat.acted[item_owner] = false;
        for (combat.partyCount()..combat.partyCount() + combat.enemyCount()) |enemy| combat.acted[enemy] = false;
        var item_completed = false;
        var values: [8192]u15 = @splat(51);
        var draws = battle.systems.Draws{ .values = &values };
        var saw_spell = false;
        var saw_item = false;
        var contacts: [6]bool = @splat(false);
        var recipient_damage: u16 = 0;
        var healed = false;
        for (0..3500) |_| {
            try combat.tickReplay(.{}, &draws);
            if (combat.active) |effect| if (effect.kind == .cast) {
                saw_spell = true;
                try std.testing.expect(effect.scene != null);
                try std.testing.expectEqual(caster, effect.actor);
            };
            if (combat.medicine_action != null) saw_item = true;
            for (combat.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
                const enemy = playback.attacker - combat.partyCount();
                if (playback.contact_at != null and !contacts[enemy]) {
                    contacts[enemy] = true;
                    if (playback.victim() == 1) recipient_damage += @intCast(playback.amount);
                }
            };
            if (healing and !healed and combat.progress.party[caster].rune_charges[0] == 8) {
                healed = true;
                try std.testing.expectEqual(@as(u16, 5000), combat.hp(1));
            }
            if (combat.medicine_action) |item_state| item_completed = item_completed or (item_state.owner_released and item_state.target_released);
            if (combat.phase != .resolving) break;
        }
        if (combat.phase != .battle_menu) std.debug.print("mixed spell round failed {s} caster={d} healing={} phase={s}\n", .{ encounter, caster, healing, @tagName(combat.phase) });
        try std.testing.expect(combat.phase == .battle_menu and combat.round == 2 and !combat.unite_vm.hasActors());
        try std.testing.expect(saw_spell and saw_item);
        try std.testing.expect(item_completed);
        try std.testing.expectEqual(@as(u8, 8), combat.progress.party[caster].rune_charges[0]);
        try std.testing.expectEqual(@as(u16, 5), combat.progress.party[item_owner].inventory.slots[0].?.uses);
        for (0..combat.enemyCount()) |enemy| {
            try std.testing.expect(contacts[enemy]);
            if (!healing and enemy == 0) try std.testing.expect(combat.enemy_hp[enemy] < 5000) else try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[enemy]);
        }
        if (healing) {
            try std.testing.expect(healed and combat.hp(1) >= 5000 - recipient_damage and combat.hp(1) <= 5000);
        } else try std.testing.expectEqual(@as(u16, 3100) - recipient_damage, combat.hp(1));
        cases += 1;
    };
    try std.testing.expectEqual(@as(usize, 24), cases);
}

test "opening journey source rounds mix physical runes Fisherman and Medicine" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_unites_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const bundle = try host.loadBundle(allocator, @embedFile("fixtures/journey_unites_actor_library.json"));
    defer bundle.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    const integration = try battle.IntegrationHost.init(allocator);
    defer integration.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const packet = try scenesWithOrdinaryDust(arena.allocator(), scenes.value);
    const enemies = try arena.allocator().dupe(battle.Profile, parsed.value.enemies);
    for (enemies) |*enemy| enemy.max_hp = 5000;
    var cases: usize = 0;
    var interruptions: usize = 0;
    const combat = try arena.allocator().create(battle.State);
    const scratch = try arena.allocator().create(battle.State);
    for ([_][]const u8{ "area_a_1", "area_a_2", "area_a_4", "area_a_5", "area_a_6", "area_a_9" }) |encounter| for ([_]struct { rune: []const u8, id: []const u8, owner: usize, numerator: u16, impact: u16 }{
        .{ .rune = "boar", .id = "pahn", .owner = 2, .numerator = 20, .impact = 323 },
        .{ .rune = "clone", .id = "hero", .owner = 0, .numerator = 20, .impact = 69 },
        .{ .rune = "shrike", .id = "kasumi", .owner = 0, .numerator = 20, .impact = 160 },
        .{ .rune = "falcon", .id = "valeria", .owner = 0, .numerator = 30, .impact = 159 },
        .{ .rune = "hate", .id = "ronnie", .owner = 0, .numerator = 30, .impact = 61 },
        .{ .rune = "trick", .id = "juppo", .owner = 0, .numerator = 15, .impact = 111 },
    }) |technique| for ([_]bool{ false, true }) |physical_first| for ([_]bool{ false, true }) |protected| {
        var ids: [6][]const u8 = undefined;
        for (&ids, parsed.value.initial_party.?) |*id, original| id.* = original;
        ids[technique.owner] = technique.id;
        var content = parsed.value;
        content.initial_party = &ids;
        content.enemies = enemies;
        var members: [6]battle.Member = undefined;
        combat.* = try battle.State.init(content, items.value, &members, 17);
        combat.encounter = for (content.encounters, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.id, encounter)) break index;
        } else return error.MissingSourceEncounter;
        combat.startEncounter();
        combat.integration = .{ .host = integration };
        try combat.attachUniteActors(&bundle.value);
        try combat.attachSpellScenes(&packet);
        if (std.mem.eql(u8, technique.id, "kasumi") or std.mem.eql(u8, technique.id, "valeria")) {
            try std.testing.expect(combat.partyProfile(technique.owner).rune_locked);
            try std.testing.expect(combat.hasRune(technique.owner, technique.rune));
        }
        combat.runes = @splat(null);
        combat.runes[technique.owner] = content.systems.?.runeIndex(technique.rune);
        try std.testing.expect(combat.canPhysicalRune(technique.owner));
        combat.actions = @splat(null);
        combat.choose(4);
        combat.queue(.{ .unite = 0 });
        try std.testing.expect(combat.uniteBoundaryFor(4) != null);
        for (combat.actions[0..combat.partyCount()]) |*action| if (action.* == null) {
            action.* = .defend;
        };
        combat.actions[technique.owner] = .{ .rune_attack = 0 };
        combat.actions[1] = .{ .item = .{ .id = .medicine, .slot = 0, .target = 3 } };
        for (combat.progress.party) |*member| {
            member.inventory.slots = @splat(null);
            member.max_hp = 5000;
            member.hp = 3000;
        }
        combat.progress.party[1].inventory.slots[0] = .{ .id = .medicine, .uses = 6 };
        combat.base_stats[if (physical_first) technique.owner else 4].speed = 999;
        if (protected) combat.protection = @splat(2);
        const charges = combat.progress.party[technique.owner].rune_charges;
        const defense = combat.stats(combat.partyCount()).defense;
        const physical_damage = battle.physicalDamage(combat.stats(technique.owner).attack, defense, 51, false) * technique.numerator / 10;
        const unite_damage = (battle.physicalDamage(combat.stats(4).attack, defense, 51, false) + battle.physicalDamage(combat.stats(5).attack, defense, 51, false)) * 3;
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.acted[technique.owner] = false;
        combat.acted[4] = false;
        combat.acted[1] = false;
        for (combat.partyCount()..combat.partyCount() + combat.enemyCount()) |enemy| combat.acted[enemy] = false;
        var item_completed = false;
        var values: [8192]u15 = @splat(51);
        var draws = battle.systems.Draws{ .values = &values };
        var saw_physical = false;
        var saw_unite = false;
        var saw_item = false;
        var contacts: [6]bool = @splat(false);
        var retried = false;
        var first_physical: ?bool = null;
        var checked_lock = false;
        var interrupted = false;
        for (0..3500) |_| {
            if (physical_first and combat.enemyCount() > 1 and !checked_lock) if (combat.unite_vm.physical_actions[technique.owner]) |playback| if (playback.action != null and playback.action.?.stage != .released) {
                scratch.* = combat.*;
                const refused = scratch;
                try std.testing.expect(!refused.unite_vm.ownsActor(combat.partyCount() + 1));
                try std.testing.expectError(error.ActorAlreadyOwned, refused.beginMelee(combat.partyCount() + 1, technique.owner, true));
                try std.testing.expectEqualDeep(combat.unite_vm, refused.unite_vm);
                checked_lock = true;
            };
            const prior_binding = combat.unite_vm.scripted_actors[technique.owner];
            const prior_position = combat.unite_vm.actors[technique.owner].position_q12;
            if (combat.unite_vm.physical_actions[technique.owner]) |playback| if (!retried and combat.camera_ticks + 1 == playback.start_at + technique.impact - 1) {
                scratch.* = combat.*;
                const before = scratch;
                const before_members = members;
                const cursor = draws.cursor;
                draws.values = values[0..cursor];
                try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
                try std.testing.expectEqualDeep(before_members, members);
                try std.testing.expectEqualDeep(before.enemy_hp, combat.enemy_hp);
                try std.testing.expectEqualDeep(before.unite_vm, combat.unite_vm);
                try std.testing.expectEqualDeep(before.active, combat.active);
                try std.testing.expectEqualDeep(before.coordinator, combat.coordinator);
                try std.testing.expectEqualDeep(before.actor_camera, combat.actor_camera);
                try std.testing.expectEqualDeep(before.medicine_action, combat.medicine_action);
                try std.testing.expectEqualDeep(before.unite_boundaries, combat.unite_boundaries);
                try std.testing.expectEqualDeep(before.unite_returns, combat.unite_returns);
                try std.testing.expectEqual(before.camera_ticks, combat.camera_ticks);
                try std.testing.expectEqual(cursor, draws.cursor);
                draws.values = &values;
                retried = true;
            };
            combat.tickReplay(.{}, &draws) catch |err| {
                std.debug.print("mixed dispatch error {s} rune={s} first={} protected={} tick={d}: {s}\n", .{ encounter, technique.rune, physical_first, protected, combat.camera_ticks, @errorName(err) });
                return err;
            };
            if (prior_binding) |prior| if (prior.family == .physical) if (combat.unite_vm.scripted_actors[technique.owner]) |current| if (current.family == .counter) {
                interrupted = true;
                try std.testing.expectEqualDeep(prior_position, combat.unite_vm.actors[technique.owner].position_q12);
                if (combat.unite_vm.physical_actions[technique.owner]) |playback| try std.testing.expect(playback.owner_done);
            };
            if (first_physical == null and (combat.sourcePhysicalRuneOwner(technique.owner) or combat.hasLiveUniteActors())) first_physical = combat.sourcePhysicalRuneOwner(technique.owner);
            saw_physical = saw_physical or combat.sourcePhysicalRuneOwner(technique.owner);
            saw_unite = saw_unite or combat.hasLiveUniteActors();
            saw_item = saw_item or combat.medicine_action != null;
            for (combat.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
                if (playback.contact_at != null) contacts[playback.attacker - combat.partyCount()] = true;
            };
            if (combat.medicine_action) |item_state| item_completed = item_completed or (item_state.owner_released and item_state.target_released);
            if (combat.phase != .resolving) break;
        }
        if (combat.phase != .battle_menu or combat.round != 2) std.debug.print("mixed physical round failed {s} rune={s} first={} protected={} phase={s} round={d}\n", .{ encounter, technique.rune, physical_first, protected, @tagName(combat.phase), combat.round });
        try std.testing.expect(combat.phase == .battle_menu and combat.round == 2);
        try std.testing.expect(!combat.hasLiveUniteActors());
        for (0..combat.partyCount() + combat.enemyCount()) |actor| {
            if (combat.coordinatorLocked(actor)) std.debug.print("held menu lock {s} rune={s} actor={d} first={} protected={}\n", .{ encounter, technique.rune, actor, physical_first, protected });
            try std.testing.expect(!combat.coordinatorLocked(actor));
        }
        const settled_members = members;
        const settled_enemies = combat.enemy_hp;
        // Released actor/auxiliary tails keep updating in the command menu.
        for (0..300) |_| {
            if (!combat.unite_vm.hasActors()) break;
            try combat.tickReplay(.{}, &draws);
            try std.testing.expectEqual(battle.Phase.battle_menu, combat.phase);
            try std.testing.expectEqualDeep(settled_members, members);
            try std.testing.expectEqualDeep(settled_enemies, combat.enemy_hp);
        }
        try std.testing.expect(!combat.unite_vm.hasActors() and !combat.hasUniteReturns());
        try std.testing.expect(saw_physical and saw_unite and saw_item and retried);
        try std.testing.expectEqual(@as(?bool, physical_first), first_physical);
        if (physical_first and combat.enemyCount() > 1) try std.testing.expect(checked_lock);
        if (interrupted) interruptions += 1;
        try std.testing.expectEqual(@as(u8, 1), combat.unbalanced[4]);
        try std.testing.expectEqual(@as(u8, 1), combat.unbalanced[5]);
        try std.testing.expectEqual(@as(u8, if (std.mem.eql(u8, technique.rune, "boar") or std.mem.eql(u8, technique.rune, "clone")) 1 else 0), combat.unbalanced[technique.owner]);
        try std.testing.expectEqual(@as(u16, @intCast(5000 - if (protected) 0 else physical_damage + unite_damage)), combat.enemy_hp[0]);
        for (1..combat.enemyCount()) |enemy| try std.testing.expectEqual(@as(u16, 5000), combat.enemy_hp[enemy]);
        for (0..combat.enemyCount()) |enemy| try std.testing.expect(contacts[enemy]);
        try std.testing.expectEqualDeep(charges, combat.progress.party[technique.owner].rune_charges);
        try std.testing.expectEqual(@as(u16, 5), combat.progress.party[1].inventory.slots[0].?.uses);
        try std.testing.expect(item_completed);
        cases += 1;
    };
    try std.testing.expectEqual(@as(usize, 144), cases);
    try std.testing.expect(interruptions > 0);
}

test "Crow journey source dive reaches every party row and retains contact rollback" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_unites_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const bundle = try host.loadBundle(allocator, @embedFile("fixtures/journey_unites_actor_library.json"));
    defer bundle.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    for (0..6) |target| for (0..4) |scenario| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(parsed.value, items.value, &members, 17);
        combat.encounter = for (combat.content.encounters, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.id, "area_a_4")) break index;
        } else return error.MissingCrowEncounter;
        combat.startEncounter();
        try combat.attachUniteActors(&bundle.value);
        try combat.attachSpellScenes(&scenes.value);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.actions = @splat(.defend);
        combat.runes = @splat(null);
        combat.progress.party[target].inventory.slots = @splat(null);
        const hp: u16 = if (scenario == 3) 1 else 5000;
        combat.progress.party[target].hp = hp;
        combat.progress.party[target].max_hp = hp;
        if (scenario == 1) combat.protection[target] = 2;
        const enemy = combat.partyCount();
        combat.acted[enemy] = false;
        var values: [128]u15 = @splat(24);
        @memset(values[0 .. target + 1], 0);
        values[target + 1] = 99;
        values[target + 2] = if (scenario == 2) 99 else 0;
        var draws = battle.systems.Draws{ .values = &values };
        try combat.tickReplay(.{}, &draws);
        try std.testing.expect(combat.active != null and combat.active.?.counter_attack);
        try std.testing.expectEqual(target, combat.active.?.target);
        var saw_dive = false;
        var rollback = false;
        for (0..700) |_| {
            for (combat.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
                if (scenario == 2 or rollback or playback.action == null or playback.action.?.stage != .approach or combat.unite_vm.actors[enemy].signals & 2 == 0) continue;
                const before = combat;
                const before_members = members;
                const cursor = draws.cursor;
                draws.values = values[0..cursor];
                try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
                try std.testing.expectEqualDeep(before_members, members);
                try std.testing.expectEqualDeep(before.unite_vm, combat.unite_vm);
                try std.testing.expectEqualDeep(before.active, combat.active);
                try std.testing.expectEqual(cursor, draws.cursor);
                draws.values = &values;
                rollback = true;
            };
            try combat.tickReplay(.{}, &draws);
            saw_dive = saw_dive or combat.unite_vm.actors[enemy].crow_dive != null;
            if (combat.phase != .resolving) break;
        }
        try std.testing.expect(saw_dive and combat.phase == .battle_menu and !combat.unite_vm.hasActors());
        try std.testing.expectEqual(scenario != 2, rollback);
        const damage: u16 = @intCast(battle.physicalDamage(combat.stats(enemy).attack, combat.stats(target).defense, 24, true));
        try std.testing.expectEqual(@as(u16, if (scenario == 0) hp - damage else if (scenario == 3) 0 else hp), combat.hp(target));
        try std.testing.expectEqual(target + @as(usize, if (scenario == 2) 3 else 4), draws.cursor);
    };
}

test "Ant journey plays source ordinary and special attacks" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_unites_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const bundle = try host.loadBundle(allocator, @embedFile("fixtures/journey_unites_actor_library.json"));
    defer bundle.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    for (0..10) |scenario| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(parsed.value, items.value, &members, 17);
        combat.encounter = for (combat.content.encounters, 0..) |encounter, index| {
            if (std.mem.eql(u8, encounter.id, "area_a_6")) break index;
        } else return error.MissingAntEncounter;
        combat.startEncounter();
        try combat.attachUniteActors(&bundle.value);
        try combat.attachSpellScenes(&scenes.value);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.actions = @splat(.defend);
        combat.runes = @splat(null);
        combat.progress.party[0].inventory.slots = @splat(null);
        const initial_hp: u16 = if (scenario >= 6) 1 else 5000;
        combat.progress.party[0].max_hp = if (scenario >= 8) 5000 else initial_hp;
        combat.progress.party[0].hp = initial_hp;
        if (scenario >= 8) {
            combat.progress.party[1].max_hp = 5000;
            combat.progress.party[1].hp = 5000;
        }
        if (scenario == 1 or scenario == 5) combat.protection[0] = 2;
        const enemy = combat.partyCount();
        combat.acted[enemy] = false;
        var values: [128]u15 = @splat(12345);
        values[0] = 0;
        values[1] = 99;
        const special = scenario == 3 or scenario == 5 or scenario == 7 or scenario == 9;
        values[2] = if (special) 30000 else if (scenario == 4) 32767 else 0;
        values[3] = if (special) 24 else if (scenario == 2) 99 else 0;
        values[4] = 24;
        var draws = battle.systems.Draws{ .values = &values };
        try combat.tickReplay(.{}, &draws);
        try std.testing.expect(combat.active != null);
        try std.testing.expectEqual(special, combat.active.?.enemy_special);
        try std.testing.expect(combat.active.?.counter_attack);
        try std.testing.expectEqual(initial_hp, combat.hp(0));
        var moved = false;
        var rolled_back = false;
        var impact_count: usize = 0;
        var last_hp = combat.hp(0);
        for (0..1000) |_| {
            for (combat.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
                if (!special or rolled_back or playback.action == null or playback.action.?.stage != .approach or combat.unite_vm.actors[enemy].signals & 2 == 0) continue;
                const before = combat;
                const before_member = combat.progress.party[0];
                const cursor = draws.cursor;
                draws.values = values[0..cursor];
                try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
                try std.testing.expectEqualDeep(before_member, combat.progress.party[0]);
                try std.testing.expectEqualDeep(before.unite_vm, combat.unite_vm);
                try std.testing.expectEqualDeep(before.active, combat.active);
                try std.testing.expectEqual(cursor, draws.cursor);
                draws.values = &values;
                rolled_back = true;
            };
            try combat.tickReplay(.{}, &draws);
            if (combat.unite_vm.scripted_actors[enemy] != null) moved = moved or combat.unite_vm.actors[enemy].position_q12[0] != combat.unite_vm.actors[enemy].home_q12[0];
            if (combat.hp(0) != last_hp) {
                impact_count += 1;
                last_hp = combat.hp(0);
            }
            if (combat.phase != .resolving) break;
        }
        try std.testing.expect(combat.phase == .battle_menu and !combat.unite_vm.hasActors());
        try std.testing.expect(moved);
        try std.testing.expectEqual(special, rolled_back);
        const amount: u16 = @intCast(battle.physicalDamage(combat.stats(enemy).attack, combat.stats(0).defense, 24, true));
        try std.testing.expectEqual(@as(u16, if (scenario == 8) 1 else if (scenario >= 6) 0 else if (scenario == 0 or scenario == 4) 5000 - amount else if (scenario == 3) 5000 - 2 * amount else 5000), combat.hp(0));
        if (scenario == 6 or scenario == 7 or scenario == 9) try std.testing.expectEqual(field.game_state.Status.unconscious, combat.progress.party[0].status);
        if (scenario == 8) {
            const guarded_damage: u16 = @intCast(battle.physicalDamage(combat.stats(enemy).attack, combat.stats(1).defense, 24, true));
            try std.testing.expectEqual(@as(u16, 5000 - guarded_damage), combat.hp(1));
        }
        if (scenario == 9) try std.testing.expectEqual(@as(u16, 5000), combat.hp(1));
        try std.testing.expectEqual(@as(usize, if (scenario == 0 or scenario == 3 or scenario >= 4 and scenario != 5 and scenario != 8) 1 else 0), impact_count);
        try std.testing.expectEqual(@as(usize, if (scenario == 0 or scenario == 1 or scenario == 4 or scenario == 6 or scenario == 8) 5 else 4), draws.cursor);
    }
}

test "Ant source coordinator delays selection while its special continues" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_unites_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const bundle = try host.loadBundle(allocator, @embedFile("fixtures/journey_unites_actor_library.json"));
    defer bundle.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    for ([_]bool{ false, true }) |special| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(parsed.value, items.value, &members, 17);
        combat.encounter = for (combat.content.encounters, 0..) |encounter, index| {
            if (std.mem.eql(u8, encounter.id, "area_a_6")) break index;
        } else return error.MissingAntEncounter;
        combat.startEncounter();
        try combat.attachUniteActors(&bundle.value);
        try combat.attachSpellScenes(&scenes.value);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.actions = @splat(.defend);
        combat.runes = @splat(null);
        combat.progress.party[0].max_hp = 5000;
        combat.progress.party[0].hp = 5000;
        const enemy = combat.partyCount();
        combat.acted[enemy] = false;
        combat.acted[1] = false;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = enemy, .cached = .{ .actor = enemy }, .elapsed = 0 };
        var values: [128]u15 = @splat(24);
        values[0] = 99; // source front-target scan
        values[1] = if (special) 30000 else 0;
        values[2] = 0; // priority for special, accuracy for ordinary
        var draws = battle.systems.Draws{ .values = &values };
        try combat.tickReplay(.{}, &draws);
        try std.testing.expect(combat.acted[enemy] and combat.active != null and combat.active.?.counter_attack);
        try std.testing.expectEqual(special, combat.active.?.enemy_special);
        try std.testing.expectEqual(battle.Coordinator.Stage.select, combat.coordinator.?.stage);
        try std.testing.expectEqual(@as(i32, if (special) 20 else 0), combat.coordinator.?.remaining);
        try std.testing.expectEqual(@as(usize, if (special) 2 else 3), draws.cursor);
        if (!special) continue;
        for (1..20) |elapsed| {
            try combat.tickReplay(.{}, &draws);
            try std.testing.expectEqual(@as(i32, @intCast(20 - elapsed)), combat.coordinator.?.remaining);
            try std.testing.expectEqual(battle.Coordinator.Stage.select, combat.coordinator.?.stage);
            try std.testing.expectEqual(@as(usize, 2), draws.cursor);
        }
        try std.testing.expect(combat.unite_vm.scripted_actors[enemy] != null);
        try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(@as(usize, 3), draws.cursor);
        try std.testing.expectEqual(battle.Coordinator.Stage.check, combat.coordinator.?.stage);
        try std.testing.expectEqual(@as(usize, 1), combat.coordinator.?.cached.?.actor);
        try std.testing.expect(combat.coordinator.?.cross_side_pending and !combat.coordinator.?.completed);
        try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(battle.Coordinator.Stage.check, combat.coordinator.?.stage);
        try std.testing.expect(!combat.acted[1]);
        for (0..500) |_| {
            try combat.tickReplay(.{}, &draws);
            if (combat.acted[1]) break;
        }
        try std.testing.expect(combat.acted[1]);
        try std.testing.expect(combat.unite_vm.scripted_actors[enemy] != null);
        try std.testing.expect(combat.unite_vm.actors[enemy].released);
        try std.testing.expectEqual(@as(usize, 4), draws.cursor); // one contact damage draw
    }
}

test "Ant special starts the coordinator in an ordinary journey round" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_unites_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const bundle = try host.loadBundle(allocator, @embedFile("fixtures/journey_unites_actor_library.json"));
    defer bundle.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    for (0..4) |mode| {
        const attack = mode == 1 or mode == 3;
        const item = mode == 2;
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(parsed.value, items.value, &members, 17);
        combat.encounter = for (combat.content.encounters, 0..) |encounter, index| {
            if (std.mem.eql(u8, encounter.id, "area_a_6")) break index;
        } else return error.MissingAntEncounter;
        combat.startEncounter();
        try combat.attachUniteActors(&bundle.value);
        try combat.attachSpellScenes(&scenes.value);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.actions = @splat(.defend);
        combat.actions[1] = if (attack) .{ .attack = 0 } else if (item) .{ .item = .{ .slot = 0, .target = 0, .id = .medicine } } else .defend;
        combat.runes = @splat(null);
        if (mode == 3) combat.runes[1] = for (combat.content.systems.?.runes, 0..) |rune, index| {
            if (std.mem.eql(u8, rune.id, "double-beat")) break index;
        } else return error.MissingRune;
        combat.progress.party[0].max_hp = 5000;
        combat.progress.party[0].hp = if (item) 1000 else 5000;
        if (item) combat.progress.party[1].inventory.slots[0] = .{ .id = .medicine, .uses = 6 };
        combat.enemy_hp[0] = 5000;
        const enemy = combat.partyCount();
        combat.acted[enemy] = false;
        combat.acted[1] = false;
        var values: [128]u15 = @splat(24);
        values[0] = 0; // party priority
        values[1] = 0; // Ant priority
        values[2] = 99; // target
        values[3] = 30000; // special
        values[4] = 0; // next party priority
        var draws = battle.systems.Draws{ .values = &values };
        try combat.tickReplay(.{}, &draws);
        try std.testing.expect(combat.active != null and combat.active.?.enemy_special);
        try std.testing.expectEqual(@as(i32, 20), combat.coordinator.?.remaining);
        try std.testing.expectEqual(@as(usize, 4), draws.cursor);
        for (0..19) |_| try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(@as(usize, 4), draws.cursor);
        try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(@as(usize, 5), draws.cursor);
        try std.testing.expectEqual(battle.Coordinator.Stage.check, combat.coordinator.?.stage);
        try std.testing.expectEqual(@as(usize, 1), combat.coordinator.?.cached.?.actor);
        var saw_locked_target_wait = false;
        var saw_item_wait = false;
        var before_healing: ?u16 = null;
        var party_started_before_ant_returned = false;
        var enemy_hits: usize = 0;
        var prior_enemy_hp = combat.enemy_hp[0];
        for (0..1000) |_| {
            try combat.tickReplay(.{}, &draws);
            if (combat.coordinator) |clock| {
                if (attack and clock.stage == .dispatch and clock.current_actor == 1 and combat.coordinatorLocked(enemy)) saw_locked_target_wait = true;
                if (item and clock.stage == .dispatch and clock.current_actor == 1 and combat.coordinatorLocked(enemy)) saw_item_wait = true;
            }
            if (item and combat.medicine_action != null and before_healing == null) before_healing = combat.hp(0);
            if (combat.enemy_hp[0] != prior_enemy_hp) {
                enemy_hits += 1;
                prior_enemy_hp = combat.enemy_hp[0];
            }
            if (combat.acted[1]) for (combat.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
                if (playback.attacker == enemy and !playback.attacker_done) party_started_before_ant_returned = true;
            };
            if (combat.phase != .resolving) break;
        }
        try std.testing.expect(combat.phase == .battle_menu and combat.acted[1]);
        try std.testing.expectEqual(attack, saw_locked_target_wait);
        try std.testing.expectEqual(item, saw_item_wait);
        try std.testing.expectEqual(mode == 0, party_started_before_ant_returned);
        try std.testing.expectEqual(attack, combat.enemy_hp[0] < 5000);
        try std.testing.expectEqual(@as(usize, if (mode == 3) 2 else if (attack) 1 else 0), enemy_hits);
        if (mode == 3) try std.testing.expect(!combat.double_beat_pending[1]);
        if (item) {
            try std.testing.expect(combat.hp(0) > before_healing.?);
            try std.testing.expectEqual(@as(u16, 5), combat.progress.party[1].inventory.slots[0].?.uses);
        }
    }
}

test "Ant coordinator retries rejected targets and rolls back an exhausted choice" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_unites_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const bundle = try host.loadBundle(allocator, @embedFile("fixtures/journey_unites_actor_library.json"));
    defer bundle.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(parsed.value, items.value, &members, 17);
    combat.encounter = for (combat.content.encounters, 0..) |encounter, index| {
        if (std.mem.eql(u8, encounter.id, "area_a_6")) break index;
    } else return error.MissingAntEncounter;
    combat.startEncounter();
    try combat.attachUniteActors(&bundle.value);
    try combat.attachSpellScenes(&scenes.value);
    combat.phase = .resolving;
    combat.acted = @splat(true);
    combat.actions = @splat(.defend);
    const enemy = combat.partyCount();
    combat.acted[enemy] = false;
    combat.coordinator = .{ .stage = .dispatch, .current_actor = enemy, .cached = .{ .actor = enemy }, .elapsed = 0 };
    var values: [8]u15 = .{ 0, 0, 0, 99, 30000, 24, 24, 24 };
    var draws = battle.systems.Draws{ .values = &values };
    try combat.tickReplay(.{}, &draws);
    try std.testing.expectEqual(@as(usize, 3), draws.cursor);
    try std.testing.expectEqual(@as(?usize, enemy), combat.pending_enemy_actor);
    try std.testing.expect(!combat.acted[enemy] and combat.active == null);
    const before = combat;
    const before_members = members;
    draws.values = values[0..4];
    try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
    try std.testing.expectEqualDeep(before, combat);
    try std.testing.expectEqualDeep(before_members, members);
    try std.testing.expectEqual(@as(usize, 3), draws.cursor);
    draws.values = &values;
    try combat.tickReplay(.{}, &draws);
    try std.testing.expectEqual(@as(usize, 5), draws.cursor);
    try std.testing.expect(combat.pending_enemy_actor == null and combat.acted[enemy]);
    try std.testing.expect(combat.active != null and combat.active.?.enemy_special);
    try std.testing.expectEqual(@as(i32, 20), combat.coordinator.?.remaining);
}

test "Ant journey target retry keeps its selected actor and priority draw" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_unites_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const bundle = try host.loadBundle(allocator, @embedFile("fixtures/journey_unites_actor_library.json"));
    defer bundle.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(parsed.value, items.value, &members, 17);
    combat.encounter = for (combat.content.encounters, 0..) |encounter, index| {
        if (std.mem.eql(u8, encounter.id, "area_a_6")) break index;
    } else return error.MissingAntEncounter;
    combat.startEncounter();
    try combat.attachUniteActors(&bundle.value);
    try combat.attachSpellScenes(&scenes.value);
    combat.phase = .resolving;
    combat.acted = @splat(true);
    combat.actions = @splat(.defend);
    const enemy = combat.partyCount();
    combat.acted[enemy] = false;
    var values: [9]u15 = .{ 0, 0, 0, 0, 99, 30000, 24, 24, 24 };
    var draws = battle.systems.Draws{ .values = &values };
    try combat.tickReplay(.{}, &draws);
    try std.testing.expectEqual(@as(usize, 4), draws.cursor);
    try std.testing.expectEqual(@as(?usize, enemy), combat.pending_enemy_actor);
    try std.testing.expect(combat.coordinator != null and !combat.acted[enemy]);
    const before = combat;
    const before_members = members;
    draws.values = values[0..5];
    try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
    try std.testing.expectEqualDeep(before, combat);
    try std.testing.expectEqualDeep(before_members, members);
    try std.testing.expectEqual(@as(usize, 4), draws.cursor);
    draws.values = &values;
    try combat.tickReplay(.{}, &draws);
    try std.testing.expectEqual(@as(usize, 6), draws.cursor);
    try std.testing.expect(combat.pending_enemy_actor == null and combat.acted[enemy]);
    try std.testing.expect(combat.active != null and combat.active.?.enemy_special);
    try std.testing.expectEqual(@as(i32, 20), combat.coordinator.?.remaining);
}

test "Melee live source selection hit miss protected KO and Buddha preserve contact rollback" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/parry_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const bundle = try host.loadBundle(allocator, @embedFile("fixtures/battle_parry_library.json"));
    defer bundle.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/parry_spell_scene_library.json"));
    defer scenes.deinit();
    for (0..5) |scenario| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(parsed.value, items.value, &members, 17);
        try combat.attachUniteActors(&bundle.value);
        try combat.attachSpellScenes(&scenes.value);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        for (combat.actions[0..combat.partyCount()]) |*action| action.* = .defend;
        combat.progress.party[0].inventory.slots = @splat(null);
        combat.progress.party[0].max_hp = 5000;
        combat.progress.party[0].hp = 5000;
        if (scenario == 1) combat.protection[0] = 2;
        if (scenario == 2 or scenario == 3) {
            combat.progress.party[0].hp = 1;
            for (combat.progress.party[1..]) |*member| {
                member.hp = 0;
                member.status = .unconscious;
            }
        }
        if (scenario == 3) combat.progress.party[0].inventory.slots[0] = .{ .id = combat.rules.automatic_revival.?.id, .uses = 0 };
        const hp = combat.hp(0);
        const enemy = combat.partyCount();
        combat.acted[enemy] = false;
        var values: [128]u15 = @splat(12345);
        // Queued actor priority, source target scan, accuracy, contact variance.
        values[0] = 0;
        values[1] = 99;
        values[2] = if (scenario == 4) 99 else 0;
        values[3] = 24;
        var draws = battle.systems.Draws{ .values = &values };
        try combat.tickReplay(.{}, &draws);
        try std.testing.expect(combat.active != null and combat.active.?.counter_attack);
        try std.testing.expectEqual(@as(usize, 3), draws.cursor);
        try std.testing.expectEqual(hp, combat.hp(0));
        var rollback = false;
        var saw_white = false;
        var saw_revival = false;
        for (0..700) |_| {
            for (combat.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
                if (playback.action == null or rollback or playback.action.?.stage != .approach or combat.unite_vm.actors[enemy].signals & 2 == 0 or scenario == 4) continue;
                const before = combat;
                const before_member = combat.progress.party[0];
                const cursor = draws.cursor;
                draws.values = values[0..cursor];
                try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
                try std.testing.expectEqualDeep(before_member, combat.progress.party[0]);
                try std.testing.expectEqualDeep(before.unite_vm, combat.unite_vm);
                try std.testing.expectEqualDeep(before.active, combat.active);
                try std.testing.expectEqual(cursor, draws.cursor);
                draws.values = &values;
                rollback = true;
            };
            try combat.tickReplay(.{}, &draws);
            if (combat.unite_vm.scripted_actors[0] != null) {
                const actor = combat.unite_vm.actors[0];
                if (actor.palette == .shared and actor.palette.shared == 0) saw_white = true;
            }
            if (combat.revivalAge(0) != null) saw_revival = true;
            if (scenario == 3) try std.testing.expect(combat.phase != .defeat);
            if (combat.phase != .resolving) break;
        }
        try std.testing.expectEqual(scenario != 4, rollback);
        try std.testing.expectEqual(scenario != 4, saw_white);
        try std.testing.expectEqual(scenario == 3, saw_revival);
        try std.testing.expect(!combat.unite_vm.hasActors() and !combat.hasPendingRevival());
        try std.testing.expectEqual(@as(usize, if (scenario == 4) 3 else 4), draws.cursor);
        if (scenario == 2) {
            try std.testing.expect(combat.phase == .defeat and combat.hp(0) == 0);
        } else {
            try std.testing.expect(combat.phase == .battle_menu and combat.round == 2);
            if (scenario == 1 or scenario == 4) try std.testing.expectEqual(hp, combat.hp(0));
            if (scenario == 0) try std.testing.expectEqual(@as(u16, @intCast(hp - battle.physicalDamage(combat.stats(enemy).attack, combat.stats(0).defense, 24, true))), combat.hp(0));
            if (scenario == 3) try std.testing.expectEqual(@as(u16, 2500), combat.hp(0));
        }
    }
}

test "Parry bundles preserve legacy counter identities and require the new role bindings" {
    const old = try host.loadBundle(allocator, @embedFile("fixtures/battle_counter_library.json"));
    defer old.deinit();
    const serialized = try std.json.Stringify.valueAlloc(allocator, old.value, .{});
    defer allocator.free(serialized);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "\"parries\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "\"melee\"") == null);
    try std.testing.expectEqualStrings("suikoden-counter-actors/1", old.value.counterPacket().?.schema);
    const current = try host.loadBundle(allocator, @embedFile("fixtures/battle_parry_library.json"));
    defer current.deinit();
    try std.testing.expectEqualStrings("suikoden-counter-actors/3", current.value.counterPacket().?.schema);
    var invalid = current.value;
    invalid.counter.?.parries = null;
    try std.testing.expectError(error.InvalidUniteBindings, invalid.validate());
    invalid = current.value;
    invalid.schema = "suikoden-unite-actors/12";
    try std.testing.expectError(error.InvalidUniteBindings, invalid.validate());
    invalid = current.value;
    invalid.counter.?.melee = null;
    try std.testing.expectError(error.InvalidUniteBindings, invalid.validate());
}

test "Parry completes a queued party turn and Kobold counters through its own selected enemy policy" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/parry_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const bundle = try host.loadBundle(allocator, @embedFile("fixtures/battle_parry_library.json"));
    defer bundle.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/parry_spell_scene_library.json"));
    defer scenes.deinit();
    for (0..2) |scenario| {
        var content = parsed.value;
        var encounter = content.encounters[0];
        if (scenario == 1) {
            encounter.enemies = &.{ "bonbon", "kobold_type_1" };
            encounter.positions = &.{ .{ .x = -100, .y = 20, .z = 0 }, .{ .x = -140, .y = -20, .z = 0 } };
            encounter.enemy_rows = &.{ .front, .front };
            content.encounters = @as(*const [1]battle.Encounter, &encounter);
        }
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(content, items.value, &members, 17);
        try combat.attachUniteActors(&bundle.value);
        try combat.attachSpellScenes(&scenes.value);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.progress.party[0].max_hp = 5000;
        combat.progress.party[0].hp = 5000;
        combat.enemy_hp = @splat(5000);
        for (combat.actions[0..combat.partyCount()]) |*action| action.* = .defend;
        combat.acted[if (scenario == 0) 0 else combat.partyCount() + 1] = false;
        if (scenario == 0) combat.actions[0] = .{ .attack = 0 };
        var values: [128]u15 = @splat(12345);
        values[0] = 0; // Priority.
        values[1] = 99; // Party accuracy, or enemy target scan.
        values[2] = if (scenario == 0) 24 else 99; // Parry contact, or enemy accuracy.
        values[3] = 24; // Counter contact; Defend needs no availability draw.
        var draws = battle.systems.Draws{ .values = &values };
        var saw_reaction = false;
        for (0..700) |_| {
            combat.tickReplay(.{}, &draws) catch |err| {
                std.debug.print("queued reaction scenario={d} tick={d} draws={d} active={any}\n", .{ scenario, combat.camera_ticks, draws.cursor, combat.active });
                return err;
            };
            for (combat.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
                try std.testing.expectEqual(if (scenario == 0) counter.Kind.parry else counter.Kind.counter, playback.kind);
                saw_reaction = true;
            };
            if (combat.phase != .resolving) break;
        }
        try std.testing.expect(saw_reaction and combat.phase == .battle_menu and combat.round == 2);
        try std.testing.expect(!combat.unite_vm.hasActors());
        try std.testing.expectEqual(@as(usize, if (scenario == 0) 3 else 4), draws.cursor);
        if (scenario == 0) try std.testing.expect(combat.hp(0) < 5000) else {
            try std.testing.expectEqual(@as(u16, 5000), combat.hp(0));
            try std.testing.expect(combat.enemy_hp[1] < 5000);
        }
    }
}

test "Parry source programs complete for all 58 melee attackers through the shared callback chain" {
    const parsed = try counter.load(allocator, @embedFile("fixtures/counter_actor_library.json"));
    defer parsed.deinit();
    const packet = parsed.value;
    const parries = packet.parries.?;
    var cases: usize = 0;
    for (parries.attackers) |attacker| for (parries.defenders) |defender| {
        var actors = [_]host.Actor{
            try host.Actor.init(packet.animations.find(attacker.id).?, .{ 120 * 4096, 40 * 4096, 0 }),
            try host.Actor.init(packet.animations.find(defender.id).?, .{ -160 * 4096, -20 * 4096, 0 }),
        };
        var children: [4]?host.Actor = @splat(null);
        var sounds = Sounds{};
        var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = packet.library(), .external = .{ .context = &sounds, .command = Sounds.command } };
        var action = try counter.Action.beginFor(packet, &runtime, 0, 1, .parry);
        var contact: ?usize = null;
        var returning: ?usize = null;
        for (0..1000) |tick| {
            for (0..2) |actor| {
                const owner = action.callbackActor() orelse continue;
                if (owner != actor) continue;
                try action.advance(packet, &runtime);
                if (action.stage == .contact) {
                    try std.testing.expect(contact == null);
                    contact = tick;
                    try action.acknowledgeContact(packet, &runtime);
                    try std.testing.expectEqual(@as(u16, 1), actors[0].animation);
                    try std.testing.expectEqual(@as(u16, 0), actors[0].signals & 4);
                    try std.testing.expectEqual(@as(?u16, 1), actors[0].owner);
                }
                if (action.returnReady(runtime)) {
                    try std.testing.expect(contact != null and returning == null);
                    returning = tick;
                    try action.beginReturn(packet, &runtime);
                }
            }
            if (action.stage == .returning) try action.advance(packet, &runtime);
            for (0..2) |actor| try runtime.stepActor(@intCast(actor));
            for (0..children.len) |child| if (children[child] != null) try runtime.stepActor(@intCast(actors.len + child));
            if (action.stage == .released) break;
        }
        if (action.stage != .released) std.debug.print("parry did not finish: {s}, stage={s}\n", .{ attacker.id, @tagName(action.stage) });
        try std.testing.expect(contact != null and returning.? > contact.?);
        try std.testing.expect(action.stage == .released);
        for (actors) |actor| {
            try std.testing.expect(actor.machine.?.halted and actor.highlights == 0);
            try std.testing.expectEqualDeep(actor.home_q12, actor.position_q12);
        }
        cases += 1;
    };
    try std.testing.expectEqual(@as(usize, 58), cases);
}

test "Parry live party hurt protection KO Buddha and Double-Beat preserve source ownership and rollback" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/parry_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const actors = try host.loadBundle(allocator, @embedFile("fixtures/battle_parry_library.json"));
    defer actors.deinit();
    const rebound = try host.loadBundle(allocator, @embedFile("fixtures/battle_parry_library.json"));
    defer rebound.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/parry_spell_scene_library.json"));
    defer scenes.deinit();
    for (0..6) |scenario| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(parsed.value, items.value, &members, 17);
        try combat.attachUniteActors(&actors.value);
        try combat.attachSpellScenes(&scenes.value);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.actions[0] = .{ .attack = 0 };
        const target = combat.partyCount();
        const initial_enemy_hp = combat.hp(target);
        // Diagnostic HP lets the same source actors cover surviving and lethal counter strikes.
        if (scenario == 0 or scenario >= 4) {
            combat.progress.party[0].max_hp = 5000;
            combat.progress.party[0].hp = 5000;
        }
        if (scenario == 1) combat.protection[0] = 2;
        combat.progress.party[0].inventory.slots = @splat(null);
        if (scenario == 2 or scenario == 3) {
            combat.progress.party[0].hp = 1;
            for (combat.progress.party[1..]) |*member| {
                member.hp = 0;
                member.status = .unconscious;
            }
        }
        if (scenario == 3) combat.progress.party[0].inventory.slots[0] = .{ .id = combat.rules.automatic_revival.?.id, .uses = 0 };
        if (scenario >= 4) combat.runes[0] = for (combat.content.systems.?.runes, 0..) |rune, index| {
            if (std.mem.eql(u8, rune.id, "double-beat")) break index;
        } else return error.MissingRune;
        const hp = combat.hp(0);
        const charges = combat.progress.party[0].rune_charges;
        var values: [128]u15 = @splat(12345);
        values[0] = 99;
        values[1] = 24;
        values[2] = if (scenario == 4) 99 else 0;
        values[3] = if (scenario == 4) 0 else 99;
        values[4] = 0;
        var draws = battle.systems.Draws{ .values = &values };
        combat.replay_draws = &draws;
        combat.beginAttack(0, 0, false, null);
        combat.replay_draws = null;
        try std.testing.expect(combat.active != null and combat.active.?.counter_attack);
        try std.testing.expectEqual(@as(usize, 1), draws.cursor);
        var contact_rollback = false;
        var repeat_rollback = false;
        var rebound_done = false;
        var saw_white = false;
        var saw_pending_ko = false;
        var saw_revival = false;
        var saw_followup_origin = false;
        var expected_followup_origin: ?battle.Position = null;
        var contacts: usize = 0;
        var last_contact: ?u32 = null;
        for (0..1100) |_| {
            for (combat.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
                if (playback.kind != .parry or playback.action == null) continue;
                if (!rebound_done and playback.action.?.stage == .response) {
                    try combat.unite_vm.rebind(&rebound.value);
                    combat.unite_actors = &rebound.value;
                    rebound_done = true;
                }
                const contact_pending = !contact_rollback and playback.action.?.stage == .strike and combat.unite_vm.actors[target].signals & 2 != 0;
                const repeat_pending = scenario >= 4 and !repeat_rollback and combat.double_beat_pending[0] and playback.action.?.stage == .hurt and combat.unite_vm.actors[0].signals & 4 != 0 and !combat.coordinatorLocked(target);
                if (contact_pending or repeat_pending) {
                    if (repeat_pending) {
                        const position = combat.unite_vm.actors[0].position_q12;
                        expected_followup_origin = .{ .x = @as(f32, @floatFromInt(position[0])) / 4096, .y = @as(f32, @floatFromInt(position[1])) / 4096, .z = @as(f32, @floatFromInt(position[2])) / 4096 };
                    }
                    const before = combat;
                    const before_member = combat.progress.party[0];
                    const cursor = draws.cursor;
                    draws.values = values[0..cursor];
                    try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
                    try std.testing.expectEqualDeep(before.unite_vm, combat.unite_vm);
                    try std.testing.expectEqualDeep(before.active, combat.active);
                    try std.testing.expectEqualDeep(before.actor_camera, combat.actor_camera);
                    try std.testing.expectEqualDeep(before.double_beat_pending, combat.double_beat_pending);
                    try std.testing.expectEqualDeep(before_member, combat.progress.party[0]);
                    try std.testing.expectEqual(before.camera_ticks, combat.camera_ticks);
                    try std.testing.expectEqual(cursor, draws.cursor);
                    draws.values = &values;
                    if (contact_pending) contact_rollback = true else repeat_rollback = true;
                }
            };
            combat.tickReplay(.{}, &draws) catch |err| {
                std.debug.print("Parry scenario={d} tick={d} phase={s} active={any} counter={any}\n", .{ scenario, combat.camera_ticks, @tagName(combat.phase), combat.active, combat.unite_vm.counter_actions });
                return err;
            };
            for (combat.unite_vm.counter_actions) |maybe| if (maybe) |playback| {
                if (playback.kind != .parry) continue;
                if (playback.contact_at) |at| if (last_contact == null or last_contact.? != at) {
                    last_contact = at;
                    contacts += 1;
                };
            };
            if (combat.unite_vm.scripted_actors[0] != null) {
                const actor = combat.unite_vm.actors[0];
                if (actor.palette == .shared and actor.palette.shared == 0) {
                    try std.testing.expectEqualDeep(combat.content.uniteWhiteGraphic("hero", actor.currentFrame().pose).?, combat.uniteVmPose(0).?);
                    saw_white = true;
                }
            }
            if (combat.hp(0) == 0 and combat.knockout_pending[0]) {
                saw_pending_ko = true;
                try std.testing.expect(combat.progress.party[0].status == .unconscious);
            }
            if (combat.revivalAge(0) != null) saw_revival = true;
            if (scenario == 3) try std.testing.expect(combat.phase != .defeat);
            if (combat.active) |effect| if (effect.motion_origin) |origin| {
                try std.testing.expectEqualDeep(expected_followup_origin.?, origin);
                saw_followup_origin = true;
            };
            if (combat.active == null and !combat.unite_vm.hasActors() and !combat.hasPendingRevival()) break;
        }
        try std.testing.expect(contact_rollback and rebound_done and saw_white);
        if (contacts != @as(usize, if (scenario == 4) 2 else 1)) std.debug.print("Parry terminal scenario={d} contacts={d} draws={d} phase={s} active={any} actors={any}\n", .{ scenario, contacts, draws.cursor, @tagName(combat.phase), combat.active, combat.unite_vm.counter_actions });
        try std.testing.expectEqual(@as(usize, if (scenario == 4) 2 else 1), contacts);
        try std.testing.expectEqual(scenario >= 4, repeat_rollback);
        try std.testing.expectEqual(scenario == 5, saw_followup_origin);
        try std.testing.expectEqual(scenario == 2 or scenario == 3, saw_pending_ko);
        try std.testing.expectEqual(scenario == 3, saw_revival);
        try std.testing.expect(!combat.unite_vm.hasActors() and combat.active == null and !combat.hasPendingRevival());
        try std.testing.expectEqualDeep(charges, combat.progress.party[0].rune_charges);
        try std.testing.expectEqual(@as(usize, if (scenario == 4) 4 else if (scenario == 5) 5 else 2), draws.cursor);
        if (scenario == 1) try std.testing.expectEqual(hp, combat.hp(0));
        if (scenario == 2) {
            try std.testing.expectEqual(@as(u16, 0), combat.hp(0));
            try combat.tickReplay(.{}, &draws);
            try std.testing.expect(combat.phase == .defeat);
        }
        if (scenario == 3) {
            try std.testing.expectEqual(@as(u16, 50), combat.hp(0));
            try std.testing.expectEqual(@as(usize, 0), combat.progress.party[0].inventory.count());
        }
        if (scenario < 4) try std.testing.expectEqual(initial_enemy_hp, combat.hp(target));
        if (scenario >= 4) try std.testing.expect(!combat.double_beat_pending[0]);
    }
}

test "Counter batch rejects invalid capability pairs and missing cross-resource hurt animations" {
    const parsed = try counter.load(allocator, @embedFile("fixtures/counter_actor_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    const enemies = try allocator.dupe(counter.Enemy, packet.enemies);
    defer allocator.free(enemies);
    packet.enemies = enemies;
    enemies[0].counterable = !enemies[0].counterable;
    try std.testing.expectError(error.InvalidCounterBindings, packet.validate());
    enemies[0] = parsed.value.enemies[0];
    const resources = try allocator.dupe(host.Resource, packet.animations.resources);
    defer allocator.free(resources);
    packet.animations.resources = resources;
    for (resources) |*resource| if (std.mem.eql(u8, resource.id, "red_soldier_ant")) {
        resource.clips = resource.clips[0..1];
    };
    try std.testing.expectError(error.MissingActorAnimation, packet.validate());
}

test "Ant special actor bindings require their version and both programs" {
    const parsed = try counter.load(allocator, @embedFile("fixtures/counter_actor_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    packet.schema = "suikoden-counter-actors/5";
    try std.testing.expectError(error.InvalidCounterBindings, packet.validate());
    packet = parsed.value;
    var melee = packet.melee.?;
    const enemies = try allocator.dupe(counter.MeleeEnemy, melee.enemies);
    defer allocator.free(enemies);
    melee.enemies = enemies;
    packet.melee = melee;
    for (enemies) |*enemy| if (std.mem.eql(u8, enemy.id, "red_soldier_ant")) {
        enemy.special = null;
    };
    try std.testing.expectError(error.InvalidCounterBindings, packet.validate());
    for (enemies) |*enemy| if (std.mem.eql(u8, enemy.id, "red_soldier_ant")) {
        enemy.special = .{ .attack_program = "missing", .hurt_program = "missing" };
    };
    try std.testing.expectError(error.MissingCounterProgram, packet.validate());
    const bundle = try host.loadBundle(allocator, @embedFile("fixtures/journey_unites_actor_library.json"));
    defer bundle.deinit();
    var old_schema = bundle.value;
    old_schema.schema = "suikoden-unite-actors/24";
    try std.testing.expectError(error.InvalidUniteBindings, old_schema.validate());
}

test "Counter batch runs all 58 eligible defenders against both enemy resources through real signals" {
    const parsed = try counter.load(allocator, @embedFile("fixtures/counter_actor_library.json"));
    defer parsed.deinit();
    const packet = parsed.value;
    var cases: usize = 0;
    for (packet.enemies) |enemy| {
        if (!enemy.counterable) continue;
        for (packet.defenders) |defender| {
            var actors = [_]host.Actor{
                try host.Actor.init(packet.animations.find(defender.id).?, .{ 120 * 4096, 40 * 4096, 0 }),
                try host.Actor.init(packet.animations.find(enemy.id).?, .{ -160 * 4096, -20 * 4096, 0 }),
            };
            var children: [4]?host.Actor = @splat(null);
            var sounds = Sounds{};
            var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = packet.library(), .external = .{ .context = &sounds, .command = Sounds.command } };
            var action = try counter.Action.begin(packet, &runtime, 1, 0);
            var contact: ?u16 = null;
            var returning: ?u16 = null;
            for (0..800) |tick| {
                try action.advance(packet, &runtime);
                if (action.stage == .contact) {
                    try std.testing.expect(contact == null);
                    try std.testing.expect(actors[0].signals & 2 != 0);
                    contact = @intCast(tick);
                    // The counter striker supplies the hurt descriptor, the enemy supplies its poses.
                    try action.acknowledgeContact(packet, &runtime);
                    try std.testing.expectEqual(@as(u16, 0), actors[0].signals);
                    try std.testing.expectEqual(@as(?u16, 0), actors[1].owner);
                    try std.testing.expect(std.mem.eql(u8, enemy.id, actors[1].resource.?.id));
                    try std.testing.expectEqual(@as(u16, 1), actors[1].animation);
                }
                if (action.returnReady(runtime)) {
                    try std.testing.expect(contact != null and returning == null);
                    returning = @intCast(tick);
                    try action.beginReturn(packet, &runtime);
                }
                for (0..actors.len) |actor| try runtime.stepActor(@intCast(actor));
                for (0..children.len) |child| if (children[child] != null) try runtime.stepActor(@intCast(actors.len + child));
                if (action.stage == .released) break;
            }
            if (action.stage != .released) std.debug.print("counter did not finish: {s} / {s}, stage={s}, signals={any}, highlights={any}\n", .{ defender.id, enemy.id, @tagName(action.stage), .{ actors[0].signals, actors[1].signals }, .{ actors[0].highlights, actors[1].highlights } });
            try std.testing.expectEqual(@as(usize, @intFromBool(contact != null)), 1);
            try std.testing.expect(returning.? > contact.?);
            try std.testing.expect(action.stage == .released);
            for (actors) |actor| {
                try std.testing.expect(actor.machine.?.halted and actor.highlights == 0);
                try std.testing.expectEqualDeep(actor.home_q12, actor.position_q12);
            }
            try std.testing.expect(sounds.count > 0);
            cases += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 116), cases);
}

test "Counter contact stays pending until HP commits and refuses early acknowledgement or return" {
    const parsed = try counter.load(allocator, @embedFile("fixtures/counter_actor_library.json"));
    defer parsed.deinit();
    const packet = parsed.value;
    var actors = [_]host.Actor{ try host.Actor.init(packet.animations.find("hero").?, .{ 0, 0, 0 }), try host.Actor.init(packet.animations.find("red_soldier_ant").?, .{ -400000, 0, 0 }) };
    var children: [4]?host.Actor = @splat(null);
    var sounds = Sounds{};
    var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = packet.library(), .external = .{ .context = &sounds, .command = Sounds.command } };
    var action = try counter.Action.begin(packet, &runtime, 1, 0);
    try std.testing.expectError(error.CounterContactNotReady, action.acknowledgeContact(packet, &runtime));
    try std.testing.expectError(error.CounterReturnNotReady, action.beginReturn(packet, &runtime));
    for (0..400) |_| {
        try action.advance(packet, &runtime);
        if (action.stage == .contact) break;
        for (0..2) |actor| try runtime.stepActor(@intCast(actor));
    }
    try std.testing.expect(action.stage == .contact);
    const signal = actors[0].signals;
    for (0..3) |_| try action.advance(packet, &runtime);
    try std.testing.expectEqual(signal, actors[0].signals);
    try std.testing.expect(action.stage == .contact and actors[1].animation != 1);
    try action.acknowledgeContact(packet, &runtime);
    try std.testing.expect(action.stage == .hurt);
    try std.testing.expectError(error.CounterContactNotReady, action.acknowledgeContact(packet, &runtime));
}

test "Counter live ordinary miss commits one protected or lethal enemy result and preserves the defender queued turn" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const actors = try host.loadBundle(allocator, @embedFile("fixtures/battle_counter_library.json"));
    defer actors.deinit();
    const rebound = try host.loadBundle(allocator, @embedFile("fixtures/battle_counter_library.json"));
    defer rebound.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    var content = parsed.value;
    var encounter = content.encounters[0];
    encounter.enemies = &.{ "bonbon", "red_soldier_ant" };
    encounter.enemy_rows = &.{ .front, .front };
    encounter.source_slots = null;
    encounter.positions = &.{ .{ .x = -100, .y = 20, .z = 0 }, .{ .x = -140, .y = -20, .z = 0 } };
    content.encounters = @as(*const [1]battle.Encounter, &encounter);
    for (0..4) |scenario| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(content, items.value, &members, 17);
        try combat.attachUniteActors(&actors.value);
        try combat.attachSpellScenes(&scenes.value);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.acted[0] = false;
        combat.actions[0] = .defend;
        const attacker = combat.partyCount() + 1;
        combat.enemy_hp[1] = if (scenario >= 2) 1 else 5000;
        if (scenario == 3) combat.enemy_hp[0] = 0;
        combat.protection[attacker] = if (scenario == 1) 1 else 0;
        const enemy_hp = combat.enemy_hp[1];
        const defender_hp = combat.hp(0);
        var values: [512]u15 = @splat(12345);
        values[0] = 99;
        var draws = battle.systems.Draws{ .values = &values };
        combat.replay_draws = &draws;
        combat.beginAttack(attacker, 0, false, null);
        combat.replay_draws = null;
        try std.testing.expect(combat.active != null and combat.active.?.counter_attack);
        try std.testing.expectEqual(@as(usize, 1), draws.cursor);
        var tested_rollback = false;
        var rebound_done = false;
        var observed_contact: ?u32 = null;
        var observed_knockout = false;
        var lethal_return_seen = false;
        var queued_turn_preserved = false;
        for (0..650) |_| {
            if (combat.unite_vm.counter_actions[1]) |playback| {
                if (!rebound_done and playback.action != null and playback.action.?.stage == .response) {
                    try combat.unite_vm.rebind(&rebound.value);
                    combat.unite_actors = &rebound.value;
                    rebound_done = true;
                }
                if (!tested_rollback and playback.action != null and playback.action.?.stage == .strike and combat.unite_vm.actors[0].signals & 2 != 0) {
                    const before = combat;
                    const cursor = draws.cursor;
                    draws.values = values[0..cursor];
                    try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
                    try std.testing.expectEqualDeep(before.unite_vm, combat.unite_vm);
                    try std.testing.expectEqualDeep(before.enemy_hp, combat.enemy_hp);
                    try std.testing.expectEqualDeep(before.active, combat.active);
                    try std.testing.expectEqualDeep(before.actor_camera, combat.actor_camera);
                    try std.testing.expectEqual(before.camera_ticks, combat.camera_ticks);
                    try std.testing.expectEqual(cursor, draws.cursor);
                    draws.values = &values;
                    tested_rollback = true;
                }
            }
            try combat.tickReplay(.{}, &draws);
            if (combat.unite_vm.counter_actions[1]) |playback| {
                if (playback.contact_at) |at| {
                    if (observed_contact) |prior| try std.testing.expectEqual(prior, at) else observed_contact = at;
                    const expected = battle.physicalDamage(combat.stats(0).attack, combat.stats(attacker).defense, values[1], false);
                    try std.testing.expectEqual(if (scenario == 1) @as(u32, 0) else expected, playback.amount);
                    try std.testing.expectEqual(@as(u16, @intCast(@as(u32, enemy_hp) -| playback.amount)), combat.enemy_hp[1]);
                    if (!playback.controller_done) {
                        try std.testing.expectEqual(@as(usize, 2), draws.cursor);
                        try std.testing.expect(!combat.acted[0]);
                        try std.testing.expect(combat.actions[0] != null and combat.actions[0].? == .defend);
                        queued_turn_preserved = true;
                    }
                }
                if (playback.knockout_at != null) {
                    observed_knockout = true;
                    const reaction = combat.spellReaction(attacker).?;
                    const age = combat.camera_ticks - playback.knockout_at.?;
                    try std.testing.expectEqual(age < 92, reaction.visible);
                    try std.testing.expect(combat.unite_vm.actors[attacker].machine.?.halted);
                    try std.testing.expectEqual(@as(u8, 0), combat.unite_vm.actors[attacker].highlights);
                    try std.testing.expectEqualDeep(combat.unite_vm.actors[attacker].home_q12, combat.unite_vm.actors[attacker].position_q12);
                    if (scenario == 3) try std.testing.expect(combat.phase == .resolving);
                } else if (scenario >= 2 and playback.controller_done) {
                    try std.testing.expect(playback.action.?.stage == .returning);
                    try std.testing.expect(combat.unite_vm.actors[attacker].highlights != 0);
                    try std.testing.expect(combat.uniteVmPose(attacker) != null);
                    lethal_return_seen = true;
                }
            }
            try std.testing.expectEqual(defender_hp, combat.hp(0));
            if (!combat.unite_vm.hasActors()) break;
        }
        try std.testing.expect(tested_rollback and rebound_done and observed_contact != null and queued_turn_preserved);
        try std.testing.expectEqual(scenario >= 2, observed_knockout);
        try std.testing.expectEqual(scenario >= 2, lethal_return_seen);
        try std.testing.expect(!combat.unite_vm.hasActors());
        // After the counter releases, ordinary scheduling draws priority for the queued Defend.
        try std.testing.expectEqual(@as(usize, if (scenario == 3) 2 else 3), draws.cursor);
        if (scenario == 3) {
            try combat.tickReplay(.{}, &draws);
            try std.testing.expect(combat.phase == .victory);
        }
    }
}

test "Counter live eligibility preserves source slot weapon Defend rune and random draw ordering" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const actors = try host.loadBundle(allocator, @embedFile("fixtures/battle_counter_library.json"));
    defer actors.deinit();
    var content = parsed.value;
    var encounter = content.encounters[0];
    var enemy_ids = [_][]const u8{ "red_soldier_ant", "red_soldier_ant" };
    encounter.enemies = &enemy_ids;
    encounter.enemy_rows = &.{ .front, .front };
    encounter.source_slots = null;
    encounter.positions = &.{ .{ .x = -100, .y = 20, .z = 0 }, .{ .x = -140, .y = -20, .z = 0 } };
    content.encounters = @as(*const [1]battle.Encounter, &encounter);
    const profiles = try allocator.dupe(battle.Profile, content.party);
    defer allocator.free(profiles);
    content.party = profiles;
    for (0..8) |scenario| {
        profiles[0].weapon_range = .medium;
        enemy_ids[1] = "red_soldier_ant";
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(content, items.value, &members, 17);
        try combat.attachUniteActors(&actors.value);
        combat.actions[0] = if (scenario == 0 or scenario == 5 or scenario == 6 or scenario == 7) .defend else .{ .attack = 0 };
        if (scenario == 3 or scenario == 4) combat.runes[0] = for (content.systems.?.runes, 0..) |rune, index| {
            if (std.mem.eql(u8, rune.id, "counter")) break index;
        } else return error.MissingCounterRune;
        if (scenario == 4) profiles[0].weapon_range = .long;
        if (scenario == 6) enemy_ids[1] = "bonbon";
        if (scenario == 7) profiles[0].weapon_range = null;
        const values = [_]u15{if (scenario == 2) 1 else 0};
        var draws = battle.systems.Draws{ .values = &values };
        combat.replay_draws = &draws;
        const attacker = combat.partyCount() + @as(usize, if (scenario == 5) 0 else 1);
        if (scenario == 7) {
            try std.testing.expectError(error.MissingCounterWeaponRange, combat.counterAvailable(attacker, 0));
        } else {
            try std.testing.expectEqual(scenario == 0 or scenario == 2 or scenario == 3, try combat.counterAvailable(attacker, 0));
        }
        try std.testing.expectEqual(@as(usize, if (scenario == 1 or scenario == 2) 1 else 0), draws.cursor);
    }
}

test "Counter live starts through ordinary journey enemy selection and finishes the queued round" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const actors = try host.loadBundle(allocator, @embedFile("fixtures/battle_counter_library.json"));
    defer actors.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    var content = parsed.value;
    var encounter = content.encounters[0];
    encounter.enemies = &.{ "bonbon", "red_soldier_ant" };
    encounter.enemy_rows = &.{ .front, .front };
    encounter.source_slots = null;
    encounter.positions = &.{ .{ .x = -100, .y = 20, .z = 0 }, .{ .x = -140, .y = -20, .z = 0 } };
    content.encounters = @as(*const [1]battle.Encounter, &encounter);
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(content, items.value, &members, 17);
    try combat.attachUniteActors(&actors.value);
    try combat.attachSpellScenes(&scenes.value);
    combat.phase = .resolving;
    combat.acted = @splat(true);
    const attacker = combat.partyCount() + 1;
    combat.acted[attacker] = false;
    for (combat.actions[0..combat.partyCount()]) |*action| action.* = .defend;
    combat.actions[0] = .{ .attack = 0 };
    combat.enemy_hp[1] = 5000;
    const hp = combat.hp(0);
    var values: [128]u15 = @splat(12345);
    // Priority, target, ordinary-vs-double attack, accuracy, availability, contact variance.
    values[0] = 0;
    values[1] = 99;
    values[2] = 0;
    values[3] = 99;
    values[4] = 1;
    var draws = battle.systems.Draws{ .values = &values };
    const before = combat;
    draws.values = values[0..4];
    try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
    try std.testing.expectEqualDeep(before.unite_vm, combat.unite_vm);
    try std.testing.expectEqualDeep(before.acted, combat.acted);
    try std.testing.expectEqualDeep(before.active, combat.active);
    try std.testing.expectEqualDeep(before.actions, combat.actions);
    try std.testing.expectEqual(before.camera_ticks, combat.camera_ticks);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    draws.values = &values;
    try combat.tickReplay(.{}, &draws);
    try std.testing.expect(combat.active != null and combat.active.?.counter_attack);
    try std.testing.expectEqual(@as(usize, 5), draws.cursor);
    var advanced: u16 = 0;
    while (combat.phase == .resolving and advanced < 500) : (advanced += 1) try combat.tickReplay(.{}, &draws);
    try std.testing.expect(combat.phase == .battle_menu and combat.round == 2);
    try std.testing.expect(!combat.unite_vm.hasActors());
    try std.testing.expectEqual(hp, combat.hp(0));
    try std.testing.expect(combat.enemy_hp[1] < 5000);
    try std.testing.expectEqual(@as(usize, 6), draws.cursor);
}

test "Counter and physical rune simultaneous callbacks consume variance in actor order" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const actors = try host.loadBundle(allocator, @embedFile("fixtures/battle_counter_library.json"));
    defer actors.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    var content = parsed.value;
    var encounter = content.encounters[0];
    encounter.enemies = &.{ "bonbon", "red_soldier_ant" };
    encounter.enemy_rows = &.{ .front, .front };
    encounter.source_slots = null;
    encounter.positions = &.{ .{ .x = -100, .y = 20, .z = 0 }, .{ .x = -140, .y = -20, .z = 0 } };
    content.encounters = @as(*const [1]battle.Encounter, &encounter);
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(content, items.value, &members, 17);
    try combat.attachUniteActors(&actors.value);
    try combat.attachSpellScenes(&scenes.value);
    combat.enemy_hp = @splat(5000);
    const recipient = combat.partyCount();
    const attacker = recipient + 1;
    combat.runes[2] = for (content.systems.?.runes, 0..) |rune, index| {
        if (std.mem.eql(u8, rune.id, "boar")) break index;
    } else return error.MissingRune;
    try combat.beginSourcePhysicalRune(2, recipient);
    combat.camera_ticks = 1;
    combat.advancePhysicalRunes();
    try combat.beginCounter(attacker, 0);
    combat.camera_ticks = 2;
    combat.advancePhysicalRunes();
    // A retained frame with both source callbacks ready: counter striker0 precedes recipient6.
    combat.unite_vm.physical_actions[2].?.action.?.stage = .returning;
    combat.unite_vm.physical_actions[2].?.action.?.damage_pending = true;
    combat.unite_vm.physical_actions[2].?.action.?.recipient_started = true;
    combat.unite_vm.actors[recipient].signals |= 2;
    combat.unite_vm.counter_actions[1].?.action.?.stage = .strike;
    combat.unite_vm.actors[0].signals |= 2;
    const values = [_]u15{ 0, 24 };
    var draws = battle.systems.Draws{ .values = &values };
    combat.phase = .resolving;
    const before = combat;
    draws.values = values[0..1];
    try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
    try std.testing.expectEqualDeep(before.unite_vm, combat.unite_vm);
    try std.testing.expectEqualDeep(before.enemy_hp, combat.enemy_hp);
    try std.testing.expectEqualDeep(before.actor_camera, combat.actor_camera);
    try std.testing.expectEqual(before.camera_ticks, combat.camera_ticks);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    draws.values = &values;
    try combat.tickReplay(.{}, &draws);
    try std.testing.expect(!combat.replay_exhausted and combat.replay_unsupported == null);
    try std.testing.expectEqual(@as(usize, 2), draws.cursor);
    const counter_amount = battle.physicalDamage(combat.stats(0).attack, combat.stats(attacker).defense, values[0], false);
    const rune_amount = battle.physicalDamage(combat.stats(2).attack, combat.stats(recipient).defense, values[1], false) * 2;
    try std.testing.expectEqual(counter_amount, combat.unite_vm.counter_actions[1].?.amount);
    try std.testing.expectEqual(rune_amount, combat.unite_vm.physical_actions[2].?.amount);
    try std.testing.expectEqual(@as(u16, @intCast(5000 - counter_amount)), combat.enemy_hp[1]);
    try std.testing.expectEqual(@as(u16, @intCast(5000 - rune_amount)), combat.enemy_hp[0]);
}

test "Parry and physical rune simultaneous contacts restore party HP after a later exhausted draw" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/parry_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const actors = try host.loadBundle(allocator, @embedFile("fixtures/battle_parry_library.json"));
    defer actors.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("fixtures/parry_spell_scene_library.json"));
    defer scenes.deinit();
    var content = parsed.value;
    var encounter = content.encounters[0];
    encounter.enemies = &.{ "kobold_type_1", "bonbon" };
    encounter.enemy_rows = &.{ .front, .front };
    encounter.source_slots = null;
    encounter.positions = &.{ .{ .x = -100, .y = 20, .z = 0 }, .{ .x = -140, .y = -20, .z = 0 } };
    content.encounters = @as(*const [1]battle.Encounter, &encounter);
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(content, items.value, &members, 17);
    try combat.attachUniteActors(&actors.value);
    try combat.attachSpellScenes(&scenes.value);
    combat.enemy_hp = @splat(5000);
    combat.progress.party[0].max_hp = 5000;
    combat.progress.party[0].hp = 5000;
    const attacker = combat.partyCount();
    const recipient = attacker + 1;
    combat.runes[2] = for (content.systems.?.runes, 0..) |rune, index| {
        if (std.mem.eql(u8, rune.id, "boar")) break index;
    } else return error.MissingRune;
    try combat.beginSourcePhysicalRune(2, recipient);
    combat.camera_ticks = 1;
    combat.advancePhysicalRunes();
    try combat.beginParry(0, attacker);
    combat.camera_ticks = 2;
    combat.advancePhysicalRunes();
    // A retained frame with both callbacks ready: Parry striker6 precedes physical recipient7.
    combat.unite_vm.physical_actions[2].?.action.?.stage = .returning;
    combat.unite_vm.physical_actions[2].?.action.?.damage_pending = true;
    combat.unite_vm.physical_actions[2].?.action.?.recipient_started = true;
    combat.unite_vm.actors[recipient].signals |= 2;
    combat.unite_vm.counter_actions[0].?.action.?.stage = .strike;
    combat.unite_vm.actors[attacker].signals |= 2;
    const values = [_]u15{ 0, 24 };
    var draws = battle.systems.Draws{ .values = &values };
    combat.phase = .resolving;
    const before = combat;
    const before_member = combat.progress.party[0];
    draws.values = values[0..1];
    try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
    try std.testing.expectEqualDeep(before.unite_vm, combat.unite_vm);
    try std.testing.expectEqualDeep(before.enemy_hp, combat.enemy_hp);
    try std.testing.expectEqualDeep(before_member, combat.progress.party[0]);
    try std.testing.expectEqualDeep(before.knockout_pending, combat.knockout_pending);
    try std.testing.expectEqualDeep(before.actor_camera, combat.actor_camera);
    try std.testing.expectEqual(before.camera_ticks, combat.camera_ticks);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    draws.values = &values;
    try combat.tickReplay(.{}, &draws);
    try std.testing.expect(!combat.replay_exhausted and combat.replay_unsupported == null);
    try std.testing.expectEqual(@as(usize, 2), draws.cursor);
    const counter_amount = battle.physicalDamage(combat.stats(attacker).attack, combat.stats(0).defense, values[0], false);
    const rune_amount = battle.physicalDamage(combat.stats(2).attack, combat.stats(recipient).defense, values[1], false) * 2;
    try std.testing.expectEqual(counter_amount, combat.unite_vm.counter_actions[0].?.amount);
    try std.testing.expectEqual(rune_amount, combat.unite_vm.physical_actions[2].?.amount);
    try std.testing.expectEqual(@as(u16, @intCast(5000 - counter_amount)), combat.hp(0));
    try std.testing.expectEqual(@as(u16, @intCast(5000 - rune_amount)), combat.enemy_hp[1]);
}
