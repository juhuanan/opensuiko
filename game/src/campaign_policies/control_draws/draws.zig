//! Logical draw state.
//!
//! A "logical draw" is one resource-sampling draw request that an existing view
//! list produces — not a pixel and not a diagnostic overlay.  The three
//! ordinary views this package follows are:
//!
//!   * `game/src/world_view.zig::compose` (water layer, cell layer, hero pose);
//!   * `game/src/field_view.zig::drawScene` (stable depth/index sort of
//!     `room.draws`, story-gated `hidden_by` pieces, hero/follower actors merged
//!     with the source `piece.depth > actor.depth` rule);
//!   * `game/src/battle_world_art.zig::compose` (procedural shadows, then the
//!     depth-sorted quad list with its per-quad light).
//!
//! The pause/party menu has no resource draw list in this snapshot: it draws
//! text through a sink.  Its logical identity is the row count, the screen tag
//! and the cursor, recorded here as `text_rows`/`screen`, so a reload can prove
//! the party owner restored the same logical frame.
//!
//! Composers are duck-typed (`anytype`): they read exactly the fields the shared
//! views read, so the production types can be passed without importing raylib
//! and a test can pass a small fixture.  A draw's `resource` is an index into a
//! qualified resource manifest; an unqualified resource is a typed refusal, not
//! a silently skipped draw.  Captured state stores the exact resource identity
//! (id + sha256) that the plan referenced, so a checkpoint restore that binds a
//! different content revision fails instead of producing a plausible frame.

const std = @import("std");

pub const schema_id = "suikoden-logical-draws/1";
pub const encoding_id = "suikoden-logical-draws-encoding/1";
pub const max_entries: usize = 4096;
pub const max_resources: usize = 8;
pub const max_actors: usize = 8;

pub const Rect = struct { x: i32 = 0, y: i32 = 0, w: i32 = 0, h: i32 = 0 };

pub const Kind = enum(u8) {
    world_tile = 0,
    world_pose = 1,
    field_scene = 2,
    field_actor = 3,
    battle_quad = 4,
};

pub const flags_scene_hidden = 0;

pub const Entry = struct {
    kind: Kind = .world_tile,
    resource: u16 = 0,
    layer: u8 = 0,
    flags: u8 = 0,
    src: Rect = .{},
    dx: i32 = 0,
    dy: i32 = 0,
    dw: i32 = 0,
    dh: i32 = 0,
    depth: i32 = 0,
    light: [3]u16 = .{ 128, 128, 128 },
};

pub const ResourceKind = enum(u8) {
    world_art = 0,
    world_map = 1,
    field_package = 2,
    battle_overlay = 3,
    party_catalogue = 4,
    atlas = 5,
};

pub const Resource = struct {
    id: []const u8,
    kind: ResourceKind,
    schema: []const u8,
    sha256: [32]u8,
};

pub const ResourceEntry = struct {
    id: []const u8,
    kind: []const u8,
    schema: []const u8,
    sha256: []const u8,
    qualified: bool = true,
};

pub const Unqualified = struct { id: []const u8, reason: []const u8 };

pub const Manifest = struct {
    schema: []const u8,
    resources: []const ResourceEntry,
    unqualified: []const Unqualified,
};

pub const Resources = struct {
    list: [max_resources]Resource = undefined,
    qualified: [max_resources]bool = @splat(false),
    len: usize = 0,

    pub fn fromManifest(manifest: Manifest) !Resources {
        if (!std.mem.eql(u8, manifest.schema, schema_id)) return error.UnsupportedDrawManifest;
        if (manifest.resources.len > max_resources) return error.TooManyDrawResources;
        var result = Resources{};
        for (manifest.resources, 0..) |entry, i| {
            result.list[i] = .{
                .id = entry.id,
                .kind = std.meta.stringToEnum(ResourceKind, entry.kind) orelse return error.UnknownDrawResourceKind,
                .schema = entry.schema,
                .sha256 = try parseHex(entry.sha256),
            };
            result.qualified[i] = entry.qualified;
        }
        result.len = manifest.resources.len;
        return result;
    }

    pub fn find(self: *const Resources, id: []const u8) ?u16 {
        for (self.list[0..self.len], 0..) |resource, i| {
            if (std.mem.eql(u8, resource.id, id)) return @intCast(i);
        }
        return null;
    }

    pub fn require(self: *const Resources, id: []const u8) !u16 {
        const index = self.find(id) orelse return error.MissingDrawResource;
        if (!self.qualified[index]) return error.UnqualifiedLogicalDraw;
        return index;
    }

    pub fn isQualified(self: *const Resources, index: u16) bool {
        return index < self.len and self.qualified[index];
    }

    pub fn count(self: *const Resources) usize {
        return self.len;
    }

    /// Bind the whole table to one content digest.  The checkpoint's
    /// `context_digest` is the exact content binding the loader already
    /// enforces, so every logical draw resource is bound to it rather than to a
    /// guessed per-file hash.
    pub fn bindAllHex(self: *Resources, digest_hex: []const u8) !void {
        const digest = try parseHex(digest_hex);
        for (self.list[0..self.len]) |*resource| resource.sha256 = digest;
    }
};

