const std = @import("std");
const war = @import("war");
const session = @import("war_session");

pub const schema = "suikoden-middle-war/1";

pub const Entry = struct {
    scenario_id: []const u8,
    selector: u8,
    source_sha256: []const u8,
    story_entry: []const u8,
    consequence_mapping: []const u8,
    dependency_status: []const u8,
};
pub const Coverage = struct { scenarios: u8, accepted_dependencies: u8, canonical_story_mappings: u8, adapter_ready: u8 };
pub const Dependency = struct {
    api: []const u8,
    scenarios_sha256: []const u8,
    session_sha256: []const u8,
    rules_sha256: []const u8,
    status: []const u8,
};
pub const Asset = struct {
    schema: []const u8,
    content_sha256: []const u8,
    dependency: Dependency,
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
        asset.entries.len != 9 or asset.coverage.scenarios != 9 or asset.coverage.adapter_ready != 9 or
        asset.coverage.accepted_dependencies != 0 or asset.coverage.canonical_story_mappings != 0)
        return error.InvalidWarAdapterContent;
    if (!std.mem.eql(u8, asset.dependency.api, "suikoden-war-session/6") or
        !std.mem.eql(u8, asset.dependency.status, "producer-only public artifact; campaign acceptance is not inferred"))
        return error.InvalidWarAdapterDependency;
    const ids = [_][]const u8{
        "pannu_yakuta",          "garan",          "scarleticia_pollen",  "scarleticia_antidote",
        "teo_before_fire_spear", "teo_fire_spear", "northern_checkpoint", "shasarazade",
        "gregminster",
    };
    for (asset.entries, ids) |entry, id| {
        if (!std.mem.eql(u8, entry.scenario_id, id) or
            !std.mem.eql(u8, entry.story_entry, "source_entry_unresolved") or
            !std.mem.eql(u8, entry.consequence_mapping, "canonical_story_mapping_unresolved") or
            !std.mem.eql(u8, entry.dependency_status, "producer_v6_not_accepted_campaign_input"))
            return error.InvalidWarAdapterEntry;
    }
}

pub const Facts = struct { story_revision: u64, roster_digest: [32]u8 };
pub const Commit = struct {
    result: war.Result,
    canonical_mapping: []const u8,
};
pub const Snapshot = struct {
    entry_id: []const u8,
    host: session.Host,
    session_json: []const u8,
};

pub const Adapter = struct {
    entry_id: []const u8,
    facts: Facts,
    session: session.Session,
    host: session.Host = .{},

    pub fn begin(allocator: std.mem.Allocator, entry_id: []const u8, scenario: war.Scenario, expected: Facts, actual: Facts, rng: war.Random) !Adapter {
        if (!std.meta.eql(expected, actual)) return error.StaleBeforeState;
        if (!std.mem.eql(u8, entry_id, scenario.id)) return error.WrongWarScenario;
        return .{ .entry_id = entry_id, .facts = expected, .session = try session.Session.init(allocator, .{ .scenario = scenario, .rng = rng }) };
    }

    pub fn deinit(self: *Adapter) void {
        self.session.deinit();
    }

    pub fn applyResult(self: *Adapter, receipt: u64) !Commit {
        const result = self.session.engine.result orelse return error.WarResultNotReady;
        if (!std.mem.eql(u8, self.entry_id, self.session.engine.scenario.id)) return error.WrongWarScenario;
        try session.applyResult(&self.host, &self.session, receipt);
        return .{ .result = result, .canonical_mapping = "canonical_story_mapping_unresolved" };
    }

    pub fn capture(self: *const Adapter, allocator: std.mem.Allocator) !Snapshot {
        if (!std.mem.eql(u8, self.entry_id, self.session.engine.scenario.id)) return error.WrongWarScenario;
        return .{
            .entry_id = self.entry_id,
            .host = self.host,
            .session_json = try self.session.snapshot(allocator),
        };
    }

    pub fn restore(allocator: std.mem.Allocator, entry_id: []const u8, scenario: war.Scenario, expected: Facts, actual: Facts, snapshot: Snapshot) !Adapter {
        if (!std.meta.eql(expected, actual)) return error.StaleBeforeState;
        if (!std.mem.eql(u8, entry_id, scenario.id) or !std.mem.eql(u8, entry_id, snapshot.entry_id)) return error.SnapshotMismatch;
        var adapter = Adapter{
            .entry_id = entry_id,
            .facts = expected,
            .session = try session.Session.init(allocator, .{ .scenario = scenario, .rng = .{ .state = 0 }, .snapshot = snapshot.session_json }),
            .host = snapshot.host,
        };
        errdefer adapter.deinit();
        if (!std.mem.eql(u8, adapter.session.engine.scenario.id, snapshot.entry_id)) return error.SnapshotMismatch;
        return adapter;
    }
};
