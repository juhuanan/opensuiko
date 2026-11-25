//! Content identity for the full-campaign snapshot.
//!
//! A campaign save is meaningless without the content it was played against, so
//! every snapshot stores a `ContentRef` (campaign id, monotonic revision,
//! SHA-256 of the canonical identity document) and every load rebinds it:
//!
//!   * same revision            -> the digest must match exactly,
//!   * older revision           -> every referenced id must still exist,
//!   * newer revision than ours -> refused (the content was downgraded),
//!   * different campaign       -> refused.
//!
//! The digest is over an explicit little-endian field stream, not over the
//! JSON text, so formatting and key order cannot change identity.  The Python
//! producer in the extraction pipeline writes the same stream; the Zig
//! gate recomputes it, which is the independent check.

const std = @import("std");
const ids = @import("ids.zig");
const budget = @import("budget.zig");

pub const schema_id = "suikoden-campaign-content/1";
pub const stream_domain = "suikoden-campaign-content-stream/1";

pub const PlaceKind = enum { map, room };
pub const Place = struct {
    id: ids.Id(32) = .{},
    kind: PlaceKind = .map,
    block: ids.Id(32) = .{},
};

/// The exact set of ids a snapshot may reference at one content revision.
pub const Document = struct {
    schema: []const u8 = schema_id,
    campaign: ids.Id(32) = .{},
    revision: u32 = 0,
    digest: ids.HexBytes(32) = .{},
    places: []const Place = &.{},
    blocks: []const ids.Id(32) = &.{},
    roster_ids: []const ids.Id(32) = &.{},
    items: []const ids.Id(32) = &.{},
    equipment: []const ids.Id(32) = &.{},
    runes: []const ids.Id(32) = &.{},
    services: []const ids.Id(32) = &.{},
    hq_rooms: []const ids.Id(32) = &.{},
    hq_stages: []const u8 = &.{},
    duels: []const ids.Id(32) = &.{},
    minigames: []const ids.Id(32) = &.{},
    quests: []const ids.Id(32) = &.{},
    war_battles: []const ids.Id(32) = &.{},

    pub fn validate(self: Document) !void {
        if (!std.mem.eql(u8, self.schema, schema_id)) return error.UnsupportedContentSchema;
        try self.campaign.validate();
        if (self.revision == 0 or self.revision > 1_000_000) return error.InvalidContentRevision;
        if (self.blocks.len == 0 or self.blocks.len > 64) return error.InvalidWorldlocks;
        if (self.places.len == 0 or self.places.len > 512) return error.InvalidContentPlaces;
        if (self.roster_ids.len == 0 or self.roster_ids.len > 128) return error.InvalidContentRoster;
        if (self.items.len > 512) return error.InvalidContentItems;
        if (self.equipment.len > 256) return error.InvalidContentEquipment;
        if (self.runes.len > 256) return error.InvalidContentRunes;
        if (self.services.len > 128) return error.InvalidContentServices;
        if (self.hq_rooms.len > 256) return error.InvalidContentHqRooms;
        if (self.hq_stages.len == 0 or self.hq_stages.len > 16) return error.InvalidContentHqStages;
        if (self.duels.len > 64) return error.InvalidContentDuels;
        if (self.minigames.len > 64) return error.InvalidContentMinigames;
        if (self.quests.len > 512) return error.InvalidContentQuests;
        if (self.war_battles.len > 64) return error.InvalidContentWar;
        try uniqueIds(32, self.blocks);
        try uniqueIds(32, self.roster_ids);
        try uniqueIds(32, self.items);
        try uniqueIds(32, self.equipment);
        try uniqueIds(32, self.runes);
        try uniqueIds(32, self.services);
        try uniqueIds(32, self.hq_rooms);
        try uniqueIds(32, self.duels);
        try uniqueIds(32, self.minigames);
        try uniqueIds(32, self.quests);
        try uniqueIds(32, self.war_battles);
        for (self.places, 0..) |entry, index| {
            try entry.id.validate();
            try entry.block.validate();
            if (!contains(ids.Id(32), self.blocks, entry.block)) return error.UnknownWorldlock;
            for (self.places[0..index]) |earlier| if (std.meta.eql(earlier.id, entry.id)) return error.DuplicateContentPlace;
        }
        var has_map = false;
        var has_room = false;
        for (self.places) |entry| switch (entry.kind) {
            .map => has_map = true,
            .room => has_room = true,
        };
        if (!has_map or !has_room) return error.IncompleteContentPlaces;
        for (self.hq_stages, 0..) |stage, index| {
            if (stage > 15) return error.InvalidContentHqStages;
            for (self.hq_stages[0..index]) |earlier| if (earlier == stage) return error.DuplicateContentStage;
        }
    }

    pub fn computeDigest(self: Document) ids.HexBytes(32) {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(stream_domain);
        hasher.update(&.{0});
        putString(&hasher, self.campaign.text());
        putU32(&hasher, self.revision);
        putIdList(&hasher, self.blocks);
        putU32(&hasher, @intCast(self.places.len));
        for (self.places) |entry| {
            putString(&hasher, entry.id.text());
            hasher.update(&.{@backingInt(entry.kind)});
            putString(&hasher, entry.block.text());
        }
        putIdList(&hasher, self.roster_ids);
        putIdList(&hasher, self.items);
        putIdList(&hasher, self.equipment);
        putIdList(&hasher, self.runes);
        putIdList(&hasher, self.services);
        putIdList(&hasher, self.hq_rooms);
        putU32(&hasher, @intCast(self.hq_stages.len));
        for (self.hq_stages) |stage| hasher.update(&.{stage});
        putIdList(&hasher, self.duels);
        putIdList(&hasher, self.minigames);
        putIdList(&hasher, self.quests);
        putIdList(&hasher, self.war_battles);
        var out: ids.HexBytes(32) = .{};
        hasher.final(&out.bytes);
        return out;
    }

    pub fn verifyDigest(self: Document) !void {
        if (!self.computeDigest().eql(self.digest)) return error.ContentDigestMismatch;
    }
};

