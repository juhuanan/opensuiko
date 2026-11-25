const std = @import("std");
const runtime = @import("event_runtime");
const r2 = @import("room2_text");
const room = r2.room2_text;
const host = r2.host;
const native_data = @import("opening_assets").native_slots;
const destination_data = @import("opening_assets").destination;

fn content(opened: *const host.Opened) runtime.Content {
    return opened.packet.value.constructor.va1_room2.events;
}
fn pcAt(opened: *const host.Opened, offset: u32) u16 {
    const program = content(opened).program("va1_r02_e02_ordinary").?;
    for (program.commands, 0..) |command, i| if (command.source_offset == offset) return @intCast(i);
    unreachable;
}
fn frame(opened: *const host.Opened, instance: *runtime.Instance, story: *runtime.StoryState, text: *room.State, pad: host.Pad) !host.Result {
    return host.pass(std.testing.allocator, opened, instance, story, text, 7, "Hero", 0, 1, pad);
}

test "synthetic isolated PC fixture retains source 12 batch until prefix finishes" {
    var opened = try host.open(std.testing.allocator, native_data.slots_json, destination_data.json);
    defer opened.deinit();
    var story = try runtime.StoryState.init(&.{content(&opened)});
    var instance = try host.start(&opened, &story);
    // Synthetic fixture: earlier source effects are deliberately not executed.
    instance.execution.pc = pcAt(&opened, 0x3d193);
    var text: room.State = .{};
    _ = try frame(&opened, &instance, &story, &text, .{});
    try std.testing.expectEqual(pcAt(&opened, 0x3d195), instance.execution.pc);
    try std.testing.expectEqual(host.Result.waiting, try frame(&opened, &instance, &story, &text, .{}));
    const id = instance.pending.?.batch.id;
    const old_pc = instance.execution.pc;
    while (!text.text.done) {
        try std.testing.expectEqual(host.Result.waiting, try frame(&opened, &instance, &story, &text, .{}));
        try std.testing.expectEqual(id, instance.pending.?.batch.id);
        try std.testing.expectEqual(old_pc, instance.execution.pc);
    }
    _ = try frame(&opened, &instance, &story, &text, .{});
    try std.testing.expect(instance.pending == null);
    try std.testing.expectEqual(pcAt(&opened, 0x3d198), instance.execution.pc);
    _ = try frame(&opened, &instance, &story, &text, .{ .pressed = 0x20 });
    try std.testing.expectEqual(@as(u16, 0), text.text.cursor);
    try std.testing.expect(text.text.fast);
    try std.testing.expect(instance.execution.wait != null);
    _ = try frame(&opened, &instance, &story, &text, .{});
    try std.testing.expect(text.text.cursor > 0);
}

test "forged pending effect and transition are atomic refusals" {
    var opened = try host.open(std.testing.allocator, native_data.slots_json, destination_data.json);
    defer opened.deinit();
    var story = try runtime.StoryState.init(&.{content(&opened)});
    var instance = try host.start(&opened, &story);
    // Synthetic fixture only: start at source 0x0B after preceding effects.
    instance.execution.pc = pcAt(&opened, 0x3d193);
    var text: room.State = .{};
    _ = try frame(&opened, &instance, &story, &text, .{});
    _ = try frame(&opened, &instance, &story, &text, .{});
    instance.pending.?.next.pc += 1;
    const before_instance = instance;
    const before_story = story;
    const before_text = text;
    try std.testing.expectError(error.InvalidRoom2EventEffect, frame(&opened, &instance, &story, &text, .{}));
    try std.testing.expect(std.meta.eql(before_instance, instance));
    try std.testing.expect(std.meta.eql(before_story, story));
    try std.testing.expect(std.meta.eql(before_text, text));
}

test "unsupported preceding source effect refuses without state mutation" {
    var opened = try host.open(std.testing.allocator, native_data.slots_json, destination_data.json);
    defer opened.deinit();
    var story = try runtime.StoryState.init(&.{content(&opened)});
    var instance = try host.start(&opened, &story);
    var text: room.State = .{};
    const before_instance = instance;
    const before_story = story;
    const before_text = text;
    try std.testing.expectError(error.UnsupportedRoom2TextEffect, frame(&opened, &instance, &story, &text, .{}));
    try std.testing.expect(std.meta.eql(before_instance, instance));
    try std.testing.expect(std.meta.eql(before_story, story));
    try std.testing.expect(std.meta.eql(before_text, text));
}

test "synthetic fixed-box close01 retains image and FD awaits actual release" {
    var opened = try host.open(std.testing.allocator, native_data.slots_json, destination_data.json);
    defer opened.deinit();
    var story = try runtime.StoryState.init(&.{content(&opened)});
    var instance = try host.start(&opened, &story);
    // Synthetic fixture: independently place PC at fixed box source span.
    instance.execution.pc = pcAt(&opened, 0x3d1c5);
    var text: room.State = .{};
    _ = try frame(&opened, &instance, &story, &text, .{});
    _ = try frame(&opened, &instance, &story, &text, .{});
    while (instance.pending != null) _ = try frame(&opened, &instance, &story, &text, .{});
    // Synthetic fixture skips the real body and input to isolate source close01.
    instance.execution.pc = pcAt(&opened, 0x3d1d3);
    _ = try frame(&opened, &instance, &story, &text, .{});
    try std.testing.expect(text.owner.slots[0].allocated and text.owner.slots[0].image != null);
    while (text.phase == .closing) _ = try frame(&opened, &instance, &story, &text, .{ .other_low_flags_clear = true });
    try std.testing.expectEqual(room.Phase.release_pending, text.phase);
    _ = try frame(&opened, &instance, &story, &text, .{ .other_low_flags_clear = true });
    try std.testing.expectEqual(room.Phase.absent, text.phase);
    try std.testing.expect(instance.execution.active);
    _ = try frame(&opened, &instance, &story, &text, .{});
    try std.testing.expect(instance.execution.active);
    try std.testing.expectEqual(host.Result.completed, try frame(&opened, &instance, &story, &text, .{ .other_low_flags_clear = true }));
}

