const std = @import("std");
const events = @import("event_runtime");
const town = @import("opening_town");
const data = @import("opening_assets").first_town;
const draw = @import("draw_record_queue");

const allocator = std.testing.allocator;
const raw_contents = data.content_json;
const content_count = raw_contents.len;

const Loaded = struct {
    parsed: [content_count]std.json.Parsed(events.Content),
    manifest: std.json.Parsed(town.Manifest),
    contents: [content_count]events.Content,

    fn deinit(self: *Loaded) void {
        for (&self.parsed) |*content| content.deinit();
        self.manifest.deinit();
    }
};

fn load() !Loaded {
    var result: Loaded = undefined;
    var count: usize = 0;
    errdefer for (0..count) |index| result.parsed[index].deinit();
    for (raw_contents, 0..) |raw, index| {
        result.parsed[index] = try std.json.parseFromSlice(events.Content, allocator, raw, .{ .allocate = .alloc_always });
        count += 1;
        try result.parsed[index].value.validate();
        result.contents[index] = result.parsed[index].value;
    }
    result.manifest = try town.loadManifest(allocator, data.manifest_json);
    return result;
}

fn contentFor(loaded: *const Loaded, id: []const u8) !events.Content {
    for (loaded.contents) |content| {
        if (std.mem.eql(u8, content.id, id)) return content;
    }
    return error.MissingTestContent;
}

fn runProgram(content: events.Content, story: *events.StoryState, program_id: []const u8) !usize {
    var instance = try events.start(content, story, program_id);
    var queue: draw.Queue = .{};
    var record_count: usize = 0;
    var ids: [70][]const u8 = undefined;
    var base_count: usize = 0;
    for ([_][]const u8{ "box_0", "box_1", "dialogue_flags", "accept", "delay", "fade" }) |id| {
        ids[base_count] = id;
        base_count += 1;
    }
    for (content.texts) |text| {
        ids[base_count] = text.id;
        base_count += 1;
    }
    for (0..256) |_| {
        var count = base_count;
        if (queue.empty()) {
            ids[count] = "text_queue";
            count += 1;
        }
        const result = try events.step(content, &instance, story, .{ .completions = ids[0..count], .confirm = true });
        if (result.batch) |batch| {
            for (batch.slice()) |effect| {
                if (effect.kind == .queue_draw_record) {
                    try queue.enqueue(effect);
                    record_count += 1;
                }
            }
            try events.acknowledge(content, &instance, story, batch.id);
        }
        var index: usize = 0;
        while (index < queue.count) {
            const effect = (try queue.consume(index, false)) orelse {
                index += 1;
                continue;
            };
            if (effect.kind != .finish) index += 1;
        }
        if (!instance.execution.active and instance.pending == null) {
            if (!queue.empty()) return error.ProgramCompletedWithDrawRecords;
            return record_count;
        }
    }
    return error.ProgramDidNotComplete;
}

fn programFor(loaded: *const Loaded, id: []const u8) !struct { content: events.Content, program: events.Program } {
    for (loaded.contents) |content| {
        if (content.program(id)) |program| return .{ .content = content, .program = program };
    }
    return error.MissingTestProgram;
}

test "manifest identity and all 27 content bundles validate" {
    var raw_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data.manifest_json, &raw_digest, .{});
    const actual = std.fmt.bytesToHex(raw_digest, .lower);
    try std.testing.expectEqualStrings(data.manifest_sha256, &actual);
    var loaded = try load();
    defer loaded.deinit();
    try town.validateContents(loaded.manifest.value, &loaded.contents);
}

test "ordinary source dialogue completes through the shared VM" {
    var loaded = try load();
    defer loaded.deinit();
    const content = try contentFor(&loaded, "va1_room0_dialogue_4");
    var story = try events.StoryState.init(&loaded.contents);
    _ = try runProgram(content, &story, "va1_r00_e27_ordinary");
    const text = content.text("va1_r00_text_0") orelse return error.MissingSourceText;
    try std.testing.expect(text.tokens.len != 0);
}

test "a source story guard rejects and then admits the same program" {
    var loaded = try load();
    defer loaded.deinit();
    var story = try events.StoryState.init(&loaded.contents);
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
    try std.testing.expectError(error.EventConditionFalse, events.start(content, &story, program.id));
    for (program.conditions) |condition| {
        const index = std.fmt.parseInt(u8, condition.flag.id[9..], 10) catch unreachable;
        if (condition.kind == .story_mask_set) story.scenario[index] |= condition.flag.mask;
    }
    _ = try runProgram(content, &story, program.id);
}

