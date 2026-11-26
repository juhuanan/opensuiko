//! Atomic publication of ordinary item operations and shared-ledger operations
//! for `item_ledger`.
//!
//! A publication is one proposal over every owner it touches:
//!
//!   * personal bag move / swap / discard / consume,
//!   * equipment loadout change against the host catalogue and the source
//!     eligibility mask,
//!   * warehouse deposit (identified bag entry gains one quantity) and withdraw
//!     (one quantity reconstructs the runtime item with its normal uses),
//!   * shared ledger acquire/remove over the seven-slot stable-id store,
//!   * weapon-fragment sidecar application.
//!
//! Failure at any step rejects the whole journal: the candidate snapshot is a
//! value copy, so the caller's state is byte-identical afterwards.  A persisted
//! journal replays against a baseline reconstructed from canonical data; a
//! stale revision/digest or an already-applied host receipt is refused.
const std = @import("std");
const field = @import("field");
const party = @import("party_session");
const packet = @import("catalogue.zig");
const owners = @import("owners.zig");
const ledger = @import("ledger.zig");
const journal = @import("journal.zig");

/// A source-qualified shared operation bound to reviewed packet identities.
/// The host derives these from its event table; `party.Sources.shared` can be
/// produced from the same rows.
pub const SharedBinding = struct {
    id: []const u8,
    source_operation: []const u8,
    item: []const u8,
    unique: bool = false,
};
pub const Sources = struct { shared: []const SharedBinding = &.{} };

pub const Proposal = struct {
    schema: u8 = owners.version,
    baseline_revision: u64,
    baseline_digest: u64,
    revision: u64,
    receipt: u64,
    snapshot: party.Snapshot,
};

pub const Outcome = struct { revision: u64, receipt: u64 };

pub fn receiptDigest(text: []const u8) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(text);
    return hasher.final();
}

pub fn validateSources(p: packet.Packet, sources: Sources) !void {
    for (sources.shared, 0..) |binding, index| {
        if (binding.id.len == 0 or binding.source_operation.len == 0 or binding.item.len == 0)
            return error.InvalidSharedOperation;
        for (sources.shared[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id, binding.id)) return error.InvalidSharedOperation;
        }
        const operation = packet.sourceOperation(p, binding.source_operation) orelse
            return error.UnknownSharedOperation;
        if (operation.effect == .deposit_identified) return error.DepositRequiresPersonalInventory;
        if (operation.status != .bound) return error.UnknownSharedOperation;
        if (packet.findById(p, binding.item) == null) return error.UnknownIdentity;
    }
}

fn bindingFor(sources: Sources, id: []const u8) ?*const SharedBinding {
    for (sources.shared) |*binding| {
        if (std.mem.eql(u8, binding.id, id)) return binding;
    }
    return null;
}

fn memberAt(snapshot: *party.Snapshot, index: usize) *field.game_state.Character {
    return &snapshot.members[index].?;
}

fn slotIndex(slot: owners.systems.EquipmentSlot) usize {
    return switch (slot) {
        .head => 0,
        .body => 1,
        .shield => 2,
        .accessory_one => 3,
        .accessory_two => 4,
    };
}

fn slotAccepts(slot: owners.systems.EquipmentSlot, required: packet.EquipmentSlot) bool {
    return switch (required) {
        .head => slot == .head,
        .body => slot == .body,
        .shield => slot == .shield,
        .feet_or_accessory => slot == .accessory_one or slot == .accessory_two,
    };
}

const SidecarElement = @FieldType(party.CharacterExtra, "weapon_element");

fn sidecarElement(fragment: packet.Fragment) SidecarElement {
    return switch (fragment) {
        .fire => .fire,
        .water => .water,
        .wind => .wind,
        .thunder => .thunder,
        .earth => .earth,
    };
}

/// One item operation against the candidate snapshot.  Every branch validates
/// the owner's own invariants before touching a slot, so a rejection leaves the
/// candidate untouched.
fn execute(p: packet.Packet, snapshot: *party.Snapshot, sources: Sources, catalogue: owners.Catalogue, command: journal.Command, revision: u32) !void {
    switch (command.kind) {
        .give => try give(snapshot, catalogue, command.member.?, command.slot.?, command.other.?),
        .swap => try swapItems(snapshot, catalogue, command.member.?, command.slot.?, command.other.?, command.other_slot.?),
        .equip => try equip(p, snapshot, catalogue, command.member.?, command.slot.?, command.item.?, command.character_type.?),
        .unequip => try unequip(snapshot, command.member.?, try equipmentSlotFor(command.slot.?)),
        .discard => try discard(snapshot, catalogue, command.member.?, command.slot.?),
        .deposit => try deposit(p, snapshot, catalogue, command.member.?, command.slot.?),
        .withdraw => try withdraw(p, snapshot, command.member.?, command.item.?),
        .shared_acquire => try sharedAcquire(p, snapshot, sources, revision, command.operation.?, command.item.?),
        .shared_remove => try sharedRemove(p, snapshot, sources, revision, command.operation.?, command.item.?),
        .apply_fragment => try applyFragment(p, snapshot, command.member.?, command.slot.?, command.other.?, command.replace),
        .consume => try consume(p, snapshot, command.member.?, command.slot.?),
    }
}

