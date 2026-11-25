//! Focused gate: shared field/battle/staged camera state.
//!
//! Expectations come from the embedded campaign asset, produced
//! by the independent static reference in the extraction pipeline.
//! Nothing here executes an original instruction, an emulator or a window.

const std = @import("std");
const root = @import("combat_systems").camera;
const battle = root.battle;

const allocator = std.testing.allocator;

const Vectors = struct {
    schema: []const u8,
    field_entry: []const EntryCase,
    field_push: PushCase,
    field_pan: PanCase,
    field_scroll: ScrollCase,
    battle_projection: ProjectionCase,
    battle_transition: TransitionCase,
    battle_track: TrackCase,
};

const EntryCase = struct {
    name: []const u8,
    focus: [2]i32,
    offset: [2]i32,
    section: [2]i32,
    expect: [2]i32,
};

const PushStateVec = struct {
    tick: u32,
    focus: [2]i32,
    offset: [2]i32,
    scroll: [2]i32,
    frames_left: u16,
    repeats_left: u16,
    owner: []const u8,
};

const PushCase = struct {
    name: []const u8,
    record: u8,
    repeats: u16,
    section: [2]i32,
    start_focus: [2]i32,
    start_offset: [2]i32,
    states: []const PushStateVec,
    finish_tick: u32,
    offset_persists: bool,
};

const PanStateVec = struct {
    tick: u32,
    focus: [2]i32,
    scroll: [2]i32,
    stage: []const u8,
};

const PanCase = struct {
    name: []const u8,
    section: [2]i32,
    start_focus: [2]i32,
    target: [2]i32,
    step_interval_ticks: u16,
    states: []const PanStateVec,
    finish_tick: u32,
};

const ScrollCase = struct {
    name: []const u8,
    start_scroll: [2]i32,
    operands: [2]u8,
    expect: [2]i32,
};

const ProjectionVec = struct {
    world: [3]i32,
    world_q12: [3]i32,
    expect_screen_no_scroll: [2]f32,
    depth: f32,
    documented: [2]f32,
    tolerance_px: f32,
};

const ProjectionCase = struct {
    preset: []const u8,
    scroll: [2]f32,
    scroll_preset_0: [2]f32,
    cases: []const ProjectionVec,
};

const TransitionState = struct {
    tick: u32,
    live: [12]i32,
    timers: [4]i32,
};

const TransitionCase = struct {
    live: []const u8,
    target: []const u8,
    frames: u16,
    deltas: [12]i32,
    states: []const TransitionState,
    settle_tick: u32,
    final: [12]i32,
};

const RectVec = struct {
    min: [2]f32,
    max: [2]f32,
    framed: bool,
};

const TrackCase = struct {
    base_preset: []const u8,
    actor_world: [3]i32,
    actor_raw: [3]i32,
    frames: u16,
    target_raw: [12]i32,
    scroll: [2]f32,
    small_target: RectVec,
    large_target: RectVec,
    large_target_wide_preset: RectVec,
};

fn loadVectors() !std.json.Parsed(Vectors) {
    return std.json.parseFromSlice(Vectors, allocator, root.vectors_json, .{ .ignore_unknown_fields = true });
}

fn ownerName(owner: root.Owner) []const u8 {
    return switch (owner) {
        .field_player => "field_player",
        .field_event => "field_event",
        .battle_frame => "battle_frame",
        .battle_transition => "battle_transition",
        .load => "load",
    };
}

fn expectVec2(actual: root.Vec2, expected: [2]i32) !void {
    try std.testing.expectEqual(expected[0], actual.x);
    try std.testing.expectEqual(expected[1], actual.y);
}

fn expectApprox(actual: f32, expected: f32, tolerance: f32) !void {
    try std.testing.expectApproxEqAbs(expected, actual, tolerance);
}

fn stateOf(state: *const root.State) *const root.field.Field {
    return &state.mode.field;
}

test "packet exposes explicit families, projections and presets" {
    var parsed = try root.load(allocator);
    defer parsed.deinit();
    const packet = &parsed.value;
    try std.testing.expectEqualStrings("suikoden-combat-camera-model/1", packet.schema);
    try std.testing.expectEqual(@as(usize, 2), packet.projections.len);
    try std.testing.expectEqual(@as(usize, 7), packet.families.len);
    try std.testing.expectEqual(@as(usize, 6), packet.battle.presets.len);
    try std.testing.expectEqual(@as(usize, 8), packet.field.push.records.len);
    try std.testing.expectEqual(@as(i32, 8), packet.units.field_cell_px);
    try std.testing.expectEqual(@as(i32, 16), packet.units.section_cell_px);
    try std.testing.expect(packet.blockers.len >= 3);
}

