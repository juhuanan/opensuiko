//! Bounded observation of the initial VA1 room 2 field collision inputs.
//!
//! This owner validates the retained 13-row ordinary-actor set and samples
//! static ground plus the known row-37 trigger for one adjacent candidate
//! cell. It deliberately does not decide whether source movement is accepted:
//! the original dynamic collision resolver has inputs beyond these exported
//! rows, so callers must not publish a move from this observation alone.
const std = @import("std");
const field_actors = @import("field_actors");
const ground = @import("travel").ground;
const scenery37 = @import("scenery37.zig");
const motion = @import("opening_audience");

pub const population_id = "va1_room2";
pub const population_sha256 = "9cbe4fab4c69616b5437ba520968c692e51d21d1bc526e4dfad46d9e2dec0a10";
pub const event_id = "va1_room2_field_events";
pub const event_sha256 = "31ca099b9f7400fcba90b8e99fc05414e7c1a8793c2041126fda2a958da3ec90";
pub const room_id = "va1_room_2";
pub const room_ground_sha256 = "8a0f7f8cfd377d045074fe76fd3a9383310e57f79c57cd259aa0c76d4cb8a094";
pub const source_room: u8 = 2;
pub const talk_zone_count: u8 = 0;
pub const first_batch_source_offset: u32 = 0x3d17c;

/// The runtime row order built by MAIN's `flags & 0x101` admission followed
/// by the accepted classifier records. The initial entity-2 descriptor has
/// already received source writes 0x3D174/0x3D178 (35,16); all other retained
/// rows remain off-map staging descriptors.
pub const expected_rows = [_]struct { id: []const u8, entity: u8, staged_x: i32, staged_y: i32 }{
    .{ .id = "scene_actor_0", .entity = 2, .staged_x = 280, .staged_y = 128 },
    .{ .id = "scene_actor_1", .entity = 4, .staged_x = 2032, .staged_y = 2032 },
    .{ .id = "scene_actor_2", .entity = 5, .staged_x = 2032, .staged_y = 2032 },
    .{ .id = "scene_actor_3", .entity = 7, .staged_x = 2032, .staged_y = 2032 },
    .{ .id = "scene_actor_4", .entity = 10, .staged_x = 2032, .staged_y = 2032 },
    .{ .id = "scene_actor_5", .entity = 24, .staged_x = 2040, .staged_y = 2040 },
    .{ .id = "scene_actor_6", .entity = 25, .staged_x = 2040, .staged_y = 2040 },
    .{ .id = "scene_actor_7", .entity = 26, .staged_x = 2040, .staged_y = 2040 },
    .{ .id = "scene_actor_8", .entity = 27, .staged_x = 2040, .staged_y = 2040 },
    .{ .id = "scene_actor_9", .entity = 28, .staged_x = 2040, .staged_y = 2040 },
    .{ .id = "scene_actor_10", .entity = 29, .staged_x = 2040, .staged_y = 2040 },
    .{ .id = "scene_actor_11", .entity = 30, .staged_x = 2040, .staged_y = 2040 },
    .{ .id = "scene_actor_12", .entity = 31, .staged_x = 2040, .staged_y = 2040 },
};

pub const Cell = struct { x: u16, y: u16 };
pub const Observation = struct {
    disposition: enum { observation_only },
    actor_from: Cell,
    actor_to: Cell,
    hero: Cell,
    current_ground: ground.Ground,
    target_ground: ground.Ground,
    /// Row 37 is evaluated against the hypothetical candidate positions.
    /// This is only a scenery/story proposal; no command or audio receipt is
    /// accepted here and the owner is not committed.
    trigger37: scenery37.Proposal,
    /// The source talk-zone builder sees no room-2 records satisfying 0x60.
    talk_zones: u8 = talk_zone_count,
};

pub const FirstBatchObservation = struct {
    /// This is the bounded `0x8012E5A0` scan result for the 13 retained rows.
    /// It is not an overall movement decision.
    disposition: enum { observation_only },
    source_offset: u32,
    source_call: u8,
    actor_from: Cell,
    actor_to: Cell,
    current_ground: ground.Ground,
    target_ground: ground.Ground,
    e5a0_result: enum { miss },
    live_row8_count: u8,
    self_row_excluded_by_slot: u8,
};

fn cellFromPixel(x: i32, y: i32) !Cell {
    if (x < 0 or y < 0 or x > 2040 or y > 2040 or @mod(x, 8) != 0 or @mod(y, 8) != 0)
        return error.InvalidRetainedPosition;
    return .{ .x = @intCast(@divTrunc(x, 8)), .y = @intCast(@divTrunc(y, 8)) };
}

