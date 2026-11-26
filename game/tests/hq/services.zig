//! Focused gate: real service callers, stage stock/limits, replay
//! re-authorisation, ownership-preserving failure and return flow.
//!
//! Pure/port-level only: no original instruction, no emulator, no window, no
//! save file.  The packet is the generated, hash-pinned source projection and
//! the transaction engines are the existing `field`/`game_state`/`storage`
//! engines through the pack's adapter.
const std = @import("std");
const hq = @import("hq");
const services_mod = hq.services;
const service_engines = hq.services.engines;
const services_data = @import("hq_data").service_callers;
const field = @import("field");
const items = field.items;
const game_state = field.game_state;

const TestState = struct {
    rules: items.Rules,
    members: [1]game_state.Member,
    state: field.State,
    progress: field.game_state.Progress,
    adapter: service_engines.Adapter,
};

fn appraisals() []const items.Appraisal {
    return &.{
        .{ .id = .failure_urn, .name = "Failure urn", .price = 20, .fee = 500 },
        .{ .id = .octopus_urn, .name = "Octopus urn", .price = 1000, .fee = 500 },
        .{ .id = .celadon_urn, .name = "Celadon urn", .price = 20000, .fee = 500 },
    };
}

fn consumables() []const items.Consumable {
    return &.{
        .{ .id = .medicine, .name = "Medicine", .price = 100, .uses = 6, .heal_hp = 100 },
        .{ .id = .antitoxin, .name = "Antitoxin", .price = 200, .uses = 4, .cure = .poison },
        .{ .id = .needle, .name = "Needle", .price = 200, .uses = 4, .cure = .balloon },
        .{ .id = .mega_medicine, .name = "Mega medicine", .price = 500, .uses = 3, .heal_hp = 500 },
    };
}

fn initState(t: *TestState, money: u32) void {
    t.members[0] = .{
        .id = "hero",
        .name = "Hero",
        .hp = 100,
        .max_hp = 100,
        .status = .healthy,
        .rune_charges = @splat(0),
        .max_rune_charges = @splat(0),
    };
    t.rules = .{
        .appraisals = appraisals(),
        .schema = "suikoden-items/4",
        .room = "test_shop",
        .npc = "keeper",
        .greeting = "Welcome.",
        .medicine = .{ .name = "Medicine", .price = 100, .uses = 6, .heal_hp = 100 },
        .consumables = consumables(),
        .goods = &.{},
        .stock = &.{ .medicine, .antitoxin },
    };
    t.progress = .{ .money = money, .party = .init(t.members[0..1]) };
    t.state = .{
        .room = 0,
        .x = 0,
        .y = 0,
        .destination = .{ .x = 0, .y = 0 },
        .progress = &t.progress,
        .item_rules = t.rules,
    };
    t.adapter = .{ .state = &t.state };
}

fn callerOf(p: *const services_mod.Packet, family: services_mod.ServiceFamily, need_stock: bool) *const services_mod.Caller {
    for (p.callers) |*caller| {
        if (caller.service != family or !caller.canonical) continue;
        if (need_stock and caller.stock.len == 0) continue;
        return caller;
    }
    @panic("packet has no matching source caller");
}

fn accessFor(caller: *const services_mod.Caller) services_mod.Access {
    return .{
        .area = caller.area,
        .npc_present = true,
        .service_available = true,
        .story_gate = true,
        .rune_permitted = true,
    };
}

fn opened(result: services_mod.OpenResult) services_mod.Host {
    return switch (result) {
        .opened => |host| host,
        .blocked => |b| {
            std.debug.print("unexpected blocker: {s} ({?s})\n", .{ @tagName(b.reason), b.requirement });
            @panic("expected an opened service");
        },
    };
}

fn expectBlocked(result: services_mod.OpenResult) services_mod.Blocked {
    return switch (result) {
        .opened => @panic("expected a blocked service"),
        .blocked => |b| b,
    };
}

