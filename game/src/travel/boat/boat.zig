//! Boat travel: source board/decline, steering, point dispatch,
//! disembark/cleanup and vessel lifetime.
//!
//! The module is a pure consumer of the exported catalogue (`data.zig`), the
//! shared world resolver and the accepted mode-result transaction.
//!
//! Lifetime model:
//! * one source boarding invocation owns one host-generated `entry_id`;
//! * the field request keeps the world mode at boat while the field is active;
//! * the installed cleanup sets world mode foot/selector 255 and retires the
//!   entry id in the host ledger;
//! * a session snapshot from before cleanup is rejected by the current ledger;
//!   reboarding is a new source invocation with a new entry id;
//! * the world heading (movement) and the saved field-facing byte (teardown
//!   0x8012C7A4 -> 0x80171598 -> Hero constructor 0x801347D0) are separate
//!   values.  This module never derives one from the other.
const std = @import("std");
const world = @import("world");
const events = @import("event_runtime");
const mode_result = @import("campaign_policies").mode_result;
const data = @import("data.zig");

pub const session_schema = "suikoden-campaign-boat-session/1";
pub const ledger_schema = "suikoden-campaign-boat-ledger/1";
pub const checkpoint_schema = "suikoden-campaign-boat-checkpoint/1";
pub const max_snapshot_bytes = 32 * 1024;
pub const max_retired = 16;
pub const foot_selector: u8 = 255;

pub const Mode = enum(u8) { foot = 0, boat = 1, scripted = 2 };
pub const WarningStage = enum { none, initial, opening, waiting, closing, closed };

/// Field sprite-facing domain captured by field teardown.  The raw byte is
/// preserved unchanged; `projectSavedFacing` is the explicit port projection to
/// the compass enum used by the mode-result camera.
pub const saved_facing_count = 4;

pub const Facts = struct {
    story: events.StoryState,
    recruitment_tier: u8,
    hero_x: i32,
    hero_y: i32,
    pressed: u32,
    upgrade_flag: bool,

    pub fn validate(self: Facts) !void {
        if (self.recruitment_tier > 4) return error.InvalidRecruitmentTier;
        if (self.hero_x < 0 or self.hero_x > 255 or self.hero_y < 0 or self.hero_y > 255) return error.InvalidHeroPosition;
    }
};

pub const Vessel = struct {
    entry_id: mode_result.Id,
    camera: world.Point,
    heading: world.Direction,
    remaining: u8 = 0,
    upgraded: bool,
    warning: WarningStage = .none,

    pub fn spriteSlot(self: Vessel, packet: data.Packet) u8 {
        return if (self.upgraded) packet.guards.sprite_slot.upgraded else packet.guards.sprite_slot.normal;
    }
};

pub const Pending = struct {
    point_index: u16,
    camera: world.Point,
    story: [240]u8,
    recruitment_tier: u8,
    hero_x: i32,
    hero_y: i32,
    pressed: u32,
    upgraded: bool,
};

pub const Status = enum { underway, awaiting_point, in_field, settled };

