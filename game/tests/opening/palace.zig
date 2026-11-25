const std = @import("std");
const events = @import("event_runtime");
const routes = @import("opening_routes");
const data = @import("opening_assets").palace_routes;

const allocator = std.testing.allocator;
const bytes = [4][]const u8{ data.room0_json, data.room1_json, data.room2_json, data.room10_json };

const Loaded = struct {
    parsed: [4]std.json.Parsed(events.Content),
    manifest: std.json.Parsed(routes.Manifest),
    contents: [4]events.Content,

    fn deinit(self: *Loaded) void {
        for (&self.parsed) |*content| content.deinit();
        self.manifest.deinit();
    }
};

fn load() !Loaded {
    var result: Loaded = undefined;
    var count: usize = 0;
    errdefer for (0..count) |index| result.parsed[index].deinit();
    for (bytes, 0..) |raw, index| {
        result.parsed[index] = try std.json.parseFromSlice(events.Content, allocator, raw, .{ .allocate = .alloc_always });
        count += 1;
        try result.parsed[index].value.validate();
        result.contents[index] = result.parsed[index].value;
    }
    result.manifest = try routes.loadManifest(allocator, data.manifest_json);
    return result;
}

const Case = struct {
    content: usize,
    program: []const u8,
    destination: []const u8,
    x: i32,
    y: i32,
};

fn expectTransition(contents: [4]events.Content, case: Case) !void {
    var story = try events.StoryState.init(&contents);
    const content = contents[case.content];
    var instance = try events.start(content, &story, case.program);
    const completion_ids = [_][]const u8{"dialogue_flags"};
    for (0..8) |_| {
        const result = try events.step(content, &instance, &story, .{ .completions = &completion_ids });
        const pending = result.batch orelse continue;
        var found = false;
        for (pending.slice()) |effect| {
            if (effect.kind != .room_transition) continue;
            found = true;
            try std.testing.expectEqualStrings(case.destination, effect.destination.?);
            try std.testing.expectEqual(case.x, effect.x.?);
            try std.testing.expectEqual(case.y, effect.y.?);
        }
        try events.acknowledge(content, &instance, &story, pending.id);
        if (found) {
            try std.testing.expect(!instance.execution.active);
            try std.testing.expect(std.mem.allEqual(u8, &story.scenario, 0));
            return;
        }
    }
    return error.MissingCompiledTransition;
}

test "generated identities and all eight programs validate" {
    var raw_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data.manifest_json, &raw_digest, .{});
    const actual = std.fmt.bytesToHex(raw_digest, .lower);
    try std.testing.expectEqualStrings(data.manifest_sha256, &actual);
    var loaded = try load();
    defer loaded.deinit();
    try routes.validate(loaded.contents, loaded.manifest.value);
}

test "audience-room exits preserve both source destinations" {
    var loaded = try load();
    defer loaded.deinit();
    try expectTransition(loaded.contents, .{ .content = 2, .program = "vaa_r02_e00_exit", .destination = "vaa_room_1", .x = 40, .y = 128 });
    try expectTransition(loaded.contents, .{ .content = 2, .program = "vaa_r02_e01_exit", .destination = "vaa_room_3", .x = 32, .y = 432 });
}

test "room-one return and room-zero onward exit use real VM batches" {
    var loaded = try load();
    defer loaded.deinit();
    try expectTransition(loaded.contents, .{ .content = 1, .program = "vaa_r01_e00_exit", .destination = "vaa_room_2", .x = 472, .y = 192 });
    try expectTransition(loaded.contents, .{ .content = 0, .program = "vaa_r00_e15_exit", .destination = "vaa_room_10", .x = 184, .y = 56 });
}

test "room-ten exits include the source VA1 handoff" {
    var loaded = try load();
    defer loaded.deinit();
    try expectTransition(loaded.contents, .{ .content = 3, .program = "vaa_r10_e00_exit", .destination = "vaa_room_0", .x = 312, .y = 736 });
    try expectTransition(loaded.contents, .{ .content = 3, .program = "vaa_r10_e01_exit", .destination = "va1_room_0", .x = 808, .y = 56 });
}

