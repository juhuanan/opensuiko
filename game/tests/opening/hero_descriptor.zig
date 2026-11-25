const std = @import("std");
const motion = @import("opening_audience");
const hero = @import("hero_descriptor");

const ticks = [_]u16{ 12, 12, 12, 12 };
const bounds: [4]motion.Bounds = @splat(.{ .width = 24, .height = 48 });
const clip: motion.AnimationClip = .{ .flags = 3, .ticks = &ticks, .bounds = &bounds };
const animation: motion.Animation = .{ .graphic = "hero", .clips = .{ clip, clip, clip, clip } };

test "construction uses retained sequence and distinct source clocks" {
    const auxiliary = try hero.Auxiliary.init(animation, 3);
    try auxiliary.validateState(animation);
    try std.testing.expectEqual(@as(u2, 3), auxiliary.child_0c.variant);
    try std.testing.expectEqual(@as(u8, 1), auxiliary.child_0c.animation.frame);
    try std.testing.expectEqual(@as(u16, 12), auxiliary.child_10.animation.remaining);
    try std.testing.expectEqual(@as(u8, 0x80), auxiliary.child_0c.attr_18);
}

test "reset, paired ticks and opcode 11 respect source call boundaries" {
    var auxiliary = try hero.Auxiliary.init(animation, 0);
    try std.testing.expectEqual(@as(u8, 0x23), try auxiliary.sequenceReset(animation, 1, 0, 0x123));
    try std.testing.expectEqual(@as(u8, 0), auxiliary.child_0c.animation.frame);
    try std.testing.expectEqual(@as(u16, 12), auxiliary.child_0c.animation.remaining);
    try std.testing.expectEqual(@as(u2, 0), auxiliary.child_10.variant);
    _ = try auxiliary.pairedTick(animation, 0, 0x80);
    _ = try auxiliary.pairedTick(animation, 0, 0x80);
    try std.testing.expectEqual(@as(u16, 10), auxiliary.child_0c.animation.remaining);
    const before = auxiliary;
    try std.testing.expect((try auxiliary.opcode11(animation, 1, 1, 1, 0x80)) == null);
    try std.testing.expectEqualDeep(before, auxiliary);
    try std.testing.expectEqual(@as(?u8, 0x80), try auxiliary.opcode11(animation, 1, 2, 1, 0x80));
    try std.testing.expectEqual(@as(u2, 2), auxiliary.child_0c.variant);
    try std.testing.expectEqual(@as(u16, 11), auxiliary.child_0c.animation.remaining);
    try std.testing.expectEqual(@as(u8, 0xa0), auxiliary.child_0c.attr_18);
    try std.testing.expectEqual(@as(u8, 2), auxiliary.child_0c.attr_19);
    try std.testing.expectEqual(@as(u8, 0x22), auxiliary.child_10.attr_18);
    try std.testing.expectEqual(@as(u8, 1), auxiliary.child_10.attr_19);
}

test "draw attributes follow room, level and full tint word" {
    var auxiliary = try hero.Auxiliary.init(animation, 0);
    try std.testing.expect(!(try auxiliary.draw(animation, 0, 0, 0)).source_draw_selected);
    try std.testing.expect(!(try auxiliary.draw(animation, 1, 1, 0)).source_draw_selected);
    try std.testing.expect((try auxiliary.draw(animation, 1, 0, 0)).source_draw_selected);
    try std.testing.expectEqual(@as(u8, 0), auxiliary.child_0c.attr_18);
    _ = try auxiliary.draw(animation, 1, 0, 0x100);
    try std.testing.expectEqual(@as(u8, 0x20), auxiliary.child_0c.attr_18);
    try auxiliary.validateState(animation);
}

test "serialized auxiliary state restores and rejects malformed clock" {
    var original = try hero.Auxiliary.init(animation, 1);
    _ = try original.pairedTick(animation, 0, 0);
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, original, .{});
    defer std.testing.allocator.free(bytes);
    const restored = try std.json.parseFromSlice(hero.Auxiliary, std.testing.allocator, bytes, .{ .allocate = .alloc_always });
    defer restored.deinit();
    try restored.value.validateState(animation);
    try std.testing.expectEqualDeep(original, restored.value);
    var invalid = restored.value;
    invalid.child_0c.animation.remaining = 0;
    try std.testing.expectError(error.InvalidAuxiliaryState, invalid.validateState(animation));
}
