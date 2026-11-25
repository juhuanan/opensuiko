const std = @import("std");
const slots = @import("room2_text").native_slots;
const names = [_]slots.Name{.{ .code = 2, .text = "Gremio", .glyph_ends = &.{ 1, 2, 3, 4, 5, 6 } }};
const context: slots.Context = .{ .generation = 1, .names = &names, .custom_images = &.{}, .loaded_characters = &.{.{ .code = 2, .id = 22 }} };
const request: slots.Request = .{ .slot = .first, .code = 2, .command = .{ .instance = 1, .batch = 1, .origin = 100 } };

test "source first pass waits and actual prefix completion admits retry" {
    var owner: slots.Owner = .{};
    try owner.allocate(.first);
    const start = try owner.propose(request, context);
    try std.testing.expectEqual(slots.Flow.wait, start.flow);
    try std.testing.expectEqualStrings("Gremio", start.prefix.?.text);
    try std.testing.expectEqual(@as(u32, 22), start.image.?.id);
    try owner.acknowledge(start, context);
    const generation = owner.slots[0].prefix.?.generation;
    for (1..8) |cursor| {
        try owner.observeGlyphs(.{ .request = request, .generation = generation, .consumed = @intCast(cursor), .done = cursor == 7 });
        const retry = try owner.propose(request, context);
        try std.testing.expectEqual(if (cursor == 7) slots.Flow.advance else slots.Flow.wait, retry.flow);
    }
    try owner.acknowledge(try owner.propose(request, context), context);
    try std.testing.expect(owner.slots[0].waiting == null);
}

test "special code requires an object and then advances without prefix wait" {
    for ([_]u8{ 8, 125, 255 }) |code| {
        var owner: slots.Owner = .{};
        const special: slots.Request = .{ .slot = .second, .code = code, .command = .{ .instance = 1, .batch = 1, .origin = 2 } };
        try std.testing.expectError(error.NativeTextObjectRequired, owner.propose(special, context));
        try owner.allocate(.second);
        const start = try owner.propose(special, context);
        try std.testing.expect(start.starts and start.flow == .wait and start.prefix == null);
        try owner.acknowledge(start, context);
        try std.testing.expectEqual(slots.Flow.advance, (try owner.propose(special, context)).flow);
    }
}

test "custom image first match wins and missing image preserves presence" {
    var owner: slots.Owner = .{};
    try owner.allocate(.first);
    const custom: slots.Context = .{ .generation = 2, .names = &names, .custom_images = &.{ .{ .code = 2, .id = 11, .available = false }, .{ .code = 2, .id = 12 }, .{ .code = 2, .id = 13 } }, .loaded_characters = context.loaded_characters };
    const proposal = try owner.propose(request, custom);
    try std.testing.expectEqual(@as(u32, 12), proposal.image.?.id);
    try owner.acknowledge(proposal, custom);
    try owner.opened(.first);
    const absent: slots.Context = .{ .generation = 3, .names = &names, .custom_images = &.{}, .loaded_characters = &.{} };
    try owner.acknowledge(try owner.propose(request, absent), absent);
    try std.testing.expectEqual(@as(u32, 12), owner.slots[0].image.?.id);
    try owner.closing(.first);
    try std.testing.expect(owner.slots[0].image == null);
}

test "stale proposals and wrong glyph receipts are atomic" {
    var owner: slots.Owner = .{};
    try std.testing.expectError(error.NativeTextObjectRequired, owner.propose(request, context));
    try owner.allocate(.first);
    const proposal = try owner.propose(request, context);
    var changed = context;
    changed.generation += 1;
    try std.testing.expectError(error.StaleNativeSlotProposal, owner.acknowledge(proposal, changed));
    try std.testing.expect(owner.slots[0].waiting == null);
    try owner.acknowledge(proposal, context);
    const before = owner;
    try std.testing.expectError(error.StaleNativeGlyphReceipt, owner.observeGlyphs(.{ .request = request, .generation = 999, .consumed = 7, .done = true }));
    try std.testing.expect(std.meta.eql(before, owner));
    var forged = proposal;
    forged.flow = .advance;
    try std.testing.expectError(error.StaleNativeSlotProposal, owner.acknowledge(forged, context));
}

test "source glyph boundary can represent one multi-character decoded glyph" {
    var owner: slots.Owner = .{};
    try owner.allocate(.first);
    const compound: slots.Context = .{ .generation = 4, .names = &.{.{ .code = 2, .text = "[s]", .glyph_ends = &.{3} }}, .custom_images = &.{}, .loaded_characters = &.{} };
    try owner.acknowledge(try owner.propose(request, compound), compound);
    const generation = owner.slots[0].prefix.?.generation;
    try owner.observeGlyphs(.{ .request = request, .generation = generation, .consumed = 1, .done = false });
    try std.testing.expectEqual(slots.Flow.wait, (try owner.propose(request, compound)).flow);
    try owner.observeGlyphs(.{ .request = request, .generation = generation, .consumed = 2, .done = true });
    try std.testing.expectEqual(slots.Flow.advance, (try owner.propose(request, compound)).flow);
}

test "receipt replay and invalid snapshot are rejected" {
    var owner: slots.Owner = .{};
    try owner.allocate(.first);
    try owner.acknowledge(try owner.propose(request, context), context);
    const receipt: slots.GlyphReceipt = .{ .request = request, .generation = owner.slots[0].prefix.?.generation, .consumed = 1, .done = false };
    try owner.observeGlyphs(receipt);
    try std.testing.expectError(error.StaleNativeGlyphReceipt, owner.observeGlyphs(receipt));
    owner.slots[0].prefix.?.done = true;
    try std.testing.expectError(error.InvalidNativePrefix, owner.validate());
}

