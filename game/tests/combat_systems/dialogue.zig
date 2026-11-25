//! Focused port gate: the source text engine, the speaker/name/image
//! variants, the two-option choice and the scene host's production/consumption
//! order.
//!
//! The expected page plans come from the generator (the extraction pipeline),
//! which derives them with a second implementation from the disc bytes. The
//! tests below are independent hosts: they do not execute original instructions,
//! an emulator or a legacy CPU fixture.

const std = @import("std");
const dialogue_mod = @import("combat_systems").dialogue;
const data = @import("combat_systems_data").pipeline;

const model = dialogue_mod.model;
const text = dialogue_mod.text;
const host = dialogue_mod.host;

const allocator = std.testing.allocator;

fn load() !std.json.Parsed(model.Pipeline) {
    return dialogue_mod.load(allocator);
}

fn assetSha() [32]u8 {
    var sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data.json, &sha, .{});
    return sha;
}

fn encode(comptime value: []const u8, buffer: []u8) ![]const u8 {
    return text.encodeAscii(value, buffer);
}

fn pageInto(page: []const []const u8, out: []u8) []const u8 {
    var at: usize = 0;
    for (page, 0..) |line, index| {
        if (index != 0) {
            out[at] = '\n';
            at += 1;
        }
        @memcpy(out[at..][0..line.len], line);
        at += line.len;
    }
    return out[0..at];
}

fn expectPage(engine: *const text.Engine, page: []const []const u8) !void {
    var expected: [256]u8 = undefined;
    var visible: [text.max_visible]u8 = undefined;
    try std.testing.expectEqualStrings(pageInto(page, &expected), engine.writeVisible(&visible));
}

// --- asset contract ---------------------------------------------------------

test "the packet is the reviewed source shape" {
    var parsed = try load();
    defer parsed.deinit();
    const pipeline = &parsed.value;
    try std.testing.expectEqualStrings("suikoden-dialogue-pipeline/1", pipeline.schema);
    try std.testing.expectEqual(@as(usize, 7), pipeline.scenes.len);
    try std.testing.expectEqual(@as(usize, 16), pipeline.controls.len);
    try std.testing.expectEqual(@as(usize, 123), pipeline.names.characters.len);
    try std.testing.expectEqual(@as(usize, 125), pipeline.names.pool.len);
    try std.testing.expectEqual(@as(usize, 4), pipeline.corpus_corrections.len);
    try std.testing.expectEqual(@as(u16, 139), pipeline.asserted_instructions);
    try std.testing.expectEqual(@as(u16, 0x5041), pipeline.choices.mask);
    try std.testing.expectEqual(@as(u8, 30), pipeline.choices.duration);
    try std.testing.expectEqual(@as(u8, 20), pipeline.box.open_close_duration);
}

test "pacing rows and the boot-selected normal row" {
    var parsed = try load();
    defer parsed.deinit();
    const pacing = parsed.value.pacing;
    try std.testing.expectEqual(@as(u8, 1), pacing.default_setting);
    try std.testing.expectEqual(@as(u8, 3), pacing.default_normal);
    try std.testing.expectEqual(@as(u8, 1), pacing.default_pressed);
    try std.testing.expectEqual(@as(u8, 1), pacing.rows[0].normal);
    try std.testing.expectEqual(@as(u8, 0), pacing.rows[0].pressed);
    try std.testing.expectEqual(@as(u8, 3), pacing.rows[1].normal);
    try std.testing.expectEqual(@as(u8, 1), pacing.rows[1].pressed);
    try std.testing.expectEqual(@as(u8, 5), pacing.rows[2].normal);
    try std.testing.expectEqual(@as(u8, 2), pacing.rows[2].pressed);
}

test "character codes, name indices and portrait indices stay separate" {
    var parsed = try load();
    defer parsed.deinit();
    const pipeline = &parsed.value;
    try std.testing.expectEqual(@as(u8, 1), (try pipeline.nameIndex(2)).?);
    try std.testing.expectEqual(@as(u8, 23), (try pipeline.nameIndex(4)).?);
    try std.testing.expectEqual(@as(u8, 4), (try pipeline.nameIndex(35)).?);
    try std.testing.expectEqual(@as(u8, 110), (try pipeline.nameIndex(110)).?);
    try std.testing.expectEqual(@as(u8, 111), (try pipeline.nameIndex(111)).?);
    try std.testing.expectEqual(@as(u8, 119), (try pipeline.nameIndex(119)).?);
    try std.testing.expectEqual(@as(?u8, null), try pipeline.nameIndex(8));
    try std.testing.expectEqual(@as(?u8, null), try pipeline.nameIndex(125));
    try std.testing.expectError(error.NullSpeakerCode, pipeline.nameIndex(0));
    try std.testing.expectEqualStrings("Kirkis", (try pipeline.nameForCode(4)).?);
    try std.testing.expectEqualStrings("Viktor", (try pipeline.nameForCode(35)).?);
    try std.testing.expectEqualStrings("Gremio", (try pipeline.nameForCode(2)).?);
    try std.testing.expectEqualStrings("Teo", (try pipeline.nameForCode(110)).?);
    // The direct-rank trap: code 8 is Sydonia's name index but Hero's code.
    try std.testing.expectEqualStrings("Sydonia", pipeline.names.pool[7].name);
}

