//! Compose spell/attack effects at the real coordinator boundaries.
//!
//! The composer consumes an accepted catalogue entry (`catalogue.zig`) and a *boundary*
//! supplied by the owning coordinator:
//!
//!   * cast contact  = `battle.State.impactTick()` (party cast_impact);
//!   * cast finish   = `battle.State.actionDuration()` (summed cast frames);
//!   * attack contact= `battle.State.memberImpact()`;
//!   * attack finish = `battle.State.memberDuration()`.
//!
//! It never derives a boundary from the presentation upload counter: the ten upload ticks
//! are a residency wait, so `ContactDuringUpload` is a refusal, not an impact.
//!
//! The timeline is effect-relative (`battle.State.effectTicks()`); the owner
//! passes ticks, never absolute `action_ticks`.  `frameAt` is pure and may be
//! polled as often as the renderer likes.  `advanceTo` is the only mutator and
//! delivers at most one contact and one finish event, in order, even when the
//! caller skips from the command menu straight to the end of the effect.
//!
//! Rule effects belong to the existing battle owner: a delivered contact event
//! carries the accepted one-time rule descriptor and the owner executes it
//! exactly once.  The composer never writes HP, charges or random draws.

const std = @import("std");
const p = @import("catalogue.zig");

pub const max_draws = 4;
pub const max_events = 2;
pub const max_id = 40;
pub const max_tick = 4096;
pub const snapshot_version: u16 = 1;

pub const Kind = enum { cast, attack };

/// Frame phases are derived from the tick; `done` means the effect finished.
pub const Phase = enum { upload, present, pre_contact, contact, post_contact, finish, done };

pub const Blocker = enum {
    palette_data_carrier,
    palette_slot_range,
    page_lifetime_unproven,
    presentation_termination,
    impact_timing,
    finish_timing,
    direct_plane_residency,
    rule_partial,

    pub fn fromCode(code: []const u8) ?Blocker {
        return std.meta.stringToEnum(Blocker, code);
    }
};

pub const Draw = union(enum) {
    /// One shared-atlas plane per upload tick; a resource operation, not a hit.
    residency: struct { slot: u16, plane: u16 },
    /// One present piece entry; only emitted when the packet admits the resource.
    presentation: struct {
        piece: u16,
        frame: u16,
        slot_base: u16,
        uv: [2]u8,
        size: [2]u8,
        palette_row: u8,
        flip: u8,
        v_wrap: u8,
    },
    /// A draw over the accepted world-art handler.  The handler resolves the
    /// actor sample and the target reaction; the composer only states the tick.
    actor_track: struct {
        track: []const u8,
        target_track: []const u8,
        track_tick: u16,
    },
};

pub const Pending = struct {
    kind: []const u8,
    blocker: Blocker,
};

pub const Cue = struct {
    kind: CueKind,
    at_tick: u16,
    acknowledged: bool,
};

pub const Frame = struct {
    tick: u16,
    phase: Phase,
    draws: [max_draws]Draw = undefined,
    draw_count: usize = 0,
    pending: ?Pending = null,
    cue: ?Cue = null,
    /// True only when every resource requested for this tick was drawable, no
    /// resource is pending, and the tick has already been simulated.
    acknowledged: bool = false,

    pub fn drawsSlice(self: *const Frame) []const Draw {
        return self.draws[0..self.draw_count];
    }
};

pub const CueKind = enum { contact, finish };

pub const Event = struct {
    kind: CueKind,
    at_tick: u16,
    rule: ?p.RuleEffect,
    partial: bool,
    acknowledged: bool,
};

pub const Delivery = struct {
    events: [max_events]Event = undefined,
    len: usize = 0,

    pub fn slice(self: *const Delivery) []const Event {
        return self.events[0..self.len];
    }
};

pub const Error = error{
    UnknownSpell,
    UnknownAttack,
    InvalidBoundary,
    FinishBeforeContact,
    ContactDuringUpload,
    PresentationPastContact,
    RuleUnavailable,
    ForgedPresentation,
    ResourceUnavailable,
    Rewind,
    InvalidSnapshot,
    SnapshotMismatch,
    InvalidPacket,
};

