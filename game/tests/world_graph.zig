//! Focused port checks: the assembled content graph, its reference
//! rules, scene residency/rebinding and the canonical cue/actor/item queries.
//!
//! These are value-level checks on packaged content.  No original instruction is
//! executed, no image or audio is decoded and no window opens.

const std = @import("std");
const world_graph_mod = @import("world_graph");
const data = world_graph_mod;

const testing = std.testing;

fn loadHost(allocator: std.mem.Allocator) !*world_graph_mod.Host {
    return world_graph_mod.open(allocator);
}

test "world graph validates its pinned file and body digests" {
    const host = try loadHost(testing.allocator);
    defer host.deinit();
    const graph = host.graph;
    try testing.expectEqualStrings(world_graph_mod.body_sha256, graph.body_sha256);
    try testing.expectEqualStrings(world_graph_mod.revision, graph.revision);
    try testing.expectEqual(@as(usize, 9), graph.packs.len);
    try testing.expect(graph.counts.nodes > 2000);
    try testing.expect(graph.counts.edges > 800);
    try testing.expect(graph.counts.dangling == 0);
    try testing.expectEqual(@as(usize, data.counts.nodes), graph.nodes.len);
    try testing.expectEqual(@as(usize, data.counts.edges), graph.edges.len);
    try testing.expectEqual(@as(usize, data.counts.scenes), graph.scenes.len);
    try testing.expectEqual(@as(usize, data.counts.requests), graph.requests.len);
    try testing.expectEqual(@as(usize, data.counts.blockers), graph.blockers.len);
    try testing.expectEqual(@as(usize, data.counts.joins), graph.joins.len);
}

test "every version join the assembler recorded is verified" {
    const host = try loadHost(testing.allocator);
    defer host.deinit();
    for (host.graph.joins) |join| {
        try testing.expect(join.verified());
    }
}

test "mandatory scenes resolve usable geometry or state an exact blocker" {
    const host = try loadHost(testing.allocator);
    defer host.deinit();
    var blocked: usize = 0;
    for (host.graph.scenes) |scene| {
        if (!scene.mandatory) continue;
        const geometry = host.graph.geometry(scene.id) catch |err| {
            if (err != error.MandatoryGeometricUnresolved) return err;
            try testing.expect(scene.hasBlocker("mandatory-geometry-unresolved"));
            blocked += 1;
            continue;
        };
        if (geometry.status != .resolved) {
            try testing.expect(scene.blockers.len > 0);
            blocked += 1;
            continue;
        }
        try testing.expectEqual(world_graph_mod.graph.Status.qualified, geometry.room.status);
        try testing.expect(std.mem.startsWith(u8, geometry.room.id, "room:"));
    }
    // The assembler records these: vb2 rooms excluded by the dialogue text-root bound and
    // the blocked VS1 room.  They stay visible instead of being defaulted.
    try testing.expectEqual(@as(usize, 3), blocked);
}

test "canonical scenes admit their exact closure and release it" {
    const host = try loadHost(testing.allocator);
    defer host.deinit();
    var total: usize = 0;
    for (world_graph_mod.canonical_scenes) |scene_id| {
        try testing.expect(world_graph_mod.isCanonicalScene(scene_id));
        const selection = try host.admitScene(scene_id);
        const scene = try host.graph.requireScene(scene_id);
        try testing.expectEqual(scene.closure.len, @as(usize, @intCast(selection.closure_len)));
        try testing.expectEqual(@as(usize, scene.closure.len), host.residentCount());
        for (scene.closure) |member| try testing.expect(host.resident(member));
        try host.release(selection);
        try testing.expectEqual(@as(usize, 0), host.residentCount());
        total += selection.closure_len;
    }
    try testing.expect(total > 10);
}

test "a blocked scene and an unadmitted id are refused, not substituted" {
    const host = try loadHost(testing.allocator);
    defer host.deinit();
    // vb2_room13's source record exists but the dialogue text-root bound excludes it.
    try testing.expectError(error.SceneHasNoUsableGeometry, host.admitScene("vb2_room13"));
    try testing.expectError(error.SceneHasNoUsableGeometry, host.admitScene("vs1_room39"));
    try testing.expectError(error.UnknownScene, host.admitScene("no_such_room"));
    const scene = try host.graph.requireScene("vb6_room0");
    try testing.expect(scene.hasBlocker("resource-only-actor"));
    for (scene.blockers) |code| {
        var known = false;
        for (host.graph.blockers) |blocker| known = known or std.mem.eql(u8, blocker.code, code);
        try testing.expect(known or std.mem.eql(u8, code, "mandatory-geometry-unresolved"));
    }
}