fn validateRowsAt(packet: field_actors.Packet, actors: field_actors.State, animations: []const motion.Animation, actor_zero_y: i32) !void {
    if (!std.mem.eql(u8, packet.scene, population_id) or
        !std.mem.eql(u8, packet.population_sha256, population_sha256) or
        !std.mem.eql(u8, packet.event_sha256, event_sha256) or
        packet.actors.len != expected_rows.len or actors.count != expected_rows.len or
        !std.mem.eql(u8, actors.content_sha256, packet.content_sha256)) return error.InvalidRoom2CollisionBinding;

    for (expected_rows, 0..) |expected, index| {
        const def = packet.actors[index];
        const slot = actors.slots[index] orelse return error.InvalidRoom2CollisionRows;
        if (def.entity != expected.entity or def.slot != index or def.source_graphics != .child_present or
            slot.phase != .active or slot.avatar == null or !std.mem.eql(u8, def.id, expected.id))
            return error.InvalidRoom2CollisionRows;
        const avatar = slot.avatar.?;
        const expected_x = if (index == 0) @as(i32, 280) else expected.staged_x;
        const expected_y = if (index == 0) actor_zero_y else expected.staged_y;
        if (!std.mem.eql(u8, avatar.id, def.id) or avatar.motion.x != expected_x or avatar.motion.y != expected_y)
            return error.InvalidRoom2CollisionRows;
    }
    // The caller's source event owner qualifies the preceding 07 writes. This
    // check additionally requires the shared actor state to equal those bytes.
    const initialized = [_]field_actors.Position{.{ .actor = 0, .x = 280, .y = actor_zero_y }};
    try actors.validateTracksAtMany(packet, animations, null, &.{}, null, &initialized);
}

fn descriptorCount(observation: scenery37.Observation, cell: Cell) usize {
    var count: usize = 0;
    for (observation.area) |entry| if (entry) |value| {
        if (value.x == @as(u8, @intCast(cell.x)) and value.y == @as(u8, @intCast(cell.y))) count += 1;
    };
    for (observation.font) |entry| if (entry) |value| {
        if (value.x == @as(u8, @intCast(cell.x)) and value.y == @as(u8, @intCast(cell.y))) count += 1;
    };
    return count;
}

pub fn validateAdjacentStep(from: Cell, to: Cell) !void {
    const dx = @as(i32, to.x) - @as(i32, from.x);
    const dy = @as(i32, to.y) - @as(i32, from.y);
    if (!((dx == 1 or dx == -1) and dy == 0) and
        !(dx == 0 and (dy == 1 or dy == -1))) return error.UnsupportedRoom2Step;
}

/// Verify packet identity and that actual retained actors still match the
/// exact initial 13-row source layout. This is intentionally narrow: after
/// any actor moves, another source movement owner must validate that movement
/// history before calling this initial-layout observer.
pub fn validateInitialRows(packet: field_actors.Packet, actors: field_actors.State, animations: []const motion.Animation) !void {
    try validateRowsAt(packet, actors, animations, 128);
}