pub const Session = struct {
    schema: []const u8 = session_schema,
    status: Status = .settled,
    entry_id: mode_result.Id = .{},
    vessel: ?Vessel = null,
    pending: ?Pending = null,
    receipt: u64 = 0,
    world_mode: Mode = .foot,
    selector: u8 = foot_selector,
    saved_field_facing: ?u8 = null,

    /// Install a freshly boarded vessel after the host committed the board
    /// result.  `receipt` is that result's receipt (expected.receipt + 1).
    pub fn begin(vessel: Vessel, receipt: u64, world_mode: Mode) Session {
        return .{
            .status = .underway,
            .entry_id = vessel.entry_id,
            .vessel = vessel,
            .receipt = receipt,
            .world_mode = world_mode,
        };
    }

    pub fn encode(self: Session, allocator: std.mem.Allocator, packet: data.Packet) ![]u8 {
        try self.validateStructure(packet);
        return std.json.Stringify.valueAlloc(allocator, self, .{});
    }

    pub fn validateStructure(self: Session, packet: data.Packet) !void {
        if (!std.mem.eql(u8, self.schema, session_schema)) return error.InvalidBoatSession;
        if (self.entry_id.isZero()) return error.InvalidBoatSession;
        if (self.receipt == std.math.maxInt(u64)) return error.InvalidBoatSession;
        switch (self.status) {
            .underway => {
                if (self.vessel == null or self.pending != null) return error.InvalidBoatSession;
            },
            .awaiting_point => {
                if (self.vessel == null or self.pending == null) return error.InvalidBoatSession;
            },
            .in_field => {
                if (self.vessel == null or self.pending == null) return error.InvalidBoatSession;
                if (self.saved_field_facing == null) return error.InvalidBoatSession;
            },
            .settled => {
                if (self.vessel != null or self.pending != null) return error.InvalidBoatSession;
                if (self.world_mode != .foot or self.selector != foot_selector) return error.InvalidBoatSession;
            },
        }
        if (self.vessel) |vessel| {
            if (!vessel.entry_id.eql(self.entry_id)) return error.InvalidBoatSession;
            if (vessel.remaining > 16) return error.InvalidBoatSession;
            if (vessel.camera.x < 0 or vessel.camera.y < 0 or
                vessel.camera.x >= @as(i32, packet.water.width) or vessel.camera.y >= @as(i32, packet.water.height)) return error.InvalidBoatSession;
        }
        if (self.pending) |pending| {
            if (@as(usize, pending.point_index) >= packet.points.rows.len) return error.InvalidBoatSession;
            if (pending.recruitment_tier > 4) return error.InvalidBoatSession;
            const point = packet.points.rows[pending.point_index];
            if (point.destination == null) return error.UnsupportedPointDestination;
            if (self.vessel) |vessel| {
                if (pending.camera.x != vessel.camera.x or pending.camera.y != vessel.camera.y) return error.InvalidBoatSession;
            }
            if (self.saved_field_facing) |facing| if (facing >= saved_facing_count) return error.InvalidFieldFacing;
        }
        switch (self.status) {
            .underway, .awaiting_point, .in_field => if (self.world_mode != .boat) return error.InvalidBoatSession,
            .settled => {},
        }
    }

    /// Steer one ordinary update.  Input is consumed only when the interpolation
    /// clock is ready, exactly like the shared world state.
    pub fn steer(self: *Session, packet: data.Packet, direction: ?world.Direction, facts: Facts) !Step {
        if (self.status == .awaiting_point) return error.BoatTransitionPending;
        if (self.status == .in_field) return error.FieldEntryPending;
        if (self.status != .underway) return error.VesselNotAboard;
        try facts.validate();
        const vessel = &(self.vessel orelse return error.VesselNotAboard);
        if (vessel.warning != .none and vessel.remaining == 0) return .{ .warning = vessel.warning };
        var probes: [4]Probe = undefined;
        for (0..4) |index| {
            probes[index] = probeWater(packet, vessel.camera, @fromBackingInt(@as(u2, @intCast(index))), vessel.upgraded);
        }
        if (vessel.remaining == 0) if (direction) |requested| {
            var passable: [4]bool = undefined;
            for (0..4) |index| passable[index] = probes[index] == .pass;
            const decision = world.resolve(requested, vessel.heading, passable);
            if (probeSequenceWarning(probes, requested, vessel.heading)) vessel.warning = .initial;
            vessel.heading = decision.heading;
            if (decision.accepted) {
                const delta = switch (decision.heading) {
                    .north => world.Point{ .x = 0, .y = -1 },
                    .east => world.Point{ .x = 1, .y = 0 },
                    .south => world.Point{ .x = 0, .y = 1 },
                    .west => world.Point{ .x = -1, .y = 0 },
                };
                vessel.camera.x += delta.x;
                vessel.camera.y += delta.y;
                vessel.remaining = 16;
            }
        };
        if (vessel.remaining > 0) vessel.remaining -= 1;
        // Source point dispatch scans the region table in order and takes the
        // first matching 2x2 anchor.
        for (packet.points.rows, 0..) |point, index| {
            if (vessel.camera.x < point.x or vessel.camera.x > point.x + 1) continue;
            if (vessel.camera.y < point.y or vessel.camera.y > point.y + 1) continue;
            if (!packet.pointKindMatches(point.kind, facts.recruitment_tier, &facts.story.scenario)) continue;
            if (point.destination == null) return error.UnsupportedPointDestination;
            self.pending = .{
                .point_index = @intCast(index),
                .camera = vessel.camera,
                .story = facts.story.scenario,
                .recruitment_tier = facts.recruitment_tier,
                .hero_x = facts.hero_x,
                .hero_y = facts.hero_y,
                .pressed = facts.pressed,
                .upgraded = facts.upgrade_flag,
            };
            self.status = .awaiting_point;
            return .{ .point = .{
                .point_index = @intCast(index),
                .point = point,
                .vessel = vessel.*,
                .camera = vessel.camera,
                .receipt = self.receipt,
            } };
        }
        return if (vessel.warning != .none) .{ .warning = vessel.warning } else .none;
    }

    /// Host-owned source window completion drives the five-stage maelstrom
    /// lifecycle.  Movement stays blocked while a stage is active.
    pub fn advanceWarning(self: *Session, input: WarningInput) !WarningStage {
        if (self.status != .underway) return error.VesselNotAboard;
        const vessel = &(self.vessel orelse return error.VesselNotAboard);
        if (vessel.remaining != 0 or vessel.warning == .none) return error.BoatWarningNotReady;
        vessel.warning = switch (vessel.warning) {
            .none => return error.NoBoatWarning,
            .initial => .opening,
            .opening => if (input.opened) .waiting else .opening,
            .waiting => if (input.confirm) .closing else .waiting,
            .closing => if (input.closed) .closed else .closing,
            .closed => .none,
        };
        return vessel.warning;
    }

    /// Field entry: revalidate the before-facts, then publish the field camera
    /// (saved field facing, not the world heading) and the source cleanup.
    /// The world mode stays boat until `settleCleanup`.
    pub fn disembark(
        self: *Session,
        packet: data.Packet,
        expected: mode_result.Expected,
        saved_field_facing: u8,
        facts: Facts,
    ) !DisembarkResult {
        if (self.status != .awaiting_point) return error.NoPointPending;
        const pending = self.pending orelse return error.NoPointPending;
        const vessel = self.vessel orelse return error.NoPointPending;
        if (saved_field_facing >= saved_facing_count) return error.InvalidFieldFacing;
        const point = packet.points.rows[pending.point_index];
        const destination = point.destination orelse return error.UnsupportedPointDestination;
        if (expected.receipt != self.receipt) return error.StaleReceipt;
        if (expected.pending_owner != null) return error.StalePendingOwner;
        if (expected.camera.place != .world or expected.camera.x != pending.camera.x or expected.camera.y != pending.camera.y) return error.StaleCamera;
        if (!std.mem.eql(u8, &pending.story, &facts.story.scenario)) return error.StaleStory;
        if (pending.recruitment_tier != facts.recruitment_tier or pending.hero_x != facts.hero_x or
            pending.hero_y != facts.hero_y or pending.pressed != facts.pressed or
            pending.upgraded != facts.upgrade_flag) return error.StalePointFacts;
        const receipt = std.math.add(u64, expected.receipt, 1) catch return error.TravelReceiptOverflow;
        const facing = try projectSavedFacing(saved_field_facing);
        const result = try resultFor(expected, self.entry_id, receipt, .{
            .x = point.spawn_x,
            .y = point.spawn_y,
            .facing = facing,
            .place = .field,
        });
        self.status = .in_field;
        self.saved_field_facing = saved_field_facing;
        return .{
            .entry_id = self.entry_id,
            .receipt = receipt,
            .point = point,
            .field = .{
                .room = point.room,
                .spawn_x = point.spawn_x,
                .spawn_y = point.spawn_y,
                .destination = destination,
            },
            .cleanup = .{ .world_mode = .foot, .selector = packet.mode.cleanup.selector },
            .saved_field_facing = saved_field_facing,
            .field_facing = facing,
            .vessel = vessel,
            .result = result,
        };
    }

    /// Apply the installed cleanup (world mode 0, selector 255) and retire the
    /// vessel identity in the host ledger.  The field-camera receipt is the
    /// last committed travel receipt.
    pub fn settleCleanup(self: *Session, ledger: *Ledger, receipt: u64) !Settled {
        if (self.status != .in_field) return error.NoFieldEntryPending;
        const expected = std.math.add(u64, self.receipt, 1) catch return error.TravelReceiptOverflow;
        if (receipt != expected) return error.InvalidTravelReceipt;
        try ledger.retire(self.entry_id, receipt);
        self.status = .settled;
        self.vessel = null;
        self.pending = null;
        self.receipt = receipt;
        self.world_mode = .foot;
        self.selector = foot_selector;
        return .{ .entry_id = self.entry_id, .receipt = receipt, .world_mode = .foot, .selector = foot_selector };
    }
};

