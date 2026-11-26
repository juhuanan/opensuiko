const std = @import("std");
const battle = @import("battle");
const host = battle.actor_host;
const vm = battle.actor_program;
const magic = battle.enemy_magic;
const allocator = std.testing.allocator;
const h = @import("helpers.zig");

const Fixture = struct {
    programs: vm.Packet,
    resource: host.Resource,
    id: []const u8,
    selection_delay: u16,
    effect: magic.Parameters,
    damage: struct { element: u8, target_rune_elements: [31]u8, fallback_element: u8 },
    clips: []const struct { id: magic.ClipKind, frames: []const struct { pose: u16, updates: u16 } },
    impact_anchors: @FieldType(magic.Art, "anchors"),
    fn binding(self: Fixture) magic.Binding {
        return .{ .id = self.id, .selection_delay = self.selection_delay, .effect = self.effect, .element = self.damage.element, .target_rune_elements = self.damage.target_rune_elements, .fallback_element = self.damage.fallback_element, .owner_program = self.programs.programs[0].id, .recipient_program = self.programs.programs[1].id };
    }
};
fn fixture() !std.json.Parsed(Fixture) {
    const parsed = try std.json.parseFromSlice(Fixture, allocator, @embedFile("../fixtures/kobold_magic_scene.json"), .{ .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    try parsed.value.programs.validate();
    try parsed.value.resource.validate();
    try parsed.value.binding().validate();
    return parsed;
}

const EffectRequest = struct {
    update: u16 = 0,
    called_at: ?u16 = null,
    fn command(raw: *anyopaque, actor: u16, request: vm.Command, resuming: bool) !bool {
        const self: *EffectRequest = @ptrCast(@alignCast(raw));
        if (actor != 0 or request != .effect or request.effect.binding != .self or !std.mem.eql(u8, request.effect.id, "kobold_magic") or resuming) return error.InvalidEnemyMagicRequest;
        if (self.called_at != null) return error.DuplicateEnemyMagicRequest;
        self.called_at = self.update;
        return true;
    }
};

test "Enemy magic source owner waits for its actual callback and leaves missing integration refused" {
    const parsed = try fixture();
    defer parsed.deinit();
    const data = parsed.value;
    const program = data.programs.find("kobold_type_3/magic_owner").?;
    var actors = [_]host.Actor{try host.Actor.init(data.resource, .{ -120 * 4096, 50 * 4096, 0 })};
    var runtime = host.Runtime{ .actors = &actors };
    try runtime.dispatch(0, null, program);
    for (1..27) |_| try runtime.stepActor(0);
    try std.testing.expectError(error.UnsupportedActorCommand, runtime.stepActor(0));
    try std.testing.expect(!actors[0].released);

    actors[0] = try host.Actor.init(data.resource, .{ -120 * 4096, 50 * 4096, 0 });
    var request = EffectRequest{};
    runtime.external = .{ .context = &request, .command = EffectRequest.command };
    try runtime.dispatch(0, null, program);
    try std.testing.expectEqual(@as(u16, 13), actors[0].animation);
    for (1..121) |update| {
        request.update = @intCast(update);
        try runtime.stepActor(0);
        if (update < 25) try std.testing.expectEqual(@as(u16, 13), actors[0].animation);
        if (update >= 25) try std.testing.expectEqual(@as(u16, 14), actors[0].animation);
        try std.testing.expect(!actors[0].released and actors[0].highlights == 1 and !actors[0].machine.?.halted);
    }
    try std.testing.expectEqual(@as(?u16, 27), request.called_at);
    actors[0].shared_value = 99;
    try runtime.stepActor(0);
    try std.testing.expectEqual(@as(u16, 15), actors[0].animation);
    try std.testing.expect(!actors[0].released);
    try runtime.stepActor(0);
    try std.testing.expect(!actors[0].released);
    try runtime.stepActor(0);
    try std.testing.expect(actors[0].released and actors[0].machine.?.halted);
    try std.testing.expectEqual(@as(u8, 0), actors[0].highlights);
    try std.testing.expectEqual(@as(i16, 100), actors[0].shared_value);
}

test "Enemy magic source palette and six jiggles run on every exported party resource" {
    const parsed = try fixture();
    defer parsed.deinit();
    const counters = try battle.counter.load(allocator, @embedFile("../fixtures/counter_actor_library.json"));
    defer counters.deinit();
    const program = parsed.value.programs.find("kobold_type_3/magic_recipient").?;
    var count: usize = 0;
    for (counters.value.melee.?.party_reactions) |member| {
        const resource = counters.value.animations.find(member.id).?;
        var actors = [_]host.Actor{try host.Actor.init(resource, .{ 120 * 4096, -20 * 4096, 0 })};
        var runtime = host.Runtime{ .actors = &actors };
        try runtime.dispatch(0, null, program);
        try std.testing.expect(!actors[0].palette_cycle_active and actors[0].highlights == 8);
        for (1..35) |update| {
            try runtime.stepActor(0);
            const offset: [2]i8 = if (update < 3) .{ 0, 0 } else if (@min((update - 3) / 5, 5) % 2 == 0) .{ -5, 0 } else .{ 0, 5 };
            try std.testing.expectEqualDeep(offset, actors[0].screen_offset);
            if (update >= 2 and update < 33) {
                try std.testing.expectEqual(@as(u8, @intCast(1 + ((update - 1) / 4) % 3)), actors[0].palette.shared);
            }
            try std.testing.expectEqualDeep(actors[0].home_q12, actors[0].position_q12);
        }
        try std.testing.expect(actors[0].machine.?.halted and !actors[0].palette_cycle_active);
        try std.testing.expect(actors[0].palette == .resource and actors[0].highlights == 0);
        try std.testing.expectEqual(@as(i16, 99), actors[0].shared_value);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 78), count);
}

const CallbackHost = struct {
    binding: magic.Binding,
    action: magic.Playback = .{ .owner = 1, .recipient = 0, .start_at = 0 },
    runtime: *host.Runtime = undefined,
    recipient_program: vm.Program,
    update: u16 = 0,
    reaction_at: ?u16 = null,
    damage_at: ?u16 = null,
    cleanup_at: ?u16 = null,
    draws: battle.systems.Draws = .{},
    amount: ?u32 = null,
    fn command(raw: *anyopaque, actor: u16, request: vm.Command, _: bool) !bool {
        const self: *CallbackHost = @ptrCast(@alignCast(raw));
        if (actor != self.action.owner or request != .effect or request.effect.binding != .self or !std.mem.eql(u8, request.effect.id, "kobold_magic")) return error.InvalidEnemyMagicRequest;
        try self.action.beginEffect();
        return true;
    }
    fn after(raw: *anyopaque, actor: u16) !void {
        const self: *CallbackHost = @ptrCast(@alignCast(raw));
        if (actor != self.action.owner) return;
        const event = self.action.advance(self.binding, &self.runtime.actors[actor], self.runtime.actors[self.action.recipient].position_q12);
        if (event.reaction) {
            if (self.reaction_at != null) return error.DuplicateMagicReaction;
            self.reaction_at = self.update;
            try self.runtime.dispatch(self.action.recipient, self.action.owner, self.recipient_program);
        }
        if (event.damage) {
            if (self.damage_at != null) return error.DuplicateMagicDamage;
            self.damage_at = self.update;
            self.amount = self.binding.damage(111, 1, 2, try self.draws.next());
        }
        if (event.cleanup) {
            if (self.cleanup_at != null) return error.DuplicateMagicCleanup;
            self.cleanup_at = self.update;
        }
    }
};

test "Enemy magic callback drives source body waits graphics and one late variance through shared actors" {
    const parsed = try fixture();
    defer parsed.deinit();
    const data = parsed.value;
    const counters = try battle.counter.load(allocator, @embedFile("../fixtures/counter_actor_library.json"));
    defer counters.deinit();
    var frames: [3][32]magic.Frame = undefined;
    var clips: [3]magic.Clip = undefined;
    for (data.clips, 0..) |clip, i| {
        for (clip.frames, 0..) |frame, j| frames[i][j] = .{ .entry = frame.pose, .updates = frame.updates };
        clips[i] = .{ .id = clip.id, .frames = frames[i][0..clip.frames.len] };
    }
    const art = magic.Art{ .clips = &clips, .anchors = data.impact_anchors };
    try art.validate(64);
    const positions = [_][2][3]i32{
        .{ .{ -200003, 35005, -120001 }, .{ 12285, -8195, 4097 } },
        .{ .{ 100000000, -100000000, 80000000 }, .{ 0, 0, 0 } },
    };
    for (positions) |home| {
        var actors = [_]host.Actor{
            try host.Actor.init(counters.value.animations.find("hero").?, home[0]),
            try host.Actor.init(data.resource, home[1]),
        };
        var context = CallbackHost{ .binding = data.binding(), .recipient_program = data.programs.find("kobold_type_3/magic_recipient").?, .draws = .{ .values = &.{50} } };
        var runtime = host.Runtime{ .actors = &actors, .external = .{ .context = &context, .command = CallbackHost.command, .after_actor = CallbackHost.after } };
        context.runtime = &runtime;
        try runtime.dispatch(1, null, data.programs.find("kobold_type_3/magic_owner").?);
        var first_graphics_at: ?u16 = null;
        var impacts: u8 = 0;
        for (1..251) |update| {
            context.update = @intCast(update);
            try runtime.stepActor(0);
            try runtime.stepActor(1);
            const graphic_frame = context.action.graphics(context.binding, art);
            if (graphic_frame.count > 0 and first_graphics_at == null) first_graphics_at = @intCast(update);
            for (graphic_frame.values[0..graphic_frame.count]) |graphic| {
                if (graphic.kind == .impact) {
                    impacts |= @as(u8, 1) << @intCast(graphic.index);
                    for (home[0], home[1], [_]i32{ -81920, 0, 0 }, graphic.position_q12) |destination, origin, offset, actual| {
                        const delta = destination +% offset -% origin;
                        try std.testing.expectEqual(@divTrunc(delta *% @as(i32, 32), 32), actual);
                    }
                }
                try std.testing.expect(graphic.size > 0);
            }
            if (context.damage_at == null) try std.testing.expectEqual(@as(usize, 0), context.draws.cursor);
            if (context.cleanup_at != null) try std.testing.expectEqual(@as(usize, 0), graphic_frame.count);
        }
        try std.testing.expectEqual(@as(?u16, 62), first_graphics_at);
        try std.testing.expectEqual(@as(?u16, 109), context.reaction_at);
        try std.testing.expectEqual(@as(?u16, 241), context.damage_at);
        try std.testing.expectEqual(@as(?u16, 242), context.cleanup_at);
        try std.testing.expectEqual(@as(usize, 1), context.draws.cursor);
        try std.testing.expectEqual(@as(?u32, 55), context.amount);
        try std.testing.expectEqual(@as(u8, 63), impacts);
        try std.testing.expect(context.action.phase == .complete and actors[1].released);
        try std.testing.expect(actors[0].machine.?.halted and actors[1].machine.?.halted);
        try std.testing.expect(actors[0].highlights == 0 and actors[1].highlights == 0);
    }
}

test "Enemy magic binding rejects unsafe clocks and matches every target rune selector" {
    const parsed = try fixture();
    defer parsed.deinit();
    var binding = parsed.value.binding();
    for (0..256) |rune| for ([_]u15{ 0, 1, 3, 4, 50, 32767 }) |draw| {
        const selected: u8 = switch (rune) {
            1 => 7,
            2, 27 => 1,
            3, 28 => 2,
            4, 29 => 5,
            5, 31 => 4,
            6, 30 => 3,
            7 => 6,
            else => 0,
        };
        const base: i32 = 110 + @divTrunc(55 - @as(i32, draw % 110), 5);
        const expected: u32 = @intCast(if (selected == 1 or selected == 7) @divTrunc(base, 2) else base);
        try std.testing.expectEqual(expected, binding.damage(111, 1, @intCast(rune), draw));
        try std.testing.expectEqual(@as(u32, 1), binding.damage(0, 65535, @intCast(rune), draw));
    };
    binding.effect.flight_updates = 0;
    try std.testing.expectError(error.InvalidEnemyMagicBinding, binding.validate());
    binding = parsed.value.binding();
    binding.effect.projectiles[0].contact_update += 1;
    try std.testing.expectError(error.InvalidEnemyMagicBinding, binding.validate());
    binding = parsed.value.binding();
    binding.target_rune_elements[0] = 8;
    try std.testing.expectError(error.InvalidEnemyMagicBinding, binding.validate());
}

test "Enemy magic actor bundle validates binding and preserves omitted legacy data" {
    const parsed = try host.loadBundle(allocator, @embedFile("../fixtures/enemy_magic_actor_library.json"));
    defer parsed.deinit();
    try std.testing.expectEqualStrings("suikoden-unite-actors/15", parsed.value.schema);
    try std.testing.expectEqualStrings("kobold_type_3", parsed.value.enemy_magic.?.id);
    var legacy = parsed.value;
    legacy.schema = "suikoden-unite-actors/14";
    try std.testing.expectError(error.InvalidUniteBindings, legacy.validate());
    legacy.enemy_magic = null;
    try legacy.validate();
    const bytes = try std.json.Stringify.valueAlloc(allocator, legacy, .{});
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"enemy_magic\"") == null);
}