pub const Composer = struct {
    packet: *const p.Packet,
    kind: Kind,
    index: usize,
    contact: u16,
    finish: u16,
    cursor: u16 = 0,
    contact_delivered: bool = false,
    finish_delivered: bool = false,
    drawable: bool,
    partial: bool,
    impact_ack: bool,
    finish_ack: bool,

    /// Keep the packet pointer out of any serialized battle state; the pure
    /// `Snapshot` value is the persistence contract.
    pub fn jsonStringify(self: Composer, writer: anytype) !void {
        _ = self;
        try writer.write(null);
    }

    pub fn spell(self: *const Composer) *const p.Spell {
        return &self.packet.spells[self.index];
    }

    pub fn attack(self: *const Composer) *const p.Attack {
        return &self.packet.attacks[self.index];
    }

    pub fn id(self: *const Composer) []const u8 {
        return switch (self.kind) {
            .cast => self.spell().id,
            .attack => self.attack().id,
        };
    }

    fn uploadTicks(self: *const Composer) u16 {
        return switch (self.kind) {
            .cast => self.spell().upload_ticks,
            .attack => 0,
        };
    }

    fn presentTicks(self: *const Composer) u16 {
        return switch (self.kind) {
            .cast => self.spell().present_ticks,
            .attack => 0,
        };
    }

    fn primaryBlocker(target: *const p.Spell) ?Blocker {
        const priority = [_][]const u8{
            "palette_data_carrier",
            "palette_slot_range",
            "page_lifetime_unproven",
            "presentation_termination",
            "impact_timing",
            "finish_timing",
            "direct_plane_residency",
            "rule_partial",
        };
        for (priority) |code| {
            for (target.blockers) |entry| {
                if (std.mem.eql(u8, entry, code)) return Blocker.fromCode(code);
            }
        }
        return null;
    }

    fn spellHasBlocker(target: *const p.Spell, code: []const u8) bool {
        for (target.blockers) |entry| if (std.mem.eql(u8, entry, code)) return true;
        return false;
    }

    /// True after `advanceTo` delivered the one contact event.  An owner that
    /// wants the exact-equality impact gate to stay authoritative can use this
    /// to suppress a second application; the recommended integration applies at
    /// the event instead, so a multi-tick skip still executes the rule once.
    pub fn contactDelivered(self: *const Composer) bool {
        return self.contact_delivered;
    }

    pub fn finishDelivered(self: *const Composer) bool {
        return self.finish_delivered;
    }

    pub fn ruleEffect(self: *const Composer) ?p.RuleEffect {
        return switch (self.kind) {
            .cast => self.spell().rule_effect,
            .attack => self.attack().rule_effect,
        };
    }

    fn phaseAt(self: *const Composer, tick: u16) Phase {
        const upload = self.uploadTicks();
        const present = self.presentTicks();
        if (upload > 0 and tick < upload) return .upload;
        if (present > 0 and tick < upload + present) return .present;
        if (tick < self.contact) return .pre_contact;
        if (tick == self.contact) return .contact;
        if (tick < self.finish) return .post_contact;
        if (tick == self.finish) return .finish;
        return .done;
    }

    fn presentFrame(self: *const Composer, offset: u16) ?struct { piece: u16, frame: u16 } {
        var remaining = offset;
        for (self.spell().present_frames, 0..) |entry, index| {
            if (remaining < entry.ticks) return .{ .piece = entry.piece, .frame = @intCast(index) };
            remaining -= entry.ticks;
        }
        return null;
    }

    /// Pure per-tick view for the renderer.  Matches the existing draw boundary:
    /// one call per rendered effect tick, no mutation, no event.
    pub fn frameAt(self: *const Composer, tick: u16) Frame {
        var frame = Frame{ .tick = tick, .phase = self.phaseAt(tick) };
        switch (self.kind) {
            .cast => {
                const cast = self.spell();
                switch (frame.phase) {
                    .upload => {
                        frame.draws[0] = .{ .residency = .{
                            .slot = self.packet.atlas.slot_base + tick,
                            .plane = tick,
                        } };
                        frame.draw_count = 1;
                        frame.acknowledged = true;
                    },
                    .present => {
                        const offset = tick - self.uploadTicks();
                        const slot = self.presentFrame(offset) orelse {
                            frame.pending = .{ .kind = "presentation", .blocker = .presentation_termination };
                            return frame;
                        };
                        if (!self.drawable) {
                            frame.pending = .{ .kind = "presentation", .blocker = primaryBlocker(cast) orelse .presentation_termination };
                            return frame;
                        }
                        for (cast.present_pieces) |piece| {
                            if (piece.id != slot.piece) continue;
                            for (piece.entries) |entry| {
                                if (frame.draw_count >= max_draws) break;
                                frame.draws[frame.draw_count] = .{ .presentation = .{
                                    .piece = slot.piece,
                                    .frame = slot.frame,
                                    .slot_base = self.packet.atlas.slot_base,
                                    .uv = entry.uv,
                                    .size = entry.size,
                                    .palette_row = entry.palette_row,
                                    .flip = entry.flip,
                                    .v_wrap = entry.v_wrap,
                                } };
                                frame.draw_count += 1;
                            }
                        }
                        frame.acknowledged = frame.draw_count > 0 and tick <= self.cursor;
                    },
                    .pre_contact, .post_contact, .done => {
                        frame.acknowledged = true;
                    },
                    .contact => {
                        if (!self.contact_delivered) return frame;
                        const acknowledged = self.impact_ack and tick <= self.cursor;
                        frame.cue = .{ .kind = .contact, .at_tick = self.contact, .acknowledged = acknowledged };
                        frame.acknowledged = acknowledged;
                        if (!acknowledged) {
                            frame.pending = .{ .kind = "contact", .blocker = if (spellHasBlocker(cast, "impact_timing")) .impact_timing else primaryBlocker(cast) orelse .impact_timing };
                        }
                    },
                    .finish => {
                        if (!self.finish_delivered) return frame;
                        const acknowledged = self.finish_ack and tick <= self.cursor;
                        frame.cue = .{ .kind = .finish, .at_tick = self.finish, .acknowledged = acknowledged };
                        frame.acknowledged = acknowledged;
                        if (!acknowledged) {
                            frame.pending = .{ .kind = "finish", .blocker = if (spellHasBlocker(cast, "finish_timing")) .finish_timing else primaryBlocker(cast) orelse .finish_timing };
                        }
                    },
                }
            },
            .attack => {
                const strike = self.attack();
                if (tick < self.finish) {
                    frame.draws[0] = .{ .actor_track = .{
                        .track = strike.track,
                        .target_track = strike.target_track,
                        .track_tick = tick,
                    } };
                    frame.draw_count = 1;
                }
                switch (frame.phase) {
                    .contact => {
                        if (!self.contact_delivered) return frame;
                        const acknowledged = self.impact_ack and tick <= self.cursor;
                        frame.cue = .{ .kind = .contact, .at_tick = self.contact, .acknowledged = acknowledged };
                        frame.acknowledged = acknowledged;
                    },
                    .finish => {
                        if (!self.finish_delivered) return frame;
                        const acknowledged = self.finish_ack and tick <= self.cursor;
                        frame.cue = .{ .kind = .finish, .at_tick = self.finish, .acknowledged = acknowledged };
                        frame.acknowledged = acknowledged;
                    },
                    .done => frame.acknowledged = true,
                    else => frame.acknowledged = tick <= self.cursor,
                }
            },
        }
        return frame;
    }

    /// Advance the simulated cursor.  Crossing contact/finish emits each event
    /// exactly once, in order, regardless of how far the caller jumps.
    pub fn advanceTo(self: *Composer, tick: u16) Error!Delivery {
        if (tick > max_tick) return error.InvalidBoundary;
        if (tick < self.cursor) return error.Rewind;
        var delivery = Delivery{};
        if (!self.contact_delivered and tick >= self.contact) {
            delivery.events[delivery.len] = .{
                .kind = .contact,
                .at_tick = self.contact,
                .rule = self.ruleEffect(),
                .partial = self.partial,
                .acknowledged = self.impact_ack,
            };
            delivery.len += 1;
            self.contact_delivered = true;
        }
        if (!self.finish_delivered and tick >= self.finish) {
            delivery.events[delivery.len] = .{
                .kind = .finish,
                .at_tick = self.finish,
                .rule = null,
                .partial = false,
                .acknowledged = self.finish_ack,
            };
            delivery.len += 1;
            self.finish_delivered = true;
        }
        self.cursor = tick;
        return delivery;
    }

    /// Every finished state is a pure value: a serialized mid-cast/mid-present
    /// continuation resumes the identical remaining frames and events.
    pub const Snapshot = struct {
        version: u16 = snapshot_version,
        kind: Kind,
        id: [max_id]u8 = @splat(0),
        id_len: u8 = 0,
        contact: u16,
        finish: u16,
        cursor: u16,
        contact_delivered: bool,
        finish_delivered: bool,
        drawable: bool = false,
    };

    pub fn snapshot(self: *const Composer) Snapshot {
        var value = Snapshot{
            .kind = self.kind,
            .contact = self.contact,
            .finish = self.finish,
            .cursor = self.cursor,
            .contact_delivered = self.contact_delivered,
            .finish_delivered = self.finish_delivered,
            .drawable = self.drawable,
        };
        const name = self.id();
        const length = @min(name.len, max_id);
        @memcpy(value.id[0..length], name[0..length]);
        value.id_len = @intCast(length);
        return value;
    }

    pub fn restore(packet: *const p.Packet, value: Snapshot) Error!Composer {
        if (value.version != snapshot_version or value.id_len == 0 or value.id_len > max_id) return error.InvalidSnapshot;
        const identity = value.id[0..value.id_len];
        var composer = switch (value.kind) {
            .cast => beginCast(packet, identity, value.contact, value.finish) catch return error.SnapshotMismatch,
            .attack => beginAttack(packet, identity, value.contact, value.finish, true) catch return error.SnapshotMismatch,
        };
        if (value.cursor > max_tick) return error.InvalidSnapshot;
        if (value.contact_delivered != (value.cursor >= value.contact)) return error.InvalidSnapshot;
        if (value.finish_delivered != (value.cursor >= value.finish)) return error.InvalidSnapshot;
        if (value.finish_delivered and !value.contact_delivered) return error.InvalidSnapshot;
        if (value.drawable != composer.drawable) return error.InvalidSnapshot;
        composer.cursor = value.cursor;
        composer.contact_delivered = value.contact_delivered;
        composer.finish_delivered = value.finish_delivered;
        return composer;
    }
};

