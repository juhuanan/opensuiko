//! Focused item-ledger gates: reviewed item/shared identity binding, atomic
//! ordinary-item publication, seven-slot shared ledger receipts, stale and
//! duplicate rejection, and restart replay for a one-member and a full party.
const std = @import("std");
const battle = @import("battle");
const field = @import("field");
const party = @import("party_session");
const ledger_mod = @import("item_ledger");
const packet = ledger_mod.catalogue;
const owners = ledger_mod.owners;
const ledger = ledger_mod.ledger;
const journal = ledger_mod.journal;
const publish = ledger_mod.publish;

const asset_bytes = @import("campaign_policies_data").item_ledger.json;

const catalogue = [_]battle.systems.Equipment{
    .{ .id = "bandanna", .name = "Bandanna", .bonuses = @splat(0), .category = .head },
    .{ .id = "pointed_hat", .name = "Pointed hat", .bonuses = @splat(0), .category = .head },
    .{ .id = "tunic", .name = "Tunic", .bonuses = @splat(0), .category = .body },
    .{ .id = "wooden_shield", .name = "Wooden shield", .bonuses = @splat(0), .category = .shield },
    .{ .id = "boots", .name = "Boots", .bonuses = @splat(0), .category = .accessory },
    .{ .id = "gloves", .name = "Gloves", .bonuses = @splat(0), .category = .accessory },
    .{ .id = "cape", .name = "Cape", .bonuses = @splat(0), .category = .accessory },
};
const catalogue_slice: owners.Catalogue = &catalogue;

// The host owns the character record, so the test supplies the character type
// mask explicitly.  `maskOf`/`lowBit` derive a compatible value from the
// reviewed item mask; `missingBit` derives an incompatible one.
fn maskOf(p: packet.Packet, id: []const u8) u8 {
    return packet.findById(p, id).?.equipment_type_mask;
}
fn lowBit(mask: u8) u8 {
    return mask & (~mask +% 1);
}
fn missingBit(mask: u8) u8 {
    return (~mask) & 0x7f;
}

fn stack(id: field.items.Id, uses: u16) field.items.Stack {
    return .{ .id = id, .uses = uses };
}

fn memberRecord(id: []const u8, bag: []const field.items.Stack) battle.OwnedMember {
    var owned: battle.OwnedMember = .{
        .member = .{
            .id = id,
            .name = id,
            .hp = 10,
            .max_hp = 10,
            .status = .healthy,
            .rune_charges = @splat(0),
            .max_rune_charges = @splat(0),
            .inventory = .{},
        },
        .level = 1,
        .experience = 0,
        .stats = .{ .attack = 1, .defense = 1, .skill = 1, .speed = 1 },
        .weapon_level = 1,
        .loadout = .{},
        .rune = null,
    };
    for (bag, 0..) |entry, index| owned.member.inventory.slots[index] = entry;
    return owned;
}

const Fixture = struct {
    ids: []const []const u8,
    bags: []const []const field.items.Stack,

    fn build(self: Fixture, revision: u64) !party.Snapshot {
        if (self.ids.len == 0 or self.ids.len > 6 or self.ids.len != self.bags.len)
            return error.InvalidFixture;
        var snapshot: party.Snapshot = .{
            .entry_id = "entry-item-ledger",
            .content_id = "content-item-ledger",
            .receipt = "boot-receipt",
            .baseline_revision = revision,
        };
        for (self.ids, 0..) |id, index| {
            snapshot.members[index] = memberRecord(id, self.bags[index]);
            snapshot.extras[index] = .{ .member_id = id };
            snapshot.eligible[index] = true;
            snapshot.active[index] = id;
        }
        return snapshot;
    }
};

fn emptyBag() []const field.items.Stack {
    return &.{};
}

fn loadPacket() !std.json.Parsed(packet.Packet) {
    return packet.load(std.testing.allocator, asset_bytes);
}

fn document(commands: []const journal.Command, receipt: []const u8, revision: u64) journal.Journal {
    return .{
        .entry_id = "entry-item-ledger",
        .content_id = "content-item-ledger",
        .receipt = receipt,
        .baseline_revision = revision,
        .commands = @constCast(commands),
    };
}

fn sameSnapshot(a: party.Snapshot, b: party.Snapshot) bool {
    return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
}

fn bagTag(snapshot: party.Snapshot, member_index: usize, slot: usize) []const u8 {
    return @tagName(snapshot.members[member_index].?.member.inventory.slots[slot].?.id);
}

