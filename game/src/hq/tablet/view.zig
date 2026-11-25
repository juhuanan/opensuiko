//! Paged Stars of Destiny tablet view.
//!
//! Pure behaviour: a 108-byte recruit array (read-only), a cursor, a page
//! scroll and the source reveal rule.  `snapshot`/`restore` carry browsing and
//! the last reveal across a process restart and refuse a different roster.
//!
//! Nothing here renders, decodes portraits, owns input devices or writes the
//! recruit flags.  `Intent` values are ordinary input edges supplied by the
//! caller; `hold` is one held frame for the source auto-repeat.

const std = @import("std");
const data = @import("table.zig");
const source = @import("source.zig");

pub const version = data.version;
pub const entry_count = data.entry_count;
pub const page_count = data.page_count;
pub const snapshot_schema = "suikoden-tablet-view/1";
pub const snapshot_version: u16 = 1;
pub const snapshot_magic: u32 = 0x5354424C; // "STBL"
pub const snapshot_size = @sizeOf(Snapshot);

pub const Intent = enum { up, down, left, right, confirm, cancel };
pub const Direction = source.Direction;
pub const Reason = enum { hidden, inactive, closed, out_of_range };

pub const Reveal = struct {
    entry: u8,
    portrait_index: u8,
    portrait_page: u8,
    portrait_cell: u8,
    recruit_index: u8,
    /// 0xFF when the star has no combat record; never a fabricated profile.
    combat_row: u8,
    name: []const u8,
};

pub const Result = union(enum) {
    moved: u8,
    blocked: Reason,
    revealed: Reveal,
    closed: void,
};

fn digestFlags(flags: [entry_count]u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&flags, &digest, .{});
    return digest;
}

fn digestText(comptime text: []const u8) [32]u8 {
    @setEvalBranchQuota(100_000);
    var out: [32]u8 = undefined;
    var index: usize = 0;
    while (index < 32) : (index += 1) {
        out[index] = std.fmt.parseInt(u8, text[2 * index .. 2 * index + 2], 16) catch unreachable;
    }
    return out;
}

/// SHA-256 of the exact committed tablet.json bytes, as a raw digest.
pub const tablet_digest = digestText(data.tablet_sha256);

fn checksum(bytes: []const u8) u32 {
    var hash: u32 = 0x811c9dc5;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 0x01000193;
    }
    return hash;
}

/// A fixed-layout, checksummed browsing snapshot.
pub const Snapshot = extern struct {
    magic: u32 = snapshot_magic,
    layout: u16 = snapshot_version,
    reserved: u16 = 0,
    tablet_sha256: [32]u8 = @splat(0),
    flags_sha256: [32]u8 = @splat(0),
    cursor: u8 = 0,
    revealed_entry: u8 = 0xFF,
    up_counter: u8 = data.repeat_first,
    down_counter: u8 = data.repeat_first,
    up_armed: u8 = 0,
    down_armed: u8 = 0,
    revision: u32 = 0,
    scroll: i16 = 0,
    scroll_target: i16 = 0,
    checksum: u32 = 0,

    pub fn encode(self: Snapshot) [snapshot_size]u8 {
        var copy = self;
        copy.checksum = 0;
        copy.checksum = checksum(std.mem.asBytes(&copy));
        var bytes: [snapshot_size]u8 = undefined;
        bytes = std.mem.asBytes(&copy).*;
        return bytes;
    }

    pub fn decode(bytes: []const u8) !Snapshot {
        if (bytes.len != snapshot_size) return error.InvalidSnapshot;
        var copy: Snapshot = std.mem.zeroes(Snapshot);
        @memcpy(std.mem.asBytes(&copy), bytes);
        if (copy.magic != snapshot_magic or copy.layout != snapshot_version) return error.InvalidSnapshot;
        const saved = copy.checksum;
        copy.checksum = 0;
        if (checksum(std.mem.asBytes(&copy)) != saved) return error.InvalidSnapshot;
        copy.checksum = saved;
        return copy;
    }
};