test "packet is the source caller projection, not a second catalogue" {
    var parsed = try services_mod.load(std.testing.allocator, services_data.json);
    defer parsed.deinit();
    const p = &parsed.value;
    try std.testing.expectEqualStrings("suikoden-service-callers/1", p.schema);
    try std.testing.expect(p.callers.len >= 100);
    try std.testing.expectEqual(@as(usize, 8), p.services.len);
    try std.testing.expectEqualStrings("candidate_only", p.entry_contracts.state);
    try std.testing.expectEqual(@as(u8, 9), p.limits.character_item_capacity);
    try std.testing.expectEqual(@as(u32, 500), p.limits.appraisal_fee);
    // The VB6 room 9 shop must reproduce the published export_shop stock.
    var found_vb6 = false;
    for (p.callers) |caller| {
        if (!std.mem.eql(u8, caller.area, "vb6") or caller.room != 9 or caller.service != .shop) continue;
        found_vb6 = true;
        var ids: [4]u16 = undefined;
        for (caller.stock, 0..) |stock, i| ids[i] = stock.native_id;
        try std.testing.expectEqualSlices(u16, &.{ 25, 72, 71, 143 }, ids[0..caller.stock.len]);
    }
    try std.testing.expect(found_vb6);
    // No warehouse caller was invented; the overlay entry is explicitly locked.
    for (p.callers) |caller| try std.testing.expect(caller.service != .warehouse);
    try std.testing.expectEqual(@as(usize, 1), p.overlay_entries.len);
    try std.testing.expect(!p.overlay_entries[0].canonical);
}

test "supported families open at their real callers and return to the same actor" {
    var parsed = try services_mod.load(std.testing.allocator, services_data.json);
    defer parsed.deinit();
    const p = &parsed.value;
    inline for (.{ .shop, .blacksmith, .rune, .appraisal }) |family| {
        const caller = callerOf(p, family, family == .shop);
        var host = opened(services_mod.open(p, caller.id, accessFor(caller), 7));
        try std.testing.expectEqualStrings(caller.id, host.returnTarget());
        try std.testing.expectEqual(services_mod.Phase.menu, host.phase);
        try std.testing.expectEqualStrings(caller.area, host.access.area.?);
    }
}

test "missing, locked, wrong-area, non-canonical and stale-revision admission" {
    var parsed = try services_mod.load(std.testing.allocator, services_data.json);
    defer parsed.deinit();
    const p = &parsed.value;
    const caller = callerOf(p, .shop, true);

    var missing = accessFor(caller);
    missing.service_available = null;
    try std.testing.expectEqual(services_mod.BlockReason.missing_condition, expectBlocked(services_mod.open(p, caller.id, missing, 1)).reason);

    var locked = accessFor(caller);
    locked.npc_present = false;
    try std.testing.expectEqual(services_mod.BlockReason.service_locked, expectBlocked(services_mod.open(p, caller.id, locked, 1)).reason);

    var gate = accessFor(caller);
    gate.story_gate = null;
    try std.testing.expectEqual(services_mod.BlockReason.missing_condition, expectBlocked(services_mod.open(p, caller.id, gate, 1)).reason);

    var wrong = accessFor(caller);
    wrong.area = "somewhere_else";
    try std.testing.expectEqual(services_mod.BlockReason.wrong_area, expectBlocked(services_mod.open(p, caller.id, wrong, 1)).reason);

    try std.testing.expectEqual(services_mod.BlockReason.invalid_revision, expectBlocked(services_mod.open(p, caller.id, accessFor(caller), 0)).reason);
    try std.testing.expectEqual(services_mod.BlockReason.unknown_caller, expectBlocked(services_mod.open(p, "", accessFor(caller), 1)).reason);
    try std.testing.expectEqual(services_mod.BlockReason.non_canonical_caller, expectBlocked(services_mod.open(p, p.overlay_entries[0].id, accessFor(caller), 1)).reason);
}

