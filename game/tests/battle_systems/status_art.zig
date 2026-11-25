const std = @import("std");
const h = @import("helpers.zig");
const battle = h.battle;
const allocator = h.allocator;

fn load() !std.json.Parsed(battle.spell_scene.Packet) {
    return battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
}

fn allStatuses(state: *battle.State) void {
    for (state.progress.party, 0..) |*member, index| {
        member.status = .poisoned;
        member.balloons = 3;
        state.asleep[index] = 1;
        state.accuracy_reduced[index] = true;
        state.rune_blocked[index] = true;
        state.unbalanced[index] = 2;
    }
}

test "Status art schema41 validates clips anchors and legacy omission" {
    const parsed = try load();
    defer parsed.deinit();
    const packet = parsed.value;
    try std.testing.expectEqual(@as(usize, 8), packet.status_icons.len);
    try std.testing.expectEqual(@as(usize, 78), packet.status_anchors.len);
    var bad = packet;
    bad.schema = "suikoden-spell-scenes/40";
    try std.testing.expectError(error.InvalidSpellScenes, bad.validate(4096, 4096));
    bad.status_icons = &.{};
    bad.status_anchors = &.{};
    bad.enemy_magic_art = null;
    bad.needle_burst = &.{};
    const reactions = try allocator.dupe(battle.spell_scene.UniteReaction, packet.unite_reactions);
    defer allocator.free(reactions);
    for (reactions) |*reaction| {
        reaction.palette_cycle = null;
        if (reaction.record == 27 or reaction.record == 30) reaction.* = .{ .record = reaction.record, .variant = reaction.variant, .duration = reaction.duration, .blocker = "legacy", .poses = &.{}, .white = &.{}, .offsets = &.{}, .motions = &.{}, .impacts = &.{} };
    }
    bad.unite_reactions = reactions;
    const hurt = try allocator.dupe(battle.spell_scene.HurtPose, packet.hurt_poses);
    defer allocator.free(hurt);
    for (hurt) |*pose| pose.idle_flash = null;
    bad.hurt_poses = hurt;
    try bad.validate(4096, 4096);
    const bytes = try std.json.Stringify.valueAlloc(allocator, bad, .{});
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "status_icons") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "status_anchors") == null);
    var icons: [8]battle.spell_scene.StatusIcon = undefined;
    @memcpy(&icons, packet.status_icons);
    icons[1].status = icons[0].status;
    bad = packet;
    bad.status_icons = &icons;
    try std.testing.expectError(error.InvalidSpellScenes, bad.validate(4096, 4096));
    var anchors: [78]battle.spell_scene.StatusAnchors = undefined;
    @memcpy(&anchors, packet.status_anchors);
    anchors[1].id = anchors[0].id;
    bad = packet;
    bad.status_anchors = &anchors;
    try std.testing.expectError(error.InvalidSpellScenes, bad.validate(4096, 4096));
    @memcpy(&anchors, packet.status_anchors);
    anchors[0].idle_pose = @intCast(anchors[0].offsets.len);
    try std.testing.expectError(error.InvalidSpellScenes, bad.validate(4096, 4096));
    const Frame = @TypeOf(packet.status_icons[0].frames[0]);
    var frames = [_]Frame{.{ .entry = 0, .ticks = 0 }};
    @memcpy(&icons, packet.status_icons);
    icons[0].frames = &frames;
    bad = packet;
    bad.status_icons = &icons;
    try std.testing.expectError(error.InvalidSpellScenes, bad.validate(4096, 4096));
}

