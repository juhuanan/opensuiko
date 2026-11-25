//! Focused gate: required actor pose/animation families beyond the base
//! party roots (party containers + the reviewed finite A-H enemy domain).
//!
//! Pure/port-level only: no original instruction executes, no emulator or
//! walker starts, no window or media opens, no image is rendered.  The generated
//! packet is read through its embedded `data.json`, so the packet identity and
//! the module cannot drift apart.
//!
//! Covered boundaries:
//!   * every supported binding of all 107 actors selects existing poses with a
//!     source anchor, resident page and in-range palette and a 1..256 duration;
//!   * blocked families (victory everywhere; missing pages/animations/roots)
//!     refuse with a stable reason and never fall back to a pose;
//!   * a missing pose, palette, page, anchor, duration, frame list, piece or
//!     binding is a typed load refusal, as is a tampered packet;
//!   * critical reuses the attack clips with reaction delay 36 and the camera
//!     gate; a static enemy attack settles immediately;
//!   * a stale content identity refuses begin and a capture from another
//!     identity refuses restore;
//!   * a capture taken after the first draw request but before the action
//!     settled, and a settled capture, both resume into a freshly parsed
//!     catalogue without replaying an emitted frame.

const std = @import("std");
const poses_mod = @import("combat_systems").poses;
const data = @import("combat_systems_data").pose_families;

const Family = poses_mod.Family;

fn load(allocator: std.mem.Allocator) !poses_mod.Catalogue {
    return poses_mod.Catalogue.load(allocator, data.json);
}

fn familyIndex(family: Family) usize {
    return @backingInt(family);
}

test "real packet: every supported family selects valid poses, pages, palettes, anchors and durations" {
    var catalogue = try load(std.testing.allocator);
    defer catalogue.deinit();
    try std.testing.expectEqualStrings(poses_mod.schema, catalogue.packet().schema);
    try std.testing.expectEqualStrings(data.content_sha256, catalogue.contentSha());

    var blocked: [8]u32 = @splat(0);
    var supported: [8]u32 = @splat(0);
    var actors: u32 = 0;
    var party: u32 = 0;
    var enemy: u32 = 0;
    var frames: u32 = 0;
    var static_bindings: u32 = 0;
    for (catalogue.packet().actors) |*actor| {
        actors += 1;
        switch (actor.side) {
            .party => party += 1,
            .enemy => enemy += 1,
        }
        for (actor.bindings) |*binding| {
            const slot = familyIndex(binding.family);
            if (binding.state == .blocked) {
                blocked[slot] += 1;
                const reason = binding.reason orelse return error.TestUnexpectedResult;
                try std.testing.expect(reason.len > 0);
                try std.testing.expectEqual(@as(usize, 0), binding.animations.len);
                continue;
            }
            supported[slot] += 1;
            if (binding.static_pose) {
                static_bindings += 1;
                try std.testing.expectEqual(@as(usize, 0), binding.animations.len);
                var static_session = try poses_mod.Session.begin(&catalogue, actor.id, binding.family);
                try std.testing.expect(static_session.isSettled());
                try std.testing.expect(static_session.draw() == null);
                try std.testing.expect(static_session.advance(5) == null);
                continue;
            }
            var session = try poses_mod.Session.begin(&catalogue, actor.id, binding.family);
            try std.testing.expect(!session.isSettled());
            try std.testing.expectEqual(@as(u16, 1), session.emittedFrames());
            var emissions: u32 = 0;
            var steps: u32 = 0;
            while (!session.isSettled()) : (steps += 1) {
                try std.testing.expect(steps < 20000);
                const draw = session.draw() orelse return error.TestUnexpectedResult;
                try std.testing.expect(draw.ticks > 0 and draw.ticks <= 256);
                try std.testing.expect(draw.elapsed < draw.ticks);
                const pose = actor.pose(draw.pose) orelse return error.TestUnexpectedResult;
                try std.testing.expect(pose.pieces.len > 0);
                try std.testing.expect(pose.anchor_x <= 255 and pose.anchor_y <= 255);
                for (pose.pieces) |piece| {
                    try std.testing.expect(actor.palette(piece.palette) != null);
                    try std.testing.expect(actor.page(piece.page) != null);
                    try std.testing.expectEqual(@as(u32, 0), piece.outside_samples);
                }
                if (session.advance(1) != null) emissions += 1;
            }
            try std.testing.expectEqual(session.frameCount(), session.emittedFrames());
            try std.testing.expectEqual(@as(u32, session.emittedFrames()), emissions + 1);
            frames += session.frameCount();
        }
    }
    try std.testing.expectEqual(@as(u32, 107), actors);
    try std.testing.expectEqual(@as(u32, 78), party);
    try std.testing.expectEqual(@as(u32, 29), enemy);
    try std.testing.expectEqualDeep([_]u32{ 107, 96, 107, 103, 107, 104, 96, 0 }, supported);
    try std.testing.expectEqualDeep([_]u32{ 0, 11, 0, 4, 0, 3, 11, 107 }, blocked);
    try std.testing.expectEqual(@as(u32, 4080), frames);
    try std.testing.expectEqual(@as(u32, 5), static_bindings);
}

