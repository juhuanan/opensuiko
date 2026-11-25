//! Content-graph focused tests: immutable reviewed-content graph loading, named
//! identity joins, cross-version refusal, and content lifetime across a mode
//! switch and a checkpoint restore.
//!
//! The test embeds the committed content graph asset and never executes
//! original instructions.

const std = @import("std");
const content_graph_mod = @import("campaign_policies").content_graph;
const data = @import("campaign_policies_data").content_graph;

const graph_bytes = data.json;

fn open(allocator: std.mem.Allocator) !*content_graph_mod.Content {
    return content_graph_mod.open(allocator, graph_bytes);
}

fn parseCopy(allocator: std.mem.Allocator) !std.json.Parsed(content_graph_mod.Graph) {
    return std.json.parseFromSlice(content_graph_mod.Graph, allocator, graph_bytes, .{ .allocate = .alloc_always });
}

fn findCharacter(copy: *content_graph_mod.Graph, id: []const u8) *const content_graph_mod.Character {
    for (copy.characters) |*character| if (std.mem.eql(u8, character.id, id)) return character;
    unreachable;
}

fn replace(allocator: std.mem.Allocator, bytes: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    if (needle.len != replacement.len) return error.LengthMismatch;
    const index = std.mem.indexOf(u8, bytes, needle) orelse return error.NotFound;
    const copy = try allocator.dupe(u8, bytes);
    @memcpy(copy[index .. index + needle.len], replacement);
    return copy;
}

fn flip(allocator: std.mem.Allocator, bytes: []const u8, index: usize) ![]u8 {
    const copy = try allocator.dupe(u8, bytes);
    copy[index] = if (copy[index] == 'a') 'b' else 'a';
    return copy;
}

fn replaceAll(allocator: std.mem.Allocator, bytes: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    if (needle.len != replacement.len) return error.LengthMismatch;
    const copy = try allocator.dupe(u8, bytes);
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, copy, index, needle)) |position| {
        @memcpy(copy[position .. position + needle.len], replacement);
        index = position + needle.len;
    }
    return copy;
}

test "loads the reviewed graph and recomputes every section digest" {
    var content = try open(std.testing.allocator);
    defer content.release();

    const graph = content.graph();
    try std.testing.expectEqualStrings("suikoden-campaign-content-graph/1", graph.schema);
    try std.testing.expectEqual(@as(usize, 1), content.references());
    try std.testing.expectEqual(@as(u16, 74), content.compatibleCount());
    try std.testing.expectEqual(@as(usize, 78), graph.characters.len);
    try std.testing.expectEqual(@as(usize, 179), graph.items.len);
    try std.testing.expectEqual(@as(usize, 8), graph.areas.len);
    try std.testing.expectEqual(@as(usize, 37), graph.drop_items.len);
    try std.testing.expectEqualStrings("b23023b00e0e1aef", graph.digests.items);

    var formations: usize = 0;
    var enemies: usize = 0;
    for (graph.areas) |area| {
        formations += area.formations.len;
        enemies += area.enemies.len;
    }
    try std.testing.expectEqual(@as(usize, 77), formations);
    try std.testing.expectEqual(@as(usize, 29), enemies);

    const expected = [_][]const u8{
        "2599058d4581f3b5349027d16be34077460d4f2735558462ac893baea1cea38f",
        "9762265f75efcfdbb7b6db3c1aa9ae056a4462b380f851ca83513ae7624f218d",
        "ca19a0f12154b99a6c1275cafe2b420e0f14502885548830a40f551920521fa9",
        "24b014bb9567150d92cc6bcca4fca3d775da5995e77d1ea38c9817cd16c4664c",
    };
    for (graph.provenance.packages, expected) |package, sha| {
        try std.testing.expectEqualStrings(sha, package.asset_file_sha256);
        try std.testing.expectEqual(@as(usize, 64), package.asset_canonical_sha256.len);
    }
    try std.testing.expectEqual(@as(usize, 78), graph.provenance.resources.len);
}

