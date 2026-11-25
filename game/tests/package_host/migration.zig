//! Save migration focused gate: full-campaign schemas, content rebinding,
//! supported migrations, atomic backup/recovery and the source save policy.
//!
//! Pure logic only: no original instruction, emulator, window, media or real
//! user save is touched.  Every test root is a fresh `std.testing.tmpDir` and
//! `store.Root.isolatedTest` refuses a non-empty directory, so a test cannot be
//! pointed at a real save.

const std = @import("std");
const migration_mod = @import("package_host").migration;

const schema = migration_mod.schema;
const content = migration_mod.content;
const ids = migration_mod.ids;
const store = migration_mod.store;
const codec = migration_mod.codec;
const policy = migration_mod.policy;
const legacy = migration_mod.legacy;
const host = migration_mod.host;

const allocator = std.testing.allocator;
const io = std.testing.io;
const content_path = "game/assets/package_host/content_identity.json";

fn loadContent(arena: std.mem.Allocator) !content.Content {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, content_path, arena, .limited(4 * 1024 * 1024));
    return content.Content.load(arena, bytes, .{});
}

/// A content revision that keeps the real id spaces but changes the revision,
/// optionally dropping one place.  Used to prove re-binding and downgrade
/// refusal without inventing ids.
fn revisedContent(arena: std.mem.Allocator, base: *const content.Content, revision: u32, drop_place: ?[]const u8) !content.Content {
    var doc = base.doc;
    doc.revision = revision;
    if (drop_place) |drop| {
        const places = try arena.alloc(content.Place, doc.places.len);
        var count: usize = 0;
        for (doc.places) |place| {
            if (place.id.eql(drop)) continue;
            places[count] = place;
            count += 1;
        }
        doc.places = places[0..count];
    }
    doc.digest = doc.computeDigest();
    return content.Content.adopt(arena, doc);
}

fn expectFactsEqual(actual: *const schema.Snapshot, expected: *const schema.Snapshot) !void {
    try std.testing.expectEqualStrings(expected.schema, actual.schema);
    try std.testing.expectEqual(expected.revision, actual.revision);
    try std.testing.expectEqual(expected.last_receipt, actual.last_receipt);
    try std.testing.expectEqual(expected.saved_ticks, actual.saved_ticks);
    try std.testing.expectEqual(expected.content.revision, actual.content.revision);
    try std.testing.expect(std.mem.eql(u8, expected.content.campaign.text(), actual.content.campaign.text()));
    try std.testing.expect(expected.content.digest.eql(actual.content.digest));
    try std.testing.expectEqualDeep(expected.roster.identities.bytes, actual.roster.identities.bytes);
    try std.testing.expectEqual(expected.roster.party.len, actual.roster.party.len);
    for (expected.roster.party.slice(), actual.roster.party.slice()) |left, right| {
        try std.testing.expect(std.mem.eql(u8, left.text(), right.text()));
    }
    try std.testing.expectEqual(expected.quest.money, actual.quest.money);
    try std.testing.expect(std.mem.eql(u8, expected.quest.block.text(), actual.quest.block.text()));
    try std.testing.expectEqualDeep(expected.quest.scenario.bytes, actual.quest.scenario.bytes);
    try std.testing.expectEqualStrings(expected.world.map.text(), actual.world.map.text());
    try std.testing.expectEqualStrings(expected.world.room.text(), actual.world.room.text());
    try std.testing.expectEqual(expected.world.x, actual.world.x);
    try std.testing.expectEqual(expected.world.y, actual.world.y);
    try std.testing.expectEqual(expected.world.facing, actual.world.facing);
    try std.testing.expectEqual(expected.hq.stage, actual.hq.stage);
    try std.testing.expectEqualDeep(expected.hq.recruit.bytes, actual.hq.recruit.bytes);
    try std.testing.expectEqual(expected.mode.kind, actual.mode.kind);
    try std.testing.expectEqual(expected.pending != null, actual.pending != null);
}

fn heroMember(id: []const u8, level: u8) schema.Member {
    return .{ .id = ids.Id(32).init(id) catch unreachable, .level = level, .experience = 100, .hp = 30, .max_hp = 40, .weapon_level = 2 };
}

fn testRoot(tmp: *std.testing.TmpDir) !store.Root {
    return store.Root.isolatedTest(io, tmp.dir);
}

fn pendingOf(receipt: u64, owner: schema.ModeKind, effects: []const schema.Effect) !schema.Pending {
    var pending: schema.Pending = .{ .receipt = receipt, .owner = owner, .content_revision = 1 };
    for (effects) |effect| try pending.effects.append(effect);
    return pending;
}

fn openNew(root: store.Root, content_ref: *const content.Content) !host.Opened {
    return host.Campaign.open(allocator, io, root, content_ref, .{}, .{
        .block = try ids.Id(32).init("region_b"),
        .map = try ids.Id(32).init("region_b"),
    });
}

// ---------------------------------------------------------------------------
// Content identity
// ---------------------------------------------------------------------------

