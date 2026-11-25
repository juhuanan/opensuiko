//! Focused gate: ordinary movement encounter eligibility, rate and
//! picker through the owned adapter.
//!
//! The domain packet and every expected value are produced by the independent
//! Python reference in the extraction pipeline; this gate replays them
//! against the Zig adapter.  No original instruction is executed.

const std = @import("std");
const encounter = @import("campaign_policies").encounter;
const data = @import("campaign_policies_data").encounter_domains;

const allocator = std.testing.allocator;

const DomainCandidate = struct {
    id: []const u8,
    enemy_level_sum: u16,
    index: u16 = 0,
    active: u32 = 0,
    roster: []const u8 = &.{},
    source_address: []const u8 = "",
    runtime_encounter_id: ?[]const u8 = null,
};

const Domain = struct {
    id: []const u8,
    source_file: []const u8,
    source_sha256: []const u8,
    rate: ?u8,
    counter_threshold: ?u16,
    rate_policy: []const u8,
    rate_blocker: ?struct { code: []const u8, detail: []const u8 } = null,
    candidate_count: usize,
    candidates: []const DomainCandidate,
};

const Packet = struct {
    schema: []const u8,
    domains: []const Domain,
    runtime_bindings: []const struct {
        region: []const u8,
        candidate_domain: []const u8,
        rate_domain: ?[]const u8,
        rate: ?u8,
        counter_threshold: ?u16,
        status: []const u8,
    },
};

const SourceRate = struct { rate: u8, counter_threshold: u16 };

const EligibilityCase = struct {
    name: []const u8,
    eligibility: encounter.Eligibility,
    rate: ?SourceRate = null,
    candidate_count: usize,
    blocker: ?[]const u8 = null,
    draws_used: usize = 0,
    cursor: usize = 0,
};

const RateCase = struct { draw: u15, roll: u8, rate: u8, passes: bool };
const PickCase = struct { count: u16, divisor: u16, draw: u15, index: u16 };
const RuneCase = struct {
    candidate: []const u8,
    enemy_level_sum: u16,
    party_level_sum: u16,
    suppression_rune: bool,
    enemy_level_scaled: u16,
    rejected: bool,
};

const VectorCandidate = struct { id: []const u8, enemy_level_sum: u16 };

const Expect = struct {
    outcome: []const u8,
    blocker: ?[]const u8 = null,
    candidate: ?[]const u8 = null,
    index: ?u16 = null,
    cursor: usize,
    draws_used: usize,
    rate_draw: ?u15 = null,
    rate_roll: ?u8 = null,
    pick_draw: ?u15 = null,
    enemy_level_scaled: ?u16 = null,
};

const WalkCase = struct {
    name: []const u8,
    eligibility: encounter.Eligibility,
    party: encounter.Party,
    rate: ?SourceRate,
    candidates: []const VectorCandidate,
    values: []const u15,
    cursor: usize = 0,
    expect: Expect,
};

const Request = struct {
    candidates: []const VectorCandidate,
    party_level_sum: u16,
    suppression_rune: bool,
    rate: u8,
    counter_threshold: u16,
    travel_counter: u16,
    cursor: usize,
    values: []const u15,
};

const ContinueCase = struct {
    name: []const u8,
    request: Request,
    expect: Expect,
};

const Vectors = struct {
    schema: []const u8,
    eligibility: []const EligibilityCase,
    rate: []const RateCase,
    pick: []const PickCase,
    rune: []const RuneCase,
    walks: []const WalkCase,
    continuation: []const ContinueCase,
};

fn ratePolicy(rate: ?SourceRate) encounter.RatePolicy {
    return if (rate) |source| .{ .source = .{ .rate = source.rate, .counter_threshold = source.counter_threshold } } else .{ .blocked = .rate_unavailable };
}

fn blockerFromName(name: []const u8) encounter.Blocker {
    return std.meta.stringToEnum(encounter.Blocker, name) orelse @panic("unknown blocker in vector");
}

