const std = @import("std");
const battle = @import("battle");
const events = @import("event_runtime");
const items = @import("item_ledger");
const item_data = @import("campaign_policies_data").item_ledger;
const party = @import("party_session");
const progression = @import("chapters").middle_progression;
const data = @import("middle_assets").item_progression;

const allocator = std.testing.allocator;

const Loaded = struct {
    packet: std.json.Parsed(items.catalogue.Packet),
    asset: std.json.Parsed(progression.Asset),

    fn deinit(self: *Loaded) void {
        self.asset.deinit();
        self.packet.deinit();
    }
};

fn load() !Loaded {
    const packet = try items.catalogue.load(allocator, item_data.json);
    errdefer packet.deinit();
    return .{ .packet = packet, .asset = try progression.open(allocator, data.json, packet.value) };
}

fn entryId(asset: progression.Asset, source_file: []const u8, offset: u32) []const u8 {
    return progression.entryAt(asset, source_file, offset).?.id;
}

fn facts(story: *const events.StoryState) progression.Facts {
    return .{ .story = story, .entity_retained = true, .interaction = true };
}

fn rootAcquire(asset: progression.Asset) []const u8 {
    return asset.running_water_root.acquire_entry;
}

fn rootConsume(asset: progression.Asset) []const u8 {
    return asset.running_water_root.consume_entry;
}

const catalogue = [_]battle.systems.Equipment{
    .{ .id = "bandanna", .name = "Bandanna", .bonuses = @splat(0), .category = .head },
};

fn memberRecord(id: []const u8) battle.OwnedMember {
    return .{
        .member = .{
            .id = id,
            .name = id,
            .hp = 40,
            .max_hp = 40,
            .status = .healthy,
            .rune_charges = @splat(0),
            .max_rune_charges = @splat(0),
            .inventory = .{},
        },
        .level = 1,
        .experience = 0,
        .stats = .{ .attack = 10, .defense = 9, .skill = 8, .speed = 7 },
        .weapon_level = 1,
        .loadout = .{},
        .rune = null,
    };
}

fn depositSnapshot() party.Snapshot {
    var snapshot = party.Snapshot{
        .entry_id = "middle-battle-entry",
        .content_id = "middle-battle-content",
        .receipt = "middle-battle-receipt",
        .baseline_revision = 7,
    };
    snapshot.members[0] = memberRecord("hero");
    snapshot.extras[0] = .{ .member_id = "hero" };
    snapshot.eligible[0] = true;
    snapshot.active[0] = "hero";
    var pahn = memberRecord("pahn");
    pahn.member.inventory.slots[0] = .{ .id = .bandanna, .uses = 0 };
    pahn.member.inventory.slots[1] = .{ .id = .medicine, .uses = 2 };
    pahn.member.inventory.slots[2] = .{ .id = .bandanna, .uses = 0 };
    pahn.loadout.head = 0;
    snapshot.members[1] = pahn;
    snapshot.extras[1] = .{ .member_id = "pahn" };
    return snapshot;
}

test "asset pins the complete source census and rejects stale item identities" {
    var raw_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data.json, &raw_digest, .{});
    const actual = std.fmt.bytesToHex(raw_digest, .lower);
    try std.testing.expectEqualStrings(data.asset_sha256, &actual);
    var loaded = try load();
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 30), loaded.asset.value.entries.len);
    try std.testing.expectEqual(@as(u16, 17), loaded.asset.value.coverage.acquire);
    try std.testing.expectEqual(@as(u16, 11), loaded.asset.value.coverage.remove);
    try std.testing.expectEqual(@as(u16, 2), loaded.asset.value.coverage.warehouse_deposits);
    try std.testing.expectEqual(@as(u16, 0), loaded.asset.value.coverage.unsupported_selectors);
    const entries = try allocator.dupe(progression.Entry, loaded.asset.value.entries);
    defer allocator.free(entries);
    entries[0].item_id = "missing";
    var bad = loaded.asset.value;
    bad.entries = entries;
    try std.testing.expectError(error.MismatchedItemIdentity, progression.validate(bad, loaded.packet.value));
}

