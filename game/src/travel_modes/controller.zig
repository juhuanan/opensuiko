const std = @import("std");
const routes = @import("route_transitions");
const events = @import("event_runtime");

const source_routes = @import("travel_data").navigation.scripted_routes;
pub const Direction = source_routes.Direction;
pub const first_crossing = source_routes.first_crossing;
pub const Point = struct { x: u16, y: u16 };
pub const Mode = enum { land, scripted, pending, acknowledged };
pub const TravelEntry = struct {
    id: []const u8,
    content_sha256: []const u8,
    location: []const u8,
    position: Point,
    heading: Direction,
};
pub const TransitionPlan = struct {
    entry_id: []const u8,
    content_sha256: []const u8,
    origin: routes.Origin,
    request: routes.Request,
    plan: routes.TransitionPlan,
    construction_before: events.StoryState,
    current_before: events.StoryState,
    receipt: u64,
};
pub const TravelResult = struct { entry_id: []const u8, content_sha256: []const u8, receipt: u64, plan: TransitionPlan };
const sequences = source_routes.sequences;

// Snapshot has no borrowed slices and may be persisted by the host with the entry and content identities.
pub const Snapshot = struct {
    version: u8 = 1,
    entry_id: []const u8,
    content_sha256: []const u8,
    location: []const u8,
    mode: Mode = .land,
    position: Point,
    heading: Direction,
    selector: ?u8 = null,
    pair: u8 = 0,
    consumed: u8 = 0,
    remaining: u8 = 0,
    receipt: u64 = 0,
};
pub const Controller = struct {
    entry: TravelEntry,
    state: Snapshot,
    pending: ?TransitionPlan = null,

    pub fn open(entry: TravelEntry) !Controller {
        if (entry.id.len == 0 or entry.content_sha256.len != 64 or entry.location.len == 0) return error.InvalidTravelEntry;
        return .{ .entry = entry, .state = .{ .entry_id = entry.id, .content_sha256 = entry.content_sha256, .location = entry.location, .position = entry.position, .heading = entry.heading } };
    }
    pub fn restore(entry: TravelEntry, state: Snapshot) !Controller {
        var self = try open(entry);
        if (state.version != 1 or !std.mem.eql(u8, state.entry_id, entry.id) or !std.mem.eql(u8, state.content_sha256, entry.content_sha256) or !std.mem.eql(u8, state.location, entry.location) or state.remaining > 15 or state.mode == .pending or (state.mode == .acknowledged and state.receipt == 0)) return error.InvalidTravelSnapshot;
        if (state.mode == .scripted) {
            const selector = state.selector orelse return error.InvalidTravelSnapshot;
            if (selector >= sequences.len or state.pair > sequences[selector].len) return error.InvalidTravelSnapshot;
            if (state.pair == sequences[selector].len) {
                if (state.consumed != 0) return error.InvalidTravelSnapshot;
            } else if (state.consumed >= sequences[selector][state.pair].count) return error.InvalidTravelSnapshot;
        } else if (state.selector != null or state.pair != 0 or state.consumed != 0 or state.remaining != 0) return error.InvalidTravelSnapshot;
        self.state = state;
        return self;
    }
    // Caller supplies a source-selected 0x4e selector; no entry effects are replayed.
    pub fn startRoute(self: *Controller, selector: u8) !void {
        if (self.state.mode != .land or selector >= sequences.len) return error.InvalidRouteStart;
        self.state.mode = .scripted;
        self.state.selector = selector;
        self.state.pair = 0;
        self.state.consumed = 0;
        self.state.remaining = 0;
    }
    // One call is one source update. Script owns input until its terminator.
    pub fn tickRoute(self: *Controller) !bool {
        if (self.state.mode != .scripted) return error.RouteNotActive;
        if (self.state.remaining > 0) {
            self.state.remaining -= 1;
            return false;
        }
        const seq = sequences[self.state.selector.?];
        if (self.state.pair == seq.len) {
            self.state.mode = .land;
            self.state.selector = null;
            self.state.pair = 0;
            self.state.consumed = 0;
            return true;
        }
        const pair = seq[self.state.pair];
        self.state.heading = pair.direction;
        switch (pair.direction) {
            .north => self.state.position.y -%= 1,
            .east => self.state.position.x +%= 1,
            .south => self.state.position.y +%= 1,
            .west => self.state.position.x -%= 1,
        }
        self.state.consumed += 1;
        if (self.state.consumed == pair.count) {
            self.state.pair += 1;
            self.state.consumed = 0;
        }
        // The world root executes the first countdown update in the starting frame.
        self.state.remaining = 15;
        return false;
    }
    // Caller supplies position/direction from the ordinary field or world controller.
    // Packet order is source dispatch order; nonmatching or ineligible entries are skipped.
    pub fn select(self: *Controller, packet: routes.Packet, construction: events.StoryState, current: events.StoryState, trigger: routes.RequestTrigger, event_flags_low2: u2) !?TransitionPlan {
        if (self.state.mode != .land or self.pending != null) return error.TravelBusy;
        if (!std.mem.eql(u8, self.entry.content_sha256, packet.content_sha256)) return error.TravelIdentityMismatch;
        try routes.validate(packet);
        for (packet.routes) |route| {
            if (!std.mem.eql(u8, route.origin.location_id, self.entry.location)) continue;
            const request: routes.Request = .{ .route_id = route.id, .origin_id = self.entry.location, .trigger = trigger, .event_flags_low2 = event_flags_low2 };
            _ = routes.plan(packet, &current, request) catch |err| switch (err) {
                error.RouteTriggerMismatch, error.RouteIneligible, error.TransitionBarrierBlocked => continue,
                else => return err,
            };
            return try self.propose(packet, construction, current, request);
        }
        return null;
    }
    // The host retains prefix execution and construction; this object proposes, never applies it.
    pub fn propose(self: *Controller, packet: routes.Packet, construction: events.StoryState, current: events.StoryState, request: routes.Request) !TransitionPlan {
        if (self.state.mode != .land or self.pending != null) return error.TravelBusy;
        if (!std.mem.eql(u8, self.entry.content_sha256, packet.content_sha256) or !std.mem.eql(u8, self.entry.location, request.origin_id)) return error.TravelIdentityMismatch;
        const plan = try routes.plan(packet, &current, request);
        const source = packet.route(request.route_id).?;
        const receipt = std.math.add(u64, self.state.receipt, 1) catch return error.TravelReceiptOverflow;
        const result = TransitionPlan{ .entry_id = self.entry.id, .content_sha256 = packet.content_sha256, .origin = source.origin, .request = request, .plan = plan, .construction_before = construction, .current_before = current, .receipt = receipt };
        self.pending = result;
        self.state.mode = .pending;
        return result;
    }
    // Restore a pending proposal only by revalidating its source request and facts.
    pub fn restorePending(entry: TravelEntry, snapshot: Snapshot, packet: routes.Packet, construction: events.StoryState, current: events.StoryState, request: routes.Request) !Controller {
        if (snapshot.mode != .pending) return error.InvalidTravelSnapshot;
        var base = snapshot;
        base.mode = .land;
        var self = try restore(entry, base);
        _ = try self.propose(packet, construction, current, request);
        return self;
    }
    // The caller supplies the committed destination identity after consuming the result.
    pub fn continueAfterResult(self: *Controller, entry: TravelEntry, receipt: u64) !void {
        if (self.state.mode != .acknowledged or self.state.receipt != receipt) return error.InvalidTravelReceipt;
        var next = try open(entry);
        next.state.receipt = receipt;
        self.* = next;
    }
    pub fn acknowledge(self: *Controller, receipt: u64) !TravelResult {
        const plan = self.pending orelse return error.NoPendingTransition;
        if (self.state.mode != .pending or receipt != plan.receipt) return error.InvalidTravelReceipt;
        self.state.receipt = receipt;
        self.state.mode = .acknowledged;
        self.pending = null;
        return .{ .entry_id = plan.entry_id, .content_sha256 = plan.content_sha256, .receipt = receipt, .plan = plan };
    }
};