test "Enemy magic live battle callback preserves protected lethal and exhausted-contact ownership" {
    const parsed = try battle.load(allocator, @embedFile("../fixtures/blacksmith_battle.json"));
    defer parsed.deinit();
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    const actors = try host.loadBundle(allocator, @embedFile("../fixtures/enemy_magic_actor_library.json"));
    defer actors.deinit();
    const source_world = try std.json.parseFromSlice(struct { enemies: []const battle.Profile }, allocator, h.world_battle.json_c, .{ .ignore_unknown_fields = true });
    defer source_world.deinit();
    const profile = for (source_world.value.enemies) |enemy| {
        if (std.mem.eql(u8, enemy.id, "kobold_type_3")) break enemy;
    } else return error.MissingEnemyMagicProfile;
    var enemies = [_]battle.Profile{profile};
    enemies[0].stats.magic = 200;
    var encounters = [_]battle.Encounter{parsed.value.encounters[0]};
    encounters[0].enemies = &.{"kobold_type_3"};
    encounters[0].positions = encounters[0].positions[0..1];
    encounters[0].enemy_rows = &.{.front};
    encounters[0].source_slots = &.{0};
    var content = parsed.value;
    content.presentation_ready = false;
    content.enemies = &enemies;
    content.encounters = &encounters;
    for (0..4) |scenario| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(content, items.value, &members, 17);
        try combat.attachUniteActors(&actors.value);
        const owner = combat.partyCount();
        combat.phase = .resolving;
        combat.acted = @splat(true);
        for (combat.actions[0..combat.partyCount()]) |*action| action.* = .defend;
        combat.progress.party.at(0).inventory.slots = @splat(null);
        combat.progress.party.at(0).max_hp = 5000;
        combat.progress.party.at(0).hp = if (scenario >= 2) 1 else 5000;
        if (scenario == 3) combat.progress.party.at(0).inventory.slots[0] = .{ .id = combat.rules.automatic_revival.?.id, .uses = 0 };
        if (scenario == 1) combat.actor_conditions[0].protection_rounds = 2;
        combat.coordinator = .{ .stage = .await_order, .current_actor = owner, .completed = false, .cached = .round_end, .elapsed = 0 };
        const hp = combat.hp(0);
        const rune: u8 = combat.runeByteFor(0) orelse 0;
        const computed = actors.value.enemy_magic.?.damage(combat.stats(owner).magic, combat.stats(0).magic, rune, 50);
        try combat.beginEnemyMagic(owner, 0);
        var draws = battle.systems.Draws{};
        var reached_damage = false;
        for (0..300) |_| {
            const action = combat.unite_vm.enemy_magic_actions[owner].?;
            if (action.phase == .running and action.update == 179) {
                reached_damage = true;
                break;
            }
            try combat.tickReplay(.{}, &draws);
            try std.testing.expectEqual(hp, combat.hp(0));
            try std.testing.expectEqual(@as(usize, 0), draws.cursor);
            try std.testing.expect(combat.active != null and combat.phase == .resolving);
        }
        try std.testing.expect(reached_damage);
        const before = combat;
        try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &draws));
        try std.testing.expectEqual(before.camera_ticks, combat.camera_ticks);
        try std.testing.expectEqual(before.action_ticks, combat.action_ticks);
        try std.testing.expectEqualDeep(before.coordinator, combat.coordinator);
        try std.testing.expectEqualDeep(before.unite_vm, combat.unite_vm);
        try std.testing.expectEqual(hp, combat.hp(0));
        try std.testing.expectEqual(@as(usize, 0), draws.cursor);
        draws.values = &.{50};
        try combat.tickReplay(.{}, &draws);
        const amount: u32 = if (scenario == 1) 0 else computed;
        try std.testing.expectEqual(@as(u16, @intCast(@as(u32, hp) -| amount)), combat.hp(0));
        try std.testing.expectEqual(@as(usize, 1), draws.cursor);
        try std.testing.expectEqual(@as(?u32, amount), combat.unite_vm.enemy_magic_actions[owner].?.amount);
        for (0..50) |_| {
            if (!combat.unite_vm.hasEnemyMagic()) break;
            try combat.tickReplay(.{}, &draws);
        }
        try std.testing.expect(!combat.unite_vm.hasEnemyMagic() and combat.active == null);
        try std.testing.expect(combat.unite_vm.scripted_actors[owner] == null and combat.unite_vm.scripted_actors[0] == null);
        try std.testing.expect(combat.coordinator.?.completed);
        try std.testing.expectEqual(@as(i32, 30), combat.coordinator.?.remaining);
        try std.testing.expectEqual(@as(usize, 1), draws.cursor);
        if (scenario == 2) try std.testing.expect(combat.progress.party.at(0).status == .unconscious);
        if (scenario == 3) {
            combat.coordinator.?.stage = .await_order;
            for (0..200) |_| {
                if (!combat.hasPendingRevival()) break;
                try combat.tickReplay(.{}, &draws);
            }
            try std.testing.expect(!combat.hasPendingRevival());
            try std.testing.expectEqual(@as(u16, 2500), combat.hp(0));
            try std.testing.expect(combat.progress.party.at(0).inventory.slots[0] == null);
            try std.testing.expect(combat.progress.party.at(0).status == .healthy);
            try std.testing.expectEqual(@as(usize, 1), draws.cursor);
        }
    }
}

