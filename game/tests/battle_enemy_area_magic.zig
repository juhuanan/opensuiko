const std = @import("std");
const battle = @import("battle");
const host = battle.actor_host;

const Fixture = struct {
    programs: battle.actor_program.Packet,
    animations: host.Resources,
    actors: []const struct { id: []const u8, special: struct { first_callback_update: u16 } },
};
fn fixture(alloc: std.mem.Allocator) !Fixture {
    const parsed = try std.json.parseFromSlice(Fixture, alloc, @embedFile("fixtures/enemy_area_magic_source.json"), .{ .ignore_unknown_fields = true });
    try parsed.value.programs.validate();
    try parsed.value.animations.validate();
    return parsed.value;
}
fn library(alloc: std.mem.Allocator, data: Fixture) !host.Library {
    const base = try host.loadBundle(alloc, @embedFile("fixtures/journey_unites_actor_library.json"));
    const shared = [_]host.Resource{base.value.animations.find("shared_impacts").?};
    return .{ .programs = data.programs, .resources = .{
        .schema = "suikoden-actor-animations/1",
        .resources = try std.mem.concat(alloc, host.Resource, &.{ data.animations.resources, &shared }),
    } };
}
const Requests = struct {
    update: u16 = 0,
    first: ?u16 = null,
    effects: u16 = 0,
    cameras: u8 = 0,
    fn command(raw: *anyopaque, _: u16, request: battle.actor_program.Command, _: bool) !bool {
        const self: *Requests = @ptrCast(@alignCast(raw));
        switch (request) {
            .effect => |effect| {
                try std.testing.expectEqualStrings("enemy_group_magic", effect.id);
                try std.testing.expect(effect.binding == .self);
                self.first = self.update;
                self.effects += 1;
            },
            .camera => self.cameras += 1,
            .sound => {},
            else => return error.UnexpectedActorCommand,
        }
        return true;
    }
};

test "area magic actor batch keeps source startup and external mailbox waits for all three owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const data = try fixture(alloc);
    const lib = try library(alloc, data);
    for (data.actors) |binding| {
        var actors = [_]host.Actor{try host.Actor.init(lib.resources.find(binding.id).?, .{ 0, 0, 0 })};
        var requests: Requests = .{};
        var runtime = host.Runtime{ .actors = &actors, .library = lib, .external = .{ .context = &requests, .command = Requests.command } };
        const id = try std.mem.concat(alloc, u8, &.{ "melee/", binding.id, "/special" });
        try runtime.dispatch(0, 0, lib.programs.find(id).?);
        for (1..binding.special.first_callback_update + 11) |update| {
            requests.update = @intCast(update);
            try runtime.stepActor(0);
        }
        try std.testing.expectEqual(binding.special.first_callback_update, requests.first.?);
        try std.testing.expectEqual(@as(u16, 1), requests.effects);
        try std.testing.expect(!actors[0].machine.?.halted and !actors[0].released);
        // The group worker is deliberately not implemented by this actor-component harness.
        actors[0].shared_value = 99;
        if (std.mem.eql(u8, binding.id, "siren")) {
            for (0..5) |_| try runtime.stepActor(0);
            try std.testing.expect(!actors[0].machine.?.halted);
            actors[0].shared_value = 100;
        }
        for (0..200) |_| try runtime.stepActor(0);
        try std.testing.expect(actors[0].machine.?.halted and actors[0].released);
        try std.testing.expectEqual(@as(u8, 0), actors[0].highlights);
        try std.testing.expectEqual(@as(u8, if (std.mem.eql(u8, binding.id, "siren")) 3 else 0), requests.cameras);
    }
}

test "area magic actor ordinary batch closes Siren facing children and shared Golem projectile returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const data = try fixture(alloc);
    const lib = try library(alloc, data);
    var facing_samples: usize = 0;
    var fixed_samples: usize = 0;
    for (data.actors) |binding| {
        var actors = [_]host.Actor{
            try host.Actor.init(lib.resources.find(binding.id).?, .{ 100 * 4096, 0, -10 * 4096 }),
            try host.Actor.init(lib.resources.find("sorcerer").?, .{ -100 * 4096, 0, 0 }),
        };
        var auxiliary: [17]?host.Actor = @splat(null);
        var requests: Requests = .{};
        var runtime = host.Runtime{ .actors = &actors, .auxiliary = &auxiliary, .library = lib, .external = .{ .context = &requests, .command = Requests.command } };
        const attack = try std.mem.concat(alloc, u8, &.{ "melee/", binding.id, "/attack" });
        const retreat = try std.mem.concat(alloc, u8, &.{ "melee/", binding.id, "/return" });
        try runtime.dispatch(0, 1, lib.programs.find(attack).?);
        var returning = false;
        for (0..600) |update| {
            runtime.camera_angles = if (update % 2 == 0) .{ -111, 222, -333 } else .{ 444, -555, 666 };
            try runtime.stepActor(0);
            try runtime.stepActor(1);
            for (0..auxiliary.len) |slot| if (auxiliary[slot] != null) {
                try runtime.stepActor(@intCast(actors.len + slot));
                if (auxiliary[slot]) |child| {
                    if (child.reaction_callback) |kind| if (kind == .camera_facing) {
                        try std.testing.expectEqualDeep(runtime.camera_angles, child.draw_angles);
                        facing_samples += 1;
                    };
                    if (child.projectile) |kind| if (kind == .fixed) {
                        fixed_samples += 1;
                    };
                }
            };
            if (!returning and actors[0].machine.?.halted) {
                try std.testing.expect(actors[0].signals & 4 != 0);
                try runtime.dispatch(0, 1, lib.programs.find(retreat).?);
                returning = true;
            }
        }
        try std.testing.expect(returning and actors[0].machine.?.halted and actors[0].released);
        try std.testing.expectEqual(@as(u8, 0), actors[0].highlights);
        for (auxiliary) |child| try std.testing.expect(child == null);
        try std.testing.expectEqual(@as(u16, 0), requests.effects);
    }
    try std.testing.expect(facing_samples > 0 and fixed_samples > 0);
}