test "speaker variants carry the source prefix count" {
    var parsed = try load();
    defer parsed.deinit();
    const pipeline = &parsed.value;
    try std.testing.expectEqual(@as(u8, 7), pipeline.variant(4).?.prefix_updates);
    try std.testing.expectEqual(@as(u8, 7), pipeline.variant(2).?.prefix_updates);
    try std.testing.expectEqual(@as(u8, 4), pipeline.variant(110).?.prefix_updates);
    try std.testing.expectEqual(@as(u8, 9), pipeline.variant(119).?.prefix_updates);
    try std.testing.expect(pipeline.variant(8).?.skip_name);
    try std.testing.expect(pipeline.variant(125).?.skip_name);
}

test "every text hash and page plan is self-consistent" {
    var parsed = try load();
    defer parsed.deinit();
    for (parsed.value.scenes) |scene| {
        try std.testing.expect(scene.texts.len >= 1);
        for (scene.texts) |spec| {
            var decoded: [text.max_body]u8 = undefined;
            const bytes = try text.decodeHex(spec.bytes_hex, &decoded);
            try std.testing.expectEqual(@as(usize, spec.bytes_len), bytes.len);
            var sha: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &sha, .{});
            const hex = std.fmt.bytesToHex(sha, .lower);
            try std.testing.expectEqualStrings(spec.sha256, &hex);
            try std.testing.expect(spec.pages.len >= 1);
            for (spec.pages) |page| {
                for (page) |line| try std.testing.expect(line.len <= 30);
            }
        }
    }
    // The reviewed VAA asset's area_text_0_12 runs 190 tokens into the next
    // strings; the bounded source body is 42 bytes.
    const choice_scene = parsed.value.scene("vaa_choice").?;
    try std.testing.expectEqual(@as(u16, 34), choice_scene.texts[0].bytes_len);
    try std.testing.expectEqual(@as(u16, 92), choice_scene.texts[1].bytes_len);
    try std.testing.expectEqual(@as(u16, 42), choice_scene.texts[2].bytes_len);
}

// --- engine: cadence, reveal, paging ---------------------------------------

test "the first glyph follows the staging update and pace+1 cadence" {
    var parsed = try load();
    defer parsed.deinit();
    var body_buffer: [8]u8 = undefined;
    var engine: text.Engine = .{};
    const body = try encode("AB", &body_buffer);
    try engine.begin(body, 3, 1);
    var visible: [text.max_visible]u8 = undefined;
    try engine.tick(&parsed.value, .{});
    try std.testing.expectEqualStrings("A", engine.writeVisible(&visible));
    try engine.tick(&parsed.value, .{});
    try engine.tick(&parsed.value, .{});
    try engine.tick(&parsed.value, .{});
    try std.testing.expectEqualStrings("A", engine.writeVisible(&visible));
    try engine.tick(&parsed.value, .{});
    try std.testing.expectEqualStrings("AB", engine.writeVisible(&visible));
    try std.testing.expect(engine.done);
}

test "a reveal press runs one unlimited pass on the next tick" {
    var parsed = try load();
    defer parsed.deinit();
    var body_buffer: [8]u8 = undefined;
    var engine: text.Engine = .{};
    try engine.begin(try encode("ABCD", &body_buffer), 3, 1);
    var visible: [text.max_visible]u8 = undefined;
    try engine.tick(&parsed.value, .{});
    try std.testing.expectEqualStrings("A", engine.writeVisible(&visible));
    try std.testing.expectEqual(text.Ack.accelerate, engine.acknowledge(&parsed.value, 0x40));
    try std.testing.expect(engine.fast);
    try std.testing.expectEqualStrings("A", engine.writeVisible(&visible)); // no glyph on the ack frame
    try engine.tick(&parsed.value, .{});
    try std.testing.expectEqualStrings("ABCD", engine.writeVisible(&visible));
    try std.testing.expect(engine.done);
}

