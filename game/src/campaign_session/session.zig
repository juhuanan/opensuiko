//! Campaign session integration.
//!
//! This module is the single host glue between the content graph / item ledger /
//! mode-result policy modules and the existing world and battle owners.  It has
//! no simulated state machine of its own: every projection is read from the
//! canonical `world_travel.State`, and every committed effect is a projection of
//! a state the production owners already produced.  A result is admitted through
//! `mode_result.Host.begin` and published through `mode_result.Host.commit`; the
//! owner state is never replaced by the projection.
//!
//! The transaction store is heap-owned so copying a `Session` does not copy a
//! multi-kilobyte model and cannot overflow a test or platform stack.

const std = @import("std");
const battle = @import("battle");
const field = @import("field");
const travel = @import("world_travel");
const world = @import("world");
const content_graph = @import("campaign_policies").content_graph;
const content_graph_data = @import("campaign_policies_data").content_graph;
const mode_result = @import("campaign_policies").mode_result;

pub const schema = "suikoden-campaign/1";

pub const Snapshot = struct {
    host: ?mode_result.Snapshot = null,
    battles: u32 = 0,
    items: u32 = 0,
    travels: u32 = 0,
    graph_digest: [64]u8 = @splat(0),
    draw_digest: [32]u8 = @splat(0),
};

