//! Focused tests: qualified ordinary party action adapter/consumer.
//!
//! No original instruction is executed, no emulator/interpreter is used, and no
//! rendering, audio or save behaviour is claimed.  The tests drive the owned
//! adapter with a hand-written host that stands in for the battle state.

const std = @import("std");
const party_actions_mod = @import("campaign_policies").party_actions;
const packet = party_actions_mod.actions;
const adapter = party_actions_mod.adapter;

const StepKind = enum { event, boundary, effect };

const Step = struct {
    update: u16,
    kind: StepKind,
    value: u16,
    amount: u32 = 0,
};

const Trace = struct {
    steps: [512]Step = undefined,
    count: usize = 0,

    fn add(self: *Trace, step: Step) void {
        if (self.count >= self.steps.len) return;
        self.steps[self.count] = step;
        self.count += 1;
    }

    fn boundaries(self: *const Trace, name: adapter.BoundaryName) usize {
        var total: usize = 0;
        for (self.steps[0..self.count]) |step| {
            if (step.kind == .boundary and step.value == @backingInt(name)) total += 1;
        }
        return total;
    }

    fn firstBoundary(self: *const Trace, name: adapter.BoundaryName) ?u16 {
        for (self.steps[0..self.count]) |step| {
            if (step.kind == .boundary and step.value == @backingInt(name)) return step.update;
        }
        return null;
    }

    fn effectsOf(self: *const Trace, kind: adapter.EffectKind) usize {
        var total: usize = 0;
        for (self.steps[0..self.count]) |step| {
            if (step.kind == .effect and step.value == @backingInt(kind)) total += 1;
        }
        return total;
    }

    fn firstEffect(self: *const Trace, kind: adapter.EffectKind) ?u16 {
        for (self.steps[0..self.count]) |step| {
            if (step.kind == .effect and step.value == @backingInt(kind)) return step.update;
        }
        return null;
    }

    fn eventCount(self: *const Trace) usize {
        var total: usize = 0;
        for (self.steps[0..self.count]) |step| {
            if (step.kind == .event) total += 1;
        }
        return total;
    }
};

const Mock = struct {
    hp: [12]u16 = @splat(100),
    dead: [12]bool = @splat(false),
    first_target: ?u32 = 6,
    draws: [8]u32 = .{ 11, 22, 33, 44, 55, 66, 77, 88 },
    draw_cursor: usize = 0,
    draw_attempts: usize = 0,
    committed_draws: usize = 0,
    fail_draw_at: ?usize = null,
    damage: u32 = 0,
    impact_update: u16 = 0,

    fn host(self: *Mock) adapter.Host {
        return .{
            .context = self,
            .target_alive = alive,
            .target_down = down,
            .first_available_target = firstTarget,
            .draw_impact_damage = drawDamage,
        };
    }

    fn alive(context: *anyopaque, target: u32) bool {
        const self: *Mock = @ptrCast(@alignCast(context));
        if (target >= self.hp.len) return false;
        return !self.dead[target] and self.hp[target] > 0;
    }

    fn down(context: *anyopaque, target: u32) bool {
        const self: *Mock = @ptrCast(@alignCast(context));
        if (target >= self.hp.len) return true;
        return self.dead[target] or self.hp[target] == 0;
    }

    fn firstTarget(context: *anyopaque, owner: usize) ?u32 {
        _ = owner;
        const self: *Mock = @ptrCast(@alignCast(context));
        return self.first_target;
    }

    fn drawDamage(context: *anyopaque, owner: usize, target: u32) anyerror!u32 {
        _ = owner;
        _ = target;
        const self: *Mock = @ptrCast(@alignCast(context));
        if (self.fail_draw_at) |at| {
            if (self.draw_attempts == at) {
                self.draw_attempts += 1;
                return error.RandomInputExhausted;
            }
        }
        self.draw_attempts += 1;
        const value = self.draws[self.draw_cursor % self.draws.len];
        self.draw_cursor += 1;
        self.committed_draws += 1;
        return value;
    }
};

fn load(allocator: std.mem.Allocator) !std.json.Parsed(packet.Content) {
    return packet.loadEmbedded(allocator);
}

fn recordOf(content: *const packet.Content, id: []const u8) *const packet.Record {
    const index = packet.lookup(content.*, id) catch unreachable;
    return &content.records[index];
}

fn countAdmitted(content: *const packet.Content) usize {
    var total: usize = 0;
    for (content.records) |record| {
        if (record.admitted) total += 1;
    }
    return total;
}