test "Enemy magic normal AI and shared native frame use source C formation and art" {
    const world = try h.world_battle.load(allocator, @embedFile("../fixtures/world_c_actor_library.json"));
    defer world.deinit();
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    const actors = try host.loadBundle(allocator, @embedFile("../fixtures/cover_actor_library.json"));
    defer actors.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(world.value.actor_content.?, items.value, &members, 17);
    combat.encounter = 1;
    combat.startEncounter();
    try combat.attachUniteActors(&actors.value);
    try combat.attachSpellScenes(&scenes.value);
    const owner = combat.partyCount() + 3;
    try std.testing.expectEqualStrings("kobold_type_3", combat.enemy(3).id);
    combat.phase = .resolving;
    combat.acted = @splat(true);
    for (combat.actions[0..combat.partyCount()]) |*action| action.* = .defend;
    combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .completed = false, .cached = .{ .actor = owner }, .elapsed = 0 };
    var draws = battle.systems.Draws{ .values = &.{ 51, 16712, 50 } };
    combat.replay_draws = &draws;
    combat.sourceEnemyDecision(owner);
    combat.replay_draws = null;
    try std.testing.expectEqual(@as(usize, 2), draws.cursor);
    try std.testing.expect(combat.active.?.kind == .enemy_magic and combat.coordinator.?.stage == .await_order);
    const art = scenes.value.enemy_magic_art.?;
    var checked_frames: usize = 0;
    var contacts: usize = 0;
    var previous_update: u16 = 0;
    for (0..300) |_| {
        if (!combat.unite_vm.hasEnemyMagic()) break;
        try combat.tickReplay(.{}, &draws);
        const action = combat.unite_vm.enemy_magic_actions[owner] orelse break;
        const graphics = action.graphics(actors.value.enemy_magic.?, art);
        const frame = combat.spellSceneFrame();
        try std.testing.expectEqual(graphics.count, frame.count);
        const block = battle.layout.currentCamera(combat);
        var without_pulse = combat;
        without_pulse.enemy_magic_pulse = null;
        var expected_camera = battle.layout.currentCamera(without_pulse);
        if (combat.enemy_magic_pulse) |pulse| if (combat.camera_ticks -% pulse.issued_at == 1) {
            expected_camera.focus[2] += 5;
        };
        try std.testing.expectEqualDeep(expected_camera, block);
        const scene_scale = @divTrunc(block.scale[0] << 10, block.translation[2]);
        for (graphics.values[0..graphics.count], frame.commands[0..frame.count]) |graphic, command| {
            try std.testing.expectEqual(@as(?u16, graphic.entry), command.texture);
            const entry = scenes.value.entries[graphic.entry];
            var world_point = action.root;
            for (graphic.position_q12, 0..) |local, axis| world_point[axis] += @as(i16, @truncate(local >> 12));
            var projected = battle.drops.project(block, world_point);
            if (graphic.kind == .impact) {
                const pose = combat.unite_vm.pose(0) orelse battle.layout.actorLayout(combat, 0).source_pose.?;
                projected.x += @floatFromInt(art.center(combat.progress.party.at(0).id, pose).?);
            }
            const size: f32 = @floatFromInt(@divTrunc(scene_scale * graphic.size, 4096));
            // The zero-angle packet projects raw wm/hm; texture samples include the last texel.
            const left = @as(f32, @floatFromInt(entry.dx)) * size / 4096;
            const top = @as(f32, @floatFromInt(entry.dy)) * size / 4096;
            try std.testing.expectApproxEqAbs(projected.x + left, command.vertices[0].x, 1.0);
            try std.testing.expectApproxEqAbs(projected.y + top, command.vertices[0].y, 1.0);
            try std.testing.expect(command.depth >= 5 and command.depth <= 379 and command.blend == .additive);
        }
        if (action.phase == .running and previous_update != action.update) {
            previous_update = action.update;
            for (actors.value.enemy_magic.?.effect.projectiles) |projectile| if (action.update == projectile.contact_update) {
                contacts += 1;
                try std.testing.expectEqual(@as(i32, 20480), combat.enemy_magic_pulse.?.delta_q12);
                try std.testing.expectEqual(combat.camera_ticks, combat.enemy_magic_pulse.?.issued_at);
                try std.testing.expect(combat.actor_camera == null);
            };
        }
        checked_frames += 1;
    }
    try std.testing.expect(checked_frames > 230 and !combat.unite_vm.hasEnemyMagic());
    try std.testing.expectEqual(@as(usize, 6), contacts);
    try std.testing.expectEqual(@as(usize, 3), draws.cursor);
    try std.testing.expect(combat.enemy_magic_damage[0] != null);
}