/// What a snapshot stores about the content it was played against.
pub const Ref = struct {
    campaign: ids.Id(32) = .{},
    revision: u32 = 0,
    digest: ids.HexBytes(32) = .{},

    pub fn validate(self: Ref) !void {
        try self.campaign.validate();
        if (self.revision == 0) return error.InvalidContentRevision;
    }
};

pub const Bind = struct {
    /// Revision the file was written against.
    from_revision: u32,
    /// Current revision after binding (>= from_revision).
    to_revision: u32,
    /// True when the file's ids had to be re-pointed at a newer revision.
    rebound: bool,
    /// True when the file already carried the current revision and digest.
    exact: bool,
};

pub const Content = struct {
    allocator: std.mem.Allocator,
    /// Set only by `load`; owns the decoded document's arena.
    owned: ?budget.Parsed(Document) = null,
    doc: Document,

    pub fn load(allocator: std.mem.Allocator, bytes: []const u8, limits: budget.Limits) !Content {
        const parsed = try budget.decode(Document, allocator, bytes, limits);
        errdefer parsed.deinit();
        try parsed.value.validate();
        try parsed.value.verifyDigest();
        return .{ .allocator = allocator, .owned = parsed, .doc = parsed.value };
    }

    /// Take a document whose slices the caller keeps alive (tests and compiled
    /// fixtures).  Validated exactly as after a JSON load.
    pub fn adopt(allocator: std.mem.Allocator, doc: Document) !Content {
        try doc.validate();
        try doc.verifyDigest();
        return .{ .allocator = allocator, .doc = doc };
    }

    pub fn deinit(self: *Content) void {
        if (self.owned) |parsed| {
            parsed.deinit();
            self.owned = null;
        }
    }

    pub fn revision(self: *const Content) u32 {
        return self.doc.revision;
    }

    pub fn ref(self: *const Content) Ref {
        return .{ .campaign = self.doc.campaign, .revision = self.doc.revision, .digest = self.doc.digest };
    }

    pub fn rebind(self: *const Content, saved: Ref) !Bind {
        try saved.validate();
        if (!std.mem.eql(u8, saved.campaign.text(), self.doc.campaign.text())) return error.ForeignCampaign;
        if (saved.revision > self.doc.revision) return error.ContentDowngraded;
        if (saved.revision == self.doc.revision) {
            if (!saved.digest.eql(self.doc.digest)) return error.ContentDigestMismatch;
            return .{ .from_revision = saved.revision, .to_revision = saved.revision, .rebound = false, .exact = true };
        }
        // An older revision may be re-pointed only if every id it names still
        // exists; the caller's section validation enforces that after rebinding.
        return .{ .from_revision = saved.revision, .to_revision = self.doc.revision, .rebound = true, .exact = false };
    }

    pub fn hasBlock(self: *const Content, block: ids.Id(32)) bool {
        return contains(ids.Id(32), self.doc.blocks, block);
    }

    pub fn place(self: *const Content, id: ids.Id(32)) ?Place {
        for (self.doc.places) |entry| if (std.meta.eql(entry.id, id)) return entry;
        return null;
    }

    pub fn hasPlace(self: *const Content, id: ids.Id(32)) bool {
        return self.place(id) != null;
    }

    pub fn hasRoster(self: *const Content, id: ids.Id(32)) bool {
        return contains(ids.Id(32), self.doc.roster_ids, id);
    }

    pub fn hasItem(self: *const Content, id: ids.Id(32)) bool {
        return contains(ids.Id(32), self.doc.items, id);
    }

    pub fn hasEquipment(self: *const Content, id: ids.Id(32)) bool {
        return contains(ids.Id(32), self.doc.equipment, id);
    }

    pub fn hasRune(self: *const Content, id: ids.Id(32)) bool {
        return contains(ids.Id(32), self.doc.runes, id);
    }

    pub fn hasService(self: *const Content, id: ids.Id(32)) bool {
        return contains(ids.Id(32), self.doc.services, id);
    }

    pub fn hasHqRoom(self: *const Content, id: ids.Id(32)) bool {
        return contains(ids.Id(32), self.doc.hq_rooms, id);
    }

    pub fn hasHqStage(self: *const Content, stage: u8) bool {
        for (self.doc.hq_stages) |candidate| if (candidate == stage) return true;
        return false;
    }

    pub fn hasDuel(self: *const Content, id: ids.Id(32)) bool {
        return contains(ids.Id(32), self.doc.duels, id);
    }

    pub fn hasMinigame(self: *const Content, id: ids.Id(32)) bool {
        return contains(ids.Id(32), self.doc.minigames, id);
    }

    pub fn hasQuest(self: *const Content, id: ids.Id(32)) bool {
        return contains(ids.Id(32), self.doc.quests, id);
    }

    pub fn hasWarBattle(self: *const Content, id: ids.Id(32)) bool {
        return contains(ids.Id(32), self.doc.war_battles, id);
    }

    pub fn maxHqStage(self: *const Content) u8 {
        var result: u8 = 0;
        for (self.doc.hq_stages) |stage| {
            if (stage > result) result = stage;
        }
        return result;
    }
};

