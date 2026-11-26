const characterFields = @import("character_fields.zig").capture;
const std = @import("std");
const battle = @import("battle");
const field = @import("field");
const allocator = std.testing.allocator;
test {
    _ = @import("battle_trick.zig");
    _ = @import("battle_physical.zig");
    _ = @import("battle_counter.zig");
    _ = @import("battle_cover.zig");
    _ = @import("battle_strong_arm.zig");
    _ = @import("battle_ninja.zig");
    _ = @import("battle_dagon.zig");
    _ = @import("battle_whip_wolf.zig");
}
const drops_art_fixture = battle.drops.Art{ .schema = "suikoden-drops-art/1", .entries = .{ .{ .x = 0, .y = 0, .w = 64, .h = 64, .dx = -32, .dy = -32 }, .{ .x = 64, .y = 0, .w = 16, .h = 32, .dx = -8, .dy = -16 }, .{ .x = 80, .y = 0, .w = 16, .h = 32, .dx = -8, .dy = -16 }, .{ .x = 96, .y = 0, .w = 16, .h = 32, .dx = -8, .dy = -16 } } };

test "scene experience keeps ten-point floor wrap cap and party growth draw order" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/blacksmith_battle.json"));
    defer parsed.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(parsed.value, rules.value, &members, 17);
    for (state.progress.party.items(), [_]u32{ 999, 995, 9, 0, 999, 999 }) |member, xp| member.experience = xp;
    state.progress.party.at(0).level = 5;
    state.progress.party.at(1).level = 98;
    state.progress.party.at(4).level = 99;
    state.progress.party.at(5).level = 99;
    var draws = state;
    for (0..14) |_| _ = draws.roll();
    try state.sceneExperience(true);
    try std.testing.expectEqualSlices(u32, &.{ 9, 5, 19, 10, 9, 9 }, &characterFields("experience", state.progress.party));
    try std.testing.expectEqual(@as(u8, 6), state.progress.party.at(0).level);
    try std.testing.expectEqual(@as(u8, 99), state.progress.party.at(1).level);
    try std.testing.expectEqualDeep(draws.random, state.random);
    const levels = characterFields("level", state.progress.party);
    try state.sceneExperience(false);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 9, 0, 0, 0 }, &characterFields("experience", state.progress.party));
    try std.testing.expectEqualDeep(levels, characterFields("level", state.progress.party));
    try std.testing.expectEqualDeep(draws.random, state.random);
}

test "Buddha generic clip flags and schema reject missing or unsafe art" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/blacksmith_battle.json"));
    defer parsed.deinit();
    var content = parsed.value;
    const profiles = try allocator.dupe(battle.Profile, content.party);
    defer allocator.free(profiles);
    content.party = profiles;
    const art = profiles[0].revival_art.?;
    var frames = [_]battle.Frame{ art.down.frames[0], art.recovery.frames[0] };
    frames[0].ticks = 2;
    frames[1].ticks = 3;
    var clip = art.down;
    clip.frames = &frames;
    clip.advances = true;
    clip.loop = true;
    try std.testing.expectEqualDeep(frames[0].pose, clip.sample(0));
    try std.testing.expectEqualDeep(frames[0].pose, clip.sample(1));
    try std.testing.expectEqualDeep(frames[1].pose, clip.sample(2));
    try std.testing.expectEqualDeep(frames[0].pose, clip.sample(5));
    clip.loop = false;
    try std.testing.expectEqualDeep(frames[1].pose, clip.sample(100));
    clip.advances = false;
    try std.testing.expectEqualDeep(frames[0].pose, clip.sample(100));
    profiles[0].revival_art = null;
    try std.testing.expectError(error.MissingRevivalArt, content.validate());
    profiles[0].revival_art = art;
    profiles[0].revival_art.?.down.frames = &.{};
    try std.testing.expectError(error.InvalidRevivalArt, content.validate());
    profiles[0].revival_art = art;
    profiles[0].revival_art.?.down.frames = &frames;
    frames[0].ticks = 0;
    try std.testing.expectError(error.InvalidBattleAssets, content.validate());
    frames[0].ticks = 2;
    frames[0].pose.rect.x = 2048;
    try std.testing.expectError(error.InvalidBattleAssets, content.validateAtlas(2048, 4096));
}

test "Critical schema39 keeps legacy packets readable and validates physical asset bindings" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    try packet.validate(4096, 4096);
    packet.schema = "suikoden-spell-scenes/38";
    packet.status_icons = &.{};
    packet.status_anchors = &.{};
    packet.enemy_magic_art = null;
    packet.needle_burst = &.{};
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    packet.physical_white_poses = &.{};
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    packet.unite_impacts = packet.unite_impacts[0..3];
    const reactions = try allocator.dupe(battle.spell_scene.UniteReaction, packet.unite_reactions);
    defer allocator.free(reactions);
    for (reactions) |*reaction| {
        reaction.retain_lock = false;
        reaction.palette_cycle = null;
        if (reaction.record == 27 or reaction.record == 30) reaction.* = .{ .record = reaction.record, .variant = reaction.variant, .duration = reaction.duration, .blocker = "legacy", .poses = &.{}, .white = &.{}, .offsets = &.{}, .motions = &.{}, .impacts = &.{} };
    }
    packet.unite_reactions = reactions;
    const hurt = try allocator.dupe(battle.spell_scene.HurtPose, packet.hurt_poses);
    defer allocator.free(hurt);
    for (hurt) |*pose| pose.idle_flash = null;
    packet.hurt_poses = hurt;
    try packet.validate(4096, 4096);
    const legacy = try std.json.Stringify.valueAlloc(allocator, packet, .{});
    defer allocator.free(legacy);
    try std.testing.expect(std.mem.indexOf(u8, legacy, "physical_white_poses") == null);
    packet = parsed.value;
    const poses = try allocator.dupe(@TypeOf(packet.physical_white_poses[0]), packet.physical_white_poses);
    defer allocator.free(poses);
    packet.physical_white_poses = poses;
    poses[0].entry = @intCast(packet.entries.len);
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    poses[0] = parsed.value.physical_white_poses[0];
    poses[1].id = poses[0].id;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "spell schema46 admits the source ranged impact without weakening older packets" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    const impacts = try allocator.alloc(@TypeOf(packet.unite_impacts[0]), packet.unite_impacts.len + 1);
    defer allocator.free(impacts);
    @memcpy(impacts[0..packet.unite_impacts.len], packet.unite_impacts);
    impacts[impacts.len - 1] = impacts[0];
    impacts[impacts.len - 1].id = 3;
    packet.unite_impacts = impacts;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    packet.schema = "suikoden-spell-scenes/46";
    try packet.validate(4096, 4096);
    impacts[impacts.len - 1].id = 4;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "animated column gaps follow source updates and reject unsafe packets" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = spellOnlyFixture(parsed.value);
    var gaps: [64]u16 = undefined;
    const samples: [64]battle.spell_scene.Sample = @splat(.{});
    const shapes: [64]battle.spell_scene.ColumnShape = @splat(.{ .radius = 800, .top_radius = 0, .base_height = -100, .height = 0, .inner = .{ 80, 80, 80 }, .outer = .{ 16, 16, 16 } });
    const wash: [65][3]u8 = @splat(.{ 0, 0, 0 });
    for (&gaps, 0..) |*gap, index| gap.* = @intCast((0x190000 - 0x3200 * (@as(i32, @intCast(index)) + 1)) >> 12);
    gaps[30] = 0;
    var mesh = battle.spell_scene.Mesh{ .kind = .column, .anchor = .world, .track = 0, .start = 0, .stop = 63, .origin = .{ 0, -30, -40 }, .radius = 800, .segments = 10, .inner = .{ 80, 80, 80 }, .outer = .{ 16, 16, 16 }, .shape_samples = &shapes, .segment_gaps = &gaps };
    var spells = [_]battle.spell_scene.Spell{.{ .id = "column", .name = "Column", .program = .{ .impact = 2, .duration = 64, .initial_draws = 0, .tracks = &.{&samples}, .objects = &.{}, .cameras = &.{}, .meshes = (&mesh)[0..1], .wash = &wash, .wash_blend = .additive } }};
    packet.spells = &spells;
    packet.schema = "suikoden-spell-scenes/46";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    packet.schema = "suikoden-spell-scenes/47";
    try packet.validate(4096, 4096);
    const animated_json = try std.json.Stringify.valueAlloc(allocator, mesh, .{});
    defer allocator.free(animated_json);
    try std.testing.expect(std.mem.indexOf(u8, animated_json, "segment_gaps") != null);
    mesh.segment_gaps = &.{};
    const legacy_json = try std.json.Stringify.valueAlloc(allocator, mesh, .{});
    defer allocator.free(legacy_json);
    try std.testing.expect(std.mem.indexOf(u8, legacy_json, "segment_gaps") == null);
    mesh.segment_gaps = &gaps;
    const instance = battle.spell_scene.Instance{ .spell = 0, .caster = .{ 0, 0, 0 }, .target = .{ 0, 0, 0 }, .initial_camera = battle.drops.initial_camera };
    for ([_]u16{ 0, 30, 62 }) |update| {
        const animated = battle.spell_scene.frameAt(&packet, &instance, update);
        mesh.segment_gaps = &.{};
        mesh.segment_gap = gaps[update];
        const fixed = battle.spell_scene.frameAt(&packet, &instance, update);
        try std.testing.expectEqual(@as(usize, 10), animated.count);
        try std.testing.expectEqualDeep(fixed.commands[0..fixed.count], animated.commands[0..animated.count]);
        mesh.segment_gap = 0;
        mesh.segment_gaps = &gaps;
    }
    mesh.segment_gaps = gaps[0..62];
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    mesh.segment_gaps = &gaps;
    gaps[10] = 409;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    gaps[10] = 200;
    mesh.segment_gap = 1;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    mesh.segment_gap = 0;
    mesh.kind = .fan;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "Flash source columns and screen wash render on their source clocks" {
    const library = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer library.deinit();
    const source = try std.json.parseFromSlice(battle.spell_scene.Program, allocator, @embedFile("fixtures/flash_scene_program.json"), .{});
    defer source.deinit();
    var packet = spellOnlyFixture(library.value);
    packet.schema = "suikoden-spell-scenes/47";
    const meshes = try allocator.dupe(battle.spell_scene.Mesh, source.value.meshes);
    defer allocator.free(meshes);
    var program = source.value;
    program.meshes = meshes;
    const spells = [_]battle.spell_scene.Spell{.{ .id = "flash", .name = "Flash", .program = program }};
    packet.spells = &spells;
    try packet.validate(4096, 4096);
    const instance = battle.spell_scene.Instance{ .spell = 0, .caster = .{ 0, 0, 0 }, .target = .{ 0, 0, 0 }, .initial_camera = battle.drops.initial_camera };
    for (1..64) |age| {
        const update: u16 = @intCast(age);
        const animated = battle.spell_scene.frameAt(&packet, &instance, update);
        try std.testing.expectEqual(@as(usize, 30), animated.count);
        for (meshes) |*mesh| {
            mesh.segment_gap = mesh.segment_gaps[update];
            mesh.segment_gaps = &.{};
        }
        const fixed = battle.spell_scene.frameAt(&packet, &instance, update);
        try std.testing.expectEqualDeep(fixed.commands[0..fixed.count], animated.commands[0..animated.count]);
        for (meshes, source.value.meshes) |*mesh, original| {
            mesh.segment_gap = 0;
            mesh.segment_gaps = original.segment_gaps;
        }
    }
    for ([_]struct { update: u16, color: u8 }{ .{ .update = 64, .color = 255 }, .{ .update = 128, .color = 255 }, .{ .update = 129, .color = 251 }, .{ .update = 191, .color = 3 } }) |row| {
        const frame = battle.spell_scene.frameAt(&packet, &instance, row.update);
        try std.testing.expectEqual(@as(usize, 1), frame.count);
        try std.testing.expectEqual([3]u8{ row.color, row.color, row.color }, frame.commands[0].colors[0]);
    }
    try std.testing.expectEqual(@as(usize, 0), battle.spell_scene.frameAt(&packet, &instance, 192).count);
}

// Older-schema tests isolate spell fields from newer shared presentation data.
fn spellOnlyFixture(original: battle.spell_scene.Packet) battle.spell_scene.Packet {
    var packet = original;
    packet.status_icons = &.{};
    packet.status_anchors = &.{};
    packet.enemy_magic_art = null;
    packet.needle_burst = &.{};
    packet.unite_scenes = &.{};
    packet.unite_impacts = &.{};
    packet.physical_white_poses = &.{};
    packet.unite_reactions = &.{};
    packet.hurt_poses = &.{};
    return packet;
}

test "shared scene offsets match source Scolding quad projection vectors" {
    const Case = struct { camera: @TypeOf(battle.drops.initial_camera), world: [3]i32, offsets: [4][3]i16, vertices: [4][2]f32, depth: i32 };
    const Fixture = struct { schema: []const u8, cases: []const Case };
    const fixture = try std.json.parseFromSlice(Fixture, allocator, @embedFile("fixtures/scolding_projection.json"), .{});
    defer fixture.deinit();
    try std.testing.expectEqualStrings("suikoden-scolding-projection-vectors/1", fixture.value.schema);
    try std.testing.expect(fixture.value.cases.len > 1000);
    for (fixture.value.cases) |case| {
        const center = battle.drops.project(case.camera, case.world);
        const quad = battle.spell_scene.sceneOffsetQuad(case.camera, center, case.offsets);
        try std.testing.expectEqual(case.depth, @divTrunc(std.math.clamp(quad.depth, 0, 65535), 4));
        for (case.vertices, quad.vertices) |xy, vertex| {
            try std.testing.expectEqual(xy[0], vertex.x);
            try std.testing.expectEqual(xy[1], vertex.y);
        }
    }
}

test "target flights and projected texture corners reject invalid contracts" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    var objects = [_]battle.spell_scene.Object{packet.spells[4].program.?.objects[1]};
    var spells = [_]battle.spell_scene.Spell{packet.spells[4]};
    spells[0].program.?.objects = &objects;
    packet.spells = &spells;
    try packet.validate(4096, 4096);
    const valid = objects[0];
    objects[0].flight.?.updates = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    objects[0] = valid;
    objects[0].flight.?.start = 258;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    objects[0] = valid;
    objects[0].flight.?.target_height_q12 = 4097;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    objects[0] = valid;
    objects[0].anchor = .world;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    objects[0] = valid;
    packet = spellOnlyFixture(packet);
    packet.schema = "suikoden-spell-scenes/30";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "Soul Eater initialized-state diagnostics compose through the shared player" {
    const Command = struct { kind: []const u8, vertices: []const [2]f32, colors: []const [3]u8 = &.{}, texture: ?u16 = null, intensity: [3]u8 = @splat(128), blend: []const u8, depth: i32, background_uv: ?[]const [2]f32 = null };
    const Fixture = struct {
        status: []const u8,
        startup: struct { root_fraction: u16, velocity_fraction: u16 = 0, point_scales: []const i32, particle_lifetimes: u16, particle_positions: [3]i32 },
        packet: battle.spell_scene.Packet,
        cases: []const struct { update: u16, draw_count: usize, commands: []const Command },
    };
    for ([_][]const u8{ @embedFile("fixtures/shadow_scene_diagnostic.json"), @embedFile("fixtures/hell_scene_diagnostic.json") }) |bytes| {
        const parsed = try std.json.parseFromSlice(Fixture, allocator, bytes, .{});
        defer parsed.deinit();
        const fixture = parsed.value;
        try std.testing.expectEqualStrings("diagnostic_not_qualified", fixture.status);
        try fixture.packet.validate(4096, 4096);
        var draws = battle.systems.Draws{ .bios_state = 17 };
        var instance = try battle.spell_scene.Instance.begin(&fixture.packet, 0, .{ 120, 50, 0 }, .{ -128, 0, 0 }, battle.drops.initial_camera, &draws);
        for (fixture.cases) |case| {
            const hell = std.mem.eql(u8, fixture.packet.spells[0].id, "spell_27");
            const minimum: ?u16 = if (hell) (if (case.update >= 97 and case.update < 317) 381 else if (case.update >= 317 and case.update < 436) 8 else null) else (if (case.update >= 97 and case.update < 250) 382 else null);
            try std.testing.expectEqual(minimum, battle.spell_scene.backgroundCaptureMinimum(fixture.packet.spells[0].program.?, case.update));
            try instance.advance(&fixture.packet, case.update, &draws);
            try std.testing.expectEqual(case.draw_count, draws.cursor);
            const frame = battle.spell_scene.frameAt(&fixture.packet, &instance, case.update);
            try std.testing.expectEqual(case.commands.len, frame.count);
            for (case.commands, frame.commands[0..frame.count]) |expected, actual| {
                try std.testing.expectEqual(expected.vertices.len, actual.count);
                try std.testing.expectEqual(expected.depth, actual.depth);
                try std.testing.expectEqual(expected.texture, actual.texture);
                try std.testing.expectEqualStrings(expected.blend, @tagName(actual.blend));
                for (expected.vertices, 0..) |xy, i| {
                    try std.testing.expectEqual(xy[0], actual.vertices[i].x);
                    try std.testing.expectEqual(xy[1], actual.vertices[i].y);
                }
                for (expected.colors, 0..) |color, i| try std.testing.expectEqualDeep(color, actual.colors[i]);
                if (expected.texture != null or expected.background_uv != null) try std.testing.expectEqualDeep(expected.intensity, actual.tint);
                if (expected.background_uv) |uvs| for (uvs, 0..) |uv, i| {
                    try std.testing.expectEqual(uv[0], actual.background_uv.?[i].x);
                    try std.testing.expectEqual(uv[1], actual.background_uv.?[i].y);
                };
            }
        }
        if (fixture.packet.spells[0].program.?.background_warps.len == 2) {
            var packet = fixture.packet;
            const spells = try allocator.dupe(battle.spell_scene.Spell, packet.spells);
            defer allocator.free(spells);
            packet.spells = spells;
            const warps = try allocator.dupe(battle.spell_scene.BackgroundWarp, spells[0].program.?.background_warps);
            defer allocator.free(warps);
            spells[0].program.?.background_warps = warps;
            warps[1].samples = warps[0].samples;
            try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
            warps[1].depth = warps[0].depth;
            const meshes = spells[0].program.?.meshes;
            spells[0].program.?.meshes = &.{};
            try packet.validate(4096, 4096);
            spells[0].program.?.meshes = meshes;
            try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
        }
    }
}

test "Hell pulse geometry preserves the source scale handoff across its complete lifetime" {
    const Fixture = struct {
        packet: battle.spell_scene.Packet,
        scale_inputs: []const i32,
        cases: []const struct { update: u16, commands: []const struct { vertices: [4][2]f32, colors: [4][3]u8, depth: i32 } },
    };
    const parsed = try std.json.parseFromSlice(Fixture, allocator, @embedFile("fixtures/hell_pulse_geometry.json"), .{});
    defer parsed.deinit();
    const fixture = parsed.value;
    try fixture.packet.validate(4096, 4096);
    try std.testing.expectEqual(@as(usize, 91), fixture.scale_inputs.len);
    var draws = battle.systems.Draws{ .values = &.{} };
    const instance = try battle.spell_scene.Instance.begin(&fixture.packet, 0, @splat(0), @splat(0), battle.drops.initial_camera, &draws);
    for (fixture.cases) |case| {
        const frame = battle.spell_scene.frameAt(&fixture.packet, &instance, case.update);
        try std.testing.expectEqual(case.commands.len, frame.count);
        for (case.commands, frame.commands[0..frame.count]) |expected, actual| {
            try std.testing.expectEqual(@as(u8, 4), actual.count);
            try std.testing.expectEqual(expected.depth, actual.depth);
            try std.testing.expectEqualDeep(expected.colors, actual.colors);
            for (expected.vertices, actual.vertices) |xy, point| {
                try std.testing.expectEqual(xy[0], point.x);
                try std.testing.expectEqual(xy[1], point.y);
            }
        }
    }
}

test "Hazy and Killer agree with static source probability vectors" {
    const Vectors = struct { hits: []const [5]u16, critical: []const [5]u16 };
    const vectors = try std.json.parseFromSlice(Vectors, allocator, @embedFile("fixtures/passive_offense.json"), .{});
    defer vectors.deinit();
    for (vectors.value.hits) |row| try std.testing.expectEqual(row[4] != 0, battle.hitsWithAccuracyPenalty(row[0], row[1], @intCast(row[3]), row[2] != 0));
    for (vectors.value.critical) |row| try std.testing.expectEqual(row[4] != 0, battle.critical(row[0], row[1], row[2] != 0, @intCast(row[3])));
}

test "battle feedback rows separate overlapping notices within the scissor" {
    var rows: battle.layout.FeedbackRows = .{};
    try std.testing.expectEqual(@as(?i32, 104), rows.place(104, 22));
    try std.testing.expectEqual(@as(?i32, 84), rows.place(104, 18));
    try std.testing.expectEqual(@as(?i32, 170), rows.place(170, 20));

    rows = .{};
    try std.testing.expectEqual(@as(?i32, 38), rows.place(-20, 22));
    try std.testing.expectEqual(@as(?i32, 62), rows.place(38, 18));
    try std.testing.expectEqual(@as(?i32, 316), rows.place(400, 20));

    rows = .{};
    try std.testing.expectEqual(@as(?i32, 38), rows.place(100, 298));
    try std.testing.expectEqual(@as(?i32, null), rows.place(100, 22));
}

test "battle layout uses the source camera framing and finite actor projections" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/demo_batch.json"));
    defer parsed.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(parsed.value, rules.value, &members, 17);
    const formations = [_][6]u8{ .{ 0, 1, 2, 3, 4, 5 }, .{ 3, 4, 5, 0, 1, 2 }, .{ 5, 3, 4, 2, 0, 1 }, .{ 1, 2, 0, 4, 5, 3 } };
    for (formations) |formation| {
        state.setFormation(formation);
        const frame = battle.layout.framing(state);
        try std.testing.expectEqual(battle.layout.Framing{}, frame);
        for (0..state.partyCount() + state.enemyCount()) |index| {
            const point = battle.layout.position(state, index);
            try std.testing.expect(std.math.isFinite(point.x) and std.math.isFinite(point.y));
        }
    }
}