test "Source Kobold scans wait for a pending front knockout before skipping" {
    const world = try h.world_battle.load(allocator, @embedFile("../fixtures/world_c_actor_library.json"));
    defer world.deinit();
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    const actors = try host.loadBundle(allocator, @embedFile("../fixtures/cover_actor_library.json"));
    defer actors.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    for ([_]struct { encounter: usize, enemy: usize }{
        .{ .encounter = 0, .enemy = 0 }, // ordinary melee
        .{ .encounter = 1, .enemy = 3 }, // magic-capable
        .{ .encounter = 2, .enemy = 0 }, // source projectile
    }) |scenario| for ([_]bool{ false, true }) |active_effect| for ([_]bool{ false, true }) |restored| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(world.value.actor_content.?, items.value, &members, 17);
        combat.encounter = scenario.encounter;
        combat.startEncounter();
        try combat.attachUniteActors(&actors.value);
        try combat.attachSpellScenes(&scenes.value);
        combat.phase = .resolving;
        const owner = combat.partyCount() + scenario.enemy;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner };
        combat.acted = @splat(true);
        for (combat.progress.party.items()) |member| {
            member.hp = 0;
            member.status = .unconscious;
        }
        combat.party_knockouts[0].pending = true;
        if (active_effect) combat.active = .{ .actor = 0, .target = 0, .kind = .defend };
        var draws = battle.systems.Draws{ .values = &.{ 51, 0, 0 } };
        combat.replay_draws = &draws;
        combat.sourceEnemyDecision(owner);
        try std.testing.expectEqual(if (active_effect) @as(?usize, null) else owner, combat.pending_enemy_actor);
        try std.testing.expect(!combat.acted[owner]);
        try std.testing.expectEqual(@as(usize, 0), draws.cursor);
        combat.active = null;
        combat.party_knockouts[0].pending = false;
        if (restored) {
            combat.progress.party.at(0).hp = 100;
            combat.progress.party.at(0).status = .healthy;
        }
        combat.sourceEnemyDecision(owner);
        try std.testing.expect(combat.pending_enemy_actor == null and combat.acted[owner]);
        try std.testing.expectEqual(.select, combat.coordinator.?.stage);
        if (restored) {
            try std.testing.expect(combat.replay_unsupported == null and combat.active != null);
            try std.testing.expectEqual(@as(usize, if (scenario.encounter == 1) 3 else 2), draws.cursor);
        } else try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    };
}