test "field entry formula and clamps" {
    var parsed = try root.load(allocator);
    defer parsed.deinit();
    var vectors = try loadVectors();
    defer vectors.deinit();
    for (vectors.value.field_entry) |case| {
        var state = try root.initField(
            &parsed.value,
            .{ .x = case.focus[0], .y = case.focus[1] },
            .{ .x = case.offset[0], .y = case.offset[1] },
            .{ .x = case.section[0], .y = case.section[1] },
        );
        try std.testing.expectEqual(root.Owner.field_player, state.owner);
        try std.testing.expectEqual(root.Family.field_track, state.family);
        try expectVec2(stateOf(&state).scroll_px, case.expect);
        // A world point at the frame centre projects to 160/120 after scroll.
        const centre = try root.project(&state, .{ .x = (case.expect[0] + 160) << 12, .y = (case.expect[1] + 120) << 12, .z = 0 });
        try expectApprox(centre.x, 160, 0.01);
        try expectApprox(centre.y, 120, 0.01);
    }
}

test "field push repeats, holds and leaves the offset committed" {
    var parsed = try root.load(allocator);
    defer parsed.deinit();
    var vectors = try loadVectors();
    defer vectors.deinit();
    const case = vectors.value.field_push;
    var state = try root.initField(
        &parsed.value,
        .{ .x = case.start_focus[0], .y = case.start_focus[1] },
        .{ .x = case.start_offset[0], .y = case.start_offset[1] },
        .{ .x = case.section[0], .y = case.section[1] },
    );
    try root.beginFieldPush(&parsed.value, &state, case.record, case.repeats);
    var index: usize = 0;
    try std.testing.expectEqualStrings(case.states[index].owner, ownerName(state.owner));
    try expectVec2(stateOf(&state).focus_cell, case.states[index].focus);
    try expectVec2(stateOf(&state).offset_px, case.states[index].offset);
    try expectVec2(stateOf(&state).scroll_px, case.states[index].scroll);
    index += 1;
    var ticks: u32 = 0;
    while (index < case.states.len) : (index += 1) {
        ticks += 1;
        const result = try root.tick(&parsed.value, &state);
        const expected = case.states[index];
        try std.testing.expectEqual(expected.tick, ticks);
        try expectVec2(stateOf(&state).focus_cell, expected.focus);
        try expectVec2(stateOf(&state).offset_px, expected.offset);
        try expectVec2(stateOf(&state).scroll_px, expected.scroll);
        try std.testing.expectEqualStrings(expected.owner, ownerName(state.owner));
        if (index + 1 == case.states.len) {
            try std.testing.expectEqual(root.TickResult.finished, result);
        } else {
            try std.testing.expectEqual(root.TickResult.active, result);
        }
    }
    try std.testing.expectEqual(case.finish_tick, ticks);
    try std.testing.expectEqual(root.Owner.field_player, state.owner);
    try std.testing.expect(state.transition == null);
    if (case.offset_persists) {
        try std.testing.expect(stateOf(&state).offset_px.x != 0 or stateOf(&state).offset_px.y != 0);
    }
}

test "field pan steps horizontally first, then vertically" {
    var parsed = try root.load(allocator);
    defer parsed.deinit();
    var vectors = try loadVectors();
    defer vectors.deinit();
    const case = vectors.value.field_pan;
    var state = try root.initField(
        &parsed.value,
        .{ .x = case.start_focus[0], .y = case.start_focus[1] },
        .{ .x = 0, .y = 0 },
        .{ .x = case.section[0], .y = case.section[1] },
    );
    try root.beginFieldPan(&parsed.value, &state, .{ .x = case.target[0], .y = case.target[1] });
    var index: usize = 0;
    var tick_count: u32 = 0;
    while (tick_count < case.finish_tick) {
        tick_count += 1;
        const result = try root.tick(&parsed.value, &state);
        if (index < case.states.len and case.states[index].tick == tick_count) {
            const expected = case.states[index];
            try expectVec2(stateOf(&state).focus_cell, expected.focus);
            try expectVec2(stateOf(&state).scroll_px, expected.scroll);
            if (index + 1 == case.states.len) {
                try std.testing.expectEqual(root.TickResult.finished, result);
            }
            index += 1;
        }
    }
    try std.testing.expectEqual(case.states.len, index);
    try std.testing.expectEqual(root.Owner.field_player, state.owner);
    try expectVec2(stateOf(&state).focus_cell, case.target);
}