const area_suite = struct {
    const field = @import("field");

    const Fixtures = struct {
        content: battle.Content,
        actors: host.Bundle,
        scenes: battle.spell_scene.Packet,
        items: field.items.Rules,

        fn init(alloc: std.mem.Allocator) !Fixtures {
            return .{
                .content = try loadContent(alloc),
                .actors = try loadActors(alloc),
                .scenes = try loadScenes(alloc),
                .items = (try field.items.load(alloc, field.items.json)).value,
            };
        }
    };

    const Setup = struct {
        content: battle.Content,
        actors: *const host.Bundle,
        scenes: *const battle.spell_scene.Packet,
        items: field.items.Rules,
        members: *[6]battle.Member,
        state: *battle.State,
    };

    fn loadContent(alloc: std.mem.Allocator) !battle.Content {
        return (try battle.load(alloc, @embedFile("fixtures/journey_unites_battle.json"))).value;
    }

    fn loadActors(alloc: std.mem.Allocator) !host.Bundle {
        return (try host.loadBundle(alloc, @embedFile("fixtures/journey_unites_actor_library.json"))).value;
    }

    fn loadScenes(alloc: std.mem.Allocator) !battle.spell_scene.Packet {
        var base = try std.json.parseFromSlice(std.json.Value, alloc, @embedFile("fixtures/spell_scene_library.json"), .{});
        const patch = try std.json.parseFromSlice(std.json.Value, alloc, @embedFile("fixtures/journey_unite_scenes_patch.json"), .{});
        var fields = patch.value.object.iterator();
        while (fields.next()) |entry| try base.value.object.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
        return (try battle.spell_scene.load(alloc, try std.json.Stringify.valueAlloc(alloc, base.value, .{}))).value;
    }

    fn findEncounter(content: battle.Content, id: []const u8) !usize {
        for (content.encounters, 0..) |entry, idx| {
            if (std.mem.eql(u8, entry.id, id)) return idx;
        }
        return error.MissingSourceEncounter;
    }

    fn findEnemy(content: battle.Content, id: []const u8) !battle.Profile {
        for (content.enemies) |entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry;
        }
        return error.MissingEnemyProfile;
    }

    fn setup(alloc: std.mem.Allocator, f: *const Fixtures, encounter_id: []const u8) !Setup {
        const members = try alloc.create([6]battle.Member);
        const state = try alloc.create(battle.State);
        state.* = try battle.State.init(f.content, f.items, members, 1234);
        state.encounter = try findEncounter(f.content, encounter_id);
        state.startEncounter();
        return .{
            .content = f.content,
            .actors = &f.actors,
            .scenes = &f.scenes,
            .items = f.items,
            .members = members,
            .state = state,
        };
    }

    fn attachAll(s: *Setup) !void {
        try s.state.attachUniteActors(s.actors);
        try s.state.attachSpellScenes(s.scenes);
    }

    fn prepareDefendingParty(s: *Setup, hp: u16) void {
        for (s.members, 0..) |*member, idx| {
            member.max_hp = hp;
            member.hp = hp;
            member.status = .healthy;
            member.balloons = 0;
            member.inventory.slots = @splat(null);
            s.state.actions[idx] = .defend;
        }
        s.state.acted = @splat(true);
        for (s.state.partyCount()..s.state.partyCount() + s.state.enemyCount()) |actor| s.state.acted[actor] = false;
        s.state.phase = .resolving;
        s.state.coordinator = .{ .stage = .dispatch, .current_actor = s.state.partyCount() };
    }

    fn hasSound(state: *const battle.State, sound_id: u16) bool {
        for (state.unite_vm.sounds[0..state.unite_vm.sound_count]) |sound| {
            if (sound.id == sound_id) return true;
        }
        return false;
    }

    fn enableSoulEaterRune(alloc: std.mem.Allocator, s: *Setup) !usize {
        var sys = s.state.content.systems.?;
        const runes = try alloc.alloc(@TypeOf(sys.runes[0]), sys.runes.len + 1);
        @memcpy(runes[0..sys.runes.len], sys.runes);
        runes[sys.runes.len] = sys.runes[0];
        runes[sys.runes.len].id = "soul_eater";
        sys.runes = runes;
        s.state.content.systems = sys;
        s.content.systems = sys;
        return sys.runes.len - 1;
    }
};

