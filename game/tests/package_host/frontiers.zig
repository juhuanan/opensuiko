//! Frontiers focused check: the source entry/resource rows, their refusals
//! and the two accepted consumers (service host and tablet view).
//!
//! Static/host level only: no original instruction, no emulator, no window, no
//! media playback and no real save.  The service transactions use a local test
//! engine so the check exercises the host's admission/return flow without
//! importing the field runtime.
const std = @import("std");
const frontiers_mod = @import("package_host").frontiers;
const hq_services = @import("hq").services;
const services_data = @import("hq_data").service_callers;
const data = frontiers_mod.data;
const entry = frontiers_mod.entry;
const consumers = frontiers_mod.consumers;

const allocator = std.testing.allocator;

fn opened(result: hq_services.OpenResult) hq_services.Host {
    return switch (result) {
        .opened => |host| host,
        .blocked => |blocked| {
            std.debug.print("unexpected block: {s} ({s})\n", .{ @tagName(blocked.reason), blocked.requirement orelse "-" });
            @panic("expected an opened host");
        },
    };
}

fn expectBlocked(result: hq_services.OpenResult) hq_services.Blocked {
    return switch (result) {
        .opened => @panic("expected a blocked result"),
        .blocked => |blocked| blocked,
    };
}

const Store = struct {
    inventory: [9]?u16 = .{ 25, null, null, null, null, null, null, null, null },
    storage: [4]u16 = .{ 0, 0, 0, 0 },

    fn deposit(ctx: *anyopaque, member: usize, slot: usize) anyerror!void {
        const self: *Store = @ptrCast(@alignCast(ctx));
        if (member != 0) return error.InvalidMember;
        if (slot != 0 or self.inventory[0] == null) return error.InvalidItem;
        self.storage[0] += 1;
        self.inventory[0] = null;
    }

    fn withdraw(ctx: *anyopaque, member: usize, native_id: u16) anyerror!void {
        const self: *Store = @ptrCast(@alignCast(ctx));
        if (member != 0) return error.InvalidMember;
        if (native_id != 25) return error.UnsupportedItem;
        if (self.storage[0] == 0) return error.ItemNotStored;
        self.storage[0] -= 1;
        self.inventory[0] = 25;
    }
};

fn engine(store: *Store) hq_services.Engine {
    return .{ .ctx = @ptrCast(store), .deposit = Store.deposit, .withdraw = Store.withdraw };
}

test "static descriptor rows are contiguous, aligned and fully resolved" {
    try std.testing.expectEqual(@as(usize, 62), data.castle_resources.len);
    try std.testing.expectEqualStrings("DATA/03_SHIRO/BOOKS.BIN", data.castle_resources[0].path);
    try std.testing.expectEqualStrings("DATA/03_SHIRO/DATA/FACE_23.BIN", data.castle_resources[61].path);
    for (data.castle_resources, 0..) |row, slot| {
        try std.testing.expectEqual(@as(u16, @intCast(slot)), row.slot);
        try std.testing.expectEqual(@as(u32, 0x8004500c) + @as(u32, row.table_index) * 8, row.descriptor);
        try std.testing.expectEqual(@as(u32, 0x353cc) + @as(u32, @intCast(slot)) * 4, row.offset);
        try std.testing.expect(row.lba != 0 and row.size != 0);
        for (data.castle_resources[0..slot]) |other| {
            try std.testing.expect(!std.mem.eql(u8, other.path, row.path));
        }
    }
    const stone = data.castle_resources[5];
    try std.testing.expectEqualStrings(data.stone_path, stone.path);
    try std.testing.expectEqual(data.stone_descriptor, stone.descriptor);
    try std.testing.expectEqual(data.stone_table_index, stone.table_index);
    try std.testing.expectEqual(@as(u32, 141092), stone.size);
    try std.testing.expectEqual(@as(u32, 81394), stone.lba);
}

test "castle header and module table are the overlay's own" {
    try std.testing.expectEqual(@as(u32, 0x80018afc), data.castle_header);
    try std.testing.expectEqual(@as(u32, 0x80018a4c), data.castle_module_table);
    try std.testing.expectEqual(@as(u8, 17), data.castle_module_count);
    try std.testing.expectEqual(@as(usize, 17), data.castle_module_entries.len);
    const end: u32 = data.load_base + 465788;
    var nulls: usize = 0;
    for (data.castle_module_entries) |module| {
        if (module.entry) |target| {
            try std.testing.expect(target >= data.load_base and target < end);
        } else {
            nulls += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 5), nulls);
    try std.testing.expectEqual(@as(u32, 0x800104c8), entry.moduleEntryOrNull(0).?);
    try std.testing.expect(entry.moduleEntryOrNull(1) == null);
    try std.testing.expect(entry.moduleEntryOrNull(16) == null);
}