/// Replay the bounded `0x8012E5A0` row gates for calls 1–14 of VA1 room 2
/// entity 2's first movement batch. The source table builder admits exactly
/// these 13 rows and allocates the three graphics children for each live row;
/// the retained packet/active-avatar identity is the logical child-presence
/// proof for row+8. Opcode 0x07 selector 0 updates the same compact slot 0
/// that the movement program passes as its row pointer, so that row is skipped
/// by the source pointer-equality gate. Every other retained row stays at its
/// verified 254/255 staging cell, outside the candidate's ±1 window. Thus no
/// further row reaches the tile-query gates, and this scan returns 0. The
/// per-area table is built at area load and survives this batch; only area
/// teardown/rebuild invalidates it. This remains an observation, not an
/// accepted move, collision receipt, scenery command, or event advancement.
pub fn observeFirstBatchStep(
    packet: field_actors.Packet,
    actors: field_actors.State,
    animations: []const motion.Animation,
    room: *const ground.Room,
    retained_ground_sha256: []const u8,
    call: u8,
) !FirstBatchObservation {
    if (call == 0 or call > 14) return error.UnsupportedRoom2CollisionCall;
    const from_y: i32 = 128 + @as(i32, call - 1) * 8;
    const actor_y = 16 + @as(i32, call - 1);
    const target_y = actor_y + 1;
    try validateRowsAt(packet, actors, animations, from_y);
    if (!std.mem.eql(u8, room.id, room_id) or !std.mem.eql(u8, retained_ground_sha256, room_ground_sha256) or
        room.width_cells != 48 or room.height_cells != 48 or target_y >= room.height_cells)
        return error.InvalidRoom2GroundBinding;

    const from = Cell{ .x = 35, .y = @intCast(actor_y) };
    const to = Cell{ .x = 35, .y = @intCast(target_y) };
    const current_ground = ground.groundAt(room, from.x, from.y, 0);
    const target_ground = ground.groundAt(room, to.x, to.y, 0);
    var live_row8_count: u8 = 0;
    for (expected_rows, 0..) |_, index| {
        const definition = packet.actors[index];
        const slot = actors.slots[index].?;
        // MAIN's +8 load gates each E5A0 row. Here child_present plus the
        // active, identity-matched retained actor is the source-backed
        // nonnull-pointer fact; no raw heap address is carried into gameplay.
        if (definition.source_graphics == .child_present and slot.phase == .active and slot.avatar != null)
            live_row8_count += 1;
        if (index == 0) continue; // input row pointer aliases DAA0 slot 0
        const row_position = try cellFromPixel(slot.avatar.?.motion.x, slot.avatar.?.motion.y);
        const dx = @abs(@as(i32, to.x) - @as(i32, row_position.x));
        const dy = @abs(@as(i32, to.y) - @as(i32, row_position.y));
        if (dx <= 1 and dy <= 1) return error.UnsupportedRoom2DynamicCollisionRow;
    }
    if (live_row8_count != @as(u8, @intCast(expected_rows.len))) return error.InvalidRoom2CollisionRows;
    return .{
        .disposition = .observation_only,
        .source_offset = first_batch_source_offset,
        .source_call = call,
        .actor_from = from,
        .actor_to = to,
        .current_ground = current_ground,
        .target_ground = target_ground,
        .e5a0_result = .miss,
        .live_row8_count = live_row8_count,
        .self_row_excluded_by_slot = 0,
    };
}

/// Sample one adjacent entity-2 step from the verified initial layout. The
/// caller supplies the real retained Hero cell and row-37 owner state. The
/// result is evidence only; callers must authenticate the ground binding and
/// complete area/font snapshot against their retained owners. The multiplicity
/// check alone cannot prove that no extra or omitted descriptors exist.
/// Callers must still run the source-qualified dynamic collision resolver
/// before applying motion.
pub fn observeInitialStep(
    packet: field_actors.Packet,
    actors: field_actors.State,
    animations: []const motion.Animation,
    room: *const ground.Room,
    retained_ground_sha256: []const u8,
    hero: Cell,
    target: Cell,
    trigger_observation: scenery37.Observation,
    trigger_owner: scenery37.Owner,
    checkpoint: u64,
) !Observation {
    try validateInitialRows(packet, actors, animations);
    if (!std.mem.eql(u8, room.id, room_id) or !std.mem.eql(u8, retained_ground_sha256, room_ground_sha256) or
        room.width_cells != 48 or room.height_cells != 48 or
        hero.x >= room.width_cells or hero.y >= room.height_cells) return error.InvalidRoom2GroundBinding;

    const moving = try cellFromPixel(actors.slots[0].?.avatar.?.motion.x, actors.slots[0].?.avatar.?.motion.y);
    try validateAdjacentStep(moving, target);

    const current_ground = ground.groundAt(room, moving.x, moving.y, 0);
    const target_ground = ground.groundAt(room, target.x, target.y, 0);

    if (trigger_observation.hero.x != @as(u8, @intCast(hero.x)) or trigger_observation.hero.y != @as(u8, @intCast(hero.y)))
        return error.InvalidRoom2TriggerObservation;
    for (expected_rows, 0..) |_, index| {
        const cell = if (index == 0) target else try cellFromPixel(actors.slots[index].?.avatar.?.motion.x, actors.slots[index].?.avatar.?.motion.y);
        var multiplicity: usize = 0;
        for (expected_rows[0 .. index + 1], 0..) |_, prior_index| {
            const prior = if (prior_index == 0) target else try cellFromPixel(actors.slots[prior_index].?.avatar.?.motion.x, actors.slots[prior_index].?.avatar.?.motion.y);
            if (prior.x == cell.x and prior.y == cell.y) multiplicity += 1;
        }
        if (descriptorCount(trigger_observation, cell) < multiplicity) return error.IncompleteRoom2TriggerObservation;
    }
    const trigger37 = try trigger_owner.propose(trigger_observation, checkpoint);
    return .{
        .disposition = .observation_only,
        .actor_from = moving,
        .actor_to = target,
        .hero = hero,
        .current_ground = current_ground,
        .target_ground = target_ground,
        .trigger37 = trigger37,
    };
}
