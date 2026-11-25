//! Focused gate: tablet identity, reveal and paged ordinary-input view.
//!
//! Pure/port-level only: no original instruction, emulator, window, portrait
//! pixel decode or save file.  The committed evidence packet is read from the
//! repository root and checked against the generated typed rows, so a content
//! or identity change breaks this gate instead of drifting silently.

const std = @import("std");
const tablet_mod = @import("hq").tablet;
const data = @import("hq").tablet.data;

const finite = std.Io.Limit.limited(8 * 1024 * 1024);
const packet_path = "game/assets/hq/tablet.json";

const Combat = struct { row: u8, id: u8, name: []const u8 };
const EntryJson = struct {
    entry: u8,
    portrait_index: u8,
    portrait_page: u8,
    portrait_cell: u8,
    recruit_index: u8,
    clut_nibble: u8,
    name_index: u8,
    name_kind: u8,
    name: []const u8,
    stone_name: []const u8,
    combat: ?Combat = null,
};
const TailJson = struct {
    entry: u8,
    portrait_byte: u8,
    mode_byte: u8,
    status: []const u8,
    reason: []const u8,
};
const TemplateJson = struct {
    row: u8,
    id: u8,
    name: []const u8,
    file: []const u8,
    star_entry: ?u8 = null,
    binding: []const u8,
};
const PageJson = struct { index: u8, origin: u16, start: u8, end: u8, rows: u8, count: u8 };
const AnchorJson = struct {
    file: []const u8,
    address: []const u8,
    word: []const u8,
    @"asm": []const u8,
    rule: []const u8,
};
const ChecksJson = struct {
    star_entries: u8,
    star_bound_templates: u8,
    stars_without_template: u8,
    non_star_templates: u8,
    tail_entries: u8,
    page_total: u8,
};
const ReviewJson = struct { status: []const u8, note: []const u8 };
const Packet = struct {
    schema: []const u8,
    task: []const u8,
    version: []const u8,
    content_sha256: []const u8,
    entries: []EntryJson,
    pages: []PageJson,
    tail: []TailJson,
    templates: []TemplateJson,
    anchors: []AnchorJson,
    checks: ChecksJson,
    portrait_review: ReviewJson,
};

fn blankFlags() [data.entry_count]u8 {
    return @splat(0);
}

fn readPacket(allocator: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, packet_path, allocator, finite);
}