fn equipmentSlotFor(slot: u8) !owners.systems.EquipmentSlot {
    return switch (slot) {
        0 => .head,
        1 => .body,
        2 => .shield,
        3 => .accessory_one,
        4 => .accessory_two,
        else => error.InvalidSlot,
    };
}

fn checkedSlot(slot: u8) !u8 {
    if (slot > 4) return error.InvalidSlot;
    return slot;
}

fn give(snapshot: *party.Snapshot, catalogue: owners.Catalogue, from_id: []const u8, slot: u8, to_id: []const u8) !void {
    const from = try owners.activeIndex(snapshot.*, from_id);
    const to = try owners.activeIndex(snapshot.*, to_id);
    if (from == to) return error.InvalidRecipient;
    const source = &memberAt(snapshot, from).inventory;
    const destination = &memberAt(snapshot, to).inventory;
    if (slot >= source.count()) return error.InvalidItem;
    if (owners.wearsItem(catalogue, memberAt(snapshot, from).*, slot)) return error.EquippedItem;
    const count = destination.count();
    if (count == destination.slots.len) return error.InventoryFull;
    destination.slots[count] = source.slots[slot];
    source.remove(slot);
}

fn swapItems(snapshot: *party.Snapshot, catalogue: owners.Catalogue, first_id: []const u8, first_slot: u8, second_id: []const u8, second_slot: u8) !void {
    const first = try owners.activeIndex(snapshot.*, first_id);
    const second = try owners.activeIndex(snapshot.*, second_id);
    if (first == second) return error.InvalidRecipient;
    const source = &memberAt(snapshot, first).inventory;
    const destination = &memberAt(snapshot, second).inventory;
    if (first_slot >= source.count() or second_slot >= destination.count()) return error.InvalidItem;
    if (owners.wearsItem(catalogue, memberAt(snapshot, first).*, first_slot) or
        owners.wearsItem(catalogue, memberAt(snapshot, second).*, second_slot)) return error.EquippedItem;
    std.mem.swap(?field.items.Stack, &source.slots[first_slot], &destination.slots[second_slot]);
}

fn discard(snapshot: *party.Snapshot, catalogue: owners.Catalogue, member_id: []const u8, slot: u8) !void {
    const index = try owners.activeIndex(snapshot.*, member_id);
    const bag = &memberAt(snapshot, index).inventory;
    if (slot >= bag.count()) return error.InvalidItem;
    if (owners.wearsItem(catalogue, memberAt(snapshot, index).*, slot)) return error.EquippedItem;
    bag.remove(slot);
}

fn deposit(p: packet.Packet, snapshot: *party.Snapshot, catalogue: owners.Catalogue, member_id: []const u8, slot: u8) !void {
    const index = try owners.activeIndex(snapshot.*, member_id);
    const bag = &memberAt(snapshot, index).inventory;
    if (slot >= bag.count()) return error.InvalidItem;
    if (owners.wearsItem(catalogue, memberAt(snapshot, index).*, slot)) return error.EquippedItem;
    const stack = bag.slots[slot].?;
    const item = packet.findById(p, @tagName(stack.id)) orelse return error.ControllerIdentityUnbound;
    const eligible = try ledger.transferEligible(item, .{ .identified = stack.identified, .worn = false });
    if (!eligible) return error.DepositNotIdentified;
    try snapshot.storage.deposit(bag, slot);
}

fn withdraw(p: packet.Packet, snapshot: *party.Snapshot, member_id: []const u8, item_id: []const u8) !void {
    const index = try owners.activeIndex(snapshot.*, member_id);
    const item = packet.findById(p, item_id) orelse return error.UnknownIdentity;
    const identity = try owners.controllerIdentity(item);
    try snapshot.storage.withdraw(&memberAt(snapshot, index).inventory, identity);
}