test "special-content selector is exactly the 16 non-tablet resources" {
    try std.testing.expectEqual(@as(usize, 16), data.special_selectors.len);
    try std.testing.expectEqualStrings("DATA/16_WAR/WAR_KUWA.BIN", data.special_selectors[0].path);
    try std.testing.expectEqualStrings("DATA/03_SHIRO/KARUTA.BIN", data.special_selectors[15].path);
    try std.testing.expectEqual(@as(u8, 11), entry.specialSelector("DATA/03_SHIRO/COIN.BIN").?);
    try std.testing.expectEqual(@as(u8, 15), entry.specialSelector("DATA/03_SHIRO/KARUTA.BIN").?);
    try std.testing.expect(entry.specialSelector(data.stone_path) == null);
    try std.testing.expect(entry.specialSelector(data.azukari_path) == null);
    for (data.special_selectors, 0..) |row, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), row.selector);
    }
}

test "27 FACE pages and the 108-entry bijection" {
    try std.testing.expectEqual(@as(usize, 27), data.face_pages.len);
    for (data.face_pages, 0..) |page, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), page.page);
        try std.testing.expectEqual(@as(u32, 16384), page.decoded_bytes);
        try std.testing.expect(page.lba != 0 and page.size != 0);
        const expected = try std.fmt.allocPrint(allocator, "DATA/03_SHIRO/DATA/FACE_{d:0>2}.BIN", .{i + 1});
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, page.path);
    }
    var seen: [108]bool = @splat(false);
    for (data.face_pages) |page| {
        for (0..4) |cell| {
            const index = @as(usize, page.page) * 4 + cell;
            try std.testing.expect(!seen[index]);
            seen[index] = true;
        }
    }
    for (seen) |bit| try std.testing.expect(bit);
    try std.testing.expect(entry.facePage(27) == null);
}

test "tablet consumer: every reveal has a FACE page and quadrant" {
    const flags: [data.tablet_entry_count]u8 = @splat(0x01);
    const session = try frontiers_mod.tablet(flags);
    try std.testing.expectEqual(@as(u16, 108), session.listed());
    var reached: [108]bool = @splat(false);
    for (0..108) |index| {
        const reveal = session.view.reveal(@intCast(index)) orelse @panic("tablet entry not eligible");
        const portrait = session.portrait(@intCast(index)) orelse @panic("no FACE resource");
        try std.testing.expectEqual(reveal.portrait_page, portrait.page);
        try std.testing.expectEqual(reveal.portrait_cell, portrait.cell);
        try std.testing.expectEqual(reveal.portrait_index, portrait.war_plane);
        const expected_cell: u16 = @intCast(reveal.portrait_index & 3);
        try std.testing.expectEqual(expected_cell, portrait.x / 64 + (portrait.y / 64) * 2);
        const page = data.face_pages[reveal.portrait_page];
        try std.testing.expectEqualStrings(page.path, portrait.path);
        try std.testing.expectEqual(page.lba, portrait.lba);
        try std.testing.expectEqual(page.size, portrait.size);
        reached[reveal.portrait_index] = true;
    }
    for (reached) |bit| try std.testing.expect(bit);

    const empty: [data.tablet_entry_count]u8 = @splat(0x00);
    const hidden = try frontiers_mod.tablet(empty);
    try std.testing.expect(hidden.portrait(0) == null);
}

test "evidence refusals are typed, not defaults" {
    const stone = entry.tabletEvidence();
    try stone.verify();
    var wrong = stone;
    wrong.room = .area_c_vc2;
    try std.testing.expectError(error.WrongRoom, wrong.verify());
    var moved = stone;
    moved.descriptor += 8;
    try std.testing.expectError(error.ResourceMismatch, moved.verify());
    var offset = stone;
    offset.row_offset += 4;
    try std.testing.expectError(error.ResourceMismatch, offset.verify());

    const vc2 = entry.warehouseEvidence(.area_c_vc2).?;
    try vc2.verify();
    const vg1 = entry.warehouseEvidence(.area_g_vg1).?;
    try vg1.verify();
    try std.testing.expectEqualStrings("DATA/06_AREA.C/VC2.BIN", vc2.path);
    try std.testing.expectEqualStrings("DATA/10_AREA.G/VG1.BIN", vg1.path);
    try std.testing.expectEqual(@as(u32, 0x35250), vc2.row_offset);
    try std.testing.expectEqual(@as(u32, 0x35214), vg1.row_offset);
    try std.testing.expect(entry.warehouseEvidence(.castle_vb5b1) == null);
}