test "area magic source admission verifies enemy stats flags drops all 10 formations and schema or art refusals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const f = try area_suite.Fixtures.init(alloc);
    const content = f.content;
    const actors = f.actors;
    const scenes = f.scenes;
    const base_scenes = (try battle.spell_scene.load(alloc, @embedFile("fixtures/spell_scene_library.json"))).value;
    const items = f.items;

    try std.testing.expectEqual(@as(usize, 32), content.enemies.len);
    try std.testing.expectEqual(@as(usize, 96), content.encounters.len);

    const sorcerer = try area_suite.findEnemy(content, "sorcerer");
    try std.testing.expectEqual(@as(u8, 40), sorcerer.level);
    try std.testing.expectEqual(@as(u16, 200), sorcerer.max_hp);
    try std.testing.expectEqualDeep(battle.Stats{ .attack = 270, .skill = 100, .defense = 30, .speed = 90, .magic = 190, .luck = 90 }, sorcerer.stats);
    try std.testing.expect(sorcerer.action_policy == .source_sorcerer);
    try std.testing.expect(sorcerer.target_policy == .front_first);
    try std.testing.expectEqual(@as(?bool, true), sorcerer.airborne);
    try std.testing.expectEqual(@as(?bool, true), sorcerer.dodges_attacks);
    try std.testing.expectEqual(@as(u16, 94), sorcerer.knockout_ticks.?);
    try std.testing.expectEqual(area_suite.field.items.Id.master_robe, sorcerer.drops.?[0].item.?);
    try std.testing.expectEqual(@as(u8, 10), sorcerer.drops.?[0].rate);

    const siren = try area_suite.findEnemy(content, "siren");
    try std.testing.expectEqual(@as(u8, 32), siren.level);
    try std.testing.expectEqual(@as(u16, 250), siren.max_hp);
    try std.testing.expectEqualDeep(battle.Stats{ .attack = 260, .skill = 60, .defense = 20, .speed = 90, .magic = 160, .luck = 40 }, siren.stats);
    try std.testing.expect(siren.action_policy == .source_siren);
    try std.testing.expect(siren.target_policy == .front_first);
    try std.testing.expectEqual(@as(?bool, false), siren.airborne);
    try std.testing.expectEqual(@as(?bool, true), siren.dodges_attacks);
    try std.testing.expectEqual(@as(u16, 94), siren.knockout_ticks.?);
    try std.testing.expectEqual(area_suite.field.items.Id.prosperity_crystal, siren.drops.?[0].item.?);
    try std.testing.expectEqual(@as(u8, 6), siren.drops.?[0].rate);

    const golem = try area_suite.findEnemy(content, "earth_golem");
    try std.testing.expectEqual(@as(u8, 53), golem.level);
    try std.testing.expectEqual(@as(u16, 600), golem.max_hp);
    try std.testing.expectEqualDeep(battle.Stats{ .attack = 340, .skill = 70, .defense = 110, .speed = 70, .magic = 230, .luck = 35 }, golem.stats);
    try std.testing.expect(golem.action_policy == .source_earth_golem);
    try std.testing.expect(golem.target_policy == .front_first);
    try std.testing.expectEqual(@as(?bool, false), golem.airborne);
    try std.testing.expectEqual(@as(?bool, true), golem.dodges_attacks);
    try std.testing.expectEqual(@as(u16, 94), golem.knockout_ticks.?);
    try std.testing.expectEqual(area_suite.field.items.Id.master_garb, golem.drops.?[0].item.?);
    try std.testing.expectEqual(@as(u8, 10), golem.drops.?[0].rate);

    for ([_][]const u8{ "sorcerer", "siren", "earth_golem" }) |enemy_id| {
        const cap = actors.counterPacket().?.enemy(enemy_id).?;
        try std.testing.expect(!cap.counterable);
    }

    // Schema boundary refusals
    var old_content = content;
    old_content.schema = "suikoden-battle-trial/41";
    try std.testing.expectError(error.UnsupportedEnemyPresentation, old_content.validate());

    var old_actors = actors;
    old_actors.schema = "suikoden-unite-actors/38";
    try std.testing.expectError(error.InvalidUniteBindings, old_actors.validate());
    old_actors.enemy_area_magic = null;
    old_actors.enemy_regional = null;
    const reactions = try alloc.dupe(battle.counter.PartyReaction, old_actors.counter.?.melee.?.party_reactions);
    for (reactions) |*reaction| reaction.return_program = null;
    old_actors.counter.?.melee.?.party_reactions = reactions;
    try old_actors.validate();

    var missing_am = actors;
    missing_am.enemy_area_magic = null;
    try std.testing.expectError(error.InvalidUniteBindings, missing_am.validate());

    // Missing note graphics or body pose during attach leaves state unmutated
    const members = try alloc.create([6]battle.Member);
    var bad_graphics_content = content;
    var filtered_graphics = try std.ArrayList(battle.UniteGraphic).initCapacity(alloc, content.unite_graphics.len);
    for (content.unite_graphics) |g| {
        if (std.mem.eql(u8, g.id, "siren")) {
            var filtered_poses = try std.ArrayList(battle.UniteGraphicPose).initCapacity(alloc, g.poses.len);
            for (g.poses) |pose| {
                if (pose.id == 14) continue;
                try filtered_poses.append(alloc, pose);
            }
            var modified = g;
            modified.poses = filtered_poses.items;
            try filtered_graphics.append(alloc, modified);
            continue;
        }
        try filtered_graphics.append(alloc, g);
    }
    bad_graphics_content.unite_graphics = filtered_graphics.items;
    var bad_state = try battle.State.init(bad_graphics_content, items, members, 1);
    bad_state.encounter = try area_suite.findEncounter(content, "area_g_8");
    bad_state.startEncounter();
    try std.testing.expectError(error.InvalidUniteGraphics, bad_state.attachUniteActors(&actors));
    try std.testing.expect(bad_state.unite_actors == null);

    var no_body_content = content;
    var filtered_body = try std.ArrayList(battle.UniteGraphic).initCapacity(alloc, content.unite_graphics.len);
    for (content.unite_graphics) |g| {
        if (std.mem.eql(u8, g.id, "sorcerer")) continue;
        try filtered_body.append(alloc, g);
    }
    no_body_content.unite_graphics = filtered_body.items;
    no_body_content.presentation_ready = false;
    var no_body_state = try battle.State.init(no_body_content, items, members, 1);
    no_body_state.encounter = try area_suite.findEncounter(content, "area_e_7");
    no_body_state.startEncounter();
    try no_body_state.attachUniteActors(&actors);
    // Once presentation_ready is restored after validation, missing body pose refuses attach
    no_body_state.unite_actors = null;
    no_body_content.presentation_ready = true;
    no_body_state.content = no_body_content;
    try std.testing.expectError(error.MissingPhysicalArt, no_body_state.attachUniteActors(&actors));
    try std.testing.expect(no_body_state.unite_actors == null);

    // Missing golem_rock / golem_impact clips or impact center refuses beginEnemyMagic
    var golem_no_clip = try area_suite.setup(alloc, &f, "area_h_7");
    try golem_no_clip.state.attachUniteActors(golem_no_clip.actors);
    try golem_no_clip.state.attachSpellScenes(&base_scenes);
    try std.testing.expectError(error.MissingEnemyMagicArt, golem_no_clip.state.beginEnemyMagic(golem_no_clip.state.partyCount(), 0));
    try std.testing.expect(golem_no_clip.state.active == null);

    var missing_center_scenes = scenes;
    var magic_art_no_centers = missing_center_scenes.enemy_magic_art.?;
    magic_art_no_centers.anchors = magic_art_no_centers.anchors[1..];
    missing_center_scenes.enemy_magic_art = magic_art_no_centers;
    var sorc_no_center = try area_suite.setup(alloc, &f, "area_e_7");
    try sorc_no_center.state.attachUniteActors(sorc_no_center.actors);
    try sorc_no_center.state.attachSpellScenes(&missing_center_scenes);
    try std.testing.expectError(error.MissingEnemyMagicArt, sorc_no_center.state.beginEnemyMagic(sorc_no_center.state.partyCount(), 0));
    try std.testing.expect(sorc_no_center.state.active == null);

    // All 10 admitted E/G/H formations execute clean round-trips
    const formations = [_][]const u8{ "area_e_7", "area_e_8", "area_e_9", "area_g_6", "area_g_8", "area_g_9", "area_h_7", "area_h_8", "area_h_9", "area_h_11" };
    for (formations) |enc_id| {
        var s = try area_suite.setup(alloc, &f, enc_id);
        try area_suite.attachAll(&s);
        area_suite.prepareDefendingParty(&s, 9999);
        const values: [4096]u15 = @splat(51);
        var draws = battle.systems.Draws{ .values = &values };
        for (0..1800) |_| {
            try s.state.tickReplay(.{}, &draws);
            if (s.state.round >= 2 and s.state.phase == .battle_menu and !s.state.unite_vm.hasActors()) break;
        }
        try std.testing.expectEqual(@as(u32, 2), s.state.round);
        try std.testing.expect(s.state.phase == .battle_menu and s.state.active == null and !s.state.unite_vm.hasActors());
        // Non-counterable & non-parryable check against slot 0 enemy
        try std.testing.expect(!try s.state.parryAvailable(0, s.state.partyCount()));
        try std.testing.expect(!try s.state.counterAvailable(0, s.state.partyCount()));
    }
}

