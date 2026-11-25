const std = @import("std");
const war = @import("war");
const content = @import("war_content");
const view = @import("war_view");

test "all nine validate resources and render" {
    const manifest_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/assets/war/content_manifest.json", std.testing.allocator, .limited(content.max_json_bytes));
    defer std.testing.allocator.free(manifest_bytes);
    const manifest = try content.load(std.testing.allocator, manifest_bytes);
    defer manifest.deinit();
    const rules_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/assets/war/scenarios.json", std.testing.allocator, .limited(war.max_json_bytes));
    defer std.testing.allocator.free(rules_bytes);
    const rules = try war.load(std.testing.allocator, rules_bytes);
    defer rules.deinit();
    for (rules.value.scenarios) |scenario| {
        var model = try view.View.init(manifest.value, scenario.id);
        var engine = try war.Engine.init(std.testing.allocator, scenario, .{ .state = 1 });
        defer engine.deinit();
        var frame: view.Frame = undefined;
        try model.render(&engine, &frame);
        var colored: usize = 0;
        for (frame.pixels) |pixel| colored += @intFromBool(pixel.a != 0 and (pixel.r != 0 or pixel.g != 0 or pixel.b != 0));
        try std.testing.expect(colored > 1000);
    }
}

test "cell composition uses source page and tile coordinates" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/assets/war/content_manifest.json", std.testing.allocator, .limited(content.max_json_bytes));
    defer std.testing.allocator.free(bytes);
    const manifest = try content.load(std.testing.allocator, bytes);
    defer manifest.deinit();
    const scenario = manifest.value.scenarios[0];
    const map = try content.map(scenario, .sky);
    var frame: view.Frame = undefined;
    @memset(&frame.pixels, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    try view.composeMap(&frame, map, 0, 0);
    const code = map.cells[0];
    const page = try content.resource(map.pages[code >> 6]);
    const tile = code & 63;
    const source_index = (tile / 8) * 16 * 128 + (tile % 8) * 16;
    const index = page.data[source_index];
    const offset: usize = @as(usize, index) * 2;
    const expected = @as(u32, page.palette.?[offset]) + @as(u32, page.palette.?[offset + 1]) * 256;
    const actual = frame.pixels[0];
    try std.testing.expectEqual(@as(u8, @intCast((expected & 31) * 255 / 31)), actual.r);
    try std.testing.expectEqual(@as(u8, @intCast(((expected >> 5) & 31) * 255 / 31)), actual.g);
    try std.testing.expectEqual(@as(u8, @intCast(((expected >> 10) & 31) * 255 / 31)), actual.b);
}

test "unit poses use exported script dimensions and source pixels" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/assets/war/content_manifest.json", std.testing.allocator, .limited(content.max_json_bytes));
    defer std.testing.allocator.free(bytes);
    const manifest = try content.load(std.testing.allocator, bytes);
    defer manifest.deinit();
    const atlas = manifest.value.scenarios[0].atlases[0];
    try std.testing.expectEqual(@as(u8, 8), atlas.poses[0].width);
    try std.testing.expectEqual(@as(u8, 8), atlas.poses[0].height);
    try std.testing.expectEqual(@as(u8, 3), atlas.poses[0].secondary);
    try std.testing.expectEqual(@as(u8, 255), atlas.poses[0].flags);
    const entry = try content.resource(atlas.resource);
    var frame: view.Frame = undefined;
    @memset(&frame.pixels, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    view.drawPose(&frame, entry, atlas.poses[0], 0, 0);
    const offset: usize = @as(usize, entry.data[0]) * 2;
    const expected = @as(u32, entry.palette.?[offset]) + @as(u32, entry.palette.?[offset + 1]) * 256;
    const actual = frame.pixels[0];
    try std.testing.expectEqual(@as(u8, @intCast((expected & 31) * 255 / 31)), actual.r);
    try std.testing.expectEqual(@as(u8, @intCast(((expected >> 5) & 31) * 255 / 31)), actual.g);
    try std.testing.expectEqual(@as(u8, @intCast(((expected >> 10) & 31) * 255 / 31)), actual.b);
}