fn equip(p: packet.Packet, snapshot: *party.Snapshot, catalogue: owners.Catalogue, member_id: []const u8, slot_value: u8, item_id: []const u8, character_type: u8) !void {
    const index = try owners.activeIndex(snapshot.*, member_id);
    _ = try checkedSlot(slot_value);
    const slot = try equipmentSlotFor(slot_value);
    if (character_type == 0) return error.CharacterTypeUnavailable;
    const item = packet.findById(p, item_id) orelse return error.UnknownIdentity;
    const required: packet.EquipmentSlot = switch (item.category) {
        .equipment_head => .head,
        .equipment_body => .body,
        .equipment_shield => .shield,
        .equipment_feet_or_accessory => .feet_or_accessory,
        else => return error.NotEquipment,
    };
    if (!slotAccepts(slot, required)) return error.EquipmentSlotMismatch;
    if ((item.equipment_type_mask & character_type) == 0) return error.EquipmentIneligible;
    const equipment_index = try owners.equipmentIndex(catalogue, item);
    const member = memberAt(snapshot, index);
    if (!catalogue[equipment_index].allows(member.id, slot)) return error.EquipmentIneligible;
    if (snapshot.extras[index].?.locked_equipment[slotIndex(slot)] and
        member.loadout.get(slot) != equipment_index) return error.EquipmentLocked;
    member.loadout.set(slot, equipment_index);
}

fn unequip(snapshot: *party.Snapshot, member_id: []const u8, slot: owners.systems.EquipmentSlot) !void {
    const index = try owners.activeIndex(snapshot.*, member_id);
    if (snapshot.extras[index].?.locked_equipment[slotIndex(slot)]) return error.EquipmentLocked;
    if (memberAt(snapshot, index).loadout.get(slot) == null) return error.NotEquipped;
    memberAt(snapshot, index).loadout.set(slot, null);
}

fn sharedAcquire(p: packet.Packet, snapshot: *party.Snapshot, sources: Sources, revision: u32, operation_id: []const u8, item_id: []const u8) !void {
    const binding = bindingFor(sources, operation_id) orelse return error.UnknownSharedOperation;
    const operation = packet.sourceOperation(p, binding.source_operation) orelse return error.UnknownSharedOperation;
    if (operation.effect != .shared_acquire) return error.SharedOperationWrongEffect;
    if (!std.mem.eql(u8, binding.item, item_id)) return error.InvalidSharedOperation;
    const item = packet.findById(p, item_id) orelse return error.UnknownIdentity;
    const view = try ledger.viewOf(p, snapshot.shared, revision);
    if (binding.unique and view.find(item.source_item_id) != null) return error.DuplicateItem;
    const applied = try ledger.apply(view, .acquire, item.source_item_id);
    snapshot.shared = try ledger.slotsOf(p, applied.view);
}

fn sharedRemove(p: packet.Packet, snapshot: *party.Snapshot, sources: Sources, revision: u32, operation_id: []const u8, item_id: []const u8) !void {
    const binding = bindingFor(sources, operation_id) orelse return error.UnknownSharedOperation;
    const operation = packet.sourceOperation(p, binding.source_operation) orelse return error.UnknownSharedOperation;
    if (operation.effect != .shared_remove) return error.SharedOperationWrongEffect;
    if (!std.mem.eql(u8, binding.item, item_id)) return error.InvalidSharedOperation;
    const item = packet.findById(p, item_id) orelse return error.UnknownIdentity;
    const view = try ledger.viewOf(p, snapshot.shared, revision);
    const applied = try ledger.apply(view, .remove, item.source_item_id);
    snapshot.shared = try ledger.slotsOf(p, applied.view);
}

fn applyFragment(p: packet.Packet, snapshot: *party.Snapshot, owner_id: []const u8, slot: u8, target_id: []const u8, replace: bool) !void {
    const owner = try owners.activeIndex(snapshot.*, owner_id);
    const target = try owners.activeIndex(snapshot.*, target_id);
    const bag = &memberAt(snapshot, owner).inventory;
    if (slot >= bag.count()) return error.InvalidItem;
    const stack = bag.slots[slot].?;
    const item = packet.findById(p, @tagName(stack.id)) orelse return error.FragmentUnbound;
    if (item.category != .weapon_fragment) return error.NotFragment;
    const fragment = item.weapon_fragment orelse return error.NotFragment;
    const element = sidecarElement(fragment);
    const extra = &snapshot.extras[target].?;
    const index: usize = @as(usize, @backingInt(element)) - 1;
    if (extra.weapon_element != .none and extra.weapon_element != element and !replace)
        return error.ReplacementConfirmationRequired;
    if ((extra.weapon_element == .none or extra.weapon_element == element) and
        extra.weapon_fragments[index] >= 9) return error.WeaponPieceLimit;
    var position: usize = 0;
    while (position < extra.weapon_fragments.len) : (position += 1) {
        if (position != index) extra.weapon_fragments[position] = 0;
    }
    extra.weapon_fragments[index] +%= 1;
    extra.weapon_element = element;
    bag.remove(slot);
}