test "the committed content identity is reproduced by the Zig digest" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var loaded = try loadContent(arena.allocator());
    defer loaded.deinit();
    try std.testing.expectEqualStrings("suikoden-i-us-1.1", loaded.doc.campaign.text());
    try std.testing.expectEqual(@as(u32, 1), loaded.revision());
    try std.testing.expect(loaded.doc.digest.eql(loaded.doc.computeDigest()));
    try std.testing.expectEqual(@as(usize, 3), loaded.doc.blocks.len);
    try std.testing.expectEqual(@as(usize, 78), loaded.doc.roster_ids.len);
    try std.testing.expectEqual(@as(usize, 179), loaded.doc.items.len);
    try std.testing.expectEqual(@as(usize, 58), loaded.doc.equipment.len);
    try std.testing.expectEqual(@as(usize, 31), loaded.doc.runes.len);
    try std.testing.expectEqual(@as(usize, 0), loaded.doc.quests.len);
    try std.testing.expectEqual(@as(usize, 0), loaded.doc.war_battles.len);
    // A tampered digest is refused by the loader, not accepted.
    var tampered = loaded.doc;
    tampered.digest.bytes[0] ^= 0xFF;
    try std.testing.expectError(error.ContentDigestMismatch, tampered.verifyDigest());
}

// ---------------------------------------------------------------------------
// Schema and codec
// ---------------------------------------------------------------------------

test "a fresh campaign round-trips through the transport with every section" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var loaded = try loadContent(arena.allocator());
    defer loaded.deinit();

    var snapshot = try schema.newGame(&loaded, try ids.Id(32).init("region_b"), try ids.Id(32).init("region_b"));
    snapshot.quest.money = 350;
    snapshot.quest.scenario.bytes[7] = 0x40;
    snapshot.saved_ticks = 1234;
    try snapshot.roster.members.append(heroMember("hero", 5));
    try snapshot.roster.party.append(try ids.Id(32).init("hero"));
    snapshot.hq.stage = 2;
    snapshot.hq.recruit.bytes[3] = 0x3;
    snapshot.hq.tablet_cursor = 9;
    snapshot.hq.rooms.append(try ids.Id(32).init(loaded.doc.hq_rooms[0].text())) catch unreachable;
    snapshot.mode = .{ .kind = .duel, .duel = .{ .id = try ids.Id(32).init("pahn_teo"), .phase = 2, .gauge = 120 } };
    try snapshot.validate(&loaded);

    const bytes = try codec.encode(allocator, snapshot, .{});
    defer allocator.free(bytes);
    const decoded = try codec.decode(allocator, bytes, &loaded, .{});
    defer decoded.deinit();
    try std.testing.expect(decoded.bind.exact);
    try std.testing.expect(decoded.migrated == null);
    try expectFactsEqual(decoded.snapshot, &snapshot);
    try std.testing.expectEqual(@as(u8, 2), decoded.snapshot.mode.duel.?.phase);
    try std.testing.expectEqual(@as(u8, 9), decoded.snapshot.hq.tablet_cursor);
}

test "an older content revision is re-bound only while every id still exists" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var loaded = try loadContent(arena.allocator());
    defer loaded.deinit();
    var newer = try revisedContent(arena.allocator(), &loaded, 2, null);
    defer newer.deinit();
    var reduced = try revisedContent(arena.allocator(), &loaded, 3, "vb6_village");
    defer reduced.deinit();

    var snapshot = try schema.newGame(&loaded, try ids.Id(32).init("region_b"), try ids.Id(32).init("region_b"));
    snapshot.mode = .{ .kind = .field };
    snapshot.world.room = try ids.Id(32).init("vb6_village");
    snapshot.world.x = 48;
    snapshot.world.y = 40;
    try snapshot.roster.members.append(heroMember("hero", 5));
    try snapshot.roster.party.append(try ids.Id(32).init("hero"));
    try snapshot.validate(&loaded);

    const bytes = try codec.encode(allocator, snapshot, .{});
    defer allocator.free(bytes);

    // Revision 2 still contains the room: the file is accepted and re-pointed.
    const rebound = try codec.decode(allocator, bytes, &newer, .{});
    defer rebound.deinit();
    try std.testing.expect(rebound.bind.rebound);
    try std.testing.expectEqual(@as(u32, 1), rebound.bind.from_revision);
    try std.testing.expectEqual(@as(u32, 2), rebound.bind.to_revision);
    try std.testing.expectEqual(@as(u32, 2), rebound.snapshot.content.revision);

    // Revision 3 dropped the room: the rebind is refused, not silently reset.
    try std.testing.expectError(error.UnknownRoom, codec.decode(allocator, bytes, &reduced, .{}));
}

test "a file written by newer content is refused as downgraded, not read as older" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var loaded = try loadContent(arena.allocator());
    defer loaded.deinit();
    var snapshot = try schema.newGame(&loaded, try ids.Id(32).init("region_b"), try ids.Id(32).init("region_b"));
    try snapshot.roster.members.append(heroMember("hero", 5));
    try snapshot.roster.party.append(try ids.Id(32).init("hero"));
    snapshot.content.revision = 9;
    const bytes = try codec.encode(allocator, snapshot, .{});
    defer allocator.free(bytes);
    try std.testing.expectError(error.ContentDowngraded, codec.decode(allocator, bytes, &loaded, .{}));

    snapshot.content.revision = 1;
    snapshot.content.campaign = try ids.Id(32).init("other-campaign");
    const foreign = try codec.encode(allocator, snapshot, .{});
    defer allocator.free(foreign);
    try std.testing.expectError(error.ForeignCampaign, codec.decode(allocator, foreign, &loaded, .{}));
}