test "page wait clears the grid, retains the cursor and needs a mask" {
    var parsed = try load();
    defer parsed.deinit();
    var body_buffer: [16]u8 = undefined;
    var engine: text.Engine = .{};
    try engine.begin(try encode("AB", &body_buffer), 3, 1);
    // Replace the body so the page control follows the two glyphs.
    var page_body: [5]u8 = .{ 0x2B, 0x2C, 0x02, 0x2D, 0x2E };
    try engine.begin(&page_body, 3, 1);
    var visible: [text.max_visible]u8 = undefined;
    try engine.tick(&parsed.value, .{});
    try std.testing.expectEqualStrings("A", engine.writeVisible(&visible));
    engine.fast = true;
    try engine.tick(&parsed.value, .{});
    try std.testing.expectEqualStrings("AB", engine.writeVisible(&visible));
    try std.testing.expect(engine.page_wait);
    const cursor_before = engine.cursor;
    try std.testing.expectEqual(text.Ack.none, engine.acknowledge(&parsed.value, 0));
    try std.testing.expect(engine.page_wait);
    try std.testing.expectEqual(@as(u8, 0), engine.page_index);
    try std.testing.expectEqual(text.Ack.page, engine.acknowledge(&parsed.value, 0x40));
    try std.testing.expect(!engine.page_wait);
    try std.testing.expectEqual(@as(u8, 1), engine.page_index);
    try std.testing.expectEqual(cursor_before, engine.cursor);
    try std.testing.expectEqualStrings("", engine.writeVisible(&visible));
    // A second acknowledgement on the same page state must not advance a page.
    _ = engine.acknowledge(&parsed.value, 0x40);
    try std.testing.expectEqual(@as(u8, 1), engine.page_index);
    engine.fast = true;
    try engine.tick(&parsed.value, .{});
    try std.testing.expectEqualStrings("CD", engine.writeVisible(&visible));
    try std.testing.expect(engine.done);
}

test "repeated confirmation cannot skip a page" {
    var parsed = try load();
    defer parsed.deinit();
    var body: [7]u8 = .{ 0x11, 0x12, 0x02, 0x13, 0x02, 0x14, 0x15 };
    var engine: text.Engine = .{};
    try engine.begin(&body, 3, 1);
    engine.fast = true;
    try engine.tick(&parsed.value, .{});
    try std.testing.expectEqual(@as(u8, 0), engine.page_index);
    try std.testing.expect(engine.page_wait);
    try std.testing.expectEqual(text.Ack.page, engine.acknowledge(&parsed.value, 0x40));
    try std.testing.expectEqual(@as(u8, 1), engine.page_index);
    // The still-held button is a new acknowledgement on the next frame, but it
    // only requests a reveal; it cannot consume page 1 before it is drawn.
    _ = engine.acknowledge(&parsed.value, 0x40);
    try std.testing.expectEqual(@as(u8, 1), engine.page_index);
    try std.testing.expect(!engine.page_wait);
    engine.fast = true;
    try engine.tick(&parsed.value, .{});
    try std.testing.expect(engine.page_wait);
    try std.testing.expectEqual(@as(u8, 1), engine.page_index);
    try std.testing.expectEqual(text.Ack.page, engine.acknowledge(&parsed.value, 0x40));
    try std.testing.expectEqual(@as(u8, 2), engine.page_index);
}

// --- engine: substitutions and controls ------------------------------------

test "nested selector 0 is the player name and selector 1 the castle name" {
    var parsed = try load();
    defer parsed.deinit();
    var body: [10]u8 = .{ 0x32, 0x19, 0x10, 0x06, 0x00, 0x10, 0x06, 0x01, 0x57, 0x00 };
    var player_buffer: [8]u8 = undefined;
    var castle_buffer: [8]u8 = undefined;
    var engine: text.Engine = .{};
    try engine.begin(&body, 3, 1);
    engine.fast = true;
    try engine.tick(&parsed.value, .{
        .player_name = try encode("Hero", &player_buffer),
        .castle_name = try encode("Toran", &castle_buffer),
    });
    var visible: [text.max_visible]u8 = undefined;
    try std.testing.expectEqualStrings("Hi Hero Toran!", engine.writeVisible(&visible));
}

test "a trailing nested selector consumes the staging sentinel" {
    var parsed = try load();
    defer parsed.deinit();
    // "Help me " + 0x06 with no explicit selector; the copied buffer's zero
    // sentinel selects the player name and then terminates.
    var body: [10]u8 = .{ 0x32, 0x15, 0x1c, 0x20, 0x10, 0x1d, 0x15, 0x10, 0x06, 0x00 };
    var player: [8]u8 = undefined;
    var engine: text.Engine = .{};
    try engine.begin(body[0..9], 3, 1);
    engine.fast = true;
    try engine.tick(&parsed.value, .{ .player_name = try encode("Hero", &player) });
    var visible: [text.max_visible]u8 = undefined;
    try std.testing.expectEqualStrings("Help me Hero", engine.writeVisible(&visible));
    try std.testing.expect(engine.done);
}