test "named identity joins bind resources, poses, actions, items and formations" {
    var content = try open(std.testing.allocator);
    defer content.release();

    const character = try content.character("alen");
    try std.testing.expectEqualStrings("are", character.resource);
    try std.testing.expectEqualStrings("supported", character.residency_status);

    const pose = try content.pose("alen", 0);
    try std.testing.expectEqual(@as(u32, 0), pose.index);
    try std.testing.expect(pose.pieces.len > 0);
    try std.testing.expectEqual(@as(u32, 1), pose.pieces[0].page);
    try std.testing.expectEqual(@as(u32, 0), pose.pieces[0].outside_samples);
    const page = character.pages[pose.pieces[0].page];

    const action = try content.action("alen");
    var bound = false;
    for (action.pages) |binding| {
        if (binding.index == pose.pieces[0].page) {
            bound = true;
            try std.testing.expectEqualStrings(binding.sha256, page.sha256);
        }
    }
    try std.testing.expect(bound);
    try std.testing.expectEqualStrings("melee", action.family);
    try std.testing.expectEqualStrings("ready", action.status);
    try std.testing.expect(action.admission.complete());
    try std.testing.expectEqual(@as(usize, 9), action.required_animations.len);

    const medicine = try content.itemBySourceId(25);
    try std.testing.expectEqualStrings("medicine", medicine.id);
    try std.testing.expectEqualStrings("consumable", medicine.category);
    try std.testing.expectEqual(@as(u32, 100), medicine.price);
    try std.testing.expectEqual(@as(u8, 6), medicine.max_uses);
    try std.testing.expectEqualStrings("medicine", (try content.item("medicine")).id);

    const formation = try content.formation("area_a", "area_a.encounter.01");
    try std.testing.expectEqual(@as(u8, 1), formation.active);
    try std.testing.expectEqualStrings("area_a.enemy.01", formation.slots[0].enemy.?);
    try std.testing.expectEqual(@as(u8, 1), formation.slots[0].roster_id);

    const enemy = try content.enemy("area_a", "area_a.enemy.01");
    try std.testing.expectEqual(@as(u16, 18), enemy.hp);
    try std.testing.expectEqual(@as(?u16, 114), enemy.drops[0].item);
    try std.testing.expectEqual(@as(u16, 114), (try content.itemBySourceId(enemy.drops[0].item.?)).source_item_id);
    try std.testing.expectEqual(@as(u16, 114), (try content.dropItem(114)).id);

    // The whole reviewed compatible set joins; the four refused records do not.
    var joined: usize = 0;
    for (content.graph().characters) |entry| {
        if (content.action(entry.id)) |_| {
            joined += 1;
        } else |err| {
            try std.testing.expectEqual(content_graph_mod.Error.ActionNotAdmitted, err);
        }
    }
    try std.testing.expectEqual(@as(usize, 74), joined);
}

test "blocked records stay blocked with typed reasons" {
    var content = try open(std.testing.allocator);
    defer content.release();

    const humphrey = try content.evaluation("humphrey");
    try std.testing.expect(!humphrey.ready);
    try std.testing.expectEqualStrings("blocked", humphrey.residency_status);
    try std.testing.expectEqualStrings("mechanics_ready", humphrey.action_status);
    try std.testing.expect(humphrey.residency_blockers.len > 0);
    try std.testing.expect(!humphrey.admission.complete());
    try std.testing.expectError(error.ActionNotAdmitted, content.action("humphrey"));
    try std.testing.expectError(error.PoseNotResident, content.pose("humphrey", 8));

    const clive = try content.evaluation("clive");
    try std.testing.expect(!clive.ready);
    try std.testing.expectEqualStrings("blocked", clive.action_status);
    try std.testing.expectEqual(@as(usize, 4), clive.action_blockers.len);
    try std.testing.expectError(error.ActionNotAdmitted, content.action("clive"));

    var refused: usize = 0;
    for (content.graph().characters) |entry| {
        const evaluation = try content.evaluation(entry.id);
        if (!evaluation.ready) {
            refused += 1;
            try std.testing.expect(
                std.mem.eql(u8, entry.id, "humphrey") or
                    std.mem.eql(u8, entry.id, "kirke") or
                    std.mem.eql(u8, entry.id, "sonya") or
                    std.mem.eql(u8, entry.id, "clive"),
            );
        }
    }
    try std.testing.expectEqual(@as(usize, 4), refused);

    // Spell presentation is a typed dependency and is never defaulted.
    try std.testing.expectError(error.SpellPresentationUnavailable, content.spellPresentation());
    try std.testing.expectEqualStrings("unavailable", content.graph().spell_presentation.status);
    try std.testing.expectEqualStrings("presentation_correction_unavailable", content.graph().spell_presentation.code);
}

