const std = @import("std");
const col = @import("opening_collision");
const collision = col.observation;
const destination = @import("opening_destination");
const data = @import("opening_assets").destination;
const field_actors = @import("field_actors");
const scenery37 = col.scenery37;

test "room2 collision owner is pinned to exact initial source rows" {
    try std.testing.expectEqual(@as(usize, 13), collision.expected_rows.len);
    try std.testing.expectEqual(@as(u8, 0), collision.talk_zone_count);
    try std.testing.expectEqual(@as(u8, 2), collision.expected_rows[0].entity);
    try std.testing.expectEqual(@as(i32, 280), collision.expected_rows[0].staged_x);
    try std.testing.expectEqual(@as(i32, 128), collision.expected_rows[0].staged_y);
    try std.testing.expectEqual(@as(u8, 31), collision.expected_rows[12].entity);
}

test "room2 observation accepts adjacent source steps only" {
    try collision.validateAdjacentStep(.{ .x = 35, .y = 16 }, .{ .x = 35, .y = 17 });
    try collision.validateAdjacentStep(.{ .x = 35, .y = 16 }, .{ .x = 34, .y = 16 });
    try std.testing.expectError(error.UnsupportedRoom2Step, collision.validateAdjacentStep(.{ .x = 35, .y = 16 }, .{ .x = 35, .y = 18 }));
    try std.testing.expectError(error.UnsupportedRoom2Step, collision.validateAdjacentStep(.{ .x = 35, .y = 16 }, .{ .x = 34, .y = 17 }));
}

fn actorTriggerSnapshot(state: field_actors.State, packet: field_actors.Packet, target: collision.Cell, hero: collision.Cell) !scenery37.Observation {
    var snapshot: scenery37.Observation = .{ .hero = .{ .x = @intCast(hero.x), .y = @intCast(hero.y) } };
    for (packet.actors, 0..) |_, index| {
        const pixel_x = if (index == 0) @as(i32, @intCast(target.x * 8)) else state.slots[index].?.avatar.?.motion.x;
        const pixel_y = if (index == 0) @as(i32, @intCast(target.y * 8)) else state.slots[index].?.avatar.?.motion.y;
        snapshot.area[index] = .{ .x = @intCast(@divTrunc(pixel_x, 8)), .y = @intCast(@divTrunc(pixel_y, 8)) };
    }
    return snapshot;
}

test "room2 observation samples retained fixture and rejects omitted trigger actor" {
    var opened = try destination.open(std.testing.allocator, data.json, data.ground_json);
    defer opened.deinit();
    const asset = opened.parsed.value;
    const room2 = asset.constructor.va1_room2;
    var actors = try field_actors.State.construct(room2.field_actors, room2.animations, asset.constructor.construction_story);
    // Apply the two source descriptor-display writes from the selected entity-2
    // stream (source offsets 0x3D174 and 0x3D178) to the retained actor state.
    actors.slots[0].?.avatar.?.motion.x = 35 * 8;
    actors.slots[0].?.avatar.?.motion.y = 16 * 8;

    const hero = collision.Cell{ .x = 19, .y = 33 };
    const target = collision.Cell{ .x = 35, .y = 17 };
    const snapshot = try actorTriggerSnapshot(actors, room2.field_actors, target, hero);
    const owner = scenery37.Owner.init(asset.constructor.construction_story.scenario[38], -1);
    const observation = try collision.observeInitialStep(
        room2.field_actors,
        actors,
        room2.animations,
        opened.groundRoom("va1_room_2").?,
        opened.groundIdentity("va1_room_2").?,
        hero,
        target,
        snapshot,
        owner,
        1,
    );
    try std.testing.expectEqual(.observation_only, observation.disposition);
    try std.testing.expect(observation.current_ground.walkable);
    try std.testing.expect(observation.target_ground.walkable);
    try std.testing.expectEqual(@as(u8, 0), observation.talk_zones);
    try std.testing.expectEqual(.none, observation.trigger37.transition);

    var incomplete = snapshot;
    incomplete.area[12] = null;
    try std.testing.expectError(error.IncompleteRoom2TriggerObservation, collision.observeInitialStep(
        room2.field_actors,
        actors,
        room2.animations,
        opened.groundRoom("va1_room_2").?,
        opened.groundIdentity("va1_room_2").?,
        hero,
        target,
        incomplete,
        owner,
        1,
    ));

    // Replay each source call in the first entity-2 batch against the actual
    // retained slot positions. The observer reports only E5A0's bounded row
    // scan and static ground; it does not commit movement.
    for (1..15) |call| {
        const step = try collision.observeFirstBatchStep(
            room2.field_actors,
            actors,
            room2.animations,
            opened.groundRoom("va1_room_2").?,
            opened.groundIdentity("va1_room_2").?,
            @intCast(call),
        );
        try std.testing.expectEqual(collision.first_batch_source_offset, step.source_offset);
        try std.testing.expectEqual(@as(u8, @intCast(call)), step.source_call);
        try std.testing.expectEqual(@as(u8, 13), step.live_row8_count);
        try std.testing.expectEqual(@as(u8, 0), step.self_row_excluded_by_slot);
        try std.testing.expectEqual(.miss, step.e5a0_result);
        try std.testing.expect(step.current_ground.walkable);
        try std.testing.expect(step.target_ground.walkable);
        actors.slots[0].?.avatar.?.motion.y = @as(i32, 16 + @as(i32, @intCast(call))) * 8;
    }
    try std.testing.expectError(error.UnsupportedRoom2CollisionCall, collision.observeFirstBatchStep(
        room2.field_actors,
        actors,
        room2.animations,
        opened.groundRoom("va1_room_2").?,
        opened.groundIdentity("va1_room_2").?,
        15,
    ));

    actors.slots[0].?.avatar.?.motion.y = 29 * 8;
    var missing_actor = actors;
    missing_actor.slots[12] = null;
    try std.testing.expectError(error.InvalidRoom2CollisionRows, collision.observeFirstBatchStep(
        room2.field_actors,
        missing_actor,
        room2.animations,
        opened.groundRoom("va1_room_2").?,
        opened.groundIdentity("va1_room_2").?,
        14,
    ));
}

