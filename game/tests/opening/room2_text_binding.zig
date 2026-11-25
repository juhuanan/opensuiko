const std = @import("std");
const r2 = @import("room2_text");
const slots = r2.native_slots;
const glyph = r2.native_glyph_adapter;
const source = r2.binding;
const native_data = @import("opening_assets").native_slots;
const destination_data = @import("opening_assets").destination;

const name: slots.Name = .{ .code = 2, .text = "[s]x", .glyph_ends = &.{ 3, 4 } };
const context: slots.Context = .{ .generation = 1, .names = &.{name}, .custom_images = &.{}, .loaded_characters = &.{} };
const request: slots.Request = .{ .slot = .first, .code = 2, .command = .{ .instance = 1, .batch = 2, .origin = 3 } };

test "shared cursor controls receipts and same-update newline completion" {
    var owner: slots.Owner = .{};
    try owner.allocate(.first);
    try owner.acknowledge(try owner.propose(request, context), context);
    var adapter = try glyph.Adapter.start(owner, request, name, 4);
    try adapter.observe(&owner, name, .{ .generation = adapter.generation, .cursor = 0, .countdown = 3, .done = false, .visible = "" });
    try std.testing.expectEqual(@as(u8, 3), adapter.countdown);
    try adapter.observe(&owner, name, .{ .generation = adapter.generation, .cursor = 1, .countdown = 0, .done = false, .visible = "[s]" });
    try std.testing.expectEqual(slots.Flow.wait, (try owner.propose(request, context)).flow);
    try adapter.observe(&owner, name, .{ .generation = adapter.generation, .cursor = 3, .countdown = 0, .done = true, .visible = "[s]x\n" });
    try std.testing.expectEqual(slots.Flow.advance, (try owner.propose(request, context)).flow);
    try adapter.validate(owner, name);
}

test "stale observations and invalid snapshots leave both owners unchanged" {
    var owner: slots.Owner = .{};
    try owner.allocate(.first);
    try owner.acknowledge(try owner.propose(request, context), context);
    var adapter = try glyph.Adapter.start(owner, request, name, 2);
    const before = adapter;
    const before_owner = owner;
    try std.testing.expectError(error.StaleNativeGlyphObservation, adapter.observe(&owner, name, .{ .generation = adapter.generation + 1, .cursor = 1, .countdown = 0, .done = false, .visible = "[s]" }));
    try std.testing.expectError(error.InvalidNativeGlyphAdapter, adapter.observe(&owner, name, .{ .generation = adapter.generation, .cursor = 1, .countdown = 0, .done = false, .visible = "bad" }));
    try std.testing.expect(std.meta.eql(before, adapter));
    try std.testing.expect(std.meta.eql(before_owner, owner));
    var corrupt = adapter;
    corrupt.visible[0] = 'x';
    try std.testing.expectError(error.InvalidNativeGlyphAdapter, corrupt.validate(owner, name));
}

test "verified source binds exact Ted custom image and body entries" {
    var opened = try source.open(std.testing.allocator, native_data.slots_json, destination_data.json);
    defer opened.deinit();
    const bound = try opened.bind("Hero", 2, 71);
    try std.testing.expectEqual(@as(u64, 71), bound.context.generation);
    try std.testing.expectEqual(@as(usize, 0), bound.context.loaded_characters.len);
    try std.testing.expectEqual(@as(u32, 513), bound.context.custom_images[1].id);
    try std.testing.expect(bound.context.custom_images[1].available);
    try std.testing.expectEqualStrings("va1_r02_text_5", bound.body5.id);
    try std.testing.expectEqualStrings("va1_r02_text_47", bound.body47.id);
    try std.testing.expectEqual(@as(usize, 160), bound.body5.tokens.len);
    try std.testing.expectEqual(@as(usize, 20), bound.body47.tokens.len);
    try std.testing.expectEqualStrings("Hero", bound.player_name);
    try std.testing.expectError(error.InvalidRoom2TextSpeed, opened.bind("Hero", 3, 71));
}

test "both source byte identities reject tampering" {
    const allocator = std.testing.allocator;
    const packet = try allocator.dupe(u8, destination_data.json);
    defer allocator.free(packet);
    packet[0] ^= 1;
    try std.testing.expectError(error.InvalidRoom2PacketDigest, source.open(allocator, native_data.slots_json, packet));
    const native = try allocator.dupe(u8, native_data.slots_json);
    defer allocator.free(native);
    native[0] ^= 1;
    try std.testing.expectError(error.StaleNativeSlotAsset, source.open(allocator, native, destination_data.json));
}

test "bind rejects post-open token and identity mutation" {
    var opened = try source.open(std.testing.allocator, native_data.slots_json, destination_data.json);
    defer opened.deinit();
    const texts = @constCast(opened.packet.value.constructor.va1_room2.dialogue.texts);
    const first = @constCast(texts[0].tokens);
    const old_first = first[0];
    first[0].text = "X";
    try std.testing.expectError(error.InvalidRoom2Packet, opened.bind("Hero", 0, 1));
    first[0] = old_first;
    const second = @constCast(texts[1].tokens);
    const old_second = second[0];
    second[0].text = "X";
    try std.testing.expectError(error.InvalidRoom2Packet, opened.bind("Hero", 0, 1));
    second[0] = old_second;
    const old_identity = opened.body_identity;
    opened.body_identity[0] ^= 1;
    try std.testing.expectError(error.InvalidRoom2PacketDigest, opened.bind("Hero", 0, 1));
    opened.body_identity = old_identity;
    _ = try opened.bind("Hero", 0, 1);
}

test "bind rejects reordered or forged source custom records and Ted name" {
    var opened = try source.open(std.testing.allocator, native_data.slots_json, destination_data.json);
    defer opened.deinit();
    const rooms = @constCast(opened.native.value.rooms);
    const r = for (rooms) |*item| {
        if (item.room == 2) break item;
    } else unreachable;
    const resources = @constCast(r.custom_images);
    const first = resources[0];
    resources[0] = resources[1];
    resources[1] = first;
    try std.testing.expectError(error.InvalidRoom2CustomImage, opened.bind("Hero", 0, 1));
    resources[1] = resources[0];
    resources[0] = first;
    resources[1].available = false;
    try std.testing.expectError(error.InvalidRoom2CustomImage, opened.bind("Hero", 0, 1));
    resources[1].available = true;
    const names = @constCast(opened.native.value.names);
    const ted = for (names) |*item| {
        if (item.code == 108) break item;
    } else unreachable;
    const old_text = ted.text;
    ted.text = "Tad";
    try std.testing.expectError(error.InvalidRoom2Packet, opened.bind("Hero", 0, 1));
    ted.text = old_text;
    _ = try opened.bind("Hero", 0, 1);
}