test "unsupported nested selectors and bytes are explicit" {
    var parsed = try load();
    defer parsed.deinit();
    var selector: [3]u8 = .{ 0x11, 0x06, 0x02 };
    var engine: text.Engine = .{};
    try engine.begin(&selector, 3, 1);
    engine.fast = true;
    try std.testing.expectError(error.UnsupportedSubstitution, engine.tick(&parsed.value, .{}));
    var bad_player: [1]u8 = .{0x01};
    var second: text.Engine = .{};
    try second.begin(&.{ 0x11, 0x06, 0x00 }, 3, 1);
    second.fast = true;
    try std.testing.expectError(error.UnsupportedNestedByte, second.tick(&parsed.value, .{ .player_name = &bad_player }));
}

test "number formatting is right-aligned and bounded to five cells" {
    var parsed = try load();
    defer parsed.deinit();
    const numbers = [_]u32{123};
    var body: [4]u8 = .{ 0x07, 0x00, 0x05, 0x00 };
    var engine: text.Engine = .{};
    try engine.begin(&body, 3, 1);
    engine.fast = true;
    try engine.tick(&parsed.value, .{ .numbers = &numbers });
    var visible: [text.max_visible]u8 = undefined;
    try std.testing.expectEqualStrings("  123", engine.writeVisible(&visible));

    var three: text.Engine = .{};
    try three.begin(&.{ 0x07, 0x00, 0x03 }, 3, 1);
    three.fast = true;
    try three.tick(&parsed.value, .{ .numbers = &numbers });
    try std.testing.expectEqualStrings("123", three.writeVisible(&visible));

    var one: text.Engine = .{};
    try one.begin(&.{ 0x07, 0x00, 0x01 }, 3, 1);
    one.fast = true;
    try one.tick(&parsed.value, .{ .numbers = &numbers });
    try std.testing.expectEqualStrings("3", one.writeVisible(&visible));

    var zero_value = [_]u32{0};
    var five: text.Engine = .{};
    try five.begin(&.{ 0x07, 0x00, 0x05 }, 3, 1);
    five.fast = true;
    try five.tick(&parsed.value, .{ .numbers = &zero_value });
    try std.testing.expectEqualStrings("    0", five.writeVisible(&visible));

    var wide: text.Engine = .{};
    var large = [_]u32{123456};
    try wide.begin(&.{ 0x07, 0x00, 0x05 }, 3, 1);
    wide.fast = true;
    try wide.tick(&parsed.value, .{ .numbers = &large });
    try std.testing.expectEqualStrings("23456", wide.writeVisible(&visible));

    var bad_width: text.Engine = .{};
    try bad_width.begin(&.{ 0x07, 0x00, 0x00 }, 3, 1);
    bad_width.fast = true;
    try std.testing.expectError(error.UnsupportedNumberWidth, bad_width.tick(&parsed.value, .{ .numbers = &numbers }));

    var bad_source: text.Engine = .{};
    try bad_source.begin(&.{ 0x07, 0x05, 0x05 }, 3, 1);
    bad_source.fast = true;
    try std.testing.expectError(error.UnsupportedNumberSource, bad_source.tick(&parsed.value, .{ .numbers = &numbers }));
}

test "colour and clear-grid controls affect only later cells" {
    var parsed = try load();
    defer parsed.deinit();
    var body: [5]u8 = .{ 0x08, 0x02, 0x2B, 0x2C, 0x00 };
    var engine: text.Engine = .{};
    try engine.begin(&body, 3, 1);
    engine.fast = true;
    try engine.tick(&parsed.value, .{});
    var visible: [text.max_visible]u8 = undefined;
    try std.testing.expectEqualStrings("AB", engine.writeVisible(&visible));
    try std.testing.expectEqual(@as(u8, 2), engine.grid.cells[0][0].colour);
    try std.testing.expectEqual(@as(u8, 2), engine.grid.cells[0][1].colour);

    var cleared: text.Engine = .{};
    try cleared.begin(&.{ 0x2B, 0x2C, 0x0f, 0x2D, 0x2E }, 3, 1);
    cleared.fast = true;
    try cleared.tick(&parsed.value, .{});
    try std.testing.expectEqualStrings("CD", cleared.writeVisible(&visible));
}

