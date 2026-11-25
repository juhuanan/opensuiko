//! Typed loader and validator for the action-application catalogue.
//!
//! The packet is names-only: no PS1 address, LBA, file offset or pointer
//! arithmetic is carried into runtime data.  Every operand that the source
//! action VM applies to an actor record is present here as a named field with
//! an explicit unit, and every family invariant is re-checked on load so a
//! packet drift is a refusal instead of a silently defaulted action.

const std = @import("std");

pub const schema = "suikoden-battle-action-application/1";
pub const max_records = 24;
pub const max_projectiles = 4;
pub const max_animations = 16;
pub const max_timers = 8;
pub const max_masks = 8;
pub const max_masks_cleared = 4;
pub const max_dodges = 6;
pub const max_tick = 4096;

pub const Offset = struct { x: i16, y: i16, z: i16 };

pub const Flags = struct {
    reuse_own_source: bool,
    secondary_draw_list: bool,
    owner_is_linked_slot: bool,
    source_position_from_owner: bool,
};

pub const Spawn = struct {
    tick: u16,
    flags: u8,
    bits: Flags,
    animation: u16,
    script_slot: u16,
    offset: Offset,
    source: []const u8,
    draw_list: []const u8,
    owner: []const u8,
    position_reference: []const u8,
};

pub const Compare = struct {
    set_tick: u16,
    set_value: u16,
    invoke_tick: u16,
    after_invoke: u16,
};

pub const Callback = struct {
    tick: u16,
    mode: u16,
    id: u16,
    compare: Compare,
    wait: struct { tick: u16, value: u16 },
};

pub const Contact = struct {
    write_tick: u16,
    mask: u8,
    from: []const u8,
    to: []const u8,
    observe_tick: u16,
};

pub const Motion = struct {
    tick: u16,
    mode: i16,
    duration: u16,
    offset: Offset,
    translation: bool = false,
};

pub const Timer = struct { tick: u16, ticks: u16 };
pub const MaskWrite = struct { tick: u16, mask: u8, target: []const u8 };

pub const Auxiliary = struct {
    motion: Motion,
    timers: []const Timer,
    masks: []const MaskWrite,
    waits_for_movement: u16,
    release: struct { tick: u16, release_path: []const u8 },
};

pub const ReturnMotion = struct {
    tick: u16,
    mode: i16,
    duration: u16,
    offset: Offset,
    delta: Offset,
};

pub const Return = struct {
    start_tick: u16,
    global_flag: struct { tick: u16, selector: u16 },
    motion: ReturnMotion,
    wait_movement_tick: u16,
    release: struct { tick: u16, clear_masks: []const u8 },
};

pub const Owner = struct {
    impact_observe_tick: u16,
    ready_write_tick: u16,
    ready_observe_tick: u16,
    return_track: Return,
};

pub const TargetRelease = struct {
    impact_observe_tick: u16,
    delay: u16,
    tick: u16,
};

pub const Residency = struct {
    animations: []const u16,
    poses: []const u16,
    qualified: bool,
    scope: []const u8,
};

pub const Tracks = struct { attack: u16, auxiliary: u16, return_script: u16, reaction: u16 };

pub const Record = struct {
    id: []const u8,
    family: []const u8,
    resource: []const u8,
    resource_sha256: []const u8,
    tracks: Tracks,
    animations: []const u16,
    audio_cues: []const u16,
    spawn: Spawn,
    callback: Callback,
    contact: Contact,
    auxiliary: Auxiliary,
    owner: Owner,
    target_release: TargetRelease,
    residency: Residency,
};

pub const Dodge = struct { id: []const u8, target_release_tick: u16 };

pub const Projectile = struct {
    id: []const u8,
    kind: []const u8,
    source: []const u8,
    target_policy: []const u8,
    impact_tick: u16,
    target_release_tick: u16,
    owner_release_tick: u16,
    dodges: []const Dodge,
};

pub const Content = struct {
    schema: []const u8,
    convention: std.json.Value,
    inputs: std.json.Value,
    families: std.json.Value,
    source_semantics: std.json.Value,
    records: []Record,
    projectiles: []Projectile,
    blockers: std.json.Value,
};

pub const ValidateError = error{
    InvalidSchema,
    RecordCount,
    RecordFamily,
    DuplicateRecord,
    InvalidSpawn,
    InvalidCallback,
    InvalidContact,
    InvalidAuxiliary,
    InvalidOwner,
    InvalidTargetRelease,
    InvalidResidency,
    InvalidProjectile,
    DuplicateProjectile,
    BoundsError,
};

fn le(a: u16, b: u16) bool {
    return a <= b;
}

fn zero(offset: Offset) bool {
    return offset.x == 0 and offset.y == 0 and offset.z == 0;
}

fn inBounds(value: i16) bool {
    return value >= -max_tick and value <= max_tick;
}

fn hasMask(masks: []const u8, wanted: u8) bool {
    for (masks) |mask| if (mask == wanted) return true;
    return false;
}