fn expectOutcome(outcome: encounter.Outcome, expect: Expect, candidates: []const encounter.Candidate) !void {
    switch (outcome) {
        .blocked => |blocker| {
            try std.testing.expectEqualStrings("blocked", expect.outcome);
            try std.testing.expectEqualStrings(expect.blocker.?, @tagName(blocker));
            try std.testing.expectEqual(@as(usize, 0), expect.draws_used);
        },
        .rate_failed => |progress| {
            try std.testing.expectEqualStrings("rate_failed", expect.outcome);
            try std.testing.expectEqual(expect.cursor, progress.draws.cursor);
            try std.testing.expectEqual(@as(usize, 1), expect.draws_used);
            try std.testing.expectEqual(expect.rate_draw.?, progress.rate_draw);
            try std.testing.expectEqual(expect.rate_roll.?, progress.rate_roll);
        },
        .rejected => |rejection| {
            try std.testing.expectEqualStrings("rejected", expect.outcome);
            try std.testing.expectEqual(expect.cursor, rejection.progress.draws.cursor);
            try std.testing.expectEqual(@as(usize, 2), expect.draws_used);
            try std.testing.expectEqualStrings(expect.candidate.?, rejection.candidate.id);
            try std.testing.expectEqual(expect.index.?, rejection.index);
            try std.testing.expectEqual(expect.pick_draw.?, rejection.progress.pick_draw.?);
            try std.testing.expectEqual(expect.enemy_level_scaled.?, rejection.progress.enemy_level_scaled);
            try std.testing.expect(!std.mem.eql(u8, candidates[rejection.index - 1].id, ""));
        },
        .selected => |selection| {
            try std.testing.expectEqualStrings("selected", expect.outcome);
            try std.testing.expectEqual(expect.cursor, selection.progress.draws.cursor);
            try std.testing.expectEqual(@as(usize, 2), expect.draws_used);
            try std.testing.expectEqualStrings(expect.candidate.?, selection.candidate.id);
            try std.testing.expectEqual(expect.index.?, selection.index);
            try std.testing.expectEqual(expect.pick_draw.?, selection.progress.pick_draw.?);
            try std.testing.expectEqual(expect.enemy_level_scaled.?, selection.progress.enemy_level_scaled);
        },
    }
}

fn buildCandidates(buffer: []encounter.Candidate, rows: []const VectorCandidate) []encounter.Candidate {
    for (rows, 0..) |row, index| buffer[index] = .{ .id = row.id, .enemy_level_sum = row.enemy_level_sum };
    return buffer[0..rows.len];
}