fn familyAdmitted(content: *const packet.Content, family: packet.Family) usize {
    var total: usize = 0;
    for (content.records) |record| {
        if (record.admitted and record.family == family) total += 1;
    }
    return total;
}

/// Run active actions to completion or `limit` updates, recording every dispatch.
fn run(set: *adapter.Set, content: *const packet.Content, host: adapter.Host, trace: *Trace, limit: usize) !usize {
    var updates: usize = 0;
    while (updates < limit) : (updates += 1) {
        var active = false;
        for (0..adapter.max_actions) |owner| {
            if (!set.available(owner)) active = true;
        }
        if (!active) break;
        const update = try set.advance(content, host);
        for (update.emissions) |emission| {
            if (emission.boundary) |name| {
                trace.add(.{ .update = emission.tick, .kind = .boundary, .value = @backingInt(name) });
            } else {
                trace.add(.{ .update = emission.tick, .kind = .event, .value = emission.event_index.? });
            }
        }
        for (update.effects) |effect| {
            trace.add(.{ .update = update.elapsed[effect.owner], .kind = .effect, .value = @backingInt(effect.kind) });
        }
    }
    return updates + 1;
}

fn hexZeros() []const u8 {
    return "0000000000000000000000000000000000000000000000000000000000000000";
}

test "packet identity, coverage and all 78 records validate" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const content = &parsed.value;
    try std.testing.expectEqual(@as(usize, 78), content.records.len);
    try std.testing.expectEqual(@as(usize, 74), countAdmitted(content));
    try std.testing.expectEqual(@as(u16, 78), content.coverage.compiled);
    try std.testing.expectEqual(@as(u16, 74), content.coverage.admitted);
    try std.testing.expectEqual(@as(usize, 56), familyAdmitted(content, .melee));
    try std.testing.expectEqual(@as(usize, 18), familyAdmitted(content, .stationary_auxiliary));
    try std.testing.expectEqual(@as(usize, 0), familyAdmitted(content, .ranged_sequence));
    try std.testing.expectEqual(@as(usize, 4), content.coverage.blocked.len);
    try std.testing.expectEqual(@as(usize, 74), content.coverage.admitted_ids.len);

    // The embeds are pinned to the exact bytes the report publishes.
    try packet.verifyAssetDigest(party_actions_mod.data.json);
    const forged = try std.testing.allocator.dupe(u8, party_actions_mod.data.json);
    defer std.testing.allocator.free(forged);
    forged[forged.len / 2] ^= 0x01;
    try std.testing.expectError(error.ContentMismatch, packet.verifyAssetDigest(forged));
    try std.testing.expectEqualStrings("cb07915d893a53fdeedd434248c5091854e7504f48472e518700b6f6f3a05efe", party_actions_mod.data.asset_sha256);
    try std.testing.expectEqualStrings("2599058d4581f3b5349027d16be34077460d4f2735558462ac893baea1cea38f", party_actions_mod.data.sprite_residency_manifest_sha256);
    try std.testing.expectEqualStrings("9762265f75efcfdbb7b6db3c1aa9ae056a4462b380f851ca83513ae7624f218d", party_actions_mod.data.party_actions_asset_sha256);
}

test "existing per-owner clocks and every named boundary are preserved" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const content = &parsed.value;
    const cases = [_]struct { id: []const u8, impact: u16, ready: u16, release: u16, delay: u16 }{
        .{ .id = "hero", .impact = 73, .ready = 97, .release = 129, .delay = 36 },
        .{ .id = "gremio", .impact = 65, .ready = 89, .release = 121, .delay = 36 },
        .{ .id = "pahn", .impact = 57, .ready = 96, .release = 128, .delay = 49 },
        .{ .id = "yam_koo", .impact = 74, .ready = 100, .release = 135, .delay = 36 },
        .{ .id = "tai_ho", .impact = 74, .ready = 100, .release = 135, .delay = 36 },
    };
    for (cases) |case| {
        const record = recordOf(content, case.id);
        try std.testing.expect(record.admitted);
        try std.testing.expectEqual(case.impact, record.boundaries.impact.?.ticks);
        try std.testing.expectEqual(case.ready, record.boundaries.owner_ready.?.ticks);
        try std.testing.expectEqual(case.release, record.boundaries.return_release.?.ticks);
        try std.testing.expectEqual(case.delay, record.reaction.delay_ticks.?);
        try std.testing.expectEqual(record.boundaries.impact.?.event_tick.? + 1, record.boundaries.impact.?.ticks);
        try std.testing.expectEqual(record.boundaries.owner_ready.?.event_tick.? + 1, record.boundaries.owner_ready.?.ticks);
        try std.testing.expectEqual(record.boundaries.impact.?.ticks + case.delay, record.boundaries.target_reaction.?.ticks);
    }
    for (content.records) |record| {
        if (!record.admitted) continue;
        try std.testing.expectEqual(record.boundaries.impact.?.event_tick.? + 1, record.boundaries.impact.?.ticks);
        try std.testing.expectEqual(record.boundaries.owner_ready.?.event_tick.? + 1, record.boundaries.owner_ready.?.ticks);
        try std.testing.expectEqual(record.reaction.delay_ticks.?, record.boundaries.target_reaction.?.delay_ticks.?);
        if (record.auxiliary != null) {
            try std.testing.expectEqual(record.boundaries.impact.?.ticks, record.boundaries.auxiliary_contact.?.ticks);
            try std.testing.expectEqual(record.auxiliary.?.spawn_tick, record.boundaries.auxiliary_spawn.?.ticks);
            try std.testing.expect(record.boundaries.auxiliary_spawn.?.ticks < record.boundaries.auxiliary_release.?.ticks);
        }
    }
}