test "packet pins all 179 reviewed identities and the runtime controller split" {
    const parsed = try loadPacket();
    defer parsed.deinit();
    const p = parsed.value;

    try std.testing.expectEqual(@as(usize, 179), p.items.len);
    const enum_count: u16 = @intCast(std.enums.values(field.items.Id).len);
    try std.testing.expectEqual(enum_count, p.bindings.items_enum_bound);
    try std.testing.expectEqual(@as(u16, packet.item_count) - enum_count, p.bindings.unbound);
    try std.testing.expectEqual(enum_count, p.bindings.runtime_tags);
    try std.testing.expectEqual(@as(usize, 0), p.bindings.degraded_runtime_tags.len);
    try std.testing.expectEqualStrings(packet.expected_identity_digest, p.source.identity_digest);
    try std.testing.expectEqual(packet.identityDigest(p), std.fmt.parseInt(u64, packet.expected_identity_digest, 16) catch unreachable);

    // Every reviewed identity is addressable; exactly the bound ones reach the
    // existing runtime controller, the rest fail with a typed error.
    var bound: usize = 0;
    var unbound: usize = 0;
    for (p.items) |*item| {
        const identity = owners.controllerIdentity(item) catch |err| switch (err) {
            error.ControllerIdentityUnbound => {
                unbound += 1;
                continue;
            },
        };
        bound += 1;
        try std.testing.expectEqualStrings(identity.name(), item.label);
        try std.testing.expectEqual(identity.maxUses(), @as(u16, item.max_uses));
    }
    try std.testing.expectEqual(@as(usize, p.bindings.items_enum_bound), bound);
    try std.testing.expectEqual(@as(usize, p.bindings.unbound), unbound);

    // The duplicate label is not a duplicate identity.
    try std.testing.expectError(error.AmbiguousLabel, packet.findByLabel(p, "Mathiu's letter"));
    try std.testing.expectEqualStrings("Mathiu's letter", packet.findById(p, "mathiu_s_letter__source_90").?.label);
    try std.testing.expectEqualStrings("Mathiu's letter", packet.findById(p, "mathiu_s_letter__source_179").?.label);
    try std.testing.expectEqual(@as(u16, 90), packet.findById(p, "mathiu_s_letter__source_90").?.source_item_id);
    try std.testing.expectEqual(@as(u16, 179), packet.findById(p, "mathiu_s_letter__source_179").?.source_item_id);
    // Trailing spaces are kept, not trimmed.
    try std.testing.expectEqualStrings("Lover's garden ", packet.findById(p, "lover_s_garden").?.label);
    try std.testing.expectEqualStrings("Prodigy ", packet.findById(p, "prodigy").?.label);
    // The five source fragments stay distinct identities.
    try std.testing.expectEqual(packet.Fragment.fire, packet.findBySourceId(p, 57).?.weapon_fragment.?);
    for (57..62) |source_id| {
        const item = packet.findBySourceId(p, @intCast(source_id)).?;
        try std.testing.expectEqualStrings(item.id, @tagName(try owners.controllerIdentity(item)));
    }
    try std.testing.expectEqual(packet.Fragment.earth, packet.findBySourceId(p, 61).?.weapon_fragment.?);

    // A hand-edited packet is refused before any state is touched.
    var tampered = try std.testing.allocator.dupe(u8, asset_bytes);
    defer std.testing.allocator.free(tampered);
    tampered[tampered.len / 2] ^= 1;
    try std.testing.expectError(error.InvalidAssetHash, packet.load(std.testing.allocator, tampered));

    var items = try std.testing.allocator.dupe(packet.Item, p.items);
    defer std.testing.allocator.free(items);
    items[0].controller = .{ .kind = .items_enum, .tag = "medicine" };
    var mutated = p;
    mutated.items = items;
    try std.testing.expectError(error.InvalidControllerBinding, packet.validatePacket(mutated));
}

test "shared ledger appends at the tail, removes the first match and refuses a full store" {
    const parsed = try loadPacket();
    defer parsed.deinit();
    const p = parsed.value;

    const empty: [7]?[]const u8 = @splat(null);
    var view = try ledger.viewOf(p, empty, 1);
    try std.testing.expectEqual(@as(u8, 0), view.len);

    const bandanna = packet.findById(p, "bandanna").?;
    const tunic = packet.findById(p, "tunic").?;
    var applied = try ledger.apply(view, .acquire, bandanna.source_item_id);
    view = applied.view;
    try std.testing.expectEqual(@as(u8, 0), applied.target);
    applied = try ledger.apply(view, .acquire, tunic.source_item_id);
    view = applied.view;
    try std.testing.expectEqual(@as(u8, 1), applied.target);
    applied = try ledger.apply(view, .acquire, bandanna.source_item_id);
    view = applied.view;
    try std.testing.expectEqual(@as(u8, 2), applied.target);
    // Source append permits the duplicate; query reports first index and count.
    const query = try ledger.query(p, view, "bandanna");
    try std.testing.expectEqual(@as(?u8, 0), query.index);
    try std.testing.expectEqual(@as(u8, 2), query.count);
    // Remove takes the first matching slot and shifts the rest left.
    applied = try ledger.apply(view, .remove, bandanna.source_item_id);
    view = applied.view;
    try std.testing.expectEqual(@as(u8, 0), applied.target);
    try std.testing.expectEqual(@as(u8, 2), view.len);
    try std.testing.expectEqual(tunic.source_item_id, view.ids[0]);
    try std.testing.expectEqual(bandanna.source_item_id, view.ids[1]);
    try std.testing.expectError(error.ItemUnavailable, ledger.apply(view, .remove, packet.findById(p, "cape").?.source_item_id));

    // Seven slots are the whole ledger.
    var full: [7]?[]const u8 = @splat(null);
    const names = [_][]const u8{ "bandanna", "tunic", "cape", "boots", "gloves", "pointed_hat", "wooden_shield" };
    for (names, 0..) |name, index| full[index] = name;
    const full_view = try ledger.viewOf(p, full, 1);
    try std.testing.expectEqual(@as(u8, 7), full_view.len);
    try std.testing.expectError(error.SharedLedgerFull, ledger.apply(full_view, .acquire, packet.findById(p, "medicine").?.source_item_id));
    // Ownership is preserved: the owner's stable ids survive the round trip.
    const materialized = try ledger.slotsOf(p, full_view);
    try std.testing.expectEqualStrings("bandanna", materialized[0].?);
    try std.testing.expectEqualStrings("wooden_shield", materialized[6].?);

    // A prepared ledger operation is atomic and single-use.
    var prepared_view = try ledger.viewOf(p, empty, 3);
    const prepared = try ledger.prepare(p, prepared_view, .acquire, "suiko_map");
    try ledger.replay(p, &prepared_view, prepared);
    try std.testing.expectEqual(@as(u8, 1), prepared_view.len);
    try std.testing.expectError(error.StaleBaseline, ledger.replay(p, &prepared_view, prepared));
    var forged = prepared;
    forged.receipt ^= 1;
    var fresh = try ledger.viewOf(p, empty, 3);
    try std.testing.expectError(error.InvalidPrepared, ledger.replay(p, &fresh, forged));
    var wrong_len = prepared;
    wrong_len.result_len = 2;
    try std.testing.expectError(error.InvalidPrepared, ledger.replay(p, &fresh, wrong_len));
}

