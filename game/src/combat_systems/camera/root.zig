//! One shared camera state for field, battle and staged events.
//!
//! The packet is embedded from the embedded campaign asset
//! and the focused vectors from `vectors.json`.  Nothing here selects a scene
//! camera on its own: every entry point takes a packet family/preset id, and an
//! unknown id/projection/frame count is a typed refusal.

const std = @import("std");
const model = @import("model.zig");
pub const field = @import("field.zig");
pub const battle = @import("battle.zig");

const data = @import("data.zig");
pub const camera_json = data.camera_model_json;
pub const vectors_json = data.vectors_json;

pub const Packet = model.Packet;
pub const Owner = model.Owner;
pub const Vec2 = field.Vec2;
pub const Vec3 = model.Vec3;
pub const ScreenPoint = battle.ScreenPoint;

pub const Family = enum {
    field_track,
    field_scripted_push,
    field_scripted_pan,
    field_scripted_scroll,
    battle_transition,
    battle_actor_track,
    battle_hold,
};

pub const TransitionKind = enum {
    battle_block,
    battle_actor_track,
    field_push,
    field_pan,
    field_scroll,
};

pub const PushState = struct {
    record_index: u8,
    frames_left: u16,
    repeats_left: u16,
};

pub const PanStage = enum { horizontal, vertical };

pub const PanState = struct {
    horizontal_remaining: i32,
    vertical_remaining: i32,
    horizontal_delta: Vec2,
    vertical_delta: Vec2,
    stage: PanStage,
    ticks_until_step: u16,
};

pub const ScrollState = struct {
    remaining: i32,
    delta: Vec2,
};

pub const Transition = struct {
    kind: TransitionKind,
    total_frames: u16,
    elapsed_frames: u16,
    finish_owner: Owner,
    preset_index: u16 = 0,
    push: ?PushState = null,
    pan: ?PanState = null,
    scroll: ?ScrollState = null,
};

pub const Mode = union(enum) {
    field: field.Field,
    battle: battle.Battle,
};

pub const State = struct {
    owner: Owner,
    family: Family,
    projection_id: []const u8,
    projection: battle.Projection,
    mode: Mode,
    transition: ?Transition = null,
    finish_owner: Owner,
};

pub const Snapshot = struct {
    version: u16 = 1,
    owner: Owner,
    family: Family,
    finish_owner: Owner,
    projection_id: []const u8,
    mode: Mode,
    transition: ?Transition,
};

pub const TickResult = enum { idle, active, finished };

pub const Bounds = struct {
    center_q12: model.Vec3,
    half_q12: model.Vec3,
};

pub const ScreenRect = field.ScreenRect;

pub fn load(allocator: std.mem.Allocator) !std.json.Parsed(Packet) {
    return model.load(allocator, camera_json);
}

pub fn familyId(family: Family) []const u8 {
    return switch (family) {
        .field_track => "field.track",
        .field_scripted_push => "field.scripted_push",
        .field_scripted_pan => "field.scripted_pan",
        .field_scripted_scroll => "field.scripted_scroll",
        .battle_transition => "battle.transition",
        .battle_actor_track => "battle.actor_track",
        .battle_hold => "battle.hold",
    };
}

fn findFamilyDef(packet: *const Packet, family: Family) !*const model.FamilyDef {
    const id = familyId(family);
    for (packet.families) |*def| if (std.mem.eql(u8, def.id, id)) return def;
    return error.MissingFamily;
}

fn projectionForFamily(packet: *const Packet, family: Family) !struct { id: []const u8, projection: battle.Projection } {
    const def = try findFamilyDef(packet, family);
    return .{
        .id = def.projection,
        .projection = try findProjection(packet, def.projection),
    };
}