test "domain packet exposes two complete movement domains and eight blocked data domains" {
    const packet = try std.json.parseFromSlice(Packet, allocator, data.domains_json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer packet.deinit();
    try std.testing.expectEqualStrings("suikoden-encounter-domains/1", packet.value.schema);
    try std.testing.expectEqual(@as(usize, 10), packet.value.domains.len);
    var candidates: usize = 0;
    var complete: usize = 0;
    for (packet.value.domains) |domain| {
        try std.testing.expect(domain.candidates.len == domain.candidate_count);
        candidates += domain.candidates.len;
        if (std.mem.eql(u8, domain.rate_policy, "source")) {
            complete += 1;
            try std.testing.expect(domain.rate != null);
            try std.testing.expect(domain.counter_threshold != null);
        } else {
            try std.testing.expect(domain.rate == null);
            try std.testing.expect(domain.rate_blocker != null);
        }
    }
    try std.testing.expectEqual(@as(usize, 93), candidates);
    try std.testing.expectEqual(@as(usize, 2), complete);
    try std.testing.expectEqual(@as(usize, 2), packet.value.runtime_bindings.len);
    var saw_b = false;
    var saw_c_blocked = false;
    for (packet.value.runtime_bindings) |binding| {
        if (std.mem.eql(u8, binding.region, "region_b")) {
            saw_b = true;
            try std.testing.expectEqual(@as(u8, 2), binding.rate.?);
            try std.testing.expectEqual(@as(u16, 60), binding.counter_threshold.?);
        }
        if (std.mem.eql(u8, binding.region, "region_c")) saw_c_blocked = std.mem.eql(u8, binding.status, "blocked");
    }
    try std.testing.expect(saw_b and saw_c_blocked);
}

test "eligibility is decided before any draw" {
    const vectors = try std.json.parseFromSlice(Vectors, allocator, data.vectors_json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer vectors.deinit();
    var buffer: [64]encounter.Candidate = undefined;
    var values = [_]u15{ 0, 0 };
    for (vectors.value.eligibility) |case| {
        const candidates = buffer[0..case.candidate_count];
        for (candidates, 0..) |*candidate, index| candidate.* = .{ .id = "dummy", .enemy_level_sum = @intCast(index) };
        const draws = encounter.draws{ .values = &values, .cursor = 0 };
        const outcome = try encounter.attempt(case.eligibility, .{ .level_sum = 0 }, ratePolicy(case.rate), candidates, draws);
        if (case.blocker) |blocker| {
            switch (outcome) {
                .blocked => |actual| try std.testing.expectEqualStrings(blocker, @tagName(actual)),
                else => return error.ExpectedBlocked,
            }
            try std.testing.expectEqual(case.cursor, draws.cursor);
        } else {
            try std.testing.expect(outcome != .blocked);
        }
    }
}

test "rate helper, picker and rune vectors" {
    const vectors = try std.json.parseFromSlice(Vectors, allocator, data.vectors_json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer vectors.deinit();
    for (vectors.value.rate) |case| {
        try std.testing.expectEqual(case.roll, encounter.rateRoll(case.draw));
        try std.testing.expectEqual(case.passes, encounter.rateRoll(case.draw) < case.rate);
    }
    for (vectors.value.pick) |case| {
        try std.testing.expectEqual(case.index, try encounter.pickIndex(case.draw, case.count));
        try std.testing.expectEqual(case.divisor, @as(u16, 0x7fff / case.count));
    }
    for (vectors.value.rune) |case| {
        const candidate = encounter.Candidate{ .id = case.candidate, .enemy_level_sum = case.enemy_level_sum };
        try std.testing.expectEqual(case.enemy_level_scaled, encounter.enemyLevelScaled(case.enemy_level_sum));
        try std.testing.expectEqual(case.rejected, encounter.runeRejects(.{ .level_sum = case.party_level_sum, .suppression_rune = case.suppression_rune }, candidate));
    }
}

test "walk vectors select the expected candidate and cursor" {
    const vectors = try std.json.parseFromSlice(Vectors, allocator, data.vectors_json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer vectors.deinit();
    var buffer: [64]encounter.Candidate = undefined;
    for (vectors.value.walks) |case| {
        const candidates = buildCandidates(&buffer, case.candidates);
        const draws = encounter.draws{ .values = case.values, .cursor = case.cursor };
        const outcome = try encounter.attempt(case.eligibility, case.party, ratePolicy(case.rate), candidates, draws);
        try expectOutcome(outcome, case.expect, candidates);
        // The caller's value is never mutated by attempt.
        try std.testing.expectEqual(case.cursor, draws.cursor);
    }
}

test "a failed admission leaves the caller's RNG and pending choice unchanged" {
    const vectors = try std.json.parseFromSlice(Vectors, allocator, data.vectors_json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer vectors.deinit();
    var buffer: [64]encounter.Candidate = undefined;
    const case = vectors.value.walks[0];
    const candidates = buildCandidates(&buffer, case.candidates);
    const caller = encounter.draws{ .values = case.values, .cursor = case.cursor };
    const before = caller;
    const outcome = try encounter.attempt(case.eligibility, case.party, ratePolicy(case.rate), candidates, caller);
    // Admission fails: the caller does not commit the returned progress.
    try std.testing.expectEqual(before.cursor, caller.cursor);
    try std.testing.expectEqual(before.values[0], caller.values[0]);
    // A later successful admission commits exactly the returned cursor once.
    switch (outcome) {
        .selected => |selection| {
            var committed = caller;
            committed = selection.progress.draws;
            try std.testing.expectEqual(@as(usize, 2), committed.cursor);
        },
        else => return error.ExpectedSelection,
    }
}

test "an RNG error leaves the caller's value untouched" {
    var one = [_]u15{0};
    const caller = encounter.draws{ .values = &one, .cursor = 0 };
    const candidates = [_]encounter.Candidate{.{ .id = "one", .enemy_level_sum = 1 }};
    try std.testing.expectError(error.RandomInputExhausted, encounter.attempt(.{ .travel_counter = 1, .counter_threshold = 0 }, .{}, .{ .source = .{ .rate = 255, .counter_threshold = 0 } }, &candidates, caller));
    try std.testing.expectEqual(@as(usize, 0), caller.cursor);
}

test "fresh-process continuation decodes the same request and selects the same candidate" {
    const vectors = try std.json.parseFromSlice(Vectors, allocator, data.vectors_json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer vectors.deinit();
    for (vectors.value.continuation) |case| {
        const bytes = try std.json.Stringify.valueAlloc(allocator, case.request, .{});
        defer allocator.free(bytes);
        const decoded = try std.json.parseFromSlice(Request, allocator, bytes, .{ .allocate = .alloc_always });
        defer decoded.deinit();
        var buffer: [encounter.max_candidates]encounter.Candidate = undefined;
        const candidates = buildCandidates(&buffer, decoded.value.candidates);
        const outcome = try encounter.attempt(
            .{ .travel_counter = decoded.value.travel_counter, .counter_threshold = decoded.value.counter_threshold },
            .{ .level_sum = decoded.value.party_level_sum, .suppression_rune = decoded.value.suppression_rune },
            .{ .source = .{ .rate = decoded.value.rate, .counter_threshold = decoded.value.counter_threshold } },
            candidates,
            .{ .values = decoded.value.values, .cursor = decoded.value.cursor },
        );
        try expectOutcome(outcome, case.expect, candidates);
    }
}