/// Validate one record against the source invariants the packet was derived
/// from.  The checks are deliberately strict: an unproven shape is refused.
pub fn validateRecord(record: Record) ValidateError!void {
    if (!std.mem.eql(u8, record.family, "stationary_auxiliary")) return error.RecordFamily;
    if (record.id.len == 0) return error.InvalidSpawn;
    if (record.resource_sha256.len != 64) return error.InvalidResidency;

    const spawn = record.spawn;
    if (spawn.flags & 0xF0 != 0) return error.InvalidSpawn;
    if (spawn.bits.reuse_own_source != (spawn.flags & 1 != 0)) return error.InvalidSpawn;
    if (spawn.bits.secondary_draw_list != (spawn.flags & 2 != 0)) return error.InvalidSpawn;
    if (spawn.bits.owner_is_linked_slot != (spawn.flags & 4 != 0)) return error.InvalidSpawn;
    if (spawn.bits.source_position_from_owner != (spawn.flags & 8 != 0)) return error.InvalidSpawn;
    if (spawn.bits.owner_is_linked_slot) return error.InvalidSpawn;
    if (!spawn.bits.reuse_own_source or !spawn.bits.secondary_draw_list) return error.InvalidSpawn;
    if (!spawn.bits.source_position_from_owner) return error.InvalidSpawn;
    if (!std.mem.eql(u8, spawn.source, "own_source")) return error.InvalidSpawn;
    if (!std.mem.eql(u8, spawn.draw_list, "secondary")) return error.InvalidSpawn;
    if (!std.mem.eql(u8, spawn.owner, "self")) return error.InvalidSpawn;
    if (!std.mem.eql(u8, spawn.position_reference, "owner")) return error.InvalidSpawn;
    if (record.tracks.auxiliary != spawn.script_slot) return error.InvalidSpawn;
    if (record.tracks.attack != 1 or record.tracks.return_script != 4) return error.InvalidSpawn;
    if (record.tracks.reaction != 2) return error.InvalidSpawn;
    if (!inBounds(spawn.offset.x) or !inBounds(spawn.offset.y) or !inBounds(spawn.offset.z))
        return error.BoundsError;
    if (spawn.animation == 0) return error.InvalidSpawn;

    var animation_known = false;
    for (record.animations) |animation| {
        if (animation == spawn.animation) animation_known = true;
    }
    if (!animation_known) return error.InvalidSpawn;

    const callback = record.callback;
    if (callback.mode != 0) return error.InvalidCallback;
    if (callback.id != 1 and callback.id != 2) return error.InvalidCallback;
    if (callback.compare.set_value != 0) return error.InvalidCallback;
    if (callback.compare.after_invoke != callback.compare.set_value + 1) return error.InvalidCallback;
    if (callback.compare.set_tick != callback.tick) return error.InvalidCallback;
    if (callback.compare.invoke_tick != callback.tick) return error.InvalidCallback;
    if (callback.wait.tick != callback.tick) return error.InvalidCallback;
    if (callback.wait.value != callback.compare.after_invoke) return error.InvalidCallback;
    if (!le(spawn.tick, callback.tick)) return error.InvalidCallback;

    const contact = record.contact;
    if (contact.mask != 2) return error.InvalidContact;
    if (!std.mem.eql(u8, contact.from, "auxiliary")) return error.InvalidContact;
    if (!std.mem.eql(u8, contact.to, "owner")) return error.InvalidContact;
    if (contact.observe_tick != contact.write_tick + 1) return error.InvalidContact;
    if (!le(callback.tick, contact.write_tick)) return error.InvalidContact;
    if (contact.observe_tick != record.owner.impact_observe_tick) return error.InvalidContact;
    if (contact.observe_tick != record.target_release.impact_observe_tick)
        return error.InvalidContact;

    const auxiliary = record.auxiliary;
    if (auxiliary.motion.mode != 3) return error.InvalidAuxiliary;
    if (auxiliary.motion.duration == 0) return error.InvalidAuxiliary;
    if (auxiliary.motion.translation) return error.InvalidAuxiliary;
    if (!zero(auxiliary.motion.offset)) return error.InvalidAuxiliary;
    if (auxiliary.motion.tick != spawn.tick) return error.InvalidAuxiliary;
    if (auxiliary.release.tick != auxiliary.motion.tick + auxiliary.motion.duration - 1)
        return error.InvalidAuxiliary;
    if (!std.mem.eql(u8, auxiliary.release.release_path, "opcode_2_exit"))
        return error.InvalidAuxiliary;
    if (!le(contact.write_tick, auxiliary.release.tick)) return error.InvalidAuxiliary;
    if (auxiliary.waits_for_movement != auxiliary.release.tick) return error.InvalidAuxiliary;
    if (auxiliary.timers.len == 0 or auxiliary.timers.len > max_timers)
        return error.InvalidAuxiliary;
    for (auxiliary.timers) |timer| {
        if (timer.ticks == 0) return error.InvalidAuxiliary;
        if (timer.tick < spawn.tick or timer.tick > auxiliary.release.tick)
            return error.InvalidAuxiliary;
    }
    if (auxiliary.masks.len == 0 or auxiliary.masks.len > max_masks)
        return error.InvalidAuxiliary;
    var contact_mask_written = false;
    for (auxiliary.masks) |mask| {
        if (!std.mem.eql(u8, mask.target, "owner")) return error.InvalidAuxiliary;
        if (mask.tick < spawn.tick or mask.tick > contact.write_tick)
            return error.InvalidAuxiliary;
        if (mask.mask == contact.mask and mask.tick == contact.write_tick) contact_mask_written = true;
    }
    if (!contact_mask_written) return error.InvalidContact;

    const owner = record.owner;
    if (owner.ready_observe_tick != owner.ready_write_tick + 1) return error.InvalidOwner;
    if (owner.ready_write_tick <= contact.observe_tick) return error.InvalidOwner;
    const ret = owner.return_track;
    if (ret.start_tick != owner.ready_observe_tick) return error.InvalidOwner;
    if (ret.global_flag.tick != ret.start_tick) return error.InvalidOwner;
    if (ret.motion.tick != ret.start_tick) return error.InvalidOwner;
    if (ret.motion.mode != 3) return error.InvalidOwner;
    if (ret.motion.duration < 2) return error.InvalidOwner;
    if (!zero(ret.motion.offset) or !zero(ret.motion.delta)) return error.InvalidOwner;
    if (ret.release.tick != ret.motion.tick + ret.motion.duration - 1) return error.InvalidOwner;
    if (ret.wait_movement_tick != ret.release.tick) return error.InvalidOwner;
    if (!hasMask(ret.release.clear_masks, 1) or !hasMask(ret.release.clear_masks, 8))
        return error.InvalidOwner;

    const target = record.target_release;
    if (target.delay == 0) return error.InvalidTargetRelease;
    if (target.tick != target.impact_observe_tick + target.delay) return error.InvalidTargetRelease;
    if (!le(target.impact_observe_tick, target.tick)) return error.InvalidTargetRelease;

    if (!record.residency.qualified) return error.InvalidResidency;
    if (record.residency.poses.len == 0) return error.InvalidResidency;
    if (record.residency.animations.len != record.animations.len) return error.InvalidResidency;
    for (record.animations, record.residency.animations) |left, right| {
        if (left != right) return error.InvalidResidency;
    }
    for (record.animations, 0..) |_, index| {
        if (index > 0) {
            if (record.animations[index - 1] >= record.animations[index])
                return error.InvalidResidency;
        }
    }
    if (spawn.tick > max_tick or ret.release.tick > max_tick or target.tick > max_tick)
        return error.BoundsError;
}