pub fn findProjection(packet: *const Packet, id: []const u8) !battle.Projection {
    for (packet.projections) |def| {
        if (!std.mem.eql(u8, def.id, id)) continue;
        if (std.mem.eql(u8, def.kind, "orthographic_2d")) {
            const width = def.viewport_width_px orelse return error.UnsupportedProjection;
            const height = def.viewport_height_px orelse return error.UnsupportedProjection;
            const origin = def.origin orelse return error.UnsupportedProjection;
            if (!std.mem.eql(u8, origin, "top_left")) return error.UnsupportedProjection;
            if ((def.pixel_scale orelse 0) != 1) return error.UnsupportedProjection;
            return .{ .ortho_2d = .{ .width_px = width, .height_px = height } };
        }
        if (std.mem.eql(u8, def.kind, "perspective")) {
            return .{ .perspective = .{
                .focal_length_px = def.focal_length_px orelse return error.UnsupportedProjection,
                .center_x_px = def.center_x_px orelse return error.UnsupportedProjection,
                .center_y_px = def.center_y_px orelse return error.UnsupportedProjection,
                .gte_ofx = def.gte_ofx orelse return error.UnsupportedProjection,
                .gte_ofy = def.gte_ofy orelse return error.UnsupportedProjection,
                .depth_min = def.depth_min orelse return error.UnsupportedProjection,
                .width_px = def.viewport_width_px orelse return error.UnsupportedProjection,
                .height_px = def.viewport_height_px orelse return error.UnsupportedProjection,
            } };
        }
        return error.UnsupportedProjection;
    }
    return error.UnknownProjection;
}

pub fn findPreset(packet: *const Packet, id: []const u8) !usize {
    for (packet.battle.presets, 0..) |preset, index| {
        if (std.mem.eql(u8, preset.id, id)) return index;
    }
    return error.UnknownPreset;
}

fn presetRaw(packet: *const Packet, index: usize) ![12]i32 {
    if (index >= packet.battle.presets.len) return error.UnknownPreset;
    return packet.battle.presets[index].raw;
}

fn refreshBattleScroll(state: *State) !void {
    switch (state.mode) {
        .battle => |*b| {
            const projection = switch (state.projection) {
                .perspective => |value| value,
                .ortho_2d => return error.ProjectionMismatch,
            };
            const block = battle.blockFromRaw(b.live_raw);
            const scroll = try battle.sceneScroll(block, projection.focal_length_px);
            b.scene_scroll = .{ .x = scroll.x + b.shake_px.x, .y = scroll.y + b.shake_px.y };
        },
        .field => return error.WrongMode,
    }
}

pub fn initField(
    packet: *const Packet,
    focus_cell: Vec2,
    offset_px: Vec2,
    section_cells: Vec2,
) !State {
    if (focus_cell.x < 0 or focus_cell.x > 255 or focus_cell.y < 0 or focus_cell.y > 255) return error.InvalidFieldFocus;
    if (offset_px.x < -128 or offset_px.x > 127 or offset_px.y < -128 or offset_px.y > 127) return error.InvalidFieldOffset;
    if (section_cells.x <= 0 or section_cells.y <= 0) return error.InvalidSectionSize;
    const projected = try projectionForFamily(packet, .field_track);
    if (projected.projection != .ortho_2d) return error.ProjectionMismatch;
    const projection = switch (projected.projection) {
        .ortho_2d => |value| value,
        .perspective => return error.ProjectionMismatch,
    };
    var camera = field.Field{
        .focus_cell = focus_cell,
        .offset_px = offset_px,
        .scroll_px = .{ .x = 0, .y = 0 },
        .section_cells = section_cells,
        .viewport_px = .{ .x = projection.width_px, .y = projection.height_px },
    };
    field.recompute(packet.field.entry, packet.units.section_cell_px, &camera);
    return .{
        .owner = .field_player,
        .family = .field_track,
        .projection_id = projected.id,
        .projection = projected.projection,
        .mode = .{ .field = camera },
        .transition = null,
        .finish_owner = .field_player,
    };
}

pub fn initBattle(packet: *const Packet, preset_id: []const u8) !State {
    const index = try findPreset(packet, preset_id);
    const raw = try presetRaw(packet, index);
    const projected = try projectionForFamily(packet, .battle_hold);
    if (projected.projection != .perspective) return error.ProjectionMismatch;
    var state = State{
        .owner = .battle_frame,
        .family = .battle_hold,
        .projection_id = projected.id,
        .projection = projected.projection,
        .mode = .{ .battle = .{ .live_raw = raw, .target_raw = raw } },
        .transition = null,
        .finish_owner = .battle_frame,
    };
    try refreshBattleScroll(&state);
    return state;
}

