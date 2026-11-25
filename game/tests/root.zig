const std = @import("std");
const menu = @import("game");
const campaign = @import("campaign");

test {
    _ = @import("field.zig");
    _ = @import("inn.zig");
    _ = @import("save_menu.zig");
    _ = @import("items.zig");
    _ = @import("battle.zig");
    _ = @import("demo_batch.zig");
    _ = @import("journey.zig");
    _ = @import("opening_events.zig");
    _ = @import("opening.zig");
    _ = @import("opening_audience.zig");
    _ = @import("audio_route.zig");
    _ = @import("ui_font.zig");
    _ = @import("battle_camera.zig");
    _ = @import("party_session/session.zig");
}

test "empty availability is rejected and an unavailable prior choice falls back" {
    try std.testing.expectError(error.NoEnabledCommands, menu.Picker.init(.{ false, false, false, false, false }, .attack));
    const picker = try menu.Picker.init(.{ false, true, false, true, false }, .rune);
    try std.testing.expectEqual(menu.Command.defend, picker.selected);
}

test "picker agrees with independently evaluated MAIN instructions" {
    const parsed = try std.json.parseFromSlice([]const [5]u8, std.testing.allocator, @embedFile("fixtures/battle_picker.json"), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1280), parsed.value.len);
    for (parsed.value) |row| {
        var enabled: [5]bool = undefined;
        for (&enabled, 0..) |*value, i| value.* = row[0] & (@as(u8, 1) << @intCast(i)) != 0;
        var picker = try menu.Picker.init(enabled, @fromBackingInt(@intCast(row[1])));
        const result = picker.update(.{
            .up = row[2] & 1 != 0,
            .down = row[2] & 2 != 0,
            .confirm = row[2] & 4 != 0,
            .cancel = row[2] & 8 != 0,
        });
        const outcome: u8 = switch (result) {
            .none => 0,
            .confirmed => |c| 1 + @backingInt(c),
            .cancelled => 6,
        };
        try std.testing.expectEqual(row[3], if (outcome == 0) @backingInt(picker.selected) else row[1]);
        try std.testing.expectEqual(row[4], outcome);
    }
}

test "campaign reports one route, not chapter stages" {
    var owner = try campaign.open(std.testing.allocator);
    defer owner.deinit();
    const status = owner.status();
    try std.testing.expect(status.playable);
    try std.testing.expect(std.mem.eql(u8, status.stage, "palace") or std.mem.eql(u8, status.stage, "first_town"));
    try std.testing.expect(!std.mem.eql(u8, status.stage, "middle"));
    try std.testing.expect(!std.mem.eql(u8, status.next, "middle"));
    try std.testing.expect(!std.mem.eql(u8, status.next, "final"));
    try std.testing.expect(!std.mem.eql(u8, status.next, "ending"));
}
