//! Source rules for the Stars of Destiny tablet.
//!
//! Every constant here is derived statically from STONE.BIN / MAIN.EXE /
//! SLUS_002.92 and frozen in the embedded asset by
//! the extraction pipeline.  The module performs no I/O, holds no
//! roster and never writes the recruit bytes.
//!
//! Source anchors:
//!   * cursor byte         state+0x2D (init 0 at 0x80080B14)
//!   * portrait index      0x80084BC0[e].byte0 (`0x80080F7C`, `0x80083440`)
//!   * recruit flag index  0x80084B40[e] + gs+0x1AF4 (`0x80080E58`, `0x80081CF4`)
//!   * listed              recruit byte != 0 (`0x80081D00`, `0x80081D0C`)
//!   * reveal              bit0 set and bit1 clear (`0x80080E60`..`0x80080E74`)
//!   * pages               0x80084E84 ranges, 0x80082940 lookup
//!   * navigation          `0x80080C38`..`0x80080D4C`

const data = @import("table.zig");

pub const entry_count = data.entry_count;
pub const page_count = data.page_count;
pub const cursor_max = data.cursor_max;
pub const scroll_step = data.scroll_step;

pub const Direction = enum { up, down };

pub const NameKind = enum {
    exact,
    prefix,
    suffix,
    player_named,
    unmatched,

    pub fn label(self: NameKind) []const u8 {
        return switch (self) {
            .exact => "exact",
            .prefix => "prefix",
            .suffix => "suffix",
            .player_named => "player_named_placeholder",
            .unmatched => "unmatched",
        };
    }
};

pub fn nameKind(record: *const data.Entry) NameKind {
    return switch (record.name_kind) {
        data.name_kind_exact => .exact,
        data.name_kind_prefix => .prefix,
        data.name_kind_suffix => .suffix,
        data.name_kind_player_named => .player_named,
        else => .unmatched,
    };
}

pub fn entry(index: u8) ?*const data.Entry {
    if (index >= entry_count) return null;
    return &data.entries[index];
}

pub fn page(index: u8) ?*const data.Page {
    if (index >= entry_count) return null;
    for (&data.pages) |*record| {
        if (index >= record.start and index <= record.end) return record;
    }
    return null;
}

pub fn pageOf(index: u8) ?u8 {
    const record = page(index) orelse return null;
    return record.index;
}

pub fn rowOf(index: u8) ?u8 {
    const record = page(index) orelse return null;
    return (index - record.start) / data.row_step;
}

pub fn colOf(index: u8) u8 {
    return index & 1;
}

pub fn scrollTarget(index: u8) ?i16 {
    const number = pageOf(index) orelse return null;
    return @as(i16, @intCast(number)) * data.scroll_step;
}

/// The source's own clamp arithmetic (`0x80080C68`, `0x80080D18`).
pub fn move(index: u8, direction: Direction) u8 {
    if (index >= entry_count) return index;
    return switch (direction) {
        .up => if (index >= 2) index - 2 else index,
        .down => if (index < 0x6A) index + 2 else index,
    };
}

/// Both left and right share one branch (`andi 0xA000` at `0x80080C38`).
pub fn toggle(index: u8) u8 {
    if (index >= entry_count) return index;
    return index ^ 1;
}

pub fn recruitByte(flags: []const u8, index: u8) ?u8 {
    const record = entry(index) orelse return null;
    if (record.recruit_index >= flags.len) return null;
    return flags[record.recruit_index];
}

/// Source list membership: an entry is drawn when its recruit byte is not zero.
pub fn listed(flags: []const u8, index: u8) bool {
    const value = recruitByte(flags, index) orelse return false;
    return value != 0;
}

/// Source confirm gate: bit0 recruited and bit1 clear.
pub fn detailEligible(flags: []const u8, index: u8) bool {
    const value = recruitByte(flags, index) orelse return false;
    return (value & data.recruited_bit) != 0 and (value & data.inactive_bit) == 0;
}

pub fn combatRow(index: u8) ?u8 {
    const record = entry(index) orelse return null;
    return if (record.combat_row == 0xFF) null else record.combat_row;
}

pub fn templateFor(index: u8) ?*const data.Template {
    const record = entry(index) orelse return null;
    for (&data.templates) |*template| {
        if (template.star_entry == record.entry) return template;
    }
    return null;
}

pub fn listedCount(flags: []const u8) u16 {
    var count: u16 = 0;
    var index: u8 = 0;
    while (index < entry_count) : (index += 1) {
        if (listed(flags, index)) count += 1;
    }
    return count;
}

pub fn eligibleCount(flags: []const u8) u16 {
    var count: u16 = 0;
    var index: u8 = 0;
    while (index < entry_count) : (index += 1) {
        if (detailEligible(flags, index)) count += 1;
    }
    return count;
}