pub const View = struct {
    flags: [entry_count]u8,
    cursor: u8 = 0,
    scroll: i16 = 0,
    scroll_target: i16 = 0,
    up_counter: u8 = data.repeat_first,
    down_counter: u8 = data.repeat_first,
    up_armed: bool = false,
    down_armed: bool = false,
    revision: u32 = 0,
    revealed_entry: u8 = 0xFF,
    closed: bool = false,

    pub fn init(flags: [entry_count]u8) View {
        var view = View{ .flags = flags };
        view.cursor = 0;
        view.scroll_target = source.scrollTarget(0) orelse 0;
        return view;
    }

    pub fn page(self: *const View) u8 {
        return source.pageOf(self.cursor) orelse 0;
    }

    pub fn row(self: *const View) u8 {
        return source.rowOf(self.cursor) orelse 0;
    }

    pub fn col(self: *const View) u8 {
        return source.colOf(self.cursor);
    }

    pub fn listed(self: *const View, index: u8) bool {
        return source.listed(&self.flags, index);
    }

    pub fn detailEligible(self: *const View, index: u8) bool {
        return source.detailEligible(&self.flags, index);
    }

    pub fn listedCount(self: *const View) u16 {
        return source.listedCount(&self.flags);
    }

    pub fn reveal(self: *const View, index: u8) ?Reveal {
        if (!source.detailEligible(&self.flags, index)) return null;
        const record = source.entry(index) orelse return null;
        return .{
            .entry = record.entry,
            .portrait_index = record.portrait_index,
            .portrait_page = record.portrait_page,
            .portrait_cell = record.portrait_cell,
            .recruit_index = record.recruit_index,
            .combat_row = record.combat_row,
            .name = record.name,
        };
    }

    pub fn lastReveal(self: *const View) ?Reveal {
        if (self.revealed_entry == 0xFF) return null;
        return self.reveal(self.revealed_entry);
    }

    fn syncTarget(self: *View) void {
        self.scroll_target = source.scrollTarget(self.cursor) orelse self.scroll_target;
    }

    fn blockReason(self: *const View, index: u8) ?Reason {
        if (index >= entry_count) return .out_of_range;
        if (!self.listed(index)) return .hidden;
        if (!self.detailEligible(index)) return .inactive;
        return null;
    }

    pub fn apply(self: *View, intent: Intent) Result {
        if (self.closed) return .{ .blocked = .closed };
        switch (intent) {
            .up => {
                self.cursor = source.move(self.cursor, .up);
                self.syncTarget();
                self.revision += 1;
                return .{ .moved = self.cursor };
            },
            .down => {
                self.cursor = source.move(self.cursor, .down);
                self.syncTarget();
                self.revision += 1;
                return .{ .moved = self.cursor };
            },
            .left, .right => {
                self.cursor = source.toggle(self.cursor);
                self.syncTarget();
                self.revision += 1;
                return .{ .moved = self.cursor };
            },
            .confirm => {
                if (self.blockReason(self.cursor)) |reason| return .{ .blocked = reason };
                self.revealed_entry = self.cursor;
                self.revision += 1;
                return .{ .revealed = self.reveal(self.cursor).? };
            },
            .cancel => {
                self.closed = true;
                return .{ .closed = {} };
            },
        }
    }

    /// One held frame of the source repeat timer (`0x80080CD4`/`0x80080D00`).
    pub fn hold(self: *View, direction: Direction) Result {
        if (self.closed) return .{ .blocked = .closed };
        const counter = switch (direction) {
            .up => &self.up_counter,
            .down => &self.down_counter,
        };
        const armed = switch (direction) {
            .up => &self.up_armed,
            .down => &self.down_armed,
        };
        counter.* -|= 1;
        if (counter.* != 0) return .{ .moved = self.cursor };
        if (!armed.*) {
            armed.* = true;
            counter.* = data.repeat_next;
            return .{ .moved = self.cursor };
        }
        counter.* = data.repeat_next;
        self.cursor = source.move(self.cursor, direction);
        self.syncTarget();
        self.revision += 1;
        return .{ .moved = self.cursor };
    }

    /// Advance the source's 0xF0 horizontal scroll one step. True when settled.
    pub fn stepScroll(self: *View) bool {
        if (self.scroll < self.scroll_target) {
            self.scroll = @min(self.scroll + data.scroll_step, self.scroll_target);
        } else if (self.scroll > self.scroll_target) {
            self.scroll = @max(self.scroll - data.scroll_step, self.scroll_target);
        }
        return self.scroll == self.scroll_target;
    }

    pub fn close(self: *View) void {
        self.closed = true;
    }

    pub fn snapshot(self: *const View) ?Snapshot {
        if (self.closed) return null;
        var snap: Snapshot = std.mem.zeroes(Snapshot);
        snap.magic = snapshot_magic;
        snap.layout = snapshot_version;
        snap.tablet_sha256 = tablet_digest;
        snap.flags_sha256 = digestFlags(self.flags);
        snap.cursor = self.cursor;
        snap.revealed_entry = self.revealed_entry;
        snap.up_counter = self.up_counter;
        snap.down_counter = self.down_counter;
        snap.up_armed = @intFromBool(self.up_armed);
        snap.down_armed = @intFromBool(self.down_armed);
        snap.revision = self.revision;
        snap.scroll = self.scroll;
        snap.scroll_target = self.scroll_target;
        return snap;
    }

    pub fn restore(stored: Snapshot, flags: [entry_count]u8) !View {
        if (!std.mem.eql(u8, &stored.tablet_sha256, &tablet_digest)) return error.PacketMismatch;
        const flags_digest = digestFlags(flags);
        if (!std.mem.eql(u8, &stored.flags_sha256, &flags_digest)) return error.FlagsMismatch;
        if (stored.cursor >= entry_count) return error.CursorOutOfRange;
        const target = source.scrollTarget(stored.cursor) orelse return error.CursorOutOfRange;
        if (stored.scroll_target != target) return error.ScrollMismatch;
        const limit: i16 = @as(i16, @intCast(page_count - 1)) * data.scroll_step;
        if (stored.scroll < 0 or stored.scroll > limit) return error.ScrollMismatch;
        if (stored.up_counter > data.repeat_first or stored.down_counter > data.repeat_first)
            return error.InvalidSnapshot;
        if (stored.revealed_entry != 0xFF and
            !source.detailEligible(&flags, stored.revealed_entry))
            return error.StaleReveal;
        var view = View.init(flags);
        view.cursor = stored.cursor;
        view.scroll = stored.scroll;
        view.scroll_target = stored.scroll_target;
        view.up_counter = stored.up_counter;
        view.down_counter = stored.down_counter;
        view.up_armed = stored.up_armed != 0;
        view.down_armed = stored.down_armed != 0;
        view.revision = stored.revision;
        view.revealed_entry = stored.revealed_entry;
        return view;
    }
};