pub fn beginBattleTransition(
    packet: *const Packet,
    state: *State,
    preset_id: []const u8,
    frames: u16,
) !void {
    if (state.transition != null) return error.CameraBusy;
    if (state.mode != .battle) return error.WrongMode;
    if (frames == 0) return error.InvalidFrameCount;
    const index = try findPreset(packet, preset_id);
    const target = try presetRaw(packet, index);
    const live = state.mode.battle.live_raw;
    const plan = try battle.interpolation(target, live, frames);
    const projected = try projectionForFamily(packet, .battle_transition);
    if (projected.projection != .perspective) return error.ProjectionMismatch;
    if (!std.mem.eql(u8, state.projection_id, projected.id)) return error.ProjectionMismatch;
    state.owner = .battle_transition;
    state.family = .battle_transition;
    state.finish_owner = .battle_frame;
    state.mode.battle.target_raw = target;
    state.mode.battle.timers = plan.timers;
    state.mode.battle.deltas = plan.deltas;
    state.transition = .{
        .kind = .battle_block,
        .total_frames = frames,
        .elapsed_frames = 0,
        .finish_owner = .battle_frame,
        .preset_index = @intCast(index),
    };
}

pub fn beginActorTrack(
    packet: *const Packet,
    state: *State,
    actor_world_q12: model.Vec3,
) !void {
    if (state.transition != null) return error.CameraBusy;
    if (state.mode != .battle) return error.WrongMode;
    const projected = try projectionForFamily(packet, .battle_actor_track);
    if (projected.projection != .perspective) return error.ProjectionMismatch;
    if (!std.mem.eql(u8, state.projection_id, projected.id)) return error.ProjectionMismatch;
    const frames = packet.battle.actor_track.frames;
    if (frames == 0) return error.InvalidFrameCount;
    const live = state.mode.battle.live_raw;
    const target = battle.actorTrackTarget(live, packet.battle.actor_track, actor_world_q12);
    const plan = try battle.interpolation(target, live, frames);
    state.owner = .battle_transition;
    state.family = .battle_actor_track;
    state.finish_owner = .battle_frame;
    state.mode.battle.target_raw = target;
    state.mode.battle.timers = plan.timers;
    state.mode.battle.deltas = plan.deltas;
    state.transition = .{
        .kind = .battle_actor_track,
        .total_frames = frames,
        .elapsed_frames = 0,
        .finish_owner = .battle_frame,
    };
}

pub fn beginFieldPush(
    packet: *const Packet,
    state: *State,
    record_index: u8,
    repeats: u16,
) !void {
    if (state.transition != null) return error.CameraBusy;
    if (state.mode != .field) return error.WrongMode;
    if (state.owner != .field_player and state.owner != .field_event) return error.WrongOwner;
    if (repeats == 0) return error.InvalidRepeatCount;
    if (record_index >= packet.field.push.records.len) return error.UnknownPushRecord;
    const record = packet.field.push.records[record_index];
    if (record.frames == 0) return error.InvalidFrameCount;
    const projected = try projectionForFamily(packet, .field_scripted_push);
    if (projected.projection != .ortho_2d) return error.ProjectionMismatch;
    if (!std.mem.eql(u8, state.projection_id, projected.id)) return error.ProjectionMismatch;
    field.applyPushRecord(packet.field.entry, packet.units.section_cell_px, &state.mode.field, record);
    state.owner = .field_event;
    state.family = .field_scripted_push;
    state.finish_owner = .field_player;
    state.transition = .{
        .kind = .field_push,
        .total_frames = @intCast(@min(@as(u32, record.frames) * repeats, 65535)),
        .elapsed_frames = 0,
        .finish_owner = .field_player,
        .push = .{
            .record_index = record_index,
            .frames_left = record.frames,
            .repeats_left = repeats,
        },
    };
}