test "ordinary item operations and shared acquisition publish atomically" {
    const parsed = try loadPacket();
    defer parsed.deinit();
    const p = parsed.value;

    const hero_bag = [_]field.items.Stack{ stack(.medicine, 6), stack(.bandanna, 0), stack(.water_rune_piece, 0) };
    const gremio_bag = [_]field.items.Stack{};
    const ids = [_][]const u8{ "hero", "gremio" };
    const bags = [_][]const field.items.Stack{ &hero_bag, &gremio_bag };
    var state = try owners.State.init(try (Fixture{ .ids = &ids, .bags = &bags }).build(1));
    const baseline = state.snapshot;

    const sources = publish.Sources{ .shared = &.{
        .{ .id = "grant-key", .source_operation = "script_item_acquire", .item = "suiko_map" },
        .{ .id = "take-key", .source_operation = "script_item_remove", .item = "suiko_map" },
    } };
    const commands = [_]journal.Command{
        .{ .kind = .give, .member = "hero", .slot = 0, .other = "gremio" },
        .{ .kind = .deposit, .member = "gremio", .slot = 0 },
        .{ .kind = .withdraw, .member = "gremio", .item = "medicine" },
        .{ .kind = .equip, .member = "hero", .slot = 0, .item = "bandanna", .character_type = lowBit(maskOf(p, "bandanna")) },
        .{ .kind = .shared_acquire, .operation = "grant-key", .item = "suiko_map" },
        .{ .kind = .consume, .member = "gremio", .slot = 0 },
    };
    const doc = document(&commands, "receipt-one", 1);
    const outcome = try publish.publish(p, &state, sources, catalogue_slice, doc);
    try std.testing.expectEqual(@as(u64, 2), outcome.revision);
    try std.testing.expectEqual(@as(u64, 2), state.revision);
    try std.testing.expectEqual(@as(u8, 1), state.receipts.len);
    try std.testing.expectEqualStrings("receipt-one", state.snapshot.receipt);
    try std.testing.expectEqual(@as(u64, 1), state.snapshot.baseline_revision - 1);

    // The medicine moved hero -> gremio, was deposited into the warehouse and
    // withdrawn as a fresh normal-use entry.
    try std.testing.expectEqual(@as(usize, 2), state.snapshot.members[0].?.member.inventory.count());
    try std.testing.expectEqualStrings("bandanna", bagTag(state.snapshot, 0, 0));
    try std.testing.expectEqualStrings("water_rune_piece", bagTag(state.snapshot, 0, 1));
    try std.testing.expectEqual(@as(usize, 1), state.snapshot.members[1].?.member.inventory.count());
    try std.testing.expectEqualStrings("medicine", bagTag(state.snapshot, 1, 0));
    try std.testing.expectEqual(@as(u16, 5), state.snapshot.members[1].?.member.inventory.slots[0].?.uses);
    try std.testing.expectEqual(@as(u16, 0), state.snapshot.storage.quantity(.medicine));
    // The equipment owner kept the bag entry; the loadout points at the
    // catalogue entry, exactly like the existing controller.
    try std.testing.expectEqual(@as(?usize, 0), state.snapshot.members[0].?.loadout.head);
    // The shared slot holds the reviewed stable id, not a runtime tag.
    try std.testing.expectEqualStrings("suiko_map", state.snapshot.shared[0].?);
    try std.testing.expectEqual(@as(?[]const u8, null), state.snapshot.shared[1]);

    // Only item-owned fields moved: the roster, entry identity and story
    // ownership are byte-identical.
    try std.testing.expectEqualStrings(baseline.entry_id, state.snapshot.entry_id);
    try std.testing.expectEqualStrings(baseline.content_id, state.snapshot.content_id);
    try std.testing.expectEqual(baseline.active, state.snapshot.active);
    try std.testing.expectEqual(baseline.forced, state.snapshot.forced);
    try std.testing.expectEqual(baseline.followers, state.snapshot.followers);
    try std.testing.expectEqual(baseline.scene_order, state.snapshot.scene_order);
    try std.testing.expectEqual(baseline.eligible, state.snapshot.eligible);
    try std.testing.expectEqual(baseline.members[0].?.member.hp, state.snapshot.members[0].?.member.hp);
    try std.testing.expectEqualStrings(baseline.extras[0].?.member_id, state.snapshot.extras[0].?.member_id);
}

test "a failure anywhere in the journal publishes nothing" {
    const parsed = try loadPacket();
    defer parsed.deinit();
    const p = parsed.value;

    const hero_bag = [_]field.items.Stack{stack(.bandanna, 0)};
    const gremio_bag = [_]field.items.Stack{stack(.medicine, 6)};
    const ids = [_][]const u8{ "hero", "gremio" };
    const bags = [_][]const field.items.Stack{ &hero_bag, &gremio_bag };
    var state = try owners.State.init(try (Fixture{ .ids = &ids, .bags = &bags }).build(1));
    state.snapshot.storage.counts.medicine = owners.warehouse_capacity;
    const before = state.snapshot;
    const before_revision = state.revision;

    // The first command is valid; the second is a rejected full-store deposit.
    const commands = [_]journal.Command{
        .{ .kind = .give, .member = "hero", .slot = 0, .other = "gremio" },
        .{ .kind = .deposit, .member = "gremio", .slot = 0 },
    };
    const doc = document(&commands, "receipt-rollback", 1);
    try std.testing.expectError(error.StorageFull, publish.publish(p, &state, .{}, catalogue_slice, doc));
    try std.testing.expect(sameSnapshot(before, state.snapshot));
    try std.testing.expectEqual(before_revision, state.revision);
    try std.testing.expectEqual(@as(u8, 0), state.receipts.len);
    try std.testing.expectEqual(@as(usize, 1), state.snapshot.members[0].?.member.inventory.count());
    try std.testing.expectEqualStrings("medicine", bagTag(state.snapshot, 1, 0));
}