fn checkBoundaries(contact: u16, finish: u16) Error!void {
    if (contact == 0 or finish == 0 or contact > max_tick or finish > max_tick) return error.InvalidBoundary;
    if (finish <= contact) return error.FinishBeforeContact;
}

/// Begin a cast against the coordinator's cast boundaries.  The packet decides
/// whether the presentation resource is drawable; a caller cannot upgrade it.
pub fn beginCast(packet: *const p.Packet, spell_id: []const u8, contact: u16, finish: u16) Error!Composer {
    const index = p.spellIndex(packet, spell_id) orelse return error.UnknownSpell;
    const spell = packet.spells[index];
    try checkBoundaries(contact, finish);
    if (spell.rule_effect.steps.len == 0 or !spell.rule_effect.one_time) return error.RuleUnavailable;
    if (std.mem.eql(u8, spell.presentation_status, "ready") and spell.blockers.len != 0) return error.ForgedPresentation;
    if (contact <= spell.upload_ticks) return error.ContactDuringUpload;
    if (contact < spell.lead_ticks) return error.PresentationPastContact;

    const drawable = std.mem.eql(u8, spell.presentation_status, "ready");
    if (drawable and (spell.present_animation == null or spell.present_ticks == 0)) return error.InvalidPacket;
    return .{
        .packet = packet,
        .kind = .cast,
        .index = index,
        .contact = contact,
        .finish = finish,
        .drawable = drawable,
        .partial = std.mem.eql(u8, spell.rule_status, "partial"),
        .impact_ack = drawable and !Composer.spellHasBlocker(&spell, "impact_timing"),
        .finish_ack = drawable and !Composer.spellHasBlocker(&spell, "finish_timing"),
    };
}

/// Begin an attack over the accepted world-art handler.  A missing handler
/// resource refuses; there is no fallback sample and no silent success.
pub fn beginAttack(packet: *const p.Packet, attack_id: []const u8, contact: u16, finish: u16, resource_ready: bool) Error!Composer {
    const index = p.attackIndex(packet, attack_id) orelse return error.UnknownAttack;
    const attack = packet.attacks[index];
    if (!resource_ready) return error.ResourceUnavailable;
    try checkBoundaries(contact, finish);
    const expected_contact = if (std.mem.eql(u8, attack.kind, "attack")) "member_impact" else "projectile_impact_tick";
    const expected_finish = if (std.mem.eql(u8, attack.kind, "attack")) "member_duration" else "projectile_duration";
    if (!std.mem.eql(u8, attack.contact, expected_contact) or !std.mem.eql(u8, attack.finish, expected_finish)) return error.InvalidBoundary;
    if (attack.rule_effect.steps.len == 0 or !attack.rule_effect.one_time) return error.RuleUnavailable;
    return .{
        .packet = packet,
        .kind = .attack,
        .index = index,
        .contact = contact,
        .finish = finish,
        .drawable = true,
        .partial = false,
        .impact_ack = true,
        .finish_ack = true,
    };
}
