//! HQ stage plan focused checks: the pure stage plan, its source boundaries,
//! repeat/forced transitions and the castle-name producer refusal.
//!
//! The asset is parsed, not trusted: every constant it publishes is compared
//! against the module's source-derived constants.

const std = @import("std");
const stage_mod = @import("hq").stage;
const data = @import("hq_data");

const allocator = std.testing.allocator;

const Asset = struct {
    schema: []const u8,
    thresholds: struct {
        first: u16,
        second: u16,
        third: u16,
        flag_slots: u16,
    },
    story_gate: struct {
        offset: []const u8,
        mask: u8,
        flag_index: u8,
    },
    stages: []const struct {
        stage: u8,
        mirror_area_index: u8,
        castle_area_slot: ?u8,
    },
    name: struct {
        field_offset: []const u8,
        terminator: []const u8,
        glyphs: u8,
        producer: []const u8,
    },
};

fn loadAsset() !std.json.Parsed(Asset) {
    return std.json.parseFromSlice(Asset, allocator, data.stage_plan_json, .{
        .ignore_unknown_fields = true,
    });
}

test "recount uses bit0|bit1 for ever and bit0&!bit1 for present" {
    var flags: [stage_mod.flag_slots]u8 = @splat(0);
    flags[0] = 0x01; // present recruit
    flags[1] = 0x02; // departed recruit, still counted by the stage
    flags[2] = 0x03; // present and departed bits together: ever only
    flags[107] = 0x01;
    const before = flags;

    const counts = stage_mod.recount(&flags);
    try std.testing.expectEqual(@as(u16, 4), counts.ever);
    try std.testing.expectEqual(@as(u16, 2), counts.present);
    try std.testing.expectEqualSlices(u8, &before, &flags);
    try counts.validate();
}

test "promotion thresholds are inclusive and use the ever count" {
    const Cases = struct { stage: stage_mod.Stage, ever: u16, story: bool, want: stage_mod.Stage };
    const cases = [_]Cases{
        .{ .stage = .zero, .ever = 108, .story = true, .want = .zero },
        .{ .stage = .one, .ever = 24, .story = true, .want = .one },
        .{ .stage = .one, .ever = 25, .story = false, .want = .one },
        .{ .stage = .one, .ever = 25, .story = true, .want = .two },
        .{ .stage = .one, .ever = 45, .story = false, .want = .one },
        .{ .stage = .one, .ever = 90, .story = false, .want = .one },
        .{ .stage = .two, .ever = 44, .story = true, .want = .two },
        .{ .stage = .two, .ever = 45, .story = false, .want = .three },
        .{ .stage = .two, .ever = 108, .story = false, .want = .three },
        .{ .stage = .three, .ever = 89, .story = true, .want = .three },
        .{ .stage = .three, .ever = 90, .story = false, .want = .four },
        .{ .stage = .four, .ever = 108, .story = true, .want = .four },
    };
    for (cases) |case| {
        const counts: stage_mod.Counts = .{ .ever = case.ever, .present = 0 };
        try std.testing.expectEqual(case.want, stage_mod.promote(case.stage, counts, case.story));
    }
}

test "repeat application takes exactly one step and converges" {
    const counts: stage_mod.Counts = .{ .ever = 90, .present = 0 };
    var stage: stage_mod.Stage = .one;
    stage = stage_mod.promote(stage, counts, true);
    try std.testing.expectEqual(stage_mod.Stage.two, stage);
    stage = stage_mod.promote(stage, counts, true);
    try std.testing.expectEqual(stage_mod.Stage.three, stage);
    stage = stage_mod.promote(stage, counts, true);
    try std.testing.expectEqual(stage_mod.Stage.four, stage);
    stage = stage_mod.promote(stage, counts, true);
    try std.testing.expectEqual(stage_mod.Stage.four, stage);
}

test "forced transitions are the stage 0 path and saturate at 4" {
    try std.testing.expectEqual(stage_mod.Stage.one, try stage_mod.applyForced(.zero));
    try std.testing.expectEqual(stage_mod.Stage.two, try stage_mod.applyForced(.one));
    try std.testing.expectEqual(stage_mod.Stage.three, try stage_mod.applyForced(.two));
    try std.testing.expectEqual(stage_mod.Stage.four, try stage_mod.applyForced(.three));
    try std.testing.expectError(error.StageSaturated, stage_mod.applyForced(.four));
}

test "validated plan rejects out-of-domain facts" {
    try std.testing.expectError(
        error.InvalidRecruitCount,
        stage_mod.plan(.zero, .{ .ever = 109, .present = 0 }, false),
    );
    try std.testing.expectError(
        error.InvalidRecruitCount,
        stage_mod.plan(.zero, .{ .ever = 1, .present = 2 }, false),
    );
    try std.testing.expectError(error.StageOutOfRange, stage_mod.Stage.fromByte(5));
    try std.testing.expectError(error.StageOutOfRange, stage_mod.Stage.fromByte(255));
}