test "future schema, missing fields, unknown fields and malformed bytes are distinct refusals" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var loaded = try loadContent(arena.allocator());
    defer loaded.deinit();
    var snapshot = try schema.newGame(&loaded, try ids.Id(32).init("region_b"), try ids.Id(32).init("region_b"));
    try snapshot.roster.members.append(heroMember("hero", 5));
    try snapshot.roster.party.append(try ids.Id(32).init("hero"));
    const good = try codec.encode(allocator, snapshot, .{});
    defer allocator.free(good);

    const future = try std.mem.replaceOwned(u8, allocator, good, "\"suikoden-campaign-save/1\"", "\"suikoden-campaign-save/2\"");
    defer allocator.free(future);
    try std.testing.expectError(error.FutureCampaignSchema, codec.decode(allocator, future, &loaded, .{}));

    const missing = try std.mem.replaceOwned(u8, allocator, good, "\"saved_ticks\":", "\"saved_ticks_typo\":");
    defer allocator.free(missing);
    try std.testing.expectError(error.MissingField, codec.decode(allocator, missing, &loaded, .{}));

    const unknown = try std.mem.replaceOwned(u8, allocator, good, "\"saved_ticks\":", "\"extra_field\":1,\"saved_ticks\":");
    defer allocator.free(unknown);
    try std.testing.expectError(error.UnknownField, codec.decode(allocator, unknown, &loaded, .{}));

    try std.testing.expectError(error.DocumentUnbalanced, codec.decode(allocator, "{\"schema\":", &loaded, .{}));
    try std.testing.expectError(error.SyntaxError, codec.decode(allocator, "{\"schema\": }", &loaded, .{}));
    var deep: [128]u8 = @splat('[');
    for (deep[64..]) |*byte| byte.* = ']';
    try std.testing.expectError(error.DocumentTooDeep, codec.decode(allocator, &deep, &loaded, .{ .depth = 8 }));
}

test "bounded parsing refuses an oversized or hostile document before allocation" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var loaded = try loadContent(arena.allocator());
    defer loaded.deinit();
    const big = try allocator.alloc(u8, 4096);
    defer allocator.free(big);
    @memset(big, ' ');
    big[0] = '{';
    big[1] = '}';
    try std.testing.expectError(error.DocumentTooLarge, codec.decode(allocator, big, &loaded, .{ .bytes = 128 }));
    // A legal but expanded document cannot exceed the arena budget.
    const padding: [2048]u8 = @splat('x');
    const padded = try std.mem.concat(allocator, u8, &.{ "{\"schema\":\"suikoden-campaign-save/1\",\"pad\":\"", &padding, "\"}" });
    defer allocator.free(padded);
    try std.testing.expectError(error.OutOfMemory, codec.decode(allocator, padded, &loaded, .{ .arena_bytes = 256 }));
}

// ---------------------------------------------------------------------------
// Durable transaction and recovery
// ---------------------------------------------------------------------------

test "a pending result commits exactly once and is durable across a reopen" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var loaded = try loadContent(arena.allocator());
    defer loaded.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);

    var opened = try openNew(root, &loaded);
    try opened.campaign.queue(try pendingOf(1, .battle, &.{
        .{ .kind = .money, .amount = 500 },
        .{ .kind = .recruit_record, .id = try ids.Id(32).init("viktor"), .amount = 42, .value = 1 },
    }));
    try std.testing.expect(opened.campaign.snapshot.pending != null);
    const outcome = try opened.campaign.commit(io);
    try std.testing.expectEqual(@as(u64, 1), outcome.revision);
    try std.testing.expectEqual(@as(u64, 1), outcome.receipt);
    try std.testing.expect(opened.campaign.snapshot.pending == null);
    try std.testing.expectEqual(@as(u32, 500), opened.campaign.snapshot.quest.money);
    try std.testing.expectEqual(@as(u8, 0x30), opened.campaign.snapshot.roster.identities.bytes[5]);

    // Same root, fresh owner: the committed value, not the pending one, is read.
    var reopened = try openNew(root, &loaded);
    try std.testing.expect(reopened.outcome != null);
    try std.testing.expectEqual(store.Which.primary, reopened.outcome.?.source);
    try std.testing.expectEqual(@as(u32, 500), reopened.campaign.snapshot.quest.money);
    try std.testing.expectEqual(@as(u64, 1), reopened.campaign.snapshot.revision);
    try std.testing.expect(reopened.campaign.snapshot.pending == null);

    // A repeated or stale receipt is refused by the queue, so it cannot apply twice.
    try std.testing.expectError(error.StalePendingReceipt, reopened.campaign.queue(try pendingOf(1, .battle, &.{.{ .kind = .money, .amount = 1 }})));
}

