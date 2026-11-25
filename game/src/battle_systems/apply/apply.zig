//! Runtime action application for the source action families.
//!
//! One `Action` owns the actor state that the source action scripts write:
//!
//!  * the owner's animation/timer/flags/screen state and its return track;
//!  * the spawned auxiliary slot (source, draw list, animation, script, owner,
//!    12.12 position, timer, motion and masks);
//!  * the compare callback handshake (set 0, install/invoke, wait 1);
//!  * three independent boundaries: contact (auxiliary mask-2 write, observed
//!    one coordinator update later), the owner-return release, and the target
//!    reaction release.
//!
//! Contact, owner return and target release are separate state: an interruption
//! stops pending motion/animation waits but never retargets, delays or drops one
//! of those three, and the checkpoint carries all three across a fresh process.
//!
//! Nothing here draws a random number, applies damage, chooses a target or
//! mutates hit points; those stay with the existing battle coordinator.

const std = @import("std");
const model = @import("content.zig");

pub const max_actions = 6;
pub const max_slots = 8;
pub const max_checkpoint_bytes = 8192;
pub const checkpoint_magic = "W5P2CKPT";
pub const checkpoint_version: u8 = 1;

pub const Vec3 = struct { x: i32 = 0, y: i32 = 0, z: i32 = 0 };

pub const Source = enum { own_source, table_default };
pub const DrawList = enum { primary, secondary };
pub const ReleaseReason = enum { none, flag_clear, teardown };
pub const InterruptReason = enum { knockout, sleep, unbalanced, target_down, round_end };

/// Named port state for one actor record.  Units are the packet's units: the
/// position is 12.12 fixed point, the timer/motion counters are source updates.
pub const Actor = struct {
    animation: ?u16 = null,
    animation_ticks: u16 = 0,
    flag_byte: u8 = 0,
    primary_flags: u8 = 0,
    secondary_flags: u8 = 0,
    compare_value: u16 = 0,
    /// Last programmed wait count (opcode 3).  The packet's event tick is the
    /// schedule; the exit-probe decrement is not re-modelled here.
    timer: u16 = 0,
    motion_remaining: u16 = 0,
    screen_x: i16 = 0,
    screen_y: i16 = 0,
    callback: ?u16 = null,
    owner: ?u8 = null,
    script_slot: u16 = 0,
    source: Source = .table_default,
    draw_list: DrawList = .primary,
    position: Vec3 = .{},
    active: bool = false,
    stopped: bool = false,
};

pub const Contact = struct {
    write_tick: u16,
    observe_tick: u16,
    mask: u8,
    written: bool = false,
    observed: bool = false,
};

pub const ReturnTrack = struct {
    start_tick: u16,
    release_tick: u16,
    started: bool = false,
    released: bool = false,
    reason: ReleaseReason = .none,
    interrupted: bool = false,
};

pub const TargetRelease = struct {
    tick: u16,
    delay: u16,
    done: bool = false,
    interrupted: bool = false,
};

pub const Update = struct {
    elapsed: u16 = 0,
    spawned: bool = false,
    spawned_slot: u8 = 0,
    callback_invoked: bool = false,
    contact_written: bool = false,
    contact_observed: bool = false,
    auxiliary_released: bool = false,
    owner_ready: bool = false,
    return_started: bool = false,
    owner_released: bool = false,
    target_released: bool = false,
    completed: bool = false,
};

pub const Host = struct {
    context: *anyopaque,
    /// The engine owns free-slot allocation; a null result is a typed refusal.
    allocate_slot: *const fn (context: *anyopaque) ?u8,
    release_slot: *const fn (context: *anyopaque, slot: u8) void,
    observe_contact: *const fn (context: *anyopaque, owner: u8) void,
    release_target: *const fn (context: *anyopaque, owner: u8) void,
    release_owner: *const fn (context: *anyopaque, owner: u8) void,
};

pub const ApplyError = error{
    NoActorSlot,
    UnknownRecord,
    ActionAlreadyRunning,
    ActionNotRunning,
    NoFreeAction,
    CompareHandshakeBroken,
    CheckpointTooSmall,
    CheckpointInvalid,
    CheckpointTruncated,
};

const flag_spawned: u8 = 1 << 0;
const flag_auxiliary_released: u8 = 1 << 1;
const flag_callback: u8 = 1 << 2;
const flag_contact_written: u8 = 1 << 3;
const flag_contact_observed: u8 = 1 << 4;
const flag_return_started: u8 = 1 << 5;
const flag_return_released: u8 = 1 << 6;
const flag_target_released: u8 = 1 << 7;

