const std = @import("std");
const ch = @import("chapters");
const events = @import("event_runtime");
const story = ch.middle_story;
const story_data = @import("middle_assets").dialogue;
const final = ch.final_story;
const data = @import("final_assets").final_story;

const allocator = std.testing.allocator;

const Loaded = struct {
    manifest: std.json.Parsed(story.Manifest),
    asset: std.json.Parsed(final.Asset),
    parsed: []std.json.Parsed(events.Content),
    contents: []events.Content,

    fn deinit(self: *Loaded) void {
        for (self.parsed) |*content| content.deinit();
        allocator.free(self.parsed);
        allocator.free(self.contents);
        self.asset.deinit();
        self.manifest.deinit();
    }
};

fn load() !Loaded {
    const manifest = try story.loadManifest(allocator, story_data.manifest_json);
    errdefer manifest.deinit();
    const asset = try final.open(allocator, data.json, manifest.value);
    errdefer asset.deinit();
    const parsed = try allocator.alloc(std.json.Parsed(events.Content), story_data.content_json.len);
    const contents = try allocator.alloc(events.Content, story_data.content_json.len);
    var count: usize = 0;
    errdefer {
        for (0..count) |index| parsed[index].deinit();
        allocator.free(parsed);
        allocator.free(contents);
    }
    for (story_data.content_json, 0..) |raw, index| {
        parsed[index] = try std.json.parseFromSlice(events.Content, allocator, raw, .{ .allocate = .alloc_always });
        count += 1;
        try parsed[index].value.validate();
        contents[index] = parsed[index].value;
    }
    return .{ .manifest = manifest, .asset = asset, .parsed = parsed, .contents = contents };
}

fn contentFor(loaded: *const Loaded, id: []const u8) !events.Content {
    for (loaded.contents) |content| {
        if (std.mem.eql(u8, content.id, id)) return content;
    }
    return error.MissingTestContent;
}

fn runProgram(content: events.Content, story_state: *events.StoryState, program_id: []const u8) !void {
    var instance = try events.start(content, story_state, program_id);
    var ids: [70][]const u8 = undefined;
    var count: usize = 0;
    for ([_][]const u8{ "box_0", "box_1", "dialogue_flags", "accept", "delay" }) |id| {
        ids[count] = id;
        count += 1;
    }
    for (content.texts) |text| {
        ids[count] = text.id;
        count += 1;
    }
    for (0..256) |_| {
        const result = try events.step(content, &instance, story_state, .{ .completions = ids[0..count], .confirm = true });
        if (result.batch) |batch| try events.acknowledge(content, &instance, story_state, batch.id);
        if (!instance.execution.active and instance.pending == null) return;
    }
    return error.ProgramDidNotComplete;
}

test "asset pins 144 compiled programs and 293 exact blockers" {
    var raw_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data.json, &raw_digest, .{});
    const actual = std.fmt.bytesToHex(raw_digest, .lower);
    try std.testing.expectEqualStrings(data.asset_sha256, &actual);
    var loaded = try load();
    defer loaded.deinit();
    try final.validate(loaded.asset.value, loaded.manifest.value);
    try std.testing.expectEqual(@as(usize, 144), loaded.asset.value.compiled_ids.len);
    try std.testing.expectEqual(@as(usize, 293), loaded.asset.value.blocked.len);
    try std.testing.expectEqual(@as(u16, 6), loaded.asset.value.coverage.source_files);
}

test "every final content reference resolves against immutable identities" {
    var loaded = try load();
    defer loaded.deinit();
    try story.validateContents(loaded.manifest.value, loaded.contents);
    for (loaded.asset.value.compiled_ids) |id| {
        const entry = final.entryById(loaded.manifest.value, id).?;
        var found = false;
        for (loaded.contents) |content| {
            if (std.mem.eql(u8, entry.content_id.?, content.id) and
                std.mem.eql(u8, entry.content_sha256.?, content.content_sha256))
            {
                found = true;
                try std.testing.expect(content.program(id) != null);
            }
        }
        try std.testing.expect(found);
    }
}

test "VZ1 source dialogue executes through the shared VM" {
    var loaded = try load();
    defer loaded.deinit();
    const content = try contentFor(&loaded, "vz1_room0_dialogue_0");
    var story_state = try events.StoryState.init(loaded.contents);
    try runProgram(content, &story_state, "vz1_r00_e00_ordinary");
}

test "the first selected unsupported entry remains a typed blocker" {
    var loaded = try load();
    defer loaded.deinit();
    const decision = try final.plan(loaded.asset.value, loaded.manifest.value, "vz1_r00_e05_ordinary");
    try std.testing.expect(std.mem.startsWith(u8, decision.blocked.reason, "vz1_r00_e05_ordinary: unsupported opcode 0x32"));
    const other = try final.plan(loaded.asset.value, loaded.manifest.value, "vz1_r00_e04_ordinary");
    try std.testing.expectEqualStrings("unsupported ordinary predicate term: unsupported", other.blocked.reason);
}

test "a stale compiled reference is rejected" {
    var loaded = try load();
    defer loaded.deinit();
    const ids = try allocator.dupe([]const u8, loaded.asset.value.compiled_ids);
    defer allocator.free(ids);
    ids[0] = "missing";
    var bad = loaded.asset.value;
    bad.compiled_ids = ids;
    try std.testing.expectError(error.MissingFinalProgram, final.validate(bad, loaded.manifest.value));
}

test "VZ7 remains outside ordinary event IR and production" {
    var loaded = try load();
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u32, 0x80010EE8), loaded.asset.value.terminal.main_ending);
    try std.testing.expectEqual(@as(u32, 0x800103B8), loaded.asset.value.terminal.ending_exit);
    try std.testing.expectEqualStrings("source_only_not_event_ir", loaded.asset.value.terminal.state);
    try std.testing.expectEqual(@as(u16, 0), loaded.asset.value.coverage.production_programs);
    for (loaded.manifest.value.entries) |entry| {
        try std.testing.expect(!std.mem.eql(u8, entry.source_file, "DATA/15_AREA.Z/VZ7.BIN"));
    }
}