test "undefined glyph bytes and truncated operands are explicit" {
    var parsed = try load();
    defer parsed.deinit();
    var bad: text.Engine = .{};
    try bad.begin(&.{0x52}, 3, 1);
    bad.fast = true;
    try std.testing.expectError(error.UnsupportedControl, bad.tick(&parsed.value, .{}));

    var truncated: text.Engine = .{};
    try truncated.begin(&.{0x07}, 3, 1);
    truncated.fast = true;
    try std.testing.expectError(error.TruncatedControl, truncated.tick(&parsed.value, .{}));

    var full: [32]u8 = @splat(0x11);
    var overflow: text.Engine = .{};
    try overflow.begin(&full, 3, 1);
    overflow.fast = true;
    try std.testing.expectError(error.LineOverflow, overflow.tick(&parsed.value, .{}));
}

test "a bottom-row line break scrolls one row and keeps the newest five" {
    var parsed = try load();
    defer parsed.deinit();
    var body: [11]u8 = .{ 0x2B, 0x01, 0x2C, 0x01, 0x2D, 0x01, 0x2E, 0x01, 0x2F, 0x01, 0x30 };
    var engine: text.Engine = .{};
    try engine.begin(&body, 3, 1);
    var visible: [text.max_visible]u8 = undefined;
    for (0..12) |_| {
        engine.fast = true;
        try engine.tick(&parsed.value, .{});
        if (engine.done) break;
    }
    try std.testing.expectEqualStrings("B\nC\nD\nE\nF", engine.writeVisible(&visible));
    try std.testing.expect(engine.grid.scrolls >= 1);
}

// --- speaker, name and image variants --------------------------------------

test "speaker prefixes follow code 8 / 125 / list / direct-rank variants" {
    var parsed = try load();
    defer parsed.deinit();
    const pipeline = &parsed.value;

    var kirkis: host.Box = .{};
    kirkis.open(20);
    try kirkis.beginSpeaker(pipeline, 4, 1, .{ .custom = &.{4} });
    try std.testing.expectEqualStrings("Kirkis", kirkis.name[0..kirkis.name_len]);
    try std.testing.expectEqual(@as(u8, 2), kirkis.image_presence);
    try std.testing.expect(!kirkis.prefix_done);
    for (0..6) |_| kirkis.tickPrefix();
    try std.testing.expectEqualStrings("Kirkis", kirkis.visibleName());
    kirkis.tickPrefix();
    try std.testing.expect(kirkis.prefix_done);

    var hero: host.Box = .{};
    hero.open(20);
    try hero.beginSpeaker(pipeline, 8, 0, .{ .party = &.{8} });
    try std.testing.expectEqual(@as(u8, 0), hero.name_len);
    try std.testing.expect(hero.prefix_done);
    try std.testing.expectEqual(@as(u8, 1), hero.image_presence);

    var generic: host.Box = .{};
    generic.open(20);
    try generic.beginSpeaker(pipeline, 125, 1, .{});
    try std.testing.expectEqual(@as(u8, 0), generic.name_len);
    try std.testing.expect(generic.prefix_done);
    try std.testing.expectEqual(@as(u8, 0), generic.image_presence);

    var missing: host.Box = .{};
    missing.open(20);
    try missing.beginSpeaker(pipeline, 4, 1, .{});
    try std.testing.expectEqualStrings("Kirkis", missing.name[0..missing.name_len]);
    try std.testing.expectEqual(@as(u8, 0), missing.image_presence);

    var null_code: host.Box = .{};
    try std.testing.expectError(error.NullSpeakerCode, null_code.beginSpeaker(pipeline, 0, 0, .{}));

    var barbarosa: host.Box = .{};
    barbarosa.open(20);
    try barbarosa.beginSpeaker(pipeline, 111, 1, .{});
    try std.testing.expectEqualStrings("Barbarosa", barbarosa.name[0..barbarosa.name_len]);
    var minister: host.Box = .{};
    minister.open(20);
    try minister.beginSpeaker(pipeline, 119, 0, .{});
    try std.testing.expectEqualStrings("Minister", minister.name[0..minister.name_len]);
}

test "close clears the image presence but retains the name" {
    var parsed = try load();
    defer parsed.deinit();
    var box: host.Box = .{};
    box.open(20);
    try box.beginSpeaker(&parsed.value, 2, 0, .{ .party = &.{2} });
    try std.testing.expectEqual(@as(u8, 1), box.image_presence);
    box.close(20);
    try std.testing.expectEqual(@as(u8, 0), box.image_presence);
    try std.testing.expectEqualStrings("Gremio", box.name[0..box.name_len]);
}

// --- host order, paging and restore ---------------------------------------

const DriveResult = struct {
    frames: usize = 0,
    pages: usize = 0,
    final_text: u8 = 0,
    speaker_count: usize = 0,
    speaker_codes: [4]u8 = .{ 0, 0, 0, 0 },
    choice_count: usize = 0,
    choice_values: [2]u8 = .{ 0, 0 },
    cancel_seen: bool = false,
};