test "three source encounters load and trial state starts independently" {
    const content = try battle.load(allocator, @embedFile("fixtures/battle_trial.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [2]battle.Member = undefined;
    var state = try battle.State.init(content.value, rules.value, &members, 17);
    try std.testing.expectEqual(@as(usize, 3), content.value.encounters.len);
    try std.testing.expectEqual(@as(usize, 1), state.enemyCount());
    try std.testing.expectEqual(@as(u16, 100), state.hp(0));
    try std.testing.expectEqual(@as(usize, 2), members[0].inventory.count());
    state.tick(.{ .confirm = true });
    try std.testing.expectEqual(.command, state.phase);
}

test "battle layout shadowLayout tracks actor ground XY and eases action camera cleanly" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/demo_batch.json"));
    defer parsed.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(parsed.value, rules.value, &members, 17);
    state.camera_ticks = 300;
    const base_cam = battle.layout.currentCamera(state);
    state.active = .{ .actor = 0, .target = 6, .kind = .attack, .started_at = 0 };
    const duration = state.actionDuration();

    state.action_ticks = 0;
    try std.testing.expectEqualDeep(base_cam, battle.layout.currentCamera(state));

    state.action_ticks = 6;
    const mid_cam = battle.layout.currentCamera(state);
    try std.testing.expect(mid_cam.focus[0] != base_cam.focus[0]);

    state.action_ticks = 18;
    const peak_cam = battle.layout.currentCamera(state);
    try std.testing.expectEqualDeep(@import("battle_camera").attack_party, peak_cam);

    state.action_ticks = duration;
    try std.testing.expectEqualDeep(base_cam, battle.layout.currentCamera(state));

    // Shadow tracks the acting character on the floor plane instead of staying pinned at home.
    state.action_ticks = 14;
    const ground_pos = battle.Position{
        .x = battle.layout.worldPosition(&state, 0).x,
        .y = battle.layout.worldPosition(&state, 0).y,
        .z = battle.layout.homePosition(&state, 0).z,
    };
    const expected_point = battle.layout.worldPoint(state, ground_pos);
    const shadow = battle.layout.shadowLayout(state, 0);
    try std.testing.expectApproxEqAbs(expected_point.x, shadow.point.x, 0.01);
    try std.testing.expectApproxEqAbs(expected_point.y, shadow.point.y, 0.01);
}

test "combat arithmetic agrees with original damage, hit and priority instructions" {
    const Damage = struct { attack: u16, defense: u16, roll: u15, defending: bool, damage: u32 };
    const Accuracy = struct { skill: u16, target_skill: u16, roll: u15, hit: bool };
    const Speed = struct { speeds: [3]u16, rolls: [3]u15, chosen: usize };
    const Vectors = struct { damage: []Damage, accuracy: []Accuracy, speed: []Speed };
    const vectors = try std.json.parseFromSlice(Vectors, allocator, @embedFile("fixtures/battle_math.json"), .{});
    defer vectors.deinit();
    for (vectors.value.damage) |row| try std.testing.expectEqual(row.damage, battle.physicalDamage(row.attack, row.defense, row.roll, row.defending));
    for (vectors.value.accuracy) |row| try std.testing.expectEqual(row.hit, battle.hits(row.skill, row.target_skill, row.roll));
    for (vectors.value.speed) |row| {
        var best = battle.priority(row.speeds[0], row.rolls[0]);
        var chosen: usize = 0;
        for (1..3) |index| {
            const value = battle.priority(row.speeds[index], row.rolls[index]);
            if (value > best) {
                best = value;
                chosen = index;
            }
        }
        try std.testing.expectEqual(row.chosen, chosen);
    }
}

test "physical weapon weakness and rune pieces apply before critical damage" {
    const content = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(content.value, rules.value, &members, 17);
    const party = try allocator.dupe(battle.Profile, content.value.party);
    defer allocator.free(party);
    const enemies = try allocator.dupe(battle.Profile, content.value.enemies);
    defer allocator.free(enemies);
    state.content.party = party;
    state.content.enemies = enemies;
    const target_name = state.enemy(0).id;
    const enemy = for (enemies) |*value| {
        if (std.mem.eql(u8, value.id, target_name)) break value;
    } else return error.MissingEnemy;
    enemy.stats.defense = 50;
    enemy.stats.attack = 100;
    enemy.affinities = .{ .fire = .weak, .earth = .weak };
    state.progress.party.at(0).base_stats.attack = 100;
    state.progress.party.at(0).base_stats.defense = 50;
    state.progress.party.at(0).loadout = .{};
    party[0].weapon.?.element = .fire;
    state.content.schema = "suikoden-battle-trial/31";
    try std.testing.expectError(error.UnsupportedBattleSchema, state.content.validate());
    state.content.schema = "suikoden-battle-trial/33";
    try state.content.validate();
    enemy.affinities = null;
    try std.testing.expectError(error.MissingElementalAffinities, state.content.validate());
    enemy.affinities = .{ .fire = .weak, .earth = .weak };
    const target = state.partyCount();
    try std.testing.expectEqual(@as(u32, 82), state.resolvePhysicalDamage(0, target, 0, false));
    state.progress.party.at(0).weapon_augment = .{ .rune = .fire, .fragments = 3 };
    try std.testing.expectEqual(@as(u32, 94), state.resolvePhysicalDamage(0, target, 0, false));
    state.progress.party.at(0).weapon_augment = .{ .rune = .wind, .fragments = 3 };
    try std.testing.expectEqual(@as(u32, 94), state.resolvePhysicalDamage(0, target, 0, false));
    state.progress.party.at(0).weapon_augment = .{ .rune = .earth, .fragments = 9 };
    try std.testing.expectEqual(@as(u32, 55), state.resolvePhysicalDamage(0, target, 0, false));
    enemy.affinities.?.wind = .weak;
    try std.testing.expectEqual(@as(u32, 82), state.resolvePhysicalDamage(0, target, 0, false));
    state.progress.party.at(0).weapon_augment = .{ .rune = .water, .fragments = 9 };
    try std.testing.expectEqual(@as(u32, 55), state.resolvePhysicalDamage(0, target, 0, false));
    try std.testing.expectEqual(@as(u32, 27), state.resolvePhysicalDamage(target, 0, 0, true));
    state.progress.party.at(0).weapon_augment = .{ .rune = .fire, .fragments = 3 };
    var draws = battle.systems.Draws{ .values = &.{ 0, 99, 0 } };
    state.replay_draws = &draws;
    state.beginAttack(0, target, .ordinary);
    try std.testing.expectEqual(target, state.active.?.target);
    try std.testing.expectEqual(@as(u32, 94), state.active.?.amount);
    try std.testing.expectEqual(@as(usize, 3), draws.cursor);
    party[0].weapon.?.element = null;
    state.progress.party.at(0).weapon_augment = .{};
    try std.testing.expectEqual(@as(u32, 55), state.resolvePhysicalDamage(0, target, 0, false));
}

fn choose(state: *battle.State, command: @import("game").Command) !void {
    for (0..5) |_| {
        if (state.picker.selected == command) {
            state.tick(.{ .confirm = true });
            return;
        }
        state.tick(.{ .down = true });
    }
    return error.CommandUnavailable;
}

fn fightTrial(state: *battle.State) !void {
    var wins: usize = 0;
    var expected_money: u32 = 350;
    for (0..30000) |_| {
        try state.progress.validate();
        for (0..state.enemyCount()) |index| try std.testing.expect(state.enemy_hp[index] <= state.enemy(index).max_hp);
        switch (state.phase) {
            .intro, .target, .item, .item_target, .confirm_round => state.tick(.{ .confirm = true }),
            .command => {
                const member = state.progress.party.at(state.actor).*;
                const command: @import("game").Command = if (member.hp < 70 and member.inventory.count() > 0) .item else if (state.encounter == 1 and state.round == 1) .defend else .attack;
                try choose(state, command);
            },
            .resolving => state.tick(.{}),
            .victory => {
                wins += 1;
                try std.testing.expectEqual(wins - 1, state.encounter);
                expected_money += state.reward_money;
                try std.testing.expectEqual(expected_money, state.progress.money);
                const before = state.progress.party.at(0).*;
                const other = state.progress.party.at(1).*;
                const experience = characterFields("experience", state.progress.party);
                for (0..100) |_| state.tick(.{});
                try std.testing.expectEqual(expected_money, state.progress.money);
                try std.testing.expectEqualDeep(experience, characterFields("experience", state.progress.party));
                state.tick(.{ .confirm = true });
                try std.testing.expectEqualDeep(before, state.progress.party.at(0).*);
                try std.testing.expectEqualDeep(other, state.progress.party.at(1).*);
            },
            .complete => {
                try std.testing.expectEqual(@as(usize, 3), wins);
                try std.testing.expectEqual(@as(u32, 930), state.progress.money);
                try std.testing.expect(state.progress.party.at(0).experience <= 850 and state.progress.party.at(1).experience <= 850);
                return;
            },
            else => return error.TrialFailed,
        }
    }
    return error.TrialDidNotFinish;
}

test "three fights carry HP, inventory, money and EXP with no duplicate victory rewards" {
    const content = try battle.load(allocator, @embedFile("fixtures/battle_trial.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    for (0..20) |case| {
        const seed = if (case == 19) battle.trial_seed else case;
        var members: [2]battle.Member = undefined;
        var state = try battle.State.init(content.value, rules.value, &members, seed);
        try fightTrial(&state);
        state.tick(.{ .restart = true });
        try std.testing.expectEqual(@as(usize, 0), state.encounter);
        try std.testing.expectEqual(@as(u32, 350), state.progress.money);
        try std.testing.expectEqual(@as(u16, 100), members[0].hp);
        try std.testing.expectEqual(@as(u16, 120), members[1].hp);
        try std.testing.expectEqual(@as(u16, 6), members[0].inventory.slots[0].?.uses);
        try std.testing.expectEqualSlices(u32, &.{ 0, 0 }, characterFields("experience", state.progress.party)[0..2]);
    }
}

test "cancel target, item target, earlier actor, round and quit without mutating progress" {
    const content = try battle.load(allocator, @embedFile("fixtures/battle_trial.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [2]battle.Member = undefined;
    var state = try battle.State.init(content.value, rules.value, &members, 17);
    const bag = &members[0].inventory;
    const original = bag.*;
    bag.slots = @splat(null);
    bag.slots[0] = .{ .id = .bandanna, .uses = 0 };
    state.tick(.{ .confirm = true });
    try std.testing.expect(!state.picker.enabled[@backingInt(@import("game").Command.item)]);
    bag.slots[1] = original.slots[0];
    bag.slots[2] = .{ .id = .sacrificial_buddha, .uses = 0 };
    bag.slots[3] = original.slots[1];
    const mixed_bag = bag.*;
    state.choose(0);
    try choose(&state, .attack);
    try std.testing.expectEqual(state.partyCount() + state.selection, state.selectedTargetActor().?);
    try std.testing.expectEqual(state.enemyCount(), state.targetSelection().?.count);
    state.tick(.{ .cancel = true });
    try std.testing.expectEqual(.command, state.phase);
    try choose(&state, .attack);
    state.tick(.{ .confirm = true });
    try std.testing.expectEqual(@as(usize, 1), state.actor);
    state.tick(.{ .cancel = true });
    try std.testing.expectEqual(@as(usize, 0), state.actor);
    try choose(&state, .item);
    try std.testing.expectEqual(@as(usize, 1), state.selection);
    state.tick(.{ .down = true });
    state.tick(.{ .confirm = true });
    state.tick(.{ .up = true });
    try std.testing.expectEqual(state.selection, state.selectedTargetActor().?);
    try std.testing.expectEqual(state.partyCount(), state.targetSelection().?.count);
    state.tick(.{ .cancel = true });
    try std.testing.expectEqual(.item, state.phase);
    try std.testing.expectEqual(@as(usize, 3), state.selection);
    state.tick(.{ .cancel = true });
    try choose(&state, .defend);
    try choose(&state, .defend);
    try std.testing.expectEqual(.confirm_round, state.phase);
    state.tick(.{ .cancel = true });
    try std.testing.expectEqual(.command, state.phase);
    try std.testing.expectEqual(@as(u16, 100), members[0].hp);
    try std.testing.expectEqualDeep(mixed_bag, bag.*);
    try std.testing.expectEqual(@as(u32, 350), state.progress.money);
    state.tick(.{ .cancel = true });
    state.tick(.{ .cancel = true });
    try std.testing.expectEqual(.confirm_quit, state.phase);
    state.tick(.{ .confirm = true });
    try std.testing.expect(!state.quit_requested);
    state.tick(.{ .cancel = true });
    state.tick(.{ .left = true });
    state.tick(.{ .confirm = true });
    try std.testing.expect(state.quit_requested);
}

fn finishRound(state: *battle.State) !void {
    for (0..1000) |_| {
        state.tick(.{});
        if (state.phase != .resolving) return;
    }
    return error.RoundStuck;
}

test "Medicine commits once, leaves full HP untouched and survives later frames" {
    const content = try battle.load(allocator, @embedFile("fixtures/battle_trial.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    for ([_]u16{ 35, 100 }) |starting_hp| {
        var members: [2]battle.Member = undefined;
        var state = try battle.State.init(content.value, rules.value, &members, 17);
        members[0].hp = starting_hp;
        state.tick(.{ .confirm = true });
        try choose(&state, .item);
        state.tick(.{ .confirm = true });
        state.tick(.{ .confirm = true });
        try choose(&state, .attack);
        state.tick(.{ .confirm = true });
        state.tick(.{ .confirm = true });
        try finishRound(&state);
        try std.testing.expectEqual(@as(u16, 5), members[0].inventory.slots[0].?.uses);
        try std.testing.expectEqual(@as(u16, 100), members[0].hp);
        try std.testing.expectEqual(.victory, state.phase);
        for (0..500) |_| state.tick(.{});
        try std.testing.expectEqual(@as(u16, 5), members[0].inventory.slots[0].?.uses);
    }
}

test "all-defend can lose, skipped KO actors earn no EXP, and defeat can restart" {
    const content = try battle.load(allocator, @embedFile("fixtures/battle_trial.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [2]battle.Member = undefined;
    var state = try battle.State.init(content.value, rules.value, &members, 17);
    members[0].hp = 0;
    members[0].status = .unconscious;
    members[1].hp = 1;
    state.tick(.{ .confirm = true });
    try std.testing.expectEqual(@as(usize, 1), state.actor);
    for (0..10000) |_| {
        switch (state.phase) {
            .command => try choose(&state, .defend),
            .confirm_round => state.tick(.{ .confirm = true }),
            .resolving => state.tick(.{}),
            .defeat => break,
            else => return error.UnexpectedPhase,
        }
    }
    try std.testing.expectEqual(.defeat, state.phase);
    try std.testing.expectEqual(@as(u32, 350), state.progress.money);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0 }, characterFields("experience", state.progress.party)[0..2]);
    state.tick(.{ .confirm = true });
    try std.testing.expectEqual(.intro, state.phase);
    try std.testing.expectEqual(@as(u16, 100), members[0].hp);
    try std.testing.expectEqual(.healthy, members[0].status);
}

test "battle content rejects unknown enemies, bad rectangles and unsupported level gains" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/battle_trial.json"));
    defer parsed.deinit();
    var content = parsed.value;
    try content.validateAtlas(2048, 4096);
    try std.testing.expectError(error.InvalidBattleAssets, content.validateAtlas(1, 1));
    var encounters: [3]battle.Encounter = undefined;
    @memcpy(&encounters, content.encounters);
    content.encounters = &encounters;
    encounters[0].enemies = &.{"missing"};
    try std.testing.expectError(error.UnknownEnemy, content.validate());
    encounters[0] = parsed.value.encounters[0];
    encounters[0].experience_per_member = 1000;
    try std.testing.expectError(error.TrialRequiresLevelUp, content.validate());
    encounters[0] = parsed.value.encounters[0];
    var party: [2]battle.Profile = undefined;
    @memcpy(&party, content.party);
    content.party = &party;
    party[0].foot_offset_y = 513;
    try std.testing.expectError(error.InvalidBattleAssets, content.validate());
}

test "contact shadows stay at the feet and scale with ground depth rather than jump height" {
    const p = battle.presentation;
    const camera: p.Camera = .{ .transform = .{ .{ 1, 0, 0, 0 }, .{ 0, 0.5, 1, 0 }, .{ 0, 1, 0.5, 1000 } }, .focal_length = 1000, .center_x = 320, .center_y = 200 };
    const home: p.Vec3 = .{ .x = 100, .y = 0, .z = 0 };
    const idle = p.contactShadow(camera, home, home, 8, 1.5);
    try std.testing.expectApproxEqAbs(p.project(camera, home).y + 12, idle.point.y, 0.001);
    const ground: p.Vec3 = .{ .x = 20, .y = 500, .z = 0 };
    const landed = p.contactShadow(camera, home, ground, 8, 1.5);
    var airborne = ground;
    airborne.z = -100;
    const jumping = p.contactShadow(camera, home, airborne, 8, 1.5);
    try std.testing.expectEqual(landed, jumping);
    try std.testing.expectApproxEqAbs(idle.radius_x * 2 / 3, landed.radius_x, 0.001);
    try std.testing.expectApproxEqAbs(idle.radius_y * 2 / 3, landed.radius_y, 0.001);
    try std.testing.expect(jumping.point.y > p.project(camera, airborne).y);
}

test "optional enemy attack poses must also fit the actual atlas" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/battle_trial.json"));
    defer parsed.deinit();
    var content = parsed.value;
    var enemies: [2]battle.Profile = undefined;
    @memcpy(&enemies, content.enemies);
    content.enemies = &enemies;
    var attack = [_]battle.Frame{.{ .pose = .{ .rect = .{ .x = 2040, .y = 0, .w = 16, .h = 8 }, .anchor_x = 8, .anchor_y = 8 }, .ticks = 1 }};
    enemies[0].attack = &attack;
    try content.validate();
    try std.testing.expectError(error.InvalidBattleAssets, content.validateAtlas(2048, 4096));
}

test "projected leaps follow original party and enemy acceleration and fade cannot overflow" {
    const presentation = battle.presentation;
    const Row = struct { character: []const u8, source_offset: u32, start: presentation.Vec3, destination: presentation.Vec3, motion: presentation.Leap, samples: []const presentation.Vec3 };
    const parsed = try std.json.parseFromSlice([]const Row, allocator, @embedFile("fixtures/battle_motion.json"), .{});
    defer parsed.deinit();
    for (parsed.value) |row| {
        for (row.samples, 0..) |sample, tick| {
            const actual = presentation.leap(row.start, row.destination, row.motion, @intCast(tick));
            try std.testing.expectApproxEqAbs(sample.x, actual.x, 0.001);
            try std.testing.expectApproxEqAbs(sample.y, actual.y, 0.001);
            try std.testing.expectApproxEqAbs(sample.z, actual.z, 0.001);
        }
    }
    var previous: u8 = 255;
    for (0..65536) |tick| {
        const alpha = presentation.fadeAlpha(@intCast(tick));
        try std.testing.expect(alpha <= previous);
        previous = alpha;
    }
    try std.testing.expectEqual(@as(u8, 255), presentation.fadeAlpha(0));
    try std.testing.expectEqual(@as(u8, 0), presentation.fadeAlpha(32));
}

fn startThreeBonBons(state: *battle.State) void {
    state.phase = .victory;
    state.tick(.{ .confirm = true });
}
fn selectAttack(state: *battle.State, target: usize) !void {
    try choose(state, .attack);
    for (0..3) |_| {
        if (state.selection == target) break;
        state.tick(.{ .down = true });
    }
    try std.testing.expectEqual(target, state.selection);
    state.tick(.{ .confirm = true });
}

test "each party member keeps their selected BonBon through execution and only hits that target" {
    const content = try battle.load(allocator, @embedFile("fixtures/battle_trial.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    for (0..20) |seed| for (0..3) |hero_target| for (0..3) |gremio_target| {
        var members: [2]battle.Member = undefined;
        var state = try battle.State.init(content.value, rules.value, &members, seed);
        startThreeBonBons(&state);
        try selectAttack(&state, hero_target);
        try selectAttack(&state, gremio_target);
        try std.testing.expectEqual(hero_target, state.actions[0].?.attack);
        try std.testing.expectEqual(gremio_target, state.actions[1].?.attack);
        state.tick(.{ .confirm = true });
        var observed = false;
        for (0..1000) |_| {
            state.tick(.{});
            if (state.active) |effect| if (effect.actor == 1) {
                const expected = if (state.enemy_hp[gremio_target] > 0) gremio_target else blk: {
                    for (0..3) |index| if (state.enemy_hp[index] > 0) break :blk index;
                    return error.NoLivingBonBon;
                };
                try std.testing.expectEqual(expected + 2, effect.target);
                try std.testing.expectEqual(if (expected != gremio_target) @as(?usize, gremio_target + 2) else null, effect.retargeted_from);
                const before = state.enemy_hp;
                while (state.active != null) {
                    try std.testing.expectEqual(expected + 2, state.active.?.target);
                    state.tick(.{});
                }
                for (0..3) |index| {
                    const hp = if (index == expected) @as(u16, @intCast(@as(u32, before[index]) -| effect.amount)) else before[index];
                    try std.testing.expectEqual(hp, state.enemy_hp[index]);
                }
                observed = true;
                break;
            };
        }
        try std.testing.expect(observed);
    };
}

test "move and confirm together records the new target before choosing the next member" {
    const content = try battle.load(allocator, @embedFile("fixtures/battle_trial.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [2]battle.Member = undefined;
    var state = try battle.State.init(content.value, rules.value, &members, battle.trial_seed);
    startThreeBonBons(&state);
    try choose(&state, .attack);
    state.tick(.{ .down = true, .confirm = true });
    try std.testing.expectEqual(@as(usize, 1), state.actions[0].?.attack);
    try choose(&state, .attack);
    state.tick(.{ .up = true, .confirm = true });
    try std.testing.expectEqual(@as(usize, 2), state.actions[1].?.attack);
    try std.testing.expectEqual(.confirm_round, state.phase);
}

test "battle compatibility keeps explicit accepted versions and rejects schema gaps" {
    const legacy = try battle.load(allocator, @embedFile("fixtures/battle_trial.json"));
    defer legacy.deinit();
    try legacy.value.validate();
    const modern = try battle.load(allocator, @embedFile("fixtures/demo_batch.json"));
    defer modern.deinit();
    var content = modern.value;
    content.initial_party = &.{ "hero", "gremio", "pahn", "viktor", "camille", "tai_ho" };
    for ([_][]const u8{ "suikoden-battle-trial/5", "suikoden-battle-trial/6", "suikoden-battle-trial/7", "suikoden-battle-trial/8", "suikoden-battle-trial/9", "suikoden-battle-trial/10", "suikoden-battle-trial/11", "suikoden-battle-trial/12", "suikoden-battle-trial/13", "suikoden-battle-trial/14", "suikoden-battle-trial/15", "suikoden-battle-trial/16", "suikoden-battle-trial/17", "suikoden-battle-trial/18", "suikoden-battle-trial/19", "suikoden-battle-trial/20", "suikoden-battle-trial/21", "suikoden-battle-trial/22", "suikoden-battle-trial/23", "suikoden-battle-trial/24", "suikoden-battle-trial/25", "suikoden-battle-trial/26" }) |schema| {
        content.schema = schema;
        try content.validate();
    }
    for ([_][]const u8{ "", "suikoden-battle-trial/0", "suikoden-battle-trial/1", "suikoden-battle-trial/3", "suikoden-battle-trial/4", "suikoden-battle-trial/47", "suikoden-battle-trial/05", "suikoden-battle-trial/5/extra", "suikoden-battle-trial/5\x00" }) |schema| {
        content.schema = schema;
        try std.testing.expectError(error.UnsupportedBattleSchema, content.validate());
    }
    const bytes = try std.json.Stringify.valueAlloc(allocator, content, .{});
    defer allocator.free(bytes);
    try std.testing.expectError(error.UnsupportedBattleSchema, battle.load(allocator, bytes));
}

test "battle schema compatibility retains legacy systems and initial party requirements" {
    const modern = try battle.load(allocator, @embedFile("fixtures/demo_batch.json"));
    defer modern.deinit();
    var content = modern.value;
    content.schema = "suikoden-battle-trial/2";
    try std.testing.expectError(error.InvalidSystems, content.validate());
    content = modern.value;
    content.systems = null;
    try std.testing.expectError(error.InvalidSystems, content.validate());
    content = modern.value;
    content.schema = "suikoden-battle-trial/15";
    try std.testing.expectError(error.MissingInitialParty, content.validate());
    content.schema = "suikoden-battle-trial/14";
    try content.validate();
}

test "battle schemas retain version thirteen attack ready validation" {
    const modern = try battle.load(allocator, @embedFile("fixtures/demo_batch.json"));
    defer modern.deinit();
    var content = modern.value;
    const profiles = try allocator.dupe(battle.Profile, content.party);
    defer allocator.free(profiles);
    content.party = profiles;
    profiles[0].motion.?.ready_tick = null;
    content.schema = "suikoden-battle-trial/12";
    try content.validate();
    content.initial_party = &.{ "hero", "gremio", "pahn", "viktor", "camille", "tai_ho" };
    for ([_][]const u8{ "suikoden-battle-trial/13", "suikoden-battle-trial/14", "suikoden-battle-trial/15", "suikoden-battle-trial/16", "suikoden-battle-trial/17", "suikoden-battle-trial/18", "suikoden-battle-trial/19", "suikoden-battle-trial/20", "suikoden-battle-trial/21", "suikoden-battle-trial/22", "suikoden-battle-trial/23", "suikoden-battle-trial/24", "suikoden-battle-trial/25", "suikoden-battle-trial/26" }) |schema| {
        content.schema = schema;
        try std.testing.expectError(error.MissingAttackReady, content.validate());
    }
}

test "ground mesh validates its vertex and tile dimensions" {
    const vertices = [_]battle.Position{
        .{ .x = -64, .y = -64, .z = 0 }, .{ .x = 0, .y = -64, .z = 0 },
        .{ .x = -64, .y = 0, .z = 0 },   .{ .x = 0, .y = 0, .z = 0 },
        .{ .x = -64, .y = 64, .z = 0 },  .{ .x = 0, .y = 64, .z = 0 },
    };
    const tiles = [_]u8{ 0, 1 };
    const ground = battle.Ground{ .across = 1, .down = 2, .vertices = &vertices, .tiles = &tiles };
    try ground.validate();
    try std.testing.expectError(error.InvalidBattleGround, (battle.Ground{ .across = 2, .down = 2, .vertices = &vertices, .tiles = &tiles }).validate());
    try std.testing.expectEqual(@as(?usize, 1), ground.tileColumns(32, 64));
    try std.testing.expectEqual(@as(?usize, 16), ground.tileColumns(512, 512));
    try std.testing.expectEqual(@as(?usize, null), ground.tileColumns(32, 32));
    try std.testing.expectEqual(@as(?usize, null), ground.tileColumns(320, 240));
    try std.testing.expectEqual(@as(?usize, null), ground.tileColumns(0, 32));
    try std.testing.expectEqual(@as(?usize, null), ground.tileColumns(-32, 32));
}

test "battlefields select ground atlas regions and scenery per encounter" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_unites_battle.json"));
    defer parsed.deinit();
    const ground = parsed.value.ground.?;
    var encounters = parsed.value.encounters[0..3].*;
    encounters[0].battlefield = "plain";
    encounters[1].battlefield = "trees";
    var battlefields = [_]battle.Battlefield{
        .{ .id = "plain", .ground = ground, .ground_atlas = .{ .x = 0, .y = 0, .w = 512, .h = 512 } },
        .{ .id = "trees", .ground = ground, .ground_atlas = .{ .x = 512, .y = 0, .w = 512, .h = 512 }, .scenery = parsed.value.scenery[0..1] },
    };
    var content = parsed.value;
    content.encounters = &encounters;
    content.battlefields = &battlefields;
    content.schema = "suikoden-battle-trial/43";
    try std.testing.expectError(error.UnsupportedBattleSchema, content.validate());
    content.schema = "suikoden-battle-trial/44";
    try content.validate();
    try content.validateGroundAtlas(1024, 512);
    try std.testing.expectError(error.InvalidBattleGroundAtlas, content.validateGroundAtlas(512, 512));
    encounters[2].battlefield = "missing";
    try std.testing.expectError(error.UnknownBattlefield, content.validate());
    encounters[2].battlefield = null;
    battlefields[1].ground_atlas.x = 513;
    try std.testing.expectError(error.InvalidBattleGroundAtlas, content.validate());
    battlefields[1].ground_atlas.x = 512;

    const bytes = try std.json.Stringify.valueAlloc(allocator, content, .{});
    defer allocator.free(bytes);
    const imported = try battle.load(allocator, bytes);
    defer imported.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(imported.value, rules.value, &members, 17);
    try std.testing.expectEqual(@as(i32, 0), battle.layout.battlefield(&state).?.ground_atlas.x);
    try std.testing.expectEqual(@as(usize, 0), battle.layout.scenery(&state).len);
    state.encounter = 1;
    state.startEncounter();
    try std.testing.expectEqual(@as(i32, 512), battle.layout.battlefield(&state).?.ground_atlas.x);
    try std.testing.expectEqualDeep(imported.value.scenery[0..1], battle.layout.scenery(&state));
    state.encounter = 2;
    state.startEncounter();
    try std.testing.expect(battle.layout.battlefield(&state) == null);
    try std.testing.expectEqualDeep(imported.value.scenery, battle.layout.scenery(&state));
    state.restart();
    try std.testing.expectEqualStrings("plain", battle.layout.battlefield(&state).?.id);
}

test "battle fixtures carry the source 2x3 party table" {
    const content = try battle.load(allocator, @embedFile("fixtures/battle_trial.json"));
    defer content.deinit();
    const source = [_][3]f32{
        .{ 120, 50, 0 }, .{ 112, 0, 0 },  .{ 120, -50, 0 },
        .{ 192, 75, 0 }, .{ 178, 25, 0 }, .{ 178, -25, 0 },
    };
    for (content.value.formation_slots, source) |slot, want| {
        try std.testing.expectEqual(want[0], slot.x);
        try std.testing.expectEqual(want[1], slot.y);
        try std.testing.expectEqual(want[2], slot.z);
    }
}

test "battle camera ticks change the actor scale and settle" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/battle_trial.json"));
    defer parsed.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [2]battle.Member = undefined;
    var state = try battle.State.init(parsed.value, rules.value, &members, 17);
    state.camera_ticks = 0;
    const intro = battle.layout.actorLayout(state, 0).scale;
    state.camera_ticks = 200;
    const settled = battle.layout.actorLayout(state, 0).scale;
    try std.testing.expect(intro > settled);
    try std.testing.expectApproxEqAbs(@as(f32, 2.375), intro, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.875), settled, 0.001);
}

test "source enemy table occupies the leading roster slots" {
    const content = try battle.load(allocator, @embedFile("fixtures/battle_trial.json"));
    defer content.deinit();
    const encounter = content.value.encounters[1];
    const expected = [_][3]f32{ .{ -128, 0, 0 }, .{ -128, -50, 0 }, .{ -128, 50, 0 } };
    try std.testing.expectEqual(@as(usize, 3), encounter.positions.len);
    for (encounter.positions, expected) |position, want| {
        try std.testing.expectEqual(want[0], position.x);
        try std.testing.expectEqual(want[1], position.y);
        try std.testing.expectEqual(want[2], position.z);
    }
}

test "canonical Firestorm applies damage to an enemy" {
    const content = try battle.load(allocator, @embedFile("fixtures/battle_canonical.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(content.value, rules.value, &members, 17);
    state.progress.party.at(0).rune = 0;
    state.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    state.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    const enemy = state.partyCount();
    const before = state.hp(enemy);
    var effect = battle.Effect{ .actor = 0, .target = enemy, .kind = .cast, .spell = 1 };
    state.applySpell(&effect);
    try std.testing.expect(effect.amounts[enemy] > 0);
    try std.testing.expect(state.hp(enemy) < before);
}

test "canonical Drops of Kindness heals an ally and spends a charge" {
    const content = try battle.load(allocator, @embedFile("fixtures/battle_canonical.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(content.value, rules.value, &members, 17);
    state.progress.party.at(0).rune = 1;
    state.progress.party.at(0).rune_charges = .{ 9, 0, 0, 0 };
    state.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    for (state.progress.party.items()) |member| member.hp = member.max_hp;
    state.choose(0);
    try choose(&state, .rune);
    try std.testing.expect(!state.canSelectSpell(2));
    state.tick(.{ .confirm = true });
    try std.testing.expectEqual(.spell, state.phase);

    state.progress.party.at(1).hp = 1;
    state.progress.party.at(2).hp = 0;
    state.progress.party.at(2).status = .unconscious;
    state.progress.party.at(3).hp = 1;
    state.tick(.{ .confirm = true });
    try std.testing.expectEqual(.spell_target, state.phase);
    try std.testing.expectEqual(@as(usize, 1), state.selection);
    state.tick(.{ .right = true });
    try std.testing.expectEqual(@as(usize, 3), state.selection);
    state.progress.party.at(3).hp = state.progress.party.at(3).max_hp;
    state.tick(.{ .confirm = true });
    try std.testing.expectEqual(.spell_target, state.phase);
    try std.testing.expect(state.actions[0] == null);
    try std.testing.expectEqual(@as(usize, 1), state.selection);
    state.tick(.{ .confirm = true });
    const queued = state.actions[0].?.spell;
    var effect = battle.Effect{ .actor = 0, .target = queued.target, .kind = .cast, .spell = queued.index };
    state.applySpell(&effect);
    try std.testing.expect(state.hp(1) > 1);
    try std.testing.expectEqual(@as(u8, 8), state.progress.party.at(0).rune_charges[0]);
}

test "every canonical damage spell applies damage through its rune" {
    const content = try battle.load(allocator, @embedFile("fixtures/battle_canonical.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    const systems = content.value.systems.?;
    for (systems.spells, 0..) |spell, spell_index| {
        if (spell.kind != .damage) continue;
        var rune_index: ?usize = null;
        for (systems.runes, 0..) |rune, index| {
            for (rune.spells) |slot| if (slot == spell_index) {
                rune_index = index;
                break;
            };
            if (rune_index != null) break;
        }
        try std.testing.expect(rune_index != null);
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(content.value, rules.value, &members, 17);
        state.progress.party.at(0).rune = rune_index;
        state.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
        state.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
        const target = state.partyCount();
        const before = state.hp(target);
        var effect = battle.Effect{ .actor = 0, .target = target, .kind = .cast, .spell = spell_index };
        state.applySpell(&effect);
        try std.testing.expect(effect.amounts[target] > 0);
        try std.testing.expect(state.hp(target) < before);
    }
}

test "every canonical non-damage spell connects and spends a charge" {
    const content = try battle.load(allocator, @embedFile("fixtures/battle_canonical.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    const systems = content.value.systems.?;
    for (systems.spells, 0..) |spell, spell_index| {
        if (spell.kind == .damage or spell.kind == .source_rule) continue;
        var rune_index: ?usize = null;
        for (systems.runes, 0..) |rune, index| {
            for (rune.spells) |slot| if (slot == spell_index) {
                rune_index = index;
                break;
            };
            if (rune_index != null) break;
        }
        try std.testing.expect(rune_index != null);
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(content.value, rules.value, &members, 17);
        state.progress.party.at(0).rune = rune_index;
        state.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
        state.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
        state.progress.party.at(0).hp = 1;
        const target = if (spell.allies) 0 else state.partyCount();
        var effect = battle.Effect{ .actor = 0, .target = target, .kind = .cast, .spell = spell_index };
        state.applySpell(&effect);
        try std.testing.expect(effect.affected != 0);
        var remaining: u16 = 0;
        for (state.progress.party.at(0).rune_charges) |charge| remaining += charge;
        try std.testing.expectEqual(@as(u16, 35), remaining);
    }
}

test "canonical party resolves a unite pair and partner" {
    const content = try battle.load(allocator, @embedFile("fixtures/battle_canonical.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(content.value, rules.value, &members, 17);
    const definition = state.uniteDefinition(2);
    try std.testing.expect(definition != null);
    const partner = state.unitePartner(2);
    try std.testing.expect(partner != null);
    try std.testing.expectEqual(@as(usize, 1), partner.?);
    try std.testing.expect(state.canUnite(2));
}

test "canonical Fisherman additional unite resolves its pair" {
    const content = try battle.load(allocator, @embedFile("fixtures/battle_canonical.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(content.value, rules.value, &members, 17);
    const definition = state.uniteDefinition(5);
    try std.testing.expect(definition != null);
    try std.testing.expectEqualStrings("Fisherman attack", definition.?.name);
    try std.testing.expectEqual(@as(?usize, 4), state.unitePartner(5));
    try std.testing.expect(state.canUnite(5));
}

test "magic rune selector follows the source table" {
    const rules = @import("battle").systems;
    try std.testing.expectEqual(@as(?u8, 7), rules.magicRuneSelector(1, 0));
    try std.testing.expectEqual(@as(?u8, 1), rules.magicRuneSelector(27, 0));
    try std.testing.expectEqual(@as(?u8, 4), rules.magicRuneSelector(31, 0));
    try std.testing.expectEqual(@as(?u8, 3), rules.magicRuneSelector(8, 3));
    try std.testing.expectEqual(@as(u32, 50), rules.magicSelectorDamage(100, 7, 0));
    try std.testing.expectEqual(@as(u32, 100), rules.magicSelectorDamage(100, 2, 5));
    try std.testing.expectEqual(@as(u32, 50), rules.magicSelectorDamage(100, 2, 2));
}

test "source-rule spell vocabulary requires battle schema sixteen" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/battle_canonical.json"));
    defer parsed.deinit();
    var content = parsed.value;
    content.schema = "suikoden-battle-trial/15";
    try std.testing.expectError(error.UnsupportedBattleSchema, content.validate());
}

test "cast camera and sprite start at the same local tick late in a round" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/battle_canonical.json"));
    defer parsed.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var early = try battle.State.init(parsed.value, rules.value, &members, 17);
    early.camera_ticks = 300;
    early.active = .{ .actor = 0, .target = early.partyCount(), .kind = .cast, .spell = 0 };
    var late = early;
    late.active.?.started_at = 400;
    for ([_]u16{ 0, 1, 8, 19, 20, 35 }) |tick| {
        early.action_ticks = tick;
        late.action_ticks = 400 + tick;
        for (0..early.partyCount() + early.enemyCount()) |actor| {
            try std.testing.expectEqualDeep(battle.layout.actorLayout(early, actor), battle.layout.actorLayout(late, actor));
        }
        try std.testing.expectEqualDeep(battle.layout.bounds(early), battle.layout.bounds(late));
    }
}

test "world drawing and overlays share the action camera at early and late dispatch" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/battle_canonical.json"));
    defer parsed.deinit();
    const art = try std.json.parseFromSlice(battle.world_art.Data, allocator, @embedFile("fixtures/world_roc_art.json"), .{});
    defer art.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(parsed.value, rules.value, &members, 17);
    // Compose this display fixture with a cast; combat rules remain outside this layout check.
    state.content.world_art = art.value;
    state.camera_ticks = 300;
    state.active = .{ .actor = 0, .target = 6, .kind = .cast, .spell = 0, .started_at = 400 };
    state.action_ticks = 407;
    const scene = battle.layout.sceneArt(state);
    for (0..6) |actor| {
        const drawn = battle.world_art.actorLayout(scene, state, actor);
        const overlay = battle.layout.actorLayout(state, actor);
        try std.testing.expectEqualDeep(drawn.point, overlay.point);
        try std.testing.expectEqualDeep(drawn.sprite, overlay.sprite);
        try std.testing.expectEqual(drawn.scale, overlay.scale);
    }
    state.active.?.started_at = 0;
    state.action_ticks = 7;
    try std.testing.expectEqualDeep(scene.camera, battle.layout.sceneArt(state).camera);
}

test "native Drops geometry agrees with independently exported source vectors" {
    const Command = struct { index: usize, texture: ?u8, vertices: []const battle.drops.Point, depth: i32, intensity: u8 };
    const Case = struct { update: u16, camera: [12]i32, command_count: usize, commands: []const Command, wash: [3]u8 };
    const Vectors = struct { draws: [18]u15, caster: [3]i32, target: [3]i32, cases: []const Case };
    const vectors = try std.json.parseFromSlice(Vectors, allocator, @embedFile("fixtures/drops_geometry.json"), .{});
    defer vectors.deinit();
    const art = drops_art_fixture;
    try art.validate(128, 64);
    var invalid = art;
    invalid.schema = "unknown";
    try std.testing.expectError(error.InvalidDropsArt, invalid.validate(128, 64));
    invalid = art;
    invalid.entries[0].y = 1;
    try std.testing.expectError(error.InvalidDropsArt, invalid.validate(128, 64));
    invalid = art;
    invalid.entries[1].w = 64;
    try std.testing.expectError(error.InvalidDropsArt, invalid.validate(128, 64));
    for (vectors.value.cases) |case| {
        const block = battle.drops.cameraAt(case.update);
        const flat = block.focus ++ block.angles ++ block.translation ++ block.scale;
        try std.testing.expectEqualDeep(case.camera, flat);
        const frame = battle.drops.frameAt(art, case.update, vectors.value.draws, vectors.value.caster, vectors.value.target);
        try std.testing.expectEqual(case.command_count, frame.count);
        try std.testing.expectEqualDeep(case.wash, frame.wash);
        for (case.commands) |command| {
            const actual = frame.commands[command.index];
            try std.testing.expectEqual(command.texture, actual.texture);
            try std.testing.expectEqual(command.depth, actual.depth);
            try std.testing.expectEqual(command.intensity, actual.intensity);
            for (command.vertices, 0..) |vertex, i| {
                try std.testing.expectApproxEqAbs(vertex.x, actual.vertices[i].x, 0.01);
                try std.testing.expectApproxEqAbs(vertex.y, actual.vertices[i].y, 0.01);
            }
        }
    }
}

test "review Drops spends its visual draws at start and heals only at callback306" {
    const content = try battle.load(allocator, @embedFile("fixtures/battle_canonical.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(content.value, rules.value, &members, 17);
    state.drops_art = drops_art_fixture;
    state.progress.party.at(0).rune = 1;
    state.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    state.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    state.progress.party.at(1).hp = 35;
    state.actions = @splat(.defend);
    state.actions[0] = .{ .spell = .{ .index = 2, .target = 1 } };
    state.acted = @splat(true);
    state.acted[0] = false;
    state.phase = .resolving;
    const tape: [64]u15 = @splat(100);
    var draws = battle.systems.Draws{ .values = &tape };
    state.replay_draws = &draws;
    state.nextAction();
    state.replay_draws = null;
    try std.testing.expect(state.hasDrops());
    try std.testing.expectEqual(@as(usize, 19), draws.cursor);
    try std.testing.expectEqual(@as(u16, 306), state.impactTick());
    try std.testing.expectEqual(@as(u16, 307), state.actionDuration());
    for (0..310) |_| {
        if (state.active == null) break;
        const tick = state.effectTicks();
        if (tick < 306) try std.testing.expectEqual(@as(u16, 35), state.hp(1));
        if (tick == 100) {
            const base = battle.layout.currentCamera(state);
            const original = state.dropsFrame();
            state.enemy_magic_pulse = .{ .issued_at = state.camera_ticks -% 1, .delta_q12 = 5 * 4096 };
            var pulsed = base;
            pulsed.focus[2] += 5;
            try std.testing.expectEqualDeep(pulsed, battle.layout.worldProjection(&state).drops);
            try std.testing.expectEqualDeep(base, battle.layout.cameraForTransition(&state));
            try std.testing.expect(!std.meta.eql(original.commands[0].vertices, state.dropsFrame().commands[0].vertices));
        }
        state.tick(.{});
    }
    try std.testing.expect(state.hp(1) > 35);
    try std.testing.expectEqual(@as(u8, 8), state.progress.party.at(0).rune_charges[0]);
}

test "exhausted Drops setup draws roll back the action before any charge or HP change" {
    const content = try battle.load(allocator, @embedFile("fixtures/battle_canonical.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(content.value, rules.value, &members, 17);
    state.drops_art = drops_art_fixture;
    state.progress.party.at(0).rune = 1;
    state.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    state.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    state.progress.party.at(1).hp = 35;
    state.actions = @splat(.defend);
    state.actions[0] = .{ .spell = .{ .index = 2, .target = 1 } };
    state.acted = @splat(true);
    state.acted[0] = false;
    state.phase = .resolving;
    const tape: [18]u15 = @splat(100);
    var draws = battle.systems.Draws{ .values = &tape };
    try std.testing.expectError(error.RandomInputExhausted, state.tickReplay(.{}, &draws));
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    try std.testing.expectEqual(@as(u16, 35), state.hp(1));
    try std.testing.expectEqual(@as(u8, 9), state.progress.party.at(0).rune_charges[0]);
    try std.testing.expect(state.active == null);
}

test "portable scene library imports33 art records and refuses untraced choreography" {
    const packet = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer packet.deinit();
    try std.testing.expectEqual(@as(usize, 33), packet.value.spells.len);
    try std.testing.expect(packet.value.indexOf("spell_1") != null);
    try std.testing.expect(packet.value.indexOf("spell_9") != null);
    try std.testing.expect(packet.value.indexOf("spell_2") != null);
    try std.testing.expect(packet.value.indexOf("spell_10") != null);
    try std.testing.expect(packet.value.indexOf("spell_11") != null);
    try std.testing.expect(packet.value.indexOf("spell_4") != null);
    try std.testing.expect(packet.value.indexOf("spell_26") != null);
    try std.testing.expect(packet.value.indexOf("spell_27") != null);
    try std.testing.expect(packet.value.indexOf("spell_5") != null);
    for (packet.value.spells) |spell| if (spell.program == null) {
        try std.testing.expectEqualStrings("object_choreography_not_exported", spell.blocker.?);
    };
}

test "portable scene programs match independent Python geometry and BIOS draws" {
    const C = struct { index: usize, texture: ?u16, vertices: []const [2]f32, depth: i32 };
    const Case = struct { target_height: u16 = 0, target_center: [2]i32 = .{ 0, 0 }, target_idle_center: [2]i32 = .{ 0, 0 }, party: []const struct { position: [3]i32 } = &.{}, spell: []const u8, update: u16, caster: [3]i32, target: [3]i32, targets: []const struct { formation_slot: ?u8 = null, position: [3]i32, center: [2]i32 }, draw_count: usize, camera: [12]i32, wash: [3]u8, count: usize, commands: []const C };
    const Vectors = struct { seed: u32, cases: []const Case };
    const vectors = try std.json.parseFromSlice(Vectors, allocator, @embedFile("fixtures/spell_scene_geometry.json"), .{});
    defer vectors.deinit();
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    const packet = &parsed.value;
    var draws = battle.systems.Draws{ .bios_state = vectors.value.seed };
    var instance: ?battle.spell_scene.Instance = null;
    for (vectors.value.cases) |case| {
        const index = packet.indexOf(case.spell).?;
        if (instance == null or instance.?.spell != index) {
            draws = .{ .bios_state = vectors.value.seed };
            var party: [6]battle.spell_scene.Target = undefined;
            for (case.party, 0..) |member, slot| party[slot] = .{ .position = member.position };
            instance = try battle.spell_scene.Instance.beginForParty(packet, index, case.caster, case.target, battle.drops.initial_camera, &draws, party[0..case.party.len]);
        }
        instance.?.target_height = case.target_height;
        instance.?.target_center = case.target_center;
        instance.?.target_idle_center = case.target_idle_center;
        instance.?.target_count = @intCast(case.targets.len);
        for (case.targets, 0..) |target, i| instance.?.targets[i] = .{ .formation_slot = target.formation_slot, .position = target.position, .center = target.center };
        try instance.?.advance(packet, case.update, &draws);
        try std.testing.expectEqual(case.draw_count, draws.cursor);
        const cam = battle.spell_scene.instanceCameraAt(packet.spells[index].program.?, &instance.?, case.update);
        try std.testing.expectEqualDeep(case.camera, cam.focus ++ cam.angles ++ cam.translation ++ cam.scale);
        const frame = battle.spell_scene.frameAt(packet, &instance.?, case.update);
        try std.testing.expectEqual(case.count, frame.count);
        try std.testing.expectEqualDeep(case.wash, frame.wash);
        for (case.commands) |expected| {
            const actual = frame.commands[expected.index];
            try std.testing.expectEqual(expected.texture, actual.texture);
            try std.testing.expectEqual(expected.depth, actual.depth);
            try std.testing.expectEqual(expected.vertices.len, actual.count);
            for (expected.vertices, 0..) |xy, i| {
                errdefer std.debug.print("spell={s} update={d} command={d} vertex={d}\n", .{ case.spell, case.update, expected.index, i });
                try std.testing.expectApproxEqAbs(xy[0], actual.vertices[i].x, 0.01);
                try std.testing.expectApproxEqAbs(xy[1], actual.vertices[i].y, 0.01);
            }
        }
        const actor = @import("battle_camera").projectScene(cam, case.target, .{}).?;
        const effect = battle.drops.project(cam, case.target);
        try std.testing.expectEqualDeep(actor, effect);
    }
}

test "scene parser rejects bad atlas paths dimensions and unsafe program data" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    packet.atlas = "../actors.png";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    packet = parsed.value;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(1, 1));
    var hurt = [_]battle.spell_scene.HurtPose{.{ .id = "bad", .entry = 4095 }};
    packet.hurt_poses = &hurt;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    packet = parsed.value;
    const spells = try allocator.dupe(battle.spell_scene.Spell, packet.spells);
    defer allocator.free(spells);
    packet.spells = spells;
    spells[0].program.?.initial_draws = 129;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[0] = parsed.value.spells[0];
    var events = [_]battle.spell_scene.CameraEvent{spells[0].program.?.cameras[0]};
    spells[0].program.?.cameras = &events;
    events[0].target.translation[2] = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    events[0].target.translation[2] = 1;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "Flaming particle replay exhaustion rolls back time RNG and game state" {
    const content = try battle.load(allocator, @embedFile("fixtures/battle_canonical.json"));
    defer content.deinit();
    const packet = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer packet.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(content.value, rules.value, &members, 17);
    try state.attachSpellScenes(&packet.value);
    const id = packet.value.indexOf("spell_1").?;
    var setup = battle.systems.Draws{ .bios_state = 17 };
    const instance = try battle.spell_scene.Instance.begin(&packet.value, id, .{ 120, 50, 0 }, .{ -120, 40, 0 }, battle.drops.initial_camera, &setup);
    state.phase = .resolving;
    state.active = .{ .actor = 0, .target = state.partyCount(), .kind = .cast, .spell = 0, .scene = instance };
    state.action_ticks = 64;
    const before = state;
    const tape: [79]u15 = @splat(100);
    var draws = battle.systems.Draws{ .values = &tape };
    try std.testing.expectError(error.RandomInputExhausted, state.tickReplay(.{}, &draws));
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    try std.testing.expectEqual(before.action_ticks, state.action_ticks);
    try std.testing.expectEqualDeep(before.active, state.active);
    try std.testing.expectEqualDeep(before.progress, state.progress);
}

test "imported spells dispatch normally apply once at source impact and return the camera" {
    const content = try battle.load(allocator, @embedFile("fixtures/battle_canonical.json"));
    defer content.deinit();
    const packet = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer packet.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    for ([_]usize{ 0, 2 }) |spell| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(content.value, rules.value, &members, 17);
        try state.attachSpellScenes(&packet.value);
        state.progress.party.at(0).rune = if (spell == 0) 0 else 1;
        state.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
        state.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
        state.progress.party.at(1).hp = 35;
        const target = if (spell == 0) state.partyCount() else 1;
        const hp = state.hp(target);
        state.actions = @splat(.defend);
        state.actions[0] = .{ .spell = .{ .index = spell, .target = if (spell == 0) 0 else 1 } };
        state.acted = @splat(true);
        state.acted[0] = false;
        state.phase = .resolving;
        state.nextAction();
        try std.testing.expect(state.hasSpellScene());
        const impact = state.impactTick();
        try std.testing.expectEqual(@as(u16, if (spell == 0) 294 else 306), impact);
        while (state.active != null) {
            if (state.effectTicks() < impact) try std.testing.expectEqual(hp, state.hp(target));
            state.tick(.{});
        }
        try std.testing.expect(if (spell == 0) state.hp(target) < hp else state.hp(target) > hp);
        try std.testing.expectEqual(@as(u8, 8), state.progress.party.at(0).rune_charges[0]);
        const after = state.hp(target);
        state.enterRoundMenu();
        state.camera_ticks += 30;
        try std.testing.expectEqualDeep(battle.drops.initial_camera, battle.layout.currentCamera(state));
        for (0..10) |_| state.tick(.{});
        try std.testing.expectEqual(after, state.hp(target));
    }
}

test "Flaming target recoil starts with the burst before damage and leaves other actors alone" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/battle_canonical.json"));
    defer parsed.deinit();
    const packet = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer packet.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(parsed.value, rules.value, &members, 17);
    try state.attachSpellScenes(&packet.value);
    var draws = battle.systems.Draws{ .bios_state = 17 };
    const scene = try battle.spell_scene.Instance.begin(&packet.value, packet.value.indexOf("spell_1").?, .{ 120, 50, 0 }, .{ -128, 0, 0 }, battle.drops.initial_camera, &draws);
    state.active = .{ .actor = 0, .target = state.partyCount(), .kind = .cast, .spell = 0, .scene = scene };
    const hp = state.hp(state.partyCount());
    state.action_ticks = 224;
    try std.testing.expect(state.spellReaction(state.partyCount()) == null);
    for ([_]u16{ 225, 226, 227, 231, 232, 236, 237, 247, 252, 257, 260 }) |tick| {
        state.action_ticks = tick;
        const reaction = state.spellReaction(state.partyCount()).?;
        const expected: [2]i16 = if (tick < 227) .{ 0, 0 } else if (tick >= 257) .{ 0, 5 } else if (((tick - 227) / 5) % 2 == 0) .{ -5, 0 } else .{ 0, 5 };
        try std.testing.expectEqualDeep(expected, reaction.offset);
        try std.testing.expect(reaction.entry != null);
        try std.testing.expect(state.spellReaction(0) == null);
        const layout = battle.layout.actorLayout(state, state.partyCount());
        const entry = packet.value.entries[reaction.entry.?];
        const home = battle.layout.position(state, state.partyCount());
        try std.testing.expectApproxEqAbs(home.x + @as(f32, if (expected[0] < 0) -10 else 0), layout.point.x, 0.01);
        try std.testing.expectApproxEqAbs(home.y + @as(f32, if (expected[1] > 0) 10 else 0), layout.point.y, 0.01);
        try std.testing.expectEqual(entry.x, layout.sprite.rect.x);
        try std.testing.expectEqual(-entry.dx, layout.sprite.anchor_x);
        try std.testing.expectEqual(hp, state.hp(state.partyCount()));
    }
    state.action_ticks = 261;
    try std.testing.expect(state.spellReaction(state.partyCount()) == null);
    state.active.?.scene.?.spell = packet.value.indexOf("spell_9").?;
    state.action_ticks = 225;
    try std.testing.expect(state.spellReaction(state.partyCount()) == null);
}

test "imported hit palettes cycle and restore without changing recoil or random state" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    const packet = &parsed.value;
    var draws = battle.systems.Draws{ .bios_state = 17 };
    const instance = try battle.spell_scene.Instance.begin(packet, packet.indexOf("spell_1").?, .{ 120, 50, 0 }, .{ -128, 0, 0 }, battle.drops.initial_camera, &draws);
    const pose = packet.hurt_poses[0];
    const Case = struct { tick: u16, palette: ?u8 };
    for ([_]Case{ .{ .tick = 225, .palette = null }, .{ .tick = 226, .palette = 0 }, .{ .tick = 228, .palette = 0 }, .{ .tick = 229, .palette = 1 }, .{ .tick = 232, .palette = 1 }, .{ .tick = 233, .palette = 2 }, .{ .tick = 236, .palette = 2 }, .{ .tick = 237, .palette = 0 }, .{ .tick = 256, .palette = 1 }, .{ .tick = 257, .palette = null }, .{ .tick = 260, .palette = null } }) |case| {
        const reaction = battle.spell_scene.reactionAt(packet, &instance, case.tick, pose.id).?;
        try std.testing.expectEqual(if (case.palette) |index| pose.flash_entries.?[index] else pose.entry, reaction.entry.?);
    }
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    var invalid = parsed.value;
    const poses = try allocator.dupe(battle.spell_scene.HurtPose, packet.hurt_poses);
    defer allocator.free(poses);
    poses[0].flash_entries.?[0] = 4095;
    invalid.hurt_poses = poses;
    try std.testing.expectError(error.InvalidSpellScenes, invalid.validate(4096, 4096));
    poses[0] = packet.hurt_poses[0];
    poses[0].flash_entries.?[0] = packet.hurt_poses[1].entry;
    try std.testing.expectError(error.InvalidSpellScenes, invalid.validate(4096, 4096));
    invalid = parsed.value;
    const spells = try allocator.dupe(battle.spell_scene.Spell, packet.spells);
    defer allocator.free(spells);
    invalid.spells = spells;
    var frames: [36]?u8 = @splat(null);
    frames[0] = 7;
    spells[0].program.?.reaction.?.flash_frames = &frames;
    try std.testing.expectError(error.InvalidSpellScenes, invalid.validate(4096, 4096));
}

test "Firestorm captures only living enemies and hits each once after group recoil" {
    const content = try battle.load(allocator, @embedFile("fixtures/battle_canonical.json"));
    defer content.deinit();
    const packet = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer packet.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(content.value, rules.value, &members, 17);
    for (state.content.encounters, 0..) |encounter, i| if (encounter.enemies.len >= 3) {
        state.encounter = i;
        state.startEncounter();
        break;
    };
    try std.testing.expect(state.enemyCount() >= 3);
    try state.attachSpellScenes(&packet.value);
    state.enemy_hp[0] = 0;
    for (1..state.enemyCount()) |index| state.enemy_hp[index] = 1;
    state.progress.party.at(0).rune = 0;
    state.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    state.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    state.actions = @splat(.defend);
    state.actions[0] = .{ .spell = .{ .index = 1, .target = 0 } };
    state.acted = @splat(true);
    state.acted[0] = false;
    state.phase = .resolving;
    const before = state.enemy_hp;
    state.nextAction();
    try std.testing.expect(state.hasSpellScene());
    try std.testing.expectEqual(state.enemyCount() - 1, state.active.?.scene.?.target_count);
    try std.testing.expectEqual(state.partyCount() + 1, state.active.?.target);
    try std.testing.expectEqual(@as(u16, 369), state.impactTick());
    try std.testing.expectEqual(@as(u16, 434), state.actionDuration());
    while (state.active != null and state.effectTicks() < 369) {
        const tick = state.effectTicks();
        try std.testing.expectEqualDeep(before, state.enemy_hp);
        try std.testing.expect(state.spellReaction(state.partyCount()) == null);
        for (1..state.enemyCount()) |enemy| {
            const reaction = state.spellReaction(state.partyCount() + enemy);
            try std.testing.expectEqual(tick >= 337, reaction != null);
        }
        state.tick(.{});
    }
    try std.testing.expectEqual(@as(u16, 465), state.actionDuration());
    while (state.active != null) {
        const tick = state.effectTicks();
        const response = state.spellReaction(state.partyCount() + 1).?;
        if (tick == 370) try std.testing.expectEqual(@as(u8, 1), response.animation);
        if (tick == 371) {
            try std.testing.expectEqual(@as(u8, 1), response.animation);
            try std.testing.expectEqualDeep([2]i16{ 0, 5 }, response.offset);
        }
        if (tick == 372) try std.testing.expectEqual(@as(u8, 3), response.animation);
        if (tick == 373) try std.testing.expectEqual(battle.spell_scene.Blend.subtractive, response.blend);
        if (tick == 374) try std.testing.expectEqual(@as(u8, 126), response.tint);
        try std.testing.expect(state.replay_unsupported == null);
        state.tick(.{});
    }
    try std.testing.expectEqual(@as(u16, 465), state.action_ticks);
    try std.testing.expectEqual(@as(u16, 0), state.enemy_hp[0]);
    for (1..state.enemyCount()) |enemy| try std.testing.expect(state.enemy_hp[enemy] < before[enemy]);
    try std.testing.expectEqual(@as(u8, 8), state.progress.party.at(0).rune_charges[1]);
    try std.testing.expectEqual(@as(u8, 9), state.progress.party.at(0).rune_charges[0]);
    const after = state.enemy_hp;
    for (0..10) |_| state.tick(.{});
    try std.testing.expectEqualDeep(after, state.enemy_hp);
}

test "spell KO data validates and preserves the source busy release boundary" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    const packet = parsed.value;
    const flaming = packet.spells[packet.indexOf("spell_1").?].program.?;
    const firestorm = packet.spells[packet.indexOf("spell_2").?].program.?;
    try std.testing.expectEqual(@as(u16, 294), battle.spell_scene.knockoutStart(flaming));
    try std.testing.expectEqual(@as(u16, 371), battle.spell_scene.knockoutStart(firestorm));
    const hurt = packet.hurt_poses[0];
    const start = battle.spell_scene.knockoutAt(hurt, firestorm, 0).?;
    try std.testing.expectEqual(hurt.entry, start.entry.?);
    try std.testing.expectEqualDeep([2]i16{ 0, 5 }, start.offset);
    for (0..95) |age| {
        const frame = battle.spell_scene.knockoutAt(hurt, firestorm, @intCast(age)).?;
        try std.testing.expectEqual(age < 92, frame.visible);
        try std.testing.expectEqual(@as(u8, @intCast(128 - @min(128, (age -| 2) * 2))), frame.tint);
    }
    var invalid = packet;
    var poses = [_]battle.spell_scene.HurtPose{hurt};
    poses[0].knockout.?.duration = 1;
    invalid.hurt_poses = &poses;
    try std.testing.expectError(error.InvalidSpellScenes, invalid.validate(4096, 4096));
}

test "Fog screen strips validate and white flicker follows the presentation phase" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    const packet = parsed.value;
    var draws = battle.systems.Draws{ .bios_state = 17 };
    var instance = try battle.spell_scene.Instance.begin(&packet, packet.indexOf("spell_10").?, .{ 120, 50, 0 }, .{ -128, 0, 0 }, battle.drops.initial_camera, &draws);
    const actor = packet.hurt_poses[0];
    try std.testing.expectEqual(actor.white_entry.?, battle.spell_scene.reactionAt(&packet, &instance, 224, actor.id).?.entry.?);
    instance.flicker_phase = 1;
    try std.testing.expectEqual(actor.entry, battle.spell_scene.reactionAt(&packet, &instance, 224, actor.id).?.entry.?);
    var invalid = packet;
    const spells = try allocator.dupe(battle.spell_scene.Spell, packet.spells);
    defer allocator.free(spells);
    invalid.spells = spells;
    var layer = [_]battle.spell_scene.ScreenLayer{spells[9].program.?.screen_layers[0]};
    spells[9].program.?.screen_layers = &layer;
    layer[0].copies = 3;
    try std.testing.expectError(error.InvalidSpellScenes, invalid.validate(4096, 4096));
    layer[0] = packet.spells[9].program.?.screen_layers[0];
    var samples = [_]?battle.spell_scene.ScreenSample{.{ .vertices = &.{}, .tint = 128 }};
    layer[0].samples = &samples;
    try std.testing.expectError(error.InvalidSpellScenes, invalid.validate(4096, 4096));
}

test "Spark coordinator preserves ordinary draws then overrides party order across busy masks" {
    const content = try battle.load(allocator, @embedFile("fixtures/battle_canonical.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members: [6]battle.Member = undefined;
    const base = try battle.State.init(content.value, rules.value, &members, 17);
    const count = base.partyCount();
    const limit = @as(usize, 1) << @intCast(count);
    const values: [32]u15 = @splat(99);
    for (0..limit) |acted| for (0..limit) |busy| {
        var normal = base;
        for (0..count) |i| {
            normal.acted[i] = acted & (@as(usize, 1) << @intCast(i)) != 0;
            if (busy & (@as(usize, 1) << @intCast(i)) != 0) normal.party_strikes[i] = .{ .actor = i, .target = count };
        }
        var spark = normal;
        var ordinary_draws = battle.systems.Draws{ .values = &values };
        var spark_draws = battle.systems.Draws{ .values = &values };
        normal.replay_draws = &ordinary_draws;
        spark.replay_draws = &spark_draws;
        const ordinary = normal.coordinatorChoice();
        spark.spark_pending = true;
        const actual = spark.coordinatorChoice();
        const expected = for (0..count) |i| {
            const mask = @as(usize, 1) << @intCast(i);
            if ((acted | busy) & mask == 0) break battle.Coordinator.Choice{ .actor = i };
        } else ordinary;
        try std.testing.expectEqualDeep(expected, actual);
        try std.testing.expectEqual(ordinary_draws.cursor, spark_draws.cursor);
        try std.testing.expectEqual(acted != limit - 1, spark.spark_pending);
    };
}

test "generated healing binds one to six party slots without consuming unused orbit draws" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    const packet = &parsed.value;
    const index = packet.indexOf("spell_11").?;
    const party: [7]battle.spell_scene.Target = @splat(.{ .position = .{ 128, 0, 0 } });
    for (1..7) |count| {
        var draws = battle.systems.Draws{ .bios_state = 17 };
        var instance = try battle.spell_scene.Instance.beginForParty(packet, index, .{ 120, 50, 0 }, .{ 128, 0, 0 }, battle.drops.initial_camera, &draws, party[0..count]);
        try std.testing.expectEqual(count * 12, draws.cursor);
        try instance.advance(packet, 97, &draws);
        const frame = battle.spell_scene.frameAt(packet, &instance, 97);
        try std.testing.expectEqual(64 + count * 4, frame.count);
        try std.testing.expectEqual(count * 12, draws.cursor);
    }
    var draws = battle.systems.Draws{ .bios_state = 17 };
    try std.testing.expectError(error.InvalidSpellTargets, battle.spell_scene.Instance.beginForParty(packet, index, .{ 0, 0, 0 }, .{ 0, 0, 0 }, battle.drops.initial_camera, &draws, &.{}));
    try std.testing.expectError(error.InvalidSpellTargets, battle.spell_scene.Instance.beginForParty(packet, index, .{ 0, 0, 0 }, .{ 0, 0, 0 }, battle.drops.initial_camera, &draws, &party));
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    var invalid = packet.*;
    const spells = try allocator.dupe(battle.spell_scene.Spell, packet.spells);
    defer allocator.free(spells);
    const objects = try allocator.dupe(battle.spell_scene.Object, spells[index].program.?.objects);
    defer allocator.free(objects);
    invalid.spells = spells;
    spells[index].program.?.objects = objects;
    objects[1].random_size.?.draw = 12;
    try std.testing.expectError(error.InvalidSpellScenes, invalid.validate(4096, 4096));
}

test "generated support response holds idle and restores both palette and RGB" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    const packet = &parsed.value;
    const index = packet.indexOf("spell_11").?;
    const party = [_]battle.spell_scene.Target{.{ .position = .{ 128, 0, 0 } }};
    var draws = battle.systems.Draws{ .bios_state = 17 };
    const instance = try battle.spell_scene.Instance.beginForParty(packet, index, .{ 120, 50, 0 }, .{ 128, 0, 0 }, battle.drops.initial_camera, &draws, &party);
    const actor = for (packet.hurt_poses) |pose| {
        if (std.mem.eql(u8, pose.id, "hero")) break pose;
    } else unreachable;
    const normal = battle.spell_scene.reactionAt(packet, &instance, 246, "hero").?;
    try std.testing.expectEqual(@as(u8, 0), normal.animation);
    try std.testing.expectEqual(@as(?u16, actor.entry), normal.entry);
    const white = battle.spell_scene.reactionAt(packet, &instance, 248, "hero").?;
    try std.testing.expectEqual(actor.white_entry, white.entry);
    try std.testing.expectEqualDeep([3]u8{ 255, 255, 64 }, white.color);
    const restored = battle.spell_scene.reactionAt(packet, &instance, 295, "hero").?;
    try std.testing.expectEqual(@as(?u16, actor.entry), restored.entry);
    try std.testing.expectEqualDeep([3]u8{ 128, 128, 128 }, restored.color);
    try std.testing.expect(battle.spell_scene.reactionAt(packet, &instance, 306, "hero") != null);
    try std.testing.expect(battle.spell_scene.reactionAt(packet, &instance, 307, "hero") == null);
}

test "legacy Unite eligibility uses the source poison sleep recovery mask for either member" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/battle_canonical.json"));
    defer parsed.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    for ([_]usize{ 1, 2 }) |member| for (0..8) |condition| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(parsed.value, rules.value, &members, 17);
        switch (condition) {
            0 => state.progress.party.at(member).status = .poisoned,
            1 => state.actor_conditions[member].sleep_turns = 1,
            2 => state.unbalanced[member] = 1,
            3 => state.progress.party.at(member).balloons = 1,
            4 => state.actor_conditions[member].accuracy_reduced = true,
            5 => state.actor_conditions[member].rune_blocked = true,
            6 => state.actor_conditions[member].protection_rounds = 3,
            7 => {},
            else => unreachable,
        }
        try std.testing.expectEqual(condition >= 3, state.canUnite(2));
    };
}

test "legacy battle items consume on no effect and protection without changing field policy" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/battle_canonical.json"));
    defer parsed.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    for ([_]field.items.Id{ .medicine, .mega_medicine, .antitoxin, .needle }) |id| for (0..3) |condition| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(parsed.value, rules.value, &members, 17);
        state.progress.party.at(1).max_hp = 1000;
        state.progress.party.at(1).hp = if (condition == 0) 1000 else 1;
        state.progress.party.at(1).status = if (condition == 0) .healthy else .poisoned;
        state.progress.party.at(1).balloons = if (condition == 0) 0 else 3;
        state.actor_conditions[1].protection_rounds = if (condition == 1) 3 else 0;
        state.progress.party.at(0).inventory.slots = @splat(null);
        state.progress.party.at(0).inventory.slots[0] = .{ .id = id, .uses = 1 };
        state.progress.party.at(0).inventory.slots[1] = .{ .id = .bandanna, .uses = 0 };
        state.phase = .resolving;
        state.actions[0] = .{ .item = .{ .slot = 0, .target = 1, .id = id } };
        state.active = .{ .actor = 0, .target = 1, .kind = .item, .item_id = id };
        state.action_ticks = state.impactTick() - 1;
        state.tick(.{});
        try std.testing.expectEqual(field.items.Id.bandanna, state.progress.party.at(0).inventory.slots[0].?.id);
        const amount: u16 = if (condition == 2) rules.value.consumable(id).?.heal_hp else 0;
        try std.testing.expectEqual(@as(u16, if (condition == 0) 1000 else 1) + amount, state.progress.party.at(1).hp);
        if (condition != 0 and id == .antitoxin) try std.testing.expectEqual(field.game_state.Status.healthy, state.progress.party.at(1).status);
        if (condition != 0 and id == .needle) try std.testing.expectEqual(@as(u8, 2), state.progress.party.at(1).balloons);
    };
}

test "shared world compositor emits the decoded four eight and one item clone sets" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/battle_canonical.json"));
    defer parsed.deinit();
    const art = try std.json.parseFromSlice(battle.world_art.Data, allocator, @embedFile("fixtures/world_roc_art.json"), .{});
    defer art.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    for ([_]field.items.Id{ .medicine, .mega_medicine, .antitoxin, .needle }, [_]usize{ 4, 8, 1, 0 }) |id, expected| {
        var members: [6]battle.Member = undefined;
        var state = try battle.State.init(parsed.value, rules.value, &members, 17);
        state.content.world_art = art.value;
        state.medicine_action = .{ .id = id, .actor = 0, .target = 1, .ticks = 21, .started_at = 0, .timing = .{ .id = "hero", .target_start = 20, .pending_tick = 51, .impact_tick = 52, .target_release = 84, .owner_release = 89 } };
        state.presentation_tick = 21;
        const target = battle.world_art.actorSample(art.value, &state, 1).sample.position;
        const effect = rules.value.consumable(id).?.battle.?;
        const frame = battle.world_art.compose(art.value, state);
        var count: usize = 0;
        for (frame.quads[0..frame.length]) |quad| if (quad.medicine_particle) {
            var found = false;
            for (effect.particles[0]) |position| if (@abs(quad.position.x - target.x - position[0]) < 0.001 and @abs(quad.position.y - target.y - position[1]) < 0.001 and @abs(quad.position.z - target.z - position[2]) < 0.001) {
                found = true;
            };
            try std.testing.expect(found);
            try std.testing.expectEqualDeep(effect.particle_tint, quad.light);
            count += 1;
        };
        try std.testing.expectEqual(expected, count);
    }
}

test "rising spell sprites reuse scaled spawn positions and keep their final life-zero frame" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    const packet = &parsed.value;
    const index = packet.indexOf("spell_21").?;
    var values: [60]u15 = undefined;
    for (&values, 0..) |*value, i| value.* = if (i % 3 == 2) 59 else 0;
    var draws = battle.systems.Draws{ .values = &values };
    var instance = try battle.spell_scene.Instance.begin(packet, index, .{ 120, 50, 0 }, .{ 128, 0, 0 }, battle.drops.initial_camera, &draws);
    try instance.advance(packet, 176, &draws);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    try instance.advance(packet, 177, &draws);
    try std.testing.expectEqual(@as(usize, 30), draws.cursor);
    for (instance.particles[0..10]) |particle| {
        try std.testing.expect(particle.active);
        try std.testing.expectEqual(@as(u16, 58), particle.life);
        try std.testing.expectEqualDeep([3]i32{ -29 * 4096, -7 * 4096, -13653 }, particle.head);
    }
    try instance.advance(packet, 235, &draws);
    try std.testing.expect(instance.particles[0].active);
    try std.testing.expectEqual(@as(u16, 0), instance.particles[0].life);
    const fraction = instance.particles[0].head[2] & 4095;
    try instance.advance(packet, 236, &draws);
    try std.testing.expect(!instance.particles[0].active);
    try instance.advance(packet, 237, &draws);
    try std.testing.expectEqual(@as(usize, 60), draws.cursor);
    try std.testing.expectEqualDeep([3]i32{ -28 * 4096, -6 * 4096, fraction - 13653 }, instance.particles[0].head);
    var invalid = packet.*;
    const spells = try allocator.dupe(battle.spell_scene.Spell, packet.spells);
    defer allocator.free(spells);
    const objects = try allocator.dupe(battle.spell_scene.Object, spells[index].program.?.objects);
    defer allocator.free(objects);
    invalid.spells = spells;
    spells[index].program.?.objects = objects;
    objects[2].particle_index = 10;
    try std.testing.expectError(error.InvalidSpellScenes, invalid.validate(4096, 4096));
    objects[2] = packet.spells[index].program.?.objects[2];
    spells[index].program.?.emitter.?.life_max = 0;
    try std.testing.expectError(error.InvalidSpellScenes, invalid.validate(4096, 4096));
}

test "scheduled sprites delay zero until clock reset and stop respawning at the fade boundary" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    const packet = &parsed.value;
    const index = packet.indexOf("spell_33").?;
    const values: [120]u15 = @splat(0);
    var draws = battle.systems.Draws{ .values = &values };
    var instance = try battle.spell_scene.Instance.begin(packet, index, .{ 120, 50, 0 }, .{ 128, 0, 0 }, battle.drops.initial_camera, &draws);
    try instance.advance(packet, 287, &draws);
    try std.testing.expectEqual(@as(usize, 40), draws.cursor);
    for (instance.particles[0..packet.spells[index].program.?.emitter.?.count]) |particle| try std.testing.expect(particle.pending and !particle.active);
    try instance.advance(packet, 288, &draws);
    try std.testing.expectEqual(@as(usize, 120), draws.cursor);
    for (instance.particles[0..packet.spells[index].program.?.emitter.?.count]) |particle| {
        try std.testing.expect(!particle.pending and particle.active);
        try std.testing.expectEqualDeep([3]i32{ -119 * 4096, -15 * 4096, -38400 }, particle.head);
    }
    try instance.advance(packet, 321, &draws);
    for (instance.particles[0..packet.spells[index].program.?.emitter.?.count]) |particle| {
        try std.testing.expect(!particle.active);
        try std.testing.expectEqual(@as(i32, -34 * 38400), particle.head[2]);
    }
    try instance.advance(packet, 353, &draws);
    try std.testing.expectEqual(@as(usize, 120), draws.cursor);
    var invalid = packet.*;
    const spells = try allocator.dupe(battle.spell_scene.Spell, packet.spells);
    defer allocator.free(spells);
    invalid.spells = spells;
    spells[index].program.?.emitter.?.spawn_clock = &.{};
    try std.testing.expectError(error.InvalidSpellScenes, invalid.validate(4096, 4096));
    spells[index] = packet.spells[index];
    spells[index].program.?.emitter.?.delay_modulus = 0;
    try std.testing.expectError(error.InvalidSpellScenes, invalid.validate(4096, 4096));
}

test "scene projection keeps exact rational boundaries and floors negative coordinates" {
    const camera = @import("battle_camera");
    const block = camera.Block{ .focus = .{ 0, 0, 0 }, .angles = .{ 0, 0, 0 }, .translation = .{ 0, 0, 0 }, .scale = @splat(4096) };
    try std.testing.expectEqualDeep([3]i32{ 128, -128, 1040 }, camera.rawProject(block, .{ 130, -130, 1040 }));
    try std.testing.expectEqualDeep([3]i32{ 127, -128, 1041 }, camera.rawProject(block, .{ 130, -130, 1041 }));
    try std.testing.expectEqualDeep([3]i32{ 1023, -1024, 0 }, camera.rawProject(block, .{ 1000, -1000, 0 }));
}

test "band meshes reject missing angle samples odd segments and older schema versions" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    const index = packet.indexOf("spell_23").?;
    const spells = try allocator.dupe(battle.spell_scene.Spell, packet.spells);
    defer allocator.free(spells);
    packet.spells = spells;
    const meshes = try allocator.dupe(battle.spell_scene.Mesh, spells[index].program.?.meshes);
    defer allocator.free(meshes);
    spells[index].program.?.meshes = meshes;
    meshes[1].opening = &.{};
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    meshes[1] = parsed.value.spells[index].program.?.meshes[1];
    meshes[1].segments = 31;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    meshes[1] = parsed.value.spells[index].program.?.meshes[1];
    packet = spellOnlyFixture(packet);
    packet.schema = "suikoden-spell-scenes/8";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "screen light ramps reject truncated samples depth overflow and older schemas" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    var spell = packet.spells[packet.indexOf("spell_30").?];
    packet.spells = (&spell)[0..1];
    spell.program.?.meshes = &.{};
    var screen = spell.program.?.screen_washes[0];
    spell.program.?.screen_washes = (&screen)[0..1];
    try packet.validate(4096, 4096);
    const colors = screen.colors;
    screen.colors = &.{};
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    screen.colors = colors;
    screen.depth = 510;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    screen.depth = 0;
    packet = spellOnlyFixture(packet);
    packet.schema = "suikoden-spell-scenes/8";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "falling particle scenes reject invalid random ranges splash bindings and old schema" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    var spell = packet.spells[packet.indexOf("spell_12").?];
    packet.spells = (&spell)[0..1];
    const original = spell.program.?.emitter.?;
    try packet.validate(4096, 4096);
    spell.program.?.emitter.?.speed_range = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spell.program.?.emitter = original;
    spell.program.?.emitter.?.splash_track = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spell.program.?.emitter = original;
    spell.program.?.emitter.?.spawn_stop = original.stop;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spell.program.?.emitter = original;
    packet = spellOnlyFixture(packet);
    packet.schema = "suikoden-spell-scenes/9";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "lightning scenes validate paired children limits and endpoint reaction release" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    var spell = packet.spells[packet.indexOf("spell_17").?];
    packet.spells = (&spell)[0..1];
    const original = spell.program.?.emitter.?;
    try std.testing.expectEqual(spell.program.?.reaction.?.offsets.len, spell.program.?.reaction.?.release.?);
    try packet.validate(4096, 4096);
    spell.program.?.reaction.?.release.? += 1;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spell.program.?.reaction.?.release.? -= 1;
    spell.program.?.emitter.?.spawn_at = &.{177};
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spell.program.?.emitter = original;
    spell.program.?.emitter.?.spark_life_min = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spell.program.?.emitter = original;
    spell.program.?.emitter.?.pulse_life = 255;
    spell.program.?.emitter.?.pulse_grow = 4096;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spell.program.?.emitter = original;
    packet = spellOnlyFixture(packet);
    packet.schema = "suikoden-spell-scenes/10";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "repeating lightning requires bounded unique formation slots and timed origins" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    var spell = packet.spells[packet.indexOf("spell_18").?];
    packet.spells = (&spell)[0..1];
    const original = spell.program.?.emitter.?;
    try packet.validate(4096, 4096);
    spell.program.?.emitter.?.repeat_until = original.strike_at;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spell.program.?.emitter = original;
    spell.program.?.emitter.?.strike_radius = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spell.program.?.emitter = original;
    packet = spellOnlyFixture(packet);
    packet.schema = "suikoden-spell-scenes/11";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    packet.schema = parsed.value.schema;
    const objects = try allocator.dupe(battle.spell_scene.Object, spell.program.?.objects);
    defer allocator.free(objects);
    spell.program.?.objects = objects;
    const until = objects[6].origin_until;
    objects[6].origin_until = spell.program.?.duration + 1;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    objects[6].origin_until = until;
    var draws = battle.systems.Draws{ .bios_state = 17 };
    var instance = try battle.spell_scene.Instance.begin(&packet, 0, .{ 120, 50, 0 }, .{ -128, 0, 0 }, battle.drops.initial_camera, &draws);
    try std.testing.expectError(error.InvalidSpellTargets, instance.advance(&packet, 1, &draws));
    try std.testing.expectEqual(@as(u16, 0), instance.elapsed);
    instance.target_count = 2;
    instance.targets[0] = .{ .formation_slot = 0 };
    instance.targets[1] = .{ .formation_slot = 2 };
    try instance.advance(&packet, 1, &draws);
    instance.targets[1].formation_slot = 0;
    try std.testing.expectError(error.InvalidSpellTargets, instance.advance(&packet, 2, &draws));
    instance.targets[1].formation_slot = 6;
    try std.testing.expectError(error.InvalidSpellTargets, instance.advance(&packet, 2, &draws));
    instance.targets[1].formation_slot = 2;
    instance.targets[1].position[0] = 32768;
    try std.testing.expectError(error.InvalidSpellTargets, instance.advance(&packet, 2, &draws));
    try std.testing.expectEqual(@as(u16, 1), instance.elapsed);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
}

test "arranged bolt payload bounds placements closure and target height before mutation" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    var spell = packet.spells[packet.indexOf("spell_19").?];
    packet.spells = (&spell)[0..1];
    const original = spell.program.?.emitter.?;
    try packet.validate(4096, 4096);
    spell.program.?.emitter.?.fixed_positions = original.fixed_positions[0..15];
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spell.program.?.emitter = original;
    spell.program.?.emitter.?.persistent_from = original.count;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spell.program.?.emitter = original;
    spell.program.?.emitter.?.spark_turn_stop = original.spark_turn_at - 1;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spell.program.?.emitter = original;
    spell.program.?.emitter.?.spark_turn_step = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spell.program.?.emitter = original;
    packet = spellOnlyFixture(packet);
    packet.schema = "suikoden-spell-scenes/12";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    packet.schema = parsed.value.schema;
    var draws = battle.systems.Draws{ .bios_state = 17 };
    try std.testing.expectError(error.InvalidSpellTargets, battle.spell_scene.Instance.begin(&packet, 0, .{ 120, 50, 0 }, .{ -128, 0, 32768 }, battle.drops.initial_camera, &draws));
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    var instance = try battle.spell_scene.Instance.begin(&packet, 0, .{ 120, 50, 0 }, .{ -128, 0, 1675 }, battle.drops.initial_camera, &draws);
    try instance.advance(&packet, 336, &draws);
    // The phase closes an old spark before the same update's primary landing re-enables it.
    try std.testing.expect(instance.particles[12].splash_active);
    try std.testing.expectEqual(@as(i32, 1024), instance.particles[12].spark_angle);
    try std.testing.expectEqual(@as(u16, 1), instance.particles[12].splash_age);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
}

test "contracting particles validate split image tracks and reaction gaps" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    var spell = packet.spells[packet.indexOf("spell_20").?];
    packet.spells = (&spell)[0..1];
    const original = spell.program.?.emitter.?;
    try packet.validate(4096, 4096);
    spell.program.?.emitter.?.spark_stop = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spell.program.?.emitter = original;
    packet = spellOnlyFixture(packet);
    packet.schema = "suikoden-spell-scenes/13";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    packet.schema = parsed.value.schema;
    const meshes = try allocator.dupe(battle.spell_scene.Mesh, spell.program.?.meshes);
    defer allocator.free(meshes);
    spell.program.?.meshes = meshes;
    meshes[1].angles[2] = 1048577;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    meshes[1].angles[2] = 2048;
    const reaction = spell.program.?.reaction.?;
    spell.program.?.reaction.?.active_samples = &.{true};
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spell.program.?.reaction = reaction;
    const objects = try allocator.dupe(battle.spell_scene.Object, spell.program.?.objects);
    defer allocator.free(objects);
    spell.program.?.objects = objects;
    const piece_track = objects[8].piece_track;
    objects[8].piece_track = @intCast(spell.program.?.tracks.len);
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    objects[8].piece_track = piece_track;
    var draws = battle.systems.Draws{ .bios_state = 17 };
    var instance = try battle.spell_scene.Instance.begin(&packet, 0, .{ 120, 50, 0 }, .{ -128, 0, 0 }, battle.drops.initial_camera, &draws);
    try instance.advance(&packet, 158, &draws);
    try std.testing.expect(instance.particles[0].active and instance.particles[0].landed);
    try std.testing.expectEqual(@as(u16, 14), instance.particles[0].age);
    try std.testing.expectEqual(@as(u16, 46), instance.particles[0].pulse_life);
    try instance.advance(&packet, 208, &draws);
    try std.testing.expectEqual(@as(u16, 64), instance.particles[0].age);
    try instance.advance(&packet, 209, &draws);
    try std.testing.expect(!instance.particles[0].active);
    try std.testing.expect(battle.spell_scene.reactionAt(&packet, &instance, 258, "crow") != null);
    try std.testing.expect(battle.spell_scene.reactionAt(&packet, &instance, 259, "crow") == null);
    try std.testing.expect(battle.spell_scene.reactionAt(&packet, &instance, 260, "crow") == null);
    try std.testing.expect(battle.spell_scene.reactionAt(&packet, &instance, 261, "crow") != null);
    try instance.advance(&packet, 289, &draws);
    try std.testing.expect(!instance.particles[0].splash_active);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
}

