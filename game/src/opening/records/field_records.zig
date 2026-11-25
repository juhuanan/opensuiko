//! Field-only source NewGame records and opcode 0x3c active order.
//! SLUS 0x80017544 copies the persistent records at image 0x33274, stride 0x50.
//! Resource loading is owned by va1_entry; this owner never creates a resource.
const std = @import("std");
const field = @import("field");
const entry = @import("entry.zig");
const Member = field.game_state.Member;
const Item = field.items.Id;

/// Immutable source records, retained for later combat materialization. Raw
/// hex includes opaque bytes and source item/weapon/rune IDs, not battle profiles.
pub const Record = struct { id: u8, name: []const u8, display: []const u8, raw_hex: []const u8, sha256: []const u8 };
pub const ted_rune_binding = .{ .source_id = @as(u8, 32), .runtime_id = "masked_rune_32", .locked = true, .binding_sha256 = "f969285b96ba396adb3f1cc9b0f2a2c2001662c5433b7b3c441db8847fbb7eb2" };
pub const records = [_]Record{
    .{ .id = 8, .name = "hero", .display = "Hero", .raw_hex = "080000001100110000000000000100000d16120f0c0f00000607050706060505010001000a000200200004001c0005001900000600000000000000000000000000000000010100000000000000000000", .sha256 = "ae52c16bb8a9c121d4cabcb7727442c94d0d068815ab3e6a33f994f1b269a05b" },
    .{ .id = 108, .name = "ted", .display = "Ted", .raw_hex = "6c0000001200120000000000000100000d140a0f0c0f000005070406070404020900020019000006000000000000000000000000000000000000000000000000000000004d0300000000000020010000", .sha256 = "526a2c07bc9e85c0d83b70ae3771f130dd1f92a53e7ea82d9bdf8890356d044d" },
    .{ .id = 6, .name = "pahn", .display = "Pahn", .raw_hex = "060000001900190000000000000100001911120a030f000007050602000406030a0002000200010020000400000000000000000000000000000000000000000000000000030100000000000008010000", .sha256 = "85be65bd01092df06e3a7aa8737864ab72dd22246e5d789a41f24b432b4bb4d6" },
    .{ .id = 1, .name = "cleo", .display = "Cleo", .raw_hex = "010000001400140000000000000100000c140f0c1514000005060506060204030a0002002a00040019000006000000000000000000000000000000000000000000000000040100000000000000000000", .sha256 = "2ed6bc9bd86acccf201e2ee8f7e59322ee8ea3412a04133addb3f7fac7b53fda" },
    .{ .id = 2, .name = "gremio", .display = "Gremio", .raw_hex = "02000000160016000000000000010000110c100a070a00000d050603020505030b0002002600040019000006000000000000000000000000000000000000000000000000020100000000000000000000", .sha256 = "338216d4a4da2ae04d485e1574631bead1d9bdf669dc0ee9ab2a01819883ffcd" },
};
const empty: Member = .{ .id = "", .name = "", .hp = 0, .max_hp = 0, .status = .healthy, .rune_charges = @splat(0), .max_rune_charges = @splat(0) };
fn indexOf(id: u8) !usize {
    for (records, 0..) |r, i| if (r.id == id) return i;
    return error.UnsupportedCharacter;
}
fn raw(record: Record) [80]u8 {
    var result: [80]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, record.raw_hex) catch unreachable;
    return result;
}
fn item(id: u16) !Item {
    return switch (id) {
        1 => .bandanna,
        2 => .headband,
        9 => .robe,
        10 => .tunic,
        11 => .leather_coat,
        25 => .medicine,
        28 => .boots,
        32 => .gloves,
        38 => .cape,
        42 => .circlet,
        else => error.UnsupportedSourceItem,
    };
}
// MAIN 0x8016A60C, four rows of nine strictly-exceeded magic thresholds.
const thresholds = [4][9]u8{ .{ 15, 25, 35, 50, 70, 95, 120, 140, 170 }, .{ 40, 60, 80, 100, 123, 145, 160, 175, 193 }, .{ 75, 90, 110, 130, 150, 165, 188, 205, 220 }, .{ 130, 143, 155, 168, 183, 200, 215, 230, 240 } };
fn initialMember(record: Record) !Member {
    const bytes = raw(record);
    var m: Member = .{ .id = record.name, .name = record.display, .hp = std.mem.readInt(u16, bytes[6..8], .little), .max_hp = std.mem.readInt(u16, bytes[4..6], .little), .status = .healthy, .rune_charges = @splat(0), .max_rune_charges = @splat(0) };
    for (0..4) |i| m.rune_charges[i] = bytes[9 + i];
    // All equipment in these four source rows contributes zero magic.
    for (thresholds, 0..) |row, i| for (row) |threshold| {
        if (bytes[0x14] > threshold) m.max_rune_charges[i] += 1;
    };
    if (bytes[0x1f] > m.inventory.slots.len) return error.InvalidSourceInventory;
    for (0..bytes[0x1f]) |i| {
        const offset = 0x20 + 4 * i;
        m.inventory.slots[i] = .{ .id = try item(std.mem.readInt(u16, bytes[offset..][0..2], .little)), .uses = bytes[offset + 3], .identified = true };
    }
    return m;
}