test "unsupported bulk-load programs remain suppressed" {
    var loaded = try load();
    defer loaded.deinit();
    try routes.validateManifest(loaded.manifest.value);
    for (loaded.manifest.value.gaps) |gap| {
        try std.testing.expect(!gap.executable);
        try std.testing.expect(gap.complete_program_suppressed);
        for (loaded.contents) |content| try std.testing.expect(content.program(gap.program_id) == null);
    }
}

test "stale coverage and blocked-program substitution fail closed" {
    var loaded = try load();
    defer loaded.deinit();
    var bad = loaded.manifest.value;
    bad.coverage.compiled_programs = 7;
    try std.testing.expectError(error.InvalidRouteCoverage, routes.validateManifest(bad));
    try routes.validate(loaded.contents, loaded.manifest.value);
}

test "source fade holds the onward suffix and survives an active checkpoint" {
    const fade = @import("palace_fade");
    var loaded = try load();
    defer loaded.deinit();
    const content = loaded.contents[1];
    var story = try events.StoryState.init(&loaded.contents);
    var instance = try events.start(content, &story, "vaa_r01_e01_exit");
    var overlay: fade.State = .{};
    var delay: u16 = 0;
    var first_cue: ?usize = null;
    var transitioned = false;
    for (0..120) |frame| {
        var completed: [3][]const u8 = undefined;
        var count: usize = 0;
        completed[count] = "dialogue_flags";
        count += 1;
        if (!overlay.active) {
            completed[count] = "fade";
            count += 1;
        }
        if (delay == 0) {
            completed[count] = "delay";
            count += 1;
        }
        const result = try events.step(content, &instance, &story, .{ .completions = completed[0..count] });
        if (result.batch) |batch| {
            for (batch.slice()) |effect| switch (effect.kind) {
                .fade_out => try overlay.request(),
                .cue => if (first_cue == null) {
                    first_cue = frame;
                },
                .delay => delay = effect.updates.?,
                .room_transition => {
                    try std.testing.expect(!overlay.active);
                    try std.testing.expectEqualStrings("vaa_room_0", effect.destination.?);
                    transitioned = true;
                },
                else => return error.UnexpectedSourceRouteEffect,
            };
            try events.acknowledge(content, &instance, &story, batch.id);
        }
        _ = try overlay.tick();
        if (delay != 0) delay -= 1;
        if (frame == 12) {
            const Saved = struct { vm: events.Instance, fade: fade.State };
            const bytes_saved = try std.json.Stringify.valueAlloc(allocator, Saved{ .vm = instance, .fade = overlay }, .{});
            defer allocator.free(bytes_saved);
            const parsed = try std.json.parseFromSlice(Saved, allocator, bytes_saved, .{ .allocate = .alloc_always });
            defer parsed.deinit();
            try parsed.value.vm.validate(content);
            try parsed.value.fade.validate();
            // Rebind borrowed VM identities to immutable content, as the live host restore does.
            instance = parsed.value.vm;
            instance.schema = events.state_schema;
            instance.content_id = content.id;
            instance.content_sha256 = content.content_sha256;
            instance.program_id = "vaa_r01_e01_exit";
            if (instance.execution.wait) |*wait| wait.id = "fade";
            overlay = parsed.value.fade;
        }
        if (transitioned) break;
    }
    try std.testing.expectEqual(@as(?usize, 31), first_cue);
    try std.testing.expect(transitioned);
    const legacy = try std.json.Stringify.valueAlloc(allocator, overlay, .{});
    defer allocator.free(legacy);
    try std.testing.expect(std.mem.indexOf(u8, legacy, "direction") == null);
    const fade_script: events.Content = .{ .schema = events.fade_in_schema, .id = "krin_fade", .content_sha256 = "0000000000000000000000000000000000000000000000000000000000000000", .programs = &.{.{ .id = "krin_fade", .entry = .ordinary, .entity = 5, .trigger = .none, .commands = &.{
        .{ .kind = .fade_in, .wait = .{ .kind = .fade, .id = "fade" } }, .{ .kind = .end_stream },
    } }} };
    var fade_story = try events.StoryState.init(&.{fade_script});
    var fade_instance = try events.start(fade_script, &fade_story, "krin_fade");
    const fade_batch = (try events.step(fade_script, &fade_instance, &fade_story, .{})).batch.?;
    try std.testing.expectEqual(.fade_in, fade_batch.effects[0].kind);
    try overlay.requestIn();
    try events.acknowledge(fade_script, &fade_instance, &fade_story, fade_batch.id);
    try std.testing.expectError(error.FadeAlreadyActive, overlay.request());
    for (0..31) |frame| {
        try std.testing.expectEqual(.waiting, (try events.step(fade_script, &fade_instance, &fade_story, .{})).status);
        const completed = try overlay.tick();
        try std.testing.expectEqual(frame == 30, completed);
        if (frame == 0) try std.testing.expectEqual(@as(u8, 247), overlay.level);
        if (frame == 29) try std.testing.expectEqual(@as(u8, 15), overlay.level);
        if (frame == 12) {
            const wire = try overlay.toWire();
            try std.testing.expectEqual(@as(u8, 2), wire.schema);
            overlay = try fade.State.fromWire(wire);
            var forged = wire;
            forged.schema = 1;
            try std.testing.expectError(error.InvalidFadeState, fade.State.fromWire(forged));
        }
    }
    try std.testing.expect(!overlay.enabled and !overlay.active and overlay.level == 0);
    try std.testing.expect(overlay.overlay() == null);
    const suffix = (try events.step(fade_script, &fade_instance, &fade_story, .{ .completions = &.{"fade"} })).batch.?;
    try std.testing.expectEqual(.end_stream, suffix.effects[0].kind);
    try events.acknowledge(fade_script, &fade_instance, &fade_story, suffix.id);
}