test "direct opcode 0x26 scroll is explicit and requires release" {
    var parsed = try root.load(allocator);
    defer parsed.deinit();
    var vectors = try loadVectors();
    defer vectors.deinit();
    const case = vectors.value.field_scroll;
    var state = try root.initField(&parsed.value, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 0 }, .{ .x = 40, .y = 56 });
    try expectVec2(stateOf(&state).scroll_px, case.start_scroll);
    try root.beginFieldScroll(&parsed.value, &state, case.operands[0], case.operands[1]);
    try expectVec2(stateOf(&state).scroll_px, case.expect);
    try std.testing.expectEqual(root.Owner.field_event, state.owner);
    try root.release(&state);
    try std.testing.expectEqual(root.Owner.field_player, state.owner);
}

test "battle projection agrees with the source-table reference" {
    var parsed = try root.load(allocator);
    defer parsed.deinit();
    var vectors = try loadVectors();
    defer vectors.deinit();
    const case = vectors.value.battle_projection;
    var state = try root.initBattle(&parsed.value, case.preset);
    const scroll = state.mode.battle.scene_scroll;
    try expectApprox(scroll.x, case.scroll[0], 0.01);
    try expectApprox(scroll.y, case.scroll[1], 0.01);
    for (case.cases) |row| {
        const point = try root.projectNoScroll(&state, .{ .x = row.world_q12[0], .y = row.world_q12[1], .z = row.world_q12[2] });
        try expectApprox(point.x, row.expect_screen_no_scroll[0], row.tolerance_px);
        try expectApprox(point.y, row.expect_screen_no_scroll[1], row.tolerance_px);
        try expectApprox(point.depth, row.depth, 2.0);
        try expectApprox(point.x, row.documented[0], row.tolerance_px);
        try expectApprox(point.y, row.documented[1], row.tolerance_px);
    }
    const preset0 = try root.initBattle(&parsed.value, "battle.preset.0");
    try expectApprox(preset0.mode.battle.scene_scroll.x, case.scroll_preset_0[0], 0.01);
    try expectApprox(preset0.mode.battle.scene_scroll.y, case.scroll_preset_0[1], 0.01);
}

test "battle transition interpolates then snaps to the exact target" {
    var parsed = try root.load(allocator);
    defer parsed.deinit();
    var vectors = try loadVectors();
    defer vectors.deinit();
    const case = vectors.value.battle_transition;
    var state = try root.initBattle(&parsed.value, case.live);
    try root.beginBattleTransition(&parsed.value, &state, case.target, case.frames);
    try std.testing.expectEqual(root.Owner.battle_transition, state.owner);
    try std.testing.expectEqual(root.Owner.battle_frame, state.finish_owner);
    var tick: u32 = 0;
    for (case.states) |expected| {
        while (tick < expected.tick) : (tick += 1) {
            _ = try root.tick(&parsed.value, &state);
        }
        try std.testing.expectEqualSlices(i32, &expected.live, &state.mode.battle.live_raw);
        try std.testing.expectEqualSlices(i32, &expected.timers, &state.mode.battle.timers);
    }
    while (tick < case.settle_tick) : (tick += 1) {
        const result = try root.tick(&parsed.value, &state);
        if (tick + 1 == case.settle_tick) try std.testing.expectEqual(root.TickResult.finished, result);
    }
    try std.testing.expectEqualSlices(i32, &case.final, &state.mode.battle.live_raw);
    try std.testing.expectEqual(root.Owner.battle_frame, state.owner);
    try std.testing.expect(state.transition == null);
}

