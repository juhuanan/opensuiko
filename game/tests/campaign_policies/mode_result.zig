//! Owned gate: executed conformance vectors plus commit-time failure,
//! tampered-pending, retry and save/restore cases for the shared mode-result
//! transaction.  No emulator, no original instructions, no game window.
const std = @import("std");
const mode_result_mod = @import("campaign_policies").mode_result;
const asset = @import("campaign_policies_data").mode_result_host;

const Op = enum { begin, commit, retry, abandon, save_load, load_bytes };

const Step = struct {
    op: Op,
    result: ?mode_result_mod.Result = null,
    owner: ?mode_result_mod.Owner = null,
    snapshot: ?[]const u8 = null,
    content_sha256: ?[]const u8 = null,
    expect_error: ?[]const u8 = null,
    expect_store_digest: ?[]const u8 = null,
    expect_receipts: ?[mode_result_mod.model.owner_count]u64 = null,
    expect_pending: ?bool = null,
    expect_pending_owner: ?mode_result_mod.Owner = null,
};

const Case = struct {
    id: []const u8,
    content_sha256: []const u8,
    store: mode_result_mod.Store,
    steps: []const Step,
};

const Vectors = struct {
    schema: []const u8,
    content_sha256: []const u8,
    cases: []const Case,
};

const Limits = struct {
    effects: u8,
    members: u8,
    inventory: u8,
    equipment: u8,
    shared: u8,
    story_bytes: u16,
    money_cap: u32,
    warehouse_entries: u8,
    warehouse_capacity: u16,
    retries: u16,
    snapshot_bytes: u32,
    identity_bytes: u8,
};

const Pinned = struct {
    content_sha256: []const u8,
    roster_digest: []const u8,
    ledger_digest: []const u8,
    story_digest: []const u8,
    store_digest: []const u8,
    result_digest: []const u8,
};

const Packet = struct {
    schema: []const u8,
    host_schema: []const u8,
    result_schema: []const u8,
    limits: Limits,
    before_facts: []const []const u8,
    rejections: []const []const u8,
    pinned_digests: Pinned,
    vector_cases: []const []const u8,
};

fn hexDigest(value: u64) [16]u8 {
    var buffer: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&buffer, "{x:0>16}", .{value}) catch unreachable;
    return buffer;
}

fn fixtureContent() mode_result_mod.Sha {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("suikoden-mode-result/fixture-content", &digest, .{});
    return .{ .bytes = digest };
}

fn id(text: []const u8) mode_result_mod.Id {
    return mode_result_mod.Id.init(text) catch unreachable;
}

fn fixtureMember(
    text: []const u8,
    hp: u16,
    max_hp: u16,
    level: u8,
    weapon: u8,
    experience: u32,
    inventory: []const ?mode_result_mod.Stack,
    equipment: []const ?mode_result_mod.Id,
) mode_result_mod.Member {
    var value: mode_result_mod.Member = .{
        .id = id(text),
        .hp = hp,
        .max_hp = max_hp,
        .level = level,
        .weapon_level = weapon,
        .experience = experience,
    };
    for (inventory, 0..) |item, index| value.inventory[index] = item;
    for (equipment, 0..) |item, index| value.equipment[index] = item;
    return value;
}

fn fixtureStore() mode_result_mod.Store {
    var store: mode_result_mod.Store = .{
        .revision = 2,
        .money = 1234,
        .price_quote = 150,
        .camera = .{ .x = 86, .y = 85, .facing = .east, .place = .world },
        .draws_cursor = 12,
        .receipts = .{ 2, 3, 1, 0 },
        .story_bound = true,
    };
    store.story[39] = 0x10;
    store.party.count = 2;
    store.party.members[0] = fixtureMember(
        "hero",
        44,
        60,
        9,
        3,
        120,
        &.{.{ .item = id("medicine_1"), .uses = 2 }},
        &.{id("bandana")},
    );
    store.party.members[1] = fixtureMember("gremio", 30, 50, 8, 2, 90, &.{}, &.{});
    store.shared[0] = id("medicine_1");
    store.warehouse[0] = .{ .item = id("medicine_1"), .quantity = 3 };
    store.warehouse[1] = .{ .item = id("bandana"), .quantity = 1 };
    store.warehouse_count = 2;
    return store;
}

