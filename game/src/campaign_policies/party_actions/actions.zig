//! Typed runtime data for the qualified ordinary party actions.
//!
//! The asset is derived by the extraction pipeline from the reviewed
//! ordinary-action contract and the reviewed scoped sprite-residency export.
//! This module never trusts the file's own numbers:
//! every named boundary is re-derived from the typed timeline and compared
//! before a record becomes executable.
//!
//! There are no PS1 addresses, LBAs, section offsets or original struct layouts
//! in the runtime packet.  Provenance is the two reviewed packet identities
//! pinned in `data.zig` (exact-file SHA-256 of the consumed assets plus their
//! reviewed commits).
//!
//! Parsing is strict: unknown fields, unknown event kinds and unknown enum tags
//! are rejected, so a forged operand block cannot be silently ignored.

const std = @import("std");
pub const data = @import("campaign_policies_data").party_actions;

pub const schema = "suikoden-ordinary-actions/1";
pub const record_count = 78;
pub const admitted_count = 74;
pub const art_gap_ids = [_][]const u8{ "humphrey", "kirke", "sonya" };
pub const reaction_blocked_id = "clive";
pub const max_timeline = 64;

pub const Track = enum { attack, auxiliary, @"return" };
pub const Consumer = enum { actor, coordinator, presentation };
pub const Phase = enum { coordinator, actor, presentation };
pub const Family = enum { melee, stationary_auxiliary, ranged_sequence };
pub const SourceStatus = enum { ready, mechanics_ready, blocked };
pub const BlockerKind = enum { art_gap, reaction_unresolved, unresolved };
pub const ResidencyStatus = enum { supported, blocked };
pub const SampleStatus = enum { supported, blocked };
pub const Trigger = enum { action_mask, actor_flag_clear };
pub const BoundaryOrigin = enum { dispatch, impact };
pub const ReactionRelease = enum { actor_flag_clear };
pub const AuxiliaryOwner = enum { self, linked_slot };
pub const CoordinatorOwned = enum { target_selection, hit, damage, target_reaction, round };

pub const Kind = enum {
    timer,
    animation_request,
    wait_animation,
    motion_jump,
    motion_long,
    wait_movement,
    auxiliary_spawn,
    set_action_mask,
    wait_action_mask,
    external_call,
    invoke_callback,
    set_compare_value,
    wait_compare_value,
    set_global_flag,
    clear_global_flag,
    set_secondary_flag,
    clear_secondary_flag,
    set_actor_flag,
    clear_actor_flag,
    screen_offset,
    teardown,
};

pub const Vec = struct { x: i32, y: i32, z: i32 };
pub const Frame = struct { pose: u16, ticks: u16 };

pub const Event = struct {
    tick: u16,
    track: Track,
    kind: Kind,
    consumer: Consumer,
    ticks: ?u16 = null,
    animation: ?u16 = null,
    duration: ?u16 = null,
    frames: ?[]const Frame = null,
    flag_byte: ?u16 = null,
    mode: ?i16 = null,
    mask: ?u16 = null,
    selector: ?u16 = null,
    value: ?u16 = null,
    id: ?u16 = null,
    flags: ?u16 = null,
    table_index: ?u16 = null,
    callback: ?u16 = null,
    offset: ?Vec = null,
    delta: ?Vec = null,
    x: ?i16 = null,
    y: ?i16 = null,
};

pub const Cue = struct { id: u16, tracks: []const Track };

pub const Blocker = struct {
    kind: BlockerKind,
    detail: []const u8,
    source_kinds: []const []const u8,
    poses: []const u16,
    opcodes: []const u16,
};

pub const SourceBlocker = struct {
    kind: []const u8,
    detail: ?[]const u8 = null,
    opcode: ?i16 = null,
    track: ?[]const u8 = null,
    pose: ?u16 = null,
    poses: ?[]const u16 = null,
    animations: ?[]const u16 = null,
};

pub const Reaction = struct {
    script_slot: u16,
    delay_ticks: ?u16 = null,
    resolved: bool,
    release: ReactionRelease,
};

pub const Auxiliary = struct {
    flags: u16,
    animation: u16,
    table_index: u16,
    offset: Vec,
    spawn_tick: u16,
    owner: AuxiliaryOwner,
    reuse_own_source: bool,
    secondary_draw_list: bool,
    source_position_from_owner: bool,
};

pub const Boundary = struct {
    from: BoundaryOrigin,
    ticks: u16,
    event_tick: ?u16 = null,
    consumer: ?Consumer = null,
    consumer_delay: ?u8 = null,
    trigger: ?Trigger = null,
    mask: ?u16 = null,
    track: ?Track = null,
    delay_ticks: ?u16 = null,
};