test "Enemy magic AI threshold retains selected target and waits for another party member revival without new draws" {
    const world = try h.world_battle.load(allocator, @embedFile("../fixtures/world_c_actor_library.json"));
    defer world.deinit();
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    const actors = try host.loadBundle(allocator, @embedFile("../fixtures/cover_actor_library.json"));
    defer actors.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    for (0..3) |scenario| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(world.value.actor_content.?, items.value, &members, 17);
        combat.encounter = 1;
        combat.startEncounter();
        try combat.attachUniteActors(&actors.value);
        try combat.attachSpellScenes(&scenes.value);
        const owner = combat.partyCount() + 3;
        combat.phase = .resolving;
        combat.camera_ticks = 300;
        combat.acted = @splat(true);
        for (combat.actions[0..combat.partyCount()]) |*action| action.* = .defend;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .completed = false, .cached = .{ .actor = owner }, .elapsed = 0 };
        if (scenario == 2) {
            combat.progress.party.at(1).hp = 0;
            combat.progress.party.at(1).inventory.slots = @splat(null);
            combat.progress.party.at(1).inventory.slots[0] = .{ .id = combat.rules.automatic_revival.?.id, .uses = 0 };
            combat.markPartyKnockout(1);
            try std.testing.expect(!combat.commitPartyKnockout(1) and combat.coordinatorLocked(1));
        }
        const values = [_]u15{ 51, if (scenario == 0) 16711 else 16712, 0 };
        var draws = battle.systems.Draws{ .values = &values };
        combat.replay_draws = &draws;
        defer combat.replay_draws = null;
        combat.sourceEnemyDecision(owner);
        try std.testing.expect(combat.replay_unsupported == null and !combat.replay_exhausted);
        if (scenario == 0) {
            try std.testing.expectEqual(@as(usize, 3), draws.cursor);
            try std.testing.expect(!combat.unite_vm.hasEnemyMagic() and combat.active.?.kind == .attack);
            const melee = combat.unite_vm.counter_actions[3].?;
            try std.testing.expect(melee.kind == .ordinary_hit and melee.attacker == owner and melee.defender == 0);
        } else if (scenario == 1) {
            try std.testing.expectEqual(@as(usize, 2), draws.cursor);
            try std.testing.expect(combat.active.?.kind == .enemy_magic and combat.active.?.target == 0);
        } else {
            try std.testing.expect(combat.active == null and combat.pending_enemy_actor == owner and !combat.acted[owner]);
            try std.testing.expectEqual(@as(u8, 0), combat.enemy_branch_selection.?.recipient);
            for (0..combat.rules.automatic_revival.?.release_delay) |_| {
                combat.sourceEnemyDecision(owner);
                try std.testing.expectEqual(@as(usize, 2), draws.cursor);
                try std.testing.expect(combat.active == null);
                combat.camera_ticks += 1;
                combat.advanceRevivals();
            }
            try std.testing.expect(!combat.hasPendingRevival() and combat.hp(1) > 0);
            combat.sourceEnemyDecision(owner);
            try std.testing.expectEqual(@as(usize, 2), draws.cursor);
            try std.testing.expect(combat.pending_enemy_actor == null and combat.enemy_branch_selection == null and combat.acted[owner]);
            try std.testing.expect(combat.active.?.kind == .enemy_magic and combat.active.?.target == 0);
        }
    }
}