test "a released selection is stale and cannot decrement another scene" {
    const host = try loadHost(testing.allocator);
    defer host.deinit();
    const first = try host.admitScene("vb6_room0");
    try host.release(first);
    try testing.expectError(error.StaleSelection, host.release(first));
    const second = try host.admitScene("vb6_room6");
    try testing.expectError(error.StaleSelection, host.release(first));
    try testing.expect(host.residentCount() > 0);
    try host.release(second);
}

test "snapshot round-trips and a changed revision or closure is refused" {
    const host = try loadHost(testing.allocator);
    defer host.deinit();
    const selection = try host.admitScene("vaa_room2");
    defer host.release(selection) catch {};
    const snapshot = try host.snapshot(selection);
    try testing.expectEqualStrings(world_graph_mod.revision, snapshot.revision);
    try testing.expectEqualStrings(world_graph_mod.body_sha256, snapshot.body_sha256);
    const restored = try host.restore(snapshot);
    try testing.expectEqualStrings(selection.closure_sha256, restored.closure_sha256);
    try host.release(restored);

    var other_revision = snapshot;
    other_revision.revision = "other-revision";
    try testing.expectError(error.ContentChanged, host.restore(other_revision));

    var other_body = snapshot;
    other_body.body_sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
    try testing.expectError(error.ContentChanged, host.restore(other_body));

    var other_closure = snapshot;
    other_closure.closure_sha256 = "1111111111111111111111111111111111111111111111111111111111111111";
    try testing.expectError(error.ContentChanged, host.restore(other_closure));

    var other_scene = snapshot;
    other_scene.scene = "no_such_room";
    try testing.expectError(error.UnknownScene, host.restore(other_scene));

    // A scene that exists but whose geometry is blocked is not a save target.
    var blocked_scene = snapshot;
    blocked_scene.scene = "vb2_room13";
    try testing.expectError(error.SceneHasNoUsableGeometry, host.restore(blocked_scene));
}

test "a substituted graph is refused by its file digest" {
    const allocator = testing.allocator;
    const mutated = try allocator.dupe(u8, world_graph_mod.content_json);
    defer allocator.free(mutated);
    // Flip one byte of the first node id: the file digest must no longer match.
    const marker = "scene:vaa_room2";
    const index = std.mem.indexOf(u8, mutated, marker) orelse return error.TestExpectedNode;
    mutated[index] = 'S';
    try testing.expectError(
        error.ContentFileDigestMismatch,
        world_graph_mod.Graph.load(allocator, mutated, world_graph_mod.file_sha256, world_graph_mod.body_sha256),
    );
}

test "a row edit that keeps the file digest cannot fake the body digest" {
    const allocator = testing.allocator;
    const mutated = try allocator.dupe(u8, world_graph_mod.content_json);
    defer allocator.free(mutated);
    // Change one node label but leave body_sha256 as generated: the graph still
    // decodes, so only the body digest can catch it.
    const marker = "Cleo|cid:1";
    const index = std.mem.indexOf(u8, mutated, marker) orelse return error.TestExpectedNode;
    mutated[index] = 'X';
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(mutated, &digest, .{});
    const file_sha = std.fmt.bytesToHex(digest, .lower);
    try testing.expectError(
        error.BodyDigestMismatch,
        world_graph_mod.Graph.load(allocator, mutated, &file_sha, world_graph_mod.body_sha256),
    );
}

