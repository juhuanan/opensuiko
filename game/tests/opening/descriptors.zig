const std = @import("std");
const release = @import("descriptor_release");
const movement_batch = @import("movement_batch");

const event_hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const binding: release.Binding = .{
    .scene = "va1_room2",
    .event_id = "va1_room2_field_events",
    .event_sha256 = event_hash,
    .program = "va1_r02_e02_ordinary",
    .actor_id = "scene_actor_0",
    .resource = "va1_room2_character_108",
    .graphic = "va1_room2_graphic_108",
    .entity = 2,
    .slot = 0,
    .selector = 0,
    .command_indices = .{ 0, 1, 2, 3, 4, 5, 6 },
};

fn receipt(operation: release.Operation, batch: u64) release.Receipt {
    const offset: u32 = switch (operation) {
        .x => 0x3d174,
        .y => 0x3d178,
        .mode0 => 0x3d186,
        .release => 0x3d1a4,
    };
    const opcode: [2]u8 = if (operation == .release) .{ 0x3a, 0 } else .{ 0x07, 0 };
    const value: u8 = switch (operation) {
        .x => 0x23,
        .y => 0x10,
        .mode0, .release => 0,
    };
    const index: u16 = switch (operation) {
        .x => 0,
        .y => 1,
        .mode0 => 4,
        .release => 6,
    };
    return .{
        .event_id = binding.event_id,
        .event_sha256 = binding.event_sha256,
        .program = binding.program,
        .instance = 3,
        .batch = batch,
        .command_index = index,
        .source_file = "VA1.BIN",
        .source_sha256 = release.source_sha256,
        .entity = 2,
        .selector = 0,
        .source_offset = offset,
        .opcode = opcode,
        .value = value,
        .operation = operation,
    };
}

fn apply(state: *release.State, input: release.Receipt) !void {
    const proposal = try state.stage(binding, input);
    try state.publish(proposal);
}

fn sourceCommand(offset: u32, batch: u64) !release.SourceCommand {
    const source = for (movement_batch.sources) |candidate| {
        if (candidate.offset == offset) break candidate;
    } else return error.UnknownTestSource;
    const index: u16 = switch (offset) {
        0x3d17c => 2,
        0x3d181 => 3,
        0x3d19f => 5,
        else => return error.UnknownTestSource,
    };
    return .{
        .event_id = binding.event_id,
        .event_sha256 = binding.event_sha256,
        .program = binding.program,
        .instance = 3,
        .batch = batch,
        .command_index = index,
        .source_file = "VA1.BIN",
        .source_sha256 = release.source_sha256,
        .source_offset = offset,
        .selector = source.selector,
        .parameter = source.parameter,
        .repetitions = source.repetitions,
        .direction = source.direction,
    };
}

/// Feed host-observed positions into each proposal. The one synthetic movement
/// checks retention of a partial position; it is not a source movement outcome.
fn runMovement(
    state: *release.State,
    offset: u32,
    batch: u64,
    checkpoint: *u64,
    move_once: bool,
) !void {
    const command = try sourceCommand(offset, batch);
    var owner = try movement_batch.Owner.restore(state.movement_owner);
    checkpoint.* += 1;
    const request = try owner.proposeRequest(offset, checkpoint.*);
    const before_request = state.actor_motion orelse release.ActorMotion{ .x = 280, .y = 128, .speed = 2 };
    const request_proposal = try state.stageMovement(binding, command, request, before_request, before_request);
    try state.publishMovement(request_proposal);

    var did_move = false;
    while (state.movement_owner.source_offset != null) {
        owner = try movement_batch.Owner.restore(state.movement_owner);
        checkpoint.* += 1;
        const tick = try owner.proposeTick(checkpoint.*);
        const before = state.actor_motion orelse return error.MissingObservedActor;
        var after = before;
        if (move_once and !did_move and tick.attempt != null) {
            after.x += 8;
            did_move = true;
        }
        const proposal = try state.stageMovement(binding, command, tick, before, after);
        try state.publishMovement(proposal);
    }
}

