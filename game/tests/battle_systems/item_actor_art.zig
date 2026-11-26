const std = @import("std");
const h = @import("helpers.zig");
const battle = h.battle;
const allocator = h.allocator;

test "Item actor schema31 validates source clips timing and legacy omission" {
    var fixture = try h.Fixture.open(null);
    defer fixture.deinit();
    var view = fixture.view;
    const profiles = try allocator.dupe(battle.Profile, view.party);
    defer allocator.free(profiles);
    view.party = profiles;
    const art = profiles[0].item_art.?;
    profiles[0].item_art = null;
    try std.testing.expectError(error.MissingItemArt, view.validate());
    profiles[0].item_art = art;
    view.schema = "suikoden-battle-trial/30";
    try std.testing.expectError(error.UnsupportedBattleSchema, view.validate());
    for (profiles) |*profile| profile.item_art = null;
    try view.validate();
    const bytes = try std.json.Stringify.valueAlloc(allocator, profiles[0], .{});
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "item_art") == null);
    @memcpy(profiles, fixture.view.party);
    view.schema = fixture.view.schema;
    view.medicine_timings = &.{};
    try std.testing.expectError(error.InvalidMedicineTiming, view.validate());
    view.medicine_timings = fixture.view.medicine_timings;
    profiles[0].item_art.?.prepare.frames = &.{};
    try std.testing.expectError(error.InvalidItemArt, view.validate());
    profiles[0].item_art = art;
    var frame = [_]battle.Frame{art.prepare.frames[0]};
    profiles[0].item_art.?.prepare.frames = &frame;
    frame[0].source_pose = null;
    try std.testing.expectError(error.InvalidItemArt, view.validate());
}

test "Item actors retain self healing ineffective recovery and Incense hold through real ticks" {
    const parsed = try battle.load(allocator, @embedFile("../fixtures/blacksmith_battle.json"));
    defer parsed.deinit();
    const items = try h.field.items.load(allocator, h.field.items.json);
    defer items.deinit();
    try std.testing.expectEqual(@as(usize, 44), parsed.value.party.len);
    for (parsed.value.party) |profile| for ([_]h.field.items.Id{ .medicine, .antitoxin, .dragon_seal_incense }) |id| {
        var view = parsed.value;
        const initial = [_][]const u8{profile.id};
        view.initial_party = &initial;
        view.party_positions = view.party_positions[0..1];
        var members: [1]battle.Member = undefined;
        var combat = try battle.State.init(view, items.value, &members, 17);
        combat.progress.party.at(0).max_hp = 1000;
        combat.progress.party.at(0).hp = 100;
        combat.progress.party.at(0).status = .healthy;
        combat.progress.party.at(0).inventory.slots = @splat(null);
        combat.progress.party.at(0).inventory.slots[0] = .{ .id = id, .uses = if (id == .dragon_seal_incense) 0 else 1 };
        combat.actions[0] = .{ .item = .{ .slot = 0, .target = 0, .id = id } };
        combat.phase = .resolving;
        combat.camera_ticks = 300;
        combat.acted = @splat(true);
        combat.coordinator = .{ .stage = .await_order, .current_actor = 0, .completed = false, .elapsed = 0 };
        try std.testing.expect(combat.beginMedicine(0));
        const timing = combat.medicine_action.?.timing;
        const art = profile.item_art.?;
        var saw_prepare = false;
        var saw_hold = false;
        var saw_recovery = false;
        var draws = battle.systems.Draws{ .values = &.{} };
        for (0..@max(timing.owner_release, timing.target_release)) |_| {
            try combat.tickReplay(.{}, &draws);
            const item = combat.medicine_action.?;
            const layout = battle.layout.actorLayout(combat, 0);
            if (item.ticks == timing.target_start - 2) {
                saw_prepare = true;
                try std.testing.expectEqual(@as(?u16, art.prepare.frames[art.prepare.frames.len - 1].source_pose.?), layout.source_pose);
            }
            if (item.ticks == timing.target_start) {
                if (id == .medicine) {
                    try std.testing.expectEqual(art.idle.frames[0].source_pose, layout.source_pose);
                    try std.testing.expectEqualDeep(art.idle.frames[0].pose, item.particle_sprites[0].?);
                } else {
                    saw_hold = true;
                    try std.testing.expectEqual(art.hold.frames[0].source_pose, layout.source_pose);
                }
            }
            if (id == .antitoxin and item.ticks == timing.target_start + 60) {
                saw_recovery = true;
                try std.testing.expectEqual(art.recover.frameAt(1).source_pose, layout.source_pose);
                try std.testing.expect(item.target_interrupted and !item.owner_released);
            }
            if (id == .dragon_seal_incense and item.ticks == timing.target_start + 64) {
                try std.testing.expectEqual(art.hold.frames[0].source_pose, layout.source_pose);
                try std.testing.expectEqualDeep(art.hold.frames[0].pose, item.particle_sprites[0].?);
                try std.testing.expect(!item.owner_released);
            }
            try std.testing.expectEqual(@as(usize, 0), draws.cursor);
        }
        try std.testing.expect(saw_prepare and combat.medicine_action.?.owner_released and combat.medicine_action.?.target_released);
        if (id == .antitoxin) try std.testing.expect(saw_hold and saw_recovery) else if (id == .dragon_seal_incense) try std.testing.expect(saw_hold);
        try std.testing.expectEqual(@as(u16, if (id == .medicine) 200 else if (id == .dragon_seal_incense) 150 else 100), combat.hp(0));
    };
}

