//! One campaign state.
//!
//! Stage ledger ownership remains encapsulated here.  This owner is the only
//! public surface: it loads the accepted campaign ledgers, reports the
//! current stage, and names the first blocker without pretending a later stage
//! was reached.

const std = @import("std");
const opening_ledger_mod = @import("opening_ledger");
const war_data = @import("middle_assets").ledger;

const content_zon = @import("campaign_content_zon").data;

const manifest: Manifest = .{
    .schema = content_zon.schema,
    .stages = &.{
        .{ .id = content_zon.stages[0].id, .root = content_zon.stages[0].root, .status = content_zon.stages[0].status, .blocker = content_zon.stages[0].blocker },
        .{ .id = content_zon.stages[1].id, .root = content_zon.stages[1].root, .status = content_zon.stages[1].status, .blocker = content_zon.stages[1].blocker },
        .{ .id = content_zon.stages[2].id, .root = content_zon.stages[2].root, .status = content_zon.stages[2].status, .blocker = content_zon.stages[2].blocker },
        .{ .id = content_zon.stages[3].id, .root = content_zon.stages[3].root, .status = content_zon.stages[3].status, .blocker = content_zon.stages[3].blocker },
    },
};

const Manifest = struct {
    schema: []const u8,
    stages: []const ManifestStage,

    fn stageById(self: Manifest, id: []const u8) ?*const ManifestStage {
        for (self.stages) |*stage| if (std.mem.eql(u8, stage.id, id)) return stage;
        return null;
    }
};

const ManifestStage = struct {
    id: []const u8,
    root: []const u8,
    status: []const u8,
    blocker: ?[]const u8 = null,
};

pub const BlockerKind = enum { integration, source, external, human };

pub const Status = struct {
    schema: []const u8 = "suikoden-campaign-status/1",
    stage: []const u8,
    playable: bool,
    next: []const u8,
    blocker: ?[]const u8,
    blocker_kind: ?[]const u8,
    owner: ?[]const u8,
    detail: ?[]const u8,
    content_root: []const u8,
    compiled_programs: ?u32 = null,
    blocked_programs: ?u32 = null,
    completed_programs: ?u32 = null,
    war_scenarios: ?u32 = null,
    war_adapter_ready: ?u32 = null,
    war_accepted_dependencies: ?u32 = null,
    war_canonical_mappings: ?u32 = null,
    war_stage: []const u8,
};

fn count(value: ?std.json.Value, key: []const u8) ?u32 {
    const object = (value orelse return null).object;
    const field = object.get(key) orelse return null;
    return switch (field) {
        .integer => |integer| std.math.cast(u32, integer),
        else => null,
    };
}

const WarStage = struct { id: []const u8, counts: ?std.json.Value = null };
const WarLedger = struct { stages: []const WarStage };