pub const Action = struct {
    record: u16,
    owner: u8,
    elapsed: u16 = 0,
    owner_actor: Actor = .{},
    auxiliary: ?Actor = null,
    auxiliary_slot: u8 = 0,
    spawned: bool = false,
    auxiliary_released: bool = false,
    callback_invoked: bool = false,
    contact: Contact,
    return_track: ReturnTrack,
    target_release: TargetRelease,
    auxiliary_release_tick: u16,
    interrupted: bool = false,
    complete: bool = false,

    pub fn init(record_index: u16, record: model.Record, owner: u8) Action {
        var owner_actor = Actor{};
        owner_actor.active = true;
        owner_actor.script_slot = record.tracks.attack;
        owner_actor.owner = owner;
        return .{
            .record = record_index,
            .owner = owner,
            .owner_actor = owner_actor,
            .contact = .{
                .write_tick = record.contact.write_tick,
                .observe_tick = record.contact.observe_tick,
                .mask = record.contact.mask,
            },
            .return_track = .{
                .start_tick = record.owner.return_track.start_tick,
                .release_tick = record.owner.return_track.release.tick,
            },
            .target_release = .{
                .tick = record.target_release.tick,
                .delay = record.target_release.delay,
            },
            .auxiliary_release_tick = record.auxiliary.release.tick,
        };
    }

    fn flags(self: Action) u8 {
        var value: u8 = 0;
        if (self.spawned) value |= flag_spawned;
        if (self.auxiliary_released) value |= flag_auxiliary_released;
        if (self.callback_invoked) value |= flag_callback;
        if (self.contact.written) value |= flag_contact_written;
        if (self.contact.observed) value |= flag_contact_observed;
        if (self.return_track.started) value |= flag_return_started;
        if (self.return_track.released) value |= flag_return_released;
        if (self.target_release.done) value |= flag_target_released;
        return value;
    }

    fn setFlags(self: *Action, value: u8) void {
        self.spawned = value & flag_spawned != 0;
        self.auxiliary_released = value & flag_auxiliary_released != 0;
        self.callback_invoked = value & flag_callback != 0;
        self.contact.written = value & flag_contact_written != 0;
        self.contact.observed = value & flag_contact_observed != 0;
        self.return_track.started = value & flag_return_started != 0;
        self.return_track.released = value & flag_return_released != 0;
        self.target_release.done = value & flag_target_released != 0;
    }

    fn boundariesDone(self: Action) bool {
        return self.contact.observed and self.return_track.released and
            self.target_release.done;
    }

    /// Apply one source actor update.  The update is transactional: a failed
    /// slot allocation restores the action exactly.
    pub fn apply(self: *Action, record: model.Record, host: Host) !Update {
        const snapshot = self.*;
        errdefer self.* = snapshot;
        var update = Update{ .elapsed = self.elapsed };
        const now = self.elapsed;

        if (now == record.spawn.tick and !self.spawned) {
            const slot = host.allocate_slot(host.context) orelse return error.NoActorSlot;
            var auxiliary = Actor{};
            auxiliary.active = true;
            auxiliary.animation = record.spawn.animation;
            auxiliary.script_slot = record.spawn.script_slot;
            auxiliary.source = if (record.spawn.bits.reuse_own_source) .own_source else .table_default;
            auxiliary.draw_list = if (record.spawn.bits.secondary_draw_list) .secondary else .primary;
            auxiliary.owner = if (record.spawn.bits.owner_is_linked_slot)
                self.owner_actor.owner orelse self.owner
            else
                self.owner;
            auxiliary.position = .{
                .x = self.owner_actor.position.x + (@as(i32, record.spawn.offset.x) << 12),
                .y = self.owner_actor.position.y + (@as(i32, record.spawn.offset.y) << 12),
                .z = self.owner_actor.position.z + (@as(i32, record.spawn.offset.z) << 12),
            };
            self.auxiliary = auxiliary;
            self.auxiliary_slot = slot;
            self.spawned = true;
            update.spawned = true;
            update.spawned_slot = slot;
        }

        if (now == record.callback.tick and self.spawned and !self.callback_invoked) {
            if (self.auxiliary) |*auxiliary| {
                auxiliary.compare_value = record.callback.compare.set_value;
                auxiliary.callback = record.callback.id;
                auxiliary.compare_value = record.callback.compare.after_invoke;
                if (auxiliary.compare_value != record.callback.wait.value)
                    return error.CompareHandshakeBroken;
            } else return error.CompareHandshakeBroken;
            self.callback_invoked = true;
            update.callback_invoked = true;
        }

        if (now == record.auxiliary.motion.tick and self.spawned) {
            if (self.auxiliary) |*auxiliary| {
                auxiliary.motion_remaining = record.auxiliary.motion.duration;
            }
        }
        if (self.auxiliary) |*auxiliary| {
            for (record.auxiliary.timers) |timer| {
                if (now == timer.tick) auxiliary.timer = timer.ticks;
            }
        }
        for (record.auxiliary.masks) |mask| {
            if (now != mask.tick or !self.spawned) continue;
            if (!std.mem.eql(u8, mask.target, "owner")) continue;
            self.owner_actor.primary_flags |= mask.mask;
            if (mask.mask == self.contact.mask and mask.tick == self.contact.write_tick) {
                self.contact.written = true;
                update.contact_written = true;
            }
        }
        if (now == self.contact.write_tick and !self.contact.written) {
            self.owner_actor.primary_flags |= self.contact.mask;
            self.contact.written = true;
            update.contact_written = true;
        }
        if (now == self.contact.observe_tick and self.contact.written and !self.contact.observed) {
            self.contact.observed = true;
            host.observe_contact(host.context, self.owner);
            update.contact_observed = true;
        }
        if (now == record.owner.ready_write_tick) {
            self.owner_actor.primary_flags |= 4;
        }
        if (now == record.owner.ready_observe_tick) {
            update.owner_ready = true;
        }
        if (now == record.owner.return_track.start_tick and !self.return_track.started) {
            self.return_track.started = true;
            self.owner_actor.motion_remaining = record.owner.return_track.motion.duration;
            self.owner_actor.screen_x = 0;
            self.owner_actor.screen_y = 0;
            update.return_started = true;
        }
        if (now == self.return_track.release_tick and !self.return_track.released) {
            self.return_track.released = true;
            self.return_track.reason = .flag_clear;
            for (record.owner.return_track.release.clear_masks) |mask| {
                self.owner_actor.primary_flags &= ~@as(u8, @intCast(mask));
            }
            host.release_owner(host.context, self.owner);
            update.owner_released = true;
        }
        if (now == self.target_release.tick and !self.target_release.done) {
            self.target_release.done = true;
            host.release_target(host.context, self.owner);
            update.target_released = true;
        }
        if (now == self.auxiliary_release_tick and self.spawned and !self.auxiliary_released) {
            host.release_slot(host.context, self.auxiliary_slot);
            if (self.auxiliary) |*auxiliary| {
                auxiliary.active = false;
                auxiliary.stopped = true;
                auxiliary.callback = null;
                auxiliary.motion_remaining = 0;
            }
            self.auxiliary_released = true;
            update.auxiliary_released = true;
        }

        if (self.auxiliary) |*auxiliary| {
            if (auxiliary.motion_remaining > 0) auxiliary.motion_remaining -= 1;
        }
        if (self.owner_actor.motion_remaining > 0) self.owner_actor.motion_remaining -= 1;

        if (self.boundariesDone() and !self.complete) {
            self.complete = true;
            update.completed = true;
        }
        self.elapsed += 1;
        return update;
    }

    pub fn encode(self: Action, writer: *Writer) !void {
        try writer.writeU16(self.record);
        try writer.writeU8(self.owner);
        try writer.writeU16(self.elapsed);
        try writer.writeU8(self.flags());
        try writer.writeU8(@backingInt(self.return_track.reason));
        try writer.writeU8(self.auxiliary_slot);
        try writer.writeU8(if (self.interrupted) 1 else 0);
        try writer.writeU8(if (self.complete) 1 else 0);
        try writer.writeBool(self.auxiliary != null);
        try encodeActor(writer, self.owner_actor);
        try encodeActor(writer, self.auxiliary orelse Actor{});
    }

    pub fn decode(reader: *Reader, content: *const model.Content) !Action {
        const record = try reader.readU16();
        if (record >= content.records.len) return error.CheckpointInvalid;
        const owner = try reader.readU8();
        var action = Action.init(record, content.records[record], owner);
        action.elapsed = try reader.readU16();
        action.setFlags(try reader.readU8());
        const reason = try reader.readU8();
        if (reason > @backingInt(ReleaseReason.teardown)) return error.CheckpointInvalid;
        action.return_track.reason = @fromBackingInt(@intCast(reason));
        action.auxiliary_slot = try reader.readU8();
        action.interrupted = (try reader.readU8()) != 0;
        action.complete = (try reader.readU8()) != 0;
        const has_auxiliary = try reader.readBool();
        action.owner_actor = try decodeActor(reader);
        const auxiliary = try decodeActor(reader);
        action.auxiliary = if (has_auxiliary) auxiliary else null;
        return action;
    }
};