test "full, locked and unbound cases fail with typed errors and no mutation" {
    const parsed = try loadPacket();
    defer parsed.deinit();
    const p = parsed.value;

    const hero_bag = [_]field.items.Stack{ stack(.bandanna, 0), stack(.failure_urn, 0), stack(.pointed_hat, 0) };
    const full_bag = [_]field.items.Stack{
        stack(.medicine, 6),      stack(.antitoxin, 4), stack(.needle, 4), stack(.mega_medicine, 3),
        stack(.tunic, 0),         stack(.cape, 0),      stack(.boots, 0),  stack(.gloves, 0),
        stack(.wooden_shield, 0),
    };
    const ids = [_][]const u8{ "hero", "gremio" };
    const bags = [_][]const field.items.Stack{ &hero_bag, &full_bag };
    var state = try owners.State.init(try (Fixture{ .ids = &ids, .bags = &bags }).build(1));
    // An unconverted urn is identified=false, and the runtime allows that only
    // for decorations; the transfer predicate then demands identification.
    state.snapshot.members[0].?.member.inventory.slots[1].?.identified = false;
    const before = state.snapshot;

    const cases = [_]struct { expected: anyerror, command: journal.Command }{
        .{ .expected = error.InventoryFull, .command = .{ .kind = .give, .member = "hero", .slot = 0, .other = "gremio" } },
        .{ .expected = error.InvalidRecipient, .command = .{ .kind = .give, .member = "hero", .slot = 0, .other = "hero" } },
        .{ .expected = error.InvalidRecipient, .command = .{ .kind = .swap, .member = "hero", .slot = 0, .other = "hero", .other_slot = 1 } },
        .{ .expected = error.InvalidItem, .command = .{ .kind = .give, .member = "hero", .slot = 8, .other = "gremio" } },
        .{ .expected = error.EquipmentSlotMismatch, .command = .{ .kind = .equip, .member = "hero", .slot = 1, .item = "bandanna", .character_type = lowBit(maskOf(p, "bandanna")) } },
        .{ .expected = error.NotEquipment, .command = .{ .kind = .equip, .member = "hero", .slot = 0, .item = "medicine", .character_type = lowBit(maskOf(p, "bandanna")) } },
        .{ .expected = error.EquipmentUnavailable, .command = .{ .kind = .equip, .member = "hero", .slot = 0, .item = "head_gear", .character_type = lowBit(maskOf(p, "head_gear")) } },
        .{ .expected = error.EquipmentIneligible, .command = .{ .kind = .equip, .member = "hero", .slot = 0, .item = "bandanna", .character_type = missingBit(maskOf(p, "bandanna")) } },
        .{ .expected = error.CharacterTypeUnavailable, .command = .{ .kind = .equip, .member = "hero", .slot = 0, .item = "bandanna", .character_type = 0 } },
        .{ .expected = error.EquipmentIneligible, .command = .{ .kind = .equip, .member = "hero", .slot = 3, .item = "cape", .character_type = lowBit(maskOf(p, "bandanna")) } },
        .{ .expected = error.DepositNotIdentified, .command = .{ .kind = .deposit, .member = "hero", .slot = 1 } },
        .{ .expected = error.NotUsable, .command = .{ .kind = .consume, .member = "hero", .slot = 0 } },
        .{ .expected = error.NotEquipped, .command = .{ .kind = .unequip, .member = "hero", .slot = 0 } },
        .{ .expected = error.UnknownIdentity, .command = .{ .kind = .withdraw, .member = "hero", .item = "not_an_item" } },
        .{ .expected = error.UnknownSharedOperation, .command = .{ .kind = .shared_acquire, .operation = "missing", .item = "suiko_map" } },
        .{ .expected = error.SharedOperationWrongEffect, .command = .{ .kind = .shared_remove, .operation = "grant", .item = "suiko_map" } },
        .{ .expected = error.ItemUnavailable, .command = .{ .kind = .shared_remove, .operation = "take", .item = "suiko_map" } },
    };
    const sources = publish.Sources{ .shared = &.{
        .{ .id = "grant", .source_operation = "script_item_acquire", .item = "suiko_map" },
        .{ .id = "take", .source_operation = "script_item_remove", .item = "suiko_map" },
    } };
    // `cape` is accessory-category with a mask the hero type does not satisfy,
    // so the eligibility rule refuses it before the catalogue does.
    for (cases) |case| {
        const commands = [_]journal.Command{case.command};
        const doc = document(&commands, "receipt-reject", 1);
        try std.testing.expectError(case.expected, publish.publish(p, &state, sources, catalogue_slice, doc));
        try std.testing.expect(sameSnapshot(before, state.snapshot));
        try std.testing.expectEqual(@as(u64, 1), state.revision);
        try std.testing.expectEqual(@as(u8, 0), state.receipts.len);
    }

    var unbound_items: [packet.item_count]packet.Item = undefined;
    @memcpy(&unbound_items, p.items);
    try std.testing.expectEqualStrings("suiko_map", unbound_items[81].id);
    unbound_items[81].controller = .{ .kind = .unbound, .reason = .no_items_enum_member, .tag = null };
    var unbound_packet = p;
    unbound_packet.items = &unbound_items;
    const unbound_commands = [_]journal.Command{.{ .kind = .withdraw, .member = "hero", .item = "suiko_map" }};
    const unbound_doc = document(&unbound_commands, "receipt-reject-unbound", 1);
    try std.testing.expectError(error.ControllerIdentityUnbound, publish.publish(unbound_packet, &state, sources, catalogue_slice, unbound_doc));
    try std.testing.expect(sameSnapshot(before, state.snapshot));
    try std.testing.expectEqual(@as(u64, 1), state.revision);
    try std.testing.expectEqual(@as(u8, 0), state.receipts.len);

    // A source-qualified deposit binding is refused: that path stays with the
    // personal-inventory/warehouse owner.
    const deposit_sources = publish.Sources{ .shared = &.{
        .{ .id = "deposit", .source_operation = "script_item_deposit", .item = "medicine" },
    } };
    try std.testing.expectError(error.DepositRequiresPersonalInventory, publish.validateSources(p, deposit_sources));

    // Unique acquisition is refused only when the source operation declares it.
    const unique_sources = publish.Sources{ .shared = &.{
        .{ .id = "unique-key", .source_operation = "script_item_acquire", .item = "suiko_map", .unique = true },
    } };
    const acquire = [_]journal.Command{
        .{ .kind = .shared_acquire, .operation = "unique-key", .item = "suiko_map" },
    };
    const first = try publish.prepare(p, state, unique_sources, catalogue_slice, document(&acquire, "receipt-unique-1", 1));
    _ = try publish.commit(p, &state, catalogue_slice, first, "receipt-unique-1");
    const before_unique = state.snapshot;
    try std.testing.expectError(error.DuplicateItem, publish.publish(p, &state, unique_sources, catalogue_slice, document(&acquire, "receipt-unique-2", 2)));
    try std.testing.expect(sameSnapshot(before_unique, state.snapshot));
}

