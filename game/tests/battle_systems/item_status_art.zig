const std = @import("std");
const h = @import("helpers.zig");
const battle = h.battle;
const allocator = h.allocator;

test "Item status art validates the source burst and omits it from legacy packets" {
    const parsed = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    const packet = parsed.value;
    try std.testing.expectEqual(@as(usize, 2), packet.needle_burst.len);
    var bad = packet;
    bad.schema = "suikoden-spell-scenes/42";
    try std.testing.expectError(error.InvalidSpellScenes, bad.validate(4096, 4096));
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
    try std.testing.expect(std.mem.indexOf(u8, bytes, "needle_burst") == null);
    var frames = [_]@TypeOf(packet.needle_burst[0]){ packet.needle_burst[0], packet.needle_burst[1] };
    bad = packet;
    bad.needle_burst = &frames;
    frames[1].ticks = 5;
    try std.testing.expectError(error.InvalidSpellScenes, bad.validate(4096, 4096));
    frames[1] = packet.needle_burst[1];
    frames[1].entry = frames[0].entry;
    try std.testing.expectError(error.InvalidSpellScenes, bad.validate(4096, 4096));
    frames[1].entry = @intCast(packet.entries.len);
    try std.testing.expectError(error.InvalidSpellScenes, bad.validate(4096, 4096));
}

test "Item status art retains poison phase and bursts only the highest balloon through source cure clocks" {
    var fixture = try h.Fixture.open(null);
    defer fixture.deinit();
    const parsed = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    const art = try battle.world_art.load(allocator, @embedFile("../fixtures/world_b_party_art.json"));
    defer art.deinit();
    for ([_]bool{ false, true }) |with_world| for ([_]h.field.items.Id{ .antitoxin, .needle }) |id| for (0..6) |owner| for ([_]bool{ false, true }) |self_use| {
        const target = if (self_use) owner else (owner + 1) % 6;
        for (1..if (id == .needle) @as(usize, 4) else 2) |balloons| {
            var members: [6]battle.Member = undefined;
            var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
            try combat.attachSpellScenes(&parsed.value);
            if (with_world) combat.content.world_art = art.value;
            for (combat.progress.party) |*member| {
                member.status = .healthy;
                member.balloons = 0;
            }
            combat.camera_ticks = 300;
            if (id == .antitoxin) {
                try std.testing.expect(combat.inflictStatus(target, .poison));
            } else for (0..balloons) |_| try std.testing.expect(combat.inflictStatus(target, .balloon));
            const birth = combat.status_icons[target].started_at[if (id == .antitoxin) @as(usize, 0) else balloons];
            combat.camera_ticks += 5;
            combat.progress.party[owner].inventory.slots = @splat(null);
            combat.progress.party[owner].inventory.slots[0] = .{ .id = id, .uses = 1 };
            combat.progress.party[owner].inventory.slots[1] = .{ .id = .bandanna, .uses = 0 };
            combat.actions[owner] = .{ .item = .{ .slot = 0, .target = target, .id = id } };
            try std.testing.expect(combat.beginMedicine(owner));
            try std.testing.expect(combat.progress.party[owner].inventory.slots[0].?.id == .bandanna);
            const timing = combat.medicine_action.?.timing;
            for (0..@max(timing.owner_release, timing.target_release)) |_| {
                combat.camera_ticks += 1;
                combat.presentation_tick += 1;
                combat.advanceMedicine();
                combat.advanceStatusIcons();
                const item = combat.medicine_action.?;
                if (item.ticks == timing.impact_tick) {
                    const impact = combat.recentItemImpact(target).?;
                    try std.testing.expectEqual(id == .antitoxin, impact.cured_poison);
                    try std.testing.expectEqual(id == .needle, impact.removed_balloon);
                }
                const frame = combat.spellSceneFrame();
                if (item.ticks < timing.target_start) {
                    try std.testing.expectEqual(if (id == .antitoxin) @as(usize, 1) else balloons, frame.count);
                    continue;
                }
                const age = item.ticks - timing.target_start;
                const visible = age >= 1 and age <= (if (id == .antitoxin) @as(u16, 29) else 10);
                const normal = if (id == .antitoxin) @as(usize, 0) else balloons - 1;
                try std.testing.expectEqual(normal + @intFromBool(visible), frame.count);
                var detached: usize = 0;
                for (frame.commands[0..frame.count]) |command| {
                    try std.testing.expect(command.blend == .@"opaque");
                    if (command.opacity == 255) continue;
                    detached += 1;
                    try std.testing.expectEqual(@as(u8, 128), command.opacity);
                    if (id == .needle) {
                        try std.testing.expectEqual(@as(?u16, parsed.value.needle_burst[if (age < 4) @as(usize, 0) else 1].entry), command.texture);
                    } else {
                        const poison = for (parsed.value.status_icons) |icon| {
                            if (icon.status == .poison) break icon;
                        } else unreachable;
                        try std.testing.expectEqual(@as(?u16, poison.entryAt(combat.camera_ticks - birth)), command.texture);
                        const origin = item.particle_origins[target].?;
                        const z = origin.z - @as(f32, @floatFromInt(@as(u32, age) * (age - 1))) / 16;
                        const block = battle.layout.currentCamera(combat);
                        const point = battle.drops.project(block, .{ @intFromFloat(@floor(origin.x)), @intFromFloat(@floor(origin.y)), @intFromFloat(@floor(z)) });
                        const scale = @divTrunc(block.scale[0] << 10, block.translation[2]);
                        const anchors = parsed.value.statusAnchors(combat.progress.party[target].id).?;
                        const offset = anchors.offsets[anchors.idle_pose];
                        const entry = parsed.value.entries[command.texture.?];
                        const dx = @divTrunc(@as(i32, offset[0]) * scale, 4096) + ((entry.dx * scale) >> 12);
                        const dy = @divTrunc(@as(i32, offset[1]) * scale, 4096) + ((entry.dy * scale) >> 12);
                        try std.testing.expectApproxEqAbs(point.x + @as(f32, @floatFromInt(dx)), command.vertices[0].x, 0.01);
                        try std.testing.expectApproxEqAbs(point.y + @as(f32, @floatFromInt(dy)), command.vertices[0].y, 0.01);
                    }
                }
                try std.testing.expectEqual(@as(usize, @intFromBool(visible)), detached);
                if (age < (if (id == .antitoxin) @as(u16, 31) else 12)) {
                    if (id == .antitoxin) try std.testing.expect(combat.progress.party[target].status == .poisoned) else try std.testing.expectEqual(balloons, combat.progress.party[target].balloons);
                }
            }
            try std.testing.expect(combat.medicine_action.?.owner_released and combat.medicine_action.?.target_released);
            if (id == .antitoxin) try std.testing.expect(combat.progress.party[target].status == .healthy) else try std.testing.expectEqual(balloons - 1, combat.progress.party[target].balloons);
        }
    };
}