pub const Session = struct {
    content: *const model.Content,
    host: Host,
    actions: [max_actions]?Action = .{ null, null, null, null, null, null },

    pub fn init(content: *const model.Content, host: Host) Session {
        return .{ .content = content, .host = host };
    }

    pub fn actionCount(self: *const Session) usize {
        var total: usize = 0;
        for (self.actions) |maybe| {
            if (maybe != null) total += 1;
        }
        return total;
    }

    pub fn find(self: *Session, owner: u8) ?*Action {
        for (&self.actions) |*slot| {
            if (slot.*) |*action| {
                if (action.owner == owner) return action;
            }
        }
        return null;
    }

    pub fn begin(self: *Session, record_index: u16, owner: u8) !*Action {
        if (record_index >= self.content.records.len) return error.UnknownRecord;
        if (self.find(owner) != null) return error.ActionAlreadyRunning;
        for (&self.actions) |*slot| {
            if (slot.* != null) continue;
            slot.* = Action.init(record_index, self.content.records[record_index], owner);
            if (slot.*) |*action| return action;
        }
        return error.NoFreeAction;
    }

    pub fn tick(self: *Session, owner: u8) !Update {
        const action = self.find(owner) orelse return error.ActionNotRunning;
        const record = self.content.records[action.record];
        return action.apply(record, self.host);
    }

    /// Stop pending motion/animation waits.  Contact, owner-return release and
    /// target release keep their own state and deadlines.
    pub fn interrupt(self: *Session, owner: u8, reason: InterruptReason) void {
        _ = reason;
        const action = self.find(owner) orelse return;
        action.interrupted = true;
        action.owner_actor.motion_remaining = 0;
        action.owner_actor.animation_ticks = 0;
        if (action.return_track.started and !action.return_track.released) {
            action.return_track.interrupted = true;
        }
        if (!action.target_release.done) action.target_release.interrupted = true;
    }

    /// Apply the source opcode-2 exit release path to the owner actor only.
    /// The auxiliary is a separate actor slot and keeps its own release.
    pub fn teardown(self: *Session, owner: u8) void {
        const action = self.find(owner) orelse return;
        action.owner_actor.animation = null;
        action.owner_actor.animation_ticks = 0;
        action.owner_actor.callback = null;
        action.owner_actor.motion_remaining = 0;
        action.owner_actor.screen_x = 0;
        action.owner_actor.screen_y = 0;
        action.owner_actor.active = false;
        action.owner_actor.stopped = true;
        if (!action.return_track.released) {
            action.return_track.released = true;
            action.return_track.reason = .teardown;
            self.host.release_owner(self.host.context, owner);
        }
    }

    pub fn checkpoint(self: *const Session, buffer: []u8) !usize {
        if (buffer.len < checkpoint_magic.len + 2) return error.CheckpointTooSmall;
        var writer = Writer{ .buffer = buffer };
        try writer.bytes(checkpoint_magic);
        try writer.writeU8(checkpoint_version);
        try writer.writeU8(@intCast(self.actions.len));
        for (self.actions) |maybe| {
            if (maybe) |action| {
                try writer.writeU8(1);
                try action.encode(&writer);
            } else {
                try writer.writeU8(0);
            }
        }
        return writer.at;
    }

    pub fn restore(self: *Session, buffer: []const u8) !void {
        if (buffer.len < checkpoint_magic.len + 2) return error.CheckpointTruncated;
        if (!std.mem.eql(u8, buffer[0..checkpoint_magic.len], checkpoint_magic))
            return error.CheckpointInvalid;
        var reader = Reader{ .data = buffer, .at = checkpoint_magic.len };
        const version = try reader.readU8();
        if (version != checkpoint_version) return error.CheckpointInvalid;
        const count = try reader.readU8();
        if (count != self.actions.len) return error.CheckpointInvalid;
        for (&self.actions) |*slot| slot.* = null;
        for (&self.actions) |*slot| {
            const present = try reader.readU8();
            if (present == 0) continue;
            slot.* = try Action.decode(&reader, self.content);
        }
    }
};