test "a locked slot and an equipped item are rejected before mutation" {
    const parsed = try loadPacket();
    defer parsed.deinit();
    const p = parsed.value;

    const hero_bag = [_]field.items.Stack{ stack(.bandanna, 0), stack(.tunic, 0) };
    const ids = [_][]const u8{"hero"};
    const bags = [_][]const field.items.Stack{&hero_bag};
    var state = try owners.State.init(try (Fixture{ .ids = &ids, .bags = &bags }).build(1));

    // A lock is only meaningful on a filled slot (an existing host invariant).
    const equip_head = [_]journal.Command{
        .{ .kind = .equip, .member = "hero", .slot = 0, .item = "bandanna", .character_type = lowBit(maskOf(p, "bandanna")) },
    };
    _ = try publish.publish(p, &state, .{}, catalogue_slice, document(&equip_head, "receipt-equip-head", 1));
    try std.testing.expectEqual(@as(?usize, 0), state.snapshot.members[0].?.loadout.head);
    state.snapshot.extras[0].?.locked_equipment[0] = true;
    const locked_before = state.snapshot;

    const locked = [_]journal.Command{
        .{ .kind = .equip, .member = "hero", .slot = 0, .item = "pointed_hat", .character_type = lowBit(maskOf(p, "pointed_hat")) },
    };
    try std.testing.expectError(error.EquipmentLocked, publish.publish(p, &state, .{}, catalogue_slice, document(&locked, "receipt-locked", 2)));
    try std.testing.expect(sameSnapshot(locked_before, state.snapshot));
    const same_locked = [_]journal.Command{
        .{ .kind = .equip, .member = "hero", .slot = 0, .item = "bandanna", .character_type = lowBit(maskOf(p, "bandanna")) },
    };
    _ = try publish.publish(p, &state, .{}, catalogue_slice, document(&same_locked, "receipt-same-locked", 2));
    const unequip_locked = [_]journal.Command{
        .{ .kind = .unequip, .member = "hero", .slot = 0 },
    };
    try std.testing.expectError(error.EquipmentLocked, publish.publish(p, &state, .{}, catalogue_slice, document(&unequip_locked, "receipt-unequip-locked", 3)));

    // Equip the body slot, then refuse to move the worn entry.
    const equip_body = [_]journal.Command{
        .{ .kind = .equip, .member = "hero", .slot = 1, .item = "tunic", .character_type = lowBit(maskOf(p, "tunic")) },
    };
    _ = try publish.publish(p, &state, .{}, catalogue_slice, document(&equip_body, "receipt-equip", 3));
    try std.testing.expectEqual(@as(?usize, 2), state.snapshot.members[0].?.loadout.body);
    const worn_before = state.snapshot;
    const worn = [_]journal.Command{
        .{ .kind = .discard, .member = "hero", .slot = 1 },
    };
    try std.testing.expectError(error.EquippedItem, publish.publish(p, &state, .{}, catalogue_slice, document(&worn, "receipt-worn", 4)));
    try std.testing.expect(sameSnapshot(worn_before, state.snapshot));
    const deposit_worn = [_]journal.Command{
        .{ .kind = .deposit, .member = "hero", .slot = 1 },
    };
    try std.testing.expectError(error.EquippedItem, publish.publish(p, &state, .{}, catalogue_slice, document(&deposit_worn, "receipt-worn-deposit", 4)));
    try std.testing.expect(sameSnapshot(worn_before, state.snapshot));
}