pub const Probe = enum { pass, blocked, conditional };

pub const WarningInput = struct { opened: bool = false, confirm: bool = false, closed: bool = false };

pub const Step = union(enum) {
    none,
    warning: WarningStage,
    point: PointProposal,
};

pub const PointProposal = struct {
    point_index: u16,
    point: data.Point,
    vessel: Vessel,
    camera: world.Point,
    receipt: u64,
};

pub const Choice = enum { board, decline };

pub const BoardOutcome = struct {
    entry_id: mode_result.Id,
    receipt: u64,
    mode_before: Mode,
    mode_after: ?Mode,
    vessel: ?Vessel,
    result: ?mode_result.Result,
    declined: bool,

    /// Install the session after the host committed the board result.
    pub fn session(self: BoardOutcome) ?Session {
        const vessel = self.vessel orelse return null;
        const mode = self.mode_after orelse return null;
        return Session.begin(vessel, self.receipt, mode);
    }
};

pub const Settled = struct {
    entry_id: mode_result.Id,
    receipt: u64,
    world_mode: Mode,
    selector: u8,
};

pub const FieldRequest = struct {
    room: u8,
    spawn_x: u16,
    spawn_y: u16,
    destination: []const u8,
};

pub const Cleanup = struct {
    world_mode: Mode,
    selector: u8,
};