pub const Writer = struct {
    buffer: []u8,
    at: usize = 0,

    pub fn bytes(self: *Writer, value: []const u8) !void {
        if (self.at + value.len > self.buffer.len) return error.CheckpointTooSmall;
        @memcpy(self.buffer[self.at..][0..value.len], value);
        self.at += value.len;
    }
    pub fn writeU8(self: *Writer, value: u8) !void {
        try self.bytes(&.{value});
    }
    pub fn writeU16(self: *Writer, value: u16) !void {
        var raw: [2]u8 = undefined;
        std.mem.writeInt(u16, &raw, value, .little);
        try self.bytes(&raw);
    }
    pub fn writeI16(self: *Writer, value: i16) !void {
        try self.writeU16(@bitCast(value));
    }
    pub fn writeI32(self: *Writer, value: i32) !void {
        var raw: [4]u8 = undefined;
        std.mem.writeInt(i32, &raw, value, .little);
        try self.bytes(&raw);
    }
    pub fn writeBool(self: *Writer, value: bool) !void {
        try self.writeU8(if (value) 1 else 0);
    }
};

pub const Reader = struct {
    data: []const u8,
    at: usize = 0,

    pub fn bytes(self: *Reader, length: usize) ![]const u8 {
        if (self.at + length > self.data.len) return error.CheckpointTruncated;
        const slice = self.data[self.at..][0..length];
        self.at += length;
        return slice;
    }
    pub fn readU8(self: *Reader) !u8 {
        return (try self.bytes(1))[0];
    }
    pub fn readU16(self: *Reader) !u16 {
        return std.mem.readInt(u16, (try self.bytes(2))[0..2], .little);
    }
    pub fn readI16(self: *Reader) !i16 {
        return @bitCast(try self.readU16());
    }
    pub fn readI32(self: *Reader) !i32 {
        return std.mem.readInt(i32, (try self.bytes(4))[0..4], .little);
    }
    pub fn readBool(self: *Reader) !bool {
        return (try self.readU8()) != 0;
    }
};

