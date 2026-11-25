//! Travel-boundary handler: Viki, the Blinking Mirror and the Escape
//! Talisman share one session, one before-fact comparison and one commit.
//!
//! The handler owns no canonical state.  It is opened by a *source request*
//! (`Request.viki_event` is the stage-C event opcode 0x43 with selector 0xFF and
//! index 3; `Request.item_use` is the item-use dispatch of item 81 or 73), it
//! revalidates the caller's before-facts when the choice is committed, and it
//! returns an arrival plan the host reconstructs.  There is deliberately no
//! key-opened destination menu: without the request the session does not open.
//!
//! Lifetime: `Session.viki`/`Session.mirror` borrow the validated catalogue, and
//! plan strings borrow either the catalogue or the caller's `Entry`.  A caller
//! must keep the `Loaded` packet and the entry alive while a session exists.
//! `save`/`load` copy everything into the caller's allocator.
//!
//! Rejections are atomic: a failed `commit` leaves the pending proposal in place
//! (retryable) and publishes nothing.  A settled receipt never settles twice.

const std = @import("std");
const event_runtime = @import("event_runtime");
const cat = @import("destination.zig");

pub const schema = "suikoden-teleport-session/1";
/// The catalogue types and the `load` entry point; re-exported so a host only
/// needs this module.
pub const catalogue = cat;
pub const loadCatalogue = cat.load;
pub const Point = cat.Point;
pub const Family = enum { viki, blinking_mirror, escape_talisman };
pub const ResultKind = enum { travel_teleport, travel_mirror };
pub const Phase = enum { selecting, pending, acknowledged, cancelled };
pub const Input = enum { up, down, left, right, confirm, cancel };
pub const Owner = enum { field };
pub const RequestKind = enum { viki_event, item_use };
pub const SelectorKind = enum { world_point, field_area, retained_point };

pub const blinking_mirror_result_id = "main_us_11_blinking_mirror";
pub const escape_result_id = "main_us_11_escape_talisman";
pub const escape_scenario_byte: u8 = 0x1B6 - 0x190;
pub const max_entry_id = 96;
pub const max_snapshot_bytes = 256 * 1024;

const tier_ids = [_][]const u8{
    "blinking_mirror_tier_0",
    "blinking_mirror_tier_1",
    "blinking_mirror_tier_2",
    "blinking_mirror_tier_3",
    "blinking_mirror_tier_4",
};

/// The admission the host must have produced from the source.  A caller cannot
/// fabricate it: `open` compares it with the catalogue's admitted request.
pub const Request = struct {
    kind: RequestKind,
    /// Opcode 0x43 operands (`selector` 0xFF, `index` 3) and the source words
    /// the request entry and callback table must carry.
    selector: u8 = 0,
    index: u8 = 0,
    callback: u32 = 0,
    request_entry: u32 = 0,
    room: u8 = 0,
    /// Item-use dispatch facts.
    item_id: u16 = 0,
    handler: u8 = 0,
    slot: u8 = 0,
};

pub const ItemState = struct {
    item_id: u16 = 0,
    slot: u8 = 0,
    present: bool = false,
    owner: []const u8 = "",
};

/// A world point the host already resolved into a field arrival.  The escape
/// talisman re-uses the accepted point retained in `game_state+0`/`+2`; the
/// host owns the region-table lookup and passes the resolved record.
pub const RetainedPoint = struct {
    region: u8,
    point: u8,
    area: []const u8,
    room: u8,
    source_spawn: Point,
    spawn: Point,
};

pub const Entry = struct {
    entry_id: []const u8,
    content_sha256: []const u8,
    /// Caller-assigned receipt for this entry.  It must be greater than every
    /// receipt already settled for the same owner.
    receipt: u64,
    settled_receipt: u64 = 0,
    money: u32 = 0,
    story: event_runtime.StoryState = .{},
    story_bound: bool = true,
    /// `game_state+0x2E`: 1 is the world map (outside), 0 is a field room.
    world_mode: u8 = 0,
    item: ItemState = .{},
    /// `game_state+0x34`, the castle stage the Blinking Mirror reads.
    castle_stage: u8 = 0,
    retained_point: ?RetainedPoint = null,
};

pub const Facts = struct {
    content_sha256: []const u8,
    entry_id: []const u8,
    receipt: u64,
    money: u32,
    story: [240]u8,
    world_mode: u8,
    item: ItemState,
    castle_stage: u8,
    retained_point: ?RetainedPoint,
};