pub const DisembarkResult = struct {
    entry_id: mode_result.Id,
    receipt: u64,
    point: data.Point,
    field: FieldRequest,
    cleanup: Cleanup,
    /// Raw teardown byte (0..3); the source saves this value and never writes it
    /// from the world heading.
    saved_field_facing: u8,
    /// Explicit port projection used by the mode-result camera.
    field_facing: mode_result.Facing,
    /// Historical pre-cleanup vessel; never authority to resume.
    vessel: Vessel,
    result: mode_result.Result,
};

pub const Ledger = struct {
    schema: []const u8 = ledger_schema,
    settled_receipt: u64 = 0,
    revision: u64 = 0,
    retired_count: u8 = 0,
    retired: [max_retired]mode_result.Id = @splat(mode_result.Id{}),

    pub fn contains(self: Ledger, id: mode_result.Id) bool {
        for (self.retired[0..self.retired_count]) |entry| if (entry.eql(id)) return true;
        return false;
    }

    pub fn retire(self: *Ledger, id: mode_result.Id, receipt: u64) !void {
        if (id.isZero()) return error.InvalidEntryIdentity;
        if (self.contains(id)) return error.EntryAlreadyRetired;
        if (receipt <= self.settled_receipt) return error.StaleSettlementReceipt;
        if (self.retired_count == max_retired) return error.LedgerFull;
        self.retired[self.retired_count] = id;
        self.retired_count += 1;
        self.settled_receipt = receipt;
        self.revision += 1;
    }

    pub fn validate(self: Ledger) !void {
        if (!std.mem.eql(u8, self.schema, ledger_schema)) return error.InvalidBoatLedger;
        if (self.retired_count > max_retired) return error.InvalidBoatLedger;
        for (self.retired[0..self.retired_count], 0..) |entry, index| {
            if (entry.isZero()) return error.InvalidBoatLedger;
            for (self.retired[0..index]) |other| if (other.eql(entry)) return error.InvalidBoatLedger;
        }
    }
};