test "room2 descriptor writes retain the exact field-copy result and graphics child" {
    var state = try release.State.init(binding);
    try state.validate(binding);
    try std.testing.expectEqual(@as(u8, 254), state.x);
    try std.testing.expect(state.child.attached);

    const x = try state.stage(binding, receipt(.x, 1));
    try std.testing.expectEqual(@as(i32, 280), x.change.descriptor_x_px);
    try std.testing.expectEqual(@as(i32, 2032), x.change.descriptor_y_px);
    try std.testing.expectEqual(@as(?u8, 0xe0), x.after.descriptor_16_result);
    try std.testing.expectEqual(@as(?u8, 0xe0), x.after.history[0].?.descriptor_16_result);
    try std.testing.expect(!x.change.released and x.change.keep_graphics_child);
    try std.testing.expectEqual(@as(u8, 254), state.x); // proposal remains unpublished
    try state.publish(x);

    try apply(&state, receipt(.y, 2));
    try std.testing.expectEqual(@as(u8, 0xe0), state.descriptor_16_result.?);
    var checkpoint: u64 = 0;
    try runMovement(&state, 0x3d17c, 3, &checkpoint, false);
    try runMovement(&state, 0x3d181, 4, &checkpoint, false);
    try apply(&state, receipt(.mode0, 5));
    try runMovement(&state, 0x3d19f, 6, &checkpoint, false);
    const released = try state.stage(binding, receipt(.release, 7));
    try std.testing.expectEqual(@as(i32, 2032), released.change.descriptor_x_px);
    try std.testing.expectEqual(@as(i32, 2032), released.change.descriptor_y_px);
    try std.testing.expect(released.change.released and released.change.keep_graphics_child);
    try state.publish(released);

    try state.validate(binding);
    try std.testing.expect(state.released);
    try std.testing.expect(!state.draw_enabled);
    try std.testing.expect(state.child.attached);
    try std.testing.expectEqualStrings("va1_room2_character_108", state.child.resource);
    try std.testing.expectEqualStrings("va1_room2_graphic_108", state.child.graphic);
    try std.testing.expectEqual(@as(u8, 254), state.x);
    try std.testing.expectEqual(@as(u8, 254), state.y);
    try std.testing.expectEqual(@as(u3, 4), state.history_len);

    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, state, .{});
    defer std.testing.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(release.State, std.testing.allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try parsed.value.validate(binding);
    try std.testing.expectEqualDeep(state, parsed.value);
}

test "ordered movement receipts preserve each host observation and rebind history" {
    var state = try release.State.init(binding);
    var initial = try state.stage(binding, receipt(.x, 1));
    try state.publish(initial);
    initial = try state.stage(binding, receipt(.y, 2));
    try state.publish(initial);

    var checkpoint: u64 = 0;
    try runMovement(&state, 0x3d17c, 3, &checkpoint, true);
    try std.testing.expectEqual(@as(i32, 288), state.actor_motion.?.x);
    try runMovement(&state, 0x3d181, 4, &checkpoint, false);
    try apply(&state, receipt(.mode0, 5));
    try runMovement(&state, 0x3d19f, 6, &checkpoint, false);
    try std.testing.expectEqual(@as(u7, 99), state.movement_len);
    try std.testing.expectEqual(@as(?u32, null), state.movement_owner.source_offset);
    try std.testing.expectEqual(@as(i32, 288), state.actor_motion.?.x);
    try std.testing.expectEqual(@as(i32, 128), state.actor_motion.?.y);

    const released = try state.stage(binding, receipt(.release, 7));
    try std.testing.expectEqual(@as(?release.ActorMotion, .{ .x = 288, .y = 128, .speed = 2 }), released.change.observed_motion);
    try std.testing.expect(released.change.keep_graphics_child);
    try state.publish(released);
    try state.validate(binding);
}

test "wrong source receipts, order, replay and stale proposals are rejected" {
    var state = try release.State.init(binding);
    var wrong = receipt(.x, 1);
    wrong.source_offset += 1;
    try std.testing.expectError(error.InvalidDescriptorReceipt, state.stage(binding, wrong));
    try std.testing.expectError(error.InvalidDescriptorReceipt, state.stage(binding, receipt(.y, 1)));

    const first = try state.stage(binding, receipt(.x, 1));
    try state.publish(first);
    try std.testing.expectError(error.InvalidDescriptorReceipt, state.stage(binding, receipt(.x, 1)));

    const stale = try state.stage(binding, receipt(.y, 2));
    try apply(&state, receipt(.y, 2));
    try std.testing.expectError(error.StaleDescriptorProposal, state.publish(stale));
    var invalid = state;
    invalid.child.attached = false;
    try std.testing.expectError(error.InvalidDescriptorState, invalid.validate(binding));
}