pub const Selector = struct {
    kind: SelectorKind,
    region: u8,
    point: u8 = 0,
    area_index: u8 = 0,
};

pub const Plan = struct {
    family: Family,
    destination_id: []const u8,
    name: []const u8,
    selector: Selector,
    area: []const u8,
    room: u8,
    source_spawn: Point,
    spawn: Point,
    world_camera: ?Point = null,
    result_kind: ResultKind,
    result_entry_id: []const u8,
};

pub const Proposal = struct {
    receipt: u64,
    family: Family,
    plan: Plan,
    expected: Facts,
};

pub const Commit = struct {
    receipt: u64,
    family: Family,
    plan: Plan,
};

pub const Return = struct {
    entry_id: []const u8,
    receipt: u64,
    owner: Owner = .field,
    settled: u64 = 0,
};

pub const Event = union(enum) {
    none,
    cancelled: Return,
    confirmed: Proposal,
};

pub const PendingSelection = struct {
    kind: Family = .viki,
    index: u8 = 0,
};

pub const Session = struct {
    viki: *const cat.Viki,
    mirror: *const cat.Mirror,
    family: Family,
    request: Request,
    entry: Entry,
    phase: Phase = .selecting,
    page: u8 = 0,
    row: u8 = 0,
    selection: PendingSelection = .{ .kind = .viki },
    proposal: ?Proposal = null,
    settled: u64 = 0,

    /// Open a source-admitted session.  The request must be the exact admitted
    /// token; anything else is `NotAdmitted`.
    pub fn open(viki: *const cat.Viki, mirror: *const cat.Mirror, request: Request, entry: Entry) !Session {
        try viki.validate();
        try mirror.validate();
        try validateEntry(entry);
        const family = try familyFor(request);
        switch (family) {
            .viki => try admitViki(request),
            .blinking_mirror, .escape_talisman => try admitItem(mirror, request, entry, family),
        }
        return .{
            .viki = viki,
            .mirror = mirror,
            .family = family,
            .request = request,
            .entry = entry,
        };
    }

    fn validateEntry(entry: Entry) !void {
        if (entry.entry_id.len == 0 or entry.entry_id.len > max_entry_id) return error.InvalidEntry;
        if (entry.content_sha256.len != 64) return error.InvalidEntry;
        if (!entry.story_bound or !std.mem.eql(u8, entry.story.schema, "suikoden-event-story/1")) return error.UnboundStory;
        if (entry.receipt == 0) return error.InvalidReceipt;
        if (entry.receipt <= entry.settled_receipt) return error.RepeatedReceipt;
        if (entry.world_mode > 1) return error.InvalidEntry;
        if (entry.item.present and entry.item.item_id == 0) return error.InvalidEntry;
    }

    fn familyFor(request: Request) !Family {
        return switch (request.kind) {
            .viki_event => .viki,
            .item_use => switch (request.item_id) {
                cat.blinking_mirror_item => .blinking_mirror,
                cat.escape_item => .escape_talisman,
                else => error.NotAdmitted,
            },
        };
    }

    fn admitViki(request: Request) !void {
        if (request.selector != cat.viki_callback_selector) return error.NotAdmitted;
        if (request.index != cat.viki_callback_index) return error.NotAdmitted;
        if (request.callback != cat.viki_request_entry) return error.NotAdmitted;
        if (request.request_entry != cat.viki_request_entry) return error.NotAdmitted;
        if (request.room != cat.viki_admission_room) return error.NotAdmitted;
    }

    fn admitItem(mirror: *const cat.Mirror, request: Request, entry: Entry, family: Family) !void {
        const item = mirror.itemById(request.item_id) orelse return error.NotAdmitted;
        if (request.handler != item.handler) return error.NotAdmitted;
        if (request.item_id == cat.blinking_mirror_item) {
            if (family != .blinking_mirror) return error.NotAdmitted;
            if (item.gate.world_mode_required != 1) return error.InvalidCatalogue;
            if (entry.world_mode != 1) return error.OutsideRequired;
        } else {
            if (family != .escape_talisman) return error.NotAdmitted;
            if (item.gate.world_mode_required != 0) return error.InvalidCatalogue;
            if (entry.world_mode != 0) return error.InsideRequired;
            const extra = item.gate.extra orelse return error.InvalidCatalogue;
            if (extra.scenario_byte != escape_scenario_byte) return error.InvalidCatalogue;
            if (entry.story.scenario[extra.scenario_byte] & extra.mask == 0) return error.EscapeUnavailable;
        }
        if (!entry.item.present) return error.ItemNotInSlot;
        if (entry.item.item_id != request.item_id) return error.ItemNotInSlot;
        if (entry.item.slot != request.slot) return error.ItemNotInSlot;
    }

    /// Eligible destinations in source order.  Locked destinations are absent;
    /// they are never shown and cannot be confirmed.
    pub fn eligible(self: *const Session, out: *[cat.max_destinations]u8) []const u8 {
        if (self.family != .viki) return out[0..0];
        var count: usize = 0;
        for (self.viki.destinations, 0..) |destination, index| {
            if (self.entry.story.scenario[destination.unlock.byte_index] & destination.unlock.mask != 0) {
                out[count] = @intCast(index);
                count += 1;
            }
        }
        return out[0..count];
    }

    pub fn visibleCount(self: *const Session) usize {
        var buffer: [cat.max_destinations]u8 = undefined;
        return self.eligible(&buffer).len;
    }

    fn rowsOnPage(self: *const Session, count: usize) !usize {
        const first = @as(usize, self.page) * cat.rows_per_page;
        if (count == 0) {
            if (self.page != 0) return error.InvalidCursor;
            return 0;
        }
        if (first >= count) return error.InvalidCursor;
        return @min(cat.rows_per_page, count - first);
    }

    fn clampRow(self: *Session, count: usize) !void {
        const rows = try self.rowsOnPage(count);
        if (rows == 0) {
            self.row = 0;
            return;
        }
        if (self.row >= rows) self.row = @intCast(rows - 1);
    }

    pub fn tick(self: *Session, input: Input) !Event {
        if (self.phase != .selecting) return error.NotSelecting;
        if (input == .cancel) return .{ .cancelled = try self.cancel() };
        if (self.family != .viki) {
            return switch (input) {
                .confirm => .{ .confirmed = try self.proposeItem() },
                else => .none,
            };
        }
        var indexes: [cat.max_destinations]u8 = undefined;
        const list = self.eligible(&indexes);
        try self.clampRow(list.len);
        switch (input) {
            .up => {
                if (self.row > 0) self.row -= 1;
            },
            .down => {
                const next = @as(usize, self.page) * cat.rows_per_page + self.row + 1;
                if (next < list.len and self.row + 1 < cat.rows_per_page) self.row += 1;
            },
            .left => {
                if (self.page > 0) self.page -= 1;
                try self.clampRow(list.len);
            },
            .right => {
                if (list.len > 0) {
                    const last: u8 = @intCast((list.len - 1) / cat.rows_per_page);
                    if (self.page < last) {
                        self.page += 1;
                        try self.clampRow(list.len);
                    }
                }
            },
            .confirm => {
                if (list.len == 0) return error.EmptyList;
                const index = @as(usize, self.page) * cat.rows_per_page + self.row;
                if (index >= list.len) return error.EmptyList;
                return .{ .confirmed = try self.proposeViki(list[index]) };
            },
            .cancel => unreachable,
        }
        return .none;
    }

    /// Confirm a Viki destination by source table index.  The index must be
    /// visible: a locked or unknown destination is a typed rejection.
    pub fn confirmViki(self: *Session, index: u8) !Proposal {
        if (self.family != .viki) return error.NotViki;
        if (self.phase != .selecting) return error.NotSelecting;
        return self.proposeViki(index);
    }

    /// Confirm the single item-family destination (Blinking Mirror tier or the
    /// retained Escape Talisman point).
    pub fn confirmItem(self: *Session) !Proposal {
        if (self.family == .viki) return error.NotItemFamily;
        if (self.phase != .selecting) return error.NotSelecting;
        return self.proposeItem();
    }

    fn proposeViki(self: *Session, index: u8) !Proposal {
        if (self.proposal != null) return error.TravelBusy;
        if (index >= self.viki.destinations.len) return error.UnknownDestination;
        const destination = self.viki.destinations[index];
        if (self.entry.story.scenario[destination.unlock.byte_index] & destination.unlock.mask == 0) return error.LockedDestination;
        const plan = try planForViki(self.viki, index);
        return self.begin(.viki, plan, .{ .kind = .viki, .index = index });
    }

    fn proposeItem(self: *Session) !Proposal {
        if (self.proposal != null) return error.TravelBusy;
        // Re-check the admission facts (the caller may have changed the entry).
        try admitItem(self.mirror, self.request, self.entry, self.family);
        switch (self.family) {
            .blinking_mirror => {
                const tier = self.entry.castle_stage;
                if (tier >= self.mirror.tiers.len) return error.InvalidCastleStage;
                const plan = planForTier(self.mirror, tier);
                return self.begin(.blinking_mirror, plan, .{ .kind = .blinking_mirror, .index = tier });
            },
            .escape_talisman => {
                const retained = self.entry.retained_point orelse return error.UnresolvedRetainedPoint;
                try validateRetained(retained);
                const plan = planForRetained(retained, self.mirror);
                return self.begin(.escape_talisman, plan, .{ .kind = .escape_talisman });
            },
            .viki => unreachable,
        }
    }

    fn begin(self: *Session, family: Family, plan: Plan, selection: PendingSelection) !Proposal {
        if (self.entry.receipt <= self.settled) return error.RepeatedReceipt;
        const proposal = Proposal{
            .receipt = self.entry.receipt,
            .family = family,
            .plan = plan,
            .expected = factsOf(self.entry),
        };
        self.proposal = proposal;
        self.phase = .pending;
        self.selection = selection;
        return proposal;
    }

    /// Commit a pending proposal against the caller's current canonical facts.
    /// Nothing is published on rejection; the pending proposal stays retryable.
    pub fn commit(self: *Session, current: Facts) !Commit {
        const proposal = self.proposal orelse return error.NoPending;
        if (self.phase != .pending) return error.NoPending;
        if (current.receipt <= self.settled) return error.RepeatedReceipt;
        if (current.receipt != proposal.expected.receipt) return error.StaleReceipt;
        if (!std.mem.eql(u8, current.content_sha256, proposal.expected.content_sha256)) return error.StaleContent;
        if (!std.mem.eql(u8, current.entry_id, proposal.expected.entry_id)) return error.StaleEntry;
        if (current.money != proposal.expected.money) return error.StaleMoney;
        if (!std.mem.eql(u8, &current.story, &proposal.expected.story)) return error.StaleStory;
        if (current.world_mode != proposal.expected.world_mode) return error.StaleWorldMode;
        if (!itemEquals(current.item, proposal.expected.item)) return error.StaleItem;
        if (current.castle_stage != proposal.expected.castle_stage) return error.StaleTier;
        if (!retainedEquals(current.retained_point, proposal.expected.retained_point)) return error.StaleRetainedPoint;
        // The destination is re-checked against the current story, not re-rolled.
        switch (self.family) {
            .viki => {
                const destination = self.viki.destinations[self.selection.index];
                if (current.story[destination.unlock.byte_index] & destination.unlock.mask == 0) return error.LockedDestination;
            },
            .blinking_mirror => {
                if (current.castle_stage >= self.mirror.tiers.len) return error.InvalidCastleStage;
            },
            .escape_talisman => {
                const extra = self.mirror.itemById(cat.escape_item).?.gate.extra orelse return error.InvalidCatalogue;
                if (current.story[extra.scenario_byte] & extra.mask == 0) return error.EscapeUnavailable;
            },
        }
        self.phase = .acknowledged;
        self.settled = proposal.receipt;
        self.proposal = null;
        return .{ .receipt = proposal.receipt, .family = proposal.family, .plan = proposal.plan };
    }

    /// Cancel returns ownership to the field entry without consuming the
    /// receipt and without touching the catalogue or canonical state.
    pub fn cancel(self: *Session) !Return {
        if (self.phase != .selecting) return error.NotSelecting;
        self.phase = .cancelled;
        return .{
            .entry_id = self.entry.entry_id,
            .receipt = self.entry.receipt,
            .settled = self.settled,
        };
    }
};