test "cancel preserves ownership and returns to the caller menu" {
    var parsed = try services_mod.load(std.testing.allocator, services_data.json);
    defer parsed.deinit();
    const p = &parsed.value;
    const caller = callerOf(p, .shop, true);
    var t: TestState = undefined;
    initState(&t, 1000);
    var host = opened(services_mod.open(p, caller.id, accessFor(caller), 3));
    _ = host.cancel();
    try std.testing.expectEqual(services_mod.Phase.returned, host.phase);
    try std.testing.expectEqual(@as(u32, 1000), t.state.progress.money);
    try std.testing.expectEqual(@as(usize, 0), t.state.progress.party.at(0).inventory.count());
    try std.testing.expectEqualStrings(caller.id, host.returnTarget());
}

test "successful shop purchase commits through the current engine" {
    var parsed = try services_mod.load(std.testing.allocator, services_data.json);
    defer parsed.deinit();
    const p = &parsed.value;
    const caller = callerOf(p, .shop, true);
    var t: TestState = undefined;
    initState(&t, 1000);
    var host = opened(services_mod.open(p, caller.id, accessFor(caller), 3));
    const engine = t.adapter.engine();
    const result = host.buy(&engine, 0, 25);
    try std.testing.expect(result == .ok);
    try std.testing.expectEqual(@as(u32, 900), t.state.progress.money);
    try std.testing.expectEqual(@as(usize, 1), t.state.progress.party.at(0).inventory.count());
    try std.testing.expectEqual(items.Id.medicine, t.state.progress.party.at(0).inventory.slots[0].?.id);
    try std.testing.expectEqual(@as(u32, 1), host.receipt.serial);
    try std.testing.expectEqual(caller.id, host.receipt.caller_id);
}

test "insufficient funds and full bag leave money and bag untouched" {
    var parsed = try services_mod.load(std.testing.allocator, services_data.json);
    defer parsed.deinit();
    const p = &parsed.value;
    const caller = callerOf(p, .shop, true);

    var poor: TestState = undefined;
    initState(&poor, 50);
    var poor_host = opened(services_mod.open(p, caller.id, accessFor(caller), 3));
    const poor_engine = poor.adapter.engine();
    const funds = poor_host.buy(&poor_engine, 0, 25);
    try std.testing.expect(funds == .failed and funds.failed.reason == .insufficient_funds);
    try std.testing.expectEqual(@as(u32, 50), poor.state.progress.money);
    try std.testing.expectEqual(@as(usize, 0), poor.state.progress.party.at(0).inventory.count());
    try std.testing.expectEqual(services_mod.Phase.menu, poor_host.phase);
    try std.testing.expectEqualStrings(caller.id, poor_host.returnTarget());

    var full: TestState = undefined;
    initState(&full, 1000);
    for (0..full.state.progress.party.at(0).inventory.slots.len) |i| {
        full.state.progress.party.at(0).inventory.slots[i] = .{ .id = .medicine, .uses = 6 };
    }
    var full_host = opened(services_mod.open(p, caller.id, accessFor(caller), 3));
    const full_engine = full.adapter.engine();
    const bag = full_host.buy(&full_engine, 0, 25);
    try std.testing.expect(bag == .failed and bag.failed.reason == .inventory_full);
    try std.testing.expectEqual(@as(u32, 1000), full.state.progress.money);
    try std.testing.expectEqual(@as(usize, 9), full.state.progress.party.at(0).inventory.count());
    try std.testing.expectEqual(services_mod.Phase.menu, full_host.phase);
}

test "stock is caller-specific: an item sold by one shop is refused by another" {
    var parsed = try services_mod.load(std.testing.allocator, services_data.json);
    defer parsed.deinit();
    const p = &parsed.value;
    var with_item: ?*const services_mod.Caller = null;
    var without_item: ?*const services_mod.Caller = null;
    for (p.callers) |*caller| {
        if (caller.service != .shop or caller.stock.len == 0) continue;
        var has_72 = false;
        for (caller.stock) |stock| {
            if (stock.native_id == 72) has_72 = true;
        }
        if (has_72 and with_item == null) with_item = caller;
        if (!has_72 and without_item == null) without_item = caller;
    }
    if (with_item != null and without_item != null) {
        var t: TestState = undefined;
        initState(&t, 1000);
        var host = opened(services_mod.open(p, without_item.?.id, accessFor(without_item.?), 3));
        const engine = t.adapter.engine();
        const result = host.buy(&engine, 0, 72);
        try std.testing.expect(result == .failed and result.failed.reason == .not_in_stock);
        try std.testing.expectEqual(@as(u32, 1000), t.state.progress.money);
    }
}