test "every interrupted write preserves the campaign and the pending result" {
    const faults = [_]store.Fault{ .after_temp_write, .after_temp_sync, .after_journal_write, .after_backup_rotate, .before_replace };
    for (faults) |fault| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var loaded = try loadContent(arena.allocator());
        defer loaded.deinit();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try testRoot(&tmp);

        var opened = try openNew(root, &loaded);
        try opened.campaign.rewrite(io); // a settled campaign exists first
        try opened.campaign.queue(try pendingOf(1, .battle, &.{.{ .kind = .money, .amount = 500 }}));
        try std.testing.expectError(error.InjectedWriteFailure, opened.campaign.commitFaulted(io, fault));
        // In-memory state is untouched: no money, pending still owned.
        try std.testing.expectEqual(@as(u32, 0), opened.campaign.snapshot.quest.money);
        try std.testing.expect(opened.campaign.snapshot.pending != null);
        try std.testing.expectEqual(@as(u64, 0), opened.campaign.snapshot.revision);

        // The same owner retries the unchanged pending result; the store first
        // resolves whatever the interrupted write left behind.
        const retry = try opened.campaign.commit(io);
        try std.testing.expectEqual(@as(u64, 1), retry.revision);
        try std.testing.expectEqual(@as(u32, 500), opened.campaign.snapshot.quest.money);
        try std.testing.expect(opened.campaign.snapshot.pending == null);

        // Exactly once: a fresh owner sees one committed result, not two.
        const again = try openNew(root, &loaded);
        try std.testing.expectEqual(@as(u32, 500), again.campaign.snapshot.quest.money);
        try std.testing.expectEqual(@as(u64, 1), again.campaign.snapshot.revision);
        try std.testing.expectEqual(@as(u64, 1), again.campaign.snapshot.last_receipt);
    }
}

test "a torn primary falls back to the rotated backup; a future file does not" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var loaded = try loadContent(arena.allocator());
    defer loaded.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);

    var opened = try openNew(root, &loaded);
    try opened.campaign.queue(try pendingOf(1, .battle, &.{.{ .kind = .money, .amount = 700 }}));
    _ = try opened.campaign.commit(io); // primary: money 700
    var second = try openNew(root, &loaded);
    try second.campaign.queue(try pendingOf(2, .battle, &.{.{ .kind = .money, .amount = 100 }}));
    _ = try second.campaign.commit(io); // backup: money 700, primary: 800

    // Torn primary: the rotated backup is the last complete campaign.
    try tmp.dir.writeFile(io, .{ .sub_path = store.file_primary, .data = "{\"schema\":\"suikoden-campaign-save/1\"" });
    const recovered = try openNew(root, &loaded);
    try std.testing.expectEqual(store.Which.backup, recovered.outcome.?.source);
    try std.testing.expectEqual(@as(u32, 700), recovered.campaign.snapshot.quest.money);

    // A corrupt primary must not be rotated over the last good backup.  The
    // new write lands, the backup stays at money 700, and a later tear still
    // recovers that campaign instead of the corrupt bytes.
    try tmp.dir.writeFile(io, .{ .sub_path = store.file_primary, .data = "garbage" });
    var healed = try openNew(root, &loaded);
    try std.testing.expectEqual(store.Which.backup, healed.outcome.?.source);
    try std.testing.expectEqual(@as(u32, 700), healed.campaign.snapshot.quest.money);
    healed.campaign.snapshot.pending = try pendingOf(2, .battle, &.{.{ .kind = .money, .amount = 200 }});
    _ = try healed.campaign.commit(io); // primary: money 900; backup must stay 700
    try tmp.dir.writeFile(io, .{ .sub_path = store.file_primary, .data = "torn again" });
    const after = try openNew(root, &loaded);
    try std.testing.expectEqual(store.Which.backup, after.outcome.?.source);
    try std.testing.expectEqual(@as(u32, 700), after.campaign.snapshot.quest.money);

    // A future primary is a protected refusal and must not be replaced by the
    // older backup bytes.
    var future = after.campaign.snapshot;
    future.schema = "suikoden-campaign-save/2";
    const future_bytes = try codec.encode(allocator, future, .{});
    defer allocator.free(future_bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = store.file_primary, .data = future_bytes });
    try std.testing.expectError(error.FutureCampaignSchema, openNew(root, &loaded));
    const primary = try tmp.dir.readFileAlloc(io, store.file_primary, allocator, .limited(1024 * 1024));
    defer allocator.free(primary);
    try std.testing.expectEqualStrings(future_bytes, primary);
}

