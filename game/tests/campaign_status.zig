const std = @import("std");
const campaign = @import("campaign");

test "the campaign exposes the existing /13 snapshot type" {
    const Snapshot = campaign.CampaignSnapshot;
    try std.testing.expect(@sizeOf(Snapshot) > 0);
}

test "the campaign reports opening stages integrated with human native review remaining" {
    var state = try campaign.open(std.testing.allocator);
    defer state.deinit();
    const status = state.status();
    try std.testing.expectEqualStrings("first_town", status.stage);
    try std.testing.expect(status.playable);
    try std.testing.expectEqualStrings("route", status.next);
    try std.testing.expectEqualStrings("native_review", status.blocker.?);
    try std.testing.expectEqualStrings("human", status.blocker_kind.?);
    try std.testing.expectEqualStrings("user", status.owner.?);
    try std.testing.expectEqualStrings("game/assets/campaign/opening/first_town", status.content_root);
    try std.testing.expectEqual(@as(?u32, 220), status.compiled_programs);
    try std.testing.expectEqual(@as(?u32, 0), status.blocked_programs);
    try std.testing.expectEqual(@as(?u32, 14), status.completed_programs);
    try std.testing.expectEqual(@as(?u32, 9), status.war_scenarios);
    try std.testing.expectEqual(@as(?u32, 9), status.war_adapter_ready);
    try std.testing.expectEqual(@as(?u32, 0), status.war_accepted_dependencies);
    try std.testing.expectEqual(@as(?u32, 0), status.war_canonical_mappings);
    try std.testing.expectEqualStrings("external", status.war_stage);
}