test "area magic AI uses front scan secondary special thresholds pending wait empty scan and ordinary rock or wave or dodge or cover" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const f = try area_suite.Fixtures.init(alloc);

    // 1. Sorcerer front scan + secondary draw threshold: 16711 -> ordinary (50%), 16712 -> special (51%)
    {
        var ord_s = try area_suite.setup(alloc, &f, "area_e_7");
        try area_suite.attachAll(&ord_s);
        area_suite.prepareDefendingParty(&ord_s, 9999);
        const owner = ord_s.state.partyCount();
        var ord_draws = battle.systems.Draws{ .values = &.{ 51, 16711, 51, 51, 51 } };
        ord_s.state.replay_draws = &ord_draws;
        ord_s.state.sourceEnemyDecision(owner);
        ord_s.state.replay_draws = null;
        try std.testing.expectEqual(@as(usize, 3), ord_draws.cursor);
        try std.testing.expect(ord_s.state.active.?.kind == .attack);
        try std.testing.expect(!ord_s.state.unite_vm.hasEnemyMagic());

        var spec_s = try area_suite.setup(alloc, &f, "area_e_7");
        try area_suite.attachAll(&spec_s);
        area_suite.prepareDefendingParty(&spec_s, 9999);
        var spec_draws = battle.systems.Draws{ .values = &.{ 51, 16712, 51 } };
        spec_s.state.replay_draws = &spec_draws;
        spec_s.state.sourceEnemyDecision(owner);
        spec_s.state.replay_draws = null;
        try std.testing.expectEqual(@as(usize, 2), spec_draws.cursor);
        try std.testing.expect(spec_s.state.active.?.kind == .enemy_magic);
        try std.testing.expect(spec_s.state.unite_vm.enemy_magic_actions[owner] != null);
    }

    // 2. Pending target wait (coordinator lock on chosen front target) and empty scan turn consumption
    {
        var wait_s = try area_suite.setup(alloc, &f, "area_e_7");
        try area_suite.attachAll(&wait_s);
        area_suite.prepareDefendingParty(&wait_s, 9999);
        const owner = wait_s.state.partyCount();
        // Mark another living party member pending KO so branch waits before starting enemy magic
        wait_s.state.party_knockouts[1].pending = true;
        var wait_draws = battle.systems.Draws{ .values = &.{ 51, 16712 } };
        wait_s.state.replay_draws = &wait_draws;
        wait_s.state.sourceEnemyDecision(owner);
        wait_s.state.replay_draws = null;
        try std.testing.expect(wait_s.state.enemy_branch_selection != null);
        try std.testing.expect(wait_s.state.active == null);
        // Empty living party leaves enemy turn cleanly consumed
        for (&wait_s.state.party_knockouts) |*knockout| knockout.pending = false;
        for (wait_s.members) |*m| {
            m.hp = 0;
            m.status = .unconscious;
        }
        wait_s.state.enemy_branch_selection = null;
        wait_s.state.acted[owner] = false;
        var empty_draws = battle.systems.Draws{ .values = &.{51} };
        wait_s.state.replay_draws = &empty_draws;
        wait_s.state.sourceEnemyDecision(owner);
        wait_s.state.replay_draws = null;
        try std.testing.expect(wait_s.state.acted[owner]);
        try std.testing.expect(wait_s.state.active == null);
    }

    // 3. Earth Golem threshold 23264 (70% ordinary + rock child) vs 23265 (71% special) & dodge + cover
    {
        var ord_g = try area_suite.setup(alloc, &f, "area_h_7");
        try area_suite.attachAll(&ord_g);
        area_suite.prepareDefendingParty(&ord_g, 9999);
        const owner = ord_g.state.partyCount();
        var values: [512]u15 = @splat(51);
        values[1] = 23264;
        var draws = battle.systems.Draws{ .values = &values };
        ord_g.state.replay_draws = &draws;
        ord_g.state.sourceEnemyDecision(owner);
        ord_g.state.replay_draws = null;
        try std.testing.expect(ord_g.state.active.?.kind == .attack);
        var saw_rock_child = false;
        for (0..180) |_| {
            if (ord_g.state.round >= 2 and ord_g.state.phase == .battle_menu and !ord_g.state.unite_vm.hasActors()) break;
            try ord_g.state.tickReplay(.{}, &draws);
            for (ord_g.state.unite_vm.auxiliary) |maybe_aux| if (maybe_aux) |aux| {
                if (aux.resource) |res| if (std.mem.eql(u8, res.id, "earth_golem")) {
                    saw_rock_child = true;
                };
            };
        }
        try std.testing.expect(saw_rock_child);

        var spec_g = try area_suite.setup(alloc, &f, "area_h_7");
        try area_suite.attachAll(&spec_g);
        area_suite.prepareDefendingParty(&spec_g, 9999);
        var spec_draws = battle.systems.Draws{ .values = &.{ 51, 23265, 51 } };
        spec_g.state.replay_draws = &spec_draws;
        spec_g.state.sourceEnemyDecision(owner);
        spec_g.state.replay_draws = null;
        try std.testing.expect(spec_g.state.active.?.kind == .enemy_magic);
    }

    // 4. Siren ordinary spawns 5 children, dodge miss, and cover protector intercepts ordinary melee
    {
        var siren_s = try area_suite.setup(alloc, &f, "area_g_8");
        try area_suite.attachAll(&siren_s);
        area_suite.prepareDefendingParty(&siren_s, 9999);
        const owner = siren_s.state.partyCount();
        var values: [512]u15 = @splat(51);
        values[1] = 16711;
        var draws = battle.systems.Draws{ .values = &values };
        siren_s.state.replay_draws = &draws;
        siren_s.state.sourceEnemyDecision(owner);
        siren_s.state.replay_draws = null;
        var max_children: usize = 0;
        for (0..180) |_| {
            if (siren_s.state.round >= 2 and siren_s.state.phase == .battle_menu and !siren_s.state.unite_vm.hasActors()) break;
            try siren_s.state.tickReplay(.{}, &draws);
            var active_children: usize = 0;
            for (siren_s.state.unite_vm.auxiliary) |maybe_aux| if (maybe_aux != null) {
                active_children += 1;
            };
            max_children = @max(max_children, active_children);
        }
        try std.testing.expect(max_children >= 5);

        // Enemy dodge check against party strike + Cover protection intercepting enemy ordinary melee
        var cov_s = try area_suite.setup(alloc, &f, "area_e_7");
        try area_suite.attachAll(&cov_s);
        cov_s.members[0].id = "camille";
        cov_s.members[0].name = "Camille";
        cov_s.members[1].id = "gremio";
        cov_s.members[1].name = "Gremio";
        cov_s.state.actions = @splat(null);
        cov_s.state.actions[0] = .defend;
        cov_s.state.actions[1] = .defend;
        cov_s.state.actions[2] = .defend;
        cov_s.state.actions[3] = .defend;
        cov_s.state.actions[4] = .defend;
        cov_s.state.actions[5] = .defend;
        for (cov_s.members) |*m| {
            m.max_hp = 9999;
            m.hp = 9999;
        }
        cov_s.state.acted = @splat(true);
        cov_s.state.acted[owner] = false;
        cov_s.state.phase = .resolving;
        cov_s.state.coordinator = .{ .stage = .dispatch, .current_actor = owner };
        // Miss strike against sorcerer (dodges_attacks = true) check: beginPartyMelee(..., hit=false, critical=false) triggers dodge
        var miss_s = try area_suite.setup(alloc, &f, "area_e_7");
        try area_suite.attachAll(&miss_s);
        area_suite.prepareDefendingParty(&miss_s, 9999);
        miss_s.state.phase = .battle_menu;
        miss_s.state.acted = @splat(true);
        try miss_s.state.beginPartyMelee(0, owner, false, false);
        const dodge_prog = f.actors.programs.find("melee/sorcerer/dodge").?.instructions.ptr;
        var miss_draws_vals: [64]u15 = @splat(51);
        var miss_draws = battle.systems.Draws{ .values = &miss_draws_vals };
        var saw_dodge = false;
        for (0..220) |_| {
            try miss_s.state.tickReplay(.{}, &miss_draws);
            if (miss_s.state.unite_vm.actors[owner].machine) |m| {
                if (m.instructions.ptr == dodge_prog) saw_dodge = true;
            }
            if (!miss_s.state.unite_vm.hasActors() and miss_s.state.active == null) break;
        }
        try std.testing.expect(saw_dodge);
        try std.testing.expect(!miss_s.state.unite_vm.hasActors() and miss_s.state.active == null);
        // Protect partner via state.protector
        cov_s.members[0].hp = 10;
        cov_s.state.progress.party[0].base_stats.luck = 0;
        cov_s.state.progress.party[1].base_stats.luck = 999;
        var p_values: [512]u15 = @splat(51);
        var p_draws = battle.systems.Draws{ .values = &p_values };
        _ = try cov_s.state.protector(0);
        for (0..220) |_| {
            try cov_s.state.tickReplay(.{}, &p_draws);
            if (cov_s.state.round >= 2 and cov_s.state.phase == .battle_menu and !cov_s.state.unite_vm.hasActors()) break;
        }
        try std.testing.expectEqual(@as(u32, 2), cov_s.state.round);
    }
}

