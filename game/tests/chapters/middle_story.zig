const std = @import("std");
const events = @import("event_runtime");
const story = @import("chapters").middle_story;
const data = @import("middle_assets").dialogue;

const allocator = std.testing.allocator;

const Loaded = struct {
    parsed: []std.json.Parsed(events.Content),
    contents: []events.Content,
    manifest: std.json.Parsed(story.Manifest),

    fn deinit(self: *Loaded) void {
        for (self.parsed) |*content| content.deinit();
        allocator.free(self.parsed);
        allocator.free(self.contents);
        self.manifest.deinit();
    }
};

fn load() !Loaded {
    const parsed = try allocator.alloc(std.json.Parsed(events.Content), data.content_json.len);
    const contents = try allocator.alloc(events.Content, data.content_json.len);
    var count: usize = 0;
    errdefer {
        for (0..count) |index| parsed[index].deinit();
        allocator.free(parsed);
        allocator.free(contents);
    }
    for (data.content_json, 0..) |raw, index| {
        parsed[index] = try std.json.parseFromSlice(events.Content, allocator, raw, .{ .allocate = .alloc_always });
        count += 1;
        try parsed[index].value.validate();
        contents[index] = parsed[index].value;
    }
    return .{ .parsed = parsed, .contents = contents, .manifest = try story.loadManifest(allocator, data.manifest_json) };
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

test "manifest identity covers every generated program" {
    var raw_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data.manifest_json, &raw_digest, .{});
    const actual = std.fmt.bytesToHex(raw_digest, .lower);
    try std.testing.expectEqualStrings(data.manifest_sha256, &actual);
    var loaded = try load();
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 4839), loaded.manifest.value.entries.len);
    try std.testing.expectEqual(@as(usize, 1130), loaded.manifest.value.coverage.compiled_programs);
}

test "all 318 bundles and references validate" {
    var loaded = try load();
    defer loaded.deinit();
    try story.validateContents(loaded.manifest.value, loaded.contents);
}

test "representative source dialogue completes through the shared VM" {
    var loaded = try load();
    defer loaded.deinit();
    const content = try contentFor(&loaded, "va1_room0_dialogue_0");
    var story_state = try events.StoryState.init(loaded.contents);
    try runProgram(content, &story_state, "va1_r00_e27_ordinary");
}

test "a source story guard rejects then admits" {
    var loaded = try load();
    defer loaded.deinit();
    var story_state = try events.StoryState.init(loaded.contents);
    var selected: ?struct { content: events.Content, program: events.Program } = null;
    outer: for (loaded.contents) |content| {
        for (content.programs) |program| {
            for (program.conditions) |condition| {
                if (condition.kind != .story_mask_set) continue;
                selected = .{ .content = content, .program = program };
                break :outer;
            }
        }
    }
    const content = selected.?.content;
    const program = selected.?.program;
    try std.testing.expectError(error.EventConditionFalse, events.start(content, &story_state, program.id));
    for (program.conditions) |condition| {
        const index = std.fmt.parseInt(u8, condition.flag.id[9..], 10) catch unreachable;
        if (condition.kind == .story_mask_set) story_state.scenario[index] |= condition.flag.mask;
    }
    try runProgram(content, &story_state, program.id);
}

test "every blocked entry remains absent from executable content" {
    var loaded = try load();
    defer loaded.deinit();
    var blocked: usize = 0;
    for (loaded.manifest.value.entries) |entry| {
        if (std.mem.eql(u8, entry.status, "compiled")) continue;
        blocked += 1;
        for (loaded.contents) |content| try std.testing.expect(content.program(entry.program_id) == null);
    }
    try std.testing.expectEqual(@as(usize, 3709), blocked);
}

test "manifest retains source ordering and population gaps" {
    var loaded = try load();
    defer loaded.deinit();
    for (loaded.manifest.value.entries[1..], 1..) |entry, index| {
        const earlier = loaded.manifest.value.entries[index - 1];
        const order = std.mem.order(u8, earlier.source_file, entry.source_file);
        try std.testing.expect(order != .gt);
        if (order != .eq) continue;
        try std.testing.expect(earlier.room <= entry.room);
        if (earlier.room != entry.room) continue;
        try std.testing.expect(earlier.entity <= entry.entity);
    }
    try std.testing.expectEqual(@as(usize, 5), loaded.manifest.value.population_gaps.len);
    for (loaded.manifest.value.population_gaps) |gap| try std.testing.expect(gap.reason.len != 0);
}

test "host-bound claims are not inferred from compilation" {
    var loaded = try load();
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u16, 0), loaded.manifest.value.coverage.host_bound_programs);
    for (loaded.manifest.value.entries) |entry| {
        if (std.mem.eql(u8, entry.status, "compiled")) {
            try std.testing.expectEqualStrings("compiled_not_host_bound", entry.runtime_state);
        }
    }
}

test "a stale content reference is rejected" {
    var loaded = try load();
    defer loaded.deinit();
    const entries = try allocator.dupe(story.Entry, loaded.manifest.value.entries);
    defer allocator.free(entries);
    for (entries) |*entry| {
        if (!std.mem.eql(u8, entry.status, "compiled")) continue;
        entry.content_id = "missing";
        break;
    }
    var bad = loaded.manifest.value;
    bad.entries = entries;
    try std.testing.expectError(error.MissingStoryContent, story.validateContents(bad, loaded.contents));
}