test "source metadata loads exact names resource ordering and constructor countdowns" {
    const data = @import("opening_assets").native_slots;
    const asset = try slots.load(std.testing.allocator, data.slots_json);
    defer asset.deinit();
    const room = try asset.value.context(1, 1, &.{});
    var owner: slots.Owner = .{};
    try owner.allocate(.first);
    const gremio = try owner.propose(request, room);
    try std.testing.expectEqualStrings("Gremio", gremio.prefix.?.text);
    try std.testing.expectEqual(slots.Image{ .id = 261, .origin = .custom }, gremio.image.?);
    const ted = try owner.propose(.{ .slot = .first, .code = 108, .command = .{ .instance = 1, .batch = 1, .origin = 101 } }, try asset.value.context(2, 2, &.{}));
    try std.testing.expectEqualStrings("Ted", ted.prefix.?.text);
    try std.testing.expectEqualSlices(u8, &.{ 2, 4, 11 }, &asset.value.initial_glyph_countdowns);
}

test "metadata byte identity rejects tampered names and resource references" {
    const data = @import("opening_assets").native_slots;
    const bytes = try std.testing.allocator.dupe(u8, data.slots_json);
    defer std.testing.allocator.free(bytes);
    const name = std.mem.indexOf(u8, bytes, "Gremio").?;
    bytes[name] = 'X';
    try std.testing.expectError(error.StaleNativeSlotAsset, slots.load(std.testing.allocator, bytes));
    @memcpy(bytes, data.slots_json);
    const resource = std.mem.indexOf(u8, bytes, "\"id\": 261").?;
    bytes[resource + 6] = '9';
    try std.testing.expectError(error.StaleNativeSlotAsset, slots.load(std.testing.allocator, bytes));
}

test "revision exhaustion cannot partially mutate any owner operation" {
    var owner: slots.Owner = .{};
    try owner.allocate(.first);
    const proposal = try owner.propose(request, context);
    try owner.acknowledge(proposal, context);
    const receipt: slots.GlyphReceipt = .{ .request = request, .generation = owner.slots[0].prefix.?.generation, .consumed = 1, .done = false };
    owner.revision = std.math.maxInt(u64);
    const before = owner;
    try std.testing.expectError(error.NativeSlotRevisionExhausted, owner.allocate(.second));
    try std.testing.expectError(error.NativeSlotRevisionExhausted, owner.opened(.first));
    try std.testing.expectError(error.NativeSlotRevisionExhausted, owner.closing(.first));
    try std.testing.expectError(error.NativeSlotRevisionExhausted, owner.closingKeepImage(.first));
    try std.testing.expectError(error.NativeSlotRevisionExhausted, owner.released(.first));
    try std.testing.expectError(error.NativeSlotRevisionExhausted, owner.propose(request, context));
    try std.testing.expectError(error.NativeSlotRevisionExhausted, owner.acknowledge(proposal, context));
    try std.testing.expectError(error.NativeSlotRevisionExhausted, owner.observeGlyphs(receipt));
    try std.testing.expect(std.meta.eql(before, owner));
}

test "loaded image selection skips null pointers in source order" {
    var owner: slots.Owner = .{};
    try owner.allocate(.first);
    const loaded: slots.Context = .{ .generation = 5, .names = &names, .custom_images = &.{}, .loaded_characters = &.{ .{ .code = 2, .id = 1, .available = false }, .{ .code = 2, .id = 2 }, .{ .code = 2, .id = 3 } } };
    const selected = try owner.propose(request, loaded);
    try std.testing.expectEqual(slots.Image{ .id = 2, .origin = .loaded_character }, selected.image.?);
}

test "opcode01 retains image and object until release, unlike opcode0c" {
    var owner: slots.Owner = .{};
    try owner.allocate(.first);
    try owner.acknowledge(try owner.propose(request, context), context);
    try owner.opened(.first);
    const proposal = try owner.propose(request, context);
    try owner.closingKeepImage(.first);
    try std.testing.expect(owner.slots[0].allocated);
    try std.testing.expectEqual(slots.Image{ .id = 22, .origin = .loaded_character }, owner.slots[0].image.?);
    try std.testing.expectError(error.StaleNativeSlotProposal, owner.acknowledge(proposal, context));
    try owner.released(.first);
    try std.testing.expect(!owner.slots[0].allocated and owner.slots[0].image == null);

    try owner.allocate(.first);
    try owner.acknowledge(try owner.propose(request, context), context);
    const old_close_proposal = try owner.propose(request, context);
    try owner.closing(.first);
    try std.testing.expect(owner.slots[0].allocated and owner.slots[0].image == null);
    try std.testing.expectError(error.StaleNativeSlotProposal, owner.acknowledge(old_close_proposal, context));
}

test "both close operations reject an absent object without mutation" {
    var owner: slots.Owner = .{};
    const before = owner;
    try std.testing.expectError(error.NativeTextObjectRequired, owner.closing(.first));
    try std.testing.expect(std.meta.eql(before, owner));
    try std.testing.expectError(error.NativeTextObjectRequired, owner.closingKeepImage(.first));
    try std.testing.expect(std.meta.eql(before, owner));
}

test "both close operations reject invalid snapshots atomically" {
    var owner: slots.Owner = .{};
    owner.slots[0].prefix = .{ .glyph_count = 1, .generation = 1 };
    const before = owner;
    try std.testing.expectError(error.InvalidNativeSlot, owner.closing(.first));
    try std.testing.expectError(error.InvalidNativeSlot, owner.closingKeepImage(.first));
    try std.testing.expect(std.meta.eql(before, owner));
}