test "warehouse host frontier: source row admits only the non-canonical overlay" {
    var parsed = try hq_services.load(allocator, services_data.json);
    defer parsed.deinit();
    const packet = &parsed.value;

    const access: hq_services.Access = .{ .npc_present = true, .service_available = true };
    const result = try frontiers_mod.warehouse(packet, .area_c_vc2, access, 4);
    var host = opened(result);
    try std.testing.expectEqualStrings("azukari_entry", host.identity());
    try std.testing.expectEqual(hq_services.Phase.menu, host.phase);
    try std.testing.expectEqualStrings("azukari_entry", host.returnTarget());

    var store = Store{};
    const eng = engine(&store);
    const deposited = host.deposit(&eng, 0, 0);
    switch (deposited) {
        .ok => {},
        .failed => |blocked| {
            std.debug.print("deposit refused: {s}\n", .{@tagName(blocked.reason)});
            return error.UnexpectedRefusal;
        },
    }
    try std.testing.expectEqual(@as(u16, 1), store.storage[0]);
    try std.testing.expect(store.inventory[0] == null);
    try std.testing.expectEqual(hq_services.Phase.menu, host.phase);

    const withdrawn = host.withdraw(&eng, 0, 25);
    switch (withdrawn) {
        .ok => {},
        .failed => return error.UnexpectedRefusal,
    }
    try std.testing.expectEqual(@as(u16, 0), store.storage[0]);
    try std.testing.expect(store.inventory[0] == 25);
    try std.testing.expectEqual(@as(u32, 2), host.receipt.serial);

    // Canonical admission of the same id is refused by the accepted host.
    const canonical = hq_services.open(packet, "azukari_entry", access, 4);
    const blocked = expectBlocked(canonical);
    try std.testing.expectEqual(hq_services.BlockReason.non_canonical_caller, blocked.reason);
    // An invented overlay id is unknown rather than silently opened.
    const invented = hq_services.openOverlay(packet, "azukari_invented", access, 4);
    try std.testing.expectEqual(hq_services.BlockReason.unknown_caller, expectBlocked(invented).reason);
    // Missing/locked conditions are refused by the service host, never defaulted.
    const missing = try frontiers_mod.warehouse(packet, .area_c_vc2, .{ .npc_present = null, .service_available = true }, 4);
    try std.testing.expectEqual(hq_services.BlockReason.missing_condition, expectBlocked(missing).reason);
    const locked = try frontiers_mod.warehouse(packet, .area_c_vc2, .{ .npc_present = false, .service_available = true }, 4);
    try std.testing.expectEqual(hq_services.BlockReason.service_locked, expectBlocked(locked).reason);
    const stale = try frontiers_mod.warehouse(packet, .area_c_vc2, access, 0);
    try std.testing.expectEqual(hq_services.BlockReason.invalid_revision, expectBlocked(stale).reason);
    // A castle room cannot present the warehouse row.
    try std.testing.expectError(consumers.WarehouseError.UnknownRoom, consumers.warehouse(packet, .castle_vb5b1, access, 4));
}

test "no invented route, quest, war or media content is claimed" {
    // The warehouse table covers exactly the two mandatory SHIRO resources plus their rooms.
    try std.testing.expectEqual(@as(usize, 2), data.warehouse_rows.len);
    for (data.castle_resources) |row| {
        try std.testing.expect(std.mem.startsWith(u8, row.path, "DATA/03_SHIRO/"));
    }
    for (data.special_selectors) |row| {
        try std.testing.expect(!std.mem.eql(u8, row.path, data.stone_path));
        try std.testing.expect(!std.mem.eql(u8, row.path, data.azukari_path));
    }
    try std.testing.expectEqual(@as(u8, 27), data.face_page_count);
    try std.testing.expectEqual(@as(u8, 108), data.tablet_entry_count);
}
