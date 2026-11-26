//! Caller-owned item/shared owner state for `item_ledger`.
//!
//! The adapter never owns canonical state.  It borrows the *existing* owner
//! representations and publishes a whole new value back into the caller's
//! snapshot only after every touched owner validates:
//!
//!   personal bag        `field.items.Inventory` (nine slots per member)
//!   equipment loadout   `battle_rules.Loadout` (five slots, catalogue indices)
//!   character sidecars  `party_session.CharacterExtra` (weapon fragments, locks)
//!   warehouse           `game_state.Storage` (per-item quantities)
//!   shared ledger       `party_session.Snapshot.shared` (seven stable ids)
//!
//! `save_file.zig` and the global game state are deliberately not imported.
const std = @import("std");
const field = @import("field");
const party = @import("party_session");
const packet = @import("catalogue.zig");

pub const systems = @import("battle_rules");
pub const items = field.items;
pub const Storage = field.game_state.storage.Storage;
pub const max_members = party.max_owned;
pub const party_size = 6;
pub const bag_capacity = 9;
pub const warehouse_capacity = field.game_state.storage.capacity;
pub const receipt_capacity = 16;
pub const version: u8 = 1;

/// The equipment catalogue supplied by the host.
pub const Catalogue = []const systems.Equipment;

pub const Receipts = struct {
    values: [receipt_capacity]u64 = @splat(0),
    len: u8 = 0,

    pub fn contains(self: Receipts, receipt: u64) bool {
        for (self.values[0..self.len]) |value| if (value == receipt) return true;
        return false;
    }
    pub fn append(self: *Receipts, receipt: u64) !void {
        if (self.len == receipt_capacity) return error.ReceiptJournalFull;
        if (self.contains(receipt)) return error.DuplicateReceipt;
        self.values[self.len] = receipt;
        self.len += 1;
    }
};

/// Canonical item state plus the publication revision and the applied-receipt
/// set.  IDs and receipts are host-owned: the journal never supplies them.
pub const State = struct {
    schema: u8 = version,
    revision: u64,
    receipts: Receipts = .{},
    snapshot: party.Snapshot,

    pub fn init(snapshot: party.Snapshot) !State {
        if (snapshot.baseline_revision == 0) return error.InvalidEntry;
        return .{ .revision = snapshot.baseline_revision, .snapshot = snapshot };
    }
};

pub fn validateState(p: packet.Packet, state: State, catalogue: Catalogue) !void {
    if (state.schema != version) return error.InvalidState;
    if (state.receipts.len > receipt_capacity) return error.InvalidState;
    if (state.revision == 0) return error.InvalidEntry;
    if (state.snapshot.baseline_revision != state.revision) return error.InvalidRevision;
    try validateSnapshot(p, state.snapshot, catalogue);
}

pub fn validateSnapshot(p: packet.Packet, snapshot: party.Snapshot, catalogue: Catalogue) !void {
    if (snapshot.schema != party.version) return error.InvalidState;
    if (snapshot.entry_id.len == 0 or snapshot.content_id.len == 0 or snapshot.receipt.len == 0)
        return error.InvalidEntry;
    if (snapshot.entry_id.len > 256 or snapshot.content_id.len > 256 or snapshot.receipt.len > 256)
        return error.InvalidEntry;

    var ended = false;
    var seen_active: usize = 0;
    for (snapshot.members, 0..) |maybe, index| {
        if (maybe) |member| {
            if (ended) return error.InvalidRoster;
            if (member.id.len == 0) return error.InvalidRoster;
            for (snapshot.members[0..index]) |prior| {
                if (prior != null and std.mem.eql(u8, prior.?.id, member.id))
                    return error.DuplicateMember;
            }
            try member.inventory.validate();
            const extra = snapshot.extras[index] orelse return error.MissingCharacterExtra;
            if (!std.mem.eql(u8, extra.member_id, member.id)) return error.InvalidCharacterExtra;
            const slots = [_]systems.EquipmentSlot{ .head, .body, .shield, .accessory_one, .accessory_two };
            for (slots, 0..) |slot, slot_index| {
                if (member.loadout.get(slot)) |equipment| {
                    if (equipment >= catalogue.len) return error.InvalidEquipmentIndex;
                } else if (extra.locked_equipment[slot_index]) return error.InvalidCharacterExtra;
            }
        } else {
            ended = true;
            if (snapshot.extras[index] != null) return error.InvalidCharacterExtra;
        }
    }

    var active_ended = false;
    for (snapshot.active, 0..) |maybe, index| {
        if (maybe) |id| {
            if (active_ended or id.len == 0) return error.InvalidParty;
            const member_index = try memberIndex(snapshot, id);
            if (!snapshot.eligible[member_index]) return error.MemberIneligible;
            for (snapshot.active[0..index]) |prior| {
                if (prior != null and std.mem.eql(u8, prior.?, id)) return error.DuplicateMember;
            }
            seen_active += 1;
        } else active_ended = true;
    }
    if (seen_active == 0) return error.InvalidParty;

    try snapshot.storage.validate();

    var shared_ended = false;
    for (snapshot.shared) |maybe| {
        if (maybe) |id| {
            if (shared_ended) return error.InvalidSharedItems;
            if (packet.findById(p, id) == null) return error.InvalidSharedItems;
        } else shared_ended = true;
    }
}