test "stale journals, duplicate receipts and stale proposals are refused" {
    const parsed = try loadPacket();
    defer parsed.deinit();
    const p = parsed.value;

    const hero_bag = [_]field.items.Stack{stack(.bandanna, 0)};
    const gremio_bag = [_]field.items.Stack{};
    const ids = [_][]const u8{ "hero", "gremio" };
    const bags = [_][]const field.items.Stack{ &hero_bag, &gremio_bag };
    var state = try owners.State.init(try (Fixture{ .ids = &ids, .bags = &bags }).build(1));

    const commands = [_]journal.Command{
        .{ .kind = .give, .member = "hero", .slot = 0, .other = "gremio" },
    };
    const doc = document(&commands, "receipt-first", 1);
    const proposal = try publish.prepare(p, state, .{}, catalogue_slice, doc);
    _ = try publish.commit(p, &state, catalogue_slice, proposal, "receipt-first");
    try std.testing.expectEqual(@as(u64, 2), state.revision);

    // The same host receipt is never applied twice, even from a fresh journal.
    try std.testing.expectError(error.StaleJournal, publish.publish(p, &state, .{}, catalogue_slice, doc));
    try std.testing.expectError(error.DuplicateReceipt, publish.publish(p, &state, .{}, catalogue_slice, document(&commands, "receipt-first", 2)));
    // A journal written against the old baseline is stale.
    const stale_revision = document(&commands, "receipt-second", 1);
    try std.testing.expectError(error.StaleJournal, publish.publish(p, &state, .{}, catalogue_slice, stale_revision));
    // A journal from another entry or content is refused.
    var foreign = document(&commands, "receipt-third", 2);
    foreign.entry_id = "other-entry";
    try std.testing.expectError(error.StaleJournal, publish.publish(p, &state, .{}, catalogue_slice, foreign));
    foreign = document(&commands, "receipt-fourth", 2);
    foreign.content_id = "other-content";
    try std.testing.expectError(error.StaleJournal, publish.publish(p, &state, .{}, catalogue_slice, foreign));
    // A malformed journal never reaches the owners.
    var bad_schema = document(&commands, "receipt-fifth", 2);
    bad_schema.schema = "suikoden-item-ledger-journal/2";
    try std.testing.expectError(error.InvalidJournalSchema, publish.publish(p, &state, .{}, catalogue_slice, bad_schema));
    var missing_slot = document(&commands, "receipt-sixth", 2);
    missing_slot.commands = @constCast(&[_]journal.Command{.{ .kind = .give, .member = "hero", .other = "gremio" }});
    try std.testing.expectError(error.InvalidCommand, publish.publish(p, &state, .{}, catalogue_slice, missing_slot));

    // A proposal prepared against an older baseline cannot be committed.
    const fresh = [_]journal.Command{
        .{ .kind = .give, .member = "gremio", .slot = 0, .other = "hero" },
    };
    const old_proposal = try publish.prepare(p, state, .{}, catalogue_slice, document(&fresh, "receipt-old", 2));
    const other = [_]journal.Command{
        .{ .kind = .give, .member = "gremio", .slot = 0, .other = "hero" },
    };
    _ = try publish.publish(p, &state, .{}, catalogue_slice, document(&other, "receipt-other", 2));
    try std.testing.expectError(error.StaleBaseline, publish.commit(p, &state, catalogue_slice, old_proposal, "receipt-old"));
    // A wrong host receipt cannot commit a valid proposal.
    const newest = try publish.prepare(p, state, .{}, catalogue_slice, document(&commands, "receipt-seven", 3));
    try std.testing.expectError(error.InvalidReceipt, publish.commit(p, &state, catalogue_slice, newest, "receipt-mismatch"));
}

test "one-member restart replays the journal and keeps future operations working" {
    const parsed = try loadPacket();
    defer parsed.deinit();
    const p = parsed.value;

    const hero_bag = [_]field.items.Stack{ stack(.medicine, 6), stack(.bandanna, 0), stack(.water_rune_piece, 0) };
    const ids = [_][]const u8{"hero"};
    const bags = [_][]const field.items.Stack{&hero_bag};
    const baseline = try (Fixture{ .ids = &ids, .bags = &bags }).build(1);
    var state = try owners.State.init(baseline);

    const commands = [_]journal.Command{
        .{ .kind = .consume, .member = "hero", .slot = 0 },
        .{ .kind = .deposit, .member = "hero", .slot = 0 },
        .{ .kind = .equip, .member = "hero", .slot = 0, .item = "bandanna", .character_type = lowBit(maskOf(p, "bandanna")) },
        .{ .kind = .shared_acquire, .operation = "grant", .item = "suiko_map" },
    };
    const sources = publish.Sources{ .shared = &.{
        .{ .id = "grant", .source_operation = "script_item_acquire", .item = "suiko_map" },
        .{ .id = "take", .source_operation = "script_item_remove", .item = "suiko_map" },
    } };
    const doc = document(&commands, "receipt-restore-one", 1);
    _ = try publish.publish(p, &state, sources, catalogue_slice, doc);
    const published = state.snapshot;

    // Persist the journal as bytes, decode it, and replay against a baseline
    // reconstructed from canonical data (not from the journal).
    const encoded = try journal.encode(std.testing.allocator, doc);
    defer std.testing.allocator.free(encoded);
    const decoded = try journal.decode(std.testing.allocator, encoded);
    defer decoded.deinit();
    const replayed_document = try journal.fromWire(decoded.value);
    try std.testing.expectEqualStrings(doc.receipt, replayed_document.receipt);
    try std.testing.expectEqual(@as(usize, commands.len), replayed_document.commands.len);

    var restored = try owners.State.init(baseline);
    const outcome = try publish.publish(p, &restored, sources, catalogue_slice, replayed_document);
    try std.testing.expectEqual(state.revision, outcome.revision);
    try std.testing.expectEqual(owners.stateDigest(published), owners.stateDigest(restored.snapshot));
    try std.testing.expectEqualStrings(published.receipt, restored.snapshot.receipt);
    try std.testing.expectEqual(@as(u8, 1), restored.receipts.len);
    try std.testing.expectEqual(@as(usize, 2), restored.snapshot.members[0].?.member.inventory.count());
    try std.testing.expectEqualStrings("bandanna", bagTag(restored.snapshot, 0, 0));
    try std.testing.expectEqual(@as(u16, 1), restored.snapshot.storage.quantity(.medicine));
    try std.testing.expectEqual(@as(?usize, 0), restored.snapshot.members[0].?.loadout.head);
    try std.testing.expectEqualStrings("suiko_map", restored.snapshot.shared[0].?);
    try std.testing.expectEqual(@as(?[]const u8, null), restored.snapshot.shared[1]);
    // Roster ownership is untouched by the restore.
    try std.testing.expectEqual(baseline.active, restored.snapshot.active);
    try std.testing.expectEqualStrings(baseline.entry_id, restored.snapshot.entry_id);

    // The restored state accepts the next publication.
    const next = [_]journal.Command{
        .{ .kind = .shared_remove, .operation = "take", .item = "suiko_map" },
        .{ .kind = .withdraw, .member = "hero", .item = "medicine" },
    };
    const outcome2 = try publish.publish(p, &restored, sources, catalogue_slice, document(&next, "receipt-restore-next", 2));
    try std.testing.expectEqual(@as(u64, 3), outcome2.revision);
    try std.testing.expectEqual(@as(?[]const u8, null), restored.snapshot.shared[0]);
    try std.testing.expectEqual(@as(u16, 0), restored.snapshot.storage.quantity(.medicine));
    try std.testing.expectEqualStrings("medicine", bagTag(restored.snapshot, 0, 2));
}