test "a full or read-only root keeps the campaign and the pending ownership" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var loaded = try loadContent(arena.allocator());
    defer loaded.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);

    var opened = try openNew(root, &loaded);
    try opened.campaign.rewrite(io);
    try opened.campaign.queue(try pendingOf(1, .battle, &.{.{ .kind = .money, .amount = 250 }}));

    // Full filesystem: the sync fails.
    var sync_vtable = io.vtable.*;
    sync_vtable.fileSync = struct {
        fn fail(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
            return error.NoSpaceLeft;
        }
    }.fail;
    var full_io = io;
    full_io.vtable = &sync_vtable;
    try std.testing.expectError(error.NoSpaceLeft, opened.campaign.save(full_io, .{ .allow = .campaign_slot }));

    // Read-only root: the temp file cannot be created at all.
    var create_vtable = io.vtable.*;
    create_vtable.dirCreateFile = struct {
        fn fail(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir.CreateFileOptions) std.Io.File.OpenError!std.Io.File {
            return error.AccessDenied;
        }
    }.fail;
    var readonly_io = io;
    readonly_io.vtable = &create_vtable;
    var commit_refused = false;
    _ = opened.campaign.commit(readonly_io) catch |err| switch (err) {
        error.AccessDenied => blk: {
            commit_refused = true;
            break :blk .{ .revision = 0, .receipt = 0 };
        },
        else => return err,
    };
    try std.testing.expect(commit_refused);

    // Both failures left the in-memory campaign and the pending result intact,
    // and the durable campaign is still the settled one (pending was produced
    // by this owner, not yet committed to disk).
    try std.testing.expectEqual(@as(u32, 0), opened.campaign.snapshot.quest.money);
    try std.testing.expect(opened.campaign.snapshot.pending != null);
    const reopened = try openNew(root, &loaded);
    try std.testing.expectEqual(@as(u32, 0), reopened.campaign.snapshot.quest.money);
    try std.testing.expectEqual(@as(u64, 0), reopened.campaign.snapshot.last_receipt);

    // The same owner retries on a writable root and commits once.
    const outcome = try opened.campaign.commit(io);
    try std.testing.expectEqual(@as(u64, 1), outcome.revision);
    try std.testing.expectEqual(@as(u32, 250), opened.campaign.snapshot.quest.money);
    const durable = try openNew(root, &loaded);
    try std.testing.expectEqual(@as(u32, 250), durable.campaign.snapshot.quest.money);
    try std.testing.expectEqual(@as(u64, 1), durable.campaign.snapshot.last_receipt);
}

test "a stray temp without a journal is discarded and never becomes the campaign" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var loaded = try loadContent(arena.allocator());
    defer loaded.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);

    var opened = try openNew(root, &loaded);
    try opened.campaign.queue(try pendingOf(1, .battle, &.{.{ .kind = .money, .amount = 10 }}));
    _ = try opened.campaign.commit(io);
    try tmp.dir.writeFile(io, .{ .sub_path = store.file_temp, .data = "half a save" });
    var reopened = try openNew(root, &loaded);
    try std.testing.expectEqual(store.Recovery.discarded_temp, reopened.outcome.?.recovery);
    try std.testing.expectEqual(@as(u32, 10), reopened.campaign.snapshot.quest.money);
    try std.testing.expect(!reopened.campaign.store.exists(io, .primary) == false);
}

test "a test root refuses to open over an existing directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "campaign.json", .data = "{}" });
    try std.testing.expectError(error.TestRootNotEmpty, store.Root.isolatedTest(io, tmp.dir));
}

test "a rejected load leaves the live campaign and its pending result untouched" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var loaded = try loadContent(arena.allocator());
    defer loaded.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);

    var opened = try openNew(root, &loaded);
    try opened.campaign.rewrite(io);
    try opened.campaign.queue(try pendingOf(1, .duel, &.{.{ .kind = .money, .amount = 300 }}));
    // A future file on disk is a protected refusal: the live value must not be
    // replaced and the pending result stays owned.
    var future = opened.campaign.snapshot;
    future.schema = "suikoden-campaign-save/2";
    const future_bytes = try codec.encode(allocator, future, .{});
    defer allocator.free(future_bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = store.file_primary, .data = future_bytes });
    try std.testing.expectError(error.FutureCampaignSchema, opened.campaign.load(io));
    try std.testing.expectEqual(@as(u32, 0), opened.campaign.snapshot.quest.money);
    try std.testing.expect(opened.campaign.snapshot.pending != null);
    try std.testing.expectEqual(schema.ModeKind.duel, opened.campaign.snapshot.pending.?.owner);
}

// ---------------------------------------------------------------------------
// Save policy
// ---------------------------------------------------------------------------

test "the campaign writer refuses non-pause-menu causes without touching the disk" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var loaded = try loadContent(arena.allocator());
    defer loaded.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);

    var opened = try openNew(root, &loaded);
    try std.testing.expectError(error.SaveRefused, opened.campaign.save(io, policy.decide(.{ .cause = .inn_stay, .presence = .field })));
    try std.testing.expectError(error.SaveRefused, opened.campaign.save(io, policy.decide(.{ .cause = .floating_orb, .presence = .world })));
    try std.testing.expectError(error.SaveRefused, opened.campaign.save(io, policy.decide(.{ .cause = .setup_change, .presence = .title })));
    try std.testing.expectError(error.SaveRefused, opened.campaign.save(io, policy.decide(.{ .cause = .pause_menu_save, .presence = .battle })));
    try std.testing.expect(!opened.campaign.store.exists(io, .primary));
    try opened.campaign.save(io, policy.decide(.{ .cause = .pause_menu_save, .presence = .field }));
    try std.testing.expect(opened.campaign.store.exists(io, .primary));
}

// ---------------------------------------------------------------------------
// Migration
// ---------------------------------------------------------------------------

