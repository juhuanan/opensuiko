//! Source data: the 108-identity / 78-profile partition and the
//! twelve source roster operations the runtime is allowed to apply.
//!
//! The packet is derived by the extraction pipeline from MAIN.EXE and
//! SLUS_002.92.  This module validates it structurally and refuses a packet
//! whose operation effects disagree with the source semantics the roster
//! engine implements.  It does not trust a caller's string labels as evidence.
const std = @import("std");
const validation = @import("validation");

pub const schema = "suikoden-roster-source/1";
pub const max_packet_bytes = 256 * 1024;

pub const ActiveEffect = enum { none, add, remove, remove_nonhero, remove_one };
pub const SlotEffect = enum { none, assign, retain, clear, restore_status };
pub const RecruitEffect = enum { none, set, toggle };
pub const Effects = struct {
    active: ActiveEffect,
    slot: SlotEffect,
    recruit: RecruitEffect,
};
pub const Operation = struct {
    id: []const u8,
    family: []const u8,
    opcode: ?u8 = null,
    selector: ?u8 = null,
    source: []const u8,
    effects: Effects,
    preserve_member: bool,
    note: []const u8 = "",
};
pub const Identity = struct {
    index: u16,
    name: []const u8,
    combat_id: ?[]const u8 = null,
};
pub const Profile = struct {
    id: []const u8,
    name: []const u8,
    source_character_id: u16,
    identity: ?u16 = null,
};
pub const Guest = struct {
    id: []const u8,
    name: []const u8,
    source_character_id: u16,
};
pub const Counts = struct {
    identities: usize,
    combat_profiles: usize,
    noncombatant_identities: usize,
    guests: usize,
};
pub const Source = struct {
    main_sha256: []const u8,
    main_image_sha256: []const u8,
    slus_sha256: []const u8,
    slus_image_sha256: []const u8,
    catalogue_sha256: []const u8,
    identity_digest: []const u8,
    name_list_address: []const u8 = "",
    slus_character_address: []const u8 = "",
};
pub const Rules = struct {
    active_min: usize,
    active_max: usize,
    loaded_max: usize,
    reserve_max: usize,
    forced_removal: []const u8,
    temporary_scene_order: []const u8,
    followers: []const u8,
    noncombatants: []const u8,
    death: []const u8,
    preserve: []const []const u8,
};
pub const Packet = struct {
    schema: []const u8,
    task: []const u8,
    source: Source,
    rules: Rules,
    operations: []const Operation,
    identities: []const Identity,
    profiles: []const Profile,
    guests: []const Guest,
    counts: Counts,

    pub fn validate(self: Packet) !void {
        if (!std.mem.eql(u8, self.schema, schema) or !std.mem.eql(u8, self.task, "hq-roster")) return error.InvalidPacketSchema;
        if (self.identities.len != 108 or self.profiles.len != 78 or self.guests.len != 2) return error.InvalidPacketCensus;
        if (self.counts.identities != 108 or self.counts.combat_profiles != 78 or
            self.counts.guests != 2 or self.counts.noncombatant_identities != 32) return error.InvalidPacketCensus;
        if (self.rules.active_min != 1 or self.rules.active_max != 6 or
            self.rules.loaded_max != 6 or self.rules.reserve_max != 78) return error.InvalidPacketRules;
        if (!std.mem.eql(u8, self.rules.forced_removal, "reject_ordinary_allow_source") or
            !std.mem.eql(u8, self.rules.temporary_scene_order, "separate_from_roster") or
            !std.mem.eql(u8, self.rules.followers, "scene_only_never_roster") or
            !std.mem.eql(u8, self.rules.noncombatants, "ledger_only_no_profile") or
            !std.mem.eql(u8, self.rules.death, "hp_zero_unconscious_stays_owned")) return error.InvalidPacketRules;
        const digests = [_][]const u8{
            self.source.main_sha256,
            self.source.main_image_sha256,
            self.source.slus_sha256,
            self.source.slus_image_sha256,
            self.source.catalogue_sha256,
            self.source.identity_digest,
        };
        for (digests) |value| if (!isHex64(value)) return error.InvalidPacketDigest;
        // Identities: sequential index, unique name, exactly one combat profile per mapped id.
        var mapped: usize = 0;
        for (self.identities, 0..) |entry, i| {
            if (entry.index != i or entry.name.len == 0) return error.InvalidPacketIdentity;
            for (self.identities[0..i]) |prior| if (std.mem.eql(u8, prior.name, entry.name)) return error.InvalidPacketIdentity;
            if (entry.combat_id) |id| {
                if (id.len == 0) return error.InvalidPacketIdentity;
                mapped += 1;
            }
        }
        if (mapped != 76) return error.InvalidPacketIdentity;
        // Guests are combat records outside the 108 portrait identities, so
        // their profile carries a record id but no identity index.
        for (self.guests, 0..) |guest, i| {
            if (guest.id.len == 0 or guest.name.len == 0) return error.InvalidPacketGuest;
            if (guest.source_character_id != 108 and guest.source_character_id != 109) return error.InvalidPacketGuest;
            for (self.guests[0..i]) |prior| if (std.mem.eql(u8, prior.id, guest.id)) return error.InvalidPacketGuest;
            for (self.identities) |entry| if (entry.combat_id) |id| {
                if (std.mem.eql(u8, id, guest.id)) return error.InvalidPacketGuest;
            };
            var profile_found = false;
            for (self.profiles) |record| {
                if (!std.mem.eql(u8, record.id, guest.id)) continue;
                if (record.identity != null or record.source_character_id != guest.source_character_id) return error.InvalidPacketGuest;
                profile_found = true;
            }
            if (!profile_found) return error.InvalidPacketGuest;
        }
        var mapped_profiles: usize = 0;
        for (self.profiles, 0..) |record, i| {
            if (record.id.len == 0 or record.name.len == 0) return error.InvalidPacketProfile;
            for (self.profiles[0..i]) |prior| if (std.mem.eql(u8, prior.id, record.id)) return error.InvalidPacketProfile;
            if (record.identity) |index| {
                if (index >= self.identities.len) return error.InvalidPacketProfile;
                const entry = self.identities[index];
                const combat = entry.combat_id orelse return error.InvalidPacketProfile;
                if (!std.mem.eql(u8, combat, record.id)) return error.InvalidPacketProfile;
                mapped_profiles += 1;
            } else {
                var guest_found = false;
                for (self.guests) |guest| if (std.mem.eql(u8, guest.id, record.id)) {
                    guest_found = true;
                };
                if (!guest_found) return error.InvalidPacketProfile;
            }
        }
        if (mapped_profiles != 76) return error.InvalidPacketProfile;
        // Required source-operation effects.  These are the facts the roster
        // engine is allowed to cite when it applies a transition.
        try self.expect("opcode1f.load_slot", "forced_member", 0x1F, null, .{ .active = .add, .slot = .assign, .recruit = .set });
        try self.expect("opcode3c.rejoin_order", "rejoin", 0x3C, null, .{ .active = .add, .slot = .retain, .recruit = .none });
        try self.expect("opcode20.leave_temporary", "leave", 0x20, 0xFC, .{ .active = .remove, .slot = .retain, .recruit = .none });
        try self.expect("opcode20.leave_permanent", "leave", 0x20, 0xFE, .{ .active = .remove, .slot = .clear, .recruit = .toggle });
        try self.expect("opcode20.leave_all_nonhero", "leave", 0x20, 0xFF, .{ .active = .remove_nonhero, .slot = .clear, .recruit = .none });
        try self.expect("opcode20.leave_all_nonhero_fd", "leave", 0x20, 0xFD, .{ .active = .remove_nonhero, .slot = .clear, .recruit = .none });
        try self.expect("opcode20.leave_one", "leave", 0x20, null, .{ .active = .remove_one, .slot = .clear, .recruit = .none });
        try self.expect("opcode3b.scene_order", "scene_order", 0x3B, null, .{ .active = .none, .slot = .none, .recruit = .none });
        try self.expect("opcode36.follower_build", "follower", 0x36, null, .{ .active = .none, .slot = .none, .recruit = .none });
        try self.expect("opcode45.recruit_toggle", "recruit", 0x45, null, .{ .active = .none, .slot = .none, .recruit = .toggle });
        try self.expectBundle("battle.knockout", "death", null, null);
        try self.expectBundle("battle.exit", "death", null, null);
    }

    fn expect(self: Packet, id: []const u8, family: []const u8, opcode: ?u8, selector: ?u8, effects: Effects) !void {
        for (self.operations) |op| if (std.mem.eql(u8, op.id, id)) {
            if (!std.mem.eql(u8, op.family, family) or op.opcode != opcode or op.selector != selector or
                !std.meta.eql(op.effects, effects) or !op.preserve_member or op.source.len == 0) return error.InvalidPacketOperation;
            return;
        };
        return error.MissingPacketOperation;
    }
    fn expectBundle(self: Packet, id: []const u8, family: []const u8, opcode: ?u8, selector: ?u8) !void {
        for (self.operations) |op| if (std.mem.eql(u8, op.id, id)) {
            if (!std.mem.eql(u8, op.family, family) or op.opcode != opcode or op.selector != selector or
                !op.preserve_member or op.source.len == 0) return error.InvalidPacketOperation;
            return;
        };
        return error.MissingPacketOperation;
    }

    pub fn operation(self: Packet, id: []const u8) ?Operation {
        for (self.operations) |op| if (std.mem.eql(u8, op.id, id)) return op;
        return null;
    }
    pub fn requires(self: Packet, id: []const u8) !void {
        if (self.operation(id) == null) return error.MissingPacketOperation;
    }
    pub fn profile(self: Packet, id: []const u8) ?Profile {
        for (self.profiles) |candidate| if (std.mem.eql(u8, candidate.id, id)) return candidate;
        return null;
    }
    pub fn identityOfCombat(self: Packet, id: []const u8) ?u16 {
        for (self.profiles) |candidate| if (std.mem.eql(u8, candidate.id, id)) return candidate.identity;
        return null;
    }
    pub fn isCombat(self: Packet, id: []const u8) bool {
        return self.profile(id) != null;
    }
    pub fn isGuest(self: Packet, id: []const u8) bool {
        for (self.guests) |guest| if (std.mem.eql(u8, guest.id, id)) return true;
        return false;
    }
    pub fn identity(self: Packet, index: u16) ?Identity {
        if (index >= self.identities.len) return null;
        return self.identities[index];
    }
    pub fn noncombatant(self: Packet, index: u16) ?Identity {
        const entry = self.identity(index) orelse return null;
        if (entry.combat_id != null) return null;
        return entry;
    }
};

pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Packet) {
    if (bytes.len > max_packet_bytes) return error.PacketTooLarge;
    const parsed = try std.json.parseFromSlice(Packet, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

pub fn digest(packet: Packet) [32]u8 {
    var out: [32]u8 = undefined;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(schema);
    for (packet.identities) |entry| {
        hash.update(entry.name);
        hash.update(if (entry.combat_id) |id| id else "");
    }
    for (packet.profiles) |record| {
        hash.update(record.id);
        hash.update(record.name);
        var id: [2]u8 = undefined;
        std.mem.writeInt(u16, &id, record.source_character_id, .little);
        hash.update(&id);
        var index: [2]u8 = undefined;
        std.mem.writeInt(u16, &index, record.identity orelse 0xFFFF, .little);
        hash.update(&index);
    }
    for (packet.guests) |guest| {
        hash.update(guest.id);
        var id: [2]u8 = undefined;
        std.mem.writeInt(u16, &id, guest.source_character_id, .little);
        hash.update(&id);
    }
    hash.final(&out);
    return out;
}

pub fn isHex64(text: []const u8) bool {
    return validation.isHex64(text);
}