test "typed admission refuses the three art gaps and Clive without defaults" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const content = &parsed.value;
    try adapter.admit(recordOf(content, "hero").*);
    try adapter.admit(recordOf(content, "cleo").*);
    try std.testing.expectError(error.ArtGap, adapter.admit(recordOf(content, "humphrey").*));
    try std.testing.expectError(error.ArtGap, adapter.admit(recordOf(content, "kirke").*));
    try std.testing.expectError(error.ArtGap, adapter.admit(recordOf(content, "sonya").*));
    try std.testing.expectError(error.ReactionUnresolved, adapter.admit(recordOf(content, "clive").*));

    const clive = recordOf(content, "clive");
    try std.testing.expect(!clive.admitted);
    try std.testing.expect(clive.blocker.?.kind == .reaction_unresolved);
    try std.testing.expectEqual(@as(?u16, null), clive.reaction.delay_ticks);
    try std.testing.expect(clive.boundaries.impact == null);
    try std.testing.expect(!clive.reaction.resolved);
    try std.testing.expect(std.mem.indexOfScalar(u16, clive.blocker.?.opcodes, 42) != null);
    try std.testing.expect(recordOf(content, "humphrey").blocker.?.poses.len == 1);
    try std.testing.expectEqual(@as(u16, 8), recordOf(content, "humphrey").blocker.?.poses[0]);
    try std.testing.expectEqual(@as(usize, 2), recordOf(content, "kirke").blocker.?.poses.len);

    var world: Mock = .{};
    var set = adapter.Set.init();
    var before_buffer: [128]u8 = @splat(0);
    const before = try encode(&set, &before_buffer);
    try std.testing.expectError(error.ReactionUnresolved, set.begin(content, world.host(), .{ .owner = 0, .id = "clive" }));
    try std.testing.expectError(error.ArtGap, set.begin(content, world.host(), .{ .owner = 0, .id = "sonya" }));
    try std.testing.expectError(error.UnknownRecord, set.begin(content, world.host(), .{ .owner = 0, .id = "missing" }));
    try std.testing.expectError(error.CommandNotEligible, set.begin(content, world.host(), .{ .owner = 0, .id = "hero", .eligible = false }));
    try std.testing.expectError(error.CommandNotEligible, set.begin(content, world.host(), .{ .owner = 0, .id = "hero", .awake = false }));
    try std.testing.expectError(error.CommandNotEligible, set.begin(content, world.host(), .{ .owner = 0, .id = "hero", .unbalanced = true }));
    var after_buffer: [128]u8 = @splat(0);
    const after = try encode(&set, &after_buffer);
    try std.testing.expectEqualStrings(before, after);
}

fn encode(set: *const adapter.Set, buffer: []u8) ![]const u8 {
    return set.encode(buffer);
}