test "blocked families refuse begin with the exported source reason" {
    var catalogue = try load(std.testing.allocator);
    defer catalogue.deinit();
    const cases = [_]struct { actor: []const u8, family: Family, reason: []const u8 }{
        .{ .actor = "hero", .family = .victory, .reason = "victory_pose_unproven" },
        .{ .actor = "clive", .family = .attack, .reason = "empty_animation" },
        .{ .actor = "humphrey", .family = .attack, .reason = "non_resident_piece" },
        .{ .actor = "humphrey", .family = .miss, .reason = "non_resident_piece" },
        .{ .actor = "lester", .family = .status_low_hp, .reason = "non_resident_piece" },
        .{ .actor = "area_a.enemy.01", .family = .status_low_hp, .reason = "empty_animation" },
        .{ .actor = "area_b.enemy.01", .family = .miss, .reason = "empty_animation" },
        .{ .actor = "area_g.enemy.03", .family = .attack, .reason = "missing_script_root" },
        .{ .actor = "area_h.enemy.01", .family = .attack, .reason = "missing_animation" },
    };
    for (cases) |case| {
        try std.testing.expectError(error.UnsupportedFamily, poses_mod.Session.begin(&catalogue, case.actor, case.family));
        const binding = catalogue.bindingFor(case.actor, case.family) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(case.reason, binding.reason.?);
    }
    try std.testing.expectError(error.UnknownActor, poses_mod.Session.begin(&catalogue, "not_an_actor", .idle));
}

test "critical reuses the attack clips with reaction delay 36 and the camera gate" {
    var catalogue = try load(std.testing.allocator);
    defer catalogue.deinit();
    for ([_][]const u8{ "hero", "gremio", "area_a.enemy.01" }) |id| {
        const actor = catalogue.actor(id) orelse return error.TestUnexpectedResult;
        const attack = actor.binding(.attack).?;
        const critical = actor.binding(.critical).?;
        if (attack.state == .blocked) {
            try std.testing.expectEqual(poses_mod.State.blocked, critical.state);
            continue;
        }
        try std.testing.expectEqualSlices(u16, attack.animations, critical.animations);
        try std.testing.expectEqual(@as(?u16, 36), critical.reaction_delay_ticks);
        try std.testing.expect(critical.camera_gate);
        var attack_session = try poses_mod.Session.begin(&catalogue, id, .attack);
        var critical_session = try poses_mod.Session.begin(&catalogue, id, .critical);
        var steps: u32 = 0;
        while (!attack_session.isSettled() and steps < 20000) : (steps += 1) {
            try std.testing.expectEqualDeep(attack_session.draw().?, critical_session.draw().?);
            const a = attack_session.advance(1);
            const c = critical_session.advance(1);
            try std.testing.expectEqual(a != null, c != null);
        }
        try std.testing.expect(critical_session.isSettled());
    }
}