test "Sorcerer special drives 20 psxSqrt lines 32 beam sprites centered impact sounds rune 1 and 7 halving and zero delay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const f = try area_suite.Fixtures.init(alloc);

    // Test slots 0..3 with runes: 0=null, 1=soul_eater (rune 1 -> selector 7 -> halved), 2=resurrection (rune 7 -> selector 6 == element -> halved), 3=water (rune 3 -> selector 2 != 6 -> full)
    var damages: [4]u32 = undefined;
    for (0..4) |slot| {
        var s = try area_suite.setup(alloc, &f, "area_e_7");
        try area_suite.attachAll(&s);
        const soul_eater_idx = try area_suite.enableSoulEaterRune(alloc, &s);
        area_suite.prepareDefendingParty(&s, 9999);
        for (s.state.progress.party) |*member| member.rune = null;
        if (slot == 1) s.state.progress.party[slot].rune = soul_eater_idx;
        if (slot == 2) s.state.progress.party[slot].rune = s.content.systems.?.runeIndex("resurrection");
        if (slot == 3) s.state.progress.party[slot].rune = s.content.systems.?.runeIndex("water");
        for (0..s.state.partyCount()) |i| s.state.progress.party[i].base_stats.magic = 40;
        const owner = s.state.partyCount();
        try s.state.beginEnemyMagic(owner, slot);

        var values: [512]u15 = @splat(1055);
        var draws = battle.systems.Draws{ .values = &values };
        var saw_u1 = false;
        var saw_beam = false;
        var saw_impact = false;
        var saw_sound_1 = false;
        var saw_sound_97 = false;
        var saw_damage = false;
        var zero_delay_checked = false;

        for (0..450) |_| {
            const had_action = s.state.unite_vm.enemy_magic_actions[owner] != null;
            const prev_phase = if (s.state.unite_vm.enemy_magic_actions[owner]) |act| act.phase else null;
            const prev_cursor = draws.cursor;
            try s.state.tickReplay(.{}, &draws);
            if (area_suite.hasSound(s.state, 2068)) saw_sound_1 = true;
            if (area_suite.hasSound(s.state, 1406)) saw_sound_97 = true;

            if (s.state.unite_vm.enemy_magic_actions[owner]) |action| {
                if (prev_phase != null and prev_phase.? == .running and action.phase == .running and action.update == 1) {
                    saw_u1 = true;
                    try std.testing.expectEqual(@as(usize, 80), draws.cursor - prev_cursor);
                    try std.testing.expect(action.area.? == .sorcerer);
                    for (action.area.?.sorcerer) |line| try std.testing.expect(line.enabled);
                    try std.testing.expect(area_suite.hasSound(s.state, 2068));
                }
                if (action.phase == .running and action.update == 97) {
                    try std.testing.expect(area_suite.hasSound(s.state, 1406));
                }
                if (action.phase == .running and action.update == 120) {
                    const gfx = action.areaGraphics(f.actors.areaMagicFor("sorcerer").?, f.scenes.enemy_magic_art.?);
                    var beams: usize = 0;
                    for (gfx.sprites[0..gfx.sprite_count]) |sp| {
                        if (sp.kind == .projectile) beams += 1;
                    }
                    saw_beam = beams == 32;
                }
                if (action.phase == .running and action.update == 121) {
                    try std.testing.expect(action.recipient_started);
                    const gfx = action.areaGraphics(f.actors.areaMagicFor("sorcerer").?, f.scenes.enemy_magic_art.?);
                    var impacts: usize = 0;
                    var beams: usize = 0;
                    for (gfx.sprites[0..gfx.sprite_count]) |sp| {
                        if (sp.kind == .projectile) beams += 1;
                        if (sp.kind == .impact) impacts += 1;
                    }
                    try std.testing.expectEqual(@as(usize, 30), beams);
                    saw_impact = impacts == 1;
                    const frame = s.state.spellSceneFrame();
                    try std.testing.expect(frame.count >= 31);
                }
                if (action.phase == .running and action.update == 293) {
                    try std.testing.expect(action.amount != null);
                    saw_damage = true;
                }
            } else if (had_action and s.state.coordinator != null and s.state.coordinator.?.stage == .select and !zero_delay_checked) {
                try std.testing.expectEqual(@as(i32, 0), s.state.coordinator.?.remaining);
                zero_delay_checked = true;
            }
            if (s.state.round >= 2 and s.state.phase == .battle_menu and !s.state.unite_vm.hasActors()) break;
        }
        try std.testing.expect(saw_u1 and saw_beam and saw_impact and saw_sound_1 and saw_sound_97 and saw_damage and zero_delay_checked);
        damages[slot] = 9999 - s.members[slot].hp;
        try std.testing.expect(damages[slot] > 0);
    }
    // Fire (rune 1) and Boar (rune 7) are halved vs Null (0) and Water (rune 2)
    try std.testing.expectEqual(damages[0], damages[3]);
    try std.testing.expectEqual(damages[1], damages[2]);
    try std.testing.expectEqual(damages[0] / 2, damages[1]);
}