fn factsOf(entry: Entry) Facts {
    return .{
        .content_sha256 = entry.content_sha256,
        .entry_id = entry.entry_id,
        .receipt = entry.receipt,
        .money = entry.money,
        .story = entry.story.scenario,
        .world_mode = entry.world_mode,
        .item = entry.item,
        .castle_stage = entry.castle_stage,
        .retained_point = entry.retained_point,
    };
}

pub fn currentFacts(entry: Entry) Facts {
    return factsOf(entry);
}

fn itemEquals(a: ItemState, b: ItemState) bool {
    return a.item_id == b.item_id and a.slot == b.slot and a.present == b.present and
        std.mem.eql(u8, a.owner, b.owner);
}

fn pointEquals(a: Point, b: Point) bool {
    return a.x == b.x and a.y == b.y;
}

fn retainedEquals(a: ?RetainedPoint, b: ?RetainedPoint) bool {
    const left = a orelse return b == null;
    const right = b orelse return false;
    return left.region == right.region and left.point == right.point and left.room == right.room and
        std.mem.eql(u8, left.area, right.area) and
        pointEquals(left.source_spawn, right.source_spawn) and pointEquals(left.spawn, right.spawn);
}

fn validateRetained(retained: RetainedPoint) !void {
    if (retained.region >= 12) return error.InvalidRetainedPoint;
    if (retained.point >= 165) return error.InvalidRetainedPoint;
    if (retained.room >= 64) return error.InvalidRetainedPoint;
    if (!std.mem.endsWith(u8, retained.area, ".BIN")) return error.InvalidRetainedPoint;
    if (retained.source_spawn.x > 255 or retained.source_spawn.y > 255) return error.InvalidRetainedPoint;
    if (retained.spawn.x != retained.source_spawn.x * 8 or retained.spawn.y != retained.source_spawn.y * 8) {
        return error.InvalidRetainedPoint;
    }
}

