//! Actor pose/animation family catalogue.
//!
//! The catalogue in `game/assets/combat_systems/pose_families.json` is
//! produced from the residency contract, the A-H enemy domain and the disc.
//! It names, per party container and per area enemy record, the
//! animation clips of the `idle`, `attack`, `hurt`, `miss`, `down`,
//! `status_low_hp` and `critical` families plus the pose/piece/palette/page
//! metadata those clips sample.
//!
//! This module is the *admission* half.  It validates every supported binding
//! once at load: an animation must resolve to non-empty frames with a duration
//! in 1..256, a frame pose must exist with a source anchor, and every piece must
//! name a resident page and an in-range palette.  A resource that fails any of
//! those checks cannot be loaded, so no caller can silently substitute a
//! fallback pose or a zero delay.  A family the exporter marked `blocked` is
//! preserved with its stable reason and is never admitted.
//!
//! `victory` is blocked for every actor on purpose: the traced battle table has
//! no victory root, the S1 "victory" set is a contact-sheet reading rather than
//! an f-record index, and resolving it needs new art evidence.  Only the low-HP
//! stance is a proven status pose; other status poses stay unsupported.

const std = @import("std");
const validation = @import("validation");

pub const schema = "suikoden-combat-pose-families/1";

pub const Family = enum { idle, attack, hurt, miss, down, status_low_hp, critical, victory };
pub const Side = enum { party, enemy };
pub const State = enum { supported, blocked };

pub const Piece = struct {
    x: i16,
    y: i16,
    page: u8,
    u: u8,
    v: u8,
    width: u8,
    height: u8,
    palette: u8,
    flip_x: bool = false,
    flip_y: bool = false,
    outside_samples: u32 = 0,
};

pub const Pose = struct {
    index: u16,
    width: u16,
    height: u16,
    anchor_x: u16,
    anchor_y: u16,
    pieces: []const Piece,
};

pub const Palette = struct { index: u16, words: u16, sha256: []const u8 };
pub const Page = struct { index: u16, slot: u8, sha256: []const u8 };
pub const Frame = struct { pose: u16, ticks: u16 };
pub const Animation = struct { index: u16, frames: []const Frame, resolved: bool };
pub const Auxiliary = struct { kind: []const u8, script: u16 };

pub const Binding = struct {
    family: Family,
    state: State,
    static_pose: bool,
    animations: []const u16,
    auxiliary: []const Auxiliary,
    reaction_delay_ticks: ?u16 = null,
    camera_gate: bool = false,
    reason: ?[]const u8 = null,
    detail: ?[]const u8 = null,
};

pub const Actor = struct {
    id: []const u8,
    side: Side,
    resource: []const u8,
    resource_sha256: []const u8,
    resource_status: []const u8,
    pages: []const Page,
    palettes: []const Palette,
    poses: []const Pose,
    animations: []const Animation,
    bindings: []const Binding,

    pub fn pose(self: *const Actor, index: u16) ?*const Pose {
        for (self.poses) |*entry| if (entry.index == index) return entry;
        return null;
    }

    pub fn animation(self: *const Actor, index: u16) ?*const Animation {
        for (self.animations) |*entry| if (entry.index == index) return entry;
        return null;
    }

    pub fn palette(self: *const Actor, index: u16) ?*const Palette {
        for (self.palettes) |*entry| if (entry.index == index) return entry;
        return null;
    }

    pub fn page(self: *const Actor, index: u16) ?*const Page {
        for (self.pages) |*entry| if (entry.index == index) return entry;
        return null;
    }

    pub fn binding(self: *const Actor, family: Family) ?*const Binding {
        for (self.bindings) |*binding_row| if (binding_row.family == family) return binding_row;
        return null;
    }
};

pub const Packet = struct {
    schema: []const u8,
    generated_by: []const u8 = "",
    content_sha256: []const u8,
    actors: []const Actor,
};

pub const LoadError = error{
    InvalidPacket,
    UnsupportedSchema,
    InvalidContentIdentity,
    DuplicateActor,
    DuplicatePose,
    DuplicateAnimation,
    DuplicatePalette,
    DuplicatePage,
    DuplicateBinding,
    MissingBinding,
    UnknownFamily,
    MissingPose,
    MissingPalette,
    MissingPage,
    InvalidAnchor,
    InvalidDuration,
    EmptyAnimation,
    NonResidentPiece,
    InvalidPiece,
    InvalidPose,
    EmptyPose,
    BlockedWithoutReason,
    InvalidBinding,
    EmptyStaticBinding,
};