test "a static enemy attack settles immediately and restarts" {
    var catalogue = try load(std.testing.allocator);
    defer catalogue.deinit();
    const binding = catalogue.bindingFor("area_a.enemy.01", .attack) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(poses_mod.State.supported, binding.state);
    try std.testing.expect(binding.static_pose);
    try std.testing.expectEqual(@as(usize, 0), binding.animations.len);
    var session = try poses_mod.Session.begin(&catalogue, "area_a.enemy.01", .attack);
    try std.testing.expect(session.isSettled());
    const cap = session.capture();
    var second = try load(std.testing.allocator);
    defer second.deinit();
    var restored = try poses_mod.Session.restore(&second, cap);
    try std.testing.expect(restored.isSettled());
    try std.testing.expectEqualDeep(cap, restored.capture());
}

test "a stale content identity refuses begin and a foreign capture refuses restore" {
    var catalogue = try load(std.testing.allocator);
    defer catalogue.deinit();
    const zeros = "0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expectError(error.StaleContent, poses_mod.Session.beginAt(&catalogue, "hero", .hurt, zeros));
    try std.testing.expectError(error.InvalidContentIdentity, poses_mod.Session.beginAt(&catalogue, "hero", .hurt, "short"));

    const ffff = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    const altered = try std.mem.replaceOwned(u8, std.testing.allocator, data.json, data.content_sha256, ffff);
    defer std.testing.allocator.free(altered);
    var other = try poses_mod.Catalogue.load(std.testing.allocator, altered);
    defer other.deinit();
    var session = try poses_mod.Session.begin(&catalogue, "hero", .hurt);
    const cap = session.capture();
    try std.testing.expectError(error.StaleCapture, poses_mod.Session.restore(&other, cap));
}

test "before-settle and settled captures survive a fresh catalogue parse without replay" {
    var first = try load(std.testing.allocator);
    defer first.deinit();

    // Step into a frame longer than one tick so the capture is genuinely
    // mid-frame: the draw for that frame was emitted, the motion has not
    // settled and elapsed is strictly inside the source duration.
    var session = try poses_mod.Session.begin(&first, "hero", .attack);
    var guard: u32 = 0;
    while (session.draw().?.elapsed == 0 and !session.isSettled() and guard < 1000) : (guard += 1) {
        _ = session.advance(1);
    }
    try std.testing.expect(!session.isSettled());
    try std.testing.expect(session.draw().?.elapsed > 0);
    const mid = session.capture();
    try std.testing.expect(!mid.settled);
    try std.testing.expect(mid.elapsed > 0);

    var second = try load(std.testing.allocator);
    defer second.deinit();
    var resumed = try poses_mod.Session.restore(&second, mid);
    try std.testing.expectEqual(mid.emitted, resumed.emittedFrames());
    try std.testing.expectEqualDeep(session.draw().?, resumed.draw().?);

    var steps: u32 = 0;
    while (!session.isSettled() and steps < 20000) : (steps += 1) {
        const a = session.advance(1);
        const b = resumed.advance(1);
        try std.testing.expectEqual(a != null, b != null);
        try std.testing.expectEqualDeep(session.draw().?, resumed.draw().?);
    }
    try std.testing.expect(resumed.isSettled());
    try std.testing.expectEqual(session.emittedFrames(), resumed.emittedFrames());

    const settled = resumed.capture();
    try std.testing.expect(settled.settled);
    var third = try load(std.testing.allocator);
    defer third.deinit();
    var settled_session = try poses_mod.Session.restore(&third, settled);
    try std.testing.expect(settled_session.isSettled());
    try std.testing.expect(settled_session.advance(9) == null);
    try std.testing.expectEqualDeep(settled, settled_session.capture());
    try std.testing.expectEqual(@as(u16, 0), settled_session.draw().?.remaining);
}