fn planForViki(viki: *const cat.Viki, index: u8) !Plan {
    const destination = viki.destinations[index];
    const camera = destination.arrival.world_camera orelse return error.InvalidCatalogue;
    return .{
        .family = .viki,
        .destination_id = destination.id,
        .name = destination.name,
        .selector = .{ .kind = .world_point, .region = destination.region, .point = destination.point },
        .area = destination.arrival.area,
        .room = destination.arrival.room,
        .source_spawn = .{ .x = destination.arrival.source_spawn.x, .y = destination.arrival.source_spawn.y },
        .spawn = .{ .x = destination.arrival.spawn.x, .y = destination.arrival.spawn.y },
        .world_camera = .{ .x = camera.x, .y = camera.y },
        .result_kind = .travel_teleport,
        .result_entry_id = cat.viki_content_id,
    };
}

fn planForTier(mirror: *const cat.Mirror, tier: u8) Plan {
    const row = mirror.tiers[tier];
    const item = mirror.itemById(cat.blinking_mirror_item).?;
    return .{
        .family = .blinking_mirror,
        .destination_id = tier_ids[tier],
        .name = item.label,
        .selector = .{ .kind = .field_area, .region = row.region, .area_index = row.area_index },
        .area = row.area,
        .room = row.room,
        .source_spawn = .{ .x = row.source_spawn.x, .y = row.source_spawn.y },
        .spawn = .{ .x = row.spawn.x, .y = row.spawn.y },
        .world_camera = null,
        .result_kind = .travel_mirror,
        .result_entry_id = blinking_mirror_result_id,
    };
}