fn encodeActor(writer: *Writer, actor: Actor) !void {
    try writer.writeBool(actor.animation != null);
    try writer.writeU16(actor.animation orelse 0);
    try writer.writeU16(actor.animation_ticks);
    try writer.writeU8(actor.flag_byte);
    try writer.writeU8(actor.primary_flags);
    try writer.writeU8(actor.secondary_flags);
    try writer.writeU16(actor.compare_value);
    try writer.writeU16(actor.timer);
    try writer.writeU16(actor.motion_remaining);
    try writer.writeI16(actor.screen_x);
    try writer.writeI16(actor.screen_y);
    try writer.writeBool(actor.callback != null);
    try writer.writeU16(actor.callback orelse 0);
    try writer.writeBool(actor.owner != null);
    try writer.writeU8(actor.owner orelse 0);
    try writer.writeU16(actor.script_slot);
    try writer.writeI32(actor.position.x);
    try writer.writeI32(actor.position.y);
    try writer.writeI32(actor.position.z);
    try writer.writeU8(@backingInt(actor.source));
    try writer.writeU8(@backingInt(actor.draw_list));
    try writer.writeBool(actor.active);
    try writer.writeBool(actor.stopped);
}

fn decodeActor(reader: *Reader) !Actor {
    var actor = Actor{};
    const has_animation = try reader.readBool();
    const animation = try reader.readU16();
    actor.animation = if (has_animation) animation else null;
    actor.animation_ticks = try reader.readU16();
    actor.flag_byte = try reader.readU8();
    actor.primary_flags = try reader.readU8();
    actor.secondary_flags = try reader.readU8();
    actor.compare_value = try reader.readU16();
    actor.timer = try reader.readU16();
    actor.motion_remaining = try reader.readU16();
    actor.screen_x = try reader.readI16();
    actor.screen_y = try reader.readI16();
    const has_callback = try reader.readBool();
    const callback = try reader.readU16();
    actor.callback = if (has_callback) callback else null;
    const has_owner = try reader.readBool();
    const owner = try reader.readU8();
    actor.owner = if (has_owner) owner else null;
    actor.script_slot = try reader.readU16();
    actor.position = .{
        .x = try reader.readI32(),
        .y = try reader.readI32(),
        .z = try reader.readI32(),
    };
    const source = try reader.readU8();
    if (source > @backingInt(Source.table_default)) return error.CheckpointInvalid;
    actor.source = @fromBackingInt(@intCast(source));
    const draw = try reader.readU8();
    if (draw > @backingInt(DrawList.secondary)) return error.CheckpointInvalid;
    actor.draw_list = @fromBackingInt(@intCast(draw));
    actor.active = try reader.readBool();
    actor.stopped = try reader.readBool();
    return actor;
}