test "Running Water Root progresses through source story and interaction guards" {
    var loaded = try load();
    defer loaded.deinit();
    var story: events.StoryState = .{};
    var view: items.ledger.View = .{};
    var input = facts(&story);
    input.interaction = false;
    try std.testing.expectError(error.InteractionRequired, progression.plan(loaded.asset.value, loaded.packet.value, rootAcquire(loaded.asset.value), input, view));
    input.interaction = true;
    const acquired = try progression.plan(loaded.asset.value, loaded.packet.value, rootAcquire(loaded.asset.value), input, view);
    try progression.commit(loaded.asset.value, loaded.packet.value, &view, acquired);
    try std.testing.expectEqual(@as(u8, 1), view.len);
    try std.testing.expectEqual(@as(u8, 1), view.count(86));
    try std.testing.expectError(error.AdmissionClosed, progression.plan(loaded.asset.value, loaded.packet.value, rootConsume(loaded.asset.value), input, view));
    story.scenario[16] = 0x20;
    const consumed = try progression.plan(loaded.asset.value, loaded.packet.value, rootConsume(loaded.asset.value), input, view);
    try progression.commit(loaded.asset.value, loaded.packet.value, &view, consumed);
    try std.testing.expectEqual(@as(u8, 0), view.len);
    try std.testing.expectEqual(@as(u32, 2), view.revision);
}

test "wrong-order consumption fails without changing the ledger" {
    var loaded = try load();
    defer loaded.deinit();
    var story: events.StoryState = .{};
    story.scenario[16] = 0x20;
    const view: items.ledger.View = .{};
    const before = view;
    try std.testing.expectError(error.ItemUnavailable, progression.plan(loaded.asset.value, loaded.packet.value, rootConsume(loaded.asset.value), facts(&story), view));
    try std.testing.expectEqualDeep(before, view);
}

test "a full shared bag rejects acquisition and retry succeeds after space is freed" {
    var loaded = try load();
    defer loaded.deinit();
    var story: events.StoryState = .{};
    var view = items.ledger.View{ .len = 7, .ids = .{ 82, 84, 85, 86, 87, 88, 89 }, .revision = 7 };
    const before = view;
    try std.testing.expectError(error.SharedLedgerFull, progression.plan(loaded.asset.value, loaded.packet.value, rootAcquire(loaded.asset.value), facts(&story), view));
    try std.testing.expectEqualDeep(before, view);
    view = (try items.ledger.apply(view, .remove, 82)).view;
    const retry = try progression.plan(loaded.asset.value, loaded.packet.value, rootAcquire(loaded.asset.value), facts(&story), view);
    try progression.commit(loaded.asset.value, loaded.packet.value, &view, retry);
    try std.testing.expectEqual(@as(u8, 7), view.len);
    try std.testing.expectEqual(@as(u8, 86), view.ids[6]);
}

test "source duplicate acquisition is preserved and removal deletes one copy" {
    var loaded = try load();
    defer loaded.deinit();
    var story: events.StoryState = .{};
    var view: items.ledger.View = .{};
    for (0..2) |_| {
        const proposal = try progression.plan(loaded.asset.value, loaded.packet.value, rootAcquire(loaded.asset.value), facts(&story), view);
        try progression.commit(loaded.asset.value, loaded.packet.value, &view, proposal);
    }
    try std.testing.expectEqual(@as(u8, 2), view.count(86));
    story.scenario[16] = 0x20;
    const proposal = try progression.plan(loaded.asset.value, loaded.packet.value, rootConsume(loaded.asset.value), facts(&story), view);
    try progression.commit(loaded.asset.value, loaded.packet.value, &view, proposal);
    try std.testing.expectEqual(@as(u8, 1), view.len);
    try std.testing.expectEqual(@as(u8, 1), view.count(86));
}

test "canonical shared slots restore the exact view and remaining progression" {
    var loaded = try load();
    defer loaded.deinit();
    var story: events.StoryState = .{};
    var view: items.ledger.View = .{};
    const acquired = try progression.plan(loaded.asset.value, loaded.packet.value, rootAcquire(loaded.asset.value), facts(&story), view);
    try progression.commit(loaded.asset.value, loaded.packet.value, &view, acquired);
    const slots = try items.ledger.slotsOf(loaded.packet.value, view);
    var restored = try items.ledger.viewOf(loaded.packet.value, slots, view.revision);
    try std.testing.expectEqualDeep(view, restored);
    story.scenario[16] = 0x20;
    const consumed = try progression.plan(loaded.asset.value, loaded.packet.value, rootConsume(loaded.asset.value), facts(&story), restored);
    try progression.commit(loaded.asset.value, loaded.packet.value, &restored, consumed);
    try std.testing.expectEqual(@as(u8, 0), restored.len);
    try std.testing.expectEqual(view.revision + 1, restored.revision);
}