test "source story writes remain in the expanded dialogue family" {
    var loaded = try load();
    defer loaded.deinit();
    var writes: usize = 0;
    for (loaded.contents) |content| {
        for (content.programs) |program| {
            for (program.commands) |command| {
                if (command.kind == .story_or) writes += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 32), writes);
}

test "blocked entries never appear in executable content" {
    var loaded = try load();
    defer loaded.deinit();
    var blocked: usize = 0;
    for (loaded.manifest.value.entries) |entry| {
        if (std.mem.eql(u8, entry.status, "compiled")) continue;
        blocked += 1;
        try std.testing.expect(!entry.executable);
        try std.testing.expect(entry.complete_program_suppressed.?);
        for (loaded.contents) |content| try std.testing.expect(content.program(entry.program_id) == null);
    }
    try std.testing.expectEqual(@as(usize, 0), blocked);
}

test "all six K1 programs execute and drain fifteen source draw records" {
    const program_ids = [_][]const u8{
        "va1_r00_e30_ordinary", "va1_r00_e33_ordinary", "va1_r00_e38_ordinary",
        "va1_r00_e42_ordinary", "va1_r03_e05_ordinary", "va1_r05_e01_ordinary",
    };
    var loaded = try load();
    defer loaded.deinit();
    var total_records: usize = 0;
    for (program_ids) |id| {
        const selected = try programFor(&loaded, id);
        var story = try events.StoryState.init(&loaded.contents);
        for (selected.program.conditions) |condition| {
            const index = std.fmt.parseInt(u8, condition.flag.id[9..], 10) catch unreachable;
            if (condition.kind == .story_mask_set) {
                story.scenario[index] |= condition.flag.mask;
            } else {
                story.scenario[index] &= ~condition.flag.mask;
            }
        }
        const records = try runProgram(selected.content, &story, id);
        try std.testing.expect(records != 0);
        total_records += records;
    }
    try std.testing.expectEqual(@as(usize, 15), total_records);
}

test "typed 0x32 command preserves source selector bytes countdown and flags" {
    var loaded = try load();
    defer loaded.deinit();
    const selected = try programFor(&loaded, "va1_r00_e30_ordinary");
    const command = for (selected.program.commands) |command| {
        if (command.kind == .queue_draw_record) break command;
    } else return error.MissingDrawRecordCommand;
    try std.testing.expectEqual(@as(?u8, 0x80), command.selector);
    try std.testing.expectEqualSlices(u8, &.{ 4, 4, 2, 28, 5 }, command.glyph_bytes.?);
    try std.testing.expectEqual(@as(?u8, 0), command.countdown);
    try std.testing.expectEqual(@as(?u8, 0), command.flags);
}

test "draw record host consumes countdown motion advance height and finish in order" {
    const bytes = [_]u8{ 2, 2, 6, 0, 4, 3, 7, 2, 5 };
    const command: events.Command = .{
        .kind = .queue_draw_record,
        .selector = 0x80,
        .glyph_bytes = &bytes,
        .countdown = 0,
        .flags = 0x40,
    };
    var queue: draw.Queue = .{};
    try queue.enqueue(command);
    try std.testing.expectEqualSlices(u8, &bytes, queue.records[0].?.glyph_bytes);
    try std.testing.expectEqual(@as(u8, 0), queue.records[0].?.countdown);
    try std.testing.expectEqual(@as(u8, 0x40), queue.records[0].?.flags);
    try std.testing.expectEqual(@as(?draw.Effect, null), try queue.consume(0, true));
    try std.testing.expectEqual(@as(u16, 0), queue.records[0].?.cursor);

    const expected = [_]draw.Effect{
        .{ .kind = .move, .selector = 0x80, .flags = 0x40, .direction = .down },
        .{ .kind = .move, .selector = 0x80, .flags = 0x40, .direction = .down },
        .{ .kind = .clear_height, .selector = 0x80, .flags = 0x40 },
        .{ .kind = .set_motion, .selector = 0x80, .flags = 0x40, .motion = 3 },
        .{ .kind = .advance, .selector = 0x80, .flags = 0x40, .direction = .up },
        .{ .kind = .advance, .selector = 0x80, .flags = 0x40, .direction = .up },
        .{ .kind = .finish, .selector = 0x80, .flags = 0x40 },
    };
    for (expected) |wanted| {
        const actual = (try queue.consume(0, false)).?;
        try std.testing.expectEqual(wanted, actual);
    }
    try std.testing.expect(queue.empty());
}

test "draw record host rejects malformed input and capacity overflow" {
    const bytes = [_]u8{ 0, 1, 5 };
    const command: events.Command = .{
        .kind = .queue_draw_record,
        .selector = 1,
        .glyph_bytes = &bytes,
        .countdown = 0,
        .flags = 0,
    };
    var queue: draw.Queue = .{};
    var invalid = command;
    invalid.glyph_bytes = &.{ 8, 1, 5 };
    try std.testing.expectError(error.InvalidDrawRecordCommand, queue.enqueue(invalid));
    invalid.glyph_bytes = &.{ 0, 1 };
    try std.testing.expectError(error.InvalidDrawRecordCommand, queue.enqueue(invalid));
    invalid.selector = null;
    invalid.glyph_bytes = &bytes;
    try std.testing.expectError(error.InvalidDrawRecordCommand, queue.enqueue(invalid));
    for (0..draw.max_records) |_| try queue.enqueue(command);
    try std.testing.expectError(error.DrawRecordQueueFull, queue.enqueue(command));
}

test "population gap remains attached to source room twelve" {
    var loaded = try load();
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.manifest.value.population_gaps.len);
    try std.testing.expectEqual(@as(u8, 12), loaded.manifest.value.population_gaps[0].room);
}

test "a stale compiled reference is rejected" {
    var loaded = try load();
    defer loaded.deinit();
    const entries = try allocator.dupe(town.Entry, loaded.manifest.value.entries);
    defer allocator.free(entries);
    for (entries) |*entry| {
        if (!std.mem.eql(u8, entry.status, "compiled")) continue;
        entry.content_id = "missing";
        break;
    }
    var bad = loaded.manifest.value;
    bad.entries = entries;
    try std.testing.expectError(error.MissingTownContent, town.validateContents(bad, &loaded.contents));
}