fn drive(pipeline: *const model.Pipeline, scene_index: u8, desired: u8, resources: host.Resources) !DriveResult {
    var machine = try host.Host.init(pipeline, scene_index, assetSha());
    machine.resources = resources;
    const scene = &pipeline.scenes[scene_index];
    var result = DriveResult{};
    var captured: [4][8]bool = @splat(@splat(false));
    var guard: usize = 0;
    while (guard < 900) : (guard += 1) {
        var mask: u16 = 0;
        if (machine.choice) |choice| {
            mask = if (choice.state != desired)
                (if (choice.state < desired) pipeline.choices.down else pipeline.choices.up)
            else
                0x40;
        } else {
            var active = false;
            var fast = false;
            for (machine.boxes) |box| {
                if (box.text.len > 0 and !box.text.done) {
                    active = true;
                    fast = box.text.fast;
                }
            }
            mask = if (active and fast) 0 else 0x40;
        }
        const emission = try machine.frame(pipeline, .{ .mask = mask });
        if (emission.speaker) |code| {
            if (result.speaker_count < result.speaker_codes.len) {
                result.speaker_codes[result.speaker_count] = code;
                result.speaker_count += 1;
            }
        }
        if (emission.choice) |choice| {
            if (result.choice_count < result.choice_values.len) {
                result.choice_values[result.choice_count] = choice;
                result.choice_count += 1;
            }
        }
        if (emission.cancel_ignored) result.cancel_seen = true;
        for (machine.boxes) |box| {
            if (box.text.len == 0) continue;
            const text_index = machine.active_text;
            if (box.text.page_wait and box.text.page_index < 8 and !captured[text_index][box.text.page_index]) {
                captured[text_index][box.text.page_index] = true;
                result.pages += 1;
                try expectPage(&box.text, scene.texts[text_index].pages[box.text.page_index]);
            } else if (box.text.done and box.text.page_index < 8 and !captured[text_index][box.text.page_index]) {
                captured[text_index][box.text.page_index] = true;
                result.pages += 1;
                try expectPage(&box.text, scene.texts[text_index].pages[box.text.page_index]);
            }
        }
        if (machine.finished) {
            result.frames = guard + 1;
            result.final_text = machine.active_text;
            for (machine.boxes) |box| try std.testing.expectEqual(host.Phase.closed, box.phase);
            return result;
        }
    }
    return error.SceneDidNotFinish;
}

test "six text scenes and the choice scene run through one pipeline" {
    var parsed = try load();
    defer parsed.deinit();
    const pipeline = &parsed.value;
    const resources = host.Resources{ .custom = &.{4}, .party = &.{ 2, 8 } };
    for (pipeline.scenes, 0..) |scene, scene_index| {
        const desired_runs = [_]u8{ 0, 1 };
        const run_count: usize = if (std.mem.eql(u8, scene.id, "vaa_choice")) 2 else 1;
        for (desired_runs[0..run_count]) |desired| {
            const result = try drive(pipeline, @intCast(scene_index), desired, resources);
            const expected = if (std.mem.eql(u8, scene.id, "vaa_choice"))
                scene.texts[0].pages.len + scene.texts[1 + desired].pages.len
            else
                scene.texts[0].pages.len;
            try std.testing.expectEqual(expected, result.pages);
            if (std.mem.eql(u8, scene.id, "vaa_choice")) {
                try std.testing.expectEqual(@as(u8, 8), result.speaker_codes[0]);
                try std.testing.expectEqual(@as(u8, 111), result.speaker_codes[1]);
                try std.testing.expectEqual(@as(usize, 1), result.choice_count);
                try std.testing.expectEqual(desired, result.choice_values[0]);
                try std.testing.expectEqual(@as(u8, 1 + desired), result.final_text);
            } else {
                try std.testing.expectEqual(@as(u8, 0), result.final_text);
            }
        }
    }
}

test "a staged body draws no glyph on its staging frame and gates the VM" {
    var parsed = try load();
    defer parsed.deinit();
    const pipeline = &parsed.value;
    var machine = try host.Host.init(pipeline, 0, assetSha());
    var visible: [text.max_visible]u8 = undefined;
    var staged_frame: ?usize = null;
    for (0..80) |frame| {
        _ = try machine.frame(pipeline, .{ .mask = 0 });
        if (machine.boxes[0].text.len > 0) {
            staged_frame = frame;
            try std.testing.expectEqualStrings("", machine.boxes[0].text.writeVisible(&visible));
            break;
        }
    }
    try std.testing.expect(staged_frame != null);
    const cursor_staged = machine.cursor;
    _ = try machine.frame(pipeline, .{ .mask = 0 });
    try std.testing.expectEqualStrings("W", machine.boxes[0].text.writeVisible(&visible));
    try std.testing.expectEqual(cursor_staged, machine.cursor); // wait_confirm is still ahead
    try std.testing.expect(machine.boxes[0].text.busy());
}