test "Status art all48 symbols follow independent source duration counters without action or RNG costs" {
    const parsed = try load();
    defer parsed.deinit();
    var fixture = try h.Fixture.open(null);
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    try combat.attachSpellScenes(&parsed.value);
    combat.phase = .command;
    allStatuses(&combat);
    const before = members;
    const hp = combat.enemy_hp;
    const durations = [_][]const u16{
        &.{ 6, 6, 29, 6, 6, 6, 6, 29, 6, 6, 6, 6, 29, 6, 6, 6, 29, 6, 6 },
        &.{ 8, 8, 8, 8 },
        &.{ 8, 8, 8, 8 },
        &.{ 8, 8, 8, 8 },
        &.{1},
        &.{ 6, 6, 6, 6 },
        &.{ 3, 1, 1 },
        &.{ 3, 1, 1 },
    };
    var frames: [8]usize = @splat(0);
    var remaining: [8]u16 = undefined;
    for (&remaining, durations) |*value, ticks| value.* = ticks[0];
    var draws = h.rules.Draws{ .values = &.{} };
    for (0..300) |_| {
        try combat.tickReplay(.{}, &draws);
        try std.testing.expect(!combat.hasSourceEffect() and combat.hasStatusIcons());
        const scene = combat.spellSceneFrame();
        try std.testing.expectEqual(@as(usize, 48), scene.count);
        for (0..8) |status| {
            remaining[status] -= 1;
            if (remaining[status] == 0) {
                frames[status] = (frames[status] + 1) % durations[status].len;
                remaining[status] = durations[status][frames[status]];
            }
            for (0..6) |actor| {
                const command = scene.commands[actor * 8 + status];
                try std.testing.expectEqual(parsed.value.status_icons[status].frames[frames[status]].entry, command.texture.?);
                try std.testing.expectEqual(battle.spell_scene.Blend.@"opaque", command.blend);
                try std.testing.expectEqualDeep([3]u8{ 128, 128, 128 }, command.tint);
            }
        }
    }
    try std.testing.expectEqualDeep(before, members);
    try std.testing.expectEqualDeep(hp, combat.enemy_hp);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    try std.testing.expect(combat.active == null and combat.coordinator == null);
}

test "Status art keeps independent acquisition phases and removes cured or departed symbols" {
    const parsed = try load();
    defer parsed.deinit();
    const host = try h.hostFixture();
    defer host.deinit();
    var fixture = try h.Fixture.open(null);
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.integration = .{ .host = host };
    try combat.attachSpellScenes(&parsed.value);
    combat.phase = .command;
    var draws = h.rules.Draws{ .values = &.{} };
    try std.testing.expect(combat.inflictStatus(1, .poison));
    for (0..12) |_| try combat.tickReplay(.{}, &draws);
    const original = combat.status_icons[1].started_at[0];
    try std.testing.expect(combat.inflictStatus(1, .sleep));
    try std.testing.expectEqual(original, combat.status_icons[1].started_at[0]);
    try std.testing.expectEqual(combat.camera_ticks, combat.status_icons[1].started_at[5]);
    const started = combat.status_icons[1];
    try std.testing.expect(!combat.inflictStatus(1, .sleep));
    try std.testing.expectEqualDeep(started, combat.status_icons[1]);
    try std.testing.expectEqual(@as(usize, 2), combat.spellSceneFrame().count);
    combat.runes[0] = combat.content.systems.?.runeIndex("water");
    combat.progress.party[0].rune_charges = .{ 9, 9, 9, 9 };
    const spell = for (combat.content.systems.?.spells, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name, "Drops of Kindness")) break index;
    } else unreachable;
    var effect = battle.Effect{ .actor = 0, .target = 1, .kind = .cast, .spell = spell };
    combat.applySpell(&effect);
    try combat.tickReplay(.{}, &draws);
    try std.testing.expectEqual(@as(usize, 0), combat.spellSceneFrame().count);
    try std.testing.expectEqual(@as(u8, 0), combat.status_icons[1].active);
    try std.testing.expect(combat.inflictStatus(1, .poison));
    try std.testing.expect(combat.status_icons[1].started_at[0] > original);
    combat.departed[1] = true;
    try std.testing.expect(!combat.hasStatusIcons());
    try std.testing.expectEqual(@as(usize, 0), combat.spellSceneFrame().count);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    combat.startEncounter();
    try std.testing.expectEqual(@as(u32, 0), combat.status_icons[1].started_at[0]);
}

