const std = @import("std");
const r2 = @import("room2_text");
const slots = r2.native_slots;
const motion = @import("opening_audience");
const room = r2.room2_text;
const name: slots.Name = .{ .code = 108, .text = "Ted", .glyph_ends = &.{ 1, 2, 3 } };
const ctx: slots.Context = .{ .generation = 1, .names = &.{name}, .custom_images = &.{.{ .code = 108, .id = 513 }}, .loaded_characters = &.{} };
const body: motion.Text = .{ .id = "entry5", .tokens = &.{.{ .kind = .glyph, .text = "X" }} };
const binding: room.Binding = .{ .context = ctx, .body_identity = @splat(7), .body5 = body, .body47 = body, .text_speed = 0, .player_name = "Hero" };
const req: slots.Request = .{ .slot = .first, .code = 108, .command = .{ .instance = 1, .batch = 2, .origin = 3 } };

test "dispatch precedes updater and final prefix retry is next pass" {
    var state: room.State = .{};
    try std.testing.expectEqual(room.Result.advance, try state.pass(binding, .{ .action = .{ .open = .layout_zero } }));
    try std.testing.expectEqual(room.Result.wait, try state.pass(binding, .{ .action = .{ .native = req } }));
    while (state.phase != .open) _ = try state.pass(binding, .{});
    while (!state.text.done) _ = try state.pass(binding, .{});
    try std.testing.expect(state.owner.slots[0].prefix.?.done);
    try std.testing.expectEqual(room.Result.advance, try state.pass(binding, .{ .action = .{ .native = req } }));
    try std.testing.expectEqualStrings("Ted\n", state.text.visible());
    try state.validate(binding);
}

test "both closes retain object until later release and bind exact resources" {
    for ([_]bool{ false, true }) |keep| {
        var state: room.State = .{};
        _ = try state.pass(binding, .{ .action = .{ .open = .fixed_10_10_12_2 } });
        _ = try state.pass(binding, .{ .action = .{ .native = req } });
        while (state.phase != .open or !state.text.done) _ = try state.pass(binding, .{});
        _ = try state.pass(binding, .{ .action = .{ .native = req } });
        _ = try state.pass(binding, .{ .action = if (keep) .close_01 else .close_0c });
        try std.testing.expect(state.owner.slots[0].allocated);
        try std.testing.expectEqual(keep, state.owner.slots[0].image != null);
        while (state.phase == .closing) _ = try state.pass(binding, .{});
        try std.testing.expectEqual(room.Phase.release_pending, state.phase);
        try std.testing.expect(!state.fdReady());
        _ = try state.pass(binding, .{});
        try std.testing.expectEqual(room.Phase.absent, state.phase);
        try std.testing.expect(state.fdReady());
    }
}

test "stale binding refuses pass without changing state" {
    var state: room.State = .{};
    _ = try state.pass(binding, .{ .action = .{ .open = .layout_zero } });
    const before = state;
    var changed = binding;
    changed.body_identity[0] = 8;
    try std.testing.expectError(error.Room2TextBindingMismatch, state.pass(changed, .{}));
    try std.testing.expect(std.meta.eql(before, state));
}

test "body starts after staging and retains shared countdown" {
    var state: room.State = .{};
    _ = try state.pass(binding, .{ .action = .{ .open = .layout_zero } });
    _ = try state.pass(binding, .{ .action = .{ .native = req } });
    while (state.phase != .open or !state.text.done) _ = try state.pass(binding, .{});
    _ = try state.pass(binding, .{ .action = .{ .native = req } });
    const countdown = state.text.countdown;
    _ = try state.pass(binding, .{ .action = .{ .body = .entry5 } });
    try std.testing.expectEqual(@as(u16, 0), state.text.cursor);
    try std.testing.expectEqual(countdown, state.text.countdown);
    try std.testing.expectEqualStrings("Ted\n", state.text.visible());
    while (!state.bodyDone()) _ = try state.pass(binding, .{});
    try std.testing.expectEqualStrings("Ted\nX", state.text.visible());
}

fn prefixReady(state: *room.State, b: room.Binding) !void {
    _ = try state.pass(b, .{ .action = .{ .open = .layout_zero } });
    _ = try state.pass(b, .{ .action = .{ .native = req } });
    while (state.phase != .open or !state.text.done) _ = try state.pass(b, .{});
    _ = try state.pass(b, .{ .action = .{ .native = req } });
}

test "fast edge is applied after updater and consumes on next pass" {
    const fast_body: motion.Text = .{ .id = "fast", .tokens = &.{ .{ .kind = .glyph, .text = "A" }, .{ .kind = .glyph, .text = "B" } } };
    var b = binding;
    b.body5 = fast_body;
    var state: room.State = .{};
    try prefixReady(&state, b);
    _ = try state.pass(b, .{ .action = .{ .body = .entry5 }, .pressed = 0x20 });
    try std.testing.expectEqual(@as(u16, 0), state.text.cursor);
    try std.testing.expect(state.text.fast);
    _ = try state.pass(b, .{});
    try std.testing.expectEqual(@as(u16, 2), state.text.cursor);
    try std.testing.expect(state.bodyDone());
}