pub const Boundaries = struct {
    initial_command: Boundary,
    impact: ?Boundary = null,
    owner_ready: ?Boundary = null,
    return_release: ?Boundary = null,
    target_reaction: ?Boundary = null,
    auxiliary_spawn: ?Boundary = null,
    auxiliary_contact: ?Boundary = null,
    auxiliary_release: ?Boundary = null,
};

pub const Admission = struct {
    mechanics_complete: bool,
    reaction_resolved: bool,
    residency_qualified: bool,
    coordinator_owned: []const CoordinatorOwned,
};

pub const ResidencyAnimation = struct { index: u16, frames: []const Frame };
pub const Piece = struct {
    page: u16,
    u: i32,
    v: i32,
    width: i32,
    height: i32,
    palette: u16,
    flip_x: bool,
    flip_y: bool,
    outside_samples: i32,
    sample_status: SampleStatus,
};
pub const Pose = struct {
    index: u16,
    width: i32,
    height: i32,
    anchor: struct { x: i32, y: i32 },
    pieces: []const Piece,
};
pub const Page = struct { index: u16, sha256: []const u8 };
pub const Palette = struct { index: u16, words: u16, sha256: []const u8 };
pub const Residency = struct {
    status: ResidencyStatus,
    binding_sha256: []const u8,
    required_animations: []const u16,
    animations: []const ResidencyAnimation,
    poses: []const Pose,
    pages: []const Page,
    palettes: []const Palette,
};

pub const Record = struct {
    id: []const u8,
    family: Family,
    source_status: SourceStatus,
    admitted: bool,
    resource: []const u8,
    resource_sha256: []const u8,
    evidence_sha256: []const u8,
    timeline_complete: bool,
    reaction: Reaction,
    auxiliary: ?Auxiliary = null,
    audio_cues: []const Cue,
    timeline: []const Event,
    boundaries: Boundaries,
    admission: Admission,
    blocker: ?Blocker = null,
    residency: ?Residency = null,
    source_blockers: []const SourceBlocker,
};

pub const FamilyCounts = struct { melee: u16, stationary_auxiliary: u16, ranged_sequence: u16 };

pub const BlockedCoverage = struct {
    id: []const u8,
    family: Family,
    reason: BlockerKind,
    detail: []const u8,
    poses: []const u16,
    opcodes: []const u16,
};

pub const Coverage = struct {
    requested: u16,
    compiled: u16,
    admitted: u16,
    families: FamilyCounts,
    admitted_families: FamilyCounts,
    admitted_ids: []const []const u8,
    blocked: []const BlockedCoverage,
};

pub const Inputs = struct {
    party_actions_schema: []const u8,
    party_actions_asset_sha256: []const u8,
    party_actions_catalogue_file_sha256: []const u8,
    party_actions_catalogue_canonical_sha256: []const u8,
    sprite_residency_schema: []const u8,
    sprite_residency_scope: []const u8,
    sprite_residency_asset_sha256: []const u8,
    sprite_residency_manifest_sha256: []const u8,
    sprite_residency_proof_sha256: []const u8,
    hash_convention: []const u8,
};

pub const Convention = struct {
    clock: []const u8,
    origin: []const u8,
    origin_tick: u16,
    first_actor_update: u16,
    units: []const u8,
    event_tick: []const u8,
    boundary_tick: []const u8,
    update_phases: []const []const u8,
    consumer_delay: struct { actor: u8, coordinator: u8, presentation: u8 },
    track_order: []const []const u8,
    reaction_origin: []const u8,
    world_offset_units: []const u8,
    delta_units: []const u8,
};

pub const Content = struct {
    schema: []const u8,
    inputs: Inputs,
    convention: Convention,
    coverage: Coverage,
    records: []const Record,
};

pub const ParseError = error{
    ContentMismatch,
    InvalidSchema,
    InvalidInputPin,
    InvalidConvention,
    InvalidCoverage,
    InvalidRecord,
    InvalidBoundary,
    InvalidEventOperand,
    UnknownEventKind,
    InvalidResidency,
    FalseComplete,
    MissingBlocker,
} || std.mem.Allocator.Error || std.json.ParseError(std.json.Scanner);

/// Exact-file digest check for the embedded runtime packet.
pub fn verifyAssetDigest(bytes: []const u8) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, data.asset_sha256)) return error.ContentMismatch;
}

pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Content) {
    try verifyAssetDigest(bytes);
    const parsed = try std.json.parseFromSlice(Content, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    try validate(&parsed.value);
    return parsed;
}

pub fn loadEmbedded(allocator: std.mem.Allocator) !std.json.Parsed(Content) {
    return load(allocator, data.json);
}

fn hexDigest(bytes: []const u8) bool {
    if (bytes.len != 64) return false;
    for (bytes) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn checkInputs(inputs: Inputs) !void {
    if (!eq(inputs.party_actions_schema, "suikoden-party-action-contracts/2") or
        !eq(inputs.party_actions_asset_sha256, data.party_actions_asset_sha256) or
        !eq(inputs.sprite_residency_schema, "suikoden-battle-sprite-residency/3") or
        !eq(inputs.sprite_residency_scope, "initialization_and_ordinary_attack_return") or
        !eq(inputs.sprite_residency_manifest_sha256, data.sprite_residency_manifest_sha256) or
        !eq(inputs.sprite_residency_proof_sha256, data.sprite_residency_proof_sha256) or
        !eq(inputs.sprite_residency_asset_sha256, data.sprite_residency_asset_sha256)) return error.InvalidInputPin;
    if (!hexDigest(inputs.party_actions_asset_sha256) or !hexDigest(inputs.party_actions_catalogue_file_sha256) or
        !hexDigest(inputs.party_actions_catalogue_canonical_sha256) or !hexDigest(inputs.sprite_residency_asset_sha256) or
        !hexDigest(inputs.sprite_residency_manifest_sha256) or !hexDigest(inputs.sprite_residency_proof_sha256)) return error.InvalidInputPin;
    if (inputs.hash_convention.len == 0) return error.InvalidInputPin;
}

fn checkConvention(c: Convention) !void {
    if (!eq(c.clock, "actor_updates") or !eq(c.origin, "ordinary_attack_dispatch") or
        c.origin_tick != 0 or c.first_actor_update != 1) return error.InvalidConvention;
    if (c.consumer_delay.actor != 0 or c.consumer_delay.coordinator != 1 or
        c.consumer_delay.presentation != 0) return error.InvalidConvention;
    if (c.update_phases.len != 3 or c.track_order.len != 3) return error.InvalidConvention;
    const phases = [_][]const u8{ "coordinator", "actors", "presentation" };
    for (c.update_phases, phases) |actual, expected| if (!eq(actual, expected)) return error.InvalidConvention;
    const tracks = [_][]const u8{ "attack", "auxiliary", "return" };
    for (c.track_order, tracks) |actual, expected| if (!eq(actual, expected)) return error.InvalidConvention;
    if (!eq(c.reaction_origin, "impact") or c.units.len == 0 or c.world_offset_units.len == 0 or
        c.delta_units.len == 0 or c.event_tick.len == 0 or c.boundary_tick.len == 0) return error.InvalidConvention;
}

// ---------------------------------------------------------------------------
// Timeline operand typing
// ---------------------------------------------------------------------------

const Operand = enum {
    ticks,
    animation,
    duration,
    frames,
    flag_byte,
    mode,
    mask,
    selector,
    value,
    id,
    flags,
    table_index,
    callback,
    offset,
    delta,
    x,
    y,
};

fn bit(operand: Operand) u32 {
    return @as(u32, 1) << @backingInt(operand);
}

fn expectedOperands(kind: Kind) u32 {
    return switch (kind) {
        .timer => bit(.ticks),
        .animation_request => bit(.animation) | bit(.duration) | bit(.frames) | bit(.flag_byte),
        .wait_animation => bit(.animation),
        .motion_jump => bit(.mode) | bit(.duration) | bit(.offset) | bit(.delta),
        .motion_long => bit(.mode) | bit(.duration) | bit(.offset),
        .wait_movement, .teardown => 0,
        .auxiliary_spawn => bit(.flags) | bit(.animation) | bit(.table_index) | bit(.offset),
        .set_action_mask, .wait_action_mask => bit(.mode) | bit(.mask),
        .external_call => bit(.id),
        .invoke_callback => bit(.mode) | bit(.callback),
        .set_compare_value, .wait_compare_value => bit(.value),
        .set_global_flag, .clear_global_flag => bit(.selector),
        .set_secondary_flag, .clear_secondary_flag => bit(.mask),
        .set_actor_flag, .clear_actor_flag => bit(.mode) | bit(.mask),
        .screen_offset => bit(.mode) | bit(.x) | bit(.y),
    };
}

fn presentOperands(event: Event) u32 {
    var mask: u32 = 0;
    if (event.ticks != null) mask |= bit(.ticks);
    if (event.animation != null) mask |= bit(.animation);
    if (event.duration != null) mask |= bit(.duration);
    if (event.frames != null) mask |= bit(.frames);
    if (event.flag_byte != null) mask |= bit(.flag_byte);
    if (event.mode != null) mask |= bit(.mode);
    if (event.mask != null) mask |= bit(.mask);
    if (event.selector != null) mask |= bit(.selector);
    if (event.value != null) mask |= bit(.value);
    if (event.id != null) mask |= bit(.id);
    if (event.flags != null) mask |= bit(.flags);
    if (event.table_index != null) mask |= bit(.table_index);
    if (event.callback != null) mask |= bit(.callback);
    if (event.offset != null) mask |= bit(.offset);
    if (event.delta != null) mask |= bit(.delta);
    if (event.x != null) mask |= bit(.x);
    if (event.y != null) mask |= bit(.y);
    return mask;
}

fn expectedConsumer(kind: Kind) Consumer {
    return switch (kind) {
        .timer, .wait_animation, .motion_jump, .motion_long, .wait_movement, .auxiliary_spawn, .invoke_callback, .set_compare_value, .wait_compare_value, .set_secondary_flag, .clear_secondary_flag, .screen_offset, .teardown => .actor,
        .set_action_mask, .wait_action_mask, .set_global_flag, .clear_global_flag => .coordinator,
        .animation_request, .external_call, .set_actor_flag, .clear_actor_flag => .presentation,
    };
}

pub fn trackRank(track: Track) u8 {
    return @backingInt(track);
}

pub fn validateEvent(event: Event) !void {
    if (event.tick < 1) return error.InvalidEventOperand;
    if (event.consumer != expectedConsumer(event.kind)) return error.InvalidEventOperand;
    if (presentOperands(event) != expectedOperands(event.kind)) return error.InvalidEventOperand;
    switch (event.kind) {
        .timer => if (event.ticks.? == 0) return error.InvalidEventOperand,
        .animation_request => {
            if (event.duration.? == 0) return error.InvalidEventOperand;
            const frames = event.frames.?;
            if (frames.len == 0) return error.InvalidEventOperand;
            var total: u32 = 0;
            for (frames) |frame| {
                if (frame.ticks == 0 or frame.ticks > 256) return error.InvalidEventOperand;
                total += frame.ticks;
            }
            if (total != event.duration.?) return error.InvalidEventOperand;
            if (event.flag_byte.? & ~@as(u16, 0x3) != 0) return error.InvalidEventOperand;
        },
        .motion_jump, .motion_long => {
            if (event.mode.? < 0 or event.mode.? > 3) return error.InvalidEventOperand;
            if (event.duration.? == 0) return error.InvalidEventOperand;
        },
        .auxiliary_spawn => {
            if (event.flags.? & 0xFFF0 != 0) return error.InvalidEventOperand;
            if (event.animation.? >= 64 or event.table_index.? >= 32) return error.InvalidEventOperand;
        },
        .set_action_mask, .wait_action_mask, .set_actor_flag, .clear_actor_flag => {
            if (event.mode.? < 0 or event.mode.? > 1) return error.InvalidEventOperand;
            if (event.mask.? == 0) return error.InvalidEventOperand;
        },
        .external_call => if (event.id.? < 1292 or event.id.? > 1302) return error.InvalidEventOperand,
        .invoke_callback => {
            if (event.mode.? != 0) return error.InvalidEventOperand;
            if (event.callback.? != 1 and event.callback.? != 2) return error.InvalidEventOperand;
        },
        .set_global_flag, .clear_global_flag => if (event.selector.? >= 32) return error.InvalidEventOperand,
        .set_secondary_flag, .clear_secondary_flag => if (event.mask.? == 0) return error.InvalidEventOperand,
        .screen_offset => if (event.mode.? < 0 or event.mode.? > 2) return error.InvalidEventOperand,
        else => {},
    }
}

fn checkTimeline(record: Record) !void {
    if (record.timeline.len > max_timeline) return error.InvalidRecord;
    var previous_tick: u16 = 0;
    var previous_rank: u8 = 0;
    for (record.timeline, 0..) |event, index| {
        try validateEvent(event);
        if (index > 0) {
            if (event.tick < previous_tick) return error.InvalidRecord;
            if (event.tick == previous_tick and trackRank(event.track) < previous_rank) return error.InvalidRecord;
        }
        previous_tick = event.tick;
        previous_rank = trackRank(event.track);
    }
}

// ---------------------------------------------------------------------------
// Boundary re-derivation
// ---------------------------------------------------------------------------

fn findEvent(timeline: []const Event, kind: Kind, mask: ?u16) ?*const Event {
    for (timeline) |*event| {
        if (event.kind != kind) continue;
        if (mask) |value| if (event.mask == null or event.mask.? != value) continue;
        return event;
    }
    return null;
}

fn countEvents(timeline: []const Event, kind: Kind) usize {
    var total: usize = 0;
    for (timeline) |event| if (event.kind == kind) {
        total += 1;
    };
    return total;
}

fn expectBoundary(actual: Boundary, from: BoundaryOrigin, ticks: u16, event_tick: ?u16, consumer: ?Consumer, delay: ?u8, trigger: ?Trigger, mask: ?u16, track: ?Track, delay_ticks: ?u16) !void {
    if (actual.from != from or actual.ticks != ticks or actual.event_tick != event_tick or
        actual.consumer != consumer or actual.consumer_delay != delay or
        actual.trigger != trigger or actual.mask != mask or actual.track != track or
        actual.delay_ticks != delay_ticks) return error.InvalidBoundary;
}

pub fn rederive(content: Content, record: Record) !Boundaries {
    _ = content;
    const timeline = record.timeline;
    if (timeline.len == 0) {
        try expectBoundary(record.boundaries.initial_command, .dispatch, 0, 0, .actor, 0, null, null, null, null);
        if (record.boundaries.impact != null or record.boundaries.owner_ready != null or
            record.boundaries.return_release != null or record.boundaries.target_reaction != null or
            record.boundaries.auxiliary_spawn != null or record.boundaries.auxiliary_contact != null or
            record.boundaries.auxiliary_release != null) return error.InvalidBoundary;
        return record.boundaries;
    }
    const mask2 = findEvent(timeline, .set_action_mask, 2) orelse return error.InvalidBoundary;
    const mask4 = findEvent(timeline, .set_action_mask, 4) orelse return error.InvalidBoundary;
    const flag1 = findEvent(timeline, .clear_actor_flag, 1) orelse return error.InvalidBoundary;
    const impact_tick = mask2.tick + 1;
    try expectBoundary(record.boundaries.initial_command, .dispatch, 0, 0, .actor, 0, null, null, null, null);
    try expectBoundary(record.boundaries.impact.?, .dispatch, impact_tick, mask2.tick, .coordinator, 1, .action_mask, 2, mask2.track, null);
    try expectBoundary(record.boundaries.owner_ready.?, .dispatch, mask4.tick + 1, mask4.tick, .coordinator, 1, .action_mask, 4, mask4.track, null);
    try expectBoundary(record.boundaries.return_release.?, .dispatch, flag1.tick, flag1.tick, .presentation, 0, .actor_flag_clear, 1, null, null);
    const delay = record.reaction.delay_ticks orelse return error.InvalidBoundary;
    try expectBoundary(record.boundaries.target_reaction.?, .impact, impact_tick + delay, null, .coordinator, 0, null, null, null, delay);
    if (record.auxiliary) |auxiliary| {
        const spawn = findEvent(timeline, .auxiliary_spawn, null) orelse return error.InvalidBoundary;
        const teardown = findEvent(timeline, .teardown, null) orelse return error.InvalidBoundary;
        try expectBoundary(record.boundaries.auxiliary_spawn.?, .dispatch, spawn.tick, spawn.tick, .actor, 0, null, null, null, null);
        try expectBoundary(record.boundaries.auxiliary_contact.?, .dispatch, impact_tick, mask2.tick, .coordinator, 1, .action_mask, 2, mask2.track, null);
        try expectBoundary(record.boundaries.auxiliary_release.?, .dispatch, teardown.tick, teardown.tick, .actor, 0, null, null, null, null);
        if (auxiliary.spawn_tick != spawn.tick) return error.InvalidBoundary;
    } else if (record.boundaries.auxiliary_spawn != null or record.boundaries.auxiliary_contact != null or
        record.boundaries.auxiliary_release != null) return error.InvalidBoundary;
    return record.boundaries;
}

// ---------------------------------------------------------------------------
// Record / residency validation
// ---------------------------------------------------------------------------

fn pagePresent(residency: Residency, index: u16) bool {
    for (residency.pages) |page| if (page.index == index) return true;
    return false;
}
fn palettePresent(residency: Residency, index: u16) bool {
    for (residency.palettes) |palette| if (palette.index == index) return true;
    return false;
}
fn posePresent(residency: Residency, index: u16) bool {
    for (residency.poses) |pose| if (pose.index == index) return true;
    return false;
}
fn animationFor(residency: Residency, index: u16) ?ResidencyAnimation {
    for (residency.animations) |animation| if (animation.index == index) return animation;
    return null;
}

fn checkResidency(record: Record) !void {
    const residency = record.residency orelse return error.InvalidResidency;
    if (!hexDigest(residency.binding_sha256)) return error.InvalidResidency;
    if (residency.status != .supported) return error.FalseComplete;
    if (residency.required_animations.len == 0) return error.InvalidResidency;
    var previous: u16 = 0;
    for (residency.required_animations, 0..) |value, index| {
        if (index > 0 and value <= previous) return error.InvalidResidency;
        previous = value;
    }
    previous = 0;
    for (residency.animations, 0..) |animation, index| {
        if (index > 0 and animation.index <= previous) return error.InvalidResidency;
        if (std.mem.indexOfScalar(u16, residency.required_animations, animation.index) == null) return error.InvalidResidency;
        if (animation.frames.len == 0) return error.InvalidResidency;
        for (animation.frames) |frame| {
            if (frame.ticks == 0 or frame.ticks > 256) return error.InvalidResidency;
            if (!posePresent(residency, frame.pose)) return error.InvalidResidency;
        }
        previous = animation.index;
    }
    previous = 0;
    for (residency.pages, 0..) |page, index| {
        if (index > 0 and page.index <= previous) return error.InvalidResidency;
        if (!hexDigest(page.sha256)) return error.InvalidResidency;
        previous = page.index;
    }
    previous = 0;
    for (residency.palettes, 0..) |palette, index| {
        if (index > 0 and palette.index <= previous) return error.InvalidResidency;
        if (!hexDigest(palette.sha256)) return error.InvalidResidency;
        if (palette.words != 32 and palette.words != 256) return error.InvalidResidency;
        previous = palette.index;
    }
    previous = 0;
    for (residency.poses, 0..) |pose, index| {
        if (index > 0 and pose.index <= previous) return error.InvalidResidency;
        previous = pose.index;
        if (pose.width <= 0 or pose.height <= 0 or pose.pieces.len == 0) return error.InvalidResidency;
        if (pose.anchor.x < 0 or pose.anchor.y < 0) return error.InvalidResidency;
        for (pose.pieces) |piece| {
            if (piece.width <= 0 or piece.height <= 0) return error.InvalidResidency;
            if (piece.u < 0 or piece.v < 0 or piece.u > 127 or piece.v > 127) return error.InvalidResidency;
            if (!pagePresent(residency, piece.page)) return error.InvalidResidency;
            if (!palettePresent(residency, piece.palette)) return error.InvalidResidency;
            if (piece.outside_samples != 0 or piece.sample_status != .supported) return error.InvalidResidency;
        }
    }
    for (record.timeline) |event| {
        if (event.kind != .animation_request) continue;
        const bound = animationFor(residency, event.animation.?) orelse return error.InvalidResidency;
        if (bound.frames.len != event.frames.?.len) return error.InvalidResidency;
        for (bound.frames, event.frames.?) |left, right| {
            if (left.pose != right.pose or left.ticks != right.ticks) return error.InvalidResidency;
        }
    }
    if (record.auxiliary) |auxiliary| {
        if (animationFor(residency, auxiliary.animation) == null) return error.InvalidResidency;
        if (auxiliary.flags & 0xFFF0 != 0) return error.InvalidResidency;
        if (auxiliary.reuse_own_source != (auxiliary.flags & 1 != 0) or
            auxiliary.secondary_draw_list != (auxiliary.flags & 2 != 0) or
            auxiliary.source_position_from_owner != (auxiliary.flags & 8 != 0)) return error.InvalidResidency;
        if (auxiliary.owner != .self) return error.InvalidResidency;
        if (auxiliary.table_index >= 32 or auxiliary.animation >= 64) return error.InvalidResidency;
    }
}

fn checkCues(record: Record) !void {
    var previous: u16 = 0;
    for (record.audio_cues, 0..) |cue, index| {
        if (cue.id < 1292 or cue.id > 1302) return error.InvalidRecord;
        if (index > 0 and cue.id <= previous) return error.InvalidRecord;
        previous = cue.id;
        if (cue.tracks.len == 0) return error.InvalidRecord;
        var previous_rank: u8 = 0;
        for (cue.tracks, 0..) |track, track_index| {
            if (track_index > 0 and trackRank(track) <= previous_rank) return error.InvalidRecord;
            previous_rank = trackRank(track);
        }
    }
    for (record.timeline) |event| if (event.kind == .external_call) {
        var bound = false;
        for (record.audio_cues) |cue| if (cue.id == event.id.?) {
            bound = true;
        };
        if (!bound) return error.InvalidRecord;
    };
    for (record.audio_cues) |cue| {
        var emitted = false;
        for (record.timeline) |event| if (event.kind == .external_call and event.id.? == cue.id) {
            emitted = true;
        };
        if (!emitted) return error.InvalidRecord;
    }
}

fn checkTail(record: Record) !void {
    const release = record.boundaries.return_release orelse return;
    var index: usize = 0;
    while (index < record.timeline.len and record.timeline[index].tick <= release.event_tick.?) : (index += 1) {}
    const tail = record.timeline[index..];
    if (tail.len == 0) return;
    if (tail.len != 2) return error.InvalidRecord;
    if (tail[0].kind != .wait_animation or tail[1].kind != .set_secondary_flag) return error.InvalidRecord;
    if (tail[1].mask.? != 2 or tail[0].tick != tail[1].tick) return error.InvalidRecord;
    if (tail[0].tick <= release.event_tick.?) return error.InvalidRecord;
}

fn checkRecord(record: Record, content: Content) !void {
    if (record.id.len == 0 or record.resource.len == 0) return error.InvalidRecord;
    if (!hexDigest(record.resource_sha256) or !hexDigest(record.evidence_sha256)) return error.InvalidRecord;
    try checkTimeline(record);
    try checkTail(record);
    try checkCues(record);
    if (record.reaction.script_slot != 2) return error.InvalidRecord;
    const expected_admitted = record.source_status == .ready;
    if (record.admitted != expected_admitted) return error.FalseComplete;
    switch (record.source_status) {
        .ready => {
            if (record.blocker != null or record.residency == null) return error.FalseComplete;
            if (record.source_blockers.len != 0) return error.FalseComplete;
            if (!record.timeline_complete or !record.admission.mechanics_complete or
                !record.admission.reaction_resolved or !record.admission.residency_qualified or
                !record.reaction.resolved) return error.FalseComplete;
            if (record.boundaries.impact == null or record.boundaries.owner_ready == null or
                record.boundaries.return_release == null or record.boundaries.target_reaction == null) return error.FalseComplete;
            if (record.residency.?.status != .supported) return error.FalseComplete;
            if (record.blocker != null) return error.FalseComplete;
        },
        .mechanics_ready => {
            if (record.admitted or record.residency != null or record.blocker == null) return error.FalseComplete;
            if (record.blocker.?.kind != .art_gap) return error.InvalidRecord;
            if (record.blocker.?.poses.len == 0) return error.MissingBlocker;
            if (!record.timeline_complete or !record.admission.mechanics_complete or
                !record.admission.reaction_resolved or record.admission.residency_qualified) return error.FalseComplete;
        },
        .blocked => {
            if (record.admitted or record.residency != null or record.blocker == null) return error.FalseComplete;
            if (record.blocker.?.kind != .reaction_unresolved) return error.InvalidRecord;
            if (record.reaction.resolved or record.reaction.delay_ticks != null or record.timeline_complete) return error.FalseComplete;
            if (record.timeline.len != 0) return error.InvalidRecord;
            if (record.blocker.?.opcodes.len == 0) return error.MissingBlocker;
            if (record.admission.mechanics_complete) return error.FalseComplete;
        },
    }
    const rederived = try rederive(content, record);
    if (record.admitted) {
        try checkResidency(record);
        if (record.auxiliary) |auxiliary| {
            if (rederived.auxiliary_contact == null or rederived.auxiliary_spawn == null or
                rederived.auxiliary_release == null) return error.InvalidBoundary;
            if (auxiliary.spawn_tick != rederived.auxiliary_spawn.?.ticks) return error.InvalidBoundary;
        } else {
            if (rederived.auxiliary_spawn != null or rederived.auxiliary_contact != null or
                rederived.auxiliary_release != null) return error.InvalidBoundary;
        }
    }
    if (record.blocker) |blocker| {
        if (blocker.detail.len == 0 or blocker.source_kinds.len == 0) return error.MissingBlocker;
    }
}

fn familyCount(records: []const Record, family: Family) u16 {
    var total: u16 = 0;
    for (records) |record| if (record.family == family) {
        total += 1;
    };
    return total;
}

fn admittedFamilyCount(records: []const Record, family: Family) u16 {
    var total: u16 = 0;
    for (records) |record| if (record.family == family and record.admitted) {
        total += 1;
    };
    return total;
}

fn isArtGap(id: []const u8) bool {
    for (art_gap_ids) |name| if (eq(name, id)) return true;
    return false;
}

fn membership(list: []const []const u8, id: []const u8) usize {
    var total: usize = 0;
    for (list) |name| if (eq(name, id)) {
        total += 1;
    };
    return total;
}

fn checkCoverage(content: Content) !void {
    const coverage = content.coverage;
    if (coverage.requested != record_count or coverage.compiled != record_count or coverage.admitted != admitted_count) return error.InvalidCoverage;
    if (coverage.families.melee != 59 or coverage.families.stationary_auxiliary != 18 or
        coverage.families.ranged_sequence != 1) return error.InvalidCoverage;
    if (coverage.admitted_families.melee != 56 or coverage.admitted_families.stationary_auxiliary != 18 or
        coverage.admitted_families.ranged_sequence != 0) return error.InvalidCoverage;
    if (coverage.admitted_ids.len != admitted_count) return error.InvalidCoverage;
    if (coverage.blocked.len != 4) return error.InvalidCoverage;
    if (!eq(coverage.blocked[0].id, "clive") and !eq(coverage.blocked[1].id, "clive") and
        !eq(coverage.blocked[2].id, "clive") and !eq(coverage.blocked[3].id, "clive")) return error.InvalidCoverage;
    var art_gaps: usize = 0;
    for (coverage.blocked) |blocked| {
        const blocked_record = for (content.records) |record| {
            if (eq(record.id, blocked.id)) break record;
        } else return error.InvalidCoverage;
        if (blocked.family != blocked_record.family) return error.InvalidCoverage;
        if (blocked.reason != blocked_record.blocker.?.kind) return error.InvalidCoverage;
        switch (blocked.reason) {
            .art_gap => {
                art_gaps += 1;
                if (!isArtGap(blocked.id)) return error.InvalidCoverage;
                if (blocked.poses.len == 0) return error.InvalidCoverage;
            },
            .reaction_unresolved => {
                if (!eq(blocked.id, reaction_blocked_id)) return error.InvalidCoverage;
                if (std.mem.indexOfScalar(u16, blocked.opcodes, 42) == null) return error.InvalidCoverage;
            },
            .unresolved => return error.InvalidCoverage,
        }
    }
    if (art_gaps != art_gap_ids.len) return error.InvalidCoverage;
    var admitted_total: u16 = 0;
    var blocked_total: u16 = 0;
    for (content.records) |record| {
        if (record.admitted) {
            admitted_total += 1;
            if (membership(coverage.admitted_ids, record.id) != 1) return error.InvalidCoverage;
        } else {
            blocked_total += 1;
            if (membership(coverage.admitted_ids, record.id) != 0) return error.InvalidCoverage;
            var listed = false;
            for (coverage.blocked) |blocked| if (eq(blocked.id, record.id)) {
                listed = true;
            };
            if (!listed) return error.InvalidCoverage;
        }
    }
    if (admitted_total != admitted_count or blocked_total != 4) return error.InvalidCoverage;
}

pub fn validate(content: *const Content) !void {
    if (!eq(content.schema, schema)) return error.InvalidSchema;
    try checkInputs(content.inputs);
    try checkConvention(content.convention);
    if (content.records.len != record_count) return error.InvalidCoverage;
    for (content.records, 0..) |record, index| {
        for (content.records[0..index]) |other| if (eq(other.id, record.id)) return error.InvalidRecord;
        try checkRecord(record, content.*);
    }
    try checkCoverage(content.*);
    if (familyCount(content.records, .melee) != content.coverage.families.melee or
        familyCount(content.records, .stationary_auxiliary) != content.coverage.families.stationary_auxiliary or
        familyCount(content.records, .ranged_sequence) != content.coverage.families.ranged_sequence) return error.InvalidCoverage;
    if (admittedFamilyCount(content.records, .melee) != content.coverage.admitted_families.melee or
        admittedFamilyCount(content.records, .stationary_auxiliary) != content.coverage.admitted_families.stationary_auxiliary or
        admittedFamilyCount(content.records, .ranged_sequence) != content.coverage.admitted_families.ranged_sequence) return error.InvalidCoverage;
}

pub fn lookup(content: Content, id: []const u8) !usize {
    for (content.records, 0..) |record, index| if (eq(record.id, id)) return index;
    return error.UnknownRecord;
}

pub fn recordAt(content: Content, index: usize) *const Record {
    return &content.records[index];
}

/// True when every named action clock and the resident art are usable.
pub fn executable(record: Record) bool {
    return record.admitted and record.source_status == .ready and
        record.residency != null and record.residency.?.status == .supported and
        record.admission.mechanics_complete and record.admission.reaction_resolved and
        record.admission.residency_qualified and record.reaction.resolved and
        record.reaction.delay_ticks != null and record.timeline_complete and
        record.boundaries.impact != null and record.boundaries.owner_ready != null and
        record.boundaries.return_release != null and record.boundaries.target_reaction != null;
}

// ---------------------------------------------------------------------------
// Same-source residency sampling (scoped residency)
// ---------------------------------------------------------------------------

pub const SamplePlan = struct {
    pose: u16,
    piece: usize,
    page: u16,
    u: i32,
    v: i32,
    width: i32,
    height: i32,
    palette: u16,
    flip_x: bool,
    flip_y: bool,
    crosses_page: bool,
};

/// Resolve one draw piece of one resident pose.  The plan is only produced for
/// an executable record whose page/palette hashes came from the scoped residency
/// export; a blocked record cannot be sampled and an unresolved piece sample is
/// refused instead of clamped.
pub fn samplingPlan(record: Record, pose_index: u16, piece_index: usize) !SamplePlan {
    if (!executable(record)) return error.RecordBlocked;
    const residency = record.residency.?;
    const pose = for (residency.poses) |entry| {
        if (entry.index == pose_index) break entry;
    } else return error.UnknownPose;
    if (piece_index >= pose.pieces.len) return error.UnknownPiece;
    const piece = pose.pieces[piece_index];
    if (piece.outside_samples != 0 or piece.sample_status != .supported) return error.UnresolvedSample;
    if (!pagePresent(residency, piece.page)) return error.MissingResidentPage;
    if (!palettePresent(residency, piece.palette)) return error.MissingPalette;
    return .{
        .pose = pose_index,
        .piece = piece_index,
        .page = piece.page,
        .u = piece.u,
        .v = piece.v,
        .width = piece.width,
        .height = piece.height,
        .palette = piece.palette,
        .flip_x = piece.flip_x,
        .flip_y = piece.flip_y,
        .crosses_page = piece.u + piece.width > 128,
    };
}

/// Frames of one resident animation; the timeline only names resident clips.
pub fn animationFrames(record: Record, animation: u16) ![]const Frame {
    if (!executable(record)) return error.RecordBlocked;
    for (record.residency.?.animations) |entry| {
        if (entry.index == animation) return entry.frames;
    }
    return error.UnknownAnimation;
}