test "a different reviewed package set is refused at the consumer" {
    const allocator = std.testing.allocator;

    const foreign_residency = try replace(allocator, graph_bytes, "2599058d4581f3b5349027d16be34077460d4f2735558462ac893baea1cea38f", "2599058d4581f3b5349027d16be34077460d4f2735558462ac893baea1cea38e");
    defer allocator.free(foreign_residency);
    try std.testing.expectError(error.CrossVersionSubstitution, content_graph_mod.open(allocator, foreign_residency));

    const foreign_actions = try replace(allocator, graph_bytes, "9762265f75efcfdbb7b6db3c1aa9ae056a4462b380f851ca83513ae7624f218d", "9762265f75efcfdbb7b6db3c1aa9ae056a4462b380f851ca83513ae7624f218e");
    defer allocator.free(foreign_actions);
    try std.testing.expectError(error.CrossVersionSubstitution, content_graph_mod.open(allocator, foreign_actions));

    const foreign_item = try replaceAll(allocator, graph_bytes, "b23023b00e0e1aef", "b23023b00e0e1ae0");
    defer allocator.free(foreign_item);
    try std.testing.expectError(error.CrossVersionSubstitution, content_graph_mod.open(allocator, foreign_item));

    const inconsistent_item = try replace(allocator, graph_bytes, "b23023b00e0e1aef", "b23023b00e0e1ae0");
    defer allocator.free(inconsistent_item);
    try std.testing.expectError(error.InvalidDigest, content_graph_mod.open(allocator, inconsistent_item));

    const foreign_revision = try replace(allocator, graph_bytes, "content-graph.1", "content-graph.0");
    defer allocator.free(foreign_revision);
    try std.testing.expectError(error.InvalidRevision, content_graph_mod.open(allocator, foreign_revision));
}

test "tampered and malformed packets are refused" {
    const allocator = std.testing.allocator;

    // A page digest that no longer matches its action binding is refused by the
    // identity join before the digest layer even runs.
    const pages_at = std.mem.indexOf(u8, graph_bytes, "\"pages\": [").?;
    const sha_at = std.mem.indexOfPos(u8, graph_bytes, pages_at, "\"sha256\": \"").? + "\"sha256\": \"".len;
    const tampered_page = try flip(allocator, graph_bytes, sha_at);
    defer allocator.free(tampered_page);
    try std.testing.expectError(error.PageIdentityMismatch, content_graph_mod.open(allocator, tampered_page));

    // A tampered section digest is refused by the digest recomputation.
    const digest_at = std.mem.indexOf(u8, graph_bytes, "\"poses\": \"").? + "\"poses\": \"".len;
    const tampered_digest = try flip(allocator, graph_bytes, digest_at);
    defer allocator.free(tampered_digest);
    try std.testing.expectError(error.ContentDigestMismatch, content_graph_mod.open(allocator, tampered_digest));

    // A duplicated character id is refused even when the JSON is well formed.
    const duplicate = try replace(allocator, graph_bytes, "\"id\": \"kasumi\"", "\"id\": \"varkas\"");
    defer allocator.free(duplicate);
    try std.testing.expectError(error.DuplicateId, content_graph_mod.open(allocator, duplicate));

    const schema_at = std.mem.indexOf(u8, graph_bytes, "suikoden-campaign-content-graph/1").?;
    const wrong_schema = try flip(allocator, graph_bytes, schema_at);
    defer allocator.free(wrong_schema);
    try std.testing.expectError(error.InvalidSchema, content_graph_mod.open(allocator, wrong_schema));

    try std.testing.expect(std.meta.isError(content_graph_mod.open(allocator, graph_bytes[0 .. graph_bytes.len / 2])));
    try std.testing.expect(std.meta.isError(content_graph_mod.open(allocator, "{}")));
}