const FixStack = struct { id: []const u8, uses: u16, identified: bool = true };
const FixInventory = struct { slots: [9]?FixStack = @splat(null) };
const FixMember = struct {
    id: []const u8,
    hp: u16,
    max_hp: u16,
    status: []const u8,
    rune_charges: [4]u16 = .{ 0, 0, 0, 0 },
    max_rune_charges: [4]u16 = .{ 0, 0, 0, 0 },
    inventory: ?FixInventory = null,
};
const FixScenario = struct { schema: []const u8 = "suikoden-event-story/1", scenario: [240]u8 = @splat(0) };
const FixStory = struct { scenario: ?FixScenario = null };
const FixLoadout = struct { head: ?usize = null, body: ?usize = null, shield: ?usize = null, accessory_one: ?usize = null, accessory_two: ?usize = null };
const FixOwned = struct { member: FixMember, level: u8, experience: u32, weapon_level: u8, loadout: ?FixLoadout = null, rune: ?usize = null };
const FixJourney = struct {
    schema: []const u8,
    room: []const u8,
    x: i32,
    y: i32,
    facing: []const u8,
    money: u32,
    story: FixStory,
    party: [6]FixMember,
    levels: [6]u8,
    experience: [6]u32,
    weapon_levels: ?[6]u8 = null,
    equipment: ?[6]?usize = null,
    loadouts: ?[6]FixLoadout = null,
    runes: ?[6]?usize = null,
    reserves: ?[72]?FixOwned = null,
    elapsed_ticks: ?u64 = null,
};

const FixPosition = struct {
    state: struct {
        mode: []const u8,
        camera: struct { x: i32, y: i32 },
        heading: []const u8 = "down",
    },
    region: []const u8,
};
const FixCampaign = struct { mode: []const u8 = "none", boat_ledger_json: ?[]const u8 = null, boat_session_json: ?[]const u8 = null, teleport_json: ?[]const u8 = null };
const FixWorldSession = struct { schema: []const u8, ownership: FixJourney, position: FixPosition, campaign: ?FixCampaign = null, hq: ?struct { version: u8 = 1 } = null };

fn fixParty() [6]FixMember {
    const ids_list = [_][]const u8{ "hero", "gremio", "pahn", "viktor", "yam_koo", "tai_ho" };
    var result: [6]FixMember = undefined;
    for (&result, ids_list) |*member, id| {
        member.* = .{ .id = id, .hp = 30, .max_hp = 40, .status = "healthy" };
    }
    result[0].inventory = .{ .slots = .{ .{ .id = "medicine", .uses = 6 }, null, null, null, null, null, null, null, null } };
    return result;
}

fn fixJourney() FixJourney {
    return .{
        .schema = "suikoden-journey-save/16",
        .room = "vb6_village",
        .x = 48,
        .y = 40,
        .facing = "down",
        .money = 350,
        .story = .{ .scenario = .{} },
        .party = fixParty(),
        .levels = .{ 5, 4, 3, 3, 2, 2 },
        .experience = .{ 900, 700, 500, 500, 300, 300 },
        .weapon_levels = .{ 2, 1, 1, 1, 1, 1 },
        .equipment = .{ null, null, null, null, null, null },
        .runes = .{ null, null, null, null, null, null },
        .elapsed_ticks = 4321,
    };
}

const TestGear = struct {
    fn equipmentId(_: *const anyopaque, index: usize) ?[]const u8 {
        return switch (index) {
            0 => "bandanna",
            1 => "tunic",
            else => null,
        };
    }
    fn runeId(_: *const anyopaque, index: usize) ?[]const u8 {
        return switch (index) {
            0 => "fire",
            else => null,
        };
    }
};

const test_bindings: legacy.Bindings = .{
    .equipment = .{ .ctx = undefined, .id_for_index = TestGear.equipmentId },
    .rune = .{ .ctx = undefined, .id_for_index = TestGear.runeId },
};

test "a journey save in the canonical opening room migrates without a world map" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var loaded = try loadContent(arena.allocator());
    defer loaded.deinit();
    var fixture = fixJourney();
    fixture.room = "vaa_room_2";
    const bytes = try std.json.Stringify.valueAlloc(allocator, fixture, .{});
    defer allocator.free(bytes);
    const decoded = try codec.loadAny(allocator, bytes, &loaded, .{});
    defer decoded.deinit();
    try std.testing.expectEqualStrings("vaa_room_2", decoded.snapshot.world.room.text());
    try std.testing.expectEqualStrings("canonical_opening", decoded.snapshot.world.block.text());
    try std.testing.expect(!decoded.snapshot.world.map.isSet());
    try std.testing.expectEqual(schema.ModeKind.field, decoded.snapshot.mode.kind);
}