pub const Campaign = struct {
    host: ?*mode_result.Host = null,
    /// Pre-transaction store retained explicitly for the battle family.  The
    /// battle owner starts from a world state, so the Session records the store
    /// at `.battle_started`, not after the return tick.
    battle_origin: ?*mode_result.Store = null,
    content_sha: mode_result.Sha = .{},
    battles: u32 = 0,
    items: u32 = 0,
    travels: u32 = 0,
    graph_checked: bool = false,
    graph_digest: [64]u8 = @splat(0),
    draw_digest: [32]u8 = @splat(0),
    /// Digest of the initial owned state, retained with the campaign host so a
    /// copied Session stays small.  Not transaction state and never published.
    initial_digest: [64]u8 = @splat(0),
    recorded_steps: usize = 0,

    pub fn deinit(self: *Campaign, allocator: std.mem.Allocator) void {
        if (self.host) |host| allocator.destroy(host);
        if (self.battle_origin) |origin| allocator.destroy(origin);
        self.host = null;
        self.battle_origin = null;
    }

    /// Load and validate the reviewed content graph once, then validate the
    /// identities the ordinary route actually consumes.  A mismatched version
    /// or a missing party/item identity is a typed blocker, never a default.
    /// Deep-copy the transactional part for a rollback boundary.  The graph
    /// digest and counters are values; the host and battle origin are the only
    /// heap owners and are duplicated explicitly.
    pub fn clone(self: *const Campaign, allocator: std.mem.Allocator) !Campaign {
        var result = self.*;
        result.host = null;
        result.battle_origin = null;
        if (self.host) |host| {
            const copy = try allocator.create(mode_result.Host);
            copy.* = host.*;
            result.host = copy;
        }
        if (self.battle_origin) |origin| {
            const copy = try allocator.create(mode_result.Store);
            copy.* = origin.*;
            result.battle_origin = copy;
        }
        return result;
    }

    pub fn ensure(self: *Campaign, allocator: std.mem.Allocator, state: *const travel.State) !void {
        if (self.graph_checked) return;
        const graph = try content_graph.open(allocator, content_graph_data.json);
        defer graph.release();
        const digest = graph.exactDigest();
        @memcpy(&self.graph_digest, digest[0..64]);
        if (self.content_sha.isZero()) self.content_sha = try contentSha(allocator, state);
        // Roster characters are the reviewed 78-record domain.  The six owned
        // route members must resolve by the same names the battle owner uses.
        for (state.combat.progress.party) |member| _ = try graph.character(member.id);
        // Item identities come from the reviewed item-ledger graph.  A stack
        // whose id is not in the graph stays a typed unbound identity rather
        // than being silently projected as zero.
        for (state.combat.progress.party) |member| {
            for (member.inventory.slots) |maybe| if (maybe) |stack| {
                _ = try graph.item(@tagName(stack.id));
            };
        }
        self.graph_checked = true;
    }

    pub fn noteBattleStart(self: *Campaign, allocator: std.mem.Allocator, state: *const travel.State, shared: [7]?[]const u8) !void {
        if (self.battle_origin != null) return error.PendingBattleOrigin;
        const revision = if (self.host) |host| host.store.revision else 0;
        const origin = try allocator.create(mode_result.Store);
        errdefer allocator.destroy(origin);
        origin.* = try storeOf(state, shared, revision, receiptsOf(state, 0));
        self.battle_origin = origin;
    }

    pub fn commitBattle(self: *Campaign, allocator: std.mem.Allocator, state: *const travel.State, shared: [7]?[]const u8, draws: world.Draws) !void {
        const origin_ptr = self.battle_origin orelse return error.MissingBattleOrigin;
        defer {
            allocator.destroy(origin_ptr);
            self.battle_origin = null;
        }
        const origin = origin_ptr.*;
        const post_receipts = receiptsOf(state, 0);
        const post = try storeOf(state, shared, origin.revision, post_receipts);
        var result = mode_result.Result{
            .schema = try mode_result.Id.init(mode_result.result_schema),
            .owner = .battle,
            .kind = .battle_result,
            .entry_id = try mode_result.Id.init(state.link.travel.selected orelse return error.MissingWorldEncounter),
            .receipt = post_receipts[1],
            .expected = expectedOf(origin, self.content_sha, 1),
            .effect_count = 4,
            .effects = @splat(.{}),
        };
        result.effects[0] = .{ .kind = .money, .payload = .{ .money = post.money } };
        result.effects[1] = .{ .kind = .party, .payload = .{ .party = post.party } };
        result.effects[2] = .{ .kind = .draws, .payload = .{ .draws = .{ .cursor = draws.cursor, .bios = draws.bios_state } } };
        result.effects[3] = .{ .kind = .camera, .payload = .{ .camera = post.camera } };
        try self.publish(allocator, origin, result);
        self.battles +%= 1;
    }

    pub fn commitItem(self: *Campaign, allocator: std.mem.Allocator, pre: *const travel.State, post: *const travel.State, pre_shared: [7]?[]const u8, post_shared: [7]?[]const u8, pre_party_revision: u64, post_party_revision: u64) !void {
        const revision = if (self.host) |host| host.store.revision else 0;
        const pre_receipts = receiptsOf(pre, pre_party_revision);
        const post_receipts = receiptsOf(post, post_party_revision);
        const origin = try storeOf(pre, pre_shared, revision, pre_receipts);
        const after = try storeOf(post, post_shared, revision, post_receipts);
        var result = mode_result.Result{
            .schema = try mode_result.Id.init(mode_result.result_schema),
            .owner = .party,
            .kind = .party_item,
            .entry_id = try mode_result.Id.init("world_pause_preparation"),
            .receipt = post_receipts[2],
            .expected = expectedOf(origin, self.content_sha, 2),
            .effect_count = 0,
            .effects = @splat(.{}),
        };
        self.addEffect(&result, .{ .kind = .party, .payload = .{ .party = after.party } }) catch return error.TooManyEffects;
        for (pre_shared, post_shared, 0..) |before, now, index| {
            if (std.meta.eql(before, now)) continue;
            const id = if (now) |value| try mode_result.Id.init(value) else null;
            self.addEffect(&result, .{ .kind = .shared, .payload = .{ .shared = .{ .index = @intCast(index), .item = id } } }) catch return error.TooManyEffects;
        }
        try self.publish(allocator, origin, result);
        self.items +%= 1;
    }

    pub fn commitTravel(self: *Campaign, allocator: std.mem.Allocator, pre: *const travel.State, post: *const travel.State, entry_id: []const u8) !void {
        const revision = if (self.host) |host| host.store.revision else 0;
        const pre_receipts = receiptsOf(pre, 0);
        const post_receipts = receiptsOf(post, 0);
        const origin = try storeOf(pre, [_]?[]const u8{ null, null, null, null, null, null, null }, revision, pre_receipts);
        const after = try storeOf(post, [_]?[]const u8{ null, null, null, null, null, null, null }, revision, post_receipts);
        var result = mode_result.Result{
            .schema = try mode_result.Id.init(mode_result.result_schema),
            .owner = .travel,
            .kind = .travel_route,
            .entry_id = try mode_result.Id.init(entry_id),
            .receipt = post_receipts[0],
            .expected = expectedOf(origin, self.content_sha, 0),
            .effect_count = 0,
            .effects = @splat(.{}),
        };
        self.addEffect(&result, .{ .kind = .camera, .payload = .{ .camera = after.camera } }) catch return error.TooManyEffects;
        for (origin.story, after.story, 0..) |before, now, index| {
            if (before == now) continue;
            self.addEffect(&result, .{ .kind = .story, .payload = .{ .story = .{ .offset = @intCast(index), .byte = now } } }) catch return error.UnsupportedStoryBatch;
        }
        try self.publish(allocator, origin, result);
        self.travels +%= 1;
    }

    fn addEffect(self: *Campaign, result: *mode_result.Result, effect: mode_result.Effect) !void {
        _ = self;
        if (result.effect_count >= mode_result.max_effects) return error.TooManyEffects;
        result.effects[result.effect_count] = effect;
        result.effect_count += 1;
    }

    fn publish(self: *Campaign, allocator: std.mem.Allocator, origin: mode_result.Store, result: mode_result.Result) !void {
        if (self.host == null) {
            const host = try allocator.create(mode_result.Host);
            errdefer allocator.destroy(host);
            host.* = try mode_result.Host.init(origin, self.content_sha);
            self.host = host;
        }
        if (self.host.?.pending != null) return error.PendingOwnerBusy;
        self.host.?.store = origin;
        try self.host.?.begin(result);
        _ = try self.host.?.commit();
    }

    pub fn snapshot(self: *const Campaign) !?Snapshot {
        if (self.host == null and self.battles == 0 and self.items == 0 and self.travels == 0) return null;
        const host = if (self.host) |value| value else return error.MissingModeResultHost;
        return .{
            .host = mode_result.Snapshot.capture(host.*),
            .battles = self.battles,
            .items = self.items,
            .travels = self.travels,
            .graph_digest = self.graph_digest,
            .draw_digest = self.draw_digest,
        };
    }

    pub fn restore(self: *Campaign, allocator: std.mem.Allocator, saved: Snapshot, state: *const travel.State) !void {
        self.battles = saved.battles;
        self.items = saved.items;
        self.travels = saved.travels;
        self.draw_digest = saved.draw_digest;
        // Legacy saves have no campaign envelope and no graph digest.  They
        // stay loadable; no host is fabricated for them.
        if (saved.host == null and std.mem.allEqual(u8, &saved.graph_digest, 0)) return;
        try self.ensure(allocator, state);
        if (!std.mem.allEqual(u8, &saved.graph_digest, 0) and !std.mem.eql(u8, &saved.graph_digest, &self.graph_digest)) return error.WorldSessionSourceMismatch;
        if (saved.host) |saved_host| {
            const host = try allocator.create(mode_result.Host);
            errdefer allocator.destroy(host);
            host.* = try mode_result.Host.fromSnapshot(saved_host, self.content_sha);
            if (self.host) |old| allocator.destroy(old);
            self.host = host;
        }
    }
};