test "a tampered capture is refused" {
    var catalogue = try load(std.testing.allocator);
    defer catalogue.deinit();
    var session = try poses_mod.Session.begin(&catalogue, "hero", .hurt);
    var cap = session.capture();
    cap.frames[0].pose +%= 1;
    try std.testing.expectError(error.InvalidCapture, poses_mod.Session.restore(&catalogue, cap));
    var cap2 = session.capture();
    cap2.emitted = 0;
    try std.testing.expectError(error.InvalidCapture, poses_mod.Session.restore(&catalogue, cap2));
}

// ---------------------------------------------------------------------------
// Hand-authored fixture packets: each one is a valid catalogue with exactly one
// deliberate resource defect, so the refusal is the thing under test.
// ---------------------------------------------------------------------------

const FixtureOptions = struct {
    schema_text: []const u8 = poses_mod.schema,
    frame_pose: u16 = 0,
    ticks: u16 = 1,
    palette: u8 = 0,
    page: u8 = 0,
    outside: u32 = 0,
    anchor_x: u16 = 4,
    resolved: bool = true,
    include_idle: bool = true,
    pieces: bool = true,
    frames: bool = true,
    frame_count: u16 = 1,
    binding_animation: u16 = 0,
};

const FixtureBuilder = struct {
    buffer: []u8,
    len: usize = 0,

    fn write(self: *FixtureBuilder, text: []const u8) void {
        @memcpy(self.buffer[self.len .. self.len + text.len], text);
        self.len += text.len;
    }

    fn number(self: *FixtureBuilder, value: anytype) void {
        var scratch: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&scratch, "{d}", .{value}) catch unreachable;
        self.write(text);
    }

    fn slice(self: *const FixtureBuilder) []const u8 {
        return self.buffer[0..self.len];
    }
};

fn buildFixture(buffer: []u8, options: FixtureOptions) []const u8 {
    const zeros = "0000000000000000000000000000000000000000000000000000000000000000";
    var writer = FixtureBuilder{ .buffer = buffer };
    writer.write("{\"schema\":\"");
    writer.write(options.schema_text);
    writer.write("\",\"generated_by\":\"test fixture\",\"content_sha256\":\"");
    writer.write(zeros);
    writer.write("\",\"actors\":[{\"id\":\"fixture\",\"side\":\"party\",\"resource\":\"fixture\",\"resource_sha256\":\"");
    writer.write(zeros);
    writer.write("\",\"resource_status\":\"supported\",\"pages\":[{\"index\":0,\"slot\":0,\"sha256\":\"");
    writer.write(zeros);
    writer.write("\"}],\"palettes\":[{\"index\":0,\"words\":32,\"sha256\":\"");
    writer.write(zeros);
    writer.write("\"}],\"poses\":[{\"index\":0,\"width\":16,\"height\":16,\"anchor_x\":");
    writer.number(options.anchor_x);
    writer.write(",\"anchor_y\":8,\"pieces\":[");
    if (options.pieces) {
        writer.write("{\"x\":0,\"y\":0,\"page\":");
        writer.number(options.page);
        writer.write(",\"u\":0,\"v\":0,\"width\":16,\"height\":16,\"palette\":");
        writer.number(options.palette);
        writer.write(",\"flip_x\":false,\"flip_y\":false,\"outside_samples\":");
        writer.number(options.outside);
        writer.write("}");
    }
    writer.write("]}],\"animations\":[{\"index\":0,\"frames\":[");
    if (options.frames) {
        var frame: u16 = 0;
        while (frame < options.frame_count) : (frame += 1) {
            if (frame != 0) writer.write(",");
            writer.write("{\"pose\":");
            writer.number(options.frame_pose);
            writer.write(",\"ticks\":");
            writer.number(options.ticks);
            writer.write("}");
        }
    }
    writer.write("],\"resolved\":");
    writer.write(if (options.resolved) "true" else "false");
    writer.write("}],\"bindings\":[");
    var first = true;
    if (options.include_idle) {
        writer.write("{\"family\":\"idle\",\"state\":\"supported\",\"static_pose\":false,\"animations\":[");
        writer.number(options.binding_animation);
        writer.write("],\"auxiliary\":[],\"reaction_delay_ticks\":null,\"camera_gate\":false,\"reason\":null,\"detail\":null}");
        first = false;
    }
    const blocked = [_][]const u8{ "attack", "hurt", "miss", "down", "status_low_hp", "critical", "victory" };
    for (blocked) |name| {
        if (!first) writer.write(",");
        first = false;
        writer.write("{\"family\":\"");
        writer.write(name);
        writer.write("\",\"state\":\"blocked\",\"static_pose\":false,\"animations\":[],\"auxiliary\":[],\"reaction_delay_ticks\":null,\"camera_gate\":false,\"reason\":\"fixture_blocked\",\"detail\":null}");
    }
    writer.write("]}]}\n");
    return writer.slice();
}

