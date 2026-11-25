//! Encoding, bounded decoding and the presence contract for
//! `suikoden-campaign-save/1`.
//!
//! A current-version file must carry every field of its sections.  Zig's
//! decoder fills struct defaults for missing keys, which would turn a truncated
//! or hand-written file into a plausible empty campaign; `validatePresence`
//! rejects that before the value is constructed.  Unknown keys are rejected by
//! the same parse (`ignore_unknown_fields` stays false), so a typo cannot be
//! silently dropped either.

const std = @import("std");
const ids = @import("ids.zig");
const budget = @import("budget.zig");
const content = @import("content.zig");
const schema = @import("schema.zig");
const legacy = @import("legacy.zig");

pub const schema_id = schema.schema_id;

pub const Decoded = struct {
    inner: budget.Parsed(std.json.Value),
    snapshot: *schema.Snapshot,
    bind: content.Bind,
    migrated: ?legacy.Source = null,

    pub fn deinit(self: Decoded) void {
        self.inner.deinit();
    }
};

pub fn encode(allocator: std.mem.Allocator, snapshot: schema.Snapshot, limits: budget.Limits) ![]u8 {
    const bytes = try std.json.Stringify.valueAlloc(allocator, snapshot, .{});
    errdefer allocator.free(bytes);
    if (bytes.len > limits.bytes) return error.CampaignTooLarge;
    return bytes;
}

/// Decode a campaign save only.  Legacy families are handled by `loadAny`.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, content_ref: *const content.Content, limits: budget.Limits) !Decoded {
    const parsed = try budget.decode(std.json.Value, allocator, bytes, limits);
    errdefer parsed.deinit();
    return decodeValue(parsed, content_ref);
}

/// Decode any supported durable file: the campaign envelope or one of the
/// established save families, which is migrated in place.
pub fn loadAny(allocator: std.mem.Allocator, bytes: []const u8, content_ref: *const content.Content, limits: budget.Limits) !Decoded {
    const parsed = try budget.decode(std.json.Value, allocator, bytes, limits);
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCampaign;
    const schema_field = parsed.value.object.get("schema") orelse return error.MissingField;
    if (schema_field != .string) return error.InvalidCampaign;
    if (!std.mem.startsWith(u8, schema_field.string, "suikoden-campaign-save/")) {
        const migration = try legacy.migrate(parsed.arena.allocator(), parsed.value, content_ref);
        const snapshot = try parsed.arena.allocator().create(schema.Snapshot);
        snapshot.* = migration.snapshot;
        return .{ .inner = parsed, .snapshot = snapshot, .bind = .{ .from_revision = content_ref.revision(), .to_revision = content_ref.revision(), .rebound = false, .exact = true }, .migrated = migration.source };
    }
    return decodeValue(parsed, content_ref);
}

fn decodeValue(parsed: budget.Parsed(std.json.Value), content_ref: *const content.Content) !Decoded {
    const value = parsed.value;
    if (value != .object) return error.InvalidCampaign;
    const schema_field = value.object.get("schema") orelse return error.MissingField;
    if (schema_field != .string) return error.InvalidCampaign;
    if (!std.mem.eql(u8, schema_field.string, schema_id)) {
        if (std.mem.startsWith(u8, schema_field.string, "suikoden-campaign-save/")) {
            return error.FutureCampaignSchema;
        }
        return error.UnsupportedCampaignSchema;
    }
    try validatePresence(value);
    const allocator = parsed.arena.allocator();
    const content_field = value.object.get("content") orelse return error.MissingField;
    const saved_ref = try std.json.innerParseFromValue(content.Ref, allocator, content_field, .{});
    const bind = try content_ref.rebind(saved_ref);
    const snapshot = try allocator.create(schema.Snapshot);
    snapshot.* = try std.json.innerParseFromValue(schema.Snapshot, allocator, value, .{});
    try snapshot.validate(content_ref);
    // A re-bound file is re-pointed at the current revision so a later save
    // records the revision it was actually validated against.
    if (bind.rebound) snapshot.content = content_ref.ref();
    return .{ .inner = parsed, .snapshot = snapshot, .bind = bind };
}