test "forged packet flags, clocks and coverage are rejected" {
    const allocator = std.testing.allocator;

    {
        var parsed = try load(allocator);
        defer parsed.deinit();
        var content = parsed.value;
        const records = @constCast(content.records);
        const hero_index = try packet.lookup(content, "hero");
        records[hero_index].boundaries.impact.?.ticks += 1;
        try std.testing.expectError(error.InvalidBoundary, packet.validate(&content));
    }
    {
        var parsed = try load(allocator);
        defer parsed.deinit();
        var content = parsed.value;
        const records = @constCast(content.records);
        const clive_index = try packet.lookup(content, "clive");
        records[clive_index].reaction.resolved = true;
        try std.testing.expectError(error.FalseComplete, packet.validate(&content));
    }
    {
        var parsed = try load(allocator);
        defer parsed.deinit();
        var content = parsed.value;
        const records = @constCast(content.records);
        const hero_index = try packet.lookup(content, "hero");
        records[hero_index].residency.?.status = .blocked;
        try std.testing.expectError(error.FalseComplete, packet.validate(&content));
    }
    {
        var parsed = try load(allocator);
        defer parsed.deinit();
        var content = parsed.value;
        const records = @constCast(content.records);
        const hero_index = try packet.lookup(content, "hero");
        records[hero_index].admitted = false;
        try std.testing.expectError(error.FalseComplete, packet.validate(&content));
    }
    {
        var parsed = try load(allocator);
        defer parsed.deinit();
        var content = parsed.value;
        const records = @constCast(content.records);
        const humphrey_index = try packet.lookup(content, "humphrey");
        records[humphrey_index].blocker.?.kind = .reaction_unresolved;
        try std.testing.expectError(error.InvalidRecord, packet.validate(&content));
    }
    {
        var parsed = try load(allocator);
        defer parsed.deinit();
        var content = parsed.value;
        content.coverage.admitted = 73;
        try std.testing.expectError(error.InvalidCoverage, packet.validate(&content));
    }
    {
        var parsed = try load(allocator);
        defer parsed.deinit();
        var content = parsed.value;
        const records = @constCast(content.records);
        const hero_index = try packet.lookup(content, "hero");
        @constCast(records[hero_index].timeline)[0].ticks = 0;
        try std.testing.expectError(error.InvalidEventOperand, packet.validate(&content));
    }
}

test "strict parser rejects unknown fields, missing fields and unknown kinds" {
    const allocator = std.testing.allocator;
    const unknown_field = "{\"tick\":1,\"track\":\"attack\",\"kind\":\"timer\",\"consumer\":\"actor\",\"ticks\":1,\"bogus\":2}";
    try std.testing.expectError(error.UnknownField, std.json.parseFromSlice(packet.Event, allocator, unknown_field, .{}));
    const missing_field = "{\"tick\":1,\"track\":\"attack\",\"kind\":\"timer\"}";
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(packet.Event, allocator, missing_field, .{}));
    const unknown_kind = "{\"tick\":1,\"track\":\"attack\",\"kind\":\"teleport\",\"consumer\":\"actor\"}";
    try std.testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(packet.Event, allocator, unknown_kind, .{}));
    const ok = "{\"tick\":1,\"track\":\"attack\",\"kind\":\"timer\",\"consumer\":\"actor\",\"ticks\":2}";
    var parsed = try std.json.parseFromSlice(packet.Event, allocator, ok, .{});
    defer parsed.deinit();
    try packet.validateEvent(parsed.value);
}

test "hero runs one ordinary action on the source clock, one impact draw" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const content = &parsed.value;
    var world: Mock = .{};
    var set = adapter.Set.init();
    try set.begin(content, world.host(), .{ .owner = 0, .id = "hero", .target = 6 });

    var trace: Trace = .{};
    _ = try run(&set, content, world.host(), &trace, 220);
    const hero = recordOf(content, "hero");
    try std.testing.expectEqual(@as(u16, 73), trace.firstBoundary(.impact).?);
    try std.testing.expectEqual(@as(u16, 97), trace.firstBoundary(.owner_ready).?);
    try std.testing.expectEqual(@as(u16, 109), trace.firstBoundary(.target_reaction).?);
    try std.testing.expectEqual(@as(u16, 129), trace.firstBoundary(.return_release).?);
    try std.testing.expectEqual(@as(usize, 1), trace.effectsOf(.impact_damage));
    try std.testing.expectEqual(@as(?u16, 73), trace.firstEffect(.impact_damage));
    try std.testing.expectEqual(@as(?u16, 109), trace.firstEffect(.target_release));
    try std.testing.expectEqual(@as(?u16, 129), trace.firstEffect(.owner_release));
    try std.testing.expectEqual(@as(?u16, 142), trace.firstEffect(.action_complete));
    // every typed operand of the timeline is dispatched exactly once
    try std.testing.expectEqual(hero.timeline.len, trace.eventCount());
    try std.testing.expectEqual(@as(u32, 1), set.draws);
    try std.testing.expectEqual(@as(usize, 1), world.committed_draws);
    try std.testing.expect(set.available(0));
    try std.testing.expect(set.updates >= 142);
}

