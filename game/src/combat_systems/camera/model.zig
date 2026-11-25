//! Runtime data types.
//!
//! Generated data lives in the embedded campaign asset
//! and is embedded by `root.zig`.  Everything here is semantic: units are
//! named in the fields, no RAM address or pointer arithmetic is carried into
//! runtime state.

const std = @import("std");

pub const schema = "suikoden-combat-camera-model/1";

pub const Owner = enum { field_player, field_event, battle_frame, battle_transition, load };

pub const Vec3 = struct { x: i32, y: i32, z: i32 };

pub const Block = struct {
    position: Vec3,
    angles: Vec3,
    translation: Vec3,
    scale: Vec3,
};

pub const Source = struct {
    commit: []const u8,
    main_exe: []const u8,
    main_base: []const u8,
    main_sha256: []const u8,
    main_size: usize,
};

pub const Units = struct {
    frame: []const u8,
    field_cell_px: i32,
    section_cell_px: i32,
    field_offset: []const u8,
    battle_block: []const u8,
    battle_angle: []const u8,
    screen_px: []const u8,
};

pub const ProjectionDef = struct {
    id: []const u8,
    kind: []const u8,
    viewport_width_px: ?i32 = null,
    viewport_height_px: ?i32 = null,
    origin: ?[]const u8 = null,
    pixel_scale: ?i32 = null,
    focal_length_px: ?i32 = null,
    center_x_px: ?i32 = null,
    center_y_px: ?i32 = null,
    gte_ofx: ?i32 = null,
    gte_ofy: ?i32 = null,
    depth_axis: ?[]const u8 = null,
    depth_min: ?i32 = null,
    rule: ?[]const u8 = null,
    source: ?[]const u8 = null,
};

pub const FamilyDef = struct {
    id: []const u8,
    owner: []const u8,
    projection: []const u8,
    finish_owner: []const u8,
};

pub const EntryDef = struct {
    focus_unit: []const u8,
    cell_shift: u5,
    x_subtract_px: i32,
    y_subtract_px: i32,
    clamp_x: []const u8,
    clamp_y: []const u8,
    source: []const u8,
};

pub const TrackDef = struct {
    focus_fields: []const u8,
    offset_fields: []const u8,
    formula: []const u8,
    owner: []const u8,
};

pub const PushRecord = struct {
    index: u8,
    dx: i8,
    dy: i8,
    xmul: u8,
    ymul: u8,
    frames: u8,
};

pub const PushDef = struct {
    record_stride_bytes: u8,
    record_count: u8,
    records: []const PushRecord,
    repeat_rule: []const u8,
    offset_rule: []const u8,
};

pub const PanDef = struct {
    step_interval_ticks: u16,
    order: []const u8,
    horizontal_parameters: struct { right: u8, left: u8 },
    vertical_codes: struct { up: u8, down: u8 },
    parameter_to_code: []const []const u8,
    focus_deltas: []const [2]i32,
    owner: []const u8,
};

pub const ScrollDef = struct {
    set_x: []const u8,
    set_y: []const u8,
    direct: []const u8,
    deltas: struct { x: [4]i32, y: [4]i32 },
};

pub const FieldDef = struct {
    entry: EntryDef,
    track: TrackDef,
    push: PushDef,
    pan: PanDef,
    scroll: ScrollDef,
};

pub const BlockDef = struct {
    position: [3]i32,
    angles: [3]i32,
    translation: [3]i32,
    scale: [3]i32,
};

pub const CallSite = struct {
    site: []const u8,
    frames: u16,
    role: []const u8,
};

pub const PresetDef = struct {
    id: []const u8,
    address: []const u8,
    raw: [12]i32,
    block: BlockDef,
    call_sites: []const CallSite,
};

pub const SetupDef = struct {
    routine: []const u8,
    frames: []const u8,
    copy: []const u8,
    timer_offsets: [4]u16,
    delta_offsets: [4]u16,
    delta_rule: []const u8,
    tick_rule: []const u8,
    settle: []const u8,
};

pub const BattleScrollDef = struct {
    rule: []const u8,
    position_role: []const u8,
    translation_role: []const u8,
    screen_rule: []const u8,
};

pub const ActorTrackDef = struct {
    routine: []const u8,
    frames: u16,
    template_raw: [12]i32,
    translation: []const u8,
    position: []const u8,
    angles: [3]i32,
    scale: [3]i32,
};

pub const BattleDef = struct {
    block_layout: struct {
        position: [3]u8,
        angles: [3]u8,
        translation: [3]u8,
        scale: [3]u8,
    },
    presets: []const PresetDef,
    setup: SetupDef,
    scroll: BattleScrollDef,
    actor_track: ActorTrackDef,
};

pub const BlockerDef = struct {
    code: []const u8,
    detail: []const u8,
};

pub const Packet = struct {
    schema: []const u8,
    source: Source,
    units: Units,
    projections: []const ProjectionDef,
    families: []const FamilyDef,
    field: FieldDef,
    battle: BattleDef,
    ownership: ?std.json.Value = null,
    blockers: []const BlockerDef,
    coverage: ?std.json.Value = null,
    consumer_contract: []const []const u8,
};

pub fn load(allocator: std.mem.Allocator, json_text: []const u8) !std.json.Parsed(Packet) {
    return std.json.parseFromSlice(Packet, allocator, json_text, .{ .ignore_unknown_fields = true });
}