test "Balloon departure uses source motion and keeps symbols attached in both views" {
    const parsed = try load();
    defer parsed.deinit();
    const world = try battle.world_art.load(allocator, @embedFile("../fixtures/world_c_party_art.json"));
    defer world.deinit();
    var fixture = try h.Fixture.open(null);
    defer fixture.deinit();
    for ([_]bool{ false, true }) |world_view| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        try combat.attachSpellScenes(&parsed.value);
        if (world_view) combat.content.world_art = world.value;
        combat.phase = .command;
        for (0..3) |_| try std.testing.expect(combat.inflictStatus(0, .balloon));
        const origin = battle.layout.worldPosition(&combat, 0);
        const hp = combat.hp(0);
        combat.beginDeparture(0);
        try std.testing.expect(combat.departed[0] and !combat.participates(0));
        try std.testing.expectEqual(hp, combat.hp(0));
        const start = combat.departures[0].?.started_at;
        var draws = h.rules.Draws{ .values = &.{} };
        try combat.tickReplay(.{}, &draws);
        try std.testing.expectEqual(start + 1, combat.camera_ticks);
        try std.testing.expectEqual(@as(usize, 0), draws.cursor);
        combat.beginDeparture(0);
        try std.testing.expectEqual(start, combat.departures[0].?.started_at);
        combat.progress.party[1].hp = 0;
        combat.progress.party[1].status = .unconscious;
        combat.beginDeparture(1);
        try std.testing.expect(!combat.departed[1] and combat.departures[1] == null);
        combat.markPartyKnockout(1);
        combat.beginDeparture(1);
        try std.testing.expect(combat.knockout_pending[1] and !combat.departed[1] and combat.departures[1] == null);
        combat.knockout_pending[1] = false;
        combat.knockout_status[1] = null;
        combat.progress.party[1].hp = 1;
        combat.progress.party[1].status = .healthy;
        combat.revivals[1] = .{ .started_at = start, .origin = battle.layout.worldPosition(&combat, 1), .original_status = .healthy };
        combat.beginDeparture(1);
        try std.testing.expect(combat.revivals[1] != null and !combat.departed[1] and combat.departures[1] == null);
        combat.revivals[1] = null;
        const checks = [_]struct { age: u32, x: i32, y: i32, z: i32 }{
            .{ .age = 0, .x = 0, .y = 0, .z = 0 },
            .{ .age = 1, .x = 14180, .y = 8208, .z = -8533 },
            .{ .age = 30, .x = 0, .y = 0, .z = -255990 },
            .{ .age = 96, .x = 46028, .y = 79816, .z = -819168 },
            .{ .age = 120, .x = 46028, .y = 79816, .z = -819168 },
        };
        for (checks) |check| {
            combat.camera_ticks = start + check.age;
            const position = battle.layout.worldPosition(&combat, 0);
            try std.testing.expectApproxEqAbs(origin.x + @as(f32, @floatFromInt(check.x)) / 4096, position.x, 0.001);
            try std.testing.expectApproxEqAbs(origin.y + @as(f32, @floatFromInt(check.y)) / 4096, position.y, 0.001);
            try std.testing.expectApproxEqAbs(origin.z + @as(f32, @floatFromInt(check.z)) / 4096, position.z, 0.001);
            try std.testing.expect(combat.hasStatusIconsFor(0));
            const frame = combat.spellSceneFrame();
            try std.testing.expectEqual(@as(usize, 3), frame.count);
            const body_layout = battle.layout.actorLayout(combat, 0);
            const anchor = parsed.value.statusAnchors(combat.progress.party[0].id).?.offsets[body_layout.source_pose.?];
            const entry = parsed.value.entries[frame.commands[0].texture.?];
            const scale: i32 = @intFromFloat(body_layout.scale * 2048);
            try std.testing.expectEqual(body_layout.point.x / 2 + @as(f32, @floatFromInt(@divTrunc(@as(i32, anchor[0]) * scale, 4096) + ((entry.dx * scale) >> 12))), frame.commands[0].vertices[0].x);
            try std.testing.expectEqual(body_layout.point.y / 2 + @as(f32, @floatFromInt(@divTrunc(@as(i32, anchor[1]) * scale, 4096) + ((entry.dy * scale) >> 12))), frame.commands[0].vertices[0].y);
            if (world_view) {
                const scene = battle.world_art.compose(battle.layout.sceneArt(combat), combat);
                try std.testing.expectEqual(@as(f32, 0), scene.shadows[0].radius_x);
                const body = for (scene.quads[0..scene.length]) |quad| {
                    if (quad.actor != null and quad.actor.? == 0 and !quad.projectile and !quad.medicine_particle) break quad;
                } else return error.MissingDepartureBody;
                try std.testing.expectEqualDeep(position, body.position);
            }
        }
        combat.startEncounter();
        try std.testing.expect(combat.departures[0] == null and !combat.departed[0]);
    }
}