fn fixtureResult(store: mode_result_mod.Store) mode_result_mod.Result {
    var result: mode_result_mod.Result = .{
        .schema = id(mode_result_mod.result_schema),
        .owner = .travel,
        .kind = .travel_route,
        .entry_id = id("region_b_point_05_to_village"),
        .receipt = 3,
        .expected = .{
            .content_sha256 = fixtureContent(),
            .revision = store.revision,
            .money = store.money,
            .price = null,
            .roster = mode_result_mod.rosterDigest(store),
            .ledger = mode_result_mod.ledgerDigest(store),
            .story = mode_result_mod.storyDigest(store),
            .camera = store.camera,
            .receipt = 2,
        },
        .effect_count = 2,
    };
    result.effects[0] = .{ .kind = .camera, .payload = .{ .camera = .{ .x = 86, .y = 83, .facing = .east, .place = .field } } };
    result.effects[1] = .{ .kind = .story, .payload = .{ .story = .{ .offset = 40, .byte = 1 } } };
    return result;
}

test "packet pins and limits agree with the owned module" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const packet = try std.json.parseFromSliceLeaky(Packet, arena, asset.mode_result_host_json, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("suikoden-mode-result-host-packet/1", packet.schema);
    try std.testing.expectEqualStrings(mode_result_mod.schema, packet.host_schema);
    try std.testing.expectEqualStrings(mode_result_mod.result_schema, packet.result_schema);
    try std.testing.expectEqual(@as(u8, mode_result_mod.max_effects), packet.limits.effects);
    try std.testing.expectEqual(@as(u8, mode_result_mod.max_members), packet.limits.members);
    try std.testing.expectEqual(@as(u8, 9), packet.limits.inventory);
    try std.testing.expectEqual(@as(u8, 5), packet.limits.equipment);
    try std.testing.expectEqual(@as(u8, mode_result_mod.shared_slots), packet.limits.shared);
    try std.testing.expectEqual(@as(u16, 240), packet.limits.story_bytes);
    try std.testing.expectEqual(mode_result_mod.money_cap, packet.limits.money_cap);
    try std.testing.expectEqual(@as(u8, 24), packet.limits.warehouse_entries);
    try std.testing.expectEqual(@as(u16, 254), packet.limits.warehouse_capacity);
    try std.testing.expectEqual(mode_result_mod.max_retries, packet.limits.retries);
    try std.testing.expectEqual(@as(u32, 256 * 1024), packet.limits.snapshot_bytes);
    try std.testing.expect(packet.before_facts.len == 11);
    try std.testing.expect(packet.rejections.len >= 20);

    const store = fixtureStore();
    const result = fixtureResult(store);
    const content_hex = fixtureContent().hex();
    try std.testing.expectEqualStrings(packet.pinned_digests.content_sha256, &content_hex);
    const roster = hexDigest(mode_result_mod.rosterDigest(store));
    try std.testing.expectEqualStrings(packet.pinned_digests.roster_digest, &roster);
    const ledger = hexDigest(mode_result_mod.ledgerDigest(store));
    try std.testing.expectEqualStrings(packet.pinned_digests.ledger_digest, &ledger);
    const story = hexDigest(mode_result_mod.storyDigest(store));
    try std.testing.expectEqualStrings(packet.pinned_digests.story_digest, &story);
    const store_hex = hexDigest(mode_result_mod.storeDigest(store));
    try std.testing.expectEqualStrings(packet.pinned_digests.store_digest, &store_hex);
    const result_hex = hexDigest(mode_result_mod.resultDigest(result));
    try std.testing.expectEqualStrings(packet.pinned_digests.result_digest, &result_hex);
}