test "Item status art leaves ineffective cures and interrupted symbols attached" {
    var fixture = try h.Fixture.open(null);
    defer fixture.deinit();
    const parsed = try battle.spell_scene.load(allocator, @embedFile("../fixtures/spell_scene_library.json"));
    defer parsed.deinit();
    for ([_]h.field.items.Id{ .antitoxin, .needle }) |id| for ([_]bool{ false, true }) |interrupted| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        try combat.attachSpellScenes(&parsed.value);
        if (interrupted) {
            if (id == .antitoxin) try std.testing.expect(combat.inflictStatus(1, .poison)) else try std.testing.expect(combat.inflictStatus(1, .balloon));
        }
        combat.progress.party[0].inventory.slots = @splat(null);
        combat.progress.party[0].inventory.slots[0] = .{ .id = id, .uses = 1 };
        combat.actions[0] = .{ .item = .{ .slot = 0, .target = 1, .id = id } };
        try std.testing.expect(combat.beginMedicine(0));
        const start = combat.medicine_action.?.timing.target_start;
        for (0..start + 3) |_| {
            combat.camera_ticks += 1;
            combat.advanceMedicine();
            combat.advanceStatusIcons();
        }
        if (interrupted) {
            const recipient = members[1];
            members[1].hp = 0;
            combat.markPartyKnockout(1);
            try std.testing.expect(combat.medicine_action.?.interrupted(1));
            try std.testing.expect(!combat.coordinatorLocked(1));
            members[1] = recipient;
            combat.party_knockouts[1].pending = false;
            combat.party_knockouts[1].prior_status = null;
            while (combat.medicine_action.?.ticks < combat.medicine_action.?.timing.impact_tick) combat.advanceMedicine();
            try std.testing.expectEqualDeep(recipient, members[1]);
        }
        const frame = combat.spellSceneFrame();
        try std.testing.expect(combat.recentItemImpact(1) == null);
        try std.testing.expectEqual(@as(usize, @intFromBool(interrupted)), frame.count);
        if (interrupted) try std.testing.expectEqual(@as(u8, 255), frame.commands[0].opacity) else try std.testing.expect(combat.medicine_action.?.detached_status == null);
        try std.testing.expect(combat.progress.party[0].inventory.slots[0] == null);
    };
}