test "Cleo's stationary auxiliary family runs spawn, contact, release and reaction" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const content = &parsed.value;
    _ = try packet.lookup(content.*, "cleo");
    const cleo = recordOf(content, "cleo");
    try std.testing.expectEqual(packet.Family.stationary_auxiliary, cleo.family);
    try std.testing.expectEqual(@as(u16, 27), cleo.boundaries.auxiliary_spawn.?.ticks);
    try std.testing.expectEqual(@as(u16, 41), cleo.boundaries.impact.?.ticks);
    try std.testing.expectEqual(@as(u16, 41), cleo.boundaries.auxiliary_contact.?.ticks);
    try std.testing.expectEqual(@as(u16, 41), cleo.boundaries.auxiliary_release.?.ticks);
    try std.testing.expectEqual(@as(u16, 69), cleo.boundaries.target_reaction.?.ticks);
    try std.testing.expectEqual(@as(u16, 93), cleo.boundaries.owner_ready.?.ticks);
    try std.testing.expectEqual(@as(u16, 112), cleo.boundaries.return_release.?.ticks);

    var world: Mock = .{};
    var set = adapter.Set.init();
    try set.begin(content, world.host(), .{ .owner = 1, .id = "cleo", .target = 6 });
    var trace: Trace = .{};
    _ = try run(&set, content, world.host(), &trace, 220);

    try std.testing.expectEqual(@as(?u16, 27), trace.firstBoundary(.auxiliary_spawn));
    try std.testing.expectEqual(@as(?u16, 41), trace.firstBoundary(.impact));
    try std.testing.expectEqual(@as(?u16, 41), trace.firstBoundary(.auxiliary_contact));
    try std.testing.expectEqual(@as(?u16, 41), trace.firstBoundary(.auxiliary_release));
    try std.testing.expectEqual(@as(?u16, 69), trace.firstBoundary(.target_reaction));
    try std.testing.expectEqual(@as(?u16, 93), trace.firstBoundary(.owner_ready));
    try std.testing.expectEqual(@as(?u16, 112), trace.firstBoundary(.return_release));
    try std.testing.expectEqual(@as(?u16, 27), trace.firstEffect(.auxiliary_spawn));
    try std.testing.expectEqual(@as(?u16, 41), trace.firstEffect(.impact_damage));
    try std.testing.expectEqual(@as(?u16, 41), trace.firstEffect(.auxiliary_release));
    try std.testing.expectEqual(@as(?u16, 69), trace.firstEffect(.target_release));
    try std.testing.expectEqual(@as(?u16, 112), trace.firstEffect(.owner_release));
    try std.testing.expectEqual(@as(?u16, 112), trace.firstEffect(.action_complete));
    try std.testing.expectEqual(cleo.timeline.len, trace.eventCount());
    try std.testing.expectEqual(@as(u32, 1), set.draws);
}

test "all 18 stationary_auxiliary records are admitted and start" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const content = &parsed.value;
    var world: Mock = .{};
    var total: usize = 0;
    for (content.records) |record| {
        if (record.family != .stationary_auxiliary) continue;
        total += 1;
        try std.testing.expect(record.admitted);
        try adapter.admit(record);
        var set = adapter.Set.init();
        try set.begin(content, world.host(), .{ .owner = 2, .id = record.id, .target = 6 });
        const update = try set.advance(content, world.host());
        try std.testing.expect(update.emissions.len > 0);
        try std.testing.expect(update.emissions[0].tick >= 1);
    }
    try std.testing.expectEqual(@as(usize, 18), total);
}