pub fn contentSha(allocator: std.mem.Allocator, state: *const travel.State) !mode_result.Sha {
    const bytes = try std.json.Stringify.valueAlloc(allocator, .{
        .map = state.link.content,
        .art = state.art,
        .overlay = state.overlay,
        .combat = state.combat.content,
    }, .{});
    defer allocator.free(bytes);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return .{ .bytes = hash };
}

fn receiptsOf(state: *const travel.State, party_revision: u64) [3]u64 {
    return .{ state.travel_receipt, state.battle_receipt, party_revision };
}

fn expectedOf(store: mode_result.Store, content_sha: mode_result.Sha, owner_index: usize) mode_result.Expected {
    return .{
        .content_sha256 = content_sha,
        .revision = store.revision,
        .money = store.money,
        .price = store.price_quote,
        .roster = mode_result.rosterDigest(store),
        .ledger = mode_result.ledgerDigest(store),
        .story = mode_result.storyDigest(store),
        .camera = store.camera,
        .pending_owner = null,
        .receipt = store.receipts[owner_index],
    };
}

pub fn storeOf(state: *const travel.State, shared: [7]?[]const u8, revision: u64, receipts: [3]u64) !mode_result.Store {
    var store = mode_result.Store{
        .revision = revision,
        .money = state.combat.progress.money,
        .price_quote = null,
        .camera = cameraOf(state),
        .shared = @splat(null),
        .story_bound = state.combat.progress.story.scenario != null,
        .draws_cursor = 0,
        .draws_bios = null,
        .receipts = receipts,
    };
    if (state.combat.progress.story.scenario) |story| store.story = story.scenario;
    for (shared, 0..) |maybe, index| {
        if (maybe) |id| store.shared[index] = try mode_result.Id.init(id);
    }
    if (state.combat.content.systems) |systems| {
        for (0..state.combat.partyCount()) |index| {
            store.party.members[index] = try memberOf(state.combat, index, systems);
        }
        store.party.count = @intCast(state.combat.partyCount());
    } else return error.UnboundEquipmentIdentity;
    try store.validate();
    return store;
}