test "Enemy magic retains a target knocked out during its wait" {
    const world = try h.world_battle.load(allocator, @embedFile("../fixtures/world_c_actor_library.json"));
    defer world.deinit();
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    const actors = try host.loadBundle(allocator, @embedFile("../fixtures/cover_actor_library.json"));
    defer actors.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(world.value.actor_content.?, items.value, &members, 17);
    combat.encounter = 1;
    combat.startEncounter();
    try combat.attachUniteActors(&actors.value);
    try combat.attachSpellScenes(&scenes.value);
    const owner = combat.partyCount() + 3;
    combat.phase = .resolving;
    combat.camera_ticks = 300;
    combat.acted = @splat(true);
    for (combat.actions[0..combat.partyCount()]) |*action| action.* = .defend;
    combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .completed = false, .cached = .{ .actor = owner }, .elapsed = 0 };
    combat.progress.party.at(1).hp = 0;
    combat.progress.party.at(1).inventory.slots = @splat(null);
    combat.progress.party.at(1).inventory.slots[0] = .{ .id = combat.rules.automatic_revival.?.id, .uses = 0 };
    combat.markPartyKnockout(1);
    try std.testing.expect(!combat.commitPartyKnockout(1));
    var draws = battle.systems.Draws{ .values = &.{ 51, 16712, 50 } };
    combat.replay_draws = &draws;
    combat.sourceEnemyDecision(owner);
    try std.testing.expectEqual(@as(u8, 0), combat.enemy_branch_selection.?.recipient);
    combat.progress.party.at(0).hp = 0;
    combat.progress.party.at(0).inventory.slots = @splat(null);
    combat.markPartyKnockout(0);
    combat.sourceEnemyDecision(owner);
    try std.testing.expect(combat.active == null and combat.enemy_branch_selection.?.recipient == 0 and draws.cursor == 2);
    try std.testing.expect(combat.commitPartyKnockout(0));
    var unselected = combat;
    unselected.enemy_branch_selection = null;
    try std.testing.expectError(error.InvalidActorBinding, unselected.beginEnemyMagic(owner, 0));
    // A second Buddha cannot be consumed by damage to an already inactive actor.
    combat.progress.party.at(0).inventory.slots[0] = .{ .id = combat.rules.automatic_revival.?.id, .uses = 0 };
    for (0..combat.rules.automatic_revival.?.release_delay) |_| {
        combat.sourceEnemyDecision(owner);
        try std.testing.expect(combat.active == null and draws.cursor == 2);
        combat.camera_ticks += 1;
        combat.advanceRevivals();
    }
    combat.front_projectiles[0] = .{ .actor = owner, .target = 0 };
    try std.testing.expect(combat.coordinatorLocked(0));
    combat.sourceEnemyDecision(owner);
    combat.front_projectiles[0] = null;
    combat.replay_draws = null;
    try std.testing.expect(combat.replay_unsupported == null and combat.active.?.target == 0);
    try std.testing.expectEqual(@as(usize, 2), draws.cursor);
    var saw_reaction = false;
    for (0..300) |_| {
        if (!combat.unite_vm.hasEnemyMagic()) break;
        try combat.tickReplay(.{}, &draws);
        if (combat.unite_vm.scripted_actors[0]) |binding| if (binding.family == .enemy_magic and combat.uniteVmPose(0) != null) {
            saw_reaction = true;
            try std.testing.expectEqual(combat.unite_vm.pose(0), battle.layout.actorLayout(combat, 0).source_pose);
        };
    }
    try std.testing.expect(saw_reaction and !combat.unite_vm.hasEnemyMagic());
    try std.testing.expectEqual(@as(usize, 3), draws.cursor);
    try std.testing.expect(combat.enemy_magic_damage[0] != null and combat.hp(0) == 0);
    try std.testing.expect(!combat.party_knockouts[0].pending and combat.party_knockouts[0].revival == null);
    try std.testing.expect(combat.progress.party.at(0).inventory.slots[0] != null and combat.progress.party.at(0).status == .unconscious);
    try std.testing.expectEqual(combat.partyProfile(0).revival_art.?.down.frames[0].source_pose, battle.layout.actorLayout(combat, 0).source_pose);
}