test "scheduled pulse scenes reject malformed events roles and obsolete schemas" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    const spells = try allocator.dupe(battle.spell_scene.Spell, packet.spells);
    defer allocator.free(spells);
    packet.spells = spells;
    const id = packet.indexOf("spell_6").?;
    const original = spells[id];
    var events = [_]battle.spell_scene.PulseSpawn{original.program.?.emitter.?.pulse_spawns[0]};
    spells[id].program.?.emitter.?.pulse_spawns = &events;
    try packet.validate(4096, 4096);
    events[0].index = 40;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[id] = original;
    spells[id].program.?.emitter.?.height_range = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[id] = original;
    const objects = try allocator.dupe(battle.spell_scene.Object, original.program.?.objects);
    defer allocator.free(objects);
    spells[id].program.?.objects = objects;
    objects[1].particle_part = .primary;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[id] = original;
    packet = spellOnlyFixture(packet);
    packet.schema = "suikoden-spell-scenes/14";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "parabolic strip parser rejects truncated edges and oversized local geometry" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    const spells = try allocator.dupe(battle.spell_scene.Spell, packet.spells);
    defer allocator.free(spells);
    packet.spells = spells;
    const id = packet.indexOf("spell_16").?;
    const meshes = try allocator.dupe(battle.spell_scene.Mesh, spells[id].program.?.meshes);
    defer allocator.free(meshes);
    spells[id].program.?.meshes = meshes;
    const original = meshes[0];
    meshes[0].strip_edges = original.strip_edges[0..2];
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    meshes[0] = original;
    const samples = try allocator.dupe([]const [2][3]i16, original.strip_edges);
    defer allocator.free(samples);
    const vertices = try allocator.dupe([2][3]i16, samples[0]);
    defer allocator.free(vertices);
    samples[0] = vertices;
    meshes[0].strip_edges = samples;
    vertices[0][0][0] = 4097;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    meshes[0] = original;
    packet = spellOnlyFixture(packet);
    packet.schema = "suikoden-spell-scenes/15";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    packet.schema = parsed.value.schema;
    const paired = packet.indexOf("spell_14").?;
    const tracks = try allocator.dupe([]const battle.spell_scene.Sample, spells[paired].program.?.tracks);
    defer allocator.free(tracks);
    const samples2 = try allocator.dupe(battle.spell_scene.Sample, tracks[1]);
    defer allocator.free(samples2);
    tracks[1] = samples2;
    spells[paired].program.?.tracks = tracks;
    samples2[145].target_weight[0] = 32769;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "sphere scene parser bounds pool radius and node variation and gates RGB schema" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    const spells = try allocator.dupe(battle.spell_scene.Spell, packet.spells);
    defer allocator.free(spells);
    packet.spells = spells;
    const id = packet.indexOf("spell_13").?;
    const original = spells[id];
    try packet.validate(4096, 4096);
    spells[id].program.?.emitter.?.count = 51;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[id] = original;
    spells[id].program.?.emitter.?.radius = 201;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[id] = original;
    const objects = try allocator.dupe(battle.spell_scene.Object, original.program.?.objects);
    defer allocator.free(objects);
    spells[id].program.?.objects = objects;
    objects[1].random_node_angle.?.draw = 100;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[id] = original;
    packet = spellOnlyFixture(packet);
    packet.schema = "suikoden-spell-scenes/16";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "sphere scene keeps initializer RNG separate from spawn draws and colours each wave row" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    const packet = &parsed.value;
    const id = packet.indexOf("spell_13").?;
    var draws = battle.systems.Draws{ .bios_state = 17 };
    var instance = try battle.spell_scene.Instance.begin(packet, id, .{ 120, 50, 0 }, .{ -128, 0, 0 }, battle.drops.initial_camera, &draws);
    try std.testing.expectEqual(@as(usize, 100), draws.cursor);
    try instance.advance(packet, 129, &draws);
    try std.testing.expectEqual(@as(usize, 300), draws.cursor);
    const program = packet.spells[id].program.?;
    const first = battle.spell_scene.frameAt(packet, &instance, 129);
    var rows: usize = 0;
    for (first.commands[0..first.count]) |command| if (command.depth == 0) {
        try std.testing.expectEqualDeep([3]u8{ 1, 1, 1 }, command.tint);
        rows += 1;
    };
    try std.testing.expectEqual(@as(usize, 128), rows);
    try instance.advance(packet, 192, &draws);
    const peak = battle.spell_scene.frameAt(packet, &instance, 192);
    for (peak.commands[0..peak.count]) |command| if (command.depth == 0) try std.testing.expectEqualDeep([3]u8{ 96, 64, 64 }, command.tint);
    try instance.advance(packet, program.emitter.?.stop, &draws);
    const stopped = battle.spell_scene.frameAt(packet, &instance, 352);
    for (stopped.commands[0..stopped.count]) |command| try std.testing.expect(command.texture == null);
}