test "full-party restart preserves duplicate-label identities and later operations" {
    const parsed = try loadPacket();
    defer parsed.deinit();
    const p = parsed.value;

    const empty = [_]field.items.Stack{};
    const hero_bag = [_]field.items.Stack{stack(.medicine, 6)};
    const last_bag = [_]field.items.Stack{stack(.bandanna, 0)};
    const ids = [_][]const u8{ "hero", "gremio", "kirkis", "cleo", "ted", "viktor" };
    const bags = [_][]const field.items.Stack{ &hero_bag, &empty, &empty, &empty, &empty, &last_bag };
    const baseline = try (Fixture{ .ids = &ids, .bags = &bags }).build(1);
    var state = try owners.State.init(baseline);

    const sources = publish.Sources{ .shared = &.{
        .{ .id = "grant-90", .source_operation = "script_item_acquire", .item = "mathiu_s_letter__source_90" },
        .{ .id = "grant-179", .source_operation = "script_item_acquire", .item = "mathiu_s_letter__source_179" },
        .{ .id = "take-90", .source_operation = "script_item_remove", .item = "mathiu_s_letter__source_90" },
    } };
    const commands = [_]journal.Command{
        .{ .kind = .give, .member = "hero", .slot = 0, .other = "viktor" },
        .{ .kind = .equip, .member = "viktor", .slot = 0, .item = "bandanna", .character_type = lowBit(maskOf(p, "bandanna")) },
        .{ .kind = .shared_acquire, .operation = "grant-90", .item = "mathiu_s_letter__source_90" },
        .{ .kind = .shared_acquire, .operation = "grant-179", .item = "mathiu_s_letter__source_179" },
    };
    const doc = document(&commands, "receipt-restore-party", 1);
    _ = try publish.publish(p, &state, sources, catalogue_slice, doc);
    const published = state.snapshot;

    const encoded = try journal.encode(std.testing.allocator, doc);
    defer std.testing.allocator.free(encoded);
    const decoded = try journal.decode(std.testing.allocator, encoded);
    defer decoded.deinit();
    var restored = try owners.State.init(baseline);
    _ = try publish.publish(p, &restored, sources, catalogue_slice, try journal.fromWire(decoded.value));
    try std.testing.expectEqual(owners.stateDigest(published), owners.stateDigest(restored.snapshot));
    try std.testing.expectEqualStrings("mathiu_s_letter__source_90", restored.snapshot.shared[0].?);
    try std.testing.expectEqualStrings("mathiu_s_letter__source_179", restored.snapshot.shared[1].?);
    try std.testing.expectEqual(@as(usize, 2), restored.snapshot.members[5].?.member.inventory.count());
    try std.testing.expectEqualStrings("bandanna", bagTag(restored.snapshot, 5, 0));
    try std.testing.expectEqualStrings("medicine", bagTag(restored.snapshot, 5, 1));
    try std.testing.expectEqual(@as(?usize, 0), restored.snapshot.members[5].?.loadout.head);
    // Every roster slot keeps its identity and its own bag.
    for (ids, 0..) |id, index| {
        try std.testing.expectEqualStrings(id, restored.snapshot.members[index].?.member.id);
        try std.testing.expectEqualStrings(id, restored.snapshot.extras[index].?.member_id);
    }

    const next = [_]journal.Command{
        .{ .kind = .shared_remove, .operation = "take-90", .item = "mathiu_s_letter__source_90" },
        .{ .kind = .deposit, .member = "viktor", .slot = 1 },
        .{ .kind = .withdraw, .member = "gremio", .item = "medicine" },
    };
    _ = try publish.publish(p, &restored, sources, catalogue_slice, document(&next, "receipt-restore-party-next", 2));
    try std.testing.expectEqualStrings("mathiu_s_letter__source_179", restored.snapshot.shared[0].?);
    try std.testing.expectEqual(@as(?[]const u8, null), restored.snapshot.shared[1]);
    try std.testing.expectEqualStrings("medicine", bagTag(restored.snapshot, 1, 0));
    try std.testing.expectEqual(@as(u16, 6), restored.snapshot.members[1].?.member.inventory.slots[0].?.uses);
    try std.testing.expectEqual(@as(u16, 0), restored.snapshot.storage.quantity(.medicine));
}

