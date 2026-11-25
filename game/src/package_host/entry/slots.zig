//! Save-slot policy for the canonical title and pause-menu Save/Load surfaces.
//!
//! The packaged slot contract is three slots with a primary record and a
//! `.bak` sibling (`game/src/save_slots.zig` and `opening_save.zig`, both
//! read-only here).  A source three-slot table is *not* derived, so the count
//! is declared `port_contract` in `entry_policy.json` rather than claimed as
//! source behavior.
//!
//! What this file fixes is the *decision* the player's choice maps to, so the
//! host cannot accidentally treat an unreadable, newer-version or empty slot
//! like a normal save:
//!
//!   status   load                    save
//!   empty    notice "empty"          direct write
//!   ready    load                    explicit overwrite confirm, old kept as backup
//!   backup   load, disclose backup   explicit overwrite confirm, old kept as backup
//!   damaged  notice "unreadable"     explicit replace confirm
//!   future   notice "newer version"  refused; a newer save is never overwritten
//!
//! A backup is still a loadable save; a damaged primary with no usable backup
//! is not, and the two are reported separately.
const std = @import("std");

pub const count: usize = 3;

pub const Status = enum { empty, ready, backup, damaged, future };

pub const PartyMember = struct {
    name: []const u8,
    level: u8 = 1,
};

/// One slot as the host read it.  `name` is the full stored name (never a
/// placeholder label), `party` is the full preview list, and `roster_total` is
/// the campaign roster size the slot carries.
pub const SlotInfo = struct {
    status: Status = .empty,
    name: []const u8 = "",
    scene: []const u8 = "",
    level: u8 = 0,
    seconds: u64 = 0,
    order: u64 = 0,
    roster_total: u16 = 0,
    party: []const PartyMember = &.{},
};

pub const Loadable = struct {
    slot: usize,
    from_backup: bool,
};

pub fn loadable(info: SlotInfo) ?bool {
    return switch (info.status) {
        .ready => false,
        .backup => true,
        else => null,
    };
}

/// `Continue game` selects the most recently written loadable slot.  Ties
/// (equal order, e.g. a host that does not stamp recency) fall to the lowest
/// slot index, which is the slot the original save screen lists first.
pub fn latest(items: []const SlotInfo) ?Loadable {
    var best: ?Loadable = null;
    var best_order: u64 = 0;
    for (items, 0..) |info, index| {
        const from_backup = loadable(info) orelse continue;
        if (best == null or info.order > best_order) {
            best = .{ .slot = index, .from_backup = from_backup };
            best_order = info.order;
        }
    }
    return best;
}

pub const Overwrite = enum {
    none,
    confirm_then_backup,
    confirm_replace,
    refused,

    pub fn needsConfirm(self: Overwrite) bool {
        return self == .confirm_then_backup or self == .confirm_replace;
    }
};

pub fn overwriteFor(status: Status) Overwrite {
    return switch (status) {
        .empty => .none,
        .ready, .backup => .confirm_then_backup,
        .damaged => .confirm_replace,
        .future => .refused,
    };
}

pub fn statusLabel(status: Status) []const u8 {
    return switch (status) {
        .empty => "Empty",
        .ready => "Saved game",
        .backup => "Saved game (backup)",
        .damaged => "Unreadable save",
        .future => "Newer version",
    };
}

pub fn overwriteLabel(overwrite: Overwrite) []const u8 {
    return switch (overwrite) {
        .none => "Write this empty slot?",
        .confirm_then_backup => "Overwrite this save? The previous save is kept as a backup.",
        .confirm_replace => "Replace this unreadable save?",
        .refused => "A newer-version save is never overwritten.",
    };
}

test "latest prefers recency then the lowest slot" {
    var items: [count]SlotInfo = @splat(.{});
    try std.testing.expect(latest(&items) == null);
    items[2] = .{ .status = .ready, .order = 3 };
    items[0] = .{ .status = .backup, .order = 7 };
    items[1] = .{ .status = .damaged, .order = 9 };
    const newest = latest(&items).?;
    try std.testing.expectEqual(@as(usize, 0), newest.slot);
    try std.testing.expect(newest.from_backup);
    items[0].order = 7;
    items[2].order = 7;
    try std.testing.expectEqual(@as(usize, 0), latest(&items).?.slot);
}

test "future is loadable by nothing and overwritable by nothing" {
    const future = SlotInfo{ .status = .future };
    try std.testing.expect(loadable(future) == null);
    try std.testing.expectEqual(Overwrite.refused, overwriteFor(.future));
    try std.testing.expectEqual(Overwrite.confirm_replace, overwriteFor(.damaged));
    try std.testing.expectEqual(Overwrite.none, overwriteFor(.empty));
}
