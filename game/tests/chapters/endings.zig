const std = @import("std");
const endings = @import("chapters").endings;
const data = @import("final_assets").endings;

const allocator = std.testing.allocator;

fn load() !std.json.Parsed(endings.Asset) {
    return endings.open(allocator, data.json);
}

test "asset pins all 108 source entries and the real exit/media contracts" {
    var raw_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data.json, &raw_digest, .{});
    const actual = std.fmt.bytesToHex(raw_digest, .lower);
    try std.testing.expectEqualStrings(data.asset_sha256, &actual);
    var parsed = try load();
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 108), parsed.value.entries.len);
    try std.testing.expectEqual(@as(u16, 5), parsed.value.coverage.special_dependencies);
    try std.testing.expectEqual(@as(u16, 1), parsed.value.coverage.production_endings);
    try std.testing.expectEqual(@as(u32, 0x800103B8), parsed.value.exit_callback);
    for (parsed.value.media) |media| try std.testing.expect(std.mem.endsWith(u8, media.role, "not_ending"));
}

test "no recruited flags produces 108 absent ending entries" {
    var parsed = try load();
    defer parsed.deinit();
    const flags = std.mem.zeroes([108]u8);
    const result = try endings.census(parsed.value, &flags);
    try std.testing.expectEqual(@as(u16, 108), result.absent);
    try std.testing.expectEqual(@as(u16, 0), result.recruited + result.recruited_alternate + result.lost + result.lost_alternate);
}

test "bit zero recruits, bit one loses, and both bits remain a loss" {
    var parsed = try load();
    defer parsed.deinit();
    var flags = std.mem.zeroes([108]u8);
    flags[8] = 1;
    try std.testing.expectEqual(endings.Variant.recruited, try endings.variant(parsed.value, 0, &flags));
    flags[8] = 2;
    try std.testing.expectEqual(endings.Variant.lost, try endings.variant(parsed.value, 0, &flags));
    flags[8] = 3;
    try std.testing.expectEqual(endings.Variant.lost, try endings.variant(parsed.value, 0, &flags));
}

test "character 33 uses character 63 for its alternate message" {
    var parsed = try load();
    defer parsed.deinit();
    var flags = std.mem.zeroes([108]u8);
    flags[33] = 1;
    try std.testing.expectEqual(endings.Variant.recruited, try endings.variant(parsed.value, 32, &flags));
    flags[63] = 2;
    try std.testing.expectEqual(endings.Variant.recruited_alternate, try endings.variant(parsed.value, 32, &flags));
    flags[33] = 2;
    try std.testing.expectEqual(endings.Variant.lost_alternate, try endings.variant(parsed.value, 32, &flags));
}

test "characters 2 and 6 use their own loss bit for the alternate" {
    var parsed = try load();
    defer parsed.deinit();
    var flags = std.mem.zeroes([108]u8);
    flags[2] = 2;
    try std.testing.expectEqual(endings.Variant.lost_alternate, try endings.variant(parsed.value, 8, &flags));
    flags[6] = 2;
    try std.testing.expectEqual(endings.Variant.lost_alternate, try endings.variant(parsed.value, 24, &flags));
}

test "mixed census preserves source-order alternate variants" {
    var parsed = try load();
    defer parsed.deinit();
    var flags = std.mem.zeroes([108]u8);
    for (&flags) |*flag| flag.* = 1;
    var result = try endings.census(parsed.value, &flags);
    try std.testing.expectEqual(@as(u16, 108), result.recruited);
    flags[63] = 2;
    result = try endings.census(parsed.value, &flags);
    try std.testing.expectEqual(@as(u16, 106), result.recruited);
    try std.testing.expectEqual(@as(u16, 1), result.recruited_alternate);
    try std.testing.expectEqual(@as(u16, 1), result.lost);
}

test "effect planning preserves special selectors and upper-nibble death causes" {
    var parsed = try load();
    defer parsed.deinit();
    var flags = std.mem.zeroes([108]u8);
    flags[33] = 1;
    const control = parsed.value.entries[32].control & 0x7F;
    var message = try endings.plan(parsed.value, 32, &flags);
    try std.testing.expectEqual(@as(?u32, parsed.value.effect_table[parsed.value.special_table1[control]]), message.effect);
    try std.testing.expect(message.death_effect == null);
    flags[63] = 2;
    message = try endings.plan(parsed.value, 32, &flags);
    try std.testing.expectEqual(@as(?u32, parsed.value.effect_table[parsed.value.special_table0[control]]), message.effect);
    flags[8] = 0xA2;
    message = try endings.plan(parsed.value, 0, &flags);
    try std.testing.expectEqual(@as(?u8, 10), message.death_cause);
    try std.testing.expectEqual(@as(?u32, parsed.value.death_effects[10]), message.death_effect);
}

test "bounded Hero ending executes the real message in source order and returns through ending_exit" {
    var parsed = try load();
    defer parsed.deinit();
    var flags = std.mem.zeroes([108]u8);
    flags[8] = 1;
    const message = try endings.plan(parsed.value, 0, &flags);
    try std.testing.expectEqual(endings.Variant.recruited, message.variant);
    try std.testing.expectEqual(@as(?u32, 0x80071024), message.effect);
    const execution = try endings.executeBounded(parsed.value, &flags);
    try std.testing.expectEqual(@as(u8, 0), execution.source_index);
    try std.testing.expectEqual(endings.Variant.recruited, execution.variant);
    try std.testing.expectEqualStrings("Become the President of the \nToran Republic, and...", execution.text);
    try std.testing.expectEqual(@as(u16, 108), execution.visited_entries);
    try std.testing.expectEqual(@as(u8, 6), execution.phases_completed);
    try std.testing.expectEqual(@as(u32, 0x800103B8), execution.exit_callback);
    try std.testing.expectEqual(@as(i32, -1), execution.return_value);
    try std.testing.expect(execution.overlay_context_cleared and execution.caller_word_cleared);
    try std.testing.expectEqual(@as(u8, 0), execution.str_resources_used);
    for (parsed.value.media) |media| try std.testing.expect(std.mem.endsWith(u8, media.role, "not_ending"));
}

test "bounded ending refuses other variants and altered message evidence" {
    var parsed = try load();
    defer parsed.deinit();
    var flags = std.mem.zeroes([108]u8);
    try std.testing.expectError(error.UnsupportedBoundedEndingFlags, endings.executeBounded(parsed.value, &flags));
    flags[8] = 2;
    try std.testing.expectError(error.UnsupportedBoundedEndingFlags, endings.executeBounded(parsed.value, &flags));
    flags[8] = 1;
    flags[2] = 1;
    try std.testing.expectError(error.UnsupportedBoundedEndingFlags, endings.executeBounded(parsed.value, &flags));
    flags[2] = 0;
    var bad = parsed.value;
    bad.bounded_ending.effect = 0x80071058;
    try std.testing.expectError(error.InvalidBoundedEnding, endings.executeBounded(bad, &flags));
}

test "invalid source indices and stale special dependencies fail closed" {
    var parsed = try load();
    defer parsed.deinit();
    const flags = std.mem.zeroes([108]u8);
    try std.testing.expectError(error.EndingSourceIndexOutOfRange, endings.variant(parsed.value, 108, &flags));
    const entries = try allocator.dupe(endings.Entry, parsed.value.entries);
    defer allocator.free(entries);
    entries[8].special_dependency = 63;
    var bad = parsed.value;
    bad.entries = entries;
    try std.testing.expectError(error.InvalidEndingEntry, endings.validate(bad));
}