test "equipment locks and weapon fragments stay distinct sidecar owners" {
    const parsed = try loadPacket();
    defer parsed.deinit();
    const p = parsed.value;

    const hero_bag = [_]field.items.Stack{ stack(.water_rune_piece, 0), stack(.earth_rune_piece, 0) };
    const gremio_bag = [_]field.items.Stack{};
    const ids = [_][]const u8{ "hero", "gremio" };
    const bags = [_][]const field.items.Stack{ &hero_bag, &gremio_bag };
    var state = try owners.State.init(try (Fixture{ .ids = &ids, .bags = &bags }).build(1));

    // The fragment owner is the target character sidecar, not the bag.
    const apply_water = [_]journal.Command{
        .{ .kind = .apply_fragment, .member = "hero", .slot = 0, .other = "gremio" },
    };
    _ = try publish.publish(p, &state, .{}, catalogue_slice, document(&apply_water, "receipt-fragment-water", 1));
    try std.testing.expectEqual(.water, state.snapshot.extras[1].?.weapon_element);
    try std.testing.expectEqual(@as(u8, 1), state.snapshot.extras[1].?.weapon_fragments[1]);
    try std.testing.expectEqual(@as(usize, 1), state.snapshot.members[0].?.member.inventory.count());
    try std.testing.expectEqualStrings("earth_rune_piece", bagTag(state.snapshot, 0, 0));

    // A different element needs an explicit confirmation.
    const before = state.snapshot;
    const apply_earth = [_]journal.Command{
        .{ .kind = .apply_fragment, .member = "hero", .slot = 0, .other = "gremio" },
    };
    try std.testing.expectError(error.ReplacementConfirmationRequired, publish.publish(p, &state, .{}, catalogue_slice, document(&apply_earth, "receipt-fragment-earth", 2)));
    try std.testing.expect(sameSnapshot(before, state.snapshot));
    const replace_earth = [_]journal.Command{
        .{ .kind = .apply_fragment, .member = "hero", .slot = 0, .other = "gremio", .replace = true },
    };
    _ = try publish.publish(p, &state, .{}, catalogue_slice, document(&replace_earth, "receipt-fragment-replace", 2));
    try std.testing.expectEqual(.earth, state.snapshot.extras[1].?.weapon_element);
    try std.testing.expectEqual(@as(u8, 1), state.snapshot.extras[1].?.weapon_fragments[4]);
    try std.testing.expectEqual(@as(u8, 0), state.snapshot.extras[1].?.weapon_fragments[1]);

    // Nine is the source cap for one element.
    state.snapshot.extras[1].?.weapon_fragments[4] = 9;
    const hero_bag_again = [_]field.items.Stack{stack(.earth_rune_piece, 0)};
    state.snapshot.members[0].?.member.inventory.slots[0] = hero_bag_again[0];
    const limit = [_]journal.Command{
        .{ .kind = .apply_fragment, .member = "hero", .slot = 0, .other = "gremio" },
    };
    try std.testing.expectError(error.WeaponPieceLimit, publish.publish(p, &state, .{}, catalogue_slice, document(&limit, "receipt-fragment-limit", 3)));

    state.snapshot.members[0].?.member.inventory.slots[0] = stack(.fire_rune_piece, 0);
    const replace_fire = [_]journal.Command{
        .{ .kind = .apply_fragment, .member = "hero", .slot = 0, .other = "gremio", .replace = true },
    };
    _ = try publish.publish(p, &state, .{}, catalogue_slice, document(&replace_fire, "receipt-fragment-fire", 3));
    try std.testing.expectEqual(.fire, state.snapshot.extras[1].?.weapon_element);
    try std.testing.expectEqual(@as(u8, 1), state.snapshot.extras[1].?.weapon_fragments[0]);
}

test "consume previews follow the source use-count rules" {
    const parsed = try loadPacket();
    defer parsed.deinit();
    const p = parsed.value;

    const plan = try ledger.prepareConsume(p, "medicine", 6);
    try std.testing.expectEqual(@as(u8, 5), plan.uses_after);
    try std.testing.expect(!plan.removes_entry);
    try ledger.verifyConsume(p, plan);
    const final = try ledger.prepareConsume(p, "medicine", 1);
    try std.testing.expect(final.removes_entry);
    try ledger.verifyConsume(p, final);
    // A reusable tool has no use counter and stays in the bag.
    const reusable = try ledger.prepareConsume(p, "blinking_mirror", 0);
    try std.testing.expect(reusable.reusable);
    try std.testing.expect(!reusable.removes_entry);
    try std.testing.expectError(error.NoUsesRemaining, ledger.prepareConsume(p, "blinking_mirror", 1));
    try std.testing.expectError(error.NoUsesRemaining, ledger.prepareConsume(p, "medicine", 0));
    try std.testing.expectError(error.UsesExceedMaximum, ledger.prepareConsume(p, "medicine", 7));
    try std.testing.expectError(error.NotUsable, ledger.prepareConsume(p, "bandanna", 0));
    // A forged plan is refused.
    var forged = plan;
    forged.uses_after = 0;
    try std.testing.expectError(error.InvalidPrepared, ledger.verifyConsume(p, forged));
}

test "the adapter does not reach save or global story state" {
    for ([_][]const u8{
        ledger_mod.review.publish_source,
        ledger_mod.review.owners_source,
        ledger_mod.review.ledger_source,
        ledger_mod.review.journal_source,
        ledger_mod.review.catalogue_source,
    }) |source| {
        for ([_][]const u8{ "@import(\"save_file\")", "@import(\"save_slots\")", "@import(\"journey\")", "Progress" }) |forbidden| {
            try std.testing.expect(std.mem.indexOf(u8, source, forbidden) == null);
        }
    }
}

test "a forged proposal snapshot is refused before commit" {
    const parsed = try loadPacket();
    defer parsed.deinit();
    const p = parsed.value;

    const hero_bag = [_]field.items.Stack{stack(.bandanna, 0)};
    const gremio_bag = [_]field.items.Stack{};
    const ids = [_][]const u8{ "hero", "gremio" };
    const bags = [_][]const field.items.Stack{ &hero_bag, &gremio_bag };
    var state = try owners.State.init(try (Fixture{ .ids = &ids, .bags = &bags }).build(1));
    const before = state.snapshot;

    const commands = [_]journal.Command{
        .{ .kind = .give, .member = "hero", .slot = 0, .other = "gremio" },
    };
    const proposal = try publish.prepare(p, state, .{}, catalogue_slice, document(&commands, "receipt-forged", 1));

    var unknown_shared = proposal;
    unknown_shared.snapshot.shared[0] = "not_an_item";
    try std.testing.expectError(error.InvalidSharedItems, publish.commit(p, &state, catalogue_slice, unknown_shared, "receipt-forged"));
    var empty_entry = proposal;
    empty_entry.snapshot.entry_id = "";
    try std.testing.expectError(error.InvalidEntry, publish.commit(p, &state, catalogue_slice, empty_entry, "receipt-forged"));
    var bad_equipment = proposal;
    bad_equipment.snapshot.members[0].?.loadout.head = 99;
    try std.testing.expectError(error.InvalidEquipmentIndex, publish.commit(p, &state, catalogue_slice, bad_equipment, "receipt-forged"));
    var wrong_revision = proposal;
    wrong_revision.snapshot.baseline_revision = 7;
    try std.testing.expectError(error.InvalidProposal, publish.commit(p, &state, catalogue_slice, wrong_revision, "receipt-forged"));
    try std.testing.expect(sameSnapshot(before, state.snapshot));
    try std.testing.expectEqual(@as(u64, 1), state.revision);
    try std.testing.expectEqual(@as(u8, 0), state.receipts.len);
}