fn planForRetained(retained: RetainedPoint, mirror: *const cat.Mirror) Plan {
    const item = mirror.itemById(cat.escape_item).?;
    return .{
        .family = .escape_talisman,
        .destination_id = "escape_talisman_retained_point",
        .name = item.label,
        .selector = .{ .kind = .retained_point, .region = retained.region, .point = retained.point },
        .area = retained.area,
        .room = retained.room,
        .source_spawn = .{ .x = retained.source_spawn.x, .y = retained.source_spawn.y },
        .spawn = .{ .x = retained.spawn.x, .y = retained.spawn.y },
        .world_camera = null,
        .result_kind = .travel_mirror,
        .result_entry_id = escape_result_id,
    };
}

fn planEquals(a: Plan, b: Plan) bool {
    if (a.family != b.family or a.room != b.room or a.result_kind != b.result_kind) return false;
    if (a.selector.kind != b.selector.kind or a.selector.region != b.selector.region) return false;
    if (a.selector.point != b.selector.point or a.selector.area_index != b.selector.area_index) return false;
    if (!pointEquals(a.source_spawn, b.source_spawn) or !pointEquals(a.spawn, b.spawn)) return false;
    if (a.world_camera) |left| {
        const right = b.world_camera orelse return false;
        if (!pointEquals(left, right)) return false;
    } else if (b.world_camera != null) return false;
    return std.mem.eql(u8, a.destination_id, b.destination_id) and
        std.mem.eql(u8, a.name, b.name) and
        std.mem.eql(u8, a.area, b.area) and
        std.mem.eql(u8, a.result_entry_id, b.result_entry_id);
}

fn factsEqual(a: Facts, b: Facts) bool {
    return a.receipt == b.receipt and a.money == b.money and a.world_mode == b.world_mode and
        a.castle_stage == b.castle_stage and
        std.mem.eql(u8, &a.story, &b.story) and
        std.mem.eql(u8, a.content_sha256, b.content_sha256) and
        std.mem.eql(u8, a.entry_id, b.entry_id) and
        itemEquals(a.item, b.item) and retainedEquals(a.retained_point, b.retained_point);
}