test "legacy sleep adapter honors the exported ward before drawing" {
    const content = try battle.load(allocator, @embedFile("fixtures/battle_canonical.json"));
    defer content.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    const profiles = try allocator.dupe(battle.Profile, content.value.enemies);
    defer allocator.free(profiles);
    for (profiles) |*profile| profile.death_immune = true;
    var view = content.value;
    view.enemies = profiles;
    const systems = view.systems.?;
    const spell = for (systems.spells, 0..) |entry, i| {
        if (entry.kind == .sleep) break i;
    } else unreachable;
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(view, rules.value, &members, 17);
    state.progress.party.at(0).rune = systems.runeIndex("wind").?;
    state.progress.party.at(0).rune_charges = .{ 9, 9, 9, 9 };
    state.progress.party.at(0).max_rune_charges = .{ 9, 9, 9, 9 };
    var draws = battle.systems.Draws{ .values = &.{} };
    state.replay_draws = &draws;
    var effect = battle.Effect{ .actor = 0, .target = state.partyCount(), .kind = .cast, .spell = spell };
    state.applySpell(&effect);
    try std.testing.expect(!state.replay_exhausted);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    for (state.actor_conditions[state.partyCount() .. state.partyCount() + state.enemyCount()]) |conditions| try std.testing.expectEqual(@as(u8, 0), conditions.sleep_turns);
    try std.testing.expectEqual(@as(u8, 8), state.progress.party.at(0).rune_charges[0]);
}

