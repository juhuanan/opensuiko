//! Opening first-town area host: one typed container for the source-backed models.
//!
//! The host deliberately exposes operations, not the original memory layout.
//! Event lowering supplies identities and operands; the models own the
//! source state transitions and validation.
const std = @import("std");
const tile = @import("area_tile.zig");
const callback = @import("area_callback.zig");
const dialogue = @import("dialogue_box.zig");
const upload = @import("sprite_upload.zig");
const room = @import("room_flags.zig");
const roster = @import("roster_edit.zig");
const transition = @import("area_transition.zig");
const predicate = @import("area_predicate.zig");

pub const Action = union(enum) {
    tile_variant: struct { tile: u8, op: tile.Op, absolute: u8 = 0 },
    area_callback: struct { selector: u8 },
    dialogue_open: struct { style: u8, handle: u32 },
    dialogue_update: struct { selector: u8, skip: u8 },
    sprite_upload: []const u8,
    room_flag: struct { id: u8, bits: u8 },
    roster_remove: struct { character: u8 },
    area_transition: struct { selector: u8, entry: u16 },
};

pub const Host = struct {
    tiles: tile.Table,
    area: callback.State = .{},
    box: dialogue.Box = .{},
    uploads: upload.Block = .{},
    room_flags: room.State = .{},
    party: roster.State = .{},
    transition: transition.State = .{},
    position: predicate.Position = .{ .x = 0, .y = 0 },
    pressed: u16 = 0,

    pub fn setVariant(self: *Host, tile_index: u8, op: tile.Op, absolute: u8) !bool {
        const descriptor = tile.resolve(&self.tiles, tile_index) orelse return error.UnknownAreaTile;
        const waiting = try tile.apply(&self.tiles, descriptor, op, absolute);
        return waiting;
    }

    pub fn installCallback(self: *Host, selector: u8) !callback.Result {
        return self.area.install(selector);
    }

    pub fn openBox(self: *Host, style: u8, handle: u32) !void {
        try self.box.open(style, handle);
    }

    pub fn updateBox(self: *Host, selector: u8, skip: u8) !dialogue.Box.Update {
        return self.box.update(selector, skip);
    }

    pub fn loadUploadBlock(self: *Host, bytes: []const u8) !void {
        self.uploads = try upload.Block.load(bytes);
    }

    pub fn orRoomFlag(self: *Host, id: u8, bits: u8) !void {
        try self.room_flags.orByte(id, bits);
    }

    pub fn removePartyMember(self: *Host, character: u8) bool {
        return self.party.remove(character);
    }

    pub fn beginTransition(self: *Host, selector: u8, entry: u16) void {
        self.transition.begin(selector, entry);
    }

    pub fn coordinateMatches(self: *const Host, axis: predicate.Axis, lower: u8, upper: u8, bounds: predicate.Bounds) bool {
        return predicate.coordinate(self.position, axis, lower, upper, bounds);
    }

    /// Apply one typed compiler action. Every arm reaches its source model;
    /// there is no default/no-op arm.
    pub fn apply(self: *Host, action: Action) !void {
        switch (action) {
            .tile_variant => |value| _ = try self.setVariant(value.tile, value.op, value.absolute),
            .area_callback => |value| _ = try self.installCallback(value.selector),
            .dialogue_open => |value| try self.openBox(value.style, value.handle),
            .dialogue_update => |value| _ = try self.updateBox(value.selector, value.skip),
            .sprite_upload => |value| try self.loadUploadBlock(value),
            .room_flag => |value| try self.orRoomFlag(value.id, value.bits),
            .roster_remove => |value| _ = self.removePartyMember(value.character),
            .area_transition => |value| self.beginTransition(value.selector, value.entry),
        }
    }
};