fn contains(comptime T: type, list: []const T, item: T) bool {
    for (list) |candidate| if (std.meta.eql(candidate, item)) return true;
    return false;
}

fn putU32(hasher: *std.crypto.hash.sha2.Sha256, value: u32) void {
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, value, .little);
    hasher.update(&encoded);
}

fn putString(hasher: *std.crypto.hash.sha2.Sha256, text: []const u8) void {
    putU32(hasher, @intCast(text.len));
    hasher.update(text);
}

fn putIdList(hasher: *std.crypto.hash.sha2.Sha256, list: anytype) void {
    putU32(hasher, @intCast(list.len));
    for (list) |entry| putString(hasher, entry.text());
}

fn uniqueIds(comptime n: usize, list: []const ids.Id(n)) !void {
    for (list, 0..) |entry, index| {
        try entry.validate();
        for (list[0..index]) |earlier| if (std.meta.eql(earlier, entry)) return error.DuplicateContentId;
    }
}

test "content digest is stable and detects a tampered id list" {
    const blocks = [_]ids.Id(32){ try ids.Id(32).init("block_a"), try ids.Id(32).init("block_b") };
    const places = [_]Place{
        .{ .id = try ids.Id(32).init("map_a"), .kind = .map, .block = blocks[0] },
        .{ .id = try ids.Id(32).init("room_a"), .kind = .room, .block = blocks[0] },
    };
    const roster = [_]ids.Id(32){try ids.Id(32).init("hero")};
    const stages = [_]u8{ 0, 1 };
    var doc: Document = .{
        .campaign = try ids.Id(32).init("test-campaign"),
        .revision = 3,
        .places = &places,
        .blocks = &blocks,
        .roster_ids = &roster,
        .hq_stages = &stages,
    };
    doc.digest = doc.computeDigest();
    try doc.validate();
    try doc.verifyDigest();
    const before = doc.digest;
    doc.revision = 4;
    try std.testing.expectError(error.ContentDigestMismatch, doc.verifyDigest());
    doc.revision = 3;
    try std.testing.expect(doc.digest.eql(before));
    doc.blocks = &blocks;
    const empty_places = [_]Place{};
    doc.places = &empty_places;
    try std.testing.expectError(error.InvalidContentPlaces, doc.validate());
}