test "cycling sprite parser rejects stale schemas unsafe draw strides and truncated scale tracks" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    const spells = try allocator.dupe(battle.spell_scene.Spell, packet.spells);
    defer allocator.free(spells);
    packet.spells = spells;
    const id = packet.indexOf("spell_3").?;
    const original = spells[id];
    for ([_]u8{ 0, 9, 255 }) |stride| {
        spells[id] = original;
        spells[id].program.?.emitter.?.delay_stride = stride;
        try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    }
    spells[id] = original;
    spells[id].program.?.initial_draws = 28;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[id] = original;
    spells[id].program.?.emitter.?.scale_track = 0;
    const tracks = try allocator.dupe([]const battle.spell_scene.Sample, original.program.?.tracks);
    defer allocator.free(tracks);
    spells[id].program.?.tracks = tracks;
    tracks[0] = tracks[0][0..1];
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[id] = original;
    packet = spellOnlyFixture(packet);
    packet.schema = "suikoden-spell-scenes/17";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "multiple emitter groups keep independent pools and preserve source array draw order" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    const spells = try allocator.dupe(battle.spell_scene.Spell, packet.spells);
    defer allocator.free(spells);
    packet.spells = spells;
    packet = spellOnlyFixture(packet);
    packet.schema = "suikoden-spell-scenes/19";
    const id = packet.indexOf("spell_3").?;
    for (spells, 0..) |*spell, index| if (index != id) {
        spell.program = null;
        spell.blocker = "not under test";
    };
    const original = spells[id].program.?;
    var groups = [_]battle.spell_scene.Emitter{ original.emitter.?, original.emitter.? };
    groups[1].particle_start = 15;
    const objects = try allocator.alloc(battle.spell_scene.Object, original.objects.len + 15);
    defer allocator.free(objects);
    @memcpy(objects[0..original.objects.len], original.objects);
    @memcpy(objects[original.objects.len..], original.objects[original.objects.len - 15 ..]);
    for (objects[original.objects.len..]) |*object| object.particle_index.? += 15;
    spells[id].program.?.objects = objects;
    spells[id].program.?.emitter = null;
    spells[id].program.?.emitters = &groups;
    try packet.validate(4096, 4096);
    const values: [400]u15 = @splat(0);
    var draws = battle.systems.Draws{ .values = &values };
    var instance = try battle.spell_scene.Instance.begin(&packet, id, .{ 120, 50, 0 }, .{ -128, 0, 0 }, battle.drops.initial_camera, &draws);
    try instance.advance(&packet, 238, &draws);
    try std.testing.expectEqual(@as(usize, 90), draws.cursor);
    for (instance.particles[0..15], instance.particles[15..30]) |first, second| {
        try std.testing.expectEqualDeep(first, second);
        try std.testing.expect(first.active and !first.pending);
        try std.testing.expectEqual(@as(i32, -149 * 4096), first.head[0]);
    }
    try instance.advance(&packet, 293, &draws);
    try std.testing.expectEqual(@as(usize, 150), draws.cursor);
    for (instance.particles[0..15], instance.particles[15..30]) |first, second| {
        try std.testing.expectEqualDeep(first, second);
        try std.testing.expectEqual(@as(u16, 1), first.age);
    }
    var seeded_draws = battle.systems.Draws{ .bios_state = 17 };
    var seeded = try battle.spell_scene.Instance.begin(&packet, id, .{ 120, 50, 0 }, .{ -128, 0, 0 }, battle.drops.initial_camera, &seeded_draws);
    try seeded.advance(&packet, 238, &seeded_draws);
    try std.testing.expectEqual(@as(usize, 38), seeded_draws.cursor);
    for ([_]usize{ 2, 14, 17, 29 }, [_][2]i32{ .{ -65, 52 }, .{ 111, 50 }, .{ 71, 44 }, .{ -122, -36 } }) |particle, position| {
        try std.testing.expectEqualDeep([3]i32{ position[0] * 4096, position[1] * 4096, 0 }, seeded.particles[particle].head);
    }
    // The groups may consume different initializer fields without sharing a pool.
    groups[1].initial_delay_draw = 1;
    try packet.validate(4096, 4096);
    groups[1].initial_delay_draw = 2;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    groups[1].initial_delay_draw = 0;
    groups[1].particle_start = 14;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    groups[1].particle_start = 40;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    groups[1].particle_start = 15;
    spells[id].program.?.emitter = original.emitter;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[id].program.?.emitter = null;
    packet.schema = "suikoden-spell-scenes/18";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "falling trail parser rejects out of range history pulse roles and unsafe focus impulses" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    const spells = try allocator.dupe(battle.spell_scene.Spell, packet.spells);
    defer allocator.free(spells);
    packet.spells = spells;
    const id = packet.indexOf("spell_28").?;
    const original = spells[id].program.?;
    const groups = try allocator.dupe(battle.spell_scene.Emitter, original.emitters);
    defer allocator.free(groups);
    const objects = try allocator.dupe(battle.spell_scene.Object, original.objects);
    defer allocator.free(objects);
    spells[id].program.?.emitters = groups;
    spells[id].program.?.objects = objects;
    groups[0].trail_count = 11;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    groups[0] = original.emitters[0];
    objects[5].trail_index = 10;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    objects[5] = original.objects[5];
    objects[49].particle_part = .pulse;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    objects[49] = original.objects[49];
    groups[1].focus_kick = 129;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    groups[1] = original.emitters[1];
    groups[1].height_range = 0;
    try packet.validate(4096, 4096);
    groups[1] = original.emitters[1];
    packet = spellOnlyFixture(packet);
    packet.schema = "suikoden-spell-scenes/18";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "Shining Wind shared circle pools preserve RNG and reject invalid motion bounds" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    const spells = try allocator.dupe(battle.spell_scene.Spell, packet.spells);
    defer allocator.free(spells);
    packet.spells = spells;
    const id = packet.indexOf("spell_31").?;
    var draws = battle.systems.Draws{ .bios_state = 17 };
    var instance = try battle.spell_scene.Instance.begin(&packet, id, .{ 120, 50, 0 }, .{ -128, 0, 0 }, battle.drops.initial_camera, &draws);
    try instance.advance(&packet, 97, &draws);
    try std.testing.expectEqual(@as(usize, 420), draws.cursor);
    for ([_]usize{ 40, 69, 70, 89 }, [_][3]i32{ .{ -642811, 315392, -740910 }, .{ -688244, 720896, -762362 }, .{ 1179755, -172032, -885153 }, .{ -839769, 700416, -651219 } }) |index, head| {
        try std.testing.expectEqualDeep(head, instance.particles[index].head);
        try std.testing.expectEqual(@as(u16, 1), instance.particles[index].age);
    }
    try instance.advance(&packet, 161, &draws);
    try std.testing.expectEqual(@as(usize, 426), draws.cursor);
    try std.testing.expectEqualDeep([3]i32{ 86016, -65536, -81920 }, instance.particles[0].head);
    try std.testing.expectEqual(@as(i32, 513), instance.particles[20].pulse_size);
    const ally = battle.spell_scene.partyReactionAt(&packet, &instance, 162, "gremio").?;
    try std.testing.expectEqualDeep([3]u8{ 255, 255, 64 }, ally.color);
    try std.testing.expect(battle.spell_scene.partyReactionAt(&packet, &instance, 354, "gremio") == null);
    try std.testing.expect(battle.spell_scene.reactionAt(&packet, &instance, 337, "bonbon") == null);
    try instance.advance(&packet, 385, &draws);
    try std.testing.expectEqual(@as(usize, 1308), draws.cursor);
    const original = spells[id].program.?;
    var groups = [_]battle.spell_scene.Emitter{ original.emitters[0], original.emitters[1], original.emitters[2] };
    spells[id].program.?.emitters = &groups;
    groups[2].particle_start = 41;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    groups[2] = original.emitters[2];
    groups[2].velocity_range = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    groups[2] = original.emitters[2];
    groups[2].radius = 301;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    groups[2] = original.emitters[2];
    groups[2].spawn_at = &.{100};
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    groups[2] = original.emitters[2];
    groups[0].height_range = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    groups[0] = original.emitters[0];
    groups[0].spawn_at = &.{161};
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    groups[0] = original.emitters[0];
    var party_reaction = original.party_reaction.?;
    party_reaction.flash_frames = &.{null};
    spells[id].program.?.party_reaction = party_reaction;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[id].program = original;
    packet = spellOnlyFixture(packet);
    packet.schema = "suikoden-spell-scenes/19";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "Explosion scale noise repeated sizes and inward line transforms remain bounded" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    const id = packet.indexOf("spell_4").?;
    var draws = battle.systems.Draws{ .bios_state = 17 };
    var instance = try battle.spell_scene.Instance.begin(&packet, id, .{ 120, 50, 0 }, .{ -128, 0, 0 }, battle.drops.initial_camera, &draws);
    try instance.advance(&packet, 320, &draws);
    try std.testing.expectEqual(@as(usize, 1275), draws.cursor);
    try std.testing.expectEqual(@as(i32, 243), instance.noise_scale);
    try std.testing.expectEqual(@as(i32, 7286), instance.particles[8].size_override);
    try std.testing.expectEqualDeep([3]i32{ -53248, 286720, 0 }, instance.particles[8].head);
    try std.testing.expectEqualDeep([3]i32{ 4339, 4339, 4339 }, instance.particles[8].spawn_scale);
    try instance.advance(&packet, 449, &draws);
    try std.testing.expectEqual(@as(usize, 1275), draws.cursor);
    const spells = try allocator.dupe(battle.spell_scene.Spell, packet.spells);
    defer allocator.free(spells);
    packet.spells = spells;
    for (spells, 0..) |*spell, i| if (i != id) {
        spell.program = null;
        spell.blocker = "not under test";
    };
    const original = spells[id].program.?;
    var groups = [_]battle.spell_scene.Emitter{ original.emitters[0], original.emitters[1], original.emitters[2] };
    spells[id].program.?.emitters = &groups;
    try packet.validate(4096, 4096);
    groups[0].repeat_size_min = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    groups[0] = original.emitters[0];
    groups[2].model_track = 128;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    groups[2] = original.emitters[2];
    groups[2].model_track = null;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    groups[2] = original.emitters[2];
    groups[2].spawn_stop = 449;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    groups[2] = original.emitters[2];
    spells[id].program.?.scale_noise.?.modulus = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[id].program = original;
    spells[id].program.?.scale_noise.?.bias = 10000;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[id].program = original;
    spells[id].program.?.scale_noise = null;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[id].program = original;
    const tracks = try allocator.dupe([]const battle.spell_scene.Sample, original.tracks);
    defer allocator.free(tracks);
    const model = try allocator.dupe(battle.spell_scene.Sample, tracks[1]);
    defer allocator.free(model);
    tracks[1] = model;
    spells[id].program.?.tracks = tracks;
    model[0].scale = @splat(65536);
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[id].program = original;
    packet = spellOnlyFixture(packet);
    packet.schema = "suikoden-spell-scenes/20";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "Earthquake opaque rocks bounce retain active impact positions and bound source motion" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    const id = packet.indexOf("spell_24").?;
    var draws = battle.systems.Draws{ .bios_state = 17 };
    var instance = try battle.spell_scene.Instance.begin(&packet, id, .{ 120, 50, 0 }, .{ -128, 0, 0 }, battle.drops.initial_camera, &draws);
    try instance.advance(&packet, 129, &draws);
    try std.testing.expectEqual(@as(usize, 103), draws.cursor);
    try std.testing.expectEqualDeep([3]i32{ 349526, 126976, -1634304 }, instance.particles[0].head);
    try std.testing.expectEqual(@as(i32, 65314), instance.particles[0].node_rotation);
    const frame = battle.spell_scene.frameAt(&packet, &instance, 129);
    try std.testing.expectEqual(@as(usize, 1), frame.count);
    try std.testing.expectEqual(battle.spell_scene.Blend.@"opaque", frame.commands[0].blend);
    try instance.advance(&packet, 157, &draws);
    try std.testing.expectEqual(@as(usize, 355), draws.cursor);
    try std.testing.expectEqual(@as(u16, 157), instance.last_landing);
    try std.testing.expectEqualDeep([3]i32{ -27306, 0, -57344 }, instance.particles[0].velocity);
    const first_impact = instance.particles[0].splash_position;
    try std.testing.expectEqualDeep([3]i32{ -387736, 126976, 0 }, first_impact);
    const program = packet.spells[id].program.?;
    const base = battle.spell_scene.cameraAt(program, 157, battle.drops.initial_camera);
    try std.testing.expectEqual(base.focus[2] + 5, battle.spell_scene.instanceCameraAt(program, &instance, 157).focus[2]);
    try instance.advance(&packet, 159, &draws);
    try std.testing.expectEqual(@as(u16, 157), instance.last_landing);
    try instance.advance(&packet, 187, &draws);
    try std.testing.expectEqualDeep(first_impact, instance.particles[0].splash_position);
    try instance.advance(&packet, 321, &draws);
    try std.testing.expectEqual(@as(usize, 1625), draws.cursor);
    for (instance.particles[0..20]) |node| try std.testing.expect(!node.active and !node.splash_active);
    const spells = try allocator.dupe(battle.spell_scene.Spell, packet.spells);
    defer allocator.free(spells);
    packet.spells = spells;
    for (spells, 0..) |*spell, i| if (i != id) {
        spell.program = null;
        spell.blocker = "not under test";
    };
    const original = spells[id].program.?;
    try packet.validate(4096, 4096);
    spells[id].program.?.emitter.?.gravity = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[id].program = original;
    spells[id].program.?.emitter.?.bounce_divisor = 1;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[id].program = original;
    spells[id].program.?.emitter.?.spin_modulus = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[id].program = original;
    spells[id].program.?.emitter.?.focus_stride = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[id].program = original;
    spells[id].program.?.emitter.?.spawn_at = &.{129};
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[id].program = original;
    spells[id].program.?.emitter.?.min_x = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[id].program = original;
    const objects = try allocator.dupe(battle.spell_scene.Object, original.objects);
    defer allocator.free(objects);
    spells[id].program.?.objects = objects;
    objects[1].random_node_angles[0].?.draw = 100;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    objects[1] = original.objects[1];
    objects[1].particle_part = .pulse;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[id].program = original;
    packet = spellOnlyFixture(packet);
    packet.schema = "suikoden-spell-scenes/21";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "Thunder God radial births delayed spark rise and ignored initial delays are bounded" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    const id = packet.indexOf("spell_32").?;
    var draws = battle.systems.Draws{ .bios_state = 17 };
    var instance = try battle.spell_scene.Instance.begin(&packet, id, .{ 120, 50, 0 }, .{ -128, 0, 0 }, battle.drops.initial_camera, &draws);
    try std.testing.expectEqual(@as(usize, 96), draws.cursor);
    try instance.advance(&packet, 189, &draws);
    try std.testing.expectEqual(@as(usize, 100), draws.cursor);
    try std.testing.expectEqualDeep([3]i32{ 614400, 0, 0 }, instance.particles[0].splash_position);
    try std.testing.expectEqual(@as(u16, 63), instance.particles[0].life);
    try std.testing.expectEqual(@as(i32, 513), instance.particles[0].pulse_size);
    try instance.advance(&packet, 252, &draws);
    try std.testing.expectEqual(@as(i32, -73728), instance.particles[0].spark_height);
    try std.testing.expect(instance.particles[0].splash_active);
    try instance.advance(&packet, 268, &draws);
    try std.testing.expect(instance.particles[0].splash_active);
    try instance.advance(&packet, 269, &draws);
    try std.testing.expect(!instance.particles[0].splash_active);
    try instance.advance(&packet, 357, &draws);
    try std.testing.expectEqual(@as(usize, 184), draws.cursor);
    try std.testing.expectEqualDeep([3]i32{ 53248, 204800, -499712 }, instance.particles[8].head);
    for (instance.particles[8..32]) |node| try std.testing.expect(node.active and node.age == 1);
    try instance.advance(&packet, 397, &draws);
    try std.testing.expectEqual(@as(usize, 472), draws.cursor);
    try std.testing.expectEqualDeep([3]i32{ -73728, -49152, -589824 }, instance.particles[8].head);
    try instance.advance(&packet, 485, &draws);
    try std.testing.expectEqual(@as(usize, 472), draws.cursor);
    for (instance.particles[0..32]) |node| try std.testing.expect(!node.active and !node.splash_active);
    const spells = try allocator.dupe(battle.spell_scene.Spell, packet.spells);
    defer allocator.free(spells);
    packet.spells = spells;
    for (spells, 0..) |*spell, i| if (i != id) {
        spell.program = null;
        spell.blocker = "not under test";
    };
    const emitters = try allocator.dupe(battle.spell_scene.Emitter, spells[id].program.?.emitters);
    defer allocator.free(emitters);
    const original = emitters[0];
    spells[id].program.?.emitters = emitters;
    try packet.validate(4096, 4096);
    emitters[0].spark_velocity_z = 1;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    emitters[0] = original;
    emitters[0].spark_min_z = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    emitters[0] = original;
    emitters[0].spawn_override = .{ 134217729, 0, 0 };
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    emitters[0] = original;
    emitters[0].initial_delays = false;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    emitters[0] = original;
    packet = spellOnlyFixture(packet);
    packet.schema = "suikoden-spell-scenes/22";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "Final Flame ballistics retain late birth ordering and bound gravity and delay inputs" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    const id = packet.indexOf("spell_29").?;
    var draws = battle.systems.Draws{ .bios_state = 17 };
    var instance = try battle.spell_scene.Instance.begin(&packet, id, .{ 120, 50, 0 }, .{ -128, 0, 0 }, battle.drops.initial_camera, &draws);
    try instance.advance(&packet, 65, &draws);
    try std.testing.expectEqual(@as(usize, 123), draws.cursor);
    try std.testing.expectEqualDeep([3]i32{ -28672, -28672, -94549 }, instance.particles[0].head);
    try instance.advance(&packet, 208, &draws);
    try std.testing.expectEqual(@as(u16, 208), instance.last_landing);
    try std.testing.expect(instance.particles[20].splash_active);
    try instance.advance(&packet, 373, &draws);
    try std.testing.expectEqual(@as(usize, 404), draws.cursor);
    try std.testing.expectEqualDeep([3]i32{ -38400, -8192, 76800 }, instance.particles[49].head);
    try instance.advance(&packet, 388, &draws);
    try std.testing.expectEqual(@as(usize, 430), draws.cursor);
    try std.testing.expectEqualDeep([3]i32{ -614400, -8192, 1228800 }, instance.particles[49].splash_position);
    try instance.advance(&packet, 586, &draws);
    try std.testing.expectEqual(@as(usize, 532), draws.cursor);
    for (instance.particles[0..80]) |node| try std.testing.expect(!node.active and !node.splash_active);
    const spells = try allocator.dupe(battle.spell_scene.Spell, packet.spells);
    defer allocator.free(spells);
    packet.spells = spells;
    for (spells, 0..) |*spell, i| if (i != id) {
        spell.program = null;
        spell.blocker = "not under test";
    };
    const emitters = try allocator.dupe(battle.spell_scene.Emitter, spells[id].program.?.emitters);
    defer allocator.free(emitters);
    spells[id].program.?.emitters = emitters;
    const falling = emitters[0];
    const flames = emitters[2];
    try packet.validate(4096, 4096);
    emitters[0].gravity = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    emitters[0] = falling;
    emitters[0].gravity = -65536;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    emitters[0] = falling;
    emitters[2].spawn_stop = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    emitters[2] = flames;
    emitters[1].landing_z = -1;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "Charm Arrow coverage and pixels agree with independent native-byte erasure vectors" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    const packet = parsed.value;
    const id = packet.indexOf("spell_8").?;
    const erode = packet.spells[id].program.?.erosion.?;
    const Row = struct { seed: u32, draws: usize, coverage: []const u8, pixels: []const u8 };
    for ([_]Row{
        .{ .seed = 0, .draws = 24715, .coverage = "5b0786e5b68f07353f74c7979c72c5567165ca7ba0939e450d0fefd99c1b6f38", .pixels = "4ee8faa18c385004f5c199576f241b97ea11e9f5eff15d3431b51cfbb455859d" },
        .{ .seed = 17, .draws = 24515, .coverage = "e96567306036d9db063359128af249884311386a94bb226ceaeeca6cfcfe82d6", .pixels = "4c649bffd08d83e2170f46ac17384d1f5d3cbf452a1e8083a66c609ab1b775c5" },
    }) |row| {
        var draws = battle.systems.Draws{ .bios_state = row.seed };
        var instance = try battle.spell_scene.Instance.begin(&packet, id, .{ 120, 50, 0 }, .{ -128, 0, 0 }, battle.drops.initial_camera, &draws);
        try instance.advance(&packet, 160, &draws);
        try std.testing.expectEqual(@as(usize, 0), draws.cursor);
        try std.testing.expectEqualSlices(u2, erode.levels, instance.coverage[0..erode.levels.len]);
        const frame = battle.spell_scene.frameAt(&packet, &instance, 160);
        var glyph = false;
        for (frame.commands[0..frame.count]) |command| if (command.texture == erode.entry) {
            glyph = true;
            try std.testing.expectEqual(@as(i32, 6), command.depth);
            try std.testing.expectEqual(battle.spell_scene.Blend.@"opaque", command.blend);
        };
        try std.testing.expect(glyph);
        try instance.advance(&packet, 224, &draws);
        try std.testing.expectEqual(row.draws, draws.cursor);
        var expanded: [16384]u8 = undefined;
        for (instance.coverage, 0..) |level, i| expanded[i] = level;
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&expanded, &hash, .{});
        var expected: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected, row.coverage);
        try std.testing.expectEqualSlices(u8, &expected, &hash);
        var pixels: [4096][4]u8 = undefined;
        try std.testing.expect(battle.spell_scene.erosionPixels(&packet, &instance, erode.entry, &pixels));
        std.crypto.hash.sha2.Sha256.hash(std.mem.asBytes(&pixels), &hash, .{});
        _ = try std.fmt.hexToBytes(&expected, row.pixels);
        try std.testing.expectEqualSlices(u8, &expected, &hash);
        try std.testing.expect(!battle.spell_scene.erosionPixels(&packet, &instance, erode.entry + 1, &pixels));
        try instance.advance(&packet, 225, &draws);
        try std.testing.expectEqual(row.draws, draws.cursor);
    }
}

test "Charm Arrow validates coverage references and clears low-weight textures without RNG" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    const id = packet.indexOf("spell_8").?;
    const spells = try allocator.dupe(battle.spell_scene.Spell, packet.spells);
    defer allocator.free(spells);
    packet.spells = spells;
    for (spells, 0..) |*spell, i| if (i != id) {
        spell.program = null;
        spell.blocker = "not under test";
    };
    const original = spells[id].program.?.erosion.?;
    spells[id].program.?.erosion.?.view_cells = &.{0};
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[id].program.?.erosion = original;
    spells[id].program.?.erosion.?.budget = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[id].program.?.erosion = original;
    spells[id].program.?.erosion.?.stop = 226;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[id].program.?.erosion = original;
    packet = spellOnlyFixture(packet);
    packet.schema = "suikoden-spell-scenes/24";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    packet.schema = "suikoden-spell-scenes/25";
    var levels: [16384]u2 = @splat(0);
    var lower: [16384]bool = @splat(false);
    levels[0] = 1;
    lower[0] = true;
    spells[id].program.?.erosion.?.levels = &levels;
    spells[id].program.?.erosion.?.lower_present = &lower;
    try packet.validate(4096, 4096);
    var draws = battle.systems.Draws{ .values = &.{} };
    var instance = try battle.spell_scene.Instance.begin(&packet, id, .{ 120, 50, 0 }, .{ -128, 0, 0 }, battle.drops.initial_camera, &draws);
    try instance.advance(&packet, 161, &draws);
    try std.testing.expectEqual(@as(u2, 0), instance.coverage[0]);
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    levels[0] = 2;
    lower[0] = false;
    spells[id].program.?.erosion.?.minimum_weight = 160;
    spells[id].program.?.erosion.?.budget = 160;
    try packet.validate(4096, 4096);
    // Phantom high-only weight can otherwise request more successful removals than exist.
    @memset(&levels, 2);
    try packet.validate(4096, 4096);
    spells[id].program.?.erosion.?.stop = 300;
    spells[id].program.?.duration = 300;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "warp capture accepts scene commands at its depth and excludes background samplers" {
    const vertices: [4]battle.spell_scene.Point = @splat(.{ .x = 0, .y = 0 });
    var command = battle.spell_scene.Command{ .vertices = vertices, .depth = 382 };
    try std.testing.expect(command.drawsInPass(382));
    try std.testing.expect(!command.drawsInPass(383));
    command.background_uv = vertices;
    try std.testing.expect(!command.drawsInPass(380));
    try std.testing.expect(command.drawsInPass(null));
}

test "shared background warp matches independent screen sampling and bounds imported geometry" {
    const Case = struct { update: u16, block: @import("battle_camera").Block, commands: []const struct { kind: []const u8, vertices: []const [2]f32, background_uv: []const [2]f32, blend: []const u8, intensity: [3]u8, depth: i32 } };
    const Fixture = struct { warp: battle.spell_scene.BackgroundWarp, cases: []const Case };
    const fixture = try std.json.parseFromSlice(Fixture, allocator, @embedFile("fixtures/spell_warp_geometry.json"), .{});
    defer fixture.deinit();
    for (fixture.value.cases) |case| {
        var frame = battle.spell_scene.Frame{ .wash = @splat(0), .wash_blend = .additive };
        battle.spell_scene.appendBackgroundWarp(&frame, fixture.value.warp, case.block, case.update);
        try std.testing.expectEqual(case.commands.len, frame.count);
        for (case.commands, frame.commands[0..frame.count]) |expected, actual| {
            try std.testing.expectEqual(@as(u8, @intCast(expected.vertices.len)), actual.count);
            try std.testing.expect(actual.texture == null and actual.background_uv != null);
            try std.testing.expectEqual(expected.depth, actual.depth);
            try std.testing.expectEqual(battle.spell_scene.Blend.@"opaque", actual.blend);
            for (expected.vertices, expected.background_uv, 0..) |point, uv, i| {
                try std.testing.expectEqual(point[0], actual.vertices[i].x);
                try std.testing.expectEqual(point[1], actual.vertices[i].y);
                try std.testing.expectEqual(uv[0], actual.background_uv.?[i].x);
                try std.testing.expectEqual(uv[1], actual.background_uv.?[i].y);
            }
        }
    }
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    const spells = try allocator.dupe(battle.spell_scene.Spell, packet.spells);
    defer allocator.free(spells);
    packet.spells = spells;
    for (spells) |*spell| {
        spell.program = null;
        spell.blocker = "not under test";
    }
    const warps = try allocator.dupe(battle.spell_scene.BackgroundWarp, &.{fixture.value.warp});
    defer allocator.free(warps);
    const wash: [323][3]u8 = @splat(@splat(0));
    spells[21].blocker = null;
    spells[21].program = .{ .group = true, .impact = 320, .duration = 322, .initial_draws = 0, .tracks = &.{&.{.{}}}, .objects = &.{}, .cameras = &.{}, .meshes = &.{}, .wash = &wash, .wash_blend = .subtractive, .background_warps = warps };
    packet = spellOnlyFixture(packet);
    packet.schema = "suikoden-spell-scenes/26";
    try packet.validate(4096, 4096);
    var draws = battle.systems.Draws{ .values = &.{} };
    const instance = try battle.spell_scene.Instance.begin(&packet, 21, .{ 120, 50, 0 }, .{ -128, 0, 0 }, battle.drops.initial_camera, &draws);
    const frame = battle.spell_scene.frameAt(&packet, &instance, 129);
    try std.testing.expectEqual(@as(usize, 72), frame.count);
    warps[0].depth = 510;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    warps[0] = fixture.value.warp;
    const faces = try allocator.dupe(battle.spell_scene.WarpFace, warps[0].faces);
    defer allocator.free(faces);
    warps[0].faces = faces;
    faces[0].indices[0] = 193;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    faces[0] = fixture.value.warp.faces[0];
    faces[0].count = 2;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    faces[0] = fixture.value.warp.faces[0];
    packet.schema = "suikoden-spell-scenes/25";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    try std.testing.expectEqual(@as(u16, 380), battle.spell_scene.groundDepth(-400));
    try std.testing.expectEqual(@as(u16, 381), battle.spell_scene.groundDepth(7));
    try std.testing.expectEqual(@as(u16, 382), battle.spell_scene.groundDepth(8));
    try std.testing.expectEqual(@as(u16, 509), battle.spell_scene.groundDepth(100000));
}

test "imported Voice actor transforms retain fractional jump inputs, home and size residue" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    const program = parsed.value.spells[21].program.?;
    var target = battle.spell_scene.Target{ .position = .{ -152, -28, 45 }, .home = .{ -152, -28, 45 }, .motion_origin = .{ -152 * 4096 - 17, -28 * 4096 + 11, 45 * 4096 + 3 }, .size_base = 4096 };
    try std.testing.expect(try battle.spell_scene.actorTransform(program, target, 144) == null);
    const first = (try battle.spell_scene.actorTransform(program, target, 145)).?;
    try std.testing.expectEqualDeep([3]i32{ -152 * 4096 - 17, -28 * 4096 + 11, 45 * 4096 + 3 - 16384 }, first.position);
    const arrived = (try battle.spell_scene.actorTransform(program, target, 176)).?;
    try std.testing.expectEqualDeep([3]i32{ -120 * 4096, 0, 0 }, arrived.position);
    try std.testing.expectEqual(@as(i32, 16), (try battle.spell_scene.actorTransform(program, target, 192)).?.size);
    target.return_origin = .{ -120 * 4096 + 7, 0, -65536 };
    const returned = (try battle.spell_scene.actorTransform(program, target, 304)).?;
    try std.testing.expectEqualDeep([3]i32{ -152 * 4096, -28 * 4096, 45 * 4096 }, returned.position);
    try std.testing.expectEqual(@as(i32, 4181), (try battle.spell_scene.actorTransform(program, target, 305)).?.size);
    target.size_base = 4181;
    try std.testing.expectEqual(@as(i32, 101), (try battle.spell_scene.actorTransform(program, target, 192)).?.size);
    try std.testing.expectEqual(@as(i32, 4266), (try battle.spell_scene.actorTransform(program, target, 322)).?.size);
    target.movable = false;
    try std.testing.expect(try battle.spell_scene.actorTransform(program, target, 200) == null);
}