test "hand-authored clocks and operands dispatch at the declared updates" {
    const frames = [_]packet.Frame{ .{ .pose = 0, .ticks = 2 }, .{ .pose = 1, .ticks = 3 } };
    const offset = packet.Vec{ .x = 40, .y = 0, .z = 0 };
    const delta = packet.Vec{ .x = 0, .y = 0, .z = -16 };
    const timeline = [_]packet.Event{
        .{ .tick = 1, .track = .attack, .kind = .timer, .consumer = .actor, .ticks = 2 },
        .{ .tick = 1, .track = .attack, .kind = .set_actor_flag, .consumer = .presentation, .mode = 0, .mask = 1 },
        .{ .tick = 2, .track = .attack, .kind = .motion_jump, .consumer = .actor, .mode = 2, .duration = 5, .offset = offset, .delta = delta },
        .{ .tick = 2, .track = .attack, .kind = .screen_offset, .consumer = .actor, .mode = 2, .x = 0, .y = 0 },
        .{ .tick = 4, .track = .attack, .kind = .set_action_mask, .consumer = .coordinator, .mode = 0, .mask = 2 },
        .{ .tick = 7, .track = .attack, .kind = .animation_request, .consumer = .presentation, .animation = 1, .duration = 5, .flag_byte = 1, .frames = &frames },
        .{ .tick = 8, .track = .attack, .kind = .set_action_mask, .consumer = .coordinator, .mode = 0, .mask = 4 },
        .{ .tick = 12, .track = .@"return", .kind = .clear_actor_flag, .consumer = .presentation, .mode = 0, .mask = 1 },
    };
    const required = [_]u16{1};
    const animations = [_]packet.ResidencyAnimation{.{ .index = 1, .frames = &frames }};
    const poses = [_]packet.Pose{};
    const pages = [_]packet.Page{};
    const palettes = [_]packet.Palette{};
    const admission_owned = [_]packet.CoordinatorOwned{ .target_selection, .hit, .damage, .target_reaction, .round };
    const residency = packet.Residency{
        .status = .supported,
        .binding_sha256 = hexZeros(),
        .required_animations = &required,
        .animations = &animations,
        .poses = &poses,
        .pages = &pages,
        .palettes = &palettes,
    };
    const record = packet.Record{
        .id = "handtest",
        .family = .melee,
        .source_status = .ready,
        .admitted = true,
        .resource = "TEST.BIN",
        .resource_sha256 = hexZeros(),
        .evidence_sha256 = hexZeros(),
        .timeline_complete = true,
        .reaction = .{ .script_slot = 2, .delay_ticks = 3, .resolved = true, .release = .actor_flag_clear },
        .auxiliary = null,
        .audio_cues = &.{},
        .timeline = &timeline,
        .boundaries = .{
            .initial_command = .{ .from = .dispatch, .ticks = 0, .event_tick = 0, .consumer = .actor, .consumer_delay = 0 },
            .impact = .{ .from = .dispatch, .ticks = 5, .event_tick = 4, .consumer = .coordinator, .consumer_delay = 1, .trigger = .action_mask, .mask = 2, .track = .attack },
            .owner_ready = .{ .from = .dispatch, .ticks = 9, .event_tick = 8, .consumer = .coordinator, .consumer_delay = 1, .trigger = .action_mask, .mask = 4, .track = .attack },
            .return_release = .{ .from = .dispatch, .ticks = 12, .event_tick = 12, .consumer = .presentation, .consumer_delay = 0, .trigger = .actor_flag_clear, .mask = 1 },
            .target_reaction = .{ .from = .impact, .ticks = 8, .consumer = .coordinator, .consumer_delay = 0, .delay_ticks = 3 },
        },
        .admission = .{ .mechanics_complete = true, .reaction_resolved = true, .residency_qualified = true, .coordinator_owned = &admission_owned },
        .blocker = null,
        .residency = residency,
        .source_blockers = &.{},
    };

    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    var content = parsed.value;
    @constCast(content.records)[0] = record;
    var world: Mock = .{};
    var set = adapter.Set.init();
    try set.beginRecord(world.host(), .{ .owner = 0, .id = "handtest", .target = 6 }, 0, record);
    var trace: Trace = .{};
    _ = try run(&set, &content, world.host(), &trace, 40);
    // Impact is the mask2 write observed one update later; owner-ready is the
    // mask4 write observed one update later; the reaction is impact+delay.
    try std.testing.expectEqual(@as(u16, 5), trace.firstBoundary(.impact).?);
    try std.testing.expectEqual(@as(u16, 9), trace.firstBoundary(.owner_ready).?);
    try std.testing.expectEqual(@as(u16, 8), trace.firstBoundary(.target_reaction).?);
    try std.testing.expectEqual(@as(u16, 12), trace.firstBoundary(.return_release).?);
    try std.testing.expectEqual(@as(u16, 5), trace.firstEffect(.impact_damage).?);
    try std.testing.expectEqual(@as(u16, 12), trace.firstEffect(.action_complete).?);
    try std.testing.expectEqual(timeline.len, trace.eventCount());
    try std.testing.expectEqual(@as(u32, 1), set.draws);

    var forged = record;
    const bad_timeline = [_]packet.Event{.{ .tick = 1, .track = .attack, .kind = .timer, .consumer = .actor }};
    forged.timeline = &bad_timeline;
    try std.testing.expectError(error.InvalidTimeline, set.beginRecord(world.host(), .{ .owner = 1, .id = "handtest", .target = 6 }, 1, forged));
}