test "Enemy magic waiting for an active effect lets it finish" {
    const world = try h.world_battle.load(allocator, @embedFile("../fixtures/world_c_actor_library.json"));
    defer world.deinit();
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    const actors = try host.loadBundle(allocator, @embedFile("../fixtures/cover_actor_library.json"));
    defer actors.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(world.value.actor_content.?, items.value, &members, 17);
    combat.encounter = 1;
    combat.startEncounter();
    try combat.attachUniteActors(&actors.value);
    try combat.attachSpellScenes(&scenes.value);
    const owner = combat.partyCount() + 3;
    combat.phase = .resolving;
    combat.camera_ticks = 300;
    combat.acted = @splat(true);
    for (combat.actions[0..combat.partyCount()]) |*action| action.* = .defend;
    combat.active = .{ .actor = 1, .target = 1, .kind = .defend };
    combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .completed = false, .cached = .{ .actor = owner }, .elapsed = 0 };
    var draws = battle.systems.Draws{ .values = &.{ 51, 16712, 50 } };
    for (0..100) |_| {
        try combat.tickReplay(.{}, &draws);
        if (combat.active == null) break;
        try std.testing.expect(combat.pending_enemy_actor == null and combat.enemy_branch_selection.?.recipient == 0);
    }
    try std.testing.expect(combat.active == null and draws.cursor == 2);
    try combat.tickReplay(.{}, &draws);
    try std.testing.expect(combat.active.?.kind == .enemy_magic and combat.active.?.target == 0 and draws.cursor == 2);
}

test "Enemy magic cancels a retained decision when its owner is knocked out" {
    const world = try h.world_battle.load(allocator, @embedFile("../fixtures/world_c_actor_library.json"));
    defer world.deinit();
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    const actors = try host.loadBundle(allocator, @embedFile("../fixtures/cover_actor_library.json"));
    defer actors.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer scenes.deinit();

    for ([_]bool{ false, true }) |active_effect| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(world.value.actor_content.?, items.value, &members, 17);
        combat.encounter = 1;
        combat.startEncounter();
        try combat.attachUniteActors(&actors.value);
        try combat.attachSpellScenes(&scenes.value);
        const owner = combat.partyCount() + 3;
        combat.phase = .resolving;
        combat.camera_ticks = 300;
        combat.acted = @splat(true);
        combat.acted[owner] = false;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner };
        if (active_effect) {
            combat.active = .{ .actor = 1, .target = 1, .kind = .defend };
        } else {
            members[1].hp = 0;
            members[1].inventory.slots = @splat(null);
            members[1].inventory.slots[0] = .{ .id = combat.rules.automatic_revival.?.id, .uses = 0 };
            combat.markPartyKnockout(1);
            try std.testing.expect(!combat.commitPartyKnockout(1));
        }

        var draws = battle.systems.Draws{ .values = &.{ 51, 16712 } };
        try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(@as(u8, @intCast(owner)), combat.enemy_branch_selection.?.owner);
        try std.testing.expectEqual(if (active_effect) @as(?usize, null) else owner, combat.pending_enemy_actor);
        try std.testing.expectEqual(@as(usize, 2), draws.cursor);

        combat.enemy_hp[owner - combat.partyCount()] = 0;
        try combat.tickReplay(.{}, &draws);
        try std.testing.expect(combat.pending_enemy_actor == null and combat.enemy_branch_selection == null);
        try std.testing.expect(combat.acted[owner] and combat.coordinator.?.completed);
        try std.testing.expectEqual(.select, combat.coordinator.?.stage);
        try std.testing.expectEqual(@as(usize, 2), draws.cursor);
        try std.testing.expect(!combat.unite_vm.hasEnemyMagic());
        if (active_effect) {
            try std.testing.expect(combat.active.?.kind == .defend);
        } else {
            try std.testing.expect(combat.party_knockouts[1].revival != null);
        }
    }
}

test "Enemy magic mixed source formations finish queued rounds with every mage and stable resources" {
    const world = try h.world_battle.load(allocator, @embedFile("../fixtures/world_c_actor_library.json"));
    defer world.deinit();
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    const actors = try host.loadBundle(allocator, @embedFile("../fixtures/cover_actor_library.json"));
    defer actors.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    const rules_host = try h.hostFixture();
    defer rules_host.deinit();
    const values = try allocator.alloc(u15, 32768);
    defer allocator.free(values);
    @memset(values, 32767);
    for ([_][]const u8{ "world_c_encounter_3", "world_c_encounter_6" }) |encounter_id| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(world.value.actor_content.?, items.value, &members, 17);
        combat.encounter = for (combat.content.encounters, 0..) |encounter, index| {
            if (std.mem.eql(u8, encounter.id, encounter_id)) break index;
        } else return error.MissingMagicEncounter;
        combat.startEncounter();
        combat.integration = .{ .host = rules_host };
        try combat.attachUniteActors(&actors.value);
        try combat.attachSpellScenes(&scenes.value);
        for (combat.progress.party.items()) |member| {
            member.max_hp = 5000;
            member.hp = 5000;
        }
        var charges: [6][4]u16 = undefined;
        for (combat.progress.party.items(), 0..) |member, index| charges[index] = member.rune_charges;
        combat.camera_ticks = 300;
        var seen: u16 = 0;
        var draws = battle.systems.Draws{ .values = values };
        for (0..2) |_| {
            combat.actions = @splat(.defend);
            combat.acted = @splat(false);
            combat.phase = .resolving;
            combat.round_start_pending = combat.round > 1;
            for (0..5000) |update| {
                if (combat.phase != .resolving) break;
                combat.tickReplay(.{}, &draws) catch |err| {
                    std.debug.print("C magic {s} failed on update{d}: {s}\n", .{ encounter_id, update, @errorName(err) });
                    return err;
                };
                for (combat.unite_vm.enemy_magic_actions, 0..) |action, owner| if (action != null) {
                    seen |= @as(u16, 1) << @intCast(owner);
                };
            }
            try std.testing.expect(combat.phase == .battle_menu);
            try std.testing.expect(!combat.unite_vm.hasActors() and combat.active == null and combat.enemy_branch_selection == null);
            for (combat.progress.party.items(), 0..) |member, index| try std.testing.expectEqualDeep(charges[index], member.rune_charges);
        }
        var expected: u16 = 0;
        for (0..combat.enemyCount()) |enemy| if (std.mem.eql(u8, combat.enemy(enemy).id, "kobold_type_3")) {
            expected |= @as(u16, 1) << @intCast(combat.partyCount() + enemy);
        };
        try std.testing.expectEqual(expected, seen);
        try std.testing.expect(combat.hp(0) < 5000 and combat.hp(0) > 0);
    }
}