test "a world-session save migrates with roster, quest, position and block" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var loaded = try loadContent(arena.allocator());
    defer loaded.deinit();
    const fixture = FixWorldSession{
        .schema = "suikoden-world-session/9",
        .ownership = fixJourney(),
        .position = .{ .state = .{ .mode = "field", .camera = .{ .x = 10, .y = 20 } }, .region = "region_b" },
    };
    const bytes = try std.json.Stringify.valueAlloc(allocator, fixture, .{});
    defer allocator.free(bytes);
    const decoded = try codec.loadAny(allocator, bytes, &loaded, .{});
    defer decoded.deinit();
    try std.testing.expectEqual(legacy.Source.world_session, decoded.migrated.?);
    const snapshot = decoded.snapshot;
    try std.testing.expectEqual(@as(u32, 350), snapshot.quest.money);
    try std.testing.expectEqualStrings("region_b", snapshot.world.map.text());
    try std.testing.expectEqualStrings("vb6_village", snapshot.world.room.text());
    try std.testing.expectEqualStrings("region_b", snapshot.world.block.text());
    try std.testing.expectEqual(@as(i32, 10), snapshot.world.camera_x);
    try std.testing.expectEqual(@as(u8, 0), snapshot.world.facing);
    try std.testing.expectEqual(@as(u64, 4321), snapshot.saved_ticks);
    try std.testing.expectEqual(@as(u8, 6), snapshot.roster.party.len);
    try std.testing.expectEqual(@as(u8, 5), snapshot.roster.members.slice()[0].level);
    try std.testing.expectEqual(@as(u8, 2), snapshot.roster.members.slice()[0].weapon_level);
    try std.testing.expectEqualStrings("medicine", snapshot.roster.members.slice()[0].inventory.slice()[0].id.text());
    try std.testing.expectEqual(schema.ModeKind.field, snapshot.mode.kind);
}

test "a journey save migrates; an owned gear index needs the battle-systems binding" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var loaded = try loadContent(arena.allocator());
    defer loaded.deinit();
    const fixture = fixJourney();
    const plain = try std.json.Stringify.valueAlloc(allocator, fixture, .{});
    defer allocator.free(plain);
    const decoded = try codec.loadAny(allocator, plain, &loaded, .{});
    defer decoded.deinit();
    try std.testing.expectEqual(legacy.Source.journey, decoded.migrated.?);
    try std.testing.expectEqualStrings("vb6_village", decoded.snapshot.world.room.text());

    // Gear without the ordered battle-systems index->id binding is refused.
    var geared = fixture;
    geared.equipment = .{ 0, null, null, null, null, null };
    const geared_bytes = try std.json.Stringify.valueAlloc(allocator, geared, .{});
    defer allocator.free(geared_bytes);
    try std.testing.expectError(error.LegacyGearUnbound, codec.loadAny(allocator, geared_bytes, &loaded, .{}));

    // With the binding the index resolves to the real content id.
    const geared_value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), geared_bytes, .{});
    const mapped = try legacy.migrateValue(arena.allocator(), geared_value, &loaded, test_bindings);
    try std.testing.expectEqualStrings("bandanna", mapped.snapshot.roster.members.slice()[0].equipment.slice()[0].?.text());
}

test "unsupported legacy facts are refused by name, never dropped" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var loaded = try loadContent(arena.allocator());
    defer loaded.deinit();

    // HQ sidecar: needs the HQ roster asset.
    const hq_fixture = FixWorldSession{
        .schema = "suikoden-world-session/10",
        .ownership = fixJourney(),
        .position = .{ .state = .{ .mode = "field", .camera = .{ .x = 0, .y = 0 } }, .region = "region_b" },
        .hq = .{ .version = 1 },
    };
    const hq_bytes = try std.json.Stringify.valueAlloc(allocator, hq_fixture, .{});
    defer allocator.free(hq_bytes);
    try std.testing.expectError(error.LegacyHqSidecarUnbound, codec.loadAny(allocator, hq_bytes, &loaded, .{}));

    // Active boat/teleport session: travel host state.
    const travel_fixture = FixWorldSession{
        .schema = "suikoden-world-session/9",
        .ownership = fixJourney(),
        .position = .{ .state = .{ .mode = "field", .camera = .{ .x = 0, .y = 0 } }, .region = "region_b" },
        .campaign = .{ .mode = "boat", .boat_ledger_json = "{}" },
    };
    const travel_bytes = try std.json.Stringify.valueAlloc(allocator, travel_fixture, .{});
    defer allocator.free(travel_bytes);
    try std.testing.expectError(error.LegacyTravelSessionActive, codec.loadAny(allocator, travel_bytes, &loaded, .{}));

    // A mid-battle capture is not a durable campaign state.
    const busy_fixture = FixWorldSession{
        .schema = "suikoden-world-session/9",
        .ownership = fixJourney(),
        .position = .{ .state = .{ .mode = "battle_pending", .camera = .{ .x = 0, .y = 0 } }, .region = "region_b" },
    };
    const busy_bytes = try std.json.Stringify.valueAlloc(allocator, busy_fixture, .{});
    defer allocator.free(busy_bytes);
    try std.testing.expectError(error.LegacyBusyMode, codec.loadAny(allocator, busy_bytes, &loaded, .{}));

    // The field slot has no level/experience/weapon fields at all.
    try std.testing.expectError(error.LegacyFormatUnsupported, codec.loadAny(allocator, "{\"schema\":\"suikoden-save/3\",\"room\":\"village\",\"x\":0,\"y\":0,\"facing\":\"down\",\"money\":0,\"party\":[]}", &loaded, .{}));
}