/// Validate a session against the authoritative ledger.  A vessel snapshot from
/// before cleanup is rejected once its entry id is retired.
pub fn validateAgainst(ledger: *const Ledger, session: Session, packet: data.Packet) !void {
    try ledger.validate();
    try session.validateStructure(packet);
    if (ledger.contains(session.entry_id)) {
        if (session.status != .settled) return error.VesselExpiredAfterCleanup;
        if (session.receipt != ledger.settled_receipt) return error.StaleSettlementReceipt;
        return;
    }
    if (session.status == .settled) return error.MissingVesselRetirement;
    if (session.receipt <= ledger.settled_receipt) return error.StaleSnapshot;
}

pub const LoadedSession = struct {
    parsed: std.json.Parsed(Session),
    session: Session,

    pub fn deinit(self: *LoadedSession) void {
        self.parsed.deinit();
    }
};

pub fn restoreSession(allocator: std.mem.Allocator, ledger: *const Ledger, bytes: []const u8, packet: data.Packet) !LoadedSession {
    if (bytes.len > max_snapshot_bytes) return error.BoatSnapshotTooLarge;
    const parsed = try std.json.parseFromSlice(Session, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try validateAgainst(ledger, parsed.value, packet);
    return .{ .parsed = parsed, .session = parsed.value };
}

pub const Checkpoint = struct {
    schema: []const u8 = checkpoint_schema,
    ledger: Ledger,
    session: Session,
};

pub const Fresh = struct {
    parsed: std.json.Parsed(Checkpoint),
    ledger: Ledger,
    session: Session,

    pub fn deinit(self: *Fresh) void {
        self.parsed.deinit();
    }
};

pub fn saveFresh(allocator: std.mem.Allocator, ledger: Ledger, session: Session, packet: data.Packet) ![]u8 {
    try ledger.validate();
    try validateAgainst(&ledger, session, packet);
    const checkpoint = Checkpoint{ .ledger = ledger, .session = session };
    return std.json.Stringify.valueAlloc(allocator, checkpoint, .{});
}

pub fn loadFresh(allocator: std.mem.Allocator, bytes: []const u8, packet: data.Packet) !Fresh {
    if (bytes.len > max_snapshot_bytes) return error.BoatSnapshotTooLarge;
    const parsed = try std.json.parseFromSlice(Checkpoint, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.schema, checkpoint_schema)) return error.InvalidBoatCheckpoint;
    try validateAgainst(&parsed.value.ledger, parsed.value.session, packet);
    return .{ .parsed = parsed, .ledger = parsed.value.ledger, .session = parsed.value.session };
}

/// Source board/decline continuation.  `board_id` selects the decoded event
/// (for example `vb8_room0_entry0`); `entry_id` is the host-generated identity
/// of this boarding invocation, not a source id.
pub fn board(
    packet: data.Packet,
    ledger: *const Ledger,
    board_id: []const u8,
    entry_id: []const u8,
    current_mode: Mode,
    facts: Facts,
    choice: Choice,
    expected: mode_result.Expected,
) !BoardOutcome {
    const entry = packet.board(board_id) orelse return error.UnknownBoardEntry;
    try facts.validate();
    const id = mode_result.Id.init(entry_id) catch return error.InvalidEntryIdentity;
    if (id.isZero()) return error.InvalidEntryIdentity;
    if (ledger.contains(id)) return error.EntryRetired;
    for (entry.predicate) |term| switch (term.kind) {
        .story_mask_set => {
            if (facts.story.scenario[term.index] & term.mask == 0) return error.StoryGuard;
        },
        .story_mask_clear => {
            if (facts.story.scenario[term.index] & term.mask != 0) return error.StoryGuard;
        },
        .hero_x_range => {
            if (facts.hero_x < @as(i32, term.lower) or facts.hero_x > @as(i32, term.upper)) return error.PositionGuard;
        },
        .hero_y_range => {
            if (facts.hero_y < @as(i32, term.lower) or facts.hero_y > @as(i32, term.upper)) return error.PositionGuard;
        },
        .input_mask => {
            if ((facts.pressed & @as(u32, term.input)) == 0) return error.InputGuard;
        },
    };
    if (choice == .decline) {
        return .{
            .entry_id = id,
            .receipt = expected.receipt,
            .mode_before = current_mode,
            .mode_after = if (entry.decline.world_mode) |value| try modeFromValue(value) else null,
            .vessel = null,
            .result = null,
            .declined = true,
        };
    }
    const mode_after = try modeFromValue(entry.board.world_mode.?);
    const receipt = std.math.add(u64, expected.receipt, 1) catch return error.TravelReceiptOverflow;
    const result = try resultFor(expected, id, receipt, .{
        .x = entry.board.camera_x,
        .y = entry.board.camera_y,
        .facing = .east,
        .place = .world,
    });
    const vessel = Vessel{
        .entry_id = id,
        .camera = .{ .x = entry.board.camera_x, .y = entry.board.camera_y },
        .heading = .east,
        .upgraded = facts.upgrade_flag,
    };
    return .{
        .entry_id = id,
        .receipt = receipt,
        .mode_before = current_mode,
        .mode_after = mode_after,
        .vessel = vessel,
        .result = result,
        .declined = false,
    };
}