test "action statements bound to another residency revision cannot be joined" {
    const allocator = std.testing.allocator;

    // A page commitment that names another revision's page digest.
    {
        var copy = try parseCopy(allocator);
        defer copy.deinit();
        const character = findCharacter(&copy.value, "alen").*;
        var action = character.action.?;
        var pages = [_]content_graph_mod.schema.PageBinding{
            .{ .index = 0, .sha256 = "1111111111111111111111111111111111111111111111111111111111111111" },
        };
        action.pages = &pages;
        try std.testing.expectError(error.PageIdentityMismatch, content_graph_mod.verifyActionBinding(character, action));
    }
    // A pose piece that agrees with the resident pose but reaches a page the
    // action did not commit: the page binding itself refuses the join.
    {
        var copy = try parseCopy(allocator);
        defer copy.deinit();
        var character = findCharacter(&copy.value, "alen").*;
        var action = character.action.?;
        const real = action.poses[0];
        var pieces = [_]content_graph_mod.schema.Piece{real.pieces[0]};
        pieces[0].page = 99;
        var poses = [_]content_graph_mod.schema.Pose{.{
            .index = real.index,
            .width = real.width,
            .height = real.height,
            .anchor = real.anchor,
            .pieces = &pieces,
        }};
        character.poses = &poses;
        action.poses = &poses;
        try std.testing.expectError(error.PageIdentityMismatch, content_graph_mod.verifyActionBinding(character, action));
    }
    // A pose that disagrees with the resident pose is a cross-version join.
    {
        var copy = try parseCopy(allocator);
        defer copy.deinit();
        const character = findCharacter(&copy.value, "alen").*;
        var action = character.action.?;
        const real = action.poses[0];
        var pieces = [_]content_graph_mod.schema.Piece{real.pieces[0]};
        pieces[0].page = 0;
        var poses = [_]content_graph_mod.schema.Pose{.{
            .index = real.index,
            .width = real.width,
            .height = real.height,
            .anchor = real.anchor,
            .pieces = &pieces,
        }};
        action.poses = &poses;
        try std.testing.expectError(error.CrossVersionSubstitution, content_graph_mod.verifyActionBinding(character, action));
    }
    // A palette commitment with a different word count.
    {
        var copy = try parseCopy(allocator);
        defer copy.deinit();
        const character = findCharacter(&copy.value, "alen").*;
        var action = character.action.?;
        var palettes = [_]content_graph_mod.schema.PaletteBinding{
            .{ .index = 0, .words = 256, .sha256 = character.palettes[0].sha256 },
        };
        action.palettes = &palettes;
        try std.testing.expectError(error.PaletteIdentityMismatch, content_graph_mod.verifyActionBinding(character, action));
    }
    // Animation frames that disagree with the residency animation.
    {
        var copy = try parseCopy(allocator);
        defer copy.deinit();
        const character = findCharacter(&copy.value, "alen").*;
        var action = character.action.?;
        const real = action.animations[0];
        var frames = [_]content_graph_mod.schema.Frame{.{ .pose = real.frames[0].pose, .ticks = real.frames[0].ticks + 1 }};
        var animations = [_]content_graph_mod.schema.Animation{.{
            .index = real.index,
            .frames = &frames,
            .resolved = true,
            .missing_poses = &.{},
        }};
        action.animations = &animations;
        try std.testing.expectError(error.CrossVersionSubstitution, content_graph_mod.verifyActionBinding(character, action));
    }
    // The same issue on the resident side: a pose piece with a foreign palette.
    {
        var copy = try parseCopy(allocator);
        defer copy.deinit();
        var character = findCharacter(&copy.value, "alen").*;
        const real = character.poses[0];
        var pieces = [_]content_graph_mod.schema.Piece{real.pieces[0]};
        pieces[0].palette = 99;
        var poses = [_]content_graph_mod.schema.Pose{.{
            .index = real.index,
            .width = real.width,
            .height = real.height,
            .anchor = real.anchor,
            .pieces = &pieces,
        }};
        character.poses = &poses;
        try std.testing.expectError(error.PaletteIdentityMismatch, content_graph_mod.verifyPoseResidency(character, character.poses[0]));
    }
}

test "formation roster identity and foreign identities are refused" {
    const allocator = std.testing.allocator;
    var content = try open(allocator);
    defer content.release();

    try std.testing.expectError(error.UnknownFormation, content.formation("area_a", "area_b.encounter.01"));
    try std.testing.expectError(error.UnknownFormation, content.formation("area_a", "area_a.encounter.99"));
    try std.testing.expectError(error.UnknownArea, content.area("area_z"));
    try std.testing.expectError(error.UnknownItem, content.itemBySourceId(9999));
    try std.testing.expectError(error.UnknownItem, content.item("no_such_item"));
    try std.testing.expectError(error.UnknownPose, content.pose("alen", 999));
    try std.testing.expectError(error.UnknownCharacter, content.action("no_such_character"));

    // A formation whose slot roster index no longer names the referenced enemy.
    {
        var copy = try parseCopy(allocator);
        defer copy.deinit();
        const area = copy.value.areas[0];
        const real = area.formations[0];
        var slots: [6]content_graph_mod.schema.Slot = undefined;
        for (real.slots, 0..) |slot, index| slots[index] = slot;
        slots[0].roster_id = 2;
        const formation = content_graph_mod.schema.Formation{ .id = real.id, .active = real.active, .slots = &slots };
        try std.testing.expectError(error.FormationIdentityMismatch, content_graph_mod.verifyFormation(area, formation));
    }
    // A slot that carries an enemy without a roster identity.
    {
        var copy = try parseCopy(allocator);
        defer copy.deinit();
        const area = copy.value.areas[0];
        const real = area.formations[0];
        var slots: [6]content_graph_mod.schema.Slot = undefined;
        for (real.slots, 0..) |slot, index| slots[index] = slot;
        slots[1].enemy = "area_a.enemy.01";
        const formation = content_graph_mod.schema.Formation{ .id = real.id, .active = real.active, .slots = &slots };
        try std.testing.expectError(error.FormationIdentityMismatch, content_graph_mod.verifyFormation(area, formation));
    }
}