test "Item actor frozen body copies share source positions scale tint and opacity in both render paths" {
    var fixture = try h.Fixture.open(null);
    defer fixture.deinit();
    const art = try battle.world_art.load(allocator, @embedFile("../fixtures/world_b_party_art.json"));
    defer art.deinit();
    for ([_]bool{ false, true }) |with_world| for ([_]h.field.items.Id{ .medicine, .mega_medicine, .antitoxin, .needle, .dragon_seal_incense }, [_]usize{ 4, 8, 1, 0, 12 }) |id, expected| {
        var members: [6]battle.Member = undefined;
        var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
        if (with_world) combat.content.world_art = art.value;
        combat.camera_ticks = 300;
        combat.progress.party.at(1).status = if (id == .antitoxin) .poisoned else .healthy;
        combat.progress.party.at(1).balloons = if (id == .needle) 1 else 0;
        combat.progress.party.at(0).inventory.slots = @splat(null);
        combat.progress.party.at(0).inventory.slots[0] = .{ .id = id, .uses = if (id == .dragon_seal_incense) 0 else 1 };
        combat.actions[0] = .{ .item = .{ .slot = 0, .target = 1, .id = id } };
        try std.testing.expect(combat.beginMedicine(0));
        const start = combat.medicine_action.?.timing.target_start;
        for (0..start) |_| {
            combat.presentation_tick += 1;
            combat.advanceMedicine();
        }
        const captured = combat.medicine_action.?;
        for (0..6) |member| {
            combat.actor_transforms[member].world_offset = .{ .x = 100, .y = -50, .z = 20 };
            combat.actor_transforms[member].scale_q12 = 8192;
        }
        const effect = fixture.items.value.consumable(id).?.battle.?;
        for (0..29) |age| {
            combat.presentation_tick += 1;
            combat.advanceMedicine();
            var count: usize = 0;
            for (0..6) |member| if (battle.layout.itemParticles(&combat, member)) |particles| {
                const origin = captured.particle_origins[member].?;
                for (particles.quads[0..particles.count], effect.particles[age]) |quad, offset| {
                    try std.testing.expectEqualDeep(captured.particle_sprites[member].?, quad.sprite);
                    try std.testing.expectEqualDeep(effect.particle_tint, quad.light);
                    try std.testing.expectEqualDeep(battle.Position{ .x = origin.x + offset[0], .y = origin.y + offset[1], .z = origin.z + offset[2] }, quad.position);
                    const block = battle.layout.currentCamera(combat);
                    const scale = @as(f32, @floatFromInt(@divTrunc(block.scale[0] << 10, block.translation[2]))) / 2048;
                    try std.testing.expectApproxEqAbs(scale, quad.scale, 0.001);
                    count += 1;
                }
            };
            try std.testing.expectEqual(expected, count);
            if (with_world) {
                const frame = battle.world_art.compose(battle.layout.sceneArt(combat), combat);
                var rendered: usize = 0;
                for (frame.quads[0..frame.length]) |quad| if (quad.medicine_particle) {
                    rendered += 1;
                    try std.testing.expectEqual(@as(u8, 128), quad.opacity);
                };
                try std.testing.expectEqual(expected, rendered);
            }
        }
        combat.advanceMedicine();
        for (0..6) |member| try std.testing.expect(battle.layout.itemParticles(&combat, member) == null);
    };
}

test "Item actor released recipients retain their next spell gesture while the item owner recovers" {
    var fixture = try h.Fixture.open(null);
    defer fixture.deinit();
    var members: [6]battle.Member = undefined;
    var combat = try battle.State.init(fixture.view, fixture.items.value, &members, 17);
    combat.progress.party.at(0).inventory.slots = @splat(null);
    combat.progress.party.at(0).inventory.slots[0] = .{ .id = .medicine, .uses = 1 };
    combat.actions[0] = .{ .item = .{ .slot = 0, .target = 1, .id = .medicine } };
    try std.testing.expect(combat.beginMedicine(0));
    const release = combat.medicine_action.?.timing.target_release;
    for (0..release) |_| {
        combat.presentation_tick += 1;
        combat.advanceMedicine();
    }
    try std.testing.expect(combat.medicine_action.?.target_released and !combat.medicine_action.?.owner_released);
    try std.testing.expect(battle.layout.itemAnimation(&combat, 1) == null);
    combat.active = .{ .actor = 1, .target = combat.partyCount(), .kind = .cast };
    const cast = combat.partyProfile(1).cast;
    combat.action_ticks = cast[0].ticks;
    try std.testing.expectEqual(cast[1].source_pose, battle.layout.actorLayout(combat, 1).source_pose);
}