test "stale and mismatched proposals fail before publication" {
    var loaded = try load();
    defer loaded.deinit();
    var story: events.StoryState = .{};
    var view: items.ledger.View = .{};
    const proposal = try progression.plan(loaded.asset.value, loaded.packet.value, rootAcquire(loaded.asset.value), facts(&story), view);
    var wrong_offset = proposal;
    wrong_offset.source_offset += 1;
    try std.testing.expectError(error.MismatchedItemProposal, progression.commit(loaded.asset.value, loaded.packet.value, &view, wrong_offset));
    try std.testing.expectEqual(@as(u8, 0), view.len);
    view = (try items.ledger.apply(view, .acquire, 82)).view;
    const before = view;
    try std.testing.expectError(error.StaleBaseline, progression.commit(loaded.asset.value, loaded.packet.value, &view, proposal));
    try std.testing.expectEqualDeep(before, view);
}

test "Pahn deposits eligible entries backward while his equipped bandanna remains" {
    var loaded = try load();
    defer loaded.deinit();
    var story: events.StoryState = .{};
    story.scenario[33] = 0x80;
    story.scenario[34] = 0x02;
    const id = entryId(loaded.asset.value, "DATA/02_AREA.B/VB7D.BIN", 0xC2DD);
    const entry = progression.entryById(loaded.asset.value, id).?;
    try std.testing.expectEqual(@as(?u8, 6), entry.character_id);
    try std.testing.expectEqualStrings("pahn", entry.member_id.?);
    var snapshot = depositSnapshot();
    const proposal = try progression.planDeposit(loaded.asset.value, loaded.packet.value, id, facts(&story), snapshot, &catalogue);
    try std.testing.expectEqual(@as(u8, 2), proposal.transferred);
    try std.testing.expectEqual(@as(usize, 3), snapshot.members[1].?.member.inventory.count());
    try progression.commitDeposit(loaded.asset.value, loaded.packet.value, &snapshot, &catalogue, proposal);
    const bag = snapshot.members[1].?.member.inventory;
    try std.testing.expectEqual(@as(usize, 1), bag.count());
    try std.testing.expectEqual(@as(u16, 1), snapshot.storage.quantity(.bandanna));
    try std.testing.expectEqual(@as(u16, 1), snapshot.storage.quantity(.medicine));
    try std.testing.expectEqual(@as(?usize, 0), snapshot.members[1].?.loadout.head);
}

test "a full warehouse rejects the whole deposit without partial item movement" {
    var loaded = try load();
    defer loaded.deinit();
    var story: events.StoryState = .{};
    story.scenario[33] = 0x80;
    story.scenario[34] = 0x02;
    const id = entryId(loaded.asset.value, "DATA/02_AREA.B/VB7D.BIN", 0xC2DD);
    var snapshot = depositSnapshot();
    snapshot.storage.counts.bandanna = 254;
    const before = snapshot;
    try std.testing.expectError(error.StorageFull, progression.planDeposit(loaded.asset.value, loaded.packet.value, id, facts(&story), snapshot, &catalogue));
    try std.testing.expectEqualDeep(before, snapshot);
}

test "unsupported source admission stays selected and blocked" {
    var loaded = try load();
    defer loaded.deinit();
    var story: events.StoryState = .{};
    const view: items.ledger.View = .{};
    const id = entryId(loaded.asset.value, "DATA/01_AREA.A/VA3.BIN", 0x29BEE);
    try std.testing.expectError(error.UnsupportedAdmission, progression.plan(loaded.asset.value, loaded.packet.value, id, facts(&story), view));
    try std.testing.expectEqual(@as(u8, 0), view.len);
    const pahn = entryId(loaded.asset.value, "DATA/07_AREA.D/VD5.BIN", 0x4AE4C);
    try std.testing.expectError(error.UnsupportedAdmission, progression.planDeposit(loaded.asset.value, loaded.packet.value, pahn, facts(&story), depositSnapshot(), &catalogue));
}

test "production item host applies source acquire and remove entries" {
    var loaded = try load();
    defer loaded.deinit();
    var story: events.StoryState = .{};
    var view: items.ledger.View = .{};
    var host = progression.Host{ .asset = &loaded.asset.value, .packet = loaded.packet.value, .view = &view, .story = &story };
    try host.apply(rootAcquire(loaded.asset.value), true, true);
    try std.testing.expectEqual(@as(u8, 1), view.count(86));
    story.scenario[16] = 0x20;
    try host.apply(rootConsume(loaded.asset.value), true, true);
    try std.testing.expectEqual(@as(u8, 0), view.count(86));
}