test "plan exposes the two source consumers" {
    const expected = [_]u8{ 128, 32, 24, 16, 16 };
    const slots = [_]?u8{ null, 0, 1, 2, 2 };
    for (expected, 0..) |area, index| {
        const stage = try stage_mod.Stage.fromByte(@intCast(index));
        try std.testing.expectEqual(area, stage.mirrorArea());
        try std.testing.expectEqual(slots[index], stage.castleAreaSlot());
        const result = try stage_mod.plan(stage, .{ .ever = 0, .present = 0 }, false);
        try std.testing.expectEqual(area, result.mirror_area);
        try std.testing.expectEqual(slots[index], result.castle_area_slot);
    }
}

test "next requirement names the missing gate" {
    const count = stage_mod.Requirement{ .count = 25 };
    const both = stage_mod.Requirement{ .count_and_story = 25 };
    try std.testing.expectEqual(stage_mod.Requirement.source_forced_only, stage_mod.nextRequirement(.zero, true));
    try std.testing.expectEqual(both, stage_mod.nextRequirement(.one, false));
    try std.testing.expectEqual(count, stage_mod.nextRequirement(.one, true));
    try std.testing.expectEqual(stage_mod.Requirement{ .count = 45 }, stage_mod.nextRequirement(.two, false));
    try std.testing.expectEqual(stage_mod.Requirement{ .count = 90 }, stage_mod.nextRequirement(.three, true));
    try std.testing.expectEqual(stage_mod.Requirement.none, stage_mod.nextRequirement(.four, false));
}

test "afterRecount applies one step and preserves the supplied facts" {
    const counts: stage_mod.Counts = .{ .ever = 25, .present = 3 };
    const result = try stage_mod.afterRecount(.one, counts, true);
    try std.testing.expectEqual(stage_mod.Stage.two, result.stage);
    try std.testing.expectEqual(counts, result.counts);
    try std.testing.expect(result.story_castle_flag);
    try std.testing.expectEqual(stage_mod.Requirement{ .count = 45 }, result.next);
    try std.testing.expectEqual(@as(u8, 24), result.mirror_area);
}

test "castle name storage validates but the producer stays unresolved" {
    const toran = [_]u8{ 0x3E, 0x1F, 0x22, 0x11, 0x1E, 0, 0, 0 };
    try std.testing.expectEqual(@as(usize, 5), try stage_mod.validateCastleName(&toran));
    const empty: [stage_mod.castle_name.glyphs]u8 = @splat(0);
    try std.testing.expectError(error.EmptyName, stage_mod.validateCastleName(&empty));
    var bad = toran;
    bad[0] = 0x01;
    try std.testing.expectError(error.InvalidGlyph, stage_mod.validateCastleName(&bad));
    var gap = toran;
    gap[6] = 0x2B;
    try std.testing.expectError(error.InvalidGlyph, stage_mod.validateCastleName(&gap));
    try std.testing.expectError(error.ProducerUnresolved, stage_mod.commitCastleName(&toran));
}

test "asset constants agree with the source-derived module" {
    const parsed = try loadAsset();
    defer parsed.deinit();
    const asset = parsed.value;

    try std.testing.expectEqualStrings(stage_mod.schema, asset.schema);
    try std.testing.expectEqual(stage_mod.thresholds.first, asset.thresholds.first);
    try std.testing.expectEqual(stage_mod.thresholds.second, asset.thresholds.second);
    try std.testing.expectEqual(stage_mod.thresholds.third, asset.thresholds.third);
    try std.testing.expectEqual(@as(u16, stage_mod.flag_slots), asset.thresholds.flag_slots);
    try std.testing.expectEqual(stage_mod.story_gate.mask, asset.story_gate.mask);
    try std.testing.expectEqual(@as(u8, 0x0F), asset.story_gate.flag_index);
    try std.testing.expectEqualStrings("0x19f", asset.story_gate.offset);

    try std.testing.expectEqual(@as(usize, stage_mod.stage_domain), asset.stages.len);
    for (asset.stages) |row| {
        const stage = try stage_mod.Stage.fromByte(row.stage);
        try std.testing.expectEqual(stage.mirrorArea(), row.mirror_area_index);
        try std.testing.expectEqual(stage.castleAreaSlot(), row.castle_area_slot);
    }

    try std.testing.expectEqualStrings("0x1b84", asset.name.field_offset);
    try std.testing.expectEqualStrings("0x1b8c", asset.name.terminator);
    try std.testing.expectEqual(@as(u8, stage_mod.castle_name.glyphs), asset.name.glyphs);
    try std.testing.expectEqualStrings("unresolved", asset.name.producer);
}