test "entry callbacks own frames until source handoff, including title hold and restart" {
    const fade = @import("palace_fade");
    var plain: fade.Entry = .{ .title_hold = false };
    try plain.tick(false);
    try std.testing.expectEqual(@as(u8, 255), plain.level);
    try std.testing.expect(!plain.ordinaryReady());
    for (0..15) |_| try plain.tick(false);
    try std.testing.expectEqual(@as(u8, 15), plain.level);
    try std.testing.expect(!plain.ordinaryReady());
    try plain.tick(false);
    try std.testing.expect(plain.ordinaryReady());
    try std.testing.expect(plain.overlay() == null);
    try plain.tick(false);
    try std.testing.expectEqual(.ordinary, plain.phase);
    var held: fade.Entry = .{ .title_hold = true };
    try held.tick(false);
    for (0..39) |_| try held.tick(false);
    try std.testing.expectEqual(@as(u8, 255), held.level);
    const bytes_saved = try std.json.Stringify.valueAlloc(allocator, held, .{});
    defer allocator.free(bytes_saved);
    const decoded = try std.json.parseFromSlice(fade.Entry, allocator, bytes_saved, .{});
    defer decoded.deinit();
    var resumed = decoded.value;
    try held.tick(false);
    try resumed.tick(false);
    try std.testing.expectEqualDeep(held, resumed);
    try std.testing.expectEqual(@as(u8, 239), held.level);
    var skipped: fade.Entry = .{ .title_hold = true };
    try skipped.tick(false);
    try skipped.tick(true);
    try std.testing.expectEqual(@as(u8, 40), skipped.held);
    try std.testing.expectEqual(@as(u8, 239), skipped.level);
    held.level = 16;
    try std.testing.expectError(error.InvalidEntryFade, held.validate());
}