test "page acknowledgements never advance the script cursor" {
    var parsed = try load();
    defer parsed.deinit();
    const pipeline = &parsed.value;
    var machine = try host.Host.init(pipeline, 0, assetSha());
    var pages: [8]bool = @splat(false);
    var guard: usize = 0;
    while (guard < 200) : (guard += 1) {
        var mask: u16 = 0;
        for (machine.boxes) |box| {
            if (box.text.len > 0 and !box.text.done) {
                mask = if (box.text.fast) 0 else 0x40;
            }
        }
        const emission = try machine.frame(pipeline, .{ .mask = mask });
        if (machine.boxes[0].text.len > 0 and !machine.boxes[0].text.done) {
            try std.testing.expectEqual(@as(u16, 2), machine.cursor); // text -> wait_confirm
        }
        if (emission.page_acked) {
            try std.testing.expect(pages.len > machine.boxes[0].text.page_index - 1);
        }
        for (machine.boxes) |box| {
            if (box.text.page_wait and box.text.page_index < 8) pages[box.text.page_index] = true;
        }
        if (machine.boxes[0].text.len > 0 and machine.boxes[0].text.done) break;
    }
    try std.testing.expect(pages[0] and pages[1]);
    try std.testing.expectEqual(@as(u16, 2), machine.cursor);
}

test "mid-page restore is inert until input and then advances exactly one page" {
    var parsed = try load();
    defer parsed.deinit();
    const pipeline = &parsed.value;
    const scene_index = pipeline.sceneIndex("va1_help").?;
    var machine = try host.Host.init(pipeline, scene_index, assetSha());
    var guard: usize = 0;
    while (guard < 300) : (guard += 1) {
        const box = machine.boxes[0];
        const mask: u16 = if (box.text.len > 0 and !box.text.done and !box.text.fast) 0x40 else 0;
        _ = try machine.frame(pipeline, .{ .mask = mask });
        if (machine.boxes[0].text.page_wait and machine.boxes[0].text.page_index == 1) break;
    }
    try std.testing.expect(machine.boxes[0].text.page_wait);
    const saved = machine.snapshot();
    var restored = try host.Host.init(pipeline, scene_index, assetSha());
    try restored.restore(pipeline, saved);
    try std.testing.expectEqual(machine.cursor, restored.cursor);
    try std.testing.expectEqual(machine.boxes[0].text.page_index, restored.boxes[0].text.page_index);
    var before: [text.max_visible]u8 = undefined;
    var after: [text.max_visible]u8 = undefined;
    try std.testing.expectEqualStrings(machine.boxes[0].text.writeVisible(&before), restored.boxes[0].text.writeVisible(&after));
    _ = try restored.frame(pipeline, .{ .mask = 0 });
    try std.testing.expect(restored.boxes[0].text.page_wait);
    try std.testing.expectEqual(@as(u8, 1), restored.boxes[0].text.page_index);
    const acknowledged = try restored.frame(pipeline, .{ .mask = 0x40 });
    try std.testing.expect(acknowledged.page_acked);
    try std.testing.expectEqual(@as(u8, 2), restored.boxes[0].text.page_index);
    try std.testing.expectEqualStrings("", restored.boxes[0].text.writeVisible(&after));

    var bad_sha = saved;
    bad_sha.content_sha[0] ^= 0xFF;
    try std.testing.expectError(error.ContentMismatch, restored.restore(pipeline, bad_sha));

    var bad_page = saved;
    bad_page.boxes[0].text.page_index = 200;
    try std.testing.expectError(error.InvalidSnapshot, restored.restore(pipeline, bad_page));

    var bad_cursor = saved;
    bad_cursor.boxes[0].text.cursor = bad_cursor.boxes[0].text.len + 1;
    try std.testing.expectError(error.InvalidSnapshot, restored.restore(pipeline, bad_cursor));

    var bad_choice = saved;
    bad_choice.choice = host.ChoiceState.start(0, 2, 30);
    bad_choice.choice.?.state = 2;
    try std.testing.expectError(error.InvalidSnapshot, restored.restore(pipeline, bad_choice));
}