test "sampled source columns match every Hell collapse boundary and reject invalid shapes" {
    const Case = struct { update: u16, commands: []const struct { vertices: [4][2]f32, colors: [4][3]u8, depth: i32 } };
    const Fixture = struct { packet: battle.spell_scene.Packet, cases: []const Case };
    const fixture = try std.json.parseFromSlice(Fixture, allocator, @embedFile("fixtures/soul_column_geometry.json"), .{});
    defer fixture.deinit();
    var packet = fixture.value.packet;
    try packet.validate(4096, 4096);
    var draws = battle.systems.Draws{ .values = &.{} };
    const instance = try battle.spell_scene.Instance.begin(&packet, 0, @splat(0), @splat(0), battle.drops.initial_camera, &draws);
    for (fixture.value.cases) |case| {
        const frame = battle.spell_scene.frameAt(&packet, &instance, case.update);
        try std.testing.expectEqual(case.commands.len, frame.count);
        for (case.commands, frame.commands[0..frame.count]) |expected, actual| {
            try std.testing.expectEqual(@as(u8, 4), actual.count);
            try std.testing.expectEqual(expected.depth, actual.depth);
            try std.testing.expectEqualDeep(expected.colors, actual.colors);
            for (expected.vertices, actual.vertices) |xy, point| {
                try std.testing.expectEqual(xy[0], point.x);
                try std.testing.expectEqual(xy[1], point.y);
            }
        }
    }
    packet = spellOnlyFixture(packet);
    packet.schema = "suikoden-spell-scenes/27";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    packet.schema = fixture.value.packet.schema;
    const spells = try allocator.dupe(battle.spell_scene.Spell, packet.spells);
    defer allocator.free(spells);
    packet.spells = spells;
    const meshes = try allocator.dupe(battle.spell_scene.Mesh, spells[0].program.?.meshes);
    defer allocator.free(meshes);
    spells[0].program.?.meshes = meshes;
    const original = meshes[0];
    meshes[0].shape_samples = original.shape_samples[0..315];
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    meshes[0] = original;
    meshes[0].kind = .fan;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    meshes[0] = original;
    const shapes = try allocator.dupe(battle.spell_scene.ColumnShape, original.shape_samples);
    defer allocator.free(shapes);
    meshes[0].shape_samples = shapes;
    shapes[225].radius = -1;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    shapes[225] = original.shape_samples[225];
    shapes[225].top_radius = 1025;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    shapes[225] = original.shape_samples[225];
    shapes[225].height = 32768;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "source point particles preserve explicit slot scales RNG births movement and pixel geometry" {
    const Particle = struct { active: bool, life: u16, head: [3]i32, velocity: [3]i32, scale: i32 };
    const Case = struct { update: u16, draw_count: usize, particles: []const Particle, commands: []const struct { vertices: [4][2]f32, colors: [4][3]u8, depth: i32 } };
    const Fixture = struct { packet: battle.spell_scene.Packet, runs: []const struct { seed: u32, cases: []const Case } };
    const fixture = try std.json.parseFromSlice(Fixture, allocator, @embedFile("fixtures/soul_point_geometry.json"), .{});
    defer fixture.deinit();
    var packet = fixture.value.packet;
    try packet.validate(4096, 4096);
    for (fixture.value.runs) |run| {
        var draws = battle.systems.Draws{ .bios_state = run.seed };
        var instance = try battle.spell_scene.Instance.begin(&packet, 0, @splat(0), @splat(0), battle.drops.initial_camera, &draws);
        for (run.cases) |case| {
            try instance.advance(&packet, case.update, &draws);
            try std.testing.expectEqual(case.draw_count, draws.cursor);
            for (case.particles, instance.particles[0..case.particles.len]) |expected, actual| {
                try std.testing.expectEqual(expected.active, actual.active);
                try std.testing.expectEqual(expected.life, actual.life);
                try std.testing.expectEqualDeep(expected.head, actual.head);
                try std.testing.expectEqualDeep(expected.velocity, actual.velocity);
                try std.testing.expectEqual(expected.scale, actual.spawn_scale[0]);
            }
            const frame = battle.spell_scene.frameAt(&packet, &instance, case.update);
            try std.testing.expectEqual(case.commands.len, frame.count);
            for (case.commands, frame.commands[0..frame.count]) |expected, actual| {
                try std.testing.expectEqual(@as(u8, 4), actual.count);
                try std.testing.expectEqual(expected.depth, actual.depth);
                try std.testing.expectEqual(battle.spell_scene.Blend.@"opaque", actual.blend);
                try std.testing.expectEqualDeep(expected.colors, actual.colors);
                for (expected.vertices, actual.vertices) |xy, point| {
                    try std.testing.expectEqual(xy[0], point.x);
                    try std.testing.expectEqual(xy[1], point.y);
                }
            }
        }
    }
    packet = spellOnlyFixture(packet);
    packet.schema = "suikoden-spell-scenes/28";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    packet.schema = fixture.value.packet.schema;
    const spells = try allocator.dupe(battle.spell_scene.Spell, packet.spells);
    defer allocator.free(spells);
    packet.spells = spells;
    const original = spells[0].program.?.emitter.?;
    spells[0].program.?.emitter.?.point_initial_scales = &.{};
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[0].program.?.emitter = original;
    spells[0].program.?.emitter.?.point_initial_scales = &(@as([40]i32, @splat(65537)));
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    spells[0].program.?.emitter = original;
    spells[0].program.?.emitter.?.origin[1] = 1;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "Deadly shared line gap and target-warp data reject unsupported inputs" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    const spells = try allocator.dupe(battle.spell_scene.Spell, packet.spells);
    defer allocator.free(spells);
    packet.spells = spells;
    const program = &spells[24].program.?;
    const original = program.emitter.?;
    packet = spellOnlyFixture(packet);
    packet.schema = "suikoden-spell-scenes/29";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    packet.schema = parsed.value.schema;
    program.emitter.?.life_max = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    program.emitter = original;
    program.emitter.?.trail_range = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    program.emitter = original;
    program.emitter.?.scale_track = 999;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    program.emitter = original;
    const meshes = try allocator.dupe(battle.spell_scene.Mesh, program.meshes);
    defer allocator.free(meshes);
    program.meshes = meshes;
    const mesh = meshes[0];
    meshes[0].segment_gap = 409;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    meshes[0] = mesh;
    meshes[0].kind = .fan;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    meshes[0] = mesh;
    const warps = try allocator.dupe(battle.spell_scene.BackgroundWarp, program.background_warps);
    defer allocator.free(warps);
    program.background_warps = warps;
    warps[0].anchor = .caster;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "battle schema seventeen requires Unite return clocks and source pose identities" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer parsed.deinit();
    try parsed.value.validate();
    var content = parsed.value;
    const profiles = try allocator.dupe(battle.Profile, content.party);
    defer allocator.free(profiles);
    content.party = profiles;
    const scenes = try allocator.dupe(battle.UniteScene, profiles[1].unite_scenes);
    defer allocator.free(scenes);
    profiles[1].unite_scenes = scenes;
    const ready = scenes[0].track.motion.ready_tick;
    scenes[0].track.motion.ready_tick = null;
    try std.testing.expectError(error.MissingUniteReady, content.validate());
    scenes[0].track.motion.ready_tick = ready;
    const frames = try allocator.dupe(battle.Frame, scenes[0].track.attack);
    defer allocator.free(frames);
    scenes[0].track.attack = frames;
    frames[0].source_pose = null;
    try std.testing.expectError(error.MissingUnitePose, content.validate());
}

test "legacy battle completion waits for playback before dispatch and allows defeat after an action" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/battle_canonical.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(parsed.value, items.value, &members, 17);
    for (state.progress.party.items()) |member| member.hp = 0;
    @memset(state.enemy_hp[0..state.enemyCount()], 0);
    state.phase = .resolving;
    state.active = null;
    state.unite_returns[0] = .{ .owner = 0, .target = state.partyCount(), .ticks = 0, .target_released = false, .handoff_at = state.camera_ticks +% 1 };
    state.nextAction();
    try std.testing.expectEqual(battle.Phase.resolving, state.phase);

    state.active = .{ .actor = 0, .target = 0, .kind = .defend };
    state.action_ticks = state.actionDuration() - 1;
    state.tick(.{});
    try std.testing.expect(state.active == null and state.hasUniteReturns());
    try std.testing.expectEqual(battle.Phase.defeat, state.phase);
    try std.testing.expect(!state.rewards_committed);

    state.unite_returns[0] = null;
    state.phase = .resolving;
    state.nextAction();
    try std.testing.expectEqual(battle.Phase.defeat, state.phase);
    try std.testing.expect(!state.rewards_committed);
}

test "coordinated battle completion waits for revival and playback before the 31-tick victory delay" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/battle_canonical.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(parsed.value, items.value, &members, 17);
    for (state.progress.party.items()) |member| member.hp = 0;
    @memset(state.enemy_hp[0..state.enemyCount()], 0);
    state.phase = .resolving;
    state.coordinator = .{ .stage = .round_ready, .current_actor = 0, .elapsed = 7 };
    state.action_ticks = 7;
    state.party_knockouts[0].revival = .{ .started_at = state.camera_ticks, .origin = .{ .x = 0, .y = 0, .z = 0 }, .screen_offset = .{ 0, 0 }, .original_status = .healthy };

    state.tick(.{});
    try std.testing.expectEqual(.round_ready, state.coordinator.?.stage);
    try std.testing.expectEqual(@as(u16, 7), state.action_ticks);
    state.party_knockouts[0].revival = null;
    state.unite_returns[0] = .{ .owner = 0, .target = state.partyCount(), .ticks = 0, .target_released = false, .handoff_at = state.camera_ticks +% 1 };
    state.tick(.{});
    try std.testing.expectEqual(.round_ready, state.coordinator.?.stage);
    try std.testing.expectEqual(@as(u16, 7), state.action_ticks);

    state.unite_returns[0] = null;
    state.tick(.{});
    try std.testing.expectEqual(.victory_wait, state.coordinator.?.stage);
    try std.testing.expectEqual(@as(u16, 8), state.action_ticks);
    const balance = state.progress.money;
    const random = state.random;
    for (0..30) |_| {
        state.tick(.{});
        try std.testing.expectEqual(battle.Phase.resolving, state.phase);
        try std.testing.expect(!state.rewards_committed);
    }
    try std.testing.expectEqual(balance, state.progress.money);
    try std.testing.expectEqualDeep(random, state.random);
    state.tick(.{});
    try std.testing.expectEqual(battle.Phase.victory, state.phase);
    try std.testing.expectEqual(balance + state.enemy(0).money, state.progress.money);
    try std.testing.expect(state.rewards_committed and state.coordinator == null);
}

test "Unite recipient recoil preserves Q12 residue fixed-white poses and home restoration" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    const packet = parsed.value;
    try packet.validate(4096, 4096);
    try std.testing.expectEqual(@as(usize, 38), packet.unite_reactions.len);
    var blocked: usize = 0;
    for (packet.unite_reactions) |reaction| if (reaction.blocker != null) {
        blocked += 1;
    };
    try std.testing.expectEqual(@as(usize, 0), blocked);
    const pose = for (packet.hurt_poses) |p| {
        if (std.mem.eql(u8, p.id, "bonbon")) break p;
    } else unreachable;
    for (packet.unite_reactions) |reaction| {
        if (reaction.record > 1) continue;
        const duration: i32 = if (reaction.record == 0) 32 else 16;
        const origin = [3]i32{ 120 * 4096 + 137, -33 * 4096 + 197, -3 * 4096 + 271 };
        const home = [3]i32{ 128 * 4096, -20 * 4096, 0 };
        var expected = origin;
        var velocity = [3]i32{ -6144, 0, 0 };
        var acceleration: [3]i32 = undefined;
        for (0..3) |axis| {
            const delta = if (axis == 2) -origin[axis] else 0;
            acceleration[axis] = @divTrunc(delta - velocity[axis] * duration, @divTrunc(duration * (duration - 1), 2));
        }
        for (0..reaction.duration + 1) |age| {
            if (age >= 2 and age < 2 + duration) {
                for (0..3) |axis| {
                    expected[axis] += velocity[axis];
                    velocity[axis] += acceleration[axis];
                }
                if (age == 1 + duration) expected = .{ origin[0], origin[1], 0 };
            }
            if (age == reaction.duration - 1) expected = home;
            try std.testing.expectEqualDeep(expected, battle.spell_scene.unitePosition(reaction, origin, home, @intCast(age)));
            const sample = battle.spell_scene.uniteReactionAt(reaction, pose, @intCast(age));
            if (age >= reaction.duration) {
                try std.testing.expect(sample == null);
                continue;
            }
            try std.testing.expectEqual(@as(u8, if (age == reaction.duration - 1) 0 else 1), sample.?.animation);
            const white = age >= 2 and age < reaction.duration - 2;
            try std.testing.expectEqual(if (age == reaction.duration - 1) @as(?u16, null) else if (white) pose.white_entry else pose.entry, sample.?.entry);
        }
    }
    var old = packet;
    old.schema = "suikoden-spell-scenes/31";
    try std.testing.expectError(error.InvalidSpellScenes, old.validate(4096, 4096));
    var future = packet;
    future.schema = "suikoden-spell-scenes/53";
    try std.testing.expectError(error.InvalidSpellScenes, future.validate(4096, 4096));
}

test "Ninja recipient keeps absolute movement flip uncentered impact and focus pulse timing" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const packet = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer packet.deinit();
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(parsed.value, items.value, &members, 17);
    try state.attachSpellScenes(&packet.value);
    const target = state.partyCount();
    const origin = [3]i32{ 120 * 4096 + 137, -33 * 4096 + 197, -3 * 4096 + 271 };
    const home = [3]i32{ 128 * 4096, -20 * 4096, 0 };
    state.unite_reactions[target] = .{ .record = 28, .variant = 1, .started_at = 100, .origin_q12 = origin, .home_q12 = home };
    const reaction = for (packet.value.unite_reactions) |r| {
        if (r.record == 28 and r.variant == 1) break r;
    } else unreachable;
    const camera = @import("battle_camera");
    state.actor_camera = try camera.ActorController.init(battle.drops.initial_camera);
    try state.actor_camera.?.request(.{ .at = 1, .updates = 200, .channel = .focus, .binding = .absolute, .target_q12 = .{ 24576, 8192, 4096 } }, .{ 0, 0, 0 });
    var expected = origin;
    var velocity: [3]i32 = undefined;
    var acceleration: [3]i32 = undefined;
    var positive_origin: i32 = 0;
    for (0..141) |age| {
        // Independently integrate the two source jumps one update at a time.
        if (age == 9 or age == 60) {
            const duration: i32 = if (age == 9) 20 else 40;
            velocity = if (age == 9) .{ 0, 0, -16384 } else .{ 0, 0, 0 };
            for (0..3) |axis| {
                const destination: i32 = if (age == 9 and axis == 2) -400 * 4096 else 0;
                acceleration[axis] = @divTrunc(destination - expected[axis] - velocity[axis] * duration, @divTrunc(duration * (duration - 1), 2));
            }
        }
        if ((age >= 9 and age <= 28) or (age >= 60 and age <= 99)) {
            for (0..3) |axis| {
                expected[axis] += velocity[axis];
                velocity[axis] += acceleration[axis];
            }
            if (age == 28) expected = .{ 0, 0, -400 * 4096 };
            if (age == 99) expected = .{ 0, 0, 0 };
        }
        try std.testing.expectEqualDeep(expected, battle.spell_scene.unitePosition(reaction, origin, home, @intCast(age)));
        state.camera_ticks = @intCast(100 + age);
        state.advanceActorCamera();
        const before = state.actor_camera.?;
        state.advanceUniteActors();
        try std.testing.expect(state.replay_unsupported == null);
        const after = state.actor_camera.?;
        try std.testing.expectEqualDeep(before.current, after.current);
        try std.testing.expectEqualDeep(before.target, after.target);
        if (age == 100 or age == 102) {
            if (age == 100) positive_origin = after.current[0][2];
            try std.testing.expectEqual(@as(u16, 1), after.remaining[0]);
            try std.testing.expectEqual(before.velocity[0][0], after.velocity[0][0]);
            try std.testing.expectEqual(before.velocity[0][1], after.velocity[0][1]);
            try std.testing.expectEqual(@as(i32, if (age == 100) 20480 else -20480), after.velocity[0][2]);
        }
        if (age == 101) try std.testing.expectEqual(positive_origin + 20480, after.current[0][2]);
        if (age == 102 or age == 104) try std.testing.expectEqualDeep(after.target[0], after.current[0]);
        if (age == 103) try std.testing.expectEqual(after.target[0][2] - 20480, after.current[0][2]);
        const sample = state.spellReaction(target).?;
        const flipped = age >= 60 and age < 116;
        try std.testing.expectEqual(flipped, sample.flip_y);
        const entry = packet.value.entries[sample.entry.?];
        const layout = battle.layout.actorLayout(state, target);
        try std.testing.expectEqual(@as(i16, @intCast(if (flipped) entry.h + entry.dy else -entry.dy)), layout.sprite.anchor_y);
        const frame = state.spellSceneFrame();
        try std.testing.expectEqual(@as(usize, if (age >= 101 and age < 121) 1 else 0), frame.count);
        if (age == 101) {
            const scale = camera.scaleBlock(battle.layout.currentCamera(state));
            const point = battle.layout.worldPoint(state, .{ .x = 5, .y = 5, .z = 0 });
            const texture = packet.value.entries[frame.commands[0].texture.?];
            try std.testing.expectApproxEqAbs(point.x / 2 + @as(f32, @floatFromInt(texture.dx)) * scale, frame.commands[0].vertices[0].x, 0.001);
            try std.testing.expectApproxEqAbs(point.y / 2 + @as(f32, @floatFromInt(texture.dy)) * scale, frame.commands[0].vertices[0].y, 0.001);
        }
        if (age >= 133) {
            try std.testing.expectEqual(@as(u8, 1), sample.animation);
            try std.testing.expect(!sample.flip_y);
            try std.testing.expectEqualDeep(battle.Position{ .x = 0, .y = 0, .z = 0 }, state.uniteActorPosition(target).?);
        }
    }
    // A dead recipient does not issue the pending camera pulse.
    state.enemy_hp[0] = 0;
    state.camera_ticks = 200;
    state.actor_camera = null;
    state.advanceUniteActors();
    try std.testing.expect(state.actor_camera == null);
    state.startEncounter();
    try std.testing.expect(state.unite_reactions[target] == null);
}

test "Ninja recipient schema validates absolute motion flip pulses and legacy serialization" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    packet.status_icons = &.{};
    packet.status_anchors = &.{};
    packet.enemy_magic_art = null;
    packet.needle_burst = &.{};
    packet.physical_white_poses = &.{};
    packet.unite_impacts = packet.unite_impacts[0..3];
    packet.unite_scenes = &.{};
    const original = for (packet.unite_reactions) |r| {
        if (r.record == 28 and r.variant == 1) break r;
    } else unreachable;
    var reactions = [_]battle.spell_scene.UniteReaction{original};
    packet.unite_reactions = &reactions;
    try packet.validate(4096, 4096);
    packet.hurt_poses = &.{};
    packet.schema = "suikoden-spell-scenes/33";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    packet.schema = "suikoden-spell-scenes/34";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    reactions[0].locks_target = true;
    reactions[0].signals = &.{};
    try packet.validate(4096, 4096);
    reactions[0] = original;
    packet.schema = parsed.value.schema;
    reactions[0].flip.?.stop = reactions[0].flip.?.start;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    reactions[0] = original;
    reactions[0].flip.?.stop = original.duration + 1;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    reactions[0] = original;
    const pulses = try allocator.dupe(@TypeOf(original.focus_z_pulses[0]), original.focus_z_pulses);
    defer allocator.free(pulses);
    reactions[0].focus_z_pulses = pulses;
    pulses[0].delta_q12 = std.math.minInt(i32);
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    pulses[0] = original.focus_z_pulses[0];
    pulses[1].at = pulses[0].at;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    pulses[1] = original.focus_z_pulses[1];
    pulses[1].at = original.duration;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    reactions[0] = original;
    const motions = try allocator.dupe(battle.spell_scene.UniteMotion, original.motions);
    defer allocator.free(motions);
    reactions[0].motions = motions;
    motions[0].home = true;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    motions[0] = original.motions[0];
    motions[0].offset_q12[2] = std.math.minInt(i32);
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    // Default fields stay absent from previously supported packet identities.
    reactions[0] = parsed.value.unite_reactions[0];
    packet.schema = "suikoden-spell-scenes/33";
    try packet.validate(4096, 4096);
    const legacy = try std.json.Stringify.valueAlloc(allocator, reactions[0], .{});
    defer allocator.free(legacy);
    for ([_][]const u8{ "absolute", "centered", "flip", "focus_z_pulses", "locks_target" }) |field_name| {
        try std.testing.expect(std.mem.indexOf(u8, legacy, field_name) == null);
    }
}

test "Unite scene parser rejects unsafe motion events and missing impact art" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    packet.status_icons = &.{};
    packet.status_anchors = &.{};
    packet.enemy_magic_art = null;
    packet.needle_burst = &.{};
    const reactions = try allocator.dupe(battle.spell_scene.UniteReaction, packet.unite_reactions);
    defer allocator.free(reactions);
    packet.unite_reactions = reactions;
    const original = reactions[0];
    reactions[0].variant = 4;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    reactions[0] = reactions[1];
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    reactions[0] = original;
    packet.schema = "suikoden-spell-scenes/32";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    packet.schema = parsed.value.schema;
    reactions[0].record = 32;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    reactions[0] = original;
    reactions[0].blocker = "unsupported callback";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    reactions[0] = original;
    const motions = try allocator.dupe(@TypeOf(original.motions[0]), original.motions);
    defer allocator.free(motions);
    reactions[0].motions = motions;
    motions[0].updates = 1;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    motions[0] = original.motions[0];
    motions[1].at = motions[0].at;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    motions[1] = original.motions[1];
    motions[0].velocity_q12[0] = std.math.maxInt(i32);
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    motions[0] = original.motions[0];
    packet.unite_impacts = &.{};
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "Unite record selection retains its own track after controller handoff" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    var content = parsed.value;
    content.unite_graphics = &.{};
    const profiles = try allocator.dupe(battle.Profile, content.party);
    defer allocator.free(profiles);
    content.party = profiles;
    const original = profiles[2].uniteTrack(0).?;
    var alternate = original;
    // Test-only distinction checks record routing; it is not a second recovered Pahn scene.
    alternate.motion.impact_tick -= 1;
    var scenes = [_]battle.UniteScene{ .{ .record = 0, .track = original }, .{ .record = 27, .track = alternate } };
    profiles[2].unite_scenes = &scenes;
    try content.validate();
    try std.testing.expectEqual(original.motion.impact_tick, profiles[2].uniteTrack(0).?.motion.impact_tick);
    try std.testing.expectEqual(alternate.motion.impact_tick, profiles[2].uniteTrack(27).?.motion.impact_tick);
    try std.testing.expect(profiles[2].uniteTrack(29) == null);
    try std.testing.expect(profiles[2].uniteTrack(null) == null);
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(content, items.value, &members, 17);
    combat.active = .{ .actor = 4, .partner = 5, .target = 6, .kind = .unite };
    combat.advanceActiveUniteReturns(); // Legacy/manual actions have no integrated boundary.
    combat.unite_returns[2] = .{ .record = 27, .owner = 2, .target = 6, .ticks = 140, .target_released = true, .handoff_at = 0 };
    try std.testing.expectEqual(alternate.motion.impact_tick, combat.actionMotion(2).?.impact_tick);
    try std.testing.expectEqual(original.attack.ptr, combat.attackFrames(2).ptr);
    combat.unite_returns[2].?.record = 0;
    try std.testing.expectEqual(original.motion.impact_tick, combat.actionMotion(2).?.impact_tick);
    content.schema = "suikoden-battle-trial/18";
    try std.testing.expectError(error.UnsupportedBattleSchema, content.validate());
    content.schema = parsed.value.schema;
    scenes[1].record = 0;
    try std.testing.expectError(error.InvalidUniteSceneBinding, content.validate());
    scenes[1].record = 32;
    try std.testing.expectError(error.InvalidUniteSceneBinding, content.validate());
    scenes[1].record = 27;
    profiles[2].unite_motion = original.motion;
    try std.testing.expectError(error.InvalidUniteSceneBinding, content.validate());
}

test "Unite delayed starts preserve idle phase locks camera offsets and local return clocks" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    var content = parsed.value;
    content.unite_graphics = &.{};
    const profiles = try allocator.dupe(battle.Profile, content.party);
    defer allocator.free(profiles);
    content.party = profiles;
    for (profiles) |*profile| profile.item_art = null;
    const legacy_scenes = try allocator.alloc(battle.UniteScene, profiles.len);
    defer allocator.free(legacy_scenes);
    for (profiles, 0..) |*profile, index| if (profile.unite_scenes.len > 0) {
        try std.testing.expectEqual(@as(usize, 1), profile.unite_scenes.len);
        legacy_scenes[index] = profile.unite_scenes[0];
        legacy_scenes[index].track.trail = null;
        profile.unite_scenes = legacy_scenes[index .. index + 1];
    };
    content.schema = "suikoden-battle-trial/19";
    var scenes = [_]battle.UniteScene{profiles[5].unite_scenes[0]};
    const original = scenes[0].track;
    const legacy_json = try std.json.Stringify.valueAlloc(allocator, original, .{});
    defer allocator.free(legacy_json);
    try std.testing.expect(std.mem.indexOf(u8, legacy_json, "start_after") == null);
    try std.testing.expect(std.mem.indexOf(u8, legacy_json, "reaction_on_hit") == null);
    try std.testing.expect(std.mem.indexOf(u8, legacy_json, "screen_offsets") == null);
    scenes[0].track.start_after = 45;
    profiles[5].unite_scenes = &scenes;
    try std.testing.expectError(error.UnsupportedBattleSchema, content.validate());
    content.schema = "suikoden-battle-trial/20";
    try content.validate();
    scenes[0].track.reaction_on_hit = true;
    try std.testing.expectError(error.UnsupportedBattleSchema, content.validate());
    content.schema = "suikoden-battle-trial/21";
    try content.validate();
    const reaction_json = try std.json.Stringify.valueAlloc(allocator, scenes[0].track, .{});
    defer allocator.free(reaction_json);
    const reaction_roundtrip = try std.json.parseFromSlice(battle.UniteTrack, allocator, reaction_json, .{});
    defer reaction_roundtrip.deinit();
    try std.testing.expect(reaction_roundtrip.value.reaction_on_hit);
    scenes[0].track.reaction_on_hit = false;
    scenes[0].track.start_after = 1000;
    try std.testing.expectError(error.InvalidUniteSceneBinding, content.validate());
    scenes[0].track.start_after = 45;
    const json = try std.json.Stringify.valueAlloc(allocator, scenes[0].track, .{});
    defer allocator.free(json);
    const roundtrip = try std.json.parseFromSlice(battle.UniteTrack, allocator, json, .{});
    defer roundtrip.deinit();
    try std.testing.expectEqual(@as(u16, 45), roundtrip.value.start_after);
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(content, items.value, &members, 17);
    combat.active = .{ .actor = 4, .partner = 5, .target = 6, .kind = .unite };
    combat.action_ticks = 40;
    combat.presentation_tick = 123;
    try std.testing.expect(combat.isActing(5));
    try std.testing.expect(combat.coordinatorLocked(5));
    try std.testing.expect(combat.uniteMemberWaiting(5));
    try std.testing.expectEqual(@as(u16, 0), combat.animationTick(5));
    try std.testing.expectEqualDeep(profiles[5].sprite, battle.layout.actorLayout(combat, 5).sprite);
    const art = try battle.world_art.load(allocator, @embedFile("fixtures/world_b_party_art.json"));
    defer art.deinit();
    combat.content.world_art = art.value;
    var idle = combat;
    idle.active = null;
    try std.testing.expectEqualDeep(battle.world_art.actorSample(art.value, &idle, 5), battle.world_art.actorSample(art.value, &combat, 5));
    combat.action_ticks = 50;
    try std.testing.expect(!combat.uniteMemberWaiting(5));
    try std.testing.expectEqual(@as(u16, 5), combat.animationTick(5));
    var tick: u16 = 5;
    for (original.attack) |frame| {
        if (tick >= frame.ticks) {
            tick -= frame.ticks;
            continue;
        }
        try std.testing.expectEqual(frame.source_pose.?, battle.world_art.actorSample(art.value, &combat, 5).sample.pose);
        break;
    }
    combat.issueUniteCameraRequests(original.camera[0].at);
    try std.testing.expect(combat.actor_camera == null);
    combat.issueUniteCameraRequests(scenes[0].track.start_after + original.camera[0].at);
    try std.testing.expect(combat.actor_camera != null);
    combat.active = null;
    combat.unite_returns[5] = .{ .record = 1, .owner = 4, .target = 6, .ticks = 155, .target_released = true, .handoff_at = 0 };
    try std.testing.expectEqual(@as(u16, 110), combat.animationTick(5));
    combat.content.world_art = null;
    try std.testing.expectEqualDeep(battle.presentation.actorPosition(battle.layout.homePosition(&combat, 5), battle.layout.homePosition(&combat, 6), original.motion, 110), battle.layout.worldPosition(&combat, 5));
    // Older packets must also reject new Unite fields on enemy profiles.
    const enemies = try allocator.dupe(battle.Profile, content.enemies);
    defer allocator.free(enemies);
    content.enemies = enemies;
    for (profiles) |*profile| profile.unite_scenes = &.{};
    enemies[0].unite_scenes = &scenes;
    content.schema = "suikoden-battle-trial/18";
    try std.testing.expectError(error.UnsupportedBattleSchema, content.validate());
}