test "refused joins and full ledgers leave live state untouched" {
    const allocator = std.testing.allocator;
    var content = try open(allocator);
    defer content.release();
    var session = content_graph_mod.Session.init(content);
    defer session.deinit();

    try std.testing.expectEqual(@as(usize, 2), content.references());

    try session.selectCharacter("alen");
    var before = session.live;
    try std.testing.expectError(error.ActionNotAdmitted, session.selectCharacter("humphrey"));
    try std.testing.expect(before.eql(session.live));
    try std.testing.expectError(error.UnknownCharacter, session.selectCharacter("nobody"));
    try std.testing.expect(before.eql(session.live));

    try session.bindFormation("area_a", "area_a.encounter.01");
    before = session.live;
    try std.testing.expectError(error.UnknownFormation, session.bindFormation("area_a", "area_b.encounter.01"));
    try std.testing.expect(before.eql(session.live));

    try session.acquireItem(25, 6);
    before = session.live;
    try std.testing.expectError(error.UnknownItem, session.acquireItem(9999, 0));
    try std.testing.expect(before.eql(session.live));
    try std.testing.expectError(error.InvalidUses, session.acquireItem(25, 7));
    try std.testing.expect(before.eql(session.live));

    while (session.live.items[6] == null) try session.acquireItem(25, 6);
    before = session.live;
    try std.testing.expectError(error.LiveStateFull, session.acquireItem(26, 0));
    try std.testing.expect(before.eql(session.live));

    try std.testing.expectError(error.ActionNotAdmitted, session.selectCharacter("clive"));
    try std.testing.expect(before.eql(session.live));
}

test "parsed content survives a mode switch and a checkpoint restore" {
    const allocator = std.testing.allocator;
    var content = try open(allocator);
    defer content.release();
    try std.testing.expectEqual(@as(usize, 1), content.references());

    var session = content_graph_mod.Session.init(content);
    try session.selectCharacter("gremio");
    try session.bindFormation("area_c", "area_c.encounter.01");
    try session.acquireItem(25, 3);
    session.switchMode(.battle);
    try std.testing.expectEqual(content_graph_mod.schema.Mode.battle, session.live.mode);
    try std.testing.expectEqual(@as(usize, 2), content.references());

    const checkpoint = session.checkpoint();
    try std.testing.expectEqualStrings(content.exactDigest(), &checkpoint.graph_sha256);
    try std.testing.expect(checkpoint.live.eql(session.live));

    var restored = try content_graph_mod.restore(content, checkpoint);
    try std.testing.expectEqual(@as(usize, 3), content.references());
    try std.testing.expect(restored.live.eql(checkpoint.live));
    try std.testing.expectEqualStrings("gremio", restored.live.character.?.slice());
    try std.testing.expectEqualStrings("medicine", restored.live.items[0].?.id.slice());
    try std.testing.expectEqual(@as(u8, 3), restored.live.items[0].?.uses);
    try std.testing.expectEqualStrings("area_c", restored.live.area.?.slice());
    try std.testing.expectEqualStrings("medicine", (try content.item("medicine")).id);
    try std.testing.expectEqual(@as(u32, 0), (try content.pose("gremio", 0)).index);

    session.deinit();
    try std.testing.expectEqual(@as(usize, 2), content.references());
    try std.testing.expectEqual(@as(u16, 74), content.compatibleCount());

    var foreign_checkpoint = checkpoint;
    foreign_checkpoint.graph_sha256[0] = if (foreign_checkpoint.graph_sha256[0] == 'a') 'b' else 'a';
    try std.testing.expectError(error.CrossVersionSubstitution, content_graph_mod.restore(content, foreign_checkpoint));
    try std.testing.expectEqual(@as(usize, 2), content.references());

    var unknown_checkpoint = checkpoint;
    unknown_checkpoint.live.character = try content_graph_mod.schema.Name.init("nobody");
    try std.testing.expectError(error.UnknownCharacter, content_graph_mod.restore(content, unknown_checkpoint));
    try std.testing.expectEqual(@as(usize, 2), content.references());

    restored.deinit();
    try std.testing.expectEqual(@as(usize, 1), content.references());
}