/// Translation-carrying projectile action state.
///
/// Contact, the target release (normal or dodge) and the owner return are three
/// independent deadlines.  Interrupting the shooter does not cancel any of them;
/// the target release keeps its dodge-specific tick.
pub const ProjectileState = struct {
    index: u8,
    impact_tick: u16,
    target_release_tick: u16,
    owner_release_tick: u16,
    dodge_tick: ?u16 = null,
    contact: bool = false,
    target_released: bool = false,
    owner_returned: bool = false,
    interrupted: bool = false,
    released_by_dodge: bool = false,

    pub const Event = struct {
        contact: bool = false,
        target_released: bool = false,
        owner_returned: bool = false,
    };

    pub fn init(content: *const model.Content, index: u8) ProjectileState {
        const projectile = content.projectiles[index];
        return .{
            .index = index,
            .impact_tick = projectile.impact_tick,
            .target_release_tick = projectile.target_release_tick,
            .owner_release_tick = projectile.owner_release_tick,
        };
    }

    /// `dodge_tick` is the defender-specific release the host resolved from the
    /// packet's dodge table; null means the target does not dodge this shot.
    pub fn tick(self: *ProjectileState, elapsed: u16, dodge_tick: ?u16) Event {
        var event = Event{};
        if (elapsed == self.impact_tick and !self.contact) {
            self.contact = true;
            event.contact = true;
        }
        if (!self.target_released) {
            // A dodging defender's release tick replaces the normal release; the
            // packet's dodge table is an alternative deadline, not an early one.
            if (dodge_tick) |release_tick| {
                if (elapsed == release_tick) {
                    self.target_released = true;
                    self.released_by_dodge = true;
                    event.target_released = true;
                }
            } else if (elapsed == self.target_release_tick) {
                self.target_released = true;
                event.target_released = true;
            }
        }
        if (elapsed == self.owner_release_tick and !self.owner_returned) {
            self.owner_returned = true;
            event.owner_returned = true;
        }
        return event;
    }

    pub fn interrupt(self: *ProjectileState) void {
        self.interrupted = true;
    }

    pub fn encode(self: ProjectileState, writer: *Writer) !void {
        try writer.writeU8(self.index);
        try writer.writeU16(self.impact_tick);
        try writer.writeU16(self.target_release_tick);
        try writer.writeU16(self.owner_release_tick);
        try writer.writeBool(self.dodge_tick != null);
        try writer.writeU16(self.dodge_tick orelse 0);
        try writer.writeU8((if (self.contact) @as(u8, 1) else 0) |
            (if (self.target_released) @as(u8, 2) else 0) |
            (if (self.owner_returned) @as(u8, 4) else 0) |
            (if (self.interrupted) @as(u8, 8) else 0) |
            (if (self.released_by_dodge) @as(u8, 16) else 0));
    }

    pub fn decode(reader: *Reader, content: *const model.Content) !ProjectileState {
        const index = try reader.readU8();
        if (index >= content.projectiles.len) return error.CheckpointInvalid;
        var state = ProjectileState.init(content, index);
        state.impact_tick = try reader.readU16();
        state.target_release_tick = try reader.readU16();
        state.owner_release_tick = try reader.readU16();
        const has_dodge = try reader.readBool();
        const dodge = try reader.readU16();
        state.dodge_tick = if (has_dodge) dodge else null;
        const bits = try reader.readU8();
        state.contact = bits & 1 != 0;
        state.target_released = bits & 2 != 0;
        state.owner_returned = bits & 4 != 0;
        state.interrupted = bits & 8 != 0;
        state.released_by_dodge = bits & 16 != 0;
        return state;
    }
};