fn cameraOf(state: *const travel.State) mode_result.Camera {
    return .{
        .x = state.link.travel.camera.x,
        .y = state.link.travel.camera.y,
        .facing = switch (state.link.travel.heading) {
            .north => .north,
            .east => .east,
            .south => .south,
            .west => .west,
        },
        .place = switch (state.link.travel.mode) {
            .world, .field_pending, .battle_pending => .world,
            .field => .field,
            .battle => .battle,
        },
    };
}

fn memberOf(combat: *const battle.State, index: usize, systems: battle.systems.Systems) !mode_result.Member {
    const owned = combat.ownedMember(index);
    var member = mode_result.Member{
        .id = try mode_result.Id.init(owned.id),
        .hp = owned.hp,
        .max_hp = owned.max_hp,
        .status = switch (owned.status) {
            .healthy => .healthy,
            .poisoned => .poisoned,
            .unconscious => .unconscious,
        },
        .level = owned.level,
        .experience = owned.experience,
        .weapon_level = owned.weapon_level,
    };
    for (owned.inventory.slots, 0..) |maybe, slot| if (maybe) |stack| {
        if (slot >= member.inventory.len) return error.InventoryOverflow;
        member.inventory[slot] = .{ .item = try mode_result.Id.init(@tagName(stack.id)), .uses = stack.uses, .identified = stack.identified };
    };
    try equip(&member.equipment, owned.loadout.head, 0, systems);
    try equip(&member.equipment, owned.loadout.body, 1, systems);
    try equip(&member.equipment, owned.loadout.shield, 2, systems);
    try equip(&member.equipment, owned.loadout.accessory_one, 3, systems);
    try equip(&member.equipment, owned.loadout.accessory_two, 4, systems);
    try member.validate();
    return member;
}

fn equip(slots: *[5]?mode_result.Id, index: ?usize, position: usize, systems: battle.systems.Systems) !void {
    const item_index = index orelse return;
    if (item_index >= systems.equipment.len) return error.UnboundEquipmentIdentity;
    slots[position] = try mode_result.Id.init(systems.equipment[item_index].id);
}
