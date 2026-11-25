//! Integrated gate: production Session/campaign host wiring plus the
//! source-encoded encounter binding.  Static/port level only: no original
//! instruction, emulator, window, media or user save is touched.
const std = @import("std");
const campaign_session = @import("campaign_session");
const bindings = campaign_session.bindings;
const mode_result_mod = @import("campaign_policies").mode_result;

test "region B source rate is bound and region C remains a typed blocker" {
    const rate = bindings.rateFor("region_b").?;
    try std.testing.expectEqual(@as(u8, 2), rate.rate);
    try std.testing.expectEqual(@as(u16, 60), rate.counter_threshold);
    try std.testing.expect(bindings.rateFor("region_c") == null);
}

test "campaign snapshot carries only value projections and no live owner pointer" {
    var campaign: campaign_session.Campaign = .{};
    try std.testing.expect((try campaign.snapshot()) == null);
    try std.testing.expect(campaign.host == null);
}

test "campaign production host uses the shared mode-result transaction envelope" {
    const source = campaign_session.review.session_source;
    try std.testing.expect(std.mem.indexOf(u8, source, "mode_result.Host.begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "mode_result.Host.commit") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "mode_result.Store") != null);
    try std.testing.expect(@TypeOf(mode_result_mod.Host) != void);
}

test "mode-result durable identities parse from the nested world-session value form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"id\":\"hero\",\"sha\":\"106e9b6f4e57a0cbec2b3a1772d5d270db416fefdb22e69c5d5e1687c4f477dd\"}", .{ .allocate = .alloc_always });
    const id = try std.json.innerParseFromValue(mode_result_mod.Id, arena.allocator(), value.object.get("id").?, .{});
    try std.testing.expectEqualStrings("hero", id.slice());
    const sha = try std.json.innerParseFromValue(mode_result_mod.Sha, arena.allocator(), value.object.get("sha").?, .{});
    try std.testing.expectEqualStrings("106e9b6f4e57a0cbec2b3a1772d5d270db416fefdb22e69c5d5e1687c4f477dd", &sha.hex());
    try std.testing.expectError(error.UnexpectedToken, std.json.innerParseFromValue(mode_result_mod.Id, arena.allocator(), .{ .integer = 1 }, .{}));
}

test "campaign host clone does not share a host pointer" {
    var campaign = campaign_session.Campaign{ .battles = 2, .items = 1 };
    var copy = try campaign.clone(std.testing.allocator);
    defer copy.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), copy.battles);
    try std.testing.expect(copy.host == null and campaign.host == null);
}