fn parseDirectionCode(code: []const u8) !u32 {
    if (code.len < 3 or code[0] != '0' or (code[1] != 'x' and code[1] != 'X')) return error.UnknownDirectionCode;
    return std.fmt.parseInt(u32, code[2..], 16);
}

fn focusDirection(code: []const u8) !usize {
    const value = try parseDirectionCode(code);
    return switch (value & 0xF000) {
        0x1000, 0x3000 => 1,
        0x2000, 0x6000 => 3,
        0x4000, 0xC000 => 0,
        0x8000, 0x9000 => 2,
        else => error.UnknownDirectionCode,
    };
}

fn deltaForParameter(packet: *const Packet, parameter: u8) !Vec2 {
    if (parameter >= packet.field.pan.parameter_to_code.len) return error.UnknownDirectionCode;
    const direction = try focusDirection(packet.field.pan.parameter_to_code[parameter]);
    if (direction >= packet.field.pan.focus_deltas.len) return error.UnknownDirectionCode;
    const delta = packet.field.pan.focus_deltas[direction];
    return .{ .x = delta[0], .y = delta[1] };
}

pub fn beginFieldPan(packet: *const Packet, state: *State, target_cell: Vec2) !void {
    if (state.transition != null) return error.CameraBusy;
    if (state.mode != .field) return error.WrongMode;
    if (state.owner != .field_player and state.owner != .field_event) return error.WrongOwner;
    const projected = try projectionForFamily(packet, .field_scripted_pan);
    if (projected.projection != .ortho_2d) return error.ProjectionMismatch;
    if (!std.mem.eql(u8, state.projection_id, projected.id)) return error.ProjectionMismatch;
    const max_cell = state.mode.field.section_cells;
    if (target_cell.x < 0 or target_cell.y < 0 or
        target_cell.x >= max_cell.x * 2 or target_cell.y >= max_cell.y * 2)
        return error.TargetOutsideSection;
    const current = state.mode.field.focus_cell;
    const dx = target_cell.x - current.x;
    const dy = target_cell.y - current.y;
    if (dx == 0 and dy == 0) return error.NothingToDo;
    const horizontal_parameter: u8 = if (dx > 0) packet.field.pan.horizontal_parameters.right else packet.field.pan.horizontal_parameters.left;
    const vertical_parameter: u8 = if (dy < 0) packet.field.pan.vertical_codes.up else packet.field.pan.vertical_codes.down;
    const horizontal_delta = try deltaForParameter(packet, horizontal_parameter);
    const vertical_delta = try deltaForParameter(packet, vertical_parameter);
    const horizontal_remaining: i32 = @intCast(@abs(dx));
    const vertical_remaining: i32 = @intCast(@abs(dy));
    const stage: PanStage = if (horizontal_remaining > 0) .horizontal else .vertical;
    const first_wait: u16 = if (horizontal_remaining > 0) 1 else packet.field.pan.step_interval_ticks + 1;
    state.owner = .field_event;
    state.family = .field_scripted_pan;
    state.finish_owner = .field_player;
    const interval: u32 = packet.field.pan.step_interval_ticks;
    var total: u32 = if (horizontal_remaining > 0)
        1 + interval * (@as(u32, @intCast(horizontal_remaining)) - 1) + 2 * interval
    else
        interval + 1;
    if (vertical_remaining > 0)
        total += interval * (@as(u32, @intCast(vertical_remaining)) - 1);
    state.transition = .{
        .kind = .field_pan,
        .total_frames = @intCast(@min(total, 65535)),
        .elapsed_frames = 0,
        .finish_owner = .field_player,
        .pan = .{
            .horizontal_remaining = horizontal_remaining,
            .vertical_remaining = vertical_remaining,
            .horizontal_delta = horizontal_delta,
            .vertical_delta = vertical_delta,
            .stage = stage,
            .ticks_until_step = first_wait,
        },
    };
}