test "no target, dead target retarget and KO before impact are typed boundaries" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const content = &parsed.value;

    // preferred target dead -> caller retarget policy
    var world: Mock = .{ .first_target = 7 };
    world.dead[6] = true;
    var set = adapter.Set.init();
    try set.begin(content, world.host(), .{ .owner = 0, .id = "hero", .target = 6 });
    try std.testing.expectEqual(@as(u32, 7), set.actionOf(0).?.target);

    // no living target at all -> typed refusal, unchanged state
    var empty: Mock = .{ .first_target = null };
    var empty_set = adapter.Set.init();
    var before: [128]u8 = undefined;
    const encoded_before = try empty_set.encode(&before);
    try std.testing.expectError(error.NoTarget, empty_set.begin(content, empty.host(), .{ .owner = 0, .id = "hero", .target = null }));
    var after: [128]u8 = undefined;
    try std.testing.expectEqualStrings(encoded_before, try empty_set.encode(&after));

    // target dies before the impact observation: no draw, target_missing, and
    // the reaction release still lands on its named boundary.
    var ko: Mock = .{};
    var ko_set = adapter.Set.init();
    try ko_set.begin(content, ko.host(), .{ .owner = 0, .id = "hero", .target = 6 });
    var trace: Trace = .{};
    var updates: usize = 0;
    while (updates < 200) : (updates += 1) {
        if (updates == 72) ko.dead[6] = true; // 0-based loop index 72 -> update 73
        const update = try ko_set.advance(content, ko.host());
        for (update.emissions) |emission| {
            if (emission.boundary) |name| trace.add(.{ .update = emission.tick, .kind = .boundary, .value = @backingInt(name) });
        }
        for (update.effects) |effect| trace.add(.{ .update = update.elapsed[effect.owner], .kind = .effect, .value = @backingInt(effect.kind) });
        if (ko_set.available(0)) break;
    }
    try std.testing.expectEqual(@as(?u16, 73), trace.firstBoundary(.impact));
    try std.testing.expectEqual(@as(usize, 0), trace.effectsOf(.impact_damage));
    try std.testing.expectEqual(@as(usize, 1), trace.effectsOf(.target_missing));
    try std.testing.expectEqual(@as(?u16, 109), trace.firstEffect(.target_down));
    try std.testing.expectEqual(@as(u32, 0), ko_set.draws);
}

test "overlap and a later failed impact roll back the entire update" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const content = &parsed.value;
    var world: Mock = .{};
    var set = adapter.Set.init();
    // alen and flik share impact update 71; owner order is the draw order.
    try set.begin(content, world.host(), .{ .owner = 0, .id = "alen", .target = 6 });
    try set.begin(content, world.host(), .{ .owner = 1, .id = "flik", .target = 6 });

    // Advance to the update before the shared impact observation (71), snapshot,
    // then inject the later-draw failure in that single update.
    while (set.updates < 70) _ = try set.advance(content, world.host());
    var before: [128]u8 = undefined;
    const encoded = try set.encode(&before);
    world.draw_attempts = 0;
    world.fail_draw_at = 1; // owner 0's draw succeeds, owner 1's later draw fails
    try std.testing.expectError(error.RandomInputExhausted, set.advance(content, world.host()));
    var after: [128]u8 = undefined;
    try std.testing.expectEqualStrings(encoded, try set.encode(&after));
    try std.testing.expectEqual(@as(u32, 0), set.draws);

    world.fail_draw_at = null;
    var trace: Trace = .{};
    _ = try run(&set, content, world.host(), &trace, 200);
    // Both actions applied on their shared impact update, owner order, two draws.
    try std.testing.expectEqual(@as(usize, 2), trace.effectsOf(.impact_damage));
    try std.testing.expectEqual(@as(u32, 2), set.draws);
    var first_impact: ?u16 = null;
    var second: ?u16 = null;
    for (trace.steps[0..trace.count]) |step| {
        if (step.kind == .effect and step.value == @backingInt(adapter.EffectKind.impact_damage)) {
            if (first_impact == null) first_impact = step.update else second = step.update;
        }
    }
    try std.testing.expectEqual(@as(?u16, 71), first_impact);
    try std.testing.expectEqual(@as(?u16, 71), second);
}

