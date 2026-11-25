//! Opening route ledger: the integrator's typed view of the canonical opening.
//!
//! Produced from the reviewed opening route artifacts plus the shared runtime
//! source. It carries identities, source-relative entry/exit facts and typed
//! blockers -- never PS1 addresses, pointers or dev-tree paths. This module owns
//! strict decoding and the two queries the host needs: "which planned stage is
//! blocked, and why" and "may the Opening-to-world boundary be handed over yet".
//!
//! A ledger row is *not* evidence that the runtime can execute the stage.  The
//! generator records `blocked` for a stage whose shared owner is missing, and the
//! host refuses to cross the boundary while any required stage is blocked.

const std = @import("std");
const data = @import("opening_assets").ledger;

pub const schema = data.schema;
pub const revision = data.revision;
pub const ledger_sha256 = data.ledger_sha256;
pub const max_bytes = 4 * 1024 * 1024;

pub const Status = enum { integrated, module_only, blocked };

pub const Point = struct { x: i32, y: i32 };

pub const Evidence = struct { path: []const u8, sha256: []const u8, bytes: u64 };

pub const Program = struct {
    program: []const u8,
    entity: ?u8 = null,
    destination: []const u8,
    x: i32,
    y: i32,
    cue_prefix: []const u16,
    fade_prefix: []const FadePrefix,
};

pub const FadePrefix = struct { blend_mode: ?u8 = null, draw_slot: ?u8 = null };

pub const Room = struct {
    room: []const u8,
    content: Evidence,
    population: Evidence,
    programs: []const Program,
};

pub const Stop = struct {
    id: []const u8,
    from: []const u8,
    to: []const u8,
    entry: Point,
    cue_prefix: []const u16,
    fade_prefix: []const FadePrefix,
    content_sha256: []const u8,
    producer: []const u8,
    status: []const u8,
};

pub const Stage = struct {
    id: []const u8,
    producer: []const u8,
    status: Status,
    detail: []const u8,
    evidence: Evidence,
    missing_api: []const []const u8 = &.{},
    blocked_programs: ?u32 = null,
    compiled_programs: ?u32 = null,
    completed_programs: ?u32 = null,
    battle_entries: ?u32 = null,
    event_party_add: ?u32 = null,
};

pub const BlockerKind = enum { integration, source, external, human };

pub const Blocker = struct {
    id: []const u8,
    kind: BlockerKind,
    owner: []const u8,
    detail: []const u8,
    missing: []const []const u8 = &.{},
    blocked_programs: ?u32 = null,
    evidence: ?Evidence = null,
};

pub const Start = struct {
    asset: Evidence,
    location: std.json.Value,
    field_entry: std.json.Value,
    money: u32,
    party_count: u8,
    party_slot_order: []const u8,
    hero: []const u8,
    bios_seed: u32,
};

pub const BoundaryStatus = enum { ready, blocked };

pub const Boundary = struct {
    id: []const u8,
    status: BoundaryStatus,
    requires: []const []const u8,
    source_state: std.json.Value,
    refusal: ?[]const u8 = null,
};

pub const Ledger = struct {
    schema: []const u8,
    revision: []const u8,
    start: Start,
    route_rooms: []const Room,
    stops: []const Stop,
    stages: []const Stage,
    blockers: []const Blocker,
    boundary: Boundary,
    conventions: std.json.Value,

    pub fn stageById(self: Ledger, id: []const u8) ?*const Stage {
        for (self.stages) |*stage| if (std.mem.eql(u8, stage.id, id)) return stage;
        return null;
    }

    pub fn blockerById(self: Ledger, id: []const u8) ?*const Blocker {
        for (self.blockers) |*blocker| if (std.mem.eql(u8, blocker.id, id)) return blocker;
        return null;
    }

    pub fn stopById(self: Ledger, id: []const u8) ?*const Stop {
        for (self.stops) |*stop| if (std.mem.eql(u8, stop.id, id)) return stop;
        return null;
    }

    /// The first required boundary stage that is not integrated, in stage order.
    pub fn firstBlockedRequirement(self: Ledger) ?*const Stage {
        for (self.boundary.requires) |id| {
            const stage = self.stageById(id) orelse continue;
            if (stage.status != .integrated) return stage;
        }
        return null;
    }

    pub fn validate(self: Ledger) !void {
        if (!std.mem.eql(u8, self.schema, schema)) return error.UnsupportedLedger;
        if (!std.mem.eql(u8, self.revision, revision)) return error.UnsupportedLedgerRevision;
        if (self.stops.len == 0 or self.stages.len == 0 or self.blockers.len == 0) return error.InvalidLedger;
        if (self.boundary.status == .ready) {
            for (self.boundary.requires) |id| {
                const stage = self.stageById(id) orelse return error.InvalidBoundary;
                if (stage.status != .integrated) return error.InvalidBoundary;
            }
        } else if (self.boundary.requires.len == 0 or self.firstBlockedRequirement() == null) return error.InvalidBoundary;
        for (self.stops) |stop| {
            if (stop.entry.x < 0 or stop.entry.y < 0 or stop.entry.x > 2040 or stop.entry.y > 2040) return error.InvalidStop;
            if (!std.mem.eql(u8, stop.content_sha256, "")) {
                if (stop.content_sha256.len != 64) return error.InvalidStop;
            }
            if (self.stopById(stop.id) == null) return error.InvalidStop;
        }
        for (self.stages) |stage| {
            if (stage.evidence.sha256.len != 64 or stage.evidence.bytes == 0) return error.InvalidStageEvidence;
            if (stage.status == .blocked and !std.mem.eql(u8, stage.id, "first_town") and !std.mem.eql(u8, stage.id, "palace_route") and !std.mem.eql(u8, stage.id, "opening_dungeon")) return error.InvalidStageStatus;
        }
        for (self.blockers) |blocker| {
            if (blocker.detail.len == 0 or blocker.owner.len == 0) return error.InvalidBlocker;
        }
        if (self.start.asset.sha256.len != 64) return error.InvalidStartEvidence;
        if (self.start.money == 0 or self.start.party_count == 0 or self.start.party_count > 6) return error.InvalidStartEvidence;
        if (self.start.bios_seed == 0) return error.InvalidStartEvidence;
    }
};

/// Decode the embedded ledger.  The digest is checked before parsing, so a
/// substituted ledger cannot arrive as a plausible-but-different route.
pub fn open(allocator: std.mem.Allocator) !std.json.Parsed(Ledger) {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data.json, &hash, .{});
    const hex = std.fmt.bytesToHex(hash, .lower);
    if (!std.mem.eql(u8, &hex, ledger_sha256)) return error.InvalidLedgerDigest;
    if (data.json.len > max_bytes) return error.LedgerTooLarge;
    const parsed = try std.json.parseFromSlice(Ledger, allocator, data.json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}