pub fn beginFieldScroll(packet: *const Packet, state: *State, x: u8, y: u8) !void {
    if (state.transition != null) return error.CameraBusy;
    if (state.mode != .field) return error.WrongMode;
    const projected = try projectionForFamily(packet, .field_scripted_scroll);
    if (projected.projection != .ortho_2d) return error.ProjectionMismatch;
    if (!std.mem.eql(u8, state.projection_id, projected.id)) return error.ProjectionMismatch;
    state.mode.field.scroll_px = .{ .x = @as(i32, x) * 8, .y = @as(i32, y) * 8 };
    state.owner = .field_event;
    state.family = .field_scripted_scroll;
    state.finish_owner = .field_player;
    state.transition = null;
}

pub fn beginScrollPan(packet: *const Packet, state: *State, tile: u8, countdown_units: u8) !void {
    if (state.transition != null) return error.CameraBusy;
    if (state.mode != .field) return error.WrongMode;
    if (tile >= packet.field.scroll.deltas.x.len) return error.UnsupportedScrollTile;
    const projected = try projectionForFamily(packet, .field_scripted_scroll);
    if (projected.projection != .ortho_2d) return error.ProjectionMismatch;
    if (!std.mem.eql(u8, state.projection_id, projected.id)) return error.ProjectionMismatch;
    state.owner = .field_event;
    state.family = .field_scripted_scroll;
    state.finish_owner = .field_player;
    state.transition = .{
        .kind = .field_scroll,
        .total_frames = @intCast(@as(u32, countdown_units) * 8 / 2),
        .elapsed_frames = 0,
        .finish_owner = .field_player,
        .scroll = .{
            .remaining = @as(i32, countdown_units) * 8,
            .delta = .{ .x = packet.field.scroll.deltas.x[tile], .y = packet.field.scroll.deltas.y[tile] },
        },
    };
}

fn finishTransition(state: *State) void {
    state.transition = null;
    state.owner = state.finish_owner;
    state.family = switch (state.mode) {
        .field => .field_track,
        .battle => .battle_hold,
    };
}

/// Explicitly return a borrowed field camera (direct opcode 0x26 scroll).
pub fn fieldScrollPx(state: *const State) !Vec2 {
    return switch (state.mode) {
        .field => |camera| camera.scroll_px,
        .battle => error.WrongMode,
    };
}

pub fn fieldFocusCell(state: *const State) !Vec2 {
    return switch (state.mode) {
        .field => |camera| camera.focus_cell,
        .battle => error.WrongMode,
    };
}

pub fn release(state: *State) !void {
    if (state.transition != null) return error.CameraBusy;
    if (state.owner == .field_event) {
        state.owner = state.finish_owner;
        state.family = .field_track;
    }
}