fn consume(p: packet.Packet, snapshot: *party.Snapshot, member_id: []const u8, slot: u8) !void {
    const index = try owners.activeIndex(snapshot.*, member_id);
    const bag = &memberAt(snapshot, index).inventory;
    if (slot >= bag.count()) return error.InvalidItem;
    var stack = bag.slots[slot].?;
    if (stack.uses > std.math.maxInt(u8)) return error.UsesExceedMaximum;
    const plan = try ledger.prepareConsume(p, @tagName(stack.id), @intCast(stack.uses));
    if (plan.removes_entry) {
        bag.remove(slot);
    } else {
        stack.uses = plan.uses_after;
        bag.slots[slot] = stack;
    }
}

/// Build the atomic candidate.  Nothing here mutates caller-owned state.
pub fn prepare(p: packet.Packet, state: owners.State, sources: Sources, catalogue: owners.Catalogue, document: journal.Journal) !Proposal {
    try owners.validateState(p, state, catalogue);
    try journal.validate(document);
    try validateSources(p, sources);
    if (!std.mem.eql(u8, document.entry_id, state.snapshot.entry_id) or
        !std.mem.eql(u8, document.content_id, state.snapshot.content_id))
        return error.StaleJournal;
    if (document.baseline_revision != state.revision) return error.StaleJournal;
    if (state.revision + 1 > std.math.maxInt(u32)) return error.RevisionOverflow;
    const receipt = receiptDigest(document.receipt);
    if (state.receipts.contains(receipt)) return error.DuplicateReceipt;

    var candidate = state.snapshot;
    for (document.commands) |command| {
        try execute(p, &candidate, sources, catalogue, command, @intCast(state.revision + 1));
    }
    if (candidate.baseline_revision != state.revision) return error.InvalidState;
    const revision = std.math.add(u64, state.revision, 1) catch return error.RevisionOverflow;
    candidate.baseline_revision = revision;
    try owners.validateSnapshot(p, candidate, catalogue);
    return .{
        .baseline_revision = state.revision,
        .baseline_digest = owners.stateDigest(state.snapshot),
        .revision = revision,
        .receipt = receipt,
        .snapshot = candidate,
    };
}

/// Commit one proposal.  Every fallible check runs before the first mutation,
/// so a rejected commit leaves the state unchanged; the three assignments at
/// the end are the atomic publication.
pub fn commit(p: packet.Packet, state: *owners.State, catalogue: owners.Catalogue, proposal: Proposal, receipt_text: []const u8) !Outcome {
    if (proposal.schema != owners.version) return error.InvalidProposal;
    if (proposal.revision != proposal.baseline_revision + 1) return error.InvalidProposal;
    if (proposal.snapshot.baseline_revision != proposal.revision) return error.InvalidProposal;
    try owners.validateSnapshot(p, proposal.snapshot, catalogue);
    if (state.revision != proposal.baseline_revision) return error.StaleBaseline;
    if (owners.stateDigest(state.snapshot) != proposal.baseline_digest) return error.StaleBaseline;
    if (receipt_text.len == 0 or receipt_text.len > 256 or receiptDigest(receipt_text) != proposal.receipt)
        return error.InvalidReceipt;
    if (state.receipts.contains(proposal.receipt)) return error.DuplicateReceipt;
    var receipts = state.receipts;
    try receipts.append(proposal.receipt);
    var snapshot = proposal.snapshot;
    snapshot.receipt = receipt_text;
    state.snapshot = snapshot;
    state.receipts = receipts;
    state.revision = proposal.revision;
    return .{ .revision = state.revision, .receipt = proposal.receipt };
}

/// The ordinary host entry point: prepare, then commit against the same state.
/// The receipt text is host-owned and must outlive the published snapshot.
pub fn publish(p: packet.Packet, state: *owners.State, sources: Sources, catalogue: owners.Catalogue, document: journal.Journal) !Outcome {
    const proposal = try prepare(p, state.*, sources, catalogue, document);
    return commit(p, state, catalogue, proposal, document.receipt);
}
