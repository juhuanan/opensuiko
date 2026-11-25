const std = @import("std");
const dungeon = @import("opening_dungeon");
const data = @import("opening_assets").dungeon;
const events = @import("event_runtime");

const allocator = std.testing.allocator;

fn load() !std.json.Parsed(dungeon.Asset) {
    return dungeon.open(allocator, data.json);
}

test "asset hash and corrected VAA room grid are pinned" {
    var raw_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data.json, &raw_digest, .{});
    const actual = std.fmt.bytesToHex(raw_digest, .lower);
    try std.testing.expectEqualStrings(data.asset_sha256, &actual);
    var parsed = try load();
    defer parsed.deinit();
    const room = dungeon.roomById(parsed.value, "vaa_room_0").?;
    try std.testing.expectEqual(@as(usize, 160 * 96), room.walkable.len);
}

test "selector nine resolves VAA and its spawn is walkable" {
    var parsed = try load();
    defer parsed.deinit();
    try std.testing.expectEqualStrings("DATA/01_AREA.A/VAA.BIN", parsed.value.entry.resolved_file);
    try dungeon.admitEntry(parsed.value);
}

test "grid queries reject negative and non-cell coordinates" {
    var parsed = try load();
    defer parsed.deinit();
    const room = dungeon.roomById(parsed.value, "vaa_room_0").?;
    try std.testing.expect(!room.canStand(-8, 0));
    try std.testing.expect(!room.canStand(1, 0));
    try std.testing.expect(!room.canStand(0, 1));
    try std.testing.expect(!room.canStand(1280, 0));
}

test "walkable bits remain source data rather than a blanket map" {
    var parsed = try load();
    defer parsed.deinit();
    const room = dungeon.roomById(parsed.value, "vaa_room_0").?;
    var walkable: usize = 0;
    for (room.walkable) |cell| walkable += @intFromBool(cell == '1');
    try std.testing.expect(walkable != 0 and walkable < room.walkable.len);
}

test "fourteen complete VAA ordinary programs are carried by the dungeon package" {
    var parsed = try load();
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u8, 14), parsed.value.coverage.completed_dungeon_programs);
    var programs = try dungeon.openPrograms(allocator);
    defer programs.deinit();
    try std.testing.expectEqual(@as(usize, 14), programs.value.programs.len);
    try std.testing.expect(programs.value.program("vaa_r00_e00_ordinary") != null);
}

test "valid spawn still does not claim the whole dungeon is playable" {
    var parsed = try load();
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u8, 14), parsed.value.coverage.completed_dungeon_programs);
}

test "stale grid and false blocked-spawn claims fail closed" {
    var parsed = try load();
    defer parsed.deinit();
    var bad = parsed.value;
    const rooms = try allocator.dupe(dungeon.Room, bad.rooms);
    defer allocator.free(rooms);
    rooms[0].width = 384;
    bad.rooms = rooms;
    try std.testing.expectError(error.InvalidDungeonRoom, dungeon.validate(bad));
    bad = parsed.value;
    bad.entry.status = "blocked_spawn_outside_decoded_room_grid";
    try std.testing.expectError(error.InvalidDungeonEntry, dungeon.validate(bad));
}