fn loadFixture(options: FixtureOptions) !poses_mod.Catalogue {
    var buffer: [8192]u8 = undefined;
    const json = buildFixture(buffer[0..], options);
    return poses_mod.Catalogue.load(std.testing.allocator, json);
}

test "fixture packets refuse each resource defect" {
    try std.testing.expectError(error.MissingPose, loadFixture(.{ .frame_pose = 5 }));
    try std.testing.expectError(error.InvalidDuration, loadFixture(.{ .ticks = 0 }));
    try std.testing.expectError(error.InvalidDuration, loadFixture(.{ .ticks = 257 }));
    try std.testing.expectError(error.MissingPalette, loadFixture(.{ .palette = 3 }));
    try std.testing.expectError(error.MissingPage, loadFixture(.{ .page = 5 }));
    try std.testing.expectError(error.NonResidentPiece, loadFixture(.{ .outside = 1 }));
    try std.testing.expectError(error.InvalidAnchor, loadFixture(.{ .anchor_x = 300 }));
    try std.testing.expectError(error.EmptyPose, loadFixture(.{ .pieces = false }));
    try std.testing.expectError(error.EmptyAnimation, loadFixture(.{ .frames = false }));
    try std.testing.expectError(error.EmptyAnimation, loadFixture(.{ .resolved = false }));
    try std.testing.expectError(error.MissingBinding, loadFixture(.{ .include_idle = false }));
    try std.testing.expectError(error.UnsupportedSchema, loadFixture(.{ .schema_text = "bogus" }));
    try std.testing.expectError(error.MissingPose, loadFixture(.{ .binding_animation = 4 }));
    try std.testing.expectError(error.InvalidPacket, poses_mod.Catalogue.load(std.testing.allocator, "not json"));
}

test "a valid fixture admits one frame and settles" {
    var catalogue = try loadFixture(.{});
    defer catalogue.deinit();
    var session = try poses_mod.Session.begin(&catalogue, "fixture", .idle);
    try std.testing.expectEqual(@as(u16, 1), session.frameCount());
    try std.testing.expectEqual(@as(u16, 1), session.emittedFrames());
    try std.testing.expectEqual(@as(u16, 1), session.draw().?.remaining);
    try std.testing.expect(session.advance(1) == null);
    try std.testing.expect(session.isSettled());
    try std.testing.expectEqual(@as(u16, 1), session.emittedFrames());
}

test "a frame list longer than the restart bound refuses begin" {
    var catalogue = try loadFixture(.{ .frame_count = poses_mod.MAX_FRAMES + 1 });
    defer catalogue.deinit();
    try std.testing.expectError(error.TooManyFrames, poses_mod.Session.begin(&catalogue, "fixture", .idle));
}