// ---------------------------------------------------------------------------
// Durable session state
// ---------------------------------------------------------------------------

pub const Snapshot = struct {
    version: u8 = 1,
    family: Family,
    request: Request,
    entry: Entry,
    phase: Phase,
    page: u8,
    row: u8,
    selection: PendingSelection,
    proposal: ?Proposal,
    settled: u64,
};

pub fn snapshot(self: Session) Snapshot {
    return .{
        .family = self.family,
        .request = self.request,
        .entry = self.entry,
        .phase = self.phase,
        .page = self.page,
        .row = self.row,
        .selection = self.selection,
        .proposal = self.proposal,
        .settled = self.settled,
    };
}

pub fn save(self: Session, allocator: std.mem.Allocator) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, snapshot(self), .{});
}

pub const Decoded = struct {
    parsed: std.json.Parsed(Snapshot),
    session: Session,

    pub fn deinit(self: *Decoded) void {
        self.parsed.deinit();
    }
};

pub fn load(allocator: std.mem.Allocator, bytes: []const u8, viki: *const cat.Viki, mirror: *const cat.Mirror) !Decoded {
    if (bytes.len > max_snapshot_bytes) return error.SnapshotTooLarge;
    const parsed = try std.json.parseFromSlice(Snapshot, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const session = try restore(viki, mirror, parsed.value);
    return .{ .parsed = parsed, .session = session };
}

pub fn restore(viki: *const cat.Viki, mirror: *const cat.Mirror, stored: Snapshot) !Session {
    if (stored.version != 1) return error.InvalidSnapshot;
    var session = try Session.open(viki, mirror, stored.request, stored.entry);
    session.phase = stored.phase;
    session.page = stored.page;
    session.row = stored.row;
    session.selection = stored.selection;
    session.settled = stored.settled;
    switch (stored.phase) {
        .selecting, .cancelled => {
            if (stored.proposal != null) return error.InvalidSnapshot;
            if (stored.settled != stored.entry.settled_receipt) return error.InvalidSnapshot;
            if (stored.phase == .selecting) {
                var buffer: [cat.max_destinations]u8 = undefined;
                const count = session.eligible(&buffer).len;
                if (count == 0) {
                    if (stored.page != 0 or stored.row != 0) return error.InvalidSnapshot;
                } else {
                    if (@as(usize, stored.page) * cat.rows_per_page >= count) return error.InvalidSnapshot;
                    try session.clampRow(count);
                    if (session.row != stored.row) return error.InvalidSnapshot;
                }
            }
        },
        .pending => {
            const proposal = stored.proposal orelse return error.InvalidSnapshot;
            if (proposal.receipt != stored.entry.receipt) return error.InvalidSnapshot;
            if (proposal.family != stored.family) return error.InvalidSnapshot;
            if (!factsEqual(proposal.expected, factsOf(stored.entry))) return error.InvalidSnapshot;
            const plan = switch (stored.family) {
                .viki => blk: {
                    if (stored.selection.kind != .viki or stored.selection.index >= viki.destinations.len) return error.InvalidSnapshot;
                    const destination = viki.destinations[stored.selection.index];
                    if (stored.entry.story.scenario[destination.unlock.byte_index] & destination.unlock.mask == 0) return error.InvalidSnapshot;
                    break :blk try planForViki(viki, stored.selection.index);
                },
                .blinking_mirror => blk: {
                    if (stored.selection.kind != .blinking_mirror or stored.selection.index >= mirror.tiers.len) return error.InvalidSnapshot;
                    break :blk planForTier(mirror, stored.selection.index);
                },
                .escape_talisman => blk: {
                    if (stored.selection.kind != .escape_talisman) return error.InvalidSnapshot;
                    const retained = stored.entry.retained_point orelse return error.InvalidSnapshot;
                    try validateRetained(retained);
                    break :blk planForRetained(retained, mirror);
                },
            };
            if (!planEquals(plan, proposal.plan)) return error.InvalidSnapshot;
            if (stored.settled != stored.entry.settled_receipt) return error.InvalidSnapshot;
            session.proposal = proposal;
        },
        .acknowledged => {
            if (stored.proposal != null) return error.InvalidSnapshot;
            if (stored.settled != stored.entry.receipt) return error.InvalidSnapshot;
        },
    }
    return session;
}