test "replay re-runs caller access and refuses a moved revision or a closed caller" {
    var parsed = try services_mod.load(std.testing.allocator, services_data.json);
    defer parsed.deinit();
    const p = &parsed.value;
    const caller = callerOf(p, .shop, true);
    var t: TestState = undefined;
    initState(&t, 1000);
    var host = opened(services_mod.open(p, caller.id, accessFor(caller), 5));
    const engine = t.adapter.engine();
    _ = host.buy(&engine, 0, 25);
    const receipt = host.receipt;

    const again = opened(services_mod.replay(p, caller.id, accessFor(caller), 5, receipt));
    try std.testing.expectEqual(receipt.serial, again.receipt.serial);
    try std.testing.expectEqualStrings(caller.id, again.returnTarget());

    try std.testing.expectEqual(services_mod.BlockReason.stale_receipt, expectBlocked(services_mod.replay(p, caller.id, accessFor(caller), 6, receipt)).reason);

    var locked = accessFor(caller);
    locked.service_available = false;
    try std.testing.expectEqual(services_mod.BlockReason.service_locked, expectBlocked(services_mod.replay(p, caller.id, locked, 5, receipt)).reason);
}

test "appraisal funds failure preserves the unidentified slot; success reveals it" {
    var parsed = try services_mod.load(std.testing.allocator, services_data.json);
    defer parsed.deinit();
    const p = &parsed.value;
    const caller = callerOf(p, .appraisal, false);

    var poor: TestState = undefined;
    initState(&poor, 400);
    poor.state.progress.party.at(0).inventory.slots[0] = .{ .id = .failure_urn, .uses = 0, .identified = false };
    var poor_host = opened(services_mod.open(p, caller.id, accessFor(caller), 3));
    var poor_engine = poor.adapter.engine();
    const refused = poor_host.appraise(&poor_engine, 0, 0);
    try std.testing.expect(refused == .failed and refused.failed.reason == .insufficient_funds);
    try std.testing.expectEqual(@as(u32, 400), poor.state.progress.money);
    try std.testing.expect(!poor.state.progress.party.at(0).inventory.slots[0].?.identified);
    try std.testing.expectEqual(services_mod.Phase.menu, poor_host.phase);

    var rich: TestState = undefined;
    initState(&rich, 500);
    rich.state.progress.party.at(0).inventory.slots[0] = .{ .id = .failure_urn, .uses = 0, .identified = false };
    var rich_host = opened(services_mod.open(p, caller.id, accessFor(caller), 3));
    var rich_engine = rich.adapter.engine();
    const result = rich_host.appraise(&rich_engine, 0, 0);
    try std.testing.expect(result == .ok);
    try std.testing.expectEqual(@as(u32, 0), rich.state.progress.money);
    try std.testing.expect(rich.state.progress.party.at(0).inventory.slots[0].?.identified);
    try std.testing.expectEqual(items.Id.failure_urn, rich.state.progress.party.at(0).inventory.slots[0].?.id);
}