pub const Plan = struct {
    entries: [max_entries]Entry = undefined,
    len: u16 = 0,
    shadows: u16 = 0,
    text_rows: u16 = 0,
    screen: u8 = 0,

    pub fn reset(self: *Plan) void {
        self.len = 0;
        self.shadows = 0;
        self.text_rows = 0;
        self.screen = 0;
    }

    pub fn add(self: *Plan, entry: Entry) !void {
        if (self.len >= max_entries) return error.LogicalDrawOverflow;
        self.entries[self.len] = entry;
        self.len += 1;
    }

    pub fn slice(self: *const Plan) []const Entry {
        return self.entries[0..self.len];
    }

    pub fn digest(self: *const Plan, resources: *const Resources) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        var header: [9]u8 = undefined;
        @memset(&header, 0);
        header[0] = self.screen;
        writeU16(header[1..3], self.shadows);
        writeU16(header[3..5], self.text_rows);
        writeU16(header[5..7], self.len);
        header[7] = @intCast(resources.len);
        hash.update(encoding_id);
        hash.update("\n");
        hash.update(header[0..8]);
        for (resources.list[0..resources.len]) |resource| {
            const id_len: u8 = @intCast(resource.id.len);
            hash.update(&[_]u8{id_len});
            hash.update(resource.id);
            hash.update(&resource.sha256);
        }
        for (self.entries[0..self.len]) |entry| {
            var record: [47]u8 = undefined;
            @memset(&record, 0);
            record[0] = @backingInt(entry.kind);
            writeU16(record[1..3], entry.resource);
            record[3] = entry.layer;
            record[4] = entry.flags;
            writeI32(record[5..9], entry.src.x);
            writeI32(record[9..13], entry.src.y);
            writeI32(record[13..17], entry.src.w);
            writeI32(record[17..21], entry.src.h);
            writeI32(record[21..25], entry.dx);
            writeI32(record[25..29], entry.dy);
            writeI32(record[29..33], entry.dw);
            writeI32(record[33..37], entry.dh);
            writeI32(record[37..41], entry.depth);
            writeU16(record[41..43], entry.light[0]);
            writeU16(record[43..45], entry.light[1]);
            writeU16(record[45..47], entry.light[2]);
            hash.update(&record);
        }
        var out: [32]u8 = undefined;
        hash.final(&out);
        return out;
    }
};

fn writeU16(into: []u8, value: u16) void {
    std.mem.writeInt(u16, into[0..2], value, .little);
}
fn writeI32(into: []u8, value: i32) void {
    std.mem.writeInt(i32, into[0..4], value, .little);
}
fn parseHex(text: []const u8) ![32]u8 {
    if (text.len != 64) return error.InvalidDrawDigest;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch return error.InvalidDrawDigest;
    return out;
}