pub fn probeWater(packet: data.Packet, camera: world.Point, direction: world.Direction, upgraded: bool) Probe {
    const delta = switch (direction) {
        .north => world.Point{ .x = 0, .y = -1 },
        .east => world.Point{ .x = 1, .y = 0 },
        .south => world.Point{ .x = 0, .y = 1 },
        .west => world.Point{ .x = -1, .y = 0 },
    };
    const x = camera.x + 10 + delta.x;
    const y = camera.y + 8 + delta.y;
    if (x < 0 or y < 0 or x >= @as(i32, packet.water.width) or y >= @as(i32, packet.water.height)) return .blocked;
    const code = packet.water.codes[@intCast(y * @as(i32, packet.water.width) + x)];
    if (code >= packet.guards.water.special_first and code <= packet.guards.water.special_last) {
        return if (upgraded) .pass else .conditional;
    }
    return if (code < packet.guards.water.passable_max) .pass else .blocked;
}

/// The shared resolver probes requested, current heading and the two adjacent
/// directions in that order.  A conditional cell in that attempted sequence
/// requests the maelstrom window (source 0x80127024).
fn probeSequenceWarning(probes: [4]Probe, requested: world.Direction, heading: world.Direction) bool {
    const raw: u8 = @backingInt(requested);
    const order = [4]u8{ raw, @backingInt(heading), if (raw == 0) 3 else raw - 1, raw + 1 };
    var warned = false;
    for (order) |candidate| {
        const probe_index: usize = if (candidate == 4) 3 else candidate;
        switch (probes[probe_index]) {
            .pass => return warned,
            .conditional => warned = true,
            .blocked => {},
        }
    }
    return warned;
}

fn modeFromValue(value: u8) !Mode {
    return switch (value) {
        0 => .foot,
        1 => .boat,
        2 => .scripted,
        else => error.UnsupportedWorldMode,
    };
}

/// Port projection of the raw saved field-facing byte to the compass enum used
/// by the mode-result camera.  The raw byte is retained separately.
pub fn projectSavedFacing(value: u8) !mode_result.Facing {
    return switch (value) {
        0 => .south,
        1 => .north,
        2 => .west,
        3 => .east,
        else => error.InvalidFieldFacing,
    };
}

fn resultFor(expected: mode_result.Expected, entry_id: mode_result.Id, receipt: u64, camera: mode_result.Camera) !mode_result.Result {
    var result = mode_result.Result{
        .schema = mode_result.Id.init(mode_result.result_schema) catch return error.InvalidResult,
        .owner = .travel,
        .kind = .travel_board,
        .entry_id = entry_id,
        .receipt = receipt,
        .expected = expected,
        .effect_count = 1,
    };
    result.effects[0] = .{ .kind = .camera, .payload = .{ .camera = camera } };
    try result.validate();
    return result;
}
