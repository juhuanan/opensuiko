const std = @import("std");
const content = @import("war_content");

fn load() !std.json.Parsed(content.Manifest) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/assets/war/content_manifest.json", std.testing.allocator, .limited(content.max_json_bytes));
    defer std.testing.allocator.free(bytes);
    return content.load(std.testing.allocator, bytes);
}

test "all scenario resources and audio references validate" {
    const manifest = try load();
    defer manifest.deinit();
    try std.testing.expectEqual(@as(usize, 9), manifest.value.scenarios.len);
    for (manifest.value.scenarios) |scenario| {
        _ = try content.map(scenario, .battlefield);
        _ = try content.map(scenario, .sky);
        _ = try content.portrait(scenario, 0);
        for (scenario.atlases) |atlas| _ = try content.resource(atlas.resource);
    }
    try std.testing.expect(manifest.value.audio.sample_count > 0);
    _ = try content.resource(manifest.value.audio.body);
}

test "map and missing-resource failures are explicit" {
    const manifest = try load();
    defer manifest.deinit();
    try std.testing.expectError(error.UnknownWarResource, content.resource("not-a-resource"));
    const scenario = manifest.value.scenarios[6];
    const battlefield = try content.map(scenario, .battlefield);
    try std.testing.expectEqual(@as(u16, 23), battlefield.width);
}

test "embedded resource hashes are checked" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/assets/war/content_manifest.json", std.testing.allocator, .limited(content.max_json_bytes));
    defer std.testing.allocator.free(bytes);
    const marker = "\"data_sha256\": \"";
    const start = std.mem.indexOf(u8, bytes, marker).? + marker.len;
    bytes[start] = if (bytes[start] == '0') '1' else '0';
    try std.testing.expectError(error.InvalidWarResourceData, content.load(std.testing.allocator, bytes));
}