pub const Catalogue = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(Packet),

    pub fn load(allocator: std.mem.Allocator, json: []const u8) !Catalogue {
        const parsed = std.json.parseFromSlice(Packet, allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.InvalidPacket;
        };
        errdefer parsed.deinit();
        try validatePacket(&parsed.value);
        return Catalogue{ .allocator = allocator, .parsed = parsed };
    }

    pub fn deinit(self: *Catalogue) void {
        self.parsed.deinit();
    }

    pub fn packet(self: *const Catalogue) *const Packet {
        return &self.parsed.value;
    }

    pub fn contentSha(self: *const Catalogue) []const u8 {
        return self.parsed.value.content_sha256;
    }

    pub fn actorIndex(self: *const Catalogue, id: []const u8) ?usize {
        for (self.parsed.value.actors, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.id, id)) return index;
        }
        return null;
    }

    pub fn actor(self: *const Catalogue, id: []const u8) ?*const Actor {
        const index = self.actorIndex(id) orelse return null;
        return &self.parsed.value.actors[index];
    }

    /// The family binding for an actor, including a blocked one, so a caller can
    /// report the source reason instead of inventing a fallback.
    pub fn bindingFor(self: *const Catalogue, id: []const u8, family: Family) ?*const Binding {
        const actor_row = self.actor(id) orelse return null;
        return actor_row.binding(family);
    }
};

fn isHex64(value: []const u8) bool {
    return validation.isHex64(value);
}

fn validatePacket(packet: *const Packet) LoadError!void {
    if (!std.mem.eql(u8, packet.schema, schema)) return error.UnsupportedSchema;
    if (!isHex64(packet.content_sha256)) return error.InvalidContentIdentity;
    if (packet.actors.len == 0) return error.InvalidPacket;
    for (packet.actors, 0..) |*actor, index| {
        if (actor.id.len == 0) return error.InvalidPacket;
        if (!isHex64(actor.resource_sha256)) return error.InvalidPacket;
        for (packet.actors[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id, actor.id)) return error.DuplicateActor;
        }
        try validateActor(actor);
    }
}

fn validateActor(actor: *const Actor) LoadError!void {
    for (actor.pages, 0..) |page, index| {
        if (!isHex64(page.sha256)) return error.InvalidPacket;
        for (actor.pages[0..index]) |previous| {
            if (previous.index == page.index) return error.DuplicatePage;
        }
    }
    for (actor.palettes, 0..) |palette, index| {
        if (palette.words != 32 and palette.words != 256) return error.InvalidPacket;
        if (!isHex64(palette.sha256)) return error.InvalidPacket;
        for (actor.palettes[0..index]) |previous| {
            if (previous.index == palette.index) return error.DuplicatePalette;
        }
    }
    for (actor.poses, 0..) |pose, index| {
        for (actor.poses[0..index]) |previous| {
            if (previous.index == pose.index) return error.DuplicatePose;
        }
        try validatePose(actor, &pose);
    }
    for (actor.animations, 0..) |animation_row, index| {
        for (actor.animations[0..index]) |previous| {
            if (previous.index == animation_row.index) return error.DuplicateAnimation;
        }
    }
    var seen: [@typeInfo(Family).@"enum".field_names.len]bool = @splat(false);
    for (actor.bindings, 0..) |binding_row, index| {
        const slot = @backingInt(binding_row.family);
        if (seen[slot]) return error.DuplicateBinding;
        seen[slot] = true;
        for (actor.bindings[0..index]) |previous| {
            if (previous.family == binding_row.family) return error.DuplicateBinding;
        }
        try validateBinding(actor, &binding_row);
    }
    for (seen) |present| if (!present) return error.MissingBinding;
}

fn validatePose(actor: *const Actor, pose: *const Pose) LoadError!void {
    if (pose.width == 0 or pose.height == 0) return error.InvalidPose;
    if (pose.anchor_x > 255 or pose.anchor_y > 255) return error.InvalidAnchor;
    if (pose.pieces.len == 0) return error.EmptyPose;
    for (pose.pieces) |piece| {
        if (piece.width == 0 or piece.height == 0) return error.InvalidPiece;
        if (piece.u >= 128 or piece.v >= 128) return error.InvalidPiece;
        if (piece.width > 128 or piece.height > 128) return error.InvalidPiece;
        if (actor.palette(piece.palette) == null) return error.MissingPalette;
        if (actor.page(piece.page) == null) return error.MissingPage;
    }
}

fn validateBinding(actor: *const Actor, binding_row: *const Binding) LoadError!void {
    switch (binding_row.state) {
        .blocked => {
            const reason = binding_row.reason orelse return error.BlockedWithoutReason;
            if (reason.len == 0) return error.BlockedWithoutReason;
            if (binding_row.animations.len != 0) return error.InvalidBinding;
            return;
        },
        .supported => {},
    }
    if (binding_row.static_pose) {
        if (binding_row.animations.len != 0) return error.EmptyStaticBinding;
        return;
    }
    if (binding_row.animations.len == 0) return error.InvalidBinding;
    for (binding_row.animations) |index| {
        const animation = actor.animation(index) orelse return error.MissingPose;
        if (!animation.resolved or animation.frames.len == 0) return error.EmptyAnimation;
        for (animation.frames) |frame| {
            if (frame.ticks == 0 or frame.ticks > 256) return error.InvalidDuration;
            const pose = actor.pose(frame.pose) orelse return error.MissingPose;
            for (pose.pieces) |piece| {
                if (actor.palette(piece.palette) == null) return error.MissingPalette;
                if (actor.page(piece.page) == null) return error.MissingPage;
                if (piece.outside_samples != 0) return error.NonResidentPiece;
            }
        }
    }
}