test "Unite trail schema bounds serialization and retained screen ring" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer parsed.deinit();
    var content = parsed.value;
    content.unite_graphics = &.{};
    const profiles = try allocator.dupe(battle.Profile, content.party);
    defer allocator.free(profiles);
    content.party = profiles;
    for (profiles) |*profile| profile.item_art = null;
    var scene = [_]battle.UniteScene{profiles[2].unite_scenes[0]};
    const sprite = profiles[2].sprite;
    scene[0].track.trail = .{ .start = 13, .stop = 43, .poses = @splat(sprite) };
    profiles[2].unite_scenes = &scene;
    content.schema = "suikoden-battle-trial/21";
    try std.testing.expectError(error.UnsupportedBattleSchema, content.validate());
    content.schema = "suikoden-battle-trial/22";
    try content.validate();
    const json = try std.json.Stringify.valueAlloc(allocator, scene[0].track, .{});
    defer allocator.free(json);
    const decoded = try std.json.parseFromSlice(battle.UniteTrack, allocator, json, .{});
    defer decoded.deinit();
    try std.testing.expectEqualDeep(scene[0].track.trail.?, decoded.value.trail.?);
    scene[0].track.trail.?.start = 0;
    try std.testing.expectError(error.InvalidUniteTrail, content.validate());
    scene[0].track.trail.?.start = 13;
    scene[0].track.trail.?.stop = 13;
    try std.testing.expectError(error.InvalidUniteTrail, content.validate());
    scene[0].track.trail.?.stop = scene[0].track.motion.duration;
    try std.testing.expectError(error.InvalidUniteTrail, content.validate());
    scene[0].track.trail.?.stop = 43;
    scene[0].track.trail.?.poses[0].rect.x = 4095;
    try std.testing.expectError(error.InvalidBattleAssets, content.validate());
    scene[0].track.trail.?.poses[0] = sprite;
    try std.testing.expectError(error.InvalidBattleAssets, content.validateAtlas(1, 1));
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(content, items.value, &members, 17);
    combat.active = .{ .actor = 2, .partner = 3, .target = 6, .kind = .unite };
    for (0..45) |elapsed| {
        combat.action_ticks = @intCast(elapsed);
        const point: battle.presentation.ScreenPoint = .{ .x = @floatFromInt(elapsed * 10), .y = 17, .depth = 20 };
        combat.advanceUniteTrails(@splat(point));
        const visible = elapsed >= 14 and elapsed <= 42;
        const quads = battle.layout.uniteTrail(combat, 2);
        try std.testing.expectEqual(visible, quads != null);
        if (quads) |draws| {
            try std.testing.expectEqualDeep(point, draws[7].point);
            for (draws, 0..) |quad, index| {
                const sampled = @max(@as(usize, 13), elapsed -| (7 - index));
                try std.testing.expectEqual(@as(f32, @floatFromInt(sampled * 10)), quad.point.x);
            }
            combat.camera_ticks += 100;
            try std.testing.expectEqualDeep(draws[0].point, battle.layout.uniteTrail(combat, 2).?[0].point);
        }
        if (elapsed == 43) try std.testing.expect(combat.unite_trails[2].initialized);
        if (elapsed == 44) try std.testing.expect(!combat.unite_trails[2].initialized);
    }
    combat.action_ticks = 13;
    combat.advanceUniteTrails(@splat(.{ .x = 1, .y = 2, .depth = 3 }));
    combat.active = null;
    combat.advanceUniteTrails(@splat(.{ .x = 0, .y = 0, .depth = 1 }));
    try std.testing.expect(!combat.unite_trails[2].initialized);
}

test "Unite screen offsets use signed interpolation target anchors and return restoration" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer parsed.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    var content = parsed.value;
    content.unite_graphics = &.{};
    const profiles = try allocator.dupe(battle.Profile, content.party);
    defer allocator.free(profiles);
    const enemies = try allocator.dupe(battle.Profile, content.enemies);
    defer allocator.free(enemies);
    content.party = profiles;
    for (profiles) |*profile| profile.item_art = null;
    content.enemies = enemies;
    var scenes = [_]battle.UniteScene{profiles[2].unite_scenes[0]};
    const offsets = [_]battle.ScreenOffset{
        .{ .start = 33, .updates = 10, .target = true, .value = .{ 0, 0 } },
        .{ .start = 88, .updates = 20, .target = false, .value = .{ 0, 0 } },
    };
    scenes[0].track.screen_offsets = &offsets;
    profiles[2].unite_scenes = &scenes;
    enemies[1].effect_offset = .{ -10, 10 }; // Wild Boar source anchor.
    content.schema = "suikoden-battle-trial/22";
    try std.testing.expectError(error.UnsupportedBattleSchema, content.validate());
    scenes[0].track.screen_offsets = &.{};
    try std.testing.expectError(error.UnsupportedBattleSchema, content.validate());
    enemies[1].effect_offset = null;
    try content.validate();
    scenes[0].track.screen_offsets = &offsets;
    enemies[1].effect_offset = .{ -10, 10 };
    content.schema = "suikoden-battle-trial/23";
    try content.validate();
    const json = try std.json.Stringify.valueAlloc(allocator, scenes[0].track, .{});
    defer allocator.free(json);
    const decoded = try std.json.parseFromSlice(battle.UniteTrack, allocator, json, .{});
    defer decoded.deinit();
    try std.testing.expectEqualDeep(offsets[0], decoded.value.screen_offsets[0]);
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(content, items.value, &members, 17);
    combat.encounter = 2;
    combat.active = .{ .actor = 2, .partner = 3, .target = 6, .kind = .unite };
    const cases = [_]struct { at: u16, x: i8 }{
        .{ .at = 32, .x = 0 },   .{ .at = 33, .x = -1 },  .{ .at = 34, .x = -2 },
        .{ .at = 41, .x = -9 },  .{ .at = 42, .x = -10 }, .{ .at = 87, .x = -10 },
        .{ .at = 88, .x = -10 }, .{ .at = 97, .x = -10 }, .{ .at = 98, .x = -9 },
        .{ .at = 106, .x = -1 }, .{ .at = 107, .x = 0 },
    };
    for (cases) |case| {
        combat.action_ticks = case.at;
        try std.testing.expectEqual([2]i8{ case.x, -case.x }, combat.uniteScreenOffset(2));
        const shifted = battle.layout.actorLayout(combat, 2);
        scenes[0].track.screen_offsets = &.{};
        const original = battle.layout.actorLayout(combat, 2);
        scenes[0].track.screen_offsets = &offsets;
        try std.testing.expectApproxEqAbs(original.point.x + @as(f32, @floatFromInt(case.x)) * original.scale, shifted.point.x, 0.001);
        try std.testing.expectApproxEqAbs(original.point.y - @as(f32, @floatFromInt(case.x)) * original.scale, shifted.point.y, 0.001);
    }
    const art = try battle.world_art.load(allocator, @embedFile("fixtures/world_b_party_art.json"));
    defer art.deinit();
    combat.content.world_art = art.value;
    combat.action_ticks = 42;
    const shifted_world = battle.layout.actorLayout(combat, 2);
    scenes[0].track.screen_offsets = &.{};
    const original_world = battle.layout.actorLayout(combat, 2);
    scenes[0].track.screen_offsets = &offsets;
    try std.testing.expectApproxEqAbs(original_world.point.x - 10 * original_world.scale, shifted_world.point.x, 0.001);
    try std.testing.expectApproxEqAbs(original_world.point.y + 10 * original_world.scale, shifted_world.point.y, 0.001);
    combat.content.world_art = null;
    combat.unite_returns[2] = .{ .record = 0, .owner = 2, .target = 6, .ticks = 98, .target_released = true, .handoff_at = 0 };
    combat.active = .{ .actor = 0, .target = 1, .kind = .attack };
    try std.testing.expectEqual([2]i8{ -9, 9 }, combat.uniteScreenOffset(2));
    combat.unite_returns[2] = null;
    combat.active = .{ .actor = 2, .partner = 3, .target = 6, .kind = .unite };
    combat.action_ticks = 42;
    enemies[1].effect_offset = .{ 130, -130 };
    try std.testing.expectEqual([2]i8{ -126, 126 }, combat.uniteScreenOffset(2));
    enemies[1].effect_offset = .{ -10, 10 };
    combat.active = null;
    try std.testing.expectEqual([2]i8{ 0, 0 }, combat.uniteScreenOffset(2));
    combat.actor_transforms[2].screen_offset = .{ 5, -5 };
    combat.content.world_art = art.value;
    try std.testing.expectEqual([2]i8{ 0, 0 }, combat.uniteScreenOffset(2));
    combat.content.world_art = null;
    profiles[2].revival_art = null;
    const revival_origin = battle.layout.homePosition(&combat, 2);
    combat.party_knockouts[2].revival = .{ .started_at = combat.camera_ticks, .origin = revival_origin, .screen_offset = .{ 5, -5 }, .original_status = .healthy };
    const old_revival = battle.layout.actorLayout(combat, 2);
    const old_origin = battle.layout.worldPoint(combat, revival_origin);
    try std.testing.expectApproxEqAbs(old_origin.y - 5 * old_revival.scale, old_revival.point.y, 0.001);
    combat.party_knockouts[2].revival = null;
    combat.actor_transforms[2].screen_offset = .{ 0, 0 };
    var bad = offsets;
    scenes[0].track.screen_offsets = &bad;
    bad[0].updates = 0;
    try std.testing.expectError(error.InvalidUniteScreenOffset, content.validate());
    bad = offsets;
    bad[1].start = 34;
    try std.testing.expectError(error.InvalidUniteScreenOffset, content.validate());
    bad = offsets;
    bad[0].start = 0;
    try std.testing.expectError(error.InvalidUniteScreenOffset, content.validate());
    bad = offsets;
    bad[0].value[0] = 513;
    try std.testing.expectError(error.InvalidUniteScreenOffset, content.validate());
    bad = offsets;
    enemies[1].effect_offset = .{ 513, 0 };
    try std.testing.expectError(error.InvalidUniteScreenOffset, content.validate());
}

test {
    _ = @import("battle_actor_program.zig");
}

test {
    _ = @import("battle_actor_host.zig");
}

test "Kobold accepts seven target-relative hops including its post-hit hop and bounds retreat" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/blacksmith_battle.json"));
    defer parsed.deinit();
    var content = parsed.value;
    const profiles = try allocator.dupe(battle.Profile, content.party);
    defer allocator.free(profiles);
    content.party = profiles;
    const index = for (profiles, 0..) |profile, slot| {
        if (std.mem.eql(u8, profile.id, "kuromimi")) break slot;
    } else return error.MissingUniteParticipant;
    var scenes = [_]battle.UniteScene{profiles[index].unite_scenes[0]};
    profiles[index].unite_scenes = &scenes;
    const motion = scenes[0].track.motion;
    try std.testing.expectEqual(@as(usize, 7), motion.stages.len);
    try std.testing.expectEqual(@as(u16, 99), motion.stages[6].start);
    try std.testing.expectEqual(@as(u16, 98), motion.impact_tick);
    try std.testing.expectEqualDeep(battle.Position{ .x = 170, .y = 60, .z = 0 }, battle.presentation.actorPosition(.{ .x = 10, .y = 20, .z = 0 }, .{ .x = 100, .y = 40, .z = 0 }, motion, 109));
    var stages: [8]battle.presentation.Stage = undefined;
    @memcpy(stages[0..7], motion.stages);
    stages[7] = stages[6];
    stages[7].start += stages[6].leap.ticks;
    scenes[0].track.motion.stages = &stages;
    try std.testing.expectError(error.InvalidBattleAssets, content.validate());
    scenes[0].track.motion.stages = stages[0..7];
    stages[6].start = motion.return_start;
    try std.testing.expectError(error.InvalidBattleAssets, content.validate());
}

test "Unite child art validates source pose keys and preserves legacy serialization" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/blacksmith_battle.json"));
    defer parsed.deinit();
    var content = parsed.value;
    try std.testing.expectEqual(@as(usize, 42), content.unite_graphics.len);
    const programs = try battle.actor_host.loadBundle(allocator, @embedFile("fixtures/battle_actor_library.json"));
    defer programs.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(content, items.value, &members, 17);
    try combat.attachUniteActors(&programs.value);
    var bad = [_]battle.UniteGraphic{content.unite_graphics[0]};
    bad[0].id = "missing_resource";
    combat.content.unite_graphics = &bad;
    try std.testing.expectError(error.InvalidUniteGraphics, combat.attachUniteActors(&programs.value));
    bad[0] = content.unite_graphics[0];
    const bad_pose = [_]battle.UniteGraphicPose{.{ .id = 255, .sprite = bad[0].poses[0].sprite }};
    bad[0].poses = &bad_pose;
    try std.testing.expectError(error.InvalidUniteGraphics, combat.attachUniteActors(&programs.value));
    content.schema = "suikoden-battle-trial/23";
    try std.testing.expectError(error.InvalidUniteGraphics, content.validate());
    content.schema = parsed.value.schema;
    const duplicate = [_]battle.UniteGraphic{ content.unite_graphics[0], content.unite_graphics[0] };
    content.unite_graphics = &duplicate;
    try std.testing.expectError(error.InvalidUniteGraphics, content.validate());
    var poses = [_]battle.UniteGraphicPose{ duplicate[0].poses[0], duplicate[0].poses[0] };
    var graphics = [_]battle.UniteGraphic{.{ .id = duplicate[0].id, .poses = &poses }};
    content.unite_graphics = &graphics;
    try std.testing.expectError(error.InvalidUniteGraphics, content.validate());
    graphics[0].poses = poses[0..1];
    poses[0].id = 256;
    try std.testing.expectError(error.InvalidUniteGraphics, content.validate());
    poses[0] = duplicate[0].poses[0];
    poses[0].sprite.rect.w = 0;
    try std.testing.expectError(error.InvalidBattleAssets, content.validate());
    content.unite_graphics = &.{};
    content.schema = "suikoden-battle-trial/23";
    const encoded = try std.json.Stringify.valueAlloc(allocator, content, .{});
    defer allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "unite_graphics") == null);
}

test "VM Unite trail art validates version and actual atlas bounds" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/blacksmith_battle.json"));
    defer parsed.deinit();
    var content = parsed.value;
    content.schema = "suikoden-battle-trial/24";
    try std.testing.expectError(error.InvalidUniteGraphics, content.validate());
    var poses = [_]battle.UniteGraphicPose{content.unite_graphics[0].poses[0]};
    const pose = &poses[0];
    const graphic = [_]battle.UniteGraphic{.{ .id = content.unite_graphics[0].id, .poses = &poses }};
    content.unite_graphics = &graphic;
    pose.sprite.rect.x = 4090;
    try std.testing.expectError(error.InvalidBattleAssets, content.validateAtlas(4096, 4096));
    pose.* = parsed.value.unite_graphics[0].poses[0];
    pose.trail = @splat(pose.sprite);
    pose.trail.?[7].rect.x = 4090;
    try std.testing.expectError(error.InvalidBattleAssets, content.validateAtlas(4096, 4096));
    pose.trail = null;
    const encoded = try std.json.Stringify.valueAlloc(allocator, pose.*, .{});
    defer allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "trail") == null);
}

test "Wild Arrow ordinary rotated nodes match independent raw descriptor projection" {
    const Camera = @TypeOf(battle.drops.initial_camera);
    const Case = struct { camera: Camera, anchor: battle.presentation.ScreenPoint, sprite: battle.Pose, angles: [3]i16, vertices: [4][2]f32, depth: f32 };
    const Position = struct { local_x_q12: i32, anchor: [3]i32, roll: i16, world: [3]i32 };
    const Fixture = struct { schema: []const u8, cases: []const Case, positions: []const Position };
    const fixture = try std.json.parseFromSlice(Fixture, allocator, @embedFile("fixtures/wild_arrow_projection.json"), .{});
    defer fixture.deinit();
    try std.testing.expectEqualStrings("suikoden-wild-arrow-projection/1", fixture.value.schema);
    for (fixture.value.positions) |case| try std.testing.expectEqualDeep(case.world, battle.layout.uniteFanPosition(case.local_x_q12, case.anchor, case.roll));
    for (fixture.value.cases) |case| {
        const quad = battle.layout.ordinaryRotatedNodeQuad(case.camera, case.anchor, case.sprite, case.angles);
        try std.testing.expectEqual(case.depth, quad.depth);
        for (quad.vertices, case.vertices) |actual, expected| {
            try std.testing.expectEqual(expected[0], actual.x);
            try std.testing.expectEqual(expected[1], actual.y);
        }
    }
}

test "primary Unite white art requires schema and matching geometry and atlas bounds" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/blacksmith_battle.json"));
    defer parsed.deinit();
    var content = parsed.value;
    const graphics = try allocator.dupe(battle.UniteGraphic, content.unite_graphics);
    defer allocator.free(graphics);
    content.unite_graphics = graphics;
    const index = for (graphics, 0..) |graphic, i| {
        if (std.mem.eql(u8, graphic.id, "krin")) break i;
    } else unreachable;
    const poses = try allocator.dupe(battle.UniteGraphicPose, graphics[index].poses);
    defer allocator.free(poses);
    graphics[index].poses = poses;
    try content.validate();
    content.schema = "suikoden-battle-trial/25";
    try std.testing.expectError(error.InvalidUniteGraphics, content.validate());
    content.schema = parsed.value.schema;
    const white_index = for (poses, 0..) |pose, i| {
        if (pose.white != null) break i;
    } else unreachable;
    const original = poses[white_index].white.?;
    poses[white_index].white.?.anchor_x += 1;
    try std.testing.expectError(error.InvalidUniteGraphics, content.validate());
    poses[white_index].white = original;
    content.schema = "suikoden-battle-trial/34";
    poses[white_index].ordinary = poses[white_index].sprite;
    poses[white_index].ordinary.?.rect.w -= 1;
    try std.testing.expectError(error.InvalidUniteGraphics, content.validate());
    poses[white_index].white.?.rect.w -= 1;
    try content.validate();
    poses[white_index].ordinary = null;
    poses[white_index].white = original;
    poses[white_index].white.?.rect.x = 4095;
    try std.testing.expectError(error.InvalidBattleAssets, content.validateAtlas(4096, 4096));
    poses[white_index].white = null;
    const encoded = try std.json.Stringify.valueAlloc(allocator, poses[white_index], .{});
    defer allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "white") == null);
}

test "Beauty recipient colors and terminal sleep require schema36 and preserve omitted defaults" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    packet.status_icons = &.{};
    packet.status_anchors = &.{};
    packet.enemy_magic_art = null;
    packet.needle_burst = &.{};
    packet.physical_white_poses = &.{};
    packet.unite_impacts = packet.unite_impacts[0..3];
    var reaction = for (packet.unite_reactions) |r| {
        if (r.record == 9 and r.variant == 1) break r;
    } else unreachable;
    packet.unite_reactions = (&reaction)[0..1];
    try packet.validate(4096, 4096);
    const pose = for (packet.hurt_poses) |p| {
        if (std.mem.eql(u8, p.id, "bonbon")) break p;
    } else unreachable;
    for (0..133) |age| {
        const sample = battle.spell_scene.uniteReactionAt(reaction, pose, @intCast(age));
        if (age == 132) {
            try std.testing.expect(sample == null);
            continue;
        }
        try std.testing.expectEqualDeep(@as([3]u8, if (age >= 2 and age < 130) .{ 192, 64, 64 } else .{ 128, 128, 128 }), sample.?.color);
        if (age >= 2 and age < 130) try std.testing.expectEqual(pose.unite_white_entry orelse pose.white_entry, sample.?.entry);
    }
    packet.hurt_poses = &.{};
    packet.schema = "suikoden-spell-scenes/35";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    packet.schema = parsed.value.schema;
    var attempts = [_]battle.spell_scene.UniteStatusAttempt{reaction.status_attempts[0]};
    reaction.status_attempts = &attempts;
    attempts[0].at = 133;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    attempts[0].at = 132;
    attempts[0].failure_percent = 101;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    attempts[0].failure_percent = 30;
    const colors = reaction.colors;
    var invalid_colors = [_]@TypeOf(colors[0]){colors[0]};
    reaction.colors = &invalid_colors;
    invalid_colors[0].at = 132;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    reaction.colors = &.{};
    reaction.status_attempts = &.{};
    packet.schema = "suikoden-spell-scenes/35";
    packet.unite_scenes = &.{};
    try packet.validate(4096, 4096);
    const bytes = try std.json.Stringify.valueAlloc(allocator, reaction, .{});
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "colors") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "status_attempts") == null);
}

test "Martial arts reaction sounds reach battle queue once in source order" {
    const content = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer content.deinit();
    const items = try field.items.load(allocator, field.items.json);
    defer items.deinit();
    const library = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer library.deinit();
    const Fixture = struct { programs: []const battle.spell_scene.UniteReaction };
    const fixture = try std.json.parseFromSlice(Fixture, allocator, @embedFile("fixtures/martial_recipients.json"), .{ .ignore_unknown_fields = true });
    defer fixture.deinit();
    var packet = library.value;
    packet.unite_reactions = fixture.value.programs;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    packet.schema = "suikoden-spell-scenes/49";
    try packet.validate(4096, 4096);
    var invalid = packet;
    var reactions = [_]battle.spell_scene.UniteReaction{packet.unite_reactions[0]};
    var sounds = [_]@TypeOf(reactions[0].sounds[0]){ reactions[0].sounds[0], reactions[0].sounds[1] };
    reactions[0].sounds = &sounds;
    invalid.unite_reactions = &reactions;
    sounds[0].at = reactions[0].duration;
    try std.testing.expectError(error.InvalidSpellScenes, invalid.validate(4096, 4096));
    sounds[0].at = 2;
    sounds[1].at = 1;
    try std.testing.expectError(error.InvalidSpellScenes, invalid.validate(4096, 4096));
    var members: [6]battle.Member = undefined;
    var state = try battle.State.init(content.value, items.value, &members, 17);
    try state.attachSpellScenes(&packet);
    const target = state.partyCount();
    state.unite_reactions[target] = .{ .record = 29, .variant = 1, .started_at = 100, .origin_q12 = @splat(0), .home_q12 = @splat(0) };
    var next: usize = 0;
    for (0..231) |age| {
        state.camera_ticks = @intCast(100 + age);
        state.unite_vm.sound_count = 0;
        state.advanceUniteReactionEvents();
        const count = state.unite_vm.sound_count;
        state.advanceUniteReactionEvents();
        try std.testing.expectEqual(count, state.unite_vm.sound_count);
        for (state.unite_vm.sounds[0..count]) |sound| {
            const expected = packet.unite_reactions[0].sounds[next];
            try std.testing.expectEqual(age, expected.at);
            try std.testing.expectEqual(expected.id, sound.id);
            try std.testing.expectEqual(target, sound.actor);
            next += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 17), next);
    state.unite_reactions[target].?.sound_cursor = 0;
    state.camera_ticks = 100 + packet.unite_reactions[0].sounds[0].at;
    state.enemy_hp[0] = 0;
    state.advanceUniteReactionEvents();
    try std.testing.expect(state.unite_reactions[target] == null);
    try std.testing.expectEqual(@as(usize, 0), state.unite_vm.takeSounds().len);
}