test "the HQ section round-trips stage, recruit bytes, rooms and services" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var loaded = try loadContent(arena.allocator());
    defer loaded.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);

    var opened = try openNew(root, &loaded);
    var snapshot = &opened.campaign.snapshot;
    snapshot.hq.stage = 3;
    snapshot.hq.recruit.bytes[0] = 0x3;
    snapshot.hq.recruit.bytes[107] = 0x3;
    snapshot.hq.tablet_cursor = 77;
    snapshot.hq.screen = .tablet;
    snapshot.hq.room = try ids.Id(32).init(loaded.doc.hq_rooms[0].text());
    try snapshot.hq.rooms.append(snapshot.hq.room);
    try snapshot.hq.services.append(try ids.Id(32).init(loaded.doc.services[0].text()));
    snapshot.mode = .{ .kind = .hq };
    try snapshot.roster.members.append(heroMember("hero", 5));
    try snapshot.roster.party.append(try ids.Id(32).init("hero"));
    try snapshot.validate(&loaded);
    try opened.campaign.save(io, .{ .allow = .campaign_slot });

    const reopened = try openNew(root, &loaded);
    try std.testing.expectEqual(schema.ModeKind.hq, reopened.campaign.snapshot.mode.kind);
    try std.testing.expectEqual(@as(u8, 3), reopened.campaign.snapshot.hq.stage);
    try std.testing.expectEqual(@as(u8, 77), reopened.campaign.snapshot.hq.tablet_cursor);
    var expected_recruit: [108]u8 = @splat(0);
    expected_recruit[0] = 0x3;
    expected_recruit[107] = 0x3;
    try std.testing.expectEqualDeep(expected_recruit, reopened.campaign.snapshot.hq.recruit.bytes);
    try std.testing.expectEqual(@as(u8, 1), reopened.campaign.snapshot.hq.services.len);

    // A stage the content does not declare is refused, not clamped.
    snapshot.hq.stage = 15;
    try std.testing.expectError(error.UnknownHqStage, snapshot.validate(&loaded));
    // A recruit byte above the two used bits is corruption, not presence data.
    snapshot.hq.stage = 3;
    snapshot.hq.recruit.bytes[0] = 0xF0;
    try std.testing.expectError(error.InvalidRecruitByte, snapshot.validate(&loaded));
}

// ---------------------------------------------------------------------------
// Cross-mode / cross-block states and the external id spaces
// ---------------------------------------------------------------------------

test "cross-mode saves keep the active mode and its typed resume facts" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var loaded = try loadContent(arena.allocator());
    defer loaded.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);

    var opened = try openNew(root, &loaded);
    // A real accepted duel id, then a real accepted minigame id.
    opened.campaign.snapshot.mode = .{ .kind = .duel, .duel = .{ .id = try ids.Id(32).init("pahn_teo"), .phase = 1, .gauge = 40 } };
    try opened.campaign.snapshot.roster.members.append(heroMember("hero", 5));
    try opened.campaign.snapshot.roster.party.append(try ids.Id(32).init("hero"));
    try opened.campaign.snapshot.validate(&loaded);
    try opened.campaign.save(io, .{ .allow = .campaign_slot });

    var reopened = try openNew(root, &loaded);
    try std.testing.expectEqual(schema.ModeKind.duel, reopened.campaign.snapshot.mode.kind);
    try std.testing.expectEqualStrings("pahn_teo", reopened.campaign.snapshot.mode.duel.?.id.text());
    try std.testing.expectEqual(@as(u16, 40), reopened.campaign.snapshot.mode.duel.?.gauge);

    reopened.campaign.snapshot.mode = .{ .kind = .minigame, .minigame = .{ .id = try ids.Id(32).init(loaded.doc.minigames[0].text()), .seed = 0x1234, .step = 3 } };
    try reopened.campaign.save(io, .{ .allow = .campaign_slot });
    var third = try openNew(root, &loaded);
    try std.testing.expectEqual(schema.ModeKind.minigame, third.campaign.snapshot.mode.kind);
    try std.testing.expectEqual(@as(u32, 3), third.campaign.snapshot.mode.minigame.?.step);

    // A war resume cannot be invented: the war id space is external.
    third.campaign.snapshot.mode = .{ .kind = .war, .war = .{ .id = try ids.Id(32).init("war_battle_1"), .handoff = try ids.Id(32).init("kimi_handoff_1") } };
    try std.testing.expectError(error.InvalidModeState, third.campaign.snapshot.validate(&loaded));
}

test "a save whose block/room moved to another block is refused after rebinding" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var loaded = try loadContent(arena.allocator());
    defer loaded.deinit();
    var snapshot = try schema.newGame(&loaded, try ids.Id(32).init("region_b"), try ids.Id(32).init("region_b"));
    snapshot.mode = .{ .kind = .field };
    snapshot.world.room = try ids.Id(32).init("vb6_village");
    snapshot.world.x = 48;
    snapshot.world.y = 40;
    try snapshot.roster.members.append(heroMember("hero", 5));
    try snapshot.roster.party.append(try ids.Id(32).init("hero"));
    try snapshot.validate(&loaded);
    const bytes = try codec.encode(allocator, snapshot, .{});
    defer allocator.free(bytes);

    // A newer revision that keeps the ids is accepted.
    var newer = try revisedContent(arena.allocator(), &loaded, 2, null);
    defer newer.deinit();
    const decoded = try codec.decode(allocator, bytes, &newer, .{});
    defer decoded.deinit();
    try std.testing.expect(decoded.bind.rebound);

    // A block that is not in the content is refused outright.
    snapshot.quest.block = try ids.Id(32).init("invented_block");
    try std.testing.expectError(error.UnknownBlock, snapshot.validate(&loaded));
}