test "Enemy magic status rounds retain all six recipients through protected contact and return" {
    const world = try h.world_battle.load(allocator, @embedFile("../fixtures/world_c_actor_library.json"));
    defer world.deinit();
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    const actors = try host.loadBundle(allocator, @embedFile("../fixtures/cover_actor_library.json"));
    defer actors.deinit();
    const scenes = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer scenes.deinit();
    const rules_host = try h.hostFixture();
    defer rules_host.deinit();
    for (0..24) |scenario| {
        const target = scenario / 4;
        const mode = scenario % 4;
        const sleeping = mode == 1 or mode == 3;
        const protected = mode >= 2;
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(world.value.actor_content.?, items.value, &members, 17);
        combat.encounter = 1;
        combat.startEncounter();
        combat.integration = .{ .host = rules_host };
        try combat.attachUniteActors(&actors.value);
        try combat.attachSpellScenes(&scenes.value);
        combat.phase = .resolving;
        combat.acted = @splat(true);
        combat.actions = @splat(.defend);
        for (combat.progress.party.items()) |member| member.rune = null;
        const owner = combat.partyCount() + 3;
        try std.testing.expectEqualStrings("kobold_type_3", combat.enemy(3).id);
        combat.acted[owner] = false;
        combat.coordinator = .{ .stage = .dispatch, .current_actor = owner, .cached = .{ .actor = owner } };
        for (combat.progress.party.items(), 0..) |member, index| {
            member.max_hp = 5000;
            member.hp = if (index == target) 5000 else 0;
            member.status = if (index != target) .unconscious else if (mode == 3) .poisoned else .healthy;
            member.inventory.slots = @splat(null);
        }
        combat.promoteRearMembers();
        try std.testing.expectEqual(battle.Row.front, combat.partyRow(target));
        combat.actor_conditions[target].sleep_turns = @intFromBool(sleeping);
        combat.actor_conditions[target].protection_rounds = if (protected) 2 else 0;
        const computed = actors.value.enemy_magic.?.damage(combat.stats(owner).magic, combat.stats(target).magic, 0, 50);
        var draws = battle.systems.Draws{ .values = &.{ 51, 16712, 50 } };
        var contact = false;
        var rollback = false;
        var frames: usize = 0;
        for (0..600) |_| {
            if (combat.unite_vm.enemy_magic_actions[owner]) |action| {
                try std.testing.expectEqual(@as(u8, @intCast(target)), action.recipient);
                if (!rollback and action.phase == .running and action.update == 179) {
                    const before = combat;
                    const before_members = members;
                    var short = draws;
                    short.values = short.values[0..short.cursor];
                    try std.testing.expectError(error.RandomInputExhausted, combat.tickReplay(.{}, &short));
                    try std.testing.expectEqualDeep(before_members, members);
                    try std.testing.expectEqualDeep(before.unite_vm, combat.unite_vm);
                    try std.testing.expectEqualDeep(before.coordinator, combat.coordinator);
                    try std.testing.expectEqualDeep(before.enemy_magic_damage, combat.enemy_magic_damage);
                    try std.testing.expectEqualDeep(before.actor_conditions, combat.actor_conditions);
                    try std.testing.expectEqual(before.camera_ticks, combat.camera_ticks);
                    try std.testing.expectEqual(draws.cursor, short.cursor);
                    rollback = true;
                }
            }
            try combat.tickReplay(.{}, &draws);
            if (combat.spellSceneFrame().count > 0) frames += 1;
            if (!contact and draws.cursor == 3) {
                contact = true;
                const amount: u32 = if (protected) 0 else computed;
                try std.testing.expectEqual(@as(u16, @intCast(5000 -| amount)), combat.hp(target));
                try std.testing.expectEqual(amount, combat.enemy_magic_damage[target].?.amount);
                for (combat.enemy_magic_damage, 0..) |notice, index| if (index != target) try std.testing.expect(notice == null);
            }
            try std.testing.expectEqual(@as(u8, @intFromBool(sleeping)), combat.actor_conditions[target].sleep_turns);
            if (combat.phase != .resolving) break;
        }
        try std.testing.expect(contact and rollback and frames > 100);
        try std.testing.expectEqual(.battle_menu, combat.phase);
        try std.testing.expectEqual(@as(u32, 2), combat.round);
        try std.testing.expectEqual(@as(usize, 3), draws.cursor);
        try std.testing.expectEqual(@as(u8, if (protected) 1 else 0), combat.actor_conditions[target].protection_rounds);
        try std.testing.expectEqual(if (mode == 3) h.field.game_state.Status.poisoned else .healthy, members[target].status);
        try std.testing.expect(!combat.unite_vm.hasActors() and combat.active == null);
    }
}