fn parsePacket(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Packet) {
    return std.json.parseFromSlice(Packet, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

fn packetDigest(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Move to an entry using ordinary intents only (source ±2 rows, pair toggle).
fn walkTo(view: *tablet_mod.View, target: u8) !void {
    while (view.cursor < target) {
        const step: u8 = target - view.cursor;
        _ = view.apply(if (step >= 2) .down else .right);
    }
}

test "packet is the committed evidence file and matches the typed rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const bytes = try readPacket(allocator);
    try std.testing.expectEqualStrings(data.tablet_sha256, &packetDigest(bytes));
    try std.testing.expectEqualStrings(data.schema, "suikoden-tablet/1");
    try std.testing.expectEqualStrings(data.version, "tablet.1");

    const parsed = try parsePacket(allocator, bytes);
    defer parsed.deinit();
    const packet = parsed.value;
    try std.testing.expectEqualStrings(data.schema, packet.schema);
    try std.testing.expectEqualStrings(data.version, packet.version);
    try std.testing.expectEqual(@as(usize, 108), packet.entries.len);
    try std.testing.expectEqual(@as(usize, 78), packet.templates.len);
    try std.testing.expectEqual(@as(usize, 34), packet.tail.len);
    try std.testing.expectEqual(@as(usize, 7), packet.pages.len);
    try std.testing.expect(packet.anchors.len >= 20);
    try std.testing.expectEqualStrings("not_assessed", packet.portrait_review.status);
    try std.testing.expectEqual(@as(u8, 108), packet.checks.star_entries);
    try std.testing.expectEqual(@as(u8, 76), packet.checks.star_bound_templates);
    try std.testing.expectEqual(@as(u8, 32), packet.checks.stars_without_template);
    try std.testing.expectEqual(@as(u8, 2), packet.checks.non_star_templates);
    try std.testing.expectEqual(@as(u8, 34), packet.checks.tail_entries);
    try std.testing.expectEqual(@as(u8, 108), packet.checks.page_total);

    for (packet.entries, data.entries) |json, typed| {
        try std.testing.expectEqual(json.entry, typed.entry);
        try std.testing.expectEqual(json.portrait_index, typed.portrait_index);
        try std.testing.expectEqual(json.portrait_page, typed.portrait_page);
        try std.testing.expectEqual(json.portrait_cell, typed.portrait_cell);
        try std.testing.expectEqual(json.recruit_index, typed.recruit_index);
        try std.testing.expectEqual(json.clut_nibble, typed.clut_nibble);
        try std.testing.expectEqual(json.name_kind, typed.name_kind);
        try std.testing.expectEqualStrings(json.name, typed.name);
        try std.testing.expectEqualStrings(json.stone_name, typed.stone_name);
        if (json.combat) |combat| {
            try std.testing.expectEqual(combat.row, typed.combat_row);
            try std.testing.expectEqual(combat.id, typed.combat_id);
            try std.testing.expectEqualStrings(combat.name, typed.combat_name);
        } else {
            try std.testing.expectEqual(@as(u8, 0xFF), typed.combat_row);
        }
    }
    for (packet.pages, data.pages) |json, typed| {
        try std.testing.expectEqual(json.index, typed.index);
        try std.testing.expectEqual(json.start, typed.start);
        try std.testing.expectEqual(json.end, typed.end);
        try std.testing.expectEqual(json.count, typed.count);
        try std.testing.expectEqual(json.rows, typed.rows);
    }
    for (packet.tail, data.tail) |json, typed| {
        try std.testing.expectEqual(json.entry, typed.entry);
        try std.testing.expectEqual(json.portrait_byte, typed.portrait_byte);
        try std.testing.expectEqual(json.mode_byte, typed.mode_byte);
        try std.testing.expectEqualStrings("unsupported", json.status);
        try std.testing.expect(json.reason.len > 0);
    }
    for (packet.templates, data.templates) |json, typed| {
        try std.testing.expectEqual(json.row, typed.row);
        try std.testing.expectEqual(json.id, typed.id);
        try std.testing.expectEqualStrings(json.name, typed.name);
        try std.testing.expectEqualStrings(json.file, typed.file);
        try std.testing.expectEqualStrings(json.binding, if (typed.binding == 0) "star" else "non_star");
        if (json.star_entry) |star| {
            try std.testing.expectEqual(star, typed.star_entry);
        } else {
            try std.testing.expectEqual(@as(u8, 0xFF), typed.star_entry);
        }
    }
    try std.testing.expectEqualStrings(data.tablet_sha256, &packetDigest(bytes));
    // the evidence packet names no image asset: this pack binds indices only
    try std.testing.expect(std.mem.indexOf(u8, bytes, ".png") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "textures/") == null);
}

test "108 recruit identities are distinct from 78 combat templates" {
    var portraits: [data.entry_count]bool = @splat(false);
    var recruits: [data.entry_count]bool = @splat(false);
    var bound: u8 = 0;
    var absent: u8 = 0;
    for (data.entries) |entry| {
        try std.testing.expect(!portraits[entry.portrait_index]);
        portraits[entry.portrait_index] = true;
        try std.testing.expect(!recruits[entry.recruit_index]);
        recruits[entry.recruit_index] = true;
        try std.testing.expect(entry.name.len > 0);
        if (entry.name_kind == data.name_kind_player_named) {
            try std.testing.expectEqual(@as(usize, 0), entry.stone_name.len);
        } else {
            try std.testing.expect(entry.stone_name.len > 0);
        }
        try std.testing.expect(entry.portrait_page < 27);
        try std.testing.expect(entry.portrait_cell < 4);
        try std.testing.expect(entry.clut_nibble < 16);
        if (entry.combat_row != 0xFF) {
            bound += 1;
            try std.testing.expect(entry.combat_row < 78);
            const template = data.templates[entry.combat_row];
            try std.testing.expectEqual(entry.recruit_index, template.id);
            try std.testing.expectEqual(entry.entry, template.star_entry);
            try std.testing.expectEqual(@as(u8, 0), template.binding);
            try std.testing.expectEqualStrings(entry.combat_name, template.name);
        } else {
            absent += 1;
        }
    }
    try std.testing.expectEqual(@as(u8, 76), bound);
    try std.testing.expectEqual(@as(u8, 32), absent);

    var non_star: u8 = 0;
    for (data.templates) |template| {
        if (template.binding == 1) {
            non_star += 1;
            try std.testing.expectEqual(@as(u8, 0xFF), template.star_entry);
            try std.testing.expect(template.id == 108 or template.id == 109);
        }
    }
    try std.testing.expectEqual(@as(u8, 2), non_star);

    const hero = data.entries[0];
    try std.testing.expectEqualStrings("Hero", hero.name);
    try std.testing.expectEqual(data.name_kind_player_named, hero.name_kind);
    try std.testing.expectEqual(@as(u8, 8), hero.recruit_index);

    const viktor = data.entries[12];
    try std.testing.expectEqualStrings("Viktor", viktor.name);
    try std.testing.expectEqual(@as(u8, 4), viktor.portrait_index);
    try std.testing.expectEqual(@as(u8, 1), viktor.portrait_page);
    try std.testing.expectEqual(@as(u8, 0), viktor.portrait_cell);
    try std.testing.expectEqual(@as(u8, 35), viktor.recruit_index);
    try std.testing.expectEqual(@as(u8, 5), viktor.combat_row);

    const mathiu = data.entries[2];
    try std.testing.expectEqualStrings("Mathiu", mathiu.name);
    try std.testing.expectEqual(@as(u8, 14), mathiu.portrait_index);
    try std.testing.expectEqual(@as(u8, 27), mathiu.recruit_index);
    try std.testing.expectEqual(@as(u8, 0xFF), mathiu.combat_row);
    try std.testing.expect(tablet_mod.source.templateFor(2) == null);
}

test "seven pages, two columns per row and the source cursor clamps" {
    try std.testing.expectEqual(@as(usize, 7), data.pages.len);
    const expected = [_][2]u8{
        .{ 0, 13 },  .{ 14, 29 }, .{ 30, 45 },  .{ 46, 61 },
        .{ 62, 77 }, .{ 78, 93 }, .{ 94, 107 },
    };
    for (data.pages, expected) |page, band| {
        try std.testing.expectEqual(band[0], page.start);
        try std.testing.expectEqual(band[1], page.end);
        try std.testing.expectEqual((page.end - page.start + 1) / 2, page.rows);
    }
    try std.testing.expectEqual(@as(u8, 0), tablet_mod.source.pageOf(13).?);
    try std.testing.expectEqual(@as(u8, 1), tablet_mod.source.pageOf(14).?);
    try std.testing.expectEqual(@as(u8, 6), tablet_mod.source.pageOf(107).?);
    try std.testing.expect(tablet_mod.source.pageOf(108) == null);
    try std.testing.expectEqual(@as(u8, 6), tablet_mod.source.rowOf(13).?);
    try std.testing.expectEqual(@as(u8, 0), tablet_mod.source.rowOf(14).?);
    try std.testing.expectEqual(@as(u8, 1), tablet_mod.source.colOf(13));
    try std.testing.expectEqual(@as(u8, 7), tablet_mod.source.rowOf(29).?);

    const flags = blankFlags();
    var view = tablet_mod.View.init(flags);
    try std.testing.expectEqual(@as(u8, 0), view.cursor);
    try std.testing.expectEqual(@as(u8, 0), view.page());
    try std.testing.expectEqual(@as(i16, 0), view.scroll_target);
    _ = view.apply(.down);
    _ = view.apply(.down);
    _ = view.apply(.right);
    _ = view.apply(.up);
    try std.testing.expectEqual(@as(u8, 3), view.cursor);

    view = tablet_mod.View.init(flags);
    var index: u8 = 0;
    while (index < 6) : (index += 1) _ = view.apply(.down);
    try std.testing.expectEqual(@as(u8, 12), view.cursor);
    _ = view.apply(.right);
    try std.testing.expectEqual(@as(u8, 13), view.cursor);
    _ = view.apply(.down);
    try std.testing.expectEqual(@as(u8, 15), view.cursor);
    try std.testing.expectEqual(@as(u8, 1), view.page());
    try std.testing.expectEqual(@as(i16, 240), view.scroll_target);
    _ = view.apply(.down);
    try std.testing.expectEqual(@as(u8, 17), view.cursor);
    _ = view.apply(.up);
    _ = view.apply(.right);
    _ = view.apply(.left);
    try std.testing.expectEqual(@as(u8, 15), view.cursor);

    view = tablet_mod.View.init(flags);
    _ = view.apply(.up);
    _ = view.apply(.up);
    try std.testing.expectEqual(@as(u8, 0), view.cursor);
    _ = view.apply(.right);
    try std.testing.expectEqual(@as(u8, 1), view.cursor);
    _ = view.apply(.right);
    _ = view.apply(.down);
    try std.testing.expectEqual(@as(u8, 2), view.cursor);

    view = tablet_mod.View.init(flags);
    index = 0;
    while (index < 53) : (index += 1) _ = view.apply(.down);
    try std.testing.expectEqual(@as(u8, 106), view.cursor);
    _ = view.apply(.down);
    try std.testing.expectEqual(@as(u8, 106), view.cursor);
    _ = view.apply(.right);
    try std.testing.expectEqual(@as(u8, 107), view.cursor);
    _ = view.apply(.down);
    try std.testing.expectEqual(@as(u8, 107), view.cursor);
    _ = view.apply(.up);
    try std.testing.expectEqual(@as(u8, 105), view.cursor);
    _ = view.apply(.down);
    try std.testing.expectEqual(@as(u8, 107), view.cursor);
}

test "source reveal and absence rules" {
    var flags = blankFlags();
    var view = tablet_mod.View.init(flags);
    try walkTo(&view, 12);
    try std.testing.expectEqual(@as(u8, 12), view.cursor);
    try std.testing.expect(!view.listed(12));
    try std.testing.expect(!view.detailEligible(12));
    switch (view.apply(.confirm)) {
        .blocked => |reason| try std.testing.expectEqual(tablet_mod.Reason.hidden, reason),
        else => return error.UnexpectedResult,
    }
    try std.testing.expect(view.lastReveal() == null);

    flags[35] = data.inactive_bit;
    view = tablet_mod.View.init(flags);
    try walkTo(&view, 12);
    try std.testing.expect(view.listed(12));
    try std.testing.expect(!view.detailEligible(12));
    switch (view.apply(.confirm)) {
        .blocked => |reason| try std.testing.expectEqual(tablet_mod.Reason.inactive, reason),
        else => return error.UnexpectedResult,
    }

    flags[35] = data.recruited_bit | data.inactive_bit;
    view = tablet_mod.View.init(flags);
    try walkTo(&view, 12);
    try std.testing.expect(view.listed(12));
    switch (view.apply(.confirm)) {
        .blocked => |reason| try std.testing.expectEqual(tablet_mod.Reason.inactive, reason),
        else => return error.UnexpectedResult,
    }

    flags[35] = data.recruited_bit;
    view = tablet_mod.View.init(flags);
    try walkTo(&view, 12);
    switch (view.apply(.confirm)) {
        .revealed => |reveal| {
            try std.testing.expectEqual(@as(u8, 12), reveal.entry);
            try std.testing.expectEqual(@as(u8, 4), reveal.portrait_index);
            try std.testing.expectEqual(@as(u8, 1), reveal.portrait_page);
            try std.testing.expectEqual(@as(u8, 0), reveal.portrait_cell);
            try std.testing.expectEqual(@as(u8, 35), reveal.recruit_index);
            try std.testing.expectEqual(@as(u8, 5), reveal.combat_row);
            try std.testing.expectEqualStrings("Viktor", reveal.name);
        },
        else => return error.UnexpectedResult,
    }
    try std.testing.expect(view.lastReveal() != null);
    try std.testing.expectEqual(@as(u8, 12), view.lastReveal().?.entry);

    flags = blankFlags();
    flags[27] = data.recruited_bit;
    view = tablet_mod.View.init(flags);
    try walkTo(&view, 2);
    switch (view.apply(.confirm)) {
        .revealed => |reveal| {
            try std.testing.expectEqual(@as(u8, 2), reveal.entry);
            try std.testing.expectEqual(@as(u8, 14), reveal.portrait_index);
            try std.testing.expectEqual(@as(u8, 3), reveal.portrait_page);
            try std.testing.expectEqual(@as(u8, 2), reveal.portrait_cell);
            try std.testing.expectEqual(@as(u8, 27), reveal.recruit_index);
            try std.testing.expectEqual(@as(u8, 0xFF), reveal.combat_row);
            try std.testing.expectEqualStrings("Mathiu", reveal.name);
        },
        else => return error.UnexpectedResult,
    }

    flags = @splat(1);
    view = tablet_mod.View.init(flags);
    try std.testing.expectEqual(@as(u16, 108), view.listedCount());
    flags = @splat(2);
    view = tablet_mod.View.init(flags);
    try std.testing.expectEqual(@as(u16, 108), view.listedCount());
    try std.testing.expectEqual(@as(u16, 0), tablet_mod.source.eligibleCount(&flags));
    flags = blankFlags();
    view = tablet_mod.View.init(flags);
    try std.testing.expectEqual(@as(u16, 0), view.listedCount());
}

test "browsing is ordinary input and leaves the roster untouched" {
    var flags = blankFlags();
    flags[35] = data.recruited_bit;
    const before = flags;
    var view = tablet_mod.View.init(flags);
    _ = view.apply(.down);
    _ = view.apply(.right);
    _ = view.apply(.left);
    _ = view.apply(.up);
    _ = view.apply(.cancel);
    try std.testing.expect(std.mem.eql(u8, &before, &view.flags));
    try std.testing.expect(view.closed);
    switch (view.apply(.down)) {
        .blocked => |reason| try std.testing.expectEqual(tablet_mod.Reason.closed, reason),
        else => return error.UnexpectedResult,
    }
    try std.testing.expect(view.snapshot() == null);
}

test "held repeat arms after sixteen frames then moves every six" {
    const flags = blankFlags();
    var view = tablet_mod.View.init(flags);
    var index: u8 = 0;
    while (index < 50) : (index += 1) _ = view.apply(.down);
    try std.testing.expectEqual(@as(u8, 100), view.cursor);
    _ = view.apply(.up);
    try std.testing.expectEqual(@as(u8, 98), view.cursor);
    index = 0;
    while (index < 15) : (index += 1) _ = view.hold(.up);
    try std.testing.expectEqual(@as(u8, 98), view.cursor);
    try std.testing.expect(!view.up_armed);
    _ = view.hold(.up);
    try std.testing.expectEqual(@as(u8, 98), view.cursor);
    try std.testing.expect(view.up_armed);
    try std.testing.expectEqual(data.repeat_next, view.up_counter);
    index = 0;
    while (index < 5) : (index += 1) _ = view.hold(.up);
    try std.testing.expectEqual(@as(u8, 98), view.cursor);
    _ = view.hold(.up);
    try std.testing.expectEqual(@as(u8, 96), view.cursor);
}

test "page scroll advances by the source 0xF0 step" {
    const flags = blankFlags();
    var view = tablet_mod.View.init(flags);
    var index: u8 = 0;
    while (index < 47) : (index += 1) _ = view.apply(.down);
    try std.testing.expectEqual(@as(u8, 94), view.cursor);
    try std.testing.expectEqual(@as(u8, 6), view.page());
    try std.testing.expectEqual(@as(i16, 1440), view.scroll_target);
    var calls: u8 = 0;
    var settled = false;
    while (!settled) {
        calls += 1;
        settled = view.stepScroll();
        if (calls > 10) return error.ScrollDidNotSettle;
    }
    try std.testing.expectEqual(@as(u8, 6), calls);
    try std.testing.expectEqual(@as(i16, 1440), view.scroll);
    try std.testing.expect(view.stepScroll());
}

test "browsing and the last reveal persist through a checked snapshot" {
    var flags = blankFlags();
    flags[35] = data.recruited_bit;
    var view = tablet_mod.View.init(flags);
    try walkTo(&view, 12);
    switch (view.apply(.confirm)) {
        .revealed => {},
        else => return error.UnexpectedResult,
    }
    const revision = view.revision;
    const snapshot = view.snapshot().?;
    const encoded = snapshot.encode();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "tablet.snap", .data = &encoded });
    const stored = try temporary.dir.readFileAlloc(std.testing.io, "tablet.snap", std.testing.allocator, finite);
    defer std.testing.allocator.free(stored);
    const decoded = try tablet_mod.Snapshot.decode(stored);
    var restored = try tablet_mod.View.restore(decoded, flags);
    try std.testing.expectEqual(@as(u8, 12), restored.cursor);
    try std.testing.expectEqual(@as(u8, 0), restored.page());
    try std.testing.expectEqual(revision, restored.revision);
    try std.testing.expectEqual(@as(u8, 12), restored.lastReveal().?.entry);
    try std.testing.expectEqualStrings("Viktor", restored.lastReveal().?.name);
    try std.testing.expectEqual(@as(u8, 5), restored.lastReveal().?.combat_row);
}