pub const State = struct {
    entry: entry.EntryState,
    active: [6]Member,
    detached: [4]?Member,
    order: [6]u8,
    count: u8,
    area_party: ?[6]u8 = null,
    revision: u64 = 0,
    receipt: u64 = 0,
    checkpoint: u64 = 0,
};
/// Source equipment slot 1..5 mapped to the current inventory slot. Only the
/// untouched seed inventory is admitted until an equipment owner tracks edits.
pub const SeedEquipment = struct { inventory_indices: [5]?u8, locked: [5]bool };
pub fn seedEquipment(member: Member, source_id: u8) !SeedEquipment {
    const record = records[try indexOf(source_id)];
    const original = try initialMember(record);
    if (!std.mem.eql(u8, member.id, record.name)) return error.InvalidSourceMember;
    if (!entry.same(member.inventory, original.inventory)) return error.UnmodeledInventoryMutation;
    const bytes = raw(record);
    var result: SeedEquipment = .{ .inventory_indices = @splat(null), .locked = @splat(false) };
    for (0..bytes[0x1f]) |i| {
        const status = bytes[0x22 + 4 * i];
        if (status == 0) continue;
        const slot = status & 0x7f;
        if (slot == 0 or slot > 5 or result.inventory_indices[slot - 1] != null) return error.InvalidSourceInventory;
        result.inventory_indices[slot - 1] = @intCast(i);
        result.locked[slot - 1] = (status & 0x80) != 0;
    }
    return result;
}
pub const Proposal = struct { operand: u8, before: State, after: State };
pub const Owner = struct {
    state: State,
    /// Caller retains Hero's name storage. Entry state must be fully settled.
    pub fn init(hero: Member, loaded: entry.EntryState) !Owner {
        const checked = try entry.Entry.restore(loaded);
        if (loaded.pending != null or (try checked.propose(try std.math.add(u64, loaded.checkpoint, 1))) != null) return error.EntryLoadPending;
        if (!std.mem.eql(u8, hero.id, "hero")) return error.InvalidHero;
        var result: Owner = .{ .state = .{ .entry = loaded, .active = @splat(empty), .detached = @splat(null), .order = loaded.order, .count = 1 } };
        result.state.active[0] = hero;
        for (records[1..], 0..) |record, i| result.state.detached[i] = try initialMember(record);
        try result.validate();
        return result;
    }
    pub fn activeMembers(self: *Owner) []Member {
        return self.state.active[0..self.state.count];
    }
    pub fn validate(self: Owner) !void {
        const s = self.state;
        const loaded = try entry.Entry.restore(s.entry);
        if (s.entry.pending != null or (try loaded.propose(try std.math.add(u64, s.entry.checkpoint, 1))) != null or s.count == 0 or s.count > 5 or s.receipt != s.revision or (s.revision == 0) != (s.checkpoint == 0) or s.checkpoint < s.revision) return error.InvalidState;
        if ((s.revision == 0) != (s.area_party == null) or s.revision < s.count - 1) return error.InvalidState;
        var seen: [5]bool = @splat(false);
        for (s.active, 0..) |m, i| {
            if (i >= s.count) {
                if (!entry.same(m, empty)) return error.InvalidState;
                continue;
            }
            const slot = s.order[i];
            if (slot >= 6) return error.InvalidState;
            const id = s.entry.slots[slot];
            const idx = try indexOf(id);
            if (seen[idx] or !std.mem.eql(u8, m.id, records[idx].name) or (idx != 0 and !std.mem.eql(u8, m.name, records[idx].display))) return error.InvalidState;
            seen[idx] = true;
        }
        if (s.order[0] != 0 or !seen[0]) return error.InvalidState;
        for (s.order[s.count..]) |slot| if (slot != 0xfe) return error.InvalidState;
        for (s.detached, 0..) |maybe, i| {
            const idx = i + 1;
            if (maybe) |m| {
                if (seen[idx] or !std.mem.eql(u8, m.id, records[idx].name) or !std.mem.eql(u8, m.name, records[idx].display)) return error.InvalidState;
                // No detached mutation operation is admitted by this bounded owner.
                if (!entry.same(m, try initialMember(records[idx]))) return error.InvalidState;
                var one = [_]Member{m};
                try (field.game_state.Progress{ .money = 0, .party = &one }).validate();
                seen[idx] = true;
            }
        }
        for (seen) |present| if (!present) return error.InvalidState;
        var active = s.active;
        try (field.game_state.Progress{ .money = 0, .party = active[0..s.count] }).validate();
        if (s.area_party) |area| {
            var expected: [6]u8 = @splat(0xff);
            var i: usize = 0;
            for (s.entry.slots) |id| if (id != 0xff) {
                expected[i] = id;
                i += 1;
            };
            if (!std.mem.eql(u8, &expected, &area)) return error.InvalidState;
        }
    }
    /// Restore rebinds static IDs/names, and Hero's caller-owned live name.
    pub fn restore(saved: State, hero_name: []const u8) !Owner {
        var result: Owner = .{ .state = saved };
        try result.validate();
        if (!std.mem.eql(u8, saved.active[0].name, hero_name)) return error.InvalidHero;
        for (result.state.active[0..result.state.count]) |*m| {
            for (records) |record| if (std.mem.eql(u8, m.id, record.name)) {
                m.id = record.name;
                m.name = if (record.id == 8) hero_name else record.display;
                break;
            };
        }
        for (&result.state.detached, 0..) |*maybe, i| if (maybe.*) |*m| {
            m.id = records[i + 1].name;
            m.name = records[i + 1].display;
        };
        return result;
    }
    fn replay(self: Owner, operand: u8, checkpoint: u64) !State {
        try self.validate();
        if (checkpoint <= self.state.checkpoint) return error.InvalidCheckpoint;
        const idx = try indexOf(operand);
        if (idx == 0) return error.UnsupportedCharacter;
        var next = self.state;
        if (std.mem.indexOfScalar(u8, &next.entry.slots, operand)) |slot| {
            for (next.order[0..next.count]) |active_slot| if (active_slot == slot) return error.UnmodeledNativePartyAppend;
            if (next.count >= 5) return error.UnmodeledNativePartyAppend;
            const member = next.detached[idx - 1] orelse return error.InvalidState;
            next.active[next.count] = member;
            next.detached[idx - 1] = null;
            next.order[next.count] = @intCast(slot);
            next.count += 1;
        }
        var area: [6]u8 = @splat(0xff);
        var count: usize = 0;
        for (next.entry.slots) |id| if (id != 0xff) {
            area[count] = id;
            count += 1;
        };
        next.area_party = area;
        next.revision = try std.math.add(u64, next.revision, 1);
        next.receipt = try std.math.add(u64, next.receipt, 1);
        next.checkpoint = checkpoint;
        return next;
    }
    pub fn proposeAdd(self: Owner, operand: u8, checkpoint: u64) !Proposal {
        return .{ .operand = operand, .before = self.state, .after = try self.replay(operand, checkpoint) };
    }
    pub fn commitAdd(self: *Owner, p: Proposal) !void {
        if (!entry.same(self.state, p.before)) return error.StaleBeforeState;
        const next = try self.replay(p.operand, p.after.checkpoint);
        if (!entry.same(next, p.after)) return error.InvalidProposal;
        self.state = next;
    }
};