test "actor identity keeps the three source spaces apart" {
    const host = try loadHost(testing.allocator);
    defer host.deinit();
    const hero = try host.graph.actorIdentity(8);
    try testing.expect(hero.record != null);
    try testing.expectEqual(@as(u32, 8), hero.record.?);
    try testing.expectEqual(@as(u32, 0), hero.portrait.?);
    try testing.expect(!hero.resourceOnly());

    const cleo = try host.graph.actorIdentity(1);
    try testing.expectEqualStrings("Cleo", cleo.name);
    try testing.expectEqual(@as(u32, 1), cleo.record.?);

    // A resource-only cid exists as an actor but has no display identity.
    var saw_resource_only = false;
    for (host.graph.nodes) |node| {
        if (node.kind != .actor) continue;
        const cid = world_graph_mod.graph.parseSuffix(node.id) orelse continue;
        const identity = try host.graph.actorIdentity(cid);
        if (identity.resourceOnly()) {
            saw_resource_only = true;
            try testing.expect(identity.record == null);
            try testing.expect(identity.portrait == null);
        }
    }
    try testing.expect(saw_resource_only);
    try testing.expectError(error.UnknownActor, host.graph.actorIdentity(9999));
}

test "weapon, item and formation references resolve from packaged content" {
    const host = try loadHost(testing.allocator);
    defer host.deinit();
    try testing.expectEqual(world_graph_mod.graph.Status.qualified, try host.graph.weaponStatus(1));
    // Weapon 79 is table-present but bound to no initial character.
    try testing.expectEqual(world_graph_mod.graph.Status.partial, try host.graph.weaponStatus(79));
    try testing.expectError(error.UnknownWeapon, host.graph.weaponStatus(9999));
    try testing.expectEqual(world_graph_mod.graph.Status.qualified, try host.graph.itemStatus(114));
    try testing.expectError(error.UnknownItem, host.graph.itemStatus(9999));

    var qualified_formations: usize = 0;
    var blocked_formations: usize = 0;
    for (host.graph.nodes) |node| {
        if (node.kind != .formation) continue;
        const id = node.id["formation:".len..];
        const formation = try host.graph.formationRef(id);
        if (formation.usable()) {
            qualified_formations += 1;
            try testing.expect(formation.enemies >= 1);
            try testing.expect(formation.enemies <= 6);
        } else {
            blocked_formations += 1;
            try testing.expect(formation.status != .qualified or formation.enemies == 0);
        }
    }
    try testing.expect(qualified_formations > 50);
    try testing.expect(blocked_formations > 0);
    try testing.expectError(error.UnknownFormation, host.graph.formationRef("no_such.formation"));
}

test "canonical cue commands resolve to packaged streams" {
    const host = try loadHost(testing.allocator);
    defer host.deinit();
    const live = try host.graph.resolveCue(0x422);
    try testing.expectEqual(world_graph_mod.graph.EdgeStatus.resolved, live.status);
    try testing.expectEqual(world_graph_mod.graph.Kind.stream, live.target_kind.?);
    try testing.expect(std.mem.endsWith(u8, live.target, "EV1.8"));

    const opening = try host.graph.resolveCue(0x404);
    try testing.expectEqual(world_graph_mod.graph.EdgeStatus.resolved, opening.status);
    try testing.expect(std.mem.endsWith(u8, opening.target, "SHIRO1.8"));
    const second = try host.graph.resolveCue(0x446);
    try testing.expectEqual(world_graph_mod.graph.EdgeStatus.resolved, second.status);

    try testing.expectError(error.UnknownCue, host.graph.resolveCue(0x9999));
    // An unresolved/excluded control command keeps its exact code.
    var coded: usize = 0;
    for (host.graph.requests) |request| {
        if (request.status != .resolved) {
            try testing.expect(request.code.len > 0);
            coded += 1;
        }
    }
    try testing.expect(coded > 0);
}

test "the runtime graph carries no source pointer or development-tree path" {
    const text = world_graph_mod.content_json;
    try testing.expect(std.mem.indexOf(u8, text, "\"0x80") == null);
    try testing.expect(std.mem.indexOf(u8, text, "/Users/") == null);
    try testing.expect(std.mem.indexOf(u8, text, "kit/work") == null);

    // Every external dependency stays visible with its exact code.
    for (data.packs) |pack| try testing.expect(pack.rows > 0);
    const host = try loadHost(testing.allocator);
    defer host.deinit();
    var external: usize = 0;
    for (host.graph.blockers) |blocker| {
        if (blocker.scope == .external) {
            external += 1;
            try testing.expect(blocker.code.len > 0);
        }
    }
    try testing.expect(external > 0);
}