test "actor track inherits translation and separates large-target framing" {
    var parsed = try root.load(allocator);
    defer parsed.deinit();
    var vectors = try loadVectors();
    defer vectors.deinit();
    const case = vectors.value.battle_track;
    var state = try root.initBattle(&parsed.value, case.base_preset);
    try root.beginActorTrack(&parsed.value, &state, .{ .x = case.actor_raw[0], .y = case.actor_raw[1], .z = case.actor_raw[2] });
    try std.testing.expectEqualSlices(i32, &case.target_raw, &state.mode.battle.target_raw);
    var guard: usize = 0;
    while (state.transition != null and guard < 100) : (guard += 1) _ = try root.tick(&parsed.value, &state);
    try std.testing.expect(state.transition == null);
    try expectApprox(state.mode.battle.scene_scroll.x, case.scroll[0], 0.01);
    try expectApprox(state.mode.battle.scene_scroll.y, case.scroll[1], 0.01);

    const small = try root.frame(&state, .{
        .center_q12 = .{ .x = case.actor_raw[0], .y = case.actor_raw[1], .z = case.actor_raw[2] },
        .half_q12 = .{ .x = 40 << 12, .y = 40 << 12, .z = 10 << 12 },
    });
    try std.testing.expectEqual(case.small_target.framed, small.framed);

    const large = try root.frame(&state, .{
        .center_q12 = .{ .x = case.actor_raw[0], .y = case.actor_raw[1], .z = case.actor_raw[2] },
        .half_q12 = .{ .x = 80 << 12, .y = 80 << 12, .z = 40 << 12 },
    });
    try std.testing.expectEqual(case.large_target.framed, large.framed);
    try std.testing.expect(!large.framed);

    var wide = try root.initBattle(&parsed.value, case.base_preset);
    const wide_rect = try root.frame(&wide, .{
        .center_q12 = .{ .x = case.actor_raw[0], .y = case.actor_raw[1], .z = case.actor_raw[2] },
        .half_q12 = .{ .x = 80 << 12, .y = 80 << 12, .z = 40 << 12 },
    });
    try std.testing.expectEqual(case.large_target_wide_preset.framed, wide_rect.framed);
    try std.testing.expect(wide_rect.framed);
}

test "interrupted battle transition restores the same owner and finish" {
    var parsed = try root.load(allocator);
    defer parsed.deinit();
    var state = try root.initBattle(&parsed.value, "battle.preset.0");
    try root.beginBattleTransition(&parsed.value, &state, "battle.preset.1", 60);
    for (0..17) |_| _ = try root.tick(&parsed.value, &state);
    const snapshot = root.capture(&state);
    var restored = try root.restore(&parsed.value, snapshot);
    try std.testing.expectEqual(root.Owner.battle_transition, restored.owner);
    try std.testing.expectEqual(root.Owner.battle_frame, restored.finish_owner);
    try std.testing.expectEqualSlices(i32, &state.mode.battle.live_raw, &restored.mode.battle.live_raw);
    try std.testing.expectEqualSlices(i32, &state.mode.battle.timers, &restored.mode.battle.timers);
    try std.testing.expectEqual(state.transition.?.elapsed_frames, restored.transition.?.elapsed_frames);
    var guard: usize = 0;
    while (restored.transition != null and guard < 100) : (guard += 1) _ = try root.tick(&parsed.value, &restored);
    const target_index = try root.findPreset(&parsed.value, "battle.preset.1");
    try std.testing.expectEqualSlices(i32, &parsed.value.battle.presets[target_index].raw, &restored.mode.battle.live_raw);
}

test "interrupted field push restores focus, offset and repeats" {
    var parsed = try root.load(allocator);
    defer parsed.deinit();
    var state = try root.initField(&parsed.value, .{ .x = 64, .y = 73 }, .{ .x = 0, .y = 0 }, .{ .x = 40, .y = 56 });
    try root.beginFieldPush(&parsed.value, &state, 0, 2);
    for (0..5) |_| _ = try root.tick(&parsed.value, &state);
    const snapshot = root.capture(&state);
    var restored = try root.restore(&parsed.value, snapshot);
    try std.testing.expectEqual(root.Owner.field_event, restored.owner);
    try std.testing.expectEqual(root.Owner.field_player, restored.finish_owner);
    try expectVec2(stateOf(&restored).focus_cell, .{ 62, 72 });
    try expectVec2(stateOf(&restored).offset_px, .{ 16, 8 });
    var guard: usize = 0;
    while (restored.transition != null and guard < 100) : (guard += 1) _ = try root.tick(&parsed.value, &restored);
    try std.testing.expectEqual(root.Owner.field_player, restored.owner);
    try expectVec2(stateOf(&restored).focus_cell, .{ 60, 71 });
    try expectVec2(stateOf(&restored).offset_px, .{ 16, 8 });
}