test "same-target overlap: the later action sees the KO without a second draw" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const content = &parsed.value;
    var world: Mock = .{};
    var set = adapter.Set.init();
    // Gremio (impact 65) and Hero (impact 73) both choose enemy 6.
    try set.begin(content, world.host(), .{ .owner = 1, .id = "gremio", .target = 6 });
    try set.begin(content, world.host(), .{ .owner = 0, .id = "hero", .target = 6 });
    // One ordinary action per owner; a second action for a busy owner is refused.
    var snapshot: [128]u8 = undefined;
    const encoded = try set.encode(&snapshot);
    try std.testing.expectError(error.OwnerBusy, set.begin(content, world.host(), .{ .owner = 1, .id = "gremio", .target = 6 }));
    var after: [128]u8 = undefined;
    try std.testing.expectEqualStrings(encoded, try set.encode(&after));

    var trace: Trace = .{};
    var updates: usize = 0;
    while (updates < 220) : (updates += 1) {
        var active = false;
        for (0..adapter.max_actions) |owner| if (!set.available(owner)) {
            active = true;
        };
        if (!active) break;
        const update = try set.advance(content, world.host());
        for (update.effects) |effect| {
            if (effect.kind == .impact_damage and effect.target == 6) world.hp[6] = 0;
            trace.add(.{ .update = update.elapsed[effect.owner], .kind = .effect, .value = @backingInt(effect.kind) });
        }
    }
    try std.testing.expectEqual(@as(usize, 1), trace.effectsOf(.impact_damage));
    try std.testing.expectEqual(@as(usize, 1), trace.effectsOf(.target_missing));
    try std.testing.expectEqual(@as(u32, 1), set.draws);
}

test "serialized mid-action continuation reproduces the identical future" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const content = &parsed.value;

    var baseline_world: Mock = .{};
    var baseline = adapter.Set.init();
    try baseline.begin(content, baseline_world.host(), .{ .owner = 1, .id = "cleo", .target = 6 });
    var prefix: Trace = .{};
    _ = try run(&baseline, content, baseline_world.host(), &prefix, 50);
    var cursor_buffer: [512]u8 = undefined;
    const saved = try baseline.encode(&cursor_buffer);
    const cursor_record = baseline.cursorOf(1).?;
    var suffix: Trace = .{};
    _ = try run(&baseline, content, baseline_world.host(), &suffix, 220);

    var resumed_world: Mock = .{};
    var resumed = adapter.Set.init();
    try resumed.begin(content, resumed_world.host(), .{ .owner = 1, .id = "cleo", .target = 6 });
    var resumed_prefix: Trace = .{};
    _ = try run(&resumed, content, resumed_world.host(), &resumed_prefix, 50);
    try resumed.decode(content, saved);
    var resumed_suffix: Trace = .{};
    _ = try run(&resumed, content, resumed_world.host(), &resumed_suffix, 220);

    try std.testing.expectEqual(suffix.count, resumed_suffix.count);
    for (suffix.steps[0..suffix.count], resumed_suffix.steps[0..resumed_suffix.count]) |left, right| {
        try std.testing.expectEqual(left.update, right.update);
        try std.testing.expectEqual(@backingInt(left.kind), @backingInt(right.kind));
        try std.testing.expectEqual(left.value, right.value);
    }
    // The JSON/check-point shape restores the same continuation from the small
    // cursor record rather than the text form.
    var restored = adapter.Set.init();
    try restored.restoreCursor(content, cursor_record);
    var restored_suffix2: Trace = .{};
    _ = try run(&restored, content, resumed_world.host(), &restored_suffix2, 220);
    try std.testing.expectEqual(suffix.count, restored_suffix2.count);
    for (suffix.steps[0..suffix.count], restored_suffix2.steps[0..restored_suffix2.count]) |left, right| {
        try std.testing.expectEqual(left.update, right.update);
        try std.testing.expectEqual(@backingInt(left.kind), @backingInt(right.kind));
        try std.testing.expectEqual(left.value, right.value);
    }
    var forged_record = cursor_record;
    forged_record.schedule_len += 1;
    try std.testing.expectError(error.InvalidSerializedState, restored.restoreCursor(content, forged_record));
    // A forged text continuation is refused without changing the set.
    try std.testing.expectError(error.InvalidSerializedState, resumed.decode(content, "v1|1,0,6,50,99,46,0"));
    try std.testing.expectError(error.InvalidSerializedState, resumed.decode(content, "v9"));
}

test "same-source residency sampling is scoped to executable records" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const content = &parsed.value;
    const cleo = recordOf(content, "cleo");
    const frames = try packet.animationFrames(cleo.*, 17);
    try std.testing.expect(frames.len > 0);
    const plan = try packet.samplingPlan(cleo.*, frames[0].pose, 0);
    try std.testing.expect(plan.width > 0 and plan.height > 0);
    try std.testing.expect(plan.u >= 0 and plan.v >= 0);
    try std.testing.expectError(error.RecordBlocked, packet.samplingPlan(recordOf(content, "clive").*, 0, 0));
    try std.testing.expectError(error.RecordBlocked, packet.samplingPlan(recordOf(content, "humphrey").*, 0, 0));
    try std.testing.expectError(error.UnknownAnimation, packet.animationFrames(cleo.*, 200));
}