test "restore refuses a stale roster, packet, cursor or reveal" {
    var flags = blankFlags();
    flags[35] = data.recruited_bit;
    var view = tablet_mod.View.init(flags);
    try walkTo(&view, 12);
    switch (view.apply(.confirm)) {
        .revealed => {},
        else => return error.UnexpectedResult,
    }
    const snapshot = view.snapshot().?;

    var different = flags;
    different[35] = 0;
    try std.testing.expectError(error.FlagsMismatch, tablet_mod.View.restore(snapshot, different));

    var packet_bad = snapshot;
    packet_bad.tablet_sha256[0] ^= 0x01;
    try std.testing.expectError(error.PacketMismatch, tablet_mod.View.restore(packet_bad, flags));

    var cursor_bad = snapshot;
    cursor_bad.cursor = 200;
    try std.testing.expectError(error.CursorOutOfRange, tablet_mod.View.restore(cursor_bad, flags));

    var stale = snapshot;
    stale.revealed_entry = 3; // Luc 26 has no recruit bit in these flags
    try std.testing.expectError(error.StaleReveal, tablet_mod.View.restore(stale, flags));

    var bytes = snapshot.encode();
    bytes[7] ^= 0x01;
    try std.testing.expectError(error.InvalidSnapshot, tablet_mod.Snapshot.decode(&bytes));
}

test "unsupported source entries are precise, not invented" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const bytes = try readPacket(allocator);
    const parsed = try parsePacket(allocator, bytes);
    defer parsed.deinit();
    const packet = parsed.value;
    try std.testing.expectEqual(@as(usize, 34), packet.tail.len);
    for (packet.tail, 0..) |tail, offset| {
        try std.testing.expectEqual(@as(u8, @intCast(108 + offset)), tail.entry);
        try std.testing.expectEqualStrings("unsupported", tail.status);
        try std.testing.expect(tail.reason.len > 32);
    }
    try std.testing.expectEqualStrings("not_assessed", data.portrait_review);
    try std.testing.expectEqualStrings("not_assessed", packet.portrait_review.status);
    try std.testing.expect(std.mem.indexOf(u8, tablet_mod.tabletDocument(), "\"portrait_review\"") != null);
    // 32 absent combat profiles stay explicit absences
    var absent: u8 = 0;
    for (data.entries) |entry| {
        if (entry.combat_row == 0xFF) absent += 1;
    }
    try std.testing.expectEqual(@as(u8, 32), absent);
}