test "defeat departure advances world presentation without gameplay changes" {
    const world = try battle.world_art.load(allocator, @embedFile("../fixtures/world_c_party_art.json"));
    defer world.deinit();
    var fixture = try h.Fixture.open(null);
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.content.world_art = world.value;
    combat.phase = .defeat;
    const start = combat.camera_ticks;
    combat.tick(.{});
    try std.testing.expectEqual(start, combat.camera_ticks);
    combat.beginDeparture(0);
    const origin = battle.layout.worldPosition(&combat, 0);
    const hp = combat.hp(0);
    const random = combat.random;
    var draws = h.rules.Draws{ .values = &.{} };
    for (0..96) |_| try combat.tickReplay(.{}, &draws);
    const end = battle.layout.worldPosition(&combat, 0);
    try std.testing.expectApproxEqAbs(origin.z - 819168.0 / 4096.0, end.z, 0.001);
    try std.testing.expectEqual(start + 96, combat.camera_ticks);
    try std.testing.expectEqual(.defeat, combat.phase);
    try std.testing.expectEqual(hp, combat.hp(0));
    try std.testing.expectEqualDeep(random, combat.random);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    try combat.tickReplay(.{}, &draws);
    try std.testing.expect(combat.departed[0] and combat.departures[0] == null);
    try combat.tickReplay(.{}, &draws);
    try std.testing.expectEqual(start + 97, combat.camera_ticks);
}

test "Status art attaches to the current source body pose and scale in both world render paths" {
    const parsed = try load();
    defer parsed.deinit();
    var fixture = try h.Fixture.open(null);
    defer fixture.deinit();
    const b = try battle.world_art.load(allocator, @embedFile("../fixtures/world_b_party_art.json"));
    defer b.deinit();
    const c = try battle.world_art.load(allocator, @embedFile("../fixtures/world_c_party_art.json"));
    defer c.deinit();
    for ([_]battle.world_art.Data{ b.value, c.value }) |art| for ([_]i32{ 2048, 4096, 8192 }) |size| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        try combat.attachSpellScenes(&parsed.value);
        combat.content.world_art = art;
        combat.phase = .command;
        for (0..6) |actor| {
            combat.actor_sizes[actor] = size;
            combat.progress.party[actor].hp = combat.progress.party[actor].max_hp / 8;
            try std.testing.expect(combat.inflictStatus(actor, .sleep));
        }
        const scene = combat.spellSceneFrame();
        try std.testing.expectEqual(@as(usize, 6), scene.count);
        for (0..6) |actor| {
            const layout = battle.layout.actorLayout(combat, actor);
            const anchors = parsed.value.statusAnchors(combat.progress.party[actor].id).?;
            const source_pose = battle.world_art.actorSample(battle.layout.sceneArt(combat), &combat, actor).sample.pose;
            try std.testing.expectEqual(@as(?u16, source_pose), layout.source_pose);
            const offset = anchors.offsets[source_pose];
            const command = scene.commands[actor];
            const entry = parsed.value.entries[command.texture.?];
            const scale: i32 = @intFromFloat(layout.scale * 2048);
            const expected = [2]i32{ @divTrunc(@as(i32, offset[0]) * scale, 4096) + ((entry.dx * scale) >> 12), @divTrunc(@as(i32, offset[1]) * scale, 4096) + ((entry.dy * scale) >> 12) };
            try std.testing.expectEqual(layout.point.x / 2 + @as(f32, @floatFromInt(expected[0])), command.vertices[0].x);
            try std.testing.expectEqual(layout.point.y / 2 + @as(f32, @floatFromInt(expected[1])), command.vertices[0].y);
        }
    };
}