pub fn memberIndex(snapshot: party.Snapshot, id: []const u8) !usize {
    if (id.len == 0) return error.UnknownMember;
    for (snapshot.members, 0..) |maybe, index| {
        if (maybe) |member| {
            if (std.mem.eql(u8, member.id, id)) return index;
        }
    }
    return error.UnknownMember;
}

/// The existing journal only moves items for an active member; keep that rule.
pub fn activeIndex(snapshot: party.Snapshot, id: []const u8) !usize {
    const index = try memberIndex(snapshot, id);
    for (snapshot.active) |maybe| {
        if (maybe) |active| {
            if (std.mem.eql(u8, active, id)) return index;
        }
    }
    return error.MemberNotActive;
}

pub const wearsItem = field.game_state.wearsItem;

/// The runtime controller identity of a reviewed packet identity, if the
/// runtime can represent it at all.
pub fn controllerIdentity(item: *const packet.Item) !items.Id {
    if (item.controller.kind != .items_enum) return error.ControllerIdentityUnbound;
    const tag = item.controller.tag orelse return error.ControllerIdentityUnbound;
    return std.meta.stringToEnum(items.Id, tag) orelse error.ControllerIdentityUnbound;
}

pub fn equipmentIndex(catalogue: Catalogue, item: *const packet.Item) !usize {
    const identity = try controllerIdentity(item);
    const tag = @tagName(identity);
    for (catalogue, 0..) |equipment, index| {
        if (std.mem.eql(u8, equipment.id, tag)) return index;
    }
    return error.EquipmentUnavailable;
}

/// Digest of every item-owned field a publication may change.  It is the
/// stale-baseline witness: roster, story and save fields are not hashed
/// because the adapter must never change them.
pub fn stateDigest(snapshot: party.Snapshot) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    for (snapshot.members) |maybe| {
        if (maybe) |member| {
            hasher.update(&.{1});
            for (member.inventory.slots) |stack| {
                if (stack) |value| {
                    hasher.update(&.{1});
                    const tag = @tagName(value.id);
                    hasher.update(&.{@intCast(tag.len)});
                    hasher.update(tag);
                    var buffer: [2]u8 = undefined;
                    std.mem.writeInt(u16, &buffer, value.uses, .little);
                    hasher.update(&buffer);
                    hasher.update(&.{@intFromBool(value.identified)});
                } else hasher.update(&.{0});
            }
            for (std.enums.values(systems.EquipmentSlot)) |slot| {
                if (member.loadout.get(slot)) |index| {
                    hasher.update(&.{1});
                    var buffer: [4]u8 = undefined;
                    std.mem.writeInt(u32, &buffer, @intCast(index), .little);
                    hasher.update(&buffer);
                } else hasher.update(&.{0});
            }
        } else hasher.update(&.{0});
    }
    for (snapshot.extras) |maybe| {
        if (maybe) |extra| {
            hasher.update(&.{1});
            hasher.update(&.{@backingInt(extra.weapon_element)});
            hasher.update(&extra.weapon_fragments);
            for (extra.locked_equipment) |locked| hasher.update(&.{@intFromBool(locked)});
        } else hasher.update(&.{0});
    }
    for (std.enums.values(items.Id)) |id| {
        var buffer: [2]u8 = undefined;
        std.mem.writeInt(u16, &buffer, snapshot.storage.quantity(id), .little);
        hasher.update(&buffer);
    }
    for (snapshot.shared) |maybe| {
        if (maybe) |id| {
            hasher.update(&.{1});
            hasher.update(&.{@intCast(id.len)});
            hasher.update(id);
        } else hasher.update(&.{0});
    }
    return hasher.final();
}