test "Siren special runs 20-tick warmup camera 4 columns 16 sirenNote quads 8 wave reactions rune_blocked Turtle mailboxes and delay 30" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const f = try area_suite.Fixtures.init(alloc);

    var s = try area_suite.setup(alloc, &f, "area_g_8");
    try area_suite.attachAll(&s);
    const soul_eater_idx = try area_suite.enableSoulEaterRune(alloc, &s);
    area_suite.prepareDefendingParty(&s, 9999);
    s.state.actor_camera = try @TypeOf(s.state.actor_camera.?).init(battle.layout.currentCamera(s.state.*));
    for (s.state.progress.party) |*member| member.rune = null;
    s.state.progress.party[1].rune = s.content.systems.?.runeIndex("turtle");
    s.state.progress.party[2].rune = soul_eater_idx;
    for (0..s.state.partyCount()) |i| s.state.progress.party[i].base_stats.magic = 40;
    const owner = s.state.partyCount();
    try s.state.beginEnemyMagic(owner, 0);

    // Draws = 51 -> statusPercent(51) == 0 < 10 (always inflicts .rune_blocked when not Turtle immune!)
    var values: [512]u15 = @splat(51);
    var draws = battle.systems.Draws{ .values = &values };
    var saw_shared_1 = false;
    var saw_shared_2 = false;
    var saw_shared_3 = false;
    var saw_shared_100 = false;
    var saw_camera = false;
    var saw_siren_note_quad = false;
    var saw_columns = false;
    var wave_dispatches: usize = 0;
    var saw_delay_30 = false;
    var prev_update: u16 = 0;
    const expected_wave_ticks = [_]u16{ 47, 63, 79, 95, 112, 128, 144, 160 };

    for (0..350) |_| {
        const had_action = s.state.unite_vm.enemy_magic_actions[owner] != null;
        try s.state.tickReplay(.{}, &draws);
        const owner_shared = s.state.unite_vm.actors[owner].shared_value;
        if (owner_shared == 1) saw_shared_1 = true;
        if (owner_shared == 2) saw_shared_2 = true;
        if (owner_shared == 3) saw_shared_3 = true;
        if (owner_shared == 100) saw_shared_100 = true;
        if (s.state.actor_camera.?.remaining[0] > 0) saw_camera = true;

        if (s.state.unite_vm.enemy_magic_actions[owner]) |action| {
            if (action.phase == .running and action.update != prev_update) {
                prev_update = action.update;
                if (action.update == 64) {
                    const gfx = action.areaGraphics(f.actors.areaMagicFor("siren").?, f.scenes.enemy_magic_art.?);
                    saw_columns = gfx.column_count == 4 and gfx.note_count == 16;
                    for (0..16) |n| {
                        const quad = battle.layout.uniteAuxiliaryPiece(s.state.*, battle.layout.siren_note_offset + n, 0);
                        if (quad != null and quad.?.translucent) saw_siren_note_quad = true;
                    }
                    const frame = s.state.spellSceneFrame();
                    try std.testing.expect(frame.count >= 4 * 24);
                }
                for (expected_wave_ticks) |wt| if (action.update == wt) {
                    wave_dispatches += 1;
                    try std.testing.expect((action.group_recipients_started & 1) != 0);
                };
            }
        } else if (had_action and s.state.coordinator != null and s.state.coordinator.?.stage == .select and !saw_delay_30) {
            try std.testing.expectEqual(@as(i32, 30), s.state.coordinator.?.remaining);
            saw_delay_30 = true;
        }
        if (s.state.round >= 2 and s.state.phase == .battle_menu and !s.state.unite_vm.hasActors()) break;
    }

    try std.testing.expect(saw_shared_1 and saw_shared_2 and saw_shared_3 and saw_shared_100);
    try std.testing.expect(saw_camera and saw_siren_note_quad and saw_columns);
    try std.testing.expectEqual(@as(usize, 8), wave_dispatches);
    try std.testing.expect(saw_delay_30);
    // Slot 0 blocked by .rune_blocked, slot 1 immune via Turtle rune!
    try std.testing.expect(s.state.actor_conditions[0].rune_blocked);
    try std.testing.expect(!s.state.actor_conditions[1].rune_blocked);
    // Fire rune slot 2 took half damage vs unequipped slot 0
    const d0 = 9999 - s.members[0].hp;
    const d2 = 9999 - s.members[2].hp;
    try std.testing.expectEqual(d0 / 2, d2);
}