test "conformance vectors execute" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const vectors = try std.json.parseFromSliceLeaky(Vectors, arena, asset.conformance_vectors_json, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("suikoden-mode-result-conformance/1", vectors.schema);
    const packet = try std.json.parseFromSliceLeaky(Packet, arena, asset.mode_result_host_json, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(packet.vector_cases.len, vectors.cases.len);

    for (vectors.cases) |case| {
        std.testing.expect(case.id.len != 0) catch return error.InvalidVector;
        const content = try mode_result_mod.Sha.initHex(case.content_sha256);
        var host = try mode_result_mod.Host.init(case.store, content);
        for (case.steps) |step| {
            const outcome: anyerror!void = blk: {
                switch (step.op) {
                    .begin => host.begin(step.result.?) catch |err| break :blk err,
                    .commit => _ = host.commit() catch |err| break :blk err,
                    .retry => _ = host.retry() catch |err| break :blk err,
                    .abandon => host.abandon(step.owner.?) catch |err| break :blk err,
                    .save_load => {
                        const bytes = host.save(arena) catch |err| break :blk err;
                        host = mode_result_mod.Host.load(arena, bytes, content) catch |err| break :blk err;
                    },
                    .load_bytes => {
                        const bound = if (step.content_sha256) |hex| mode_result_mod.Sha.initHex(hex) catch |err| break :blk err else content;
                        host = mode_result_mod.Host.load(arena, step.snapshot.?, bound) catch |err| break :blk err;
                    },
                }
                break :blk {};
            };
            if (step.expect_error) |expected| {
                if (outcome) |_| {
                    std.debug.print("case {s}: expected {s}, step succeeded\n", .{ case.id, expected });
                    return error.ExpectedFailure;
                } else |err| {
                    std.testing.expectEqualStrings(expected, @errorName(err)) catch |mismatch| {
                        std.debug.print("case {s}: expected {s}, got {s}\n", .{ case.id, expected, @errorName(err) });
                        return mismatch;
                    };
                }
            } else outcome catch |err| {
                std.debug.print("case {s} op {s} failed: {s}\n", .{ case.id, @tagName(step.op), @errorName(err) });
                return err;
            };
            if (step.expect_store_digest) |hex| {
                const want = try std.fmt.parseInt(u64, hex, 16);
                try std.testing.expectEqual(want, mode_result_mod.storeDigest(host.store));
            }
            if (step.expect_receipts) |receipts| try std.testing.expectEqual(receipts, host.store.receipts);
            if (step.expect_pending) |pending| try std.testing.expectEqual(pending, host.pending != null);
            if (step.expect_pending_owner) |owner| try std.testing.expectEqual(owner, host.pending.?.result.owner);
        }
    }
}

test "fixture commit is one canonical mutation" {
    const store = fixtureStore();
    var host = try mode_result_mod.Host.init(store, fixtureContent());
    try host.begin(fixtureResult(store));
    const before = mode_result_mod.storeDigest(host.store);
    const outcome = try host.commit();
    try std.testing.expectEqual(@as(u64, 3), outcome.revision);
    try std.testing.expectEqual(@as(u64, 3), outcome.receipt);
    try std.testing.expectEqual(mode_result_mod.Owner.travel, outcome.owner);
    try std.testing.expect(host.pending == null);
    try std.testing.expect(mode_result_mod.storeDigest(host.store) != before);
    try std.testing.expectEqual(@as(u64, 3), host.store.receipts[0]);
    try std.testing.expectEqual(@as(u64, 3), host.store.revision);
    try std.testing.expectEqual(@as(u8, 1), host.store.story[40]);
    try std.testing.expectEqual(@as(i32, 86), host.store.camera.x);
    try std.testing.expectEqual(mode_result_mod.Place.field, host.store.camera.place);
    try std.testing.expectError(error.NoPendingResult, host.commit());
    try std.testing.expectError(error.NoPendingResult, host.retry());
}

test "commit-time staleness keeps the pending owner and a pre-result restore retries" {
    const allocator = std.testing.allocator;
    const store = fixtureStore();
    var host = try mode_result_mod.Host.init(store, fixtureContent());
    try host.begin(fixtureResult(store));
    const snapshot = try host.save(allocator);
    defer allocator.free(snapshot);
    const expected_store = try mode_result_mod.Host.load(allocator, snapshot, fixtureContent());
    defer _ = expected_store;

    host.store.money += 1;
    try std.testing.expectError(error.StaleMoney, host.commit());
    try std.testing.expect(host.pending != null);
    try std.testing.expectEqual(mode_result_mod.Owner.travel, host.pending.?.result.owner);

    var resumed = try mode_result_mod.Host.load(allocator, snapshot, fixtureContent());
    try std.testing.expect(resumed.pending != null);
    try std.testing.expectEqual(@as(u64, 0), resumed.pending.?.attempts);
    const outcome = try resumed.retry();
    try std.testing.expectEqual(@as(u64, 3), outcome.receipt);

    var direct = try mode_result_mod.Host.init(store, fixtureContent());
    try direct.begin(fixtureResult(store));
    _ = try direct.commit();
    try std.testing.expectEqual(mode_result_mod.storeDigest(direct.store), mode_result_mod.storeDigest(resumed.store));
}

test "a tampered pending result is stale and remains rejectable" {
    const store = fixtureStore();
    var host = try mode_result_mod.Host.init(store, fixtureContent());
    try host.begin(fixtureResult(store));
    host.pending.?.result.effects[0].payload.camera.x = 0;
    try std.testing.expectError(error.StaleResult, host.commit());
    try std.testing.expect(host.pending != null);
    // The live store was never touched.
    try std.testing.expectEqual(mode_result_mod.storeDigest(store), mode_result_mod.storeDigest(host.store));
}

test "retry exhaustion and owner-scoped abandon" {
    const store = fixtureStore();
    var host = try mode_result_mod.Host.init(store, fixtureContent());
    try host.begin(fixtureResult(store));
    host.pending.?.attempts = mode_result_mod.max_retries;
    try std.testing.expectError(error.RetryExhausted, host.retry());
    try std.testing.expect(host.pending != null);
    try std.testing.expectError(error.PendingOwnerMismatch, host.abandon(.battle));
    try host.abandon(.travel);
    try std.testing.expectError(error.NoPendingResult, host.commit());
}

test "pending owner is exclusive and a second begin is refused" {
    const store = fixtureStore();
    var host = try mode_result_mod.Host.init(store, fixtureContent());
    try host.begin(fixtureResult(store));
    try std.testing.expectError(error.PendingOwnerBusy, host.begin(fixtureResult(store)));
    try std.testing.expectEqual(mode_result_mod.storeDigest(store), mode_result_mod.storeDigest(host.store));
}

test "snapshot text is deterministic and round-trips the pending owner" {
    const allocator = std.testing.allocator;
    const store = fixtureStore();
    var host = try mode_result_mod.Host.init(store, fixtureContent());
    try host.begin(fixtureResult(store));
    const first = try host.save(allocator);
    defer allocator.free(first);
    const second = try host.save(allocator);
    defer allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    const loaded = try mode_result_mod.Host.load(allocator, first, fixtureContent());
    try std.testing.expectEqual(mode_result_mod.storeDigest(host.store), mode_result_mod.storeDigest(loaded.store));
    try std.testing.expectEqual(mode_result_mod.Owner.travel, loaded.pending.?.result.owner);
    try std.testing.expectEqual(host.pending.?.digest, loaded.pending.?.digest);
}

test "duplicate party identities and an empty replacement party are refused" {
    var store = fixtureStore();
    store.party.members[1].id = store.party.members[0].id;
    try std.testing.expectError(error.InvalidStore, mode_result_mod.Host.init(store, fixtureContent()));
    var hidden = fixtureStore();
    hidden.party.members[2].hp = 1;
    try std.testing.expectError(error.InvalidStore, mode_result_mod.Host.init(hidden, fixtureContent()));
    var bad = fixtureResult(fixtureStore());
    bad.effects[0] = .{ .kind = .party, .payload = .{ .party = .{ .count = 0 } } };
    try std.testing.expectError(error.InvalidEffect, bad.validate());
}

test "trailing non-default effects and foreign effect ownership are invalid" {
    const store = fixtureStore();
    var bad = fixtureResult(store);
    bad.effect_count = 1;
    try std.testing.expectError(error.InvalidResult, bad.validate());
    var travel = fixtureResult(store);
    travel.effects[1] = .{ .kind = .draws, .payload = .{ .draws = .{ .cursor = 9, .bios = null } } };
    try std.testing.expectError(error.InvalidResult, travel.validate());
}

test "unbound story is a typed rejection, not a defaulted write" {
    var store = fixtureStore();
    store.story_bound = false;
    var result = fixtureResult(store);
    result.effects[1] = .{ .kind = .story, .payload = .{ .story = .{ .offset = 40, .byte = 1 } } };
    var host = try mode_result_mod.Host.init(store, fixtureContent());
    try std.testing.expectError(error.UnboundStory, host.begin(result));
    try std.testing.expect(host.pending == null);
}