fn sceneryObservation(x: u8, y: u8) scenery37.Observation {
    var o: scenery37.Observation = .{ .hero = .{ .x = 19, .y = 33 } };
    o.area[0] = .{ .x = x, .y = y };
    return o;
}

test "source trigger known bits and exit hysteresis" {
    var owner = scenery37.Owner.init(0, -1);
    var p = try owner.propose(sceneryObservation(35, 23), 1);
    try std.testing.expectEqual(.none, p.transition);
    try owner.commit(p.observation, p);
    p = try owner.propose(sceneryObservation(35, 24), 2);
    try std.testing.expectEqual(.enter, p.transition);
    try std.testing.expectEqual(@as(?u16, 0x506), p.command);
    try std.testing.expectEqual(@as(u32, 0xffffffff), p.after.child.known_mask);
    try std.testing.expectEqual(@as(u32, 0x1fe00ff0), p.after.child.value);
    try owner.commit(p.observation, p);
    p = try owner.propose(sceneryObservation(35, 26), 3);
    try std.testing.expectEqual(.none, p.transition);
    try owner.commit(p.observation, p);
    p = try owner.propose(sceneryObservation(35, 27), 4);
    try std.testing.expectEqual(.exit, p.transition);
    try std.testing.expectEqual(@as(?u16, null), p.command);
    try std.testing.expectEqual(@as(u32, 0x1fe00ff0), p.after.child.value);
    try owner.commit(p.observation, p);
}

test "opaque word transform cache and source scenario alternate" {
    var owner = scenery37.Owner.init(0x20, 0x547);
    const p = try owner.propose(sceneryObservation(35, 24), 1);
    try std.testing.expectEqual(@as(?u16, null), p.command);
    try std.testing.expectEqual(@as(u8, 0), p.after.scenario38);
    try std.testing.expectEqual(@as(i16, 0x547), p.after.command_cache);
    try owner.commit(p.observation, p);
    const unknown: scenery37.WordFacts = .{ .known_mask = 0, .value = 0 };
    const transformed = unknown.afterEntry();
    try std.testing.expectEqual(@as(u32, 0xfffcfffe), transformed.known_mask);
    try std.testing.expectEqual(@as(u32, 0x1fe00ff0), transformed.value);
}

test "stale observation and forged output are atomic" {
    var owner = scenery37.Owner.init(0, -1);
    const p = try owner.propose(sceneryObservation(35, 24), 1);
    try std.testing.expectError(error.StaleSceneryState, owner.commit(sceneryObservation(35, 25), p));
    var forged = p;
    forged.command = 0x547;
    try std.testing.expectError(error.InvalidSceneryProposal, owner.commit(p.observation, forged));
    try std.testing.expect(!owner.state.inside);
    try owner.commit(p.observation, p);
    try std.testing.expectError(error.StaleSceneryState, owner.commit(p.observation, p));
}