test "Earth Golem special runs 6 rock arcs camera z pulses centered golem_impact slot fallback halving sounds and delay 30" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const f = try area_suite.Fixtures.init(alloc);

    var s = try area_suite.setup(alloc, &f, "area_h_7");
    try area_suite.attachAll(&s);
    area_suite.prepareDefendingParty(&s, 9999);
    for (s.state.progress.party) |*member| member.rune = null;
    s.state.progress.party[1].rune = s.content.systems.?.runeIndex("earth"); // rune=6 -> target_rune_elements[5]=3 == element
    s.state.progress.party[2].rune = null; // fallback_by_slot -> slot 2 + 1 = 3 == element
    s.state.progress.party[3].rune = s.content.systems.?.runeIndex("water"); // rune=3 -> raw=2 != 3
    s.state.progress.party[4].rune = s.content.systems.?.runeIndex("shrike"); // rune=9 -> raw=0 -> fallback=5 != 3
    for (0..s.state.partyCount()) |i| s.state.progress.party[i].base_stats.magic = 40;
    const owner = s.state.partyCount();
    try s.state.beginEnemyMagic(owner, 0);

    var values: [512]u15 = @splat(100);
    var draws = battle.systems.Draws{ .values = &values };
    var saw_sound_1 = false;
    var saw_sound_113 = false;
    var saw_pos_pulse = false;
    var saw_neg_pulse = false;
    var saw_launch = false;
    var saw_impacts = false;
    var saw_delay_30 = false;
    var prev_update: u16 = 0;

    for (0..350) |_| {
        const had_action = s.state.unite_vm.enemy_magic_actions[owner] != null;
        try s.state.tickReplay(.{}, &draws);
        if (area_suite.hasSound(s.state, 2080)) saw_sound_1 = true;
        if (area_suite.hasSound(s.state, 1313)) saw_sound_113 = true;

        if (s.state.unite_vm.enemy_magic_actions[owner]) |action| {
            if (action.phase == .running and action.update != prev_update) {
                prev_update = action.update;
                if (action.update <= 191) {
                    if (action.update % 4 == 1) {
                        try std.testing.expectEqual(@as(i32, 20480), s.state.enemy_magic_pulse.?.delta_q12);
                        saw_pos_pulse = true;
                    }
                    if (action.update % 4 == 3) {
                        try std.testing.expectEqual(@as(i32, -20480), s.state.enemy_magic_pulse.?.delta_q12);
                        saw_neg_pulse = true;
                    }
                }
                if (action.update == 65) {
                    const gfx = action.areaGraphics(f.actors.areaMagicFor("earth_golem").?, f.scenes.enemy_magic_art.?);
                    saw_launch = gfx.sprite_count == 6;
                }
                if (action.update == 113) {
                    const gfx = action.areaGraphics(f.actors.areaMagicFor("earth_golem").?, f.scenes.enemy_magic_art.?);
                    try std.testing.expectEqual(@as(usize, 12), gfx.sprite_count);
                    const frame = s.state.spellSceneFrame();
                    try std.testing.expect(frame.count >= 12);
                    saw_impacts = true;
                }
            }
        } else if (had_action and s.state.coordinator != null and s.state.coordinator.?.stage == .select and !saw_delay_30) {
            try std.testing.expectEqual(@as(i32, 30), s.state.coordinator.?.remaining);
            saw_delay_30 = true;
        }
        if (s.state.round >= 2 and s.state.phase == .battle_menu and !s.state.unite_vm.hasActors()) break;
    }

    try std.testing.expect(saw_sound_1 and saw_sound_113 and saw_pos_pulse and saw_neg_pulse);
    try std.testing.expect(saw_launch and saw_impacts and saw_delay_30);
    const d0 = 9999 - s.members[0].hp;
    try std.testing.expectEqual(d0 / 2, 9999 - s.members[1].hp);
    try std.testing.expectEqual(d0 / 2, 9999 - s.members[2].hp);
    try std.testing.expectEqual(d0, 9999 - s.members[3].hp);
    try std.testing.expectEqual(d0, 9999 - s.members[4].hp);

    // Slot 2 with water rune (raw = 1 != 0) does NOT fall back to slot 3 -> full damage
    var s2 = try area_suite.setup(alloc, &f, "area_h_7");
    try area_suite.attachAll(&s2);
    area_suite.prepareDefendingParty(&s2, 9999);
    for (s2.state.progress.party) |*member| member.rune = null;
    s2.state.progress.party[2].rune = s2.content.systems.?.runeIndex("water");
    for (0..s2.state.partyCount()) |i| s2.state.progress.party[i].base_stats.magic = 40;
    try s2.state.beginEnemyMagic(s2.state.partyCount(), 0);
    var draws2 = battle.systems.Draws{ .values = &values };
    for (0..350) |_| {
        try s2.state.tickReplay(.{}, &draws2);
        if (s2.state.round >= 2 and s2.state.phase == .battle_menu and !s2.state.unite_vm.hasActors()) break;
    }
    try std.testing.expectEqual(d0, 9999 - s2.members[2].hp);
}