pub fn hex32(value: [32]u8) [64]u8 {
    const alphabet = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (value, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

// ---------------------------------------------------------------------------
// Composers.  Each one mirrors one existing view list; order is the draw order.
// ---------------------------------------------------------------------------

/// Mirrors `game/src/world_view.zig::compose` (lines 106-121 at the snapshot).
fn rectOf(value: anytype) Rect {
    return .{ .x = value.x, .y = value.y, .w = value.w, .h = value.h };
}

pub fn composeWorld(plan: *Plan, resources: *const Resources, art_resource: u16, data: anytype, travel: anytype, visual: anytype) !void {
    if (!resources.isQualified(art_resource)) return error.UnqualifiedLogicalDraw;
    if (travel.boat or travel.scripted or visual.clip >= 4 or
        visual.frame >= data.clips[visual.clip].len or
        (visual.water_tile != 10 and visual.water_tile != 20)) return error.InvalidWorldView;
    plan.reset();
    const origin = travel.originPixels();
    const offset_x = @mod(origin.x, 16);
    const offset_y = @mod(origin.y, 16);
    const columns: i32 = if (offset_x == 0) 20 else 21;
    const rows: i32 = if (offset_y == 0) 15 else 16;
    for (0..2) |layer| {
        for (0..@as(usize, @intCast(rows))) |y| {
            for (0..@as(usize, @intCast(columns))) |x| {
                const column = @mod(@divFloor(origin.x, 16) + @as(i32, @intCast(x)), 160);
                const row = @mod(@divFloor(origin.y, 16) + @as(i32, @intCast(y)), 120);
                const cell_index: usize = @intCast(row * 160 + column);
                if (cell_index >= visual.cells.len) return error.InvalidWorldView;
                const tile = if (layer == 0) visual.water_tile else visual.cells[cell_index];
                if (tile >= data.tiles.len) return error.InvalidWorldView;
                try plan.add(.{
                    .kind = .world_tile,
                    .resource = art_resource,
                    .layer = @intCast(layer),
                    .src = rectOf(data.tiles[tile]),
                    .dx = @as(i32, @intCast(x)) * 16 - offset_x,
                    .dy = @as(i32, @intCast(y)) * 16 - offset_y,
                    .dw = data.tiles[tile].w,
                    .dh = data.tiles[tile].h,
                });
            }
        }
    }
    const pose = data.clips[visual.clip][visual.frame].pose;
    if (pose >= data.poses.len) return error.InvalidWorldView;
    try plan.add(.{
        .kind = .world_pose,
        .resource = art_resource,
        .layer = 2,
        .src = rectOf(data.poses[pose]),
        .dx = data.hero_x,
        .dy = data.hero_y,
        .dw = data.poses[pose].w,
        .dh = data.poses[pose].h,
    });
}

pub const Actor = struct {
    resource: u16,
    rect: Rect,
    /// Canvas coordinates, already including the camera offset (the shared
    /// `sprite()` helper rounds these).
    x: f32,
    y: f32,
    depth: f32,
    /// Logical identity of the actor resource (e.g. the dialogue atlas).  The
    /// caller keeps it qualified; an actor is never a diagnostic rectangle.
    qualified: bool = true,
};

/// Mirrors `game/src/field_view.zig::drawScene` (lines 26-54 at the snapshot):
/// stable (depth, index) sort, `hidden_by` gated by the current story, actors
/// merged with the source strict-`>` depth rule.  Authored NPC markers
/// (lines 56-68) are prototype conveniences and are deliberately not logical
/// draws.
pub fn composeField(plan: *Plan, resources: *const Resources, atlas_resource: u16, room: anytype, story: anytype, scene_ticks: u32, origin_x: f32, origin_y: f32, actors: []const Actor) !void {
    if (!resources.isQualified(atlas_resource)) return error.UnqualifiedLogicalDraw;
    if (room.draws.len > max_entries) return error.LogicalDrawOverflow;
    if (actors.len > max_actors) return error.TooManyDrawActors;
    plan.reset();
    var order: [max_entries]u16 = undefined;
    const count = room.draws.len;
    for (0..count) |i| order[i] = @intCast(i);
    // Stable insertion sort by (depth, index) — the comparator is total, so
    // stability is not needed for equal depths, but insertion keeps it.
    var i: usize = 1;
    while (i < count) : (i += 1) {
        const value = order[i];
        var j = i;
        while (j > 0 and room.draws[order[j - 1]].depth > room.draws[value].depth) : (j -= 1) order[j] = order[j - 1];
        order[j] = value;
    }
    var sorted_actors: [max_actors]Actor = undefined;
    @memcpy(sorted_actors[0..actors.len], actors);
    var a: usize = 1;
    while (a < actors.len) : (a += 1) {
        const value = sorted_actors[a];
        var j = a;
        while (j > 0 and sorted_actors[j - 1].depth > value.depth) : (j -= 1) sorted_actors[j] = sorted_actors[j - 1];
        sorted_actors[j] = value;
    }
    var next_actor: usize = 0;
    for (order[0..count]) |index| {
        const piece = room.draws[index].sample(scene_ticks);
        if (piece.hidden_by) |flag| if (story.has(flag)) continue;
        while (next_actor < actors.len and @as(f32, @floatFromInt(piece.depth)) > sorted_actors[next_actor].depth) : (next_actor += 1) {
            try addActor(plan, resources, sorted_actors[next_actor]);
        }
        try plan.add(.{
            .kind = .field_scene,
            .resource = atlas_resource,
            .src = rectOf(piece.rect),
            .dx = @intFromFloat(@round(origin_x + @as(f32, @floatFromInt(piece.x)))),
            .dy = @intFromFloat(@round(origin_y + @as(f32, @floatFromInt(piece.y)))),
            .dw = piece.rect.w,
            .dh = piece.rect.h,
            .depth = piece.depth,
        });
    }
    while (next_actor < actors.len) : (next_actor += 1) try addActor(plan, resources, sorted_actors[next_actor]);
}

fn addActor(plan: *Plan, resources: *const Resources, actor: Actor) !void {
    if (!actor.qualified or !resources.isQualified(actor.resource)) return error.UnqualifiedLogicalDraw;
    try plan.add(.{
        .kind = .field_actor,
        .resource = actor.resource,
        .flags = 1,
        .src = actor.rect,
        .dx = @intFromFloat(@round(actor.x)),
        .dy = @intFromFloat(@round(actor.y)),
        .dw = actor.rect.w,
        .dh = actor.rect.h,
        .depth = @intFromFloat(@round(actor.depth)),
    });
}

/// Mirrors `game/src/battle_world_art.zig::compose`: procedural shadows are
/// counted (they sample no resource) and the depth-sorted quad list is kept in
/// order with its per-quad light.
pub fn composeBattle(plan: *Plan, resources: *const Resources, atlas_resource: u16, list: anytype) !void {
    if (!resources.isQualified(atlas_resource)) return error.UnqualifiedLogicalDraw;
    if (list.length > max_entries) return error.LogicalDrawOverflow;
    plan.reset();
    if (list.shadows.len > std.math.maxInt(u16)) return error.LogicalDrawOverflow;
    plan.shadows = @intCast(list.shadows.len);
    for (list.quads[0..list.length], 0..) |quad, index| {
        const rect = quad.sprite.rect;
        try plan.add(.{
            .kind = .battle_quad,
            .resource = atlas_resource,
            .layer = 0,
            .flags = if (index == 0) 1 else 0,
            .src = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h },
            .dx = quad.x,
            .dy = quad.y,
            .dw = quad.w,
            .dh = quad.h,
            .depth = quad.y,
            .light = .{ quad.light[0], quad.light[1], quad.light[2] },
        });
    }
}

/// Party owner: the existing view is a text sink, so the logical frame is the
/// screen tag and row count.  No resource draw is synthesized for text.
pub fn composeParty(plan: *Plan, screen: u8, rows: u16) !void {
    if (rows > 64) return error.InvalidPartyLogicalDraw;
    plan.reset();
    plan.screen = screen;
    plan.text_rows = rows;
}

// ---------------------------------------------------------------------------
// Captured state: the reload equality contract.
// ---------------------------------------------------------------------------

fn usesResource(plan: *const Plan, resource: u16) bool {
    for (plan.entries[0..plan.len]) |entry| {
        if (entry.resource == resource) return true;
    }
    return false;
}

pub const Binding = struct {
    id: []const u8,
    sha256: [32]u8,
};

pub const State = struct {
    schema: []const u8 = schema_id,
    owner: u8 = 0,
    screen: u8 = 0,
    entry_count: u16 = 0,
    shadows: u16 = 0,
    text_rows: u16 = 0,
    plan_digest: [32]u8 = @splat(0),
    resources: []const Binding = &.{},

    pub fn capture(allocator: std.mem.Allocator, owner: u8, plan: *const Plan, resources: *const Resources) !State {
        // Unqualified resources may sit in the table (the packet records why),
        // but a plan that references one is refused by the composers.
        const bindings = try allocator.alloc(Binding, resources.len);
        for (resources.list[0..resources.len], 0..) |resource, index| {
            bindings[index] = .{ .id = resource.id, .sha256 = resource.sha256 };
        }
        return .{
            .owner = owner,
            .screen = plan.screen,
            .entry_count = plan.len,
            .shadows = plan.shadows,
            .text_rows = plan.text_rows,
            .plan_digest = plan.digest(resources),
            .resources = bindings,
        };
    }

    /// The reload contract: the recomposed plan must have the same logical
    /// shape and digest, and every resource must still be the exact content
    /// revision captured with it.
    pub fn verify(self: *const State, plan: *const Plan, resources: *const Resources) !void {
        if (!std.mem.eql(u8, self.schema, schema_id)) return error.UnsupportedDrawState;
        if (self.entry_count != plan.len or self.screen != plan.screen or
            self.shadows != plan.shadows or self.text_rows != plan.text_rows) return error.DrawPlanMismatch;
        if (self.resources.len != resources.len) return error.DrawResourceMismatch;
        for (self.resources, 0..) |binding, index| {
            if (!resources.qualified[index] and usesResource(plan, @intCast(index))) return error.UnqualifiedLogicalDraw;
            const current = resources.list[index];
            if (!std.mem.eql(u8, binding.id, current.id) or !std.mem.eql(u8, &binding.sha256, &current.sha256)) return error.DrawResourceMismatch;
        }
        const digest = plan.digest(resources);
        if (!std.mem.eql(u8, &self.plan_digest, &digest)) return error.DrawPlanMismatch;
    }

    pub fn jsonStringify(self: State, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("schema");
        try writer.write(self.schema);
        try writer.objectField("owner");
        try writer.write(self.owner);
        try writer.objectField("screen");
        try writer.write(self.screen);
        try writer.objectField("entry_count");
        try writer.write(self.entry_count);
        try writer.objectField("shadows");
        try writer.write(self.shadows);
        try writer.objectField("text_rows");
        try writer.write(self.text_rows);
        const hex = hex32(self.plan_digest);
        try writer.objectField("plan_digest");
        try writer.write(&hex);
        try writer.objectField("resources");
        try writer.beginArray();
        for (self.resources) |binding| {
            try writer.beginObject();
            try writer.objectField("id");
            try writer.write(binding.id);
            const sha = hex32(binding.sha256);
            try writer.objectField("sha256");
            try writer.write(&sha);
            try writer.endObject();
        }
        try writer.endArray();
        try writer.endObject();
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !State {
        return jsonParseFromValue(allocator, try std.json.innerParse(std.json.Value, allocator, source, options), options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !State {
        _ = options;
        if (source != .object) return error.UnexpectedToken;
        const object = source.object;
        var result = State{};
        if (object.get("schema")) |value| {
            result.schema = switch (value) {
                .string => |text| try allocator.dupe(u8, text),
                else => return error.UnexpectedToken,
            };
        }
        if (object.get("owner")) |value| result.owner = @intCast(value.integer);
        if (object.get("screen")) |value| result.screen = @intCast(value.integer);
        if (object.get("entry_count")) |value| result.entry_count = @intCast(value.integer);
        if (object.get("shadows")) |value| result.shadows = @intCast(value.integer);
        if (object.get("text_rows")) |value| result.text_rows = @intCast(value.integer);
        if (object.get("plan_digest")) |value| {
            result.plan_digest = parseHex(switch (value) {
                .string => |text| text,
                else => return error.UnexpectedToken,
            }) catch return error.UnexpectedToken;
        }
        if (object.get("resources")) |value| {
            if (value != .array) return error.UnexpectedToken;
            const list = try allocator.alloc(Binding, value.array.items.len);
            for (value.array.items, 0..) |item, index| {
                if (item != .object) return error.UnexpectedToken;
                const id = item.object.get("id") orelse return error.MissingField;
                const sha = item.object.get("sha256") orelse return error.MissingField;
                list[index] = .{
                    .id = try allocator.dupe(u8, switch (id) {
                        .string => |text| text,
                        else => return error.UnexpectedToken,
                    }),
                    .sha256 = parseHex(switch (sha) {
                        .string => |text| text,
                        else => return error.UnexpectedToken,
                    }) catch return error.UnexpectedToken,
                };
            }
            result.resources = list;
        }
        return result;
    }
};

// ---------------------------------------------------------------------------
// Internal checks.  The production-type and manifest-vector checks live in
// its focused test suite.
// ---------------------------------------------------------------------------

const FakeRoom = struct {
    draws: []const FakeDraw,
};
const FakeDraw = struct {
    rect: Rect = .{ .x = 1, .y = 2, .w = 3, .h = 4 },
    x: i32 = 0,
    y: i32 = 0,
    depth: i32 = 0,
    hidden_by: ?u8 = null,
    frames: []const FakeFrame = &.{},
    fn sample(self: FakeDraw, elapsed: u32) FakeDraw {
        if (self.frames.len == 0) return self;
        var total: u32 = 0;
        for (self.frames) |frame| total += frame.ticks;
        var tick = elapsed % total;
        var result = self;
        for (self.frames) |frame| {
            if (tick < frame.ticks) {
                result.rect = frame.rect;
                result.x = frame.x;
                result.y = frame.y;
                return result;
            }
            tick -= frame.ticks;
        }
        unreachable;
    }
};
const FakeFrame = struct { rect: Rect = .{}, x: i32 = 0, y: i32 = 0, ticks: u16 = 1 };
const FakeStory = struct {
    flags: u8 = 0,
    fn has(self: FakeStory, flag: u8) bool {
        return self.flags & flag != 0;
    }
};

const zeros = "0000000000000000000000000000000000000000000000000000000000000000";
const ones = "1111111111111111111111111111111111111111111111111111111111111111";

fn fakeResources() !Resources {
    const manifest = Manifest{
        .schema = schema_id,
        .resources = &.{
            .{ .id = "field.journey.package", .kind = "field_package", .schema = "suikoden-room/7", .sha256 = zeros },
            .{ .id = "field.authored_marker", .kind = "field_package", .schema = "authored/0", .sha256 = ones, .qualified = false },
        },
        .unqualified = &.{},
    };
    return Resources.fromManifest(manifest);
}

test "field order is the stable depth/index order with story gating" {
    var resources = try fakeResources();
    const draws = [_]FakeDraw{
        .{ .depth = -1, .x = 1 },
        .{ .depth = 5, .x = 2 },
        .{ .depth = 5, .x = 3 },
        .{ .depth = 2, .x = 4, .hidden_by = 1 },
    };
    const room = FakeRoom{ .draws = &draws };
    var plan = Plan{};
    try composeField(&plan, &resources, 0, room, FakeStory{ .flags = 0 }, 0, 0, 24, &.{});
    try std.testing.expectEqual(@as(u16, 4), plan.len);
    try std.testing.expectEqual(@as(i32, 1), plan.entries[0].dx);
    try std.testing.expectEqual(@as(i32, 24), plan.entries[0].dy);
    try std.testing.expectEqual(@as(i32, 4), plan.entries[1].dx);
    try std.testing.expectEqual(@as(i32, 2), plan.entries[2].dx);
    try std.testing.expectEqual(@as(i32, 3), plan.entries[3].dx);
    // The hidden piece disappears once its flag is set.
    try composeField(&plan, &resources, 0, room, FakeStory{ .flags = 1 }, 0, 0, 24, &.{});
    try std.testing.expectEqual(@as(u16, 3), plan.len);
}

test "actors merge with the source strict-greater depth rule" {
    var resources = try fakeResources();
    const draws = [_]FakeDraw{.{ .depth = 4, .x = 1 }};
    const room = FakeRoom{ .draws = &draws };
    var plan = Plan{};
    const actors = [_]Actor{
        .{ .resource = 0, .rect = .{ .x = 9, .y = 9, .w = 8, .h = 8 }, .x = 10, .y = 20, .depth = 4.0 },
        .{ .resource = 0, .rect = .{ .x = 9, .y = 9, .w = 8, .h = 8 }, .x = 30, .y = 40, .depth = 5.0 },
    };
    try composeField(&plan, &resources, 0, room, FakeStory{}, 0, 0, 24, &actors);
    try std.testing.expectEqual(@as(u16, 3), plan.len);
    // Equal depth: the scene piece is drawn first, then the actor.
    try std.testing.expectEqual(Kind.field_scene, plan.entries[0].kind);
    try std.testing.expectEqual(Kind.field_actor, plan.entries[1].kind);
    try std.testing.expectEqual(@as(i32, 10), plan.entries[1].dx);
    try std.testing.expectEqual(Kind.field_actor, plan.entries[2].kind);
    try std.testing.expectEqual(@as(i32, 30), plan.entries[2].dx);
    // An unqualified actor resource is refused.
    var bad = actors;
    bad[0].qualified = false;
    try std.testing.expectError(error.UnqualifiedLogicalDraw, composeField(&plan, &resources, 0, room, FakeStory{}, 0, 0, 24, &bad));
    // An unqualified atlas resource is refused.
    try std.testing.expectError(error.UnqualifiedLogicalDraw, composeField(&plan, &resources, 1, room, FakeStory{}, 0, 0, 24, &.{}));
}

test "battle composition keeps quad order and counts procedural shadows" {
    var resources = try fakeResources();
    const shadows = [_]struct { radius_x: f32 = 1, radius_y: f32 = 1 }{ .{}, .{} };
    const quad = struct {
        sprite: struct { rect: Rect },
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        light: [3]u16,
    }{ .sprite = .{ .rect = .{ .x = 4, .y = 5, .w = 6, .h = 7 } }, .x = 8, .y = 9, .w = 10, .h = 11, .light = .{ 120, 130, 140 } };
    var quads = [_]@TypeOf(quad){ quad, quad };
    const list = .{ .shadows = &shadows, .quads = &quads, .length = 2 };
    var plan = Plan{};
    try composeBattle(&plan, &resources, 0, list);
    try std.testing.expectEqual(@as(u16, 2), plan.shadows);
    try std.testing.expectEqual(@as(u16, 2), plan.len);
    try std.testing.expectEqual(@as(u16, 1), plan.entries[0].flags);
    try std.testing.expectEqual(@as(i32, 8), plan.entries[1].dx);
    try std.testing.expectEqual(@as([3]u16, .{ 120, 130, 140 }), plan.entries[1].light);
}

test "capture and verify reject a substituted resource or plan" {
    var resources = try fakeResources();
    var plan = Plan{};
    const draws = [_]FakeDraw{.{}};
    try composeField(&plan, &resources, 0, FakeRoom{ .draws = &draws }, FakeStory{}, 0, 0, 24, &.{});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const state = try State.capture(arena.allocator(), 1, &plan, &resources);
    try state.verify(&plan, &resources);
    // Same shape, different resource revision: the reload is refused.
    var other = resources;
    other.list[0].sha256[0] ^= 0xff;
    try std.testing.expectError(error.DrawResourceMismatch, state.verify(&plan, &other));
    // Same resources, different logical frame.
    plan.entries[0].dx += 1;
    try std.testing.expectError(error.DrawPlanMismatch, state.verify(&plan, &resources));
}

test "state survives a JSON round trip" {
    var resources = try fakeResources();
    var plan = Plan{};
    try composeParty(&plan, 7, 11);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const state = try State.capture(arena.allocator(), 2, &plan, &resources);
    const text = try std.json.Stringify.valueAlloc(arena.allocator(), state, .{});
    const parsed = try std.json.parseFromSlice(State, arena.allocator(), text, .{});
    try parsed.value.verify(&plan, &resources);
    try std.testing.expectEqual(@as(u8, 2), parsed.value.owner);
    try std.testing.expectEqual(@as(u16, 11), parsed.value.text_rows);
}

test "party logical frame is text only" {
    var plan = Plan{};
    try composeParty(&plan, 3, 8);
    try std.testing.expectEqual(@as(u16, 0), plan.len);
    try std.testing.expectEqual(@as(u16, 8), plan.text_rows);
    try std.testing.expectEqual(@as(u8, 3), plan.screen);
    try std.testing.expectError(error.InvalidPartyLogicalDraw, composeParty(&plan, 0, 65));
}
