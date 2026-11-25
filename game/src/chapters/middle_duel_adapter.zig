const std = @import("std");
const duel = @import("duel");

pub const schema = "suikoden-middle-duels/1";

pub const Entry = struct {
    id: []const u8,
    duel_id: []const u8,
    source_file: []const u8,
    source_sha256: []const u8,
    participants: []const []const u8,
    participant_state: []const u8,
    story_entry: []const u8,
    consequences: []const u8,
    adapter: []const u8,
};
pub const Coverage = struct { duels: u8, source_entry_mappings: u8, source_consequence_mappings: u8, adapter_ready: u8 };
pub const Asset = struct {
    schema: []const u8,
    content_sha256: []const u8,
    entries: []const Entry,
    coverage: Coverage,
};

pub fn open(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Asset) {
    const parsed = try std.json.parseFromSlice(Asset, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    errdefer parsed.deinit();
    try validate(parsed.value);
    return parsed;
}

pub fn validate(asset: Asset) !void {
    if (!std.mem.eql(u8, asset.schema, schema) or asset.content_sha256.len != 64 or
        asset.entries.len != 3 or asset.coverage.duels != 3 or asset.coverage.adapter_ready != 3 or
        asset.coverage.source_entry_mappings != 0 or asset.coverage.source_consequence_mappings != 0)
        return error.InvalidDuelAdapterContent;
    const ids = [_][]const u8{ "pahn_teo", "shu_kwanda", "shu_teo" };
    for (asset.entries, ids) |entry, id| {
        if (!std.mem.eql(u8, entry.duel_id, id) or entry.participants.len != 2 or
            !std.mem.eql(u8, entry.story_entry, "source_entry_unresolved") or
            !std.mem.eql(u8, entry.consequences, "source_consequences_unresolved"))
            return error.InvalidDuelAdapterEntry;
    }
}

pub const Facts = struct {
    story_revision: u64,
    roster_digest: [32]u8,
};
pub const Result = struct {
    entry_id: []const u8,
    outcome: duel.Outcome,
    player_hp: i32,
    opponent_hp: i32,
    final_random: duel.Random,
    expected_story_revision: u64,
    expected_roster_digest: [32]u8,
    receipt: [32]u8,
    consequences: []const u8,
};

fn receipt(entry_id: []const u8, outcome: duel.Outcome, player_hp: i32, opponent_hp: i32, random: duel.Random, facts: Facts) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(entry_id);
    hash.update(&[_]u8{@backingInt(outcome)});
    var numbers: [20]u8 = undefined;
    std.mem.writeInt(i32, numbers[0..4], player_hp, .little);
    std.mem.writeInt(i32, numbers[4..8], opponent_hp, .little);
    std.mem.writeInt(u64, numbers[8..16], random.cursor, .little);
    std.mem.writeInt(u32, numbers[16..20], random.bios_state orelse 0, .little);
    hash.update(&numbers);
    hash.update(&facts.roster_digest);
    var revision: [8]u8 = undefined;
    std.mem.writeInt(u64, &revision, facts.story_revision, .little);
    hash.update(&revision);
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

pub const Session = struct {
    content: *const duel.Content,
    entry_id: []const u8,
    facts: Facts,
    state: duel.State,
    result: ?Result = null,
    consumed: bool = false,

    pub fn begin(content: *const duel.Content, entry: Entry, expected: Facts, actual: Facts, fighters: [2]duel.FighterState, random: duel.Random) !Session {
        if (!std.meta.eql(expected, actual)) return error.StaleBeforeState;
        const state = try duel.State.init(content, entry.duel_id, fighters, random);
        return .{ .content = content, .entry_id = entry.id, .facts = expected, .state = state };
    }

    pub fn choose(self: *Session, command: duel.Command) !void {
        if (self.consumed) return error.ResultAlreadyConsumed;
        try self.state.choose(command);
    }

    pub fn tick(self: *Session) !void {
        if (self.consumed) return error.ResultAlreadyConsumed;
        try self.state.tick();
    }

    fn makeResult(self: *const Session) !Result {
        if (self.state.phase != .finished) return error.ResultPending;
        const outcome = self.state.outcome orelse return error.MissingDuelOutcome;
        return .{
            .entry_id = self.entry_id,
            .outcome = outcome,
            .player_hp = self.state.fighters[0].hp,
            .opponent_hp = self.state.fighters[1].hp,
            .final_random = self.state.random,
            .expected_story_revision = self.facts.story_revision,
            .expected_roster_digest = self.facts.roster_digest,
            .receipt = receipt(self.entry_id, outcome, self.state.fighters[0].hp, self.state.fighters[1].hp, self.state.random, self.facts),
            .consequences = "source_consequences_unresolved",
        };
    }

    pub fn takeResult(self: *Session) !Result {
        if (self.consumed) return error.DuplicateResult;
        if (self.result == null) self.result = try self.makeResult();
        self.consumed = true;
        return self.result.?;
    }

    pub fn capture(self: *const Session) !Snapshot {
        if (self.result) |result| {
            const expected = receipt(result.entry_id, result.outcome, result.player_hp, result.opponent_hp, result.final_random, .{
                .story_revision = result.expected_story_revision,
                .roster_digest = result.expected_roster_digest,
            });
            if (!std.mem.eql(u8, &expected, &result.receipt)) return error.InvalidResultReceipt;
        }
        return .{
            .entry_id = self.entry_id,
            .duel_id = self.state.duel.id,
            .current_exchange_id = if (self.state.current_exchange) |exchange| exchange.id else null,
            .state = self.state,
            .result = self.result,
            .consumed = self.consumed,
        };
    }

    pub fn restore(content: *const duel.Content, entry: Entry, expected: Facts, actual: Facts, snapshot: Snapshot) !Session {
        if (!std.meta.eql(expected, actual)) return error.StaleBeforeState;
        if (!std.mem.eql(u8, entry.id, snapshot.entry_id) or
            !std.mem.eql(u8, entry.duel_id, snapshot.duel_id)) return error.SnapshotMismatch;
        const encounter = duel.findDuel(content, snapshot.duel_id) orelse return error.SnapshotMismatch;
        var state = snapshot.state;
        state.duel = encounter;
        state.current_exchange = null;
        if (snapshot.current_exchange_id) |id| {
            for (encounter.exchanges) |*exchange| {
                if (std.mem.eql(u8, exchange.id, id)) {
                    state.current_exchange = exchange;
                    break;
                }
            }
            if (state.current_exchange == null) return error.SnapshotMismatch;
        }
        if (snapshot.consumed and snapshot.result == null) return error.InvalidSnapshot;
        var session = Session{ .content = content, .entry_id = entry.id, .facts = expected, .state = state, .result = snapshot.result, .consumed = snapshot.consumed };
        if (session.result) |saved| {
            const computed = try session.makeResult();
            if (!std.meta.eql(computed, saved)) return error.SnapshotMismatch;
        }
        return session;
    }
};

pub const Snapshot = struct {
    entry_id: []const u8,
    duel_id: []const u8,
    current_exchange_id: ?[]const u8,
    state: duel.State,
    result: ?Result,
    consumed: bool,
};