pub fn tick(packet: *const Packet, state: *State) !TickResult {
    if (state.transition == null) return .idle;
    const transition = &state.transition.?;
    switch (transition.kind) {
        .battle_block, .battle_actor_track => {
            const settled = try battle.advance(
                &state.mode.battle.live_raw,
                state.mode.battle.target_raw,
                &state.mode.battle.timers,
                state.mode.battle.deltas,
            );
            try refreshBattleScroll(state);
            transition.elapsed_frames += 1;
            if (settled) {
                finishTransition(state);
                return .finished;
            }
            return .active;
        },
        .field_push => {
            const push = &(transition.push orelse return error.InvalidTransition);
            if (push.frames_left == 0) return error.InvalidTransition;
            push.frames_left -= 1;
            if (push.frames_left == 0) {
                if (push.repeats_left > 1) {
                    push.repeats_left -= 1;
                    const record = packet.field.push.records[push.record_index];
                    field.applyPushRecord(packet.field.entry, packet.units.section_cell_px, &state.mode.field, record);
                    push.frames_left = record.frames;
                } else {
                    transition.elapsed_frames += 1;
                    finishTransition(state);
                    return .finished;
                }
            }
            transition.elapsed_frames += 1;
            return .active;
        },
        .field_pan => {
            const pan = &(transition.pan orelse return error.InvalidTransition);
            if (pan.ticks_until_step > 1) {
                pan.ticks_until_step -= 1;
                transition.elapsed_frames += 1;
                return .active;
            }
            switch (pan.stage) {
                .horizontal => {
                    if (pan.horizontal_remaining > 0) {
                        field.stepFocus(&state.mode.field, pan.horizontal_delta);
                        pan.horizontal_remaining -= 1;
                    }
                    if (pan.horizontal_remaining == 0) {
                        pan.stage = .vertical;
                        pan.ticks_until_step = 2 * packet.field.pan.step_interval_ticks;
                    } else {
                        pan.ticks_until_step = packet.field.pan.step_interval_ticks;
                    }
                },
                .vertical => {
                    if (pan.vertical_remaining > 0) {
                        field.stepFocus(&state.mode.field, pan.vertical_delta);
                        pan.vertical_remaining -= 1;
                    }
                    if (pan.vertical_remaining == 0) {
                        field.recompute(packet.field.entry, packet.units.section_cell_px, &state.mode.field);
                        transition.elapsed_frames += 1;
                        finishTransition(state);
                        return .finished;
                    }
                    pan.ticks_until_step = packet.field.pan.step_interval_ticks;
                },
            }
            field.recompute(packet.field.entry, packet.units.section_cell_px, &state.mode.field);
            if (state.mode.field.focus_cell.x < 0 or state.mode.field.focus_cell.y < 0 or
                state.mode.field.focus_cell.x >= state.mode.field.section_cells.x * 2 or
                state.mode.field.focus_cell.y >= state.mode.field.section_cells.y * 2)
                return error.FocusOutOfSection;
            transition.elapsed_frames += 1;
            return .active;
        },
        .field_scroll => {
            const scroll = &(transition.scroll orelse return error.InvalidTransition);
            if (scroll.remaining > 0) {
                state.mode.field.scroll_px.x += scroll.delta.x;
                state.mode.field.scroll_px.y += scroll.delta.y;
                scroll.remaining -= 2;
                transition.elapsed_frames += 1;
                if (scroll.remaining <= 0) {
                    finishTransition(state);
                    return .finished;
                }
                return .active;
            }
            finishTransition(state);
            return .finished;
        },
    }
}

pub fn project(state: *const State, world_q12: model.Vec3) !ScreenPoint {
    return switch (state.projection) {
        .ortho_2d => switch (state.mode) {
            .field => |camera| field.project(camera, world_q12),
            .battle => error.ProjectionMismatch,
        },
        .perspective => |projection| switch (state.mode) {
            .battle => |camera| battle.project(projection, battle.blockFromRaw(camera.live_raw), camera.scene_scroll, world_q12),
            .field => error.ProjectionMismatch,
        },
    };
}

pub fn projectNoScroll(state: *const State, world_q12: model.Vec3) !ScreenPoint {
    return switch (state.projection) {
        .perspective => |projection| switch (state.mode) {
            .battle => |camera| battle.projectNoScroll(projection, battle.blockFromRaw(camera.live_raw), world_q12),
            .field => error.ProjectionMismatch,
        },
        .ortho_2d => error.ProjectionMismatch,
    };
}

pub fn frame(state: *const State, bounds: Bounds) !ScreenRect {
    return switch (state.mode) {
        .field => |camera| blk: {
            const projection = switch (state.projection) {
                .ortho_2d => |value| value,
                .perspective => return error.ProjectionMismatch,
            };
            break :blk field.frameRect(camera, .{ .center_q12 = bounds.center_q12, .half_q12 = bounds.half_q12 }, projection.width_px, projection.height_px);
        },
        .battle => |camera| blk: {
            const projection = switch (state.projection) {
                .perspective => |value| value,
                .ortho_2d => return error.ProjectionMismatch,
            };
            const block = battle.blockFromRaw(camera.live_raw);
            var min_x: f32 = std.math.inf(f32);
            var min_y: f32 = std.math.inf(f32);
            var max_x: f32 = -std.math.inf(f32);
            var max_y: f32 = -std.math.inf(f32);
            for ([_]i32{ -1, 1 }) |sx| {
                for ([_]i32{ -1, 1 }) |sy| {
                    for ([_]i32{ -1, 1 }) |sz| {
                        const point = try battle.project(projection, block, camera.scene_scroll, .{
                            .x = bounds.center_q12.x + sx * bounds.half_q12.x,
                            .y = bounds.center_q12.y + sy * bounds.half_q12.y,
                            .z = bounds.center_q12.z + sz * bounds.half_q12.z,
                        });
                        min_x = @min(min_x, point.x);
                        min_y = @min(min_y, point.y);
                        max_x = @max(max_x, point.x);
                        max_y = @max(max_y, point.y);
                    }
                }
            }
            break :blk .{
                .min_x = min_x,
                .min_y = min_y,
                .max_x = max_x,
                .max_y = max_y,
                .framed = min_x >= 0 and max_x <= @as(f32, @floatFromInt(projection.width_px)) and min_y >= 0 and max_y <= @as(f32, @floatFromInt(projection.height_px)),
            };
        },
    };
}