test "synthetic layout close0c clears image without immediate object release" {
    var opened = try host.open(std.testing.allocator, native_data.slots_json, destination_data.json);
    defer opened.deinit();
    var story = try runtime.StoryState.init(&.{content(&opened)});
    var instance = try host.start(&opened, &story);
    // Synthetic fixture skips preceding non-text event effects.
    instance.execution.pc = pcAt(&opened, 0x3d193);
    var text: room.State = .{};
    _ = try frame(&opened, &instance, &story, &text, .{});
    _ = try frame(&opened, &instance, &story, &text, .{});
    while (instance.pending != null) _ = try frame(&opened, &instance, &story, &text, .{});
    // Synthetic fixture skips body/input solely to exercise close0c.
    instance.execution.pc = pcAt(&opened, 0x3d19d);
    _ = try frame(&opened, &instance, &story, &text, .{});
    try std.testing.expect(text.owner.slots[0].allocated and text.owner.slots[0].image == null);
}

fn snapshotReceipt(opened: *const host.Opened, instance: runtime.Instance) ?host.Receipt {
    const batch = instance.effect_sequence - @as(u64, @intFromBool(instance.pending != null));
    if (batch == 0) return null;
    return .{ .content_sha256 = content(opened).content_sha256, .program = instance.program_id, .instance = 7, .batch = batch };
}
fn snapshot(opened: *const host.Opened, instance: *const runtime.Instance, story: *const runtime.StoryState, text: *const room.State, receipt: ?host.Receipt) !void {
    try host.validateSnapshot(std.testing.allocator, opened, instance, story, text, 7, receipt, "Hero", 0, 1);
}

test "synthetic source prefix snapshot binds pending receipt and PC" {
    var opened = try host.open(std.testing.allocator, native_data.slots_json, destination_data.json);
    defer opened.deinit();
    var story = try runtime.StoryState.init(&.{content(&opened)});
    var instance = try host.start(&opened, &story);
    // Synthetic fixture skips preceding source effects; it is not a route.
    instance.execution.pc = pcAt(&opened, 0x3d193);
    var text: room.State = .{};
    _ = try frame(&opened, &instance, &story, &text, .{});
    try snapshot(&opened, &instance, &story, &text, snapshotReceipt(&opened, instance));
    _ = try frame(&opened, &instance, &story, &text, .{});
    const receipt = snapshotReceipt(&opened, instance).?;
    try snapshot(&opened, &instance, &story, &text, receipt);
    var bad_receipt = receipt;
    bad_receipt.batch += 1;
    try std.testing.expectError(error.InvalidRoom2EventReceipt, snapshot(&opened, &instance, &story, &text, bad_receipt));
    bad_receipt = receipt;
    bad_receipt.instance += 1;
    try std.testing.expectError(error.InvalidRoom2EventReceipt, snapshot(&opened, &instance, &story, &text, bad_receipt));
    var bad_instance = instance;
    bad_instance.execution.pc = pcAt(&opened, 0x3d1cb);
    try std.testing.expectError(error.InvalidRoom2EventEffect, snapshot(&opened, &bad_instance, &story, &text, receipt));
    var bad_text = text;
    bad_text.job = .none;
    try std.testing.expectError(error.InvalidRoom2TextState, snapshot(&opened, &instance, &story, &bad_text, receipt));
    try std.testing.expect(instance.pending != null and text.owner.slots[0].waiting != null);
}

test "synthetic body snapshot rejects wrong job and retained receipt" {
    var opened = try host.open(std.testing.allocator, native_data.slots_json, destination_data.json);
    defer opened.deinit();
    var story = try runtime.StoryState.init(&.{content(&opened)});
    var instance = try host.start(&opened, &story);
    instance.execution.pc = pcAt(&opened, 0x3d193); // synthetic fixture
    var text: room.State = .{};
    _ = try frame(&opened, &instance, &story, &text, .{});
    _ = try frame(&opened, &instance, &story, &text, .{});
    while (instance.pending != null) _ = try frame(&opened, &instance, &story, &text, .{});
    _ = try frame(&opened, &instance, &story, &text, .{});
    const receipt = snapshotReceipt(&opened, instance).?;
    try snapshot(&opened, &instance, &story, &text, receipt);
    var bad_text = text;
    bad_text.job = .body47;
    try std.testing.expectError(error.InvalidRoom2TextState, snapshot(&opened, &instance, &story, &bad_text, receipt));
    try std.testing.expectError(error.InvalidRoom2EventReceipt, snapshot(&opened, &instance, &story, &text, null));
}