test "close starts a 20-update transition and wait_boxes owns the gate" {
    var parsed = try load();
    defer parsed.deinit();
    const pipeline = &parsed.value;
    var machine = try host.Host.init(pipeline, 0, assetSha());
    var closing_frame: ?usize = null;
    for (0..200) |frame| {
        _ = try machine.frame(pipeline, .{ .mask = 0x40 });
        if (machine.boxes[0].phase == .closing) {
            closing_frame = frame;
            break;
        }
    }
    try std.testing.expect(closing_frame != null);
    var closed_after: usize = 0;
    while (machine.boxes[0].phase != .closed and closed_after < 40) : (closed_after += 1) {
        try std.testing.expectEqual(@as(u16, 4), machine.cursor); // close_box -> wait_boxes
        _ = try machine.frame(pipeline, .{ .mask = 0x40 });
    }
    try std.testing.expectEqual(host.Phase.closed, machine.boxes[0].phase);
    try std.testing.expect(closed_after >= 20);
    // The next frame advances wait_boxes, then finish closes the scene.
    _ = try machine.frame(pipeline, .{ .mask = 0x40 });
    try std.testing.expectEqual(@as(u16, 5), machine.cursor);
}

// --- choices ---------------------------------------------------------------

test "choice interpolation is the source 30-update formula" {
    try std.testing.expectEqual(@as(u8, 0), host.interpolate(0, 240, 30, 30));
    try std.testing.expectEqual(@as(u8, 120), host.interpolate(0, 240, 15, 30));
    try std.testing.expectEqual(@as(u8, 240), host.interpolate(0, 240, 0, 30));
    try std.testing.expectEqual(@as(u8, 20), host.interpolate(10, 30, 15, 30));

    var choice = host.ChoiceState.start(0, 2, 30);
    try std.testing.expectEqual(@as(u8, 0), choice.position());
    choice.previous();
    try std.testing.expectEqual(@as(u8, 1), choice.state);
    try std.testing.expect(choice.moving);
    try std.testing.expectEqual(@as(u8, 0), choice.position()); // first tick is still the from row
    var tick: usize = 0;
    while (tick < 30) : (tick += 1) choice.tick();
    try std.testing.expect(!choice.moving);
    try std.testing.expectEqual(@as(u8, 1), choice.position());
}

test "choice confirm commits once and the branch picks the response text" {
    var parsed = try load();
    defer parsed.deinit();
    const pipeline = &parsed.value;
    const scene_index = pipeline.sceneIndex("vaa_choice").?;
    for ([_]u8{ 0, 1 }) |desired| {
        var machine = try host.Host.init(pipeline, scene_index, assetSha());
        var guard: usize = 0;
        while (machine.choice == null and guard < 200) : (guard += 1) {
            _ = try machine.frame(pipeline, .{ .mask = 0x40 });
        }
        try std.testing.expect(machine.choice != null);
        try std.testing.expectEqual(@as(u8, 0), machine.choice.?.state);
        if (desired == 1) {
            _ = try machine.frame(pipeline, .{ .mask = pipeline.choices.down });
            try std.testing.expectEqual(@as(u8, 1), machine.choice.?.state);
        }
        const committed = try machine.frame(pipeline, .{ .mask = 0x40 });
        try std.testing.expectEqual(@as(?u8, desired), committed.choice);
        try std.testing.expect(machine.choice == null);
        const committed_state = machine.state_byte;
        // A repeated confirm has nothing left to commit: it cannot fire a second
        // choice event or change the committed row.
        const repeated = try machine.frame(pipeline, .{ .mask = 0x40 });
        try std.testing.expectEqual(@as(?u8, null), repeated.choice);
        try std.testing.expectEqual(committed_state, machine.state_byte);
        try std.testing.expect(machine.choice == null);

        const result = try drive(pipeline, scene_index, desired, .{});
        try std.testing.expectEqual(@as(u8, 1 + desired), result.final_text);
        try std.testing.expectEqual(@as(usize, 1), result.choice_count);
        try std.testing.expectEqual(desired, result.choice_values[0]);
    }
}

test "cancel is reported and leaves the choice open" {
    var parsed = try load();
    defer parsed.deinit();
    const pipeline = &parsed.value;
    const scene_index = pipeline.sceneIndex("vaa_choice").?;
    var machine = try host.Host.init(pipeline, scene_index, assetSha());
    var guard: usize = 0;
    while (machine.choice == null and guard < 200) : (guard += 1) {
        _ = try machine.frame(pipeline, .{ .mask = 0x40 });
    }
    try std.testing.expect(machine.choice != null);
    const emission = try machine.frame(pipeline, .{ .mask = 0, .cancel = true });
    try std.testing.expect(emission.cancel_ignored);
    try std.testing.expect(machine.choice != null);
    try std.testing.expectEqual(@as(u8, 0), machine.choice.?.state);
}