pub fn validateProjectile(projectile: Projectile) ValidateError!void {
    if (!std.mem.eql(u8, projectile.kind, "front_projectile") and
        !std.mem.eql(u8, projectile.kind, "projectile")) return error.InvalidProjectile;
    if (projectile.impact_tick == 0) return error.InvalidProjectile;
    if (!le(projectile.impact_tick, projectile.target_release_tick)) return error.InvalidProjectile;
    if (projectile.impact_tick == projectile.target_release_tick) return error.InvalidProjectile;
    if (!le(projectile.target_release_tick, projectile.owner_release_tick))
        return error.InvalidProjectile;
    if (projectile.owner_release_tick > max_tick) return error.BoundsError;
    if (projectile.dodges.len > max_dodges) return error.InvalidProjectile;
    if (std.mem.eql(u8, projectile.kind, "front_projectile")) {
        for (projectile.dodges, 0..) |dodge, index| {
            for (projectile.dodges[0..index]) |previous| {
                if (std.mem.eql(u8, previous.id, dodge.id)) return error.InvalidProjectile;
            }
            if (dodge.id.len == 0) return error.InvalidProjectile;
            if (!le(projectile.impact_tick, dodge.target_release_tick))
                return error.InvalidProjectile;
            if (dodge.target_release_tick > max_tick) return error.BoundsError;
        }
    } else if (projectile.dodges.len != 0) {
        return error.InvalidProjectile;
    }
}

pub fn validate(content: Content) ValidateError!void {
    if (!std.mem.eql(u8, content.schema, schema)) return error.InvalidSchema;
    if (content.records.len == 0 or content.records.len > max_records) return error.RecordCount;
    for (content.records, 0..) |record, index| {
        try validateRecord(record);
        for (content.records[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id, record.id)) return error.DuplicateRecord;
        }
    }
    if (content.projectiles.len > max_projectiles) return error.InvalidProjectile;
    for (content.projectiles, 0..) |projectile, index| {
        try validateProjectile(projectile);
        for (content.projectiles[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id, projectile.id)) return error.DuplicateProjectile;
        }
    }
}

pub fn find(content: Content, id: []const u8) ?usize {
    for (content.records, 0..) |record, index| {
        if (std.mem.eql(u8, record.id, id)) return index;
    }
    return null;
}

pub fn findProjectile(content: Content, id: []const u8) ?usize {
    for (content.projectiles, 0..) |projectile, index| {
        if (std.mem.eql(u8, projectile.id, id)) return index;
    }
    return null;
}

pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Content) {
    const parsed = try std.json.parseFromSlice(Content, allocator, bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();
    try validate(parsed.value);
    return parsed;
}