test "page edge applies after glyph and held repeat survives release" {
    const paged: motion.Text = .{ .id = "paged", .tokens = &.{ .{ .kind = .page }, .{ .kind = .glyph, .text = "A" } } };
    var b = binding;
    b.body5 = paged;
    var state: room.State = .{};
    try prefixReady(&state, b);
    _ = try state.pass(b, .{ .action = .{ .body = .entry5 } });
    _ = try state.pass(b, .{ .pressed = 0x20 });
    try std.testing.expect(!state.text.page_wait);
    try std.testing.expectEqual(@as(u16, 1), state.text.cursor);
    try std.testing.expect(!state.bodyDone());

    state = .{};
    try prefixReady(&state, b);
    _ = try state.pass(b, .{ .action = .{ .body = .entry5 } });
    _ = try state.pass(b, .{});
    try std.testing.expect(state.text.page_wait);
    for (0..30) |_| _ = try state.pass(b, .{ .held = 0x01 });
    _ = try state.pass(b, .{});
    try std.testing.expectEqual(@as(u8, 30), state.page_repeat);
    _ = try state.pass(b, .{ .held = 0x40 });
    try std.testing.expect(!state.text.page_wait);
    try std.testing.expectEqual(@as(u8, 0), state.page_repeat);
    try std.testing.expectEqual(@as(u16, 1), state.text.cursor);
}

test "unrelated input bits do not fast forward or acknowledge a page" {
    const paged: motion.Text = .{ .id = "masked", .tokens = &.{ .{ .kind = .page }, .{ .kind = .glyph, .text = "A" } } };
    var b = binding;
    b.body5 = paged;
    var state: room.State = .{};
    try prefixReady(&state, b);
    _ = try state.pass(b, .{ .action = .{ .body = .entry5 }, .pressed = 0x02 });
    try std.testing.expect(!state.text.fast);
    _ = try state.pass(b, .{ .pressed = 0x02, .held = 0x02 });
    try std.testing.expect(state.text.page_wait);
    try std.testing.expectEqual(@as(u8, 0), state.page_repeat);
}

test "body staging initializes selected speed and resets page repeat" {
    var b = binding;
    b.text_speed = 2;
    var state: room.State = .{};
    try prefixReady(&state, b);
    state.page_repeat = 9;
    _ = try state.pass(b, .{ .action = .{ .body = .entry5 } });
    try std.testing.expectEqual(@as(u8, 2), state.body_speed);
    try std.testing.expectEqual(@as(u8, 5), state.current_pace);
    try std.testing.expectEqual(@as(u8, 0), state.page_repeat);
}

test "body snapshots derive prefix name pages and cursor from pinned tokens" {
    const page_body: motion.Text = .{ .id = "validate-body", .tokens = &.{
        .{ .kind = .glyph, .text = "A" }, .{ .kind = .player_name },        .{ .kind = .newline },
        .{ .kind = .page },               .{ .kind = .glyph, .text = "B" },
    } };
    var b = binding;
    b.body5 = page_body;
    var state: room.State = .{};
    try prefixReady(&state, b);
    _ = try state.pass(b, .{ .action = .{ .body = .entry5 }, .pressed = 0x20 });
    _ = try state.pass(b, .{});
    try std.testing.expect(state.text.page_wait);
    try std.testing.expectEqualStrings("Ted\nAHero\n", state.text.visible());
    try state.validate(b);

    var forged = state;
    forged.text.buffer[0] = 'X';
    try std.testing.expectError(error.InvalidRoom2TextState, forged.validate(b));
    forged = state;
    forged.text.cursor -= 1;
    try std.testing.expectError(error.InvalidRoom2TextState, forged.validate(b));
    forged = state;
    forged.text.page += 1;
    try std.testing.expectError(error.InvalidRoom2TextState, forged.validate(b));
    forged = state;
    forged.text.page_wait = false;
    try std.testing.expectError(error.InvalidRoom2TextState, forged.validate(b));
    var wrong_hero = b;
    wrong_hero.player_name = "Fake";
    try std.testing.expectError(error.InvalidRoom2TextState, state.validate(wrong_hero));

    _ = try state.pass(b, .{ .pressed = 0x01 });
    try std.testing.expectEqual(@as(u8, 1), state.text.page);
    try std.testing.expectEqualStrings("", state.text.visible());
    try state.validate(b);
    while (!state.bodyDone()) _ = try state.pass(b, .{});
    try std.testing.expectEqualStrings("B", state.text.visible());
    try state.validate(b);
    forged = state;
    forged.text.done = false;
    try std.testing.expectError(error.InvalidRoom2TextState, forged.validate(b));
}

test "entry47 body snapshot verifies consumed buffer" {
    var state: room.State = .{};
    try prefixReady(&state, binding);
    _ = try state.pass(binding, .{ .action = .{ .body = .entry47 } });
    while (!state.bodyDone()) _ = try state.pass(binding, .{});
    try state.validate(binding);
    var forged = state;
    forged.text.buffer[forged.text.length - 1] = 'Z';
    try std.testing.expectError(error.InvalidRoom2TextState, forged.validate(binding));
}