pub fn capture(state: *const State) Snapshot {
    return .{
        .owner = state.owner,
        .family = state.family,
        .finish_owner = state.finish_owner,
        .projection_id = state.projection_id,
        .mode = state.mode,
        .transition = state.transition,
    };
}

pub fn restore(packet: *const Packet, snapshot: Snapshot) !State {
    if (snapshot.version != 1) return error.UnsupportedSnapshotVersion;
    if (snapshot.projection_id.len == 0) return error.UnknownProjection;
    const projection = try findProjection(packet, snapshot.projection_id);
    switch (snapshot.mode) {
        .field => if (projection != .ortho_2d) return error.ProjectionMismatch,
        .battle => if (projection != .perspective) return error.ProjectionMismatch,
    }
    if (snapshot.transition) |transition| {
        if (transition.finish_owner != snapshot.finish_owner) return error.InconsistentOwner;
        if (snapshot.owner == transition.finish_owner) return error.InconsistentOwner;
        switch (transition.kind) {
            .battle_block, .battle_actor_track => {
                if (snapshot.mode != .battle) return error.WrongMode;
                if (snapshot.owner != .battle_transition) return error.InconsistentOwner;
                if (transition.kind == .battle_block and transition.preset_index >= packet.battle.presets.len) return error.UnknownPreset;
                for (snapshot.mode.battle.timers) |timer| if (timer < 0) return error.InvalidTimer;
            },
            .field_push => {
                if (snapshot.mode != .field) return error.WrongMode;
                if (snapshot.owner != .field_event) return error.InconsistentOwner;
                const push = transition.push orelse return error.InvalidTransition;
                if (push.record_index >= packet.field.push.records.len) return error.UnknownPushRecord;
                if (push.frames_left == 0 or push.repeats_left == 0) return error.InvalidTransition;
            },
            .field_pan => {
                if (snapshot.mode != .field) return error.WrongMode;
                if (snapshot.owner != .field_event) return error.InconsistentOwner;
                const pan = transition.pan orelse return error.InvalidTransition;
                if (pan.horizontal_remaining < 0 or pan.vertical_remaining < 0) return error.InvalidTransition;
                if (pan.ticks_until_step == 0) return error.InvalidTransition;
            },
            .field_scroll => {
                if (snapshot.mode != .field) return error.WrongMode;
                if (snapshot.owner != .field_event) return error.InconsistentOwner;
                const scroll = transition.scroll orelse return error.InvalidTransition;
                if (scroll.remaining < 0) return error.InvalidTransition;
            },
        }
    } else {
        if (snapshot.owner == .battle_transition) return error.InconsistentOwner;
        if (snapshot.family == .field_scripted_push or snapshot.family == .field_scripted_pan or
            snapshot.family == .battle_transition or snapshot.family == .battle_actor_track)
            return error.InconsistentOwner;
    }
    return .{
        .owner = snapshot.owner,
        .family = snapshot.family,
        .projection_id = snapshot.projection_id,
        .projection = projection,
        .mode = snapshot.mode,
        .transition = snapshot.transition,
        .finish_owner = snapshot.finish_owner,
    };
}