test "unknown projection, preset, record and frames are refused" {
    var parsed = try root.load(allocator);
    defer parsed.deinit();
    try std.testing.expectError(error.UnknownProjection, root.findProjection(&parsed.value, "battle.unknown"));
    try std.testing.expectError(error.UnknownPreset, root.initBattle(&parsed.value, "battle.preset.99"));
    var battle_state = try root.initBattle(&parsed.value, "battle.preset.0");
    try std.testing.expectError(error.InvalidFrameCount, root.beginBattleTransition(&parsed.value, &battle_state, "battle.preset.1", 0));
    var field_state = try root.initField(&parsed.value, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 0 }, .{ .x = 40, .y = 56 });
    try std.testing.expectError(error.UnknownPushRecord, root.beginFieldPush(&parsed.value, &field_state, 8, 1));
    try std.testing.expectError(error.InvalidRepeatCount, root.beginFieldPush(&parsed.value, &field_state, 0, 0));
    try std.testing.expectError(error.UnsupportedScrollTile, root.beginScrollPan(&parsed.value, &field_state, 9, 4));
    try std.testing.expectError(error.TargetOutsideSection, root.beginFieldPan(&parsed.value, &field_state, .{ .x = 100, .y = 100 }));
    var snapshot = root.capture(&field_state);
    snapshot.projection_id = "field.unknown";
    try std.testing.expectError(error.UnknownProjection, root.restore(&parsed.value, snapshot));
    var battle_snapshot = root.capture(&battle_state);
    battle_snapshot.owner = .battle_transition;
    battle_snapshot.family = .battle_transition;
    battle_snapshot.finish_owner = .battle_frame;
    battle_snapshot.transition = .{
        .kind = .battle_block,
        .total_frames = 60,
        .elapsed_frames = 0,
        .finish_owner = .battle_frame,
        .preset_index = 99,
    };
    try std.testing.expectError(error.UnknownPreset, root.restore(&parsed.value, battle_snapshot));
}

test "release refuses while a transition owns the camera" {
    var parsed = try root.load(allocator);
    defer parsed.deinit();
    var state = try root.initField(&parsed.value, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 0 }, .{ .x = 40, .y = 56 });
    try root.beginFieldPush(&parsed.value, &state, 0, 1);
    try std.testing.expectError(error.CameraBusy, root.release(&state));
}

test "opcode 0x08 scroll pan and direct-scroll restore" {
    var parsed = try root.load(allocator);
    defer parsed.deinit();
    var state = try root.initField(&parsed.value, .{ .x = 64, .y = 73 }, .{ .x = 0, .y = 0 }, .{ .x = 40, .y = 56 });
    try expectVec2(stateOf(&state).scroll_px, .{ 320, 472 });
    // Tile 2 has delta (0,+1); four countdown units are eight frames of two
    // units each, i.e. sixteen scroll pixels down.
    try root.beginScrollPan(&parsed.value, &state, 2, 4);
    var guard: usize = 0;
    while (state.transition != null and guard < 100) : (guard += 1) _ = try root.tick(&parsed.value, &state);
    try expectVec2(stateOf(&state).scroll_px, .{ 320, 488 });
    try std.testing.expectEqual(root.Owner.field_player, state.owner);

    try root.beginFieldScroll(&parsed.value, &state, 40, 59);
    try expectVec2(stateOf(&state).scroll_px, .{ 320, 472 });
    const snapshot = root.capture(&state);
    var restored = try root.restore(&parsed.value, snapshot);
    try std.testing.expectEqual(root.Owner.field_event, restored.owner);
    try expectVec2(stateOf(&restored).scroll_px, .{ 320, 472 });
    try root.release(&restored);
    try std.testing.expectEqual(root.Owner.field_player, restored.owner);
}

test "field framing uses the explicit viewport" {
    var parsed = try root.load(allocator);
    defer parsed.deinit();
    var state = try root.initField(&parsed.value, .{ .x = 64, .y = 73 }, .{ .x = 0, .y = 0 }, .{ .x = 40, .y = 56 });
    const small = try root.frame(&state, .{
        .center_q12 = .{ .x = 512 << 12, .y = 584 << 12, .z = 0 },
        .half_q12 = .{ .x = 40 << 12, .y = 40 << 12, .z = 0 },
    });
    try std.testing.expect(small.framed);
    const large = try root.frame(&state, .{
        .center_q12 = .{ .x = 512 << 12, .y = 584 << 12, .z = 0 },
        .half_q12 = .{ .x = 200 << 12, .y = 200 << 12, .z = 0 },
    });
    try std.testing.expect(!large.framed);
}