test "warehouse deposit/withdraw full failures preserve both owners and stay module-only" {
    var parsed = try services_mod.load(std.testing.allocator, services_data.json);
    defer parsed.deinit();
    const p = &parsed.value;
    const entry = p.overlay_entries[0];
    var t: TestState = undefined;
    initState(&t, 1000);
    try std.testing.expectEqual(services_mod.BlockReason.non_canonical_caller, expectBlocked(services_mod.open(p, entry.id, .{ .npc_present = true, .service_available = true }, 1)).reason);

    // The overlay entry is an explicit module-only surface: the host has no
    // canonical NPC caller for it, so production leaves it locked.
    var host = opened(services_mod.openOverlay(p, entry.id, .{ .npc_present = true, .service_available = true }, 4));
    try std.testing.expectEqualStrings(entry.id, host.returnTarget());

    // Warehouse full: 254 is the source cap.  The current Storage maps it per id.
    t.state.progress.storage.counts.medicine = 254;
    t.state.progress.party.at(0).inventory.slots[0] = .{ .id = .medicine, .uses = 6 };
    const engine = t.adapter.engine();
    const full = host.deposit(&engine, 0, 0);
    try std.testing.expect(full == .failed and full.failed.reason == .warehouse_full);
    try std.testing.expectEqual(@as(u16, 254), t.state.progress.storage.quantity(.medicine));
    try std.testing.expectEqual(@as(usize, 1), t.state.progress.party.at(0).inventory.count());
    try std.testing.expectEqual(services_mod.Phase.menu, host.phase);

    // Bag full on withdraw leaves the warehouse count intact.
    t.state.progress.storage.counts.medicine = 1;
    for (0..t.state.progress.party.at(0).inventory.slots.len) |i| {
        t.state.progress.party.at(0).inventory.slots[i] = .{ .id = .medicine, .uses = 6 };
    }
    const bag = host.withdraw(&engine, 0, 25);
    try std.testing.expect(bag == .failed and bag.failed.reason == .inventory_full);
    try std.testing.expectEqual(@as(u16, 1), t.state.progress.storage.quantity(.medicine));
    try std.testing.expectEqual(@as(usize, 9), t.state.progress.party.at(0).inventory.count());
}

test "blacksmith and rune admission stays locked until their required facts exist" {
    var parsed = try services_mod.load(std.testing.allocator, services_data.json);
    defer parsed.deinit();
    const p = &parsed.value;
    const smith = callerOf(p, .blacksmith, false);
    const rune = callerOf(p, .rune, false);
    var t: TestState = undefined;
    initState(&t, 1000);

    var smith_host = opened(services_mod.open(p, smith.id, accessFor(smith), 3));
    const engine = t.adapter.engine();
    const invalid = smith_host.sharpen(&engine, 0, 0);
    try std.testing.expect(invalid == .failed and invalid.failed.reason == .level_limit_invalid);
    // Without a decoded per-caller limit the host refuses to run the engine.
    try std.testing.expect(smith.level_limit == null);
    const unavailable = smith_host.sharpen(&engine, 0, p.limits.weapon_level_max);
    try std.testing.expect(unavailable == .failed and unavailable.failed.reason == .unsupported_engine);

    var rune_host = opened(services_mod.open(p, rune.id, accessFor(rune), 3));
    var no_grant = accessFor(rune);
    no_grant.rune_permitted = null;
    var rune_host2 = opened(services_mod.open(p, rune.id, no_grant, 3));
    const missing = rune_host2.attach(&engine, 0, 2, 0);
    try std.testing.expect(missing == .failed and missing.failed.reason == .missing_condition);
    var denied = accessFor(rune);
    denied.rune_permitted = false;
    var rune_host3 = opened(services_mod.open(p, rune.id, denied, 3));
    const refused = rune_host3.attach(&engine, 0, 2, 0);
    try std.testing.expect(refused == .failed and refused.failed.reason == .condition_denied);
    _ = &rune_host;
}

test "return flow and close never reselect a different screen" {
    var parsed = try services_mod.load(std.testing.allocator, services_data.json);
    defer parsed.deinit();
    const p = &parsed.value;
    const caller = callerOf(p, .shop, true);
    var t: TestState = undefined;
    initState(&t, 1000);
    var host = opened(services_mod.open(p, caller.id, accessFor(caller), 3));
    const engine = t.adapter.engine();
    _ = host.buy(&engine, 0, 25);
    try std.testing.expectEqual(services_mod.Phase.menu, host.phase);
    try std.testing.expectEqualStrings(caller.id, host.returnTarget());
    host.close();
    try std.testing.expectEqual(services_mod.Phase.closed, host.phase);
    const late = host.buy(&engine, 0, 25);
    try std.testing.expect(late == .failed and late.failed.reason == .wrong_phase);
}