test "area magic covers group protection Sleep Sacrificial Buddha revival RNG rollback and JSON checkpoint round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const f = try area_suite.Fixtures.init(alloc);
    const other_actors = try area_suite.loadActors(alloc);

    // 1. Group protection + Sleep + Sacrificial Buddha delayed revival (on Siren where reaction_update == damage_update == 198)
    {
        var s = try area_suite.setup(alloc, &f, "area_g_8");
        try area_suite.attachAll(&s);
        area_suite.prepareDefendingParty(&s, 9999);
        s.members[0].hp = 1; // Sacrificial Buddha target
        s.members[0].inventory.slots[0] = .{ .id = .sacrificial_buddha, .uses = 0 };
        for (&s.state.actor_conditions) |*conditions| conditions.protection_rounds = 0;
        s.state.actor_conditions[1].protection_rounds = 2;
        s.state.clearSleep();
        s.state.actor_conditions[2].sleep_turns = 2;
        const owner = s.state.partyCount();
        try s.state.beginEnemyMagic(owner, 0);
        var values: [512]u15 = @splat(100);
        var draws = battle.systems.Draws{ .values = &values };
        var checked_locked_pending = false;
        for (0..450) |_| {
            try s.state.tickReplay(.{}, &draws);
            if (s.members[0].hp == 0 and s.state.unite_vm.ownsActor(0)) {
                try std.testing.expect(s.state.party_knockouts[0].pending);
                try std.testing.expect(s.state.party_knockouts[0].revival == null);
                checked_locked_pending = true;
            }
            if (s.state.round >= 2 and s.state.phase == .battle_menu and !s.state.unite_vm.hasActors() and !s.state.hasPendingRevival()) break;
        }
        try std.testing.expect(checked_locked_pending);
        try std.testing.expectEqual(@as(u16, 4999), s.members[0].hp);
        try std.testing.expectEqual(area_suite.field.game_state.Status.healthy, s.members[0].status);
        try std.testing.expect(s.members[0].inventory.slots[0] == null);
        // Slot 1 protected -> 0 damage; Slot 2 still slept/took damage cleanly
        try std.testing.expectEqual(@as(u16, 9999), s.members[1].hp);
        try std.testing.expect(s.members[2].hp < 9999);
    }

    // 2. RNG exhaustion rollback on Sorcerer at u==1 (mid line-pool draw) and at damage_update (293)
    {
        var s = try area_suite.setup(alloc, &f, "area_e_7");
        try area_suite.attachAll(&s);
        area_suite.prepareDefendingParty(&s, 9999);
        const owner = s.state.partyCount();
        try s.state.beginEnemyMagic(owner, 0);
        var values: [4096]u15 = @splat(1055);
        var draws = battle.systems.Draws{ .values = &values };
        const before_state = try alloc.create(battle.State);
        const before_members = try alloc.create([6]battle.Member);
        var tested_u1 = false;
        var tested_dmg = false;

        for (0..400) |_| {
            if (s.state.unite_vm.enemy_magic_actions[owner]) |action| {
                if (!tested_u1 and action.phase == .create) {
                    before_state.* = s.state.*;
                    before_members.* = s.members.*;
                    const saved_cursor = draws.cursor;
                    try s.state.tickReplay(.{}, &draws); // enters .running u=0
                    // Next tick runs u=1 (80 draws); cut off after 10
                    before_state.* = s.state.*;
                    before_members.* = s.members.*;
                    draws.values = values[0 .. draws.cursor + 10];
                    const mid_cursor = draws.cursor;
                    try std.testing.expectError(error.RandomInputExhausted, s.state.tickReplay(.{}, &draws));
                    try std.testing.expectEqualDeep(before_members.*, s.members.*);
                    try std.testing.expectEqualDeep(before_state.unite_vm.enemy_magic_actions, s.state.unite_vm.enemy_magic_actions);
                    try std.testing.expectEqual(mid_cursor, draws.cursor);
                    try std.testing.expectEqual(before_state.camera_ticks, s.state.camera_ticks);
                    draws.values = &values;
                    tested_u1 = true;
                    _ = saved_cursor;
                }
                if (!tested_dmg and action.phase == .running and action.update == 292) {
                    before_state.* = s.state.*;
                    before_members.* = s.members.*;
                    const cursor = draws.cursor;
                    draws.values = values[0..cursor];
                    try std.testing.expectError(error.RandomInputExhausted, s.state.tickReplay(.{}, &draws));
                    try std.testing.expectEqualDeep(before_members.*, s.members.*);
                    try std.testing.expectEqualDeep(before_state.unite_vm.enemy_magic_actions, s.state.unite_vm.enemy_magic_actions);
                    try std.testing.expectEqual(cursor, draws.cursor);
                    draws.values = &values;
                    tested_dmg = true;
                }
            }
            try s.state.tickReplay(.{}, &draws);
            if (s.state.round >= 2 and s.state.phase == .battle_menu and !s.state.unite_vm.hasActors()) break;
        }
        try std.testing.expect(tested_u1 and tested_dmg);
    }

    // 3. JSON checkpoint round-trip mid-.running for Sorcerer, Siren, and Earth Golem
    for ([_]struct { enc: []const u8, pause_u: u16 }{
        .{ .enc = "area_e_7", .pause_u = 50 },
        .{ .enc = "area_g_8", .pause_u = 50 },
        .{ .enc = "area_h_7", .pause_u = 80 },
    }) |spec| {
        var s = try area_suite.setup(alloc, &f, spec.enc);
        try area_suite.attachAll(&s);
        area_suite.prepareDefendingParty(&s, 9999);
        const owner = s.state.partyCount();
        try s.state.beginEnemyMagic(owner, 0);
        var values: [4096]u15 = @splat(1055);
        var draws = battle.systems.Draws{ .values = &values };
        var checkpointed = false;
        for (0..450) |_| {
            try s.state.tickReplay(.{}, &draws);
            if (!checkpointed) if (s.state.unite_vm.enemy_magic_actions[owner]) |action| if (action.phase == .running and action.update == spec.pause_u) {
                const bytes = try std.json.Stringify.valueAlloc(alloc, s.state.unite_vm, .{});
                var decoded = try std.json.parseFromSlice(battle.unite_playback.State, alloc, bytes, .{});
                try decoded.value.rebind(&other_actors);
                s.state.unite_vm = decoded.value;
                s.state.unite_actors = &other_actors;
                try std.testing.expect(s.state.unite_vm.enemy_magic_actions[owner].?.area != null);
                checkpointed = true;
            };
            if (s.state.round >= 2 and s.state.phase == .battle_menu and !s.state.unite_vm.hasActors()) break;
        }
        try std.testing.expect(checkpointed);
        try std.testing.expectEqual(@as(u32, 2), s.state.round);
        try std.testing.expect(s.members[0].hp < 9999);
    }
}