pub const Campaign = struct {
    allocator: std.mem.Allocator,
    manifest: Manifest,
    opening_ledger: std.json.Parsed(opening_ledger_mod.Ledger),
    war_scenarios: ?u32,
    war_adapter_ready: ?u32,
    war_accepted_dependencies: ?u32,
    war_canonical_mappings: ?u32,

    pub fn open(allocator: std.mem.Allocator) !Campaign {
        if (!std.mem.eql(u8, manifest.schema, "suikoden-campaign-content/1") or manifest.stages.len != 4) return error.InvalidCampaignManifest;
        for ([_][]const u8{ "opening", "palace", "first_town", "war" }) |id| {
            const stage = manifest.stageById(id) orelse return error.InvalidCampaignManifest;
            if (stage.root.len == 0) return error.InvalidCampaignManifest;
        }
        var opening_ledger = try opening_ledger_mod.open(allocator);
        errdefer opening_ledger.deinit();
        const war = try std.json.parseFromSlice(WarLedger, allocator, war_data.json, .{ .ignore_unknown_fields = true });
        defer war.deinit();
        var war_scenarios: ?u32 = null;
        var war_adapter_ready: ?u32 = null;
        var war_accepted_dependencies: ?u32 = null;
        var war_canonical_mappings: ?u32 = null;
        for (war.value.stages) |stage| if (std.mem.eql(u8, stage.id, "war")) {
            war_scenarios = count(stage.counts, "scenarios");
            war_adapter_ready = count(stage.counts, "adapter_ready");
            war_accepted_dependencies = count(stage.counts, "accepted_dependencies");
            war_canonical_mappings = count(stage.counts, "canonical_story_mappings");
        };
        return .{ .allocator = allocator, .manifest = manifest, .opening_ledger = opening_ledger, .war_scenarios = war_scenarios, .war_adapter_ready = war_adapter_ready, .war_accepted_dependencies = war_accepted_dependencies, .war_canonical_mappings = war_canonical_mappings };
    }

    pub fn deinit(self: *Campaign) void {
        self.opening_ledger.deinit();
    }

    /// The first reachable stage.  Palace is playable today; first town is the
    /// first blocked stage.  Later stages are not reported as reached.
    pub fn status(self: *const Campaign) Status {
        const war_content = self.manifest.stageById("war");
        const first_town_content = self.manifest.stageById("first_town");
        const first_town = self.opening_ledger.value.stageById("first_town") orelse {
            return .{ .stage = "unknown", .playable = false, .next = "unknown", .blocker = "missing_campaign_stage", .blocker_kind = "integration", .owner = "campaign", .detail = "campaign ledger has no first_town stage", .content_root = "", .war_stage = "external" };
        };
        if (first_town.status == .blocked) {
            const blocker = self.opening_ledger.value.blockerById("first_town_mandatory_content");
            return .{
                .stage = "palace",
                .playable = true,
                .next = "first_town",
                .blocker = if (blocker) |b| b.id else "first_town_mandatory_content",
                .blocker_kind = if (blocker) |b| @tagName(b.kind) else "source",
                .owner = if (blocker) |b| b.owner else "first_town",
                .detail = if ((first_town.blocked_programs orelse 0) == 0)
                    "the first-town content is complete; the route handoff remains blocked"
                else if (blocker) |b| b.detail else first_town.detail,
                .content_root = if (first_town_content) |c| c.root else "",
                .compiled_programs = first_town.compiled_programs,
                .blocked_programs = first_town.blocked_programs,
                .completed_programs = first_town.completed_programs,
                .war_scenarios = self.war_scenarios,
                .war_adapter_ready = self.war_adapter_ready,
                .war_accepted_dependencies = self.war_accepted_dependencies,
                .war_canonical_mappings = self.war_canonical_mappings,
                .war_stage = if (war_content) |w| w.status else "external",
            };
        }
        const dungeon = self.opening_ledger.value.stageById("opening_dungeon");
        const review = self.opening_ledger.value.blockerById("native_review");
        if (self.opening_ledger.value.boundary.status == .ready) {
            return .{
                .stage = "first_town",
                .playable = true,
                .next = "route",
                .blocker = if (review) |b| b.id else null,
                .blocker_kind = if (review) |b| @tagName(b.kind) else null,
                .owner = if (review) |b| b.owner else null,
                .detail = if (review) |b| b.detail else null,
                .content_root = if (first_town_content) |c| c.root else "",
                .compiled_programs = first_town.compiled_programs,
                .blocked_programs = first_town.blocked_programs,
                .completed_programs = if (dungeon) |d| d.completed_programs else null,
                .war_scenarios = self.war_scenarios,
                .war_adapter_ready = self.war_adapter_ready,
                .war_accepted_dependencies = self.war_accepted_dependencies,
                .war_canonical_mappings = self.war_canonical_mappings,
                .war_stage = if (war_content) |w| w.status else "external",
            };
        }
        return .{
            .stage = "first_town",
            .playable = true,
            .next = "route",
            .blocker = "first_town_route_binding",
            .blocker_kind = "integration",
            .owner = "campaign",
            .detail = "first-town content is playable; the journey route binding is not complete",
            .content_root = if (first_town_content) |c| c.root else "",
            .war_scenarios = self.war_scenarios,
            .war_adapter_ready = self.war_adapter_ready,
            .war_accepted_dependencies = self.war_accepted_dependencies,
            .war_canonical_mappings = self.war_canonical_mappings,
            .war_stage = if (war_content) |w| w.status else "external",
        };
    }
};