pub const Presence = struct {
    pub const top = [_][]const u8{ "schema", "content", "revision", "last_receipt", "saved_ticks", "roster", "quest", "world", "hq", "mode" };
    pub const content_ref = [_][]const u8{ "campaign", "revision", "digest" };
    pub const roster = [_][]const u8{ "identities", "party", "reserves", "members" };
    pub const member = [_][]const u8{ "id", "level", "experience", "hp", "max_hp", "weapon_level", "status", "rune_charges", "max_rune_charges", "inventory", "equipment", "rune" };
    pub const stack = [_][]const u8{ "id", "uses" };
    pub const quest = [_][]const u8{ "scenario", "money", "block", "quests" };
    pub const quest_entry = [_][]const u8{ "id", "state", "receipt" };
    pub const world = [_][]const u8{ "block", "map", "room", "x", "y", "camera_x", "camera_y", "facing", "travel_receipt", "battle_receipt" };
    pub const hq = [_][]const u8{ "stage", "recruit", "tablet_cursor", "screen", "room", "rooms", "services", "revision" };
    pub const mode = [_][]const u8{ "kind", "battle", "duel", "minigame", "war" };
    pub const battle = [_][]const u8{ "round", "receipt", "active_party" };
    pub const duel = [_][]const u8{ "id", "phase", "gauge" };
    pub const minigame = [_][]const u8{ "id", "seed", "step" };
    pub const war = [_][]const u8{ "id", "handoff" };
    pub const pending = [_][]const u8{ "receipt", "owner", "content_revision", "effects" };
    pub const effect = [_][]const u8{ "kind", "id", "amount", "value" };
};

fn requireKeys(object: std.json.ObjectMap, keys: []const []const u8, label: []const u8) !void {
    _ = label;
    for (keys) |key| if (!object.contains(key)) return error.MissingField;
}

fn objectAt(object: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    const value = object.get(key) orelse return error.MissingField;
    if (value != .object) return error.UnexpectedToken;
    return value.object;
}

fn arrayAt(object: std.json.ObjectMap, key: []const u8) ![]std.json.Value {
    const value = object.get(key) orelse return error.MissingField;
    if (value != .array) return error.UnexpectedToken;
    return value.array.items;
}

fn optionalObjectAt(object: std.json.ObjectMap, key: []const u8) !?std.json.ObjectMap {
    const value = object.get(key) orelse return error.MissingField;
    return switch (value) {
        .null => null,
        .object => |map| map,
        else => error.UnexpectedToken,
    };
}

fn eachObject(object: std.json.ObjectMap, key: []const u8, keys: []const []const u8) !void {
    const entries = try arrayAt(object, key);
    for (entries) |entry| {
        if (entry != .object) return error.UnexpectedToken;
        try requireKeys(entry.object, keys, key);
    }
}

/// Reject a current-version document that omits any declared field.
pub fn validatePresence(root: std.json.Value) !void {
    if (root != .object) return error.InvalidCampaign;
    const top = root.object;
    try requireKeys(top, &Presence.top, "campaign");
    try requireKeys(try objectAt(top, "content"), &Presence.content_ref, "content");
    const roster = try objectAt(top, "roster");
    try requireKeys(roster, &Presence.roster, "roster");
    const members = try arrayAt(roster, "members");
    for (members) |member| {
        if (member != .object) return error.UnexpectedToken;
        try requireKeys(member.object, &Presence.member, "member");
        const stacks = try arrayAt(member.object, "inventory");
        for (stacks) |stack| {
            if (stack != .object) return error.UnexpectedToken;
            try requireKeys(stack.object, &Presence.stack, "inventory slot");
        }
    }
    const quest = try objectAt(top, "quest");
    try requireKeys(quest, &Presence.quest, "quest");
    const quests = try arrayAt(quest, "quests");
    for (quests) |entry| {
        if (entry != .object) return error.UnexpectedToken;
        try requireKeys(entry.object, &Presence.quest_entry, "quest entry");
    }
    const world = try objectAt(top, "world");
    try requireKeys(world, &Presence.world, "world");
    const hq = try objectAt(top, "hq");
    try requireKeys(hq, &Presence.hq, "hq");
    const mode = try objectAt(top, "mode");
    try requireKeys(mode, &Presence.mode, "mode");
    if (try optionalObjectAt(mode, "battle")) |battle| try requireKeys(battle, &Presence.battle, "battle resume");
    if (try optionalObjectAt(mode, "duel")) |duel| try requireKeys(duel, &Presence.duel, "duel resume");
    if (try optionalObjectAt(mode, "minigame")) |game| try requireKeys(game, &Presence.minigame, "minigame resume");
    if (try optionalObjectAt(mode, "war")) |war| try requireKeys(war, &Presence.war, "war resume");
    if (try optionalObjectAt(top, "pending")) |pending| {
        try requireKeys(pending, &Presence.pending, "pending");
        try eachObject(pending, "effects", &Presence.effect);
    }
}