test "Status art follows idle attack and cast source poses for every exported party profile" {
    const parsed = try load();
    defer parsed.deinit();
    const content = try battle.load(allocator, @embedFile("../fixtures/blacksmith_battle.json"));
    defer content.deinit();
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    try std.testing.expectEqual(@as(usize, 44), content.value.party.len);
    for (content.value.party) |profile| {
        var view = content.value;
        var selected = [_][]const u8{profile.id};
        view.initial_party = &selected;
        view.party_positions = view.party_positions[0..1];
        var members: [1]battle.Member = undefined;
        var combat = try battle.State.init(view, items.value, &members, 17);
        try combat.attachSpellScenes(&parsed.value);
        try std.testing.expect(combat.inflictStatus(0, .poison));
        const anchors = parsed.value.statusAnchors(profile.id).?;
        try std.testing.expectEqual(@as(?u16, anchors.idle_pose), battle.layout.actorLayout(combat, 0).source_pose);
        try std.testing.expectEqual(@as(usize, 1), combat.spellSceneFrame().count);
        for ([_]bool{ false, true }) |casting| {
            combat.active = .{ .actor = 0, .target = 1, .kind = if (casting) .cast else .attack };
            var age: u16 = 0;
            const frames = if (casting) profile.cast else profile.attack;
            for (frames) |frame| {
                combat.action_ticks = age;
                const pose = battle.layout.actorLayout(combat, 0);
                try std.testing.expect(frame.source_pose != null);
                try std.testing.expectEqual(frame.source_pose, pose.source_pose);
                try std.testing.expectEqual(@as(usize, 1), combat.spellSceneFrame().count);
                age += frame.ticks;
            }
        }
    }
}

test "Status art keeps idle attachments throughout Shining Wind support reactions" {
    const parsed = try load();
    defer parsed.deinit();
    const host = try h.hostFixture();
    defer host.deinit();
    var fixture = try h.Fixture.open(null);
    defer fixture.deinit();
    const world = try battle.world_art.load(allocator, @embedFile("../fixtures/world_c_party_art.json"));
    defer world.deinit();
    const scene = parsed.value.spells[parsed.value.indexOf("spell_31").?];
    const start = scene.program.?.party_reaction.?.start;
    const spell_index = for (fixture.view.systems.?.spells, 0..) |spell, index| {
        if (std.mem.eql(u8, spell.id, scene.id)) break index;
    } else unreachable;
    for ([_]bool{ false, true }) |with_world| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        combat.integration = .{ .host = host };
        try combat.attachSpellScenes(&parsed.value);
        if (with_world) combat.content.world_art = world.value;
        combat.runes[0] = found: {
            for (combat.content.systems.?.runes, 0..) |rune, index| for (rune.spells) |slot| {
                if (slot != null and slot.? == spell_index) break :found index;
            };
            unreachable;
        };
        combat.progress.party[0].rune_charges = @splat(9);
        combat.progress.party[1].hp /= 2;
        try std.testing.expect(combat.inflictStatus(1, .poison));
        combat.actions = @splat(.defend);
        combat.actions[0] = .{ .spell = .{ .index = spell_index, .target = 0 } };
        combat.acted = @splat(true);
        combat.phase = .resolving;
        var tape = h.Tape{};
        var draws = tape.init();
        combat.replay_draws = &draws;
        try std.testing.expect(combat.beginSpellAction(0, .{ .index = spell_index, .target = @as(usize, 0) }));
        combat.replay_draws = null;
        for (0..start) |_| try combat.tickReplay(.{}, &draws);
        const response = combat.spellReaction(1).?;
        try std.testing.expectEqual(@as(u8, 0), response.animation);
        try std.testing.expect(response.entry != null);
        const anchors = parsed.value.statusAnchors(combat.progress.party[1].id).?;
        try std.testing.expectEqual(@as(?u16, anchors.idle_pose), battle.layout.actorLayout(combat, 1).source_pose);
        try std.testing.expect(combat.hasStatusIconsFor(1));
        const frame = combat.spellSceneFrame();
        try std.testing.expect(frame.count > 0);
        const icon = parsed.value.status_icons[0];
        try std.testing.expectEqual(icon.entryAt(combat.camera_ticks - combat.status_icons[1].started_at[0] + 1), frame.commands[frame.count - 1].texture.?);
    }
}