test "Martial arts controller drives source actors through target queue and delayed finish" {
    const controller = battle.unite_martial;
    const Fixture = struct { programs: battle.actor_program.Packet, animations: battle.actor_host.Resources, bindings: [3]controller.Binding };
    const parsed = try std.json.parseFromSlice(Fixture, allocator, @embedFile("fixtures/martial_actors.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const timing = try std.json.parseFromSlice(battle.unite_queue.Timing, allocator, @embedFile("fixtures/martial_queue_timing.json"), .{});
    defer timing.deinit();
    const Observer = struct {
        fn command(_: *anyopaque, _: u16, request: battle.actor_program.Command, _: bool) !bool {
            return switch (request) {
                .sound, .recovery => true,
                else => error.UnexpectedActorCommand,
            };
        }
        fn previous(_: *anyopaque, _: u16) !battle.presentation.ScreenPoint {
            return .{ .x = 0, .y = 0, .depth = 1024 };
        }
    };
    for ([_][6]bool{ @splat(true), .{ false, true, false, false, true, false }, @splat(false) }) |pending| {
        var actors: [9]battle.actor_host.Actor = undefined;
        for (0..3) |i| actors[i] = try battle.actor_host.Actor.init(parsed.value.animations.find(parsed.value.bindings[i].id).?, .{ 0, @as(i32, @intCast(i)) * 50 * 4096, 0 });
        for (3..9) |i| actors[i] = battle.actor_host.Actor.anchor(.{ 120 * 4096, @as(i32, @intCast(i)) * 20 * 4096, 0 }, .{ 120 * 4096, 0, 0 }, .{ 0, 0 });
        var children: [10]?battle.actor_host.Actor = @splat(null);
        var observer: u8 = 0;
        var camera = try @import("battle_camera").ActorController.init(@import("battle_camera").settled_pan);
        var runtime = battle.actor_host.Runtime{ .actors = &actors, .auxiliary = &children, .camera_controller = &camera, .library = .{ .programs = parsed.value.programs, .resources = parsed.value.animations }, .external = .{ .context = &observer, .command = Observer.command, .previous_screen_position = Observer.previous } };
        var playback = try controller.State.init(&runtime, parsed.value.bindings, .{ 0, 1, 2 }, .{ 3, 4, 5, 6, 7, 8 }, pending, timing.value);
        try std.testing.expectError(error.InvalidActorBinding, controller.State.init(&runtime, parsed.value.bindings, .{ 0, 0, 2 }, .{ 3, 4, 5, 6, 7, 8 }, pending, timing.value));
        try std.testing.expectError(error.InvalidActorBinding, controller.State.init(&runtime, parsed.value.bindings, .{ 0, 1, 2 }, .{ 3, 3, 5, 6, 7, 8 }, pending, timing.value));
        try std.testing.expectError(error.InvalidActorBinding, controller.State.init(&runtime, parsed.value.bindings, .{ 0, 1, 2 }, @splat(null), @splat(true), timing.value));
        try std.testing.expectError(error.InvalidActorPlayback, playback.advance(&runtime));
        try playback.start(&runtime);
        try std.testing.expectError(error.ActorAlreadyOwned, playback.start(&runtime));
        var claimed: [6]bool = @splat(false);
        var reacted: [6]bool = @splat(false);
        var next_target: usize = 0;
        var stages: u3 = 0;
        for (0..1500) |_| {
            runtime.beginUpdate();
            const age = playback.queue.finish_age;
            const events = try playback.advance(&runtime);
            for (events.claims) |maybe| if (maybe) |target| {
                while (!pending[next_target]) next_target += 1;
                try std.testing.expectEqual(next_target, target);
                next_target += 1;
                try std.testing.expect(!claimed[target]);
                claimed[target] = true;
            };
            for (events.reactions) |maybe| if (maybe) |target| {
                try std.testing.expect(claimed[target] and !reacted[target]);
                reacted[target] = true;
            };
            if (events.recipient_return) {
                try std.testing.expectEqual(@as(u16, 80), age);
                stages |= 1;
            }
            if (events.damage) {
                try std.testing.expectEqual(@as(u16, 140), age);
                stages |= 2;
            }
            if (events.cleanup) {
                try std.testing.expectEqual(@as(u16, 200), age);
                stages |= 4;
                break;
            }
            for (0..3) |actor| try runtime.stepActor(@intCast(actor));
        }
        try std.testing.expectEqualDeep(pending, claimed);
        try std.testing.expectEqualDeep(pending, reacted);
        try std.testing.expectEqual(@as(u3, 7), stages);
        try std.testing.expect(playback.queue.finished);
    }
}

test "Martial arts shared strike runs against all three member resources" {
    const Binding = struct { id: []const u8, setup: []const u8, strike: []const u8, @"return": []const u8 };
    const Fixture = struct { programs: battle.actor_program.Packet, animations: battle.actor_host.Resources, bindings: []const Binding };
    const parsed = try std.json.parseFromSlice(Fixture, allocator, @embedFile("fixtures/martial_actors.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try parsed.value.programs.validate();
    try parsed.value.animations.validate();
    const Observer = struct {
        sounds: usize = 0,
        fn command(raw: *anyopaque, _: u16, request: battle.actor_program.Command, _: bool) !bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (request != .sound) return error.UnexpectedActorCommand;
            self.sounds += 1;
            return true;
        }
        fn previous(_: *anyopaque, _: u16) !battle.presentation.ScreenPoint {
            return .{ .x = 0, .y = 0, .depth = 1024 };
        }
    };
    for (parsed.value.bindings) |binding| {
        var actors = [_]battle.actor_host.Actor{
            try battle.actor_host.Actor.init(parsed.value.animations.find(binding.id).?, .{ 0, 0, 0 }),
            battle.actor_host.Actor.anchor(.{ 120 * 4096, 0, 0 }, .{ 120 * 4096, 0, 0 }, .{ 0, 0 }),
        };
        var children: [8]?battle.actor_host.Actor = @splat(null);
        var observer = Observer{};
        var camera = try @import("battle_camera").ActorController.init(@import("battle_camera").settled_pan);
        var runtime = battle.actor_host.Runtime{ .actors = &actors, .auxiliary = &children, .camera_controller = &camera, .library = .{ .programs = parsed.value.programs, .resources = parsed.value.animations }, .external = .{ .context = &observer, .command = Observer.command, .previous_screen_position = Observer.previous } };
        try runtime.dispatch(0, 1, parsed.value.programs.find(binding.strike).?);
        var saw_animation = false;
        for (0..500) |_| {
            runtime.beginUpdate();
            try runtime.stepActor(0);
            if (actors[0].animation == 16) saw_animation = true;
            if (actors[0].machine.?.halted) break;
        }
        try std.testing.expect(saw_animation and actors[0].machine.?.halted);
        try std.testing.expectEqual(@as(u16, 18), actors[0].signals & 18);
        try std.testing.expectEqual(@as(usize, 1), observer.sounds);
    }
}

test "Martial arts target claims precede reactions and finish clock follows return dispatch" {
    const queue = battle.unite_queue;
    const parsed = try std.json.parseFromSlice(queue.Timing, allocator, @embedFile("fixtures/martial_queue_timing.json"), .{});
    defer parsed.deinit();
    var state = try queue.State.init(parsed.value, .{ true, false, true, true, false, true });
    var events = state.advance(.{ 16, 16, 16 });
    try std.testing.expectEqualDeep([3]?u8{ 0, 2, 3 }, events.claims);
    try std.testing.expectEqualDeep([3]u16{ 16, 16, 16 }, events.consumed);
    events = state.advance(.{ 2, 2, 2 });
    try std.testing.expectEqualDeep([3]?u8{ 0, 2, 3 }, events.reactions);
    try std.testing.expect(!events.damage and state.finish_age == 0);
    events = state.advance(.{ 0, 18, 0 });
    try std.testing.expectEqual(@as(?u8, 5), events.claims[1]);
    try std.testing.expectEqual(@as(?u8, 5), events.reactions[1]);
    events = state.advance(.{ 16, 0, 16 });
    try std.testing.expectEqual(@as(u3, 5), events.returns);
    for (0..50) |_| _ = state.advance(.{ 0, 0, 0 });
    try std.testing.expectEqual(@as(u16, 0), state.finish_age);
    events = state.advance(.{ 0, 16, 0 });
    try std.testing.expectEqual(@as(u3, 2), events.returns);
    try std.testing.expectEqual(@as(u16, 1), state.finish_age);
    for (1..201) |age| {
        events = state.advance(.{ 0, 0, 0 });
        try std.testing.expectEqual(age == 80, events.recipient_return);
        try std.testing.expectEqual(age == 140, events.damage);
        try std.testing.expectEqual(age == 200, events.cleanup);
    }
    try std.testing.expectEqualDeep(queue.Events{}, state.advance(.{ 18, 18, 18 }));
    try std.testing.expectError(error.InvalidUniteQueueTiming, queue.State.init(.{ .recipient_return = 140, .damage = 80, .cleanup = 200 }, @splat(false)));
    state = try queue.State.init(parsed.value, @splat(false));
    events = state.advance(.{ 16, 16, 16 });
    try std.testing.expectEqual(@as(u3, 7), events.returns);
    try std.testing.expectEqualDeep([3]?u8{ null, null, null }, events.claims);
}

test "Martial arts recipient launch and return retain source fixed point motion" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    const Fixture = struct { programs: []const battle.spell_scene.UniteReaction };
    const fixture = try std.json.parseFromSlice(Fixture, allocator, @embedFile("fixtures/martial_recipients.json"), .{ .ignore_unknown_fields = true });
    defer fixture.deinit();
    var packet = parsed.value;
    packet.unite_reactions = fixture.value.programs;
    packet.schema = "suikoden-spell-scenes/49";
    try packet.validate(4096, 4096);
    const first = packet.unite_reactions[0];
    const second = packet.unite_reactions[1];
    const home = [3]i32{ 120 * 4096 + 137, -20 * 4096 + 197, 0 };
    var expected = home;
    const acceleration = @divTrunc(-400 * 4096 - @as(i64, -32768) * 60, 60 * 59 / 2);
    var velocity: i64 = -32768;
    for (0..261) |age| {
        if (age >= 170 and age < 230) {
            expected[2] += @intCast(velocity);
            velocity += acceleration;
            if (age == 229) expected[2] = -400 * 4096;
        }
        try std.testing.expectEqualDeep(expected, battle.spell_scene.unitePosition(first, home, home, @intCast(age)));
    }
    const origin = expected;
    const starts = [_]u32{ 0, 60, 90 };
    const durations = [_]i64{ 60, 30, 15 };
    const velocities = [_]i64{ 0, -32768, -16384 };
    var stage: usize = 0;
    var acceleration_return: i64 = 0;
    velocity = 0;
    for (0..107) |age| {
        if (stage < 3 and age == starts[stage]) {
            velocity = velocities[stage];
            acceleration_return = @divTrunc(-@as(i64, expected[2]) - velocity * durations[stage], @divTrunc(durations[stage] * (durations[stage] - 1), 2));
        }
        if (stage < 3) {
            expected[2] += @intCast(velocity);
            velocity += acceleration_return;
            if (age + 1 == starts[stage] + @as(u32, @intCast(durations[stage]))) {
                expected = home;
                stage += 1;
            }
        }
        try std.testing.expectEqualDeep(expected, battle.spell_scene.unitePosition(second, origin, home, @intCast(age)));
    }
    const pose = packet.hurt_poses[0];
    try std.testing.expect(first.retain_lock and second.locks_target and !second.retain_lock);
    try std.testing.expect(battle.spell_scene.uniteReactionAt(first, pose, 260) != null);
    try std.testing.expectEqual(@as(u8, 1), battle.spell_scene.uniteReactionAt(second, pose, 0).?.animation);
    try std.testing.expect(battle.spell_scene.uniteReactionAt(second, pose, 106) == null);
    var reactions = [_]battle.spell_scene.UniteReaction{first};
    var motions = [_]battle.spell_scene.UniteMotion{first.motions[0]};
    reactions[0].motions = &motions;
    packet.unite_reactions = &reactions;
    motions[0].offset_q12[2] = -32768 * 4096 - 1;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "Warriors source scene and recipient use the shared players" {
    const Fixture = struct { scene: battle.spell_scene.Spell, reaction: battle.spell_scene.UniteReaction };
    const fixture = try std.json.parseFromSlice(Fixture, allocator, @embedFile("fixtures/unite_warriors_scene.json"), .{});
    defer fixture.deinit();
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    const scenes = [_]battle.spell_scene.Spell{fixture.value.scene};
    const reactions = [_]battle.spell_scene.UniteReaction{fixture.value.reaction};
    packet.unite_scenes = &scenes;
    packet.unite_reactions = &reactions;
    try packet.validate(4096, 4096);
    var draws = battle.systems.Draws{ .values = &.{} };
    var instance = try battle.spell_scene.Instance.beginUnite(&packet, 0, @import("battle_camera").settled_pan, &draws);
    instance.caster = .{ 40, 20, -60 };
    instance.target = .{ -120, -20, 0 };
    for ([_]struct { update: u16, commands: usize }{
        .{ .update = 0, .commands = 0 },   .{ .update = 1, .commands = 8 },
        .{ .update = 80, .commands = 8 },  .{ .update = 81, .commands = 9 },
        .{ .update = 95, .commands = 9 },  .{ .update = 96, .commands = 1 },
        .{ .update = 109, .commands = 1 }, .{ .update = 110, .commands = 0 },
    }) |boundary| {
        try instance.advance(&packet, boundary.update, &draws);
        try std.testing.expectEqual(boundary.commands, battle.spell_scene.frameAt(&packet, &instance, boundary.update).count);
    }
    try std.testing.expectEqual(@as(usize, 0), draws.cursor);
    const reaction = fixture.value.reaction;
    const pose = for (packet.hurt_poses) |value| {
        if (std.mem.eql(u8, value.id, "bonbon")) break value;
    } else unreachable;
    try std.testing.expectEqualDeep([3]u8{ 255, 64, 64 }, battle.spell_scene.uniteReactionAt(reaction, pose, 2).?.color);
    try std.testing.expectEqualDeep([3]u8{ 128, 128, 128 }, battle.spell_scene.uniteReactionAt(reaction, pose, 51).?.color);
    try std.testing.expect(battle.spell_scene.uniteReactionAt(reaction, pose, 53) == null);
    const origin = [3]i32{ 120 * 4096 + 137, -33 * 4096 + 197, 0 };
    const home = [3]i32{ 128 * 4096, -20 * 4096, 0 };
    try std.testing.expectEqualDeep([3]i32{ origin[0] - 6144, origin[1], 0 }, battle.spell_scene.unitePosition(reaction, origin, home, 2));
    try std.testing.expectEqualDeep(home, battle.spell_scene.unitePosition(reaction, origin, home, 52));
}

test "Beauty shared scene seeds thirty hearts with one hundred fifty draws and retires its fade" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    const packet = parsed.value;
    const index = packet.uniteIndexOf("beauty").?;
    var values: [4096]u15 = undefined;
    var seed: u32 = 17;
    for (&values) |*value| {
        seed = seed *% 1103515245 +% 12345;
        value.* = @intCast((seed >> 16) & 32767);
    }
    var draws = battle.systems.Draws{ .values = &values };
    var instance = try battle.spell_scene.Instance.beginUnite(&packet, index, @import("battle_camera").settled_pan, &draws);
    try std.testing.expect(instance.unite_scene);
    try std.testing.expectEqual(@as(usize, 150), draws.cursor);
    try std.testing.expectEqual(@as(usize, 0), battle.spell_scene.frameAt(&packet, &instance, 0).count);
    for (instance.particles[0..30], 0..) |particle, i| {
        try std.testing.expect(particle.active);
        try std.testing.expectEqual(@as(u16, values[5 * i] % 32), particle.age);
        try std.testing.expectEqual(@as(u16, values[5 * i + 1] % 64), particle.phase);
        try std.testing.expectEqual(particle.head[2], particle.base_z);
    }
    var prior: usize = 150;
    for (1..226) |update| {
        try instance.advance(&packet, @intCast(update), &draws);
        if (update <= 65) try std.testing.expectEqual(@as(usize, 150), draws.cursor);
        if (update > 192) try std.testing.expectEqual(prior, draws.cursor);
        const frame = battle.spell_scene.frameAt(&packet, &instance, @intCast(update));
        if (update < 224) try std.testing.expect(frame.count >= 128) else try std.testing.expectEqual(@as(usize, 0), frame.count);
        prior = draws.cursor;
    }
    try std.testing.expect(draws.cursor > 150);
    for (instance.particles[0..30]) |particle| try std.testing.expect(!particle.active);
}

test "Beauty shared scene rejects incomplete seeds and unsupported packet versions" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    packet.status_icons = &.{};
    packet.status_anchors = &.{};
    packet.enemy_magic_art = null;
    packet.needle_burst = &.{};
    packet.schema = "suikoden-spell-scenes/36";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    packet.schema = parsed.value.schema;
    var scenes = [_]battle.spell_scene.Spell{packet.unite_scenes[0]};
    packet.unite_scenes = &scenes;
    const original = scenes[0].program.?;
    scenes[0].program.?.initial_draws = 149;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    scenes[0].program = original;
    scenes[0].program.?.emitter.?.initial_warmup = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    scenes[0].program = original;
    scenes[0].program.?.emitter.?.oscillation = &.{};
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    scenes[0].program = original;
    scenes[0].program.?.emitter.?.loop_stop = original.emitter.?.spawn_stop;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
}

test "Beauty shared scene matches independent particle camera and packet witnesses" {
    const Particle = struct { age: u16, phase: u16, base_z: i32, active: bool, head: [3]i32, spawn_scale: [3]i32 };
    const Command = struct { index: usize, texture: ?u16, vertices: [4][2]f32, depth: i32, tint: [3]u8, blend: battle.spell_scene.Blend };
    const Case = struct { seed: u32, update: u16, draw_count: usize, camera: [12]i32, count: usize, particles: []const Particle, commands: []const Command };
    const Fixture = struct { schema: []const u8, scope: []const u8, cases: []const Case };
    const vectors = try std.json.parseFromSlice(Fixture, allocator, @embedFile("fixtures/unite_beauty_vfx_vectors.json"), .{});
    defer vectors.deinit();
    try std.testing.expectEqualStrings("suikoden-beauty-vfx-vectors/1", vectors.value.schema);
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    const packet = &parsed.value;
    var instance: ?battle.spell_scene.Instance = null;
    var draws = battle.systems.Draws{};
    for (vectors.value.cases) |case| {
        if (case.update == 0) {
            draws = .{ .bios_state = case.seed };
            instance = try battle.spell_scene.Instance.beginUnite(packet, packet.uniteIndexOf("beauty").?, battle.drops.initial_camera, &draws);
        }
        try instance.?.advance(packet, case.update, &draws);
        try std.testing.expectEqual(case.draw_count, draws.cursor);
        for (case.particles, instance.?.particles[0..30], 0..) |expected, actual, index| {
            errdefer std.debug.print("Beauty seed={d} update={d} particle={d}\n", .{ case.seed, case.update, index });
            inline for (@typeInfo(Particle).@"struct".field_names) |name| try std.testing.expectEqualDeep(@field(expected, name), @field(actual, name));
        }
        const block = battle.spell_scene.instanceCameraAt(instance.?.sceneProgram(packet), &instance.?, case.update);
        try std.testing.expectEqualDeep(case.camera, block.focus ++ block.angles ++ block.translation ++ block.scale);
        const frame = battle.spell_scene.frameAt(packet, &instance.?, case.update);
        try std.testing.expectEqual(case.count, frame.count);
        for (case.commands) |expected| {
            errdefer std.debug.print("Beauty seed={d} update={d} command={d}\n", .{ case.seed, case.update, expected.index });
            const actual = frame.commands[expected.index];
            try std.testing.expectEqual(expected.texture, actual.texture);
            try std.testing.expectEqual(expected.depth, actual.depth);
            try std.testing.expectEqualDeep(expected.tint, actual.tint);
            try std.testing.expectEqual(expected.blend, actual.blend);
            for (expected.vertices, actual.vertices) |xy, vertex| {
                try std.testing.expectApproxEqAbs(xy[0], vertex.x, 0.01);
                try std.testing.expectApproxEqAbs(xy[1], vertex.y, 0.01);
            }
        }
    }
}

test "Unite recipient signals require schema38 and validate terminal ordered events" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    packet.status_icons = &.{};
    packet.status_anchors = &.{};
    packet.enemy_magic_art = null;
    packet.needle_burst = &.{};
    packet.physical_white_poses = &.{};
    packet.unite_impacts = packet.unite_impacts[0..3];
    var reaction = for (packet.unite_reactions) |r| {
        if (r.record == 10) break r;
    } else unreachable;
    packet.unite_reactions = (&reaction)[0..1];
    try packet.validate(4096, 4096);
    var signals = [_]battle.spell_scene.UniteSignal{
        .{ .at = 0, .bits = 4, .set = false },
        .{ .at = reaction.duration, .bits = 6, .set = true },
    };
    reaction.signals = &signals;
    try packet.validate(4096, 4096);
    packet.hurt_poses = &.{};
    packet.schema = "suikoden-spell-scenes/37";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    packet.schema = parsed.value.schema;
    signals[1].at += 1;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    signals[1].at = 2;
    signals[0].at = 3;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    signals[0].at = 0;
    signals[1].bits = 0;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    signals[1].bits = 6;
    reaction.blocker = "pending";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    reaction.blocker = null;
    reaction.signals = &.{};
    packet.schema = "suikoden-spell-scenes/37";
    try packet.validate(4096, 4096);
    const bytes = try std.json.Stringify.valueAlloc(allocator, reaction, .{});
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "signals") == null);
}

test "Unite recipient retained locks require schema40 and preserve the final pose" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    packet.status_icons = &.{};
    packet.status_anchors = &.{};
    packet.enemy_magic_art = null;
    packet.needle_burst = &.{};
    var reaction = for (packet.unite_reactions) |r| {
        if (r.record == 17 and r.variant == 1) break r;
    } else unreachable;
    packet.unite_reactions = (&reaction)[0..1];
    try packet.validate(4096, 4096);
    const pose = packet.hurt_poses[0];
    const final = battle.spell_scene.uniteReactionAt(reaction, pose, reaction.duration + 20).?;
    try std.testing.expectEqual(@as(u8, 1), final.animation);
    packet.schema = "suikoden-spell-scenes/39";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    packet.schema = parsed.value.schema;
    reaction.locks_target = false;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    reaction.locks_target = true;
    reaction.retain_lock = false;
    try packet.validate(4096, 4096);
    const bytes = try std.json.Stringify.valueAlloc(allocator, reaction, .{});
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "retain_lock") == null);
}

test "Unite record graphics preserve ordinary bodies and select scoped sprites and trails" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_battle.json"));
    defer parsed.deinit();
    var content = parsed.value;
    const original = for (content.unite_graphics) |graphic| {
        if (std.mem.eql(u8, graphic.id, "pahn")) break graphic;
    } else return error.MissingPahnFixture;
    const pose = original.poses[0];
    const scoped_poses = [_]battle.UniteGraphicPose{.{ .id = pose.id, .sprite = .{ .rect = .{ .x = pose.sprite.rect.x + 1, .y = pose.sprite.rect.y, .w = pose.sprite.rect.w, .h = pose.sprite.rect.h }, .anchor_x = pose.sprite.anchor_x, .anchor_y = pose.sprite.anchor_y }, .trail = @splat(pose.sprite) }};
    const graphics = try allocator.alloc(battle.UniteGraphic, content.unite_graphics.len + 1);
    defer allocator.free(graphics);
    @memcpy(graphics[0..content.unite_graphics.len], content.unite_graphics);
    graphics[graphics.len - 1] = .{ .id = "pahn", .record = 29, .poses = &scoped_poses };
    content.unite_graphics = graphics;
    try std.testing.expectError(error.InvalidUniteGraphics, content.validate());
    content.schema = "suikoden-battle-trial/35";
    try content.validate();
    try std.testing.expectEqualDeep(pose.sprite, content.uniteGraphic("pahn", pose.id).?);
    try std.testing.expectEqualDeep(pose, content.uniteGraphicPose("pahn", pose.id, null).?.*);
    try std.testing.expectEqualDeep(pose, content.uniteGraphicPose("pahn", pose.id, 0).?.*);
    try std.testing.expectEqualDeep(scoped_poses[0], content.uniteGraphicPose("pahn", pose.id, 29).?.*);
    try std.testing.expectEqualDeep(pose.ordinary, content.ordinaryActorGraphic("pahn", pose.id));
    graphics[graphics.len - 1].record = 32;
    try std.testing.expectError(error.InvalidUniteGraphics, content.validate());
    graphics[graphics.len - 1].record = null;
    try std.testing.expectError(error.InvalidUniteGraphics, content.validate());
    const encoded = try std.json.Stringify.valueAlloc(allocator, original, .{});
    defer allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "record") == null);
}

test "Beat em up source actors follow callback order and keep the child after controller cleanup" {
    const beat = battle.unite_beat;
    const Expected = struct { first_reaction: u16, transition: u16, child: u16, damage: u16, cleanup: u16, child_hidden: u16, child_retired: u16, pahn_complete: u16 };
    const Fixture = struct { programs: battle.actor_program.Packet, animations: battle.actor_host.Resources, members: [2]beat.Binding, child: battle.actor_program.Child, expected: Expected };
    const parsed = try std.json.parseFromSlice(Fixture, allocator, @embedFile("fixtures/beat_actors.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try parsed.value.programs.validate();
    try parsed.value.animations.validate();
    const Observer = struct {
        age: u16 = 0,
        recovery_at: ?u16 = null,
        fn command(raw: *anyopaque, _: u16, command_: battle.actor_program.Command, _: bool) !bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (command_) {
                .sound => {},
                .recovery => {
                    if (self.recovery_at != null) return error.DuplicateRecovery;
                    self.recovery_at = self.age + 1;
                },
                else => return error.UnexpectedActorCommand,
            }
            return true;
        }
        fn previous(_: *anyopaque, _: u16) !battle.presentation.ScreenPoint {
            return .{ .x = 17, .y = 29, .depth = 1024 };
        }
    };
    for ([_][2]u16{ .{ 0, 1 }, .{ 1, 0 } }) |members| {
        var actors: [3]battle.actor_host.Actor = undefined;
        for (members, parsed.value.members, 0..) |actor, binding, i| actors[actor] = try battle.actor_host.Actor.init(parsed.value.animations.find(binding.id).?, .{ 0, @as(i32, @intCast(i)) * 40 * 4096, 0 });
        actors[2] = battle.actor_host.Actor.anchor(.{ 120 * 4096, 25 * 4096, 0 }, .{ 120 * 4096, 25 * 4096, 0 }, .{ 7, -11 });
        var children: [4]?battle.actor_host.Actor = @splat(null);
        var observer = Observer{};
        var runtime = battle.actor_host.Runtime{ .actors = &actors, .auxiliary = &children, .library = .{ .programs = parsed.value.programs, .resources = parsed.value.animations }, .external = .{ .context = &observer, .command = Observer.command, .previous_screen_position = Observer.previous } };
        try std.testing.expectError(error.InvalidActorBinding, beat.State.init(&runtime, parsed.value.members, .{ members[0], members[0] }, 2, parsed.value.child));
        try std.testing.expectError(error.InvalidActorBinding, beat.State.init(&runtime, parsed.value.members, members, members[0], parsed.value.child));
        var invalid_child = parsed.value.child;
        invalid_child.resource = parsed.value.members[0].id;
        try std.testing.expectError(error.InvalidActorBinding, beat.State.init(&runtime, parsed.value.members, members, 2, invalid_child));
        var state = try beat.State.init(&runtime, parsed.value.members, members, 2, parsed.value.child);
        try std.testing.expectError(error.InvalidActorPlayback, state.advance(&runtime));
        try state.start(&runtime);
        try std.testing.expectError(error.ActorAlreadyOwned, state.start(&runtime));
        var events_seen: u5 = 0;
        var child_age: ?u16 = null;
        var child_retired: ?u16 = null;
        for (0..450) |age| {
            observer.age = @intCast(age);
            const parent_position = actors[members[1]].position_q12;
            runtime.beginUpdate();
            if (age == parsed.value.expected.child) {
                for (&children) |*slot| slot.* = battle.actor_host.Actor.anchor(.{ 0, 0, 0 }, .{ 0, 0, 0 }, null);
                const before = state;
                const signals = actors[members[0]].signals;
                try std.testing.expectError(error.ActorPoolExhausted, state.advance(&runtime));
                try std.testing.expectEqualDeep(before, state);
                try std.testing.expectEqual(signals, actors[members[0]].signals);
                try std.testing.expectEqual(@as(i16, 1), actors[members[1]].shared_value);
                children = @splat(null);
            }
            const events = try state.advance(&runtime);
            if (events.first_reaction) {
                try std.testing.expectEqual(parsed.value.expected.first_reaction, age);
                events_seen |= 1;
            }
            if (events.transition) {
                try std.testing.expectEqual(parsed.value.expected.transition, age);
                events_seen |= 2;
            }
            if (events.child) {
                try std.testing.expectEqual(parsed.value.expected.child, age);
                try std.testing.expect(children[3] != null);
                const child = children[3].?;
                try std.testing.expectEqualDeep([3]i32{ parent_position[0] - 10 * 4096, parent_position[1], parent_position[2] - 20 * 4096 }, child.position_q12);
                try std.testing.expectEqualDeep(actors[2].position_q12, child.home_q12);
                try std.testing.expectEqualDeep([2]i32{ 7, -11 }, child.offset_destination);
                try std.testing.expectEqual(@as(?u16, members[1]), child.owner);
                try std.testing.expectEqual(@as(u16, 18), child.animation);
                try std.testing.expect(!child.has_draw_record);
                try std.testing.expectEqual(@as(i16, 99), actors[members[1]].shared_value);
                child_age = @intCast(age);
                events_seen |= 4;
            }
            if (events.damage) {
                try std.testing.expectEqual(parsed.value.expected.damage, age);
                events_seen |= 8;
            }
            if (events.cleanup) {
                try std.testing.expectEqual(parsed.value.expected.cleanup, age);
                try std.testing.expect(children[3] != null);
                try std.testing.expect(!actors[members[0]].machine.?.halted);
                events_seen |= 16;
            }
            for (0..3) |actor| try runtime.stepActor(@intCast(actor));
            for (0..children.len) |i| if (children[i] != null) try runtime.stepActor(@intCast(actors.len + i));
            if (age == parsed.value.expected.child_hidden) {
                try std.testing.expect(children[3] != null);
                try std.testing.expect(!children[3].?.visible);
            }
            if (child_age != null and child_retired == null and children[3] == null) child_retired = @intCast(age);
        }
        try std.testing.expectEqual(@as(u5, 31), events_seen);
        try std.testing.expectEqual(parsed.value.expected.child_retired, child_retired.?);
        try std.testing.expectEqual(parsed.value.expected.pahn_complete, observer.recovery_at.?);
        try std.testing.expect(state.finished and actors[members[0]].released and actors[members[1]].released);
        try std.testing.expect(actors[members[0]].machine.?.halted and actors[members[1]].machine.?.halted);
    }
}

test "Beat em up recipient prefix retains the target until the damage stage replaces it" {
    const Fixture = struct { programs: []const battle.spell_scene.UniteReaction };
    const parsed = try std.json.parseFromSlice(Fixture, allocator, @embedFile("fixtures/beat_recipients.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const library = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer library.deinit();
    var packet = library.value;
    packet.schema = "suikoden-spell-scenes/49";
    packet.unite_reactions = parsed.value.programs;
    try packet.validate(4096, 4096);
    const prefix = parsed.value.programs[0];
    const final = parsed.value.programs[1];
    const pose = packet.hurt_poses[0];
    try std.testing.expect(prefix.retain_lock and prefix.locks_target);
    try std.testing.expect(final.locks_target and !final.retain_lock);
    try std.testing.expectEqual(@as(u16, 261), prefix.duration);
    try std.testing.expectEqual(@as(usize, 17), prefix.sounds.len);
    for ([_]u32{ 260, 261, 267, 1000 }) |age| try std.testing.expect(battle.spell_scene.uniteReactionAt(prefix, pose, age) != null);
    try std.testing.expect(battle.spell_scene.uniteReactionAt(final, pose, 0) != null);
    try std.testing.expect(battle.spell_scene.uniteReactionAt(final, pose, 108) != null);
    try std.testing.expect(battle.spell_scene.uniteReactionAt(final, pose, 109) == null);
}

test "Beat target attachments preserve unsigned differences separately from byte impact offsets" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    var packet = parsed.value;
    var pose = packet.hurt_poses[0];
    packet.hurt_poses = (&pose)[0..1];
    const wrapped = pose.impact_offset.?;
    var full: [2]i16 = undefined;
    for (wrapped, 0..) |value, axis| full[axis] = if (value == 0) 0 else @as(i16, value) + (if (value < 0) @as(i16, 256) else -256);
    pose.source_attachment = full;
    packet.schema = "suikoden-spell-scenes/50";
    try packet.validate(4096, 4096);
    packet.schema = "suikoden-spell-scenes/49";
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    packet.schema = "suikoden-spell-scenes/50";
    pose.source_attachment.?[0] = 256;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    pose.source_attachment = full;
    pose.source_attachment.?[0] += 1;
    try std.testing.expectError(error.InvalidSpellScenes, packet.validate(4096, 4096));
    pose.source_attachment = null;
    const bytes = try std.json.Stringify.valueAlloc(allocator, pose, .{});
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "source_attachment") == null);
}

test "Unite scoped graphic capacity retains schema bounds and pose validation" {
    const parsed = try battle.load(allocator, @embedFile("fixtures/journey_unites_battle.json"));
    defer parsed.deinit();
    var content = parsed.value;
    var labels: [303][16]u8 = undefined;
    var graphics: [303]battle.UniteGraphic = undefined;
    const poses = [_]battle.UniteGraphicPose{.{ .id = 0, .sprite = content.party[0].sprite }};
    for (&graphics, 0..) |*graphic, index| graphic.* = .{ .id = try std.fmt.bufPrint(&labels[index], "graphic_{d}", .{index}), .poses = &poses };
    for (content.party, 0..) |profile, index| graphics[index].id = profile.id;
    for (content.enemies, 0..) |profile, index| graphics[content.party.len + index].id = profile.id;
    content.unite_graphics = graphics[0..302];
    try content.validate();
    content.unite_graphics = &graphics;
    try std.testing.expectError(error.InvalidUniteGraphics, content.validate());
    content.schema = "suikoden-battle-trial/34";
    // The current full catalogue exceeds the legacy graphic cap; keep that boundary fixture scoped to Area A1.
    content.enemies = content.enemies[0..1];
    content.encounters = content.encounters[0..1];
    content.unite_graphics = graphics[0..64];
    try content.validate();
    content.unite_graphics = graphics[0..65];
    try std.testing.expectError(error.InvalidUniteGraphics, content.validate());
}

test "battle.spell_scene.parseSchemaVersion parses v1..v52 and rejects invalid schemas" {
    try std.testing.expectEqual(@as(?u8, 1), battle.spell_scene.parseSchemaVersion("suikoden-spell-scenes/1"));
    try std.testing.expectEqual(@as(?u8, 25), battle.spell_scene.parseSchemaVersion("suikoden-spell-scenes/25"));
    try std.testing.expectEqual(@as(?u8, 52), battle.spell_scene.parseSchemaVersion("suikoden-spell-scenes/52"));
    try std.testing.expectEqual(@as(?u8, null), battle.spell_scene.parseSchemaVersion("suikoden-spell-scenes/0"));
    try std.testing.expectEqual(@as(?u8, null), battle.spell_scene.parseSchemaVersion("suikoden-spell-scenes/01"));
    try std.testing.expectEqual(@as(?u8, null), battle.spell_scene.parseSchemaVersion("suikoden-spell-scenes/53"));
    try std.testing.expectEqual(@as(?u8, null), battle.spell_scene.parseSchemaVersion("bad"));
}
