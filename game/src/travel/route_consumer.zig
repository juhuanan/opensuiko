//! Campaign route consumer: cue ownership, ordered prefix commit and
//! destination reconstruction over the source-derived edge catalogue.
//!
//! This is a pure policy module. It never executes an effect, mutates canonical
//! story, loads a room or writes a save: the host acknowledges effects in source
//! order and supplies the story it committed. `begin()` borrows the edge slices
//! from the validated packet, so a consumer must not outlive its packet.
const std = @import("std");
const event_runtime = @import("event_runtime");
pub const edges = @import("route_edges.zig");

pub const schema = "suikoden-campaign-route-consumer/1";
pub const State = enum { idle, effects_pending, committed };

pub const FieldTrigger = struct {
    position: edges.Coordinate,
    direction: ?edges.Direction = null,
};
pub const Trigger = union(enum) {
    field_rectangle: FieldTrigger,
    world_point: edges.Coordinate,
    ordinary_event: void,
};
pub const Cue = struct {
    origin_id: []const u8,
    trigger: Trigger,
    /// Low two event-state bits. A field edge refuses while they are set; a
    /// world-region entry does not consult them.
    event_flags_low2: u2 = 0,
};
/// Locations the host can currently construct. This is the only source of truth
/// for "available": the catalogue's `constructible` flag describes export
/// readiness, not the packages attached to a running session.
pub const Scope = struct {
    locations: []const []const u8,

    pub fn includes(self: Scope, id: []const u8) bool {
        for (self.locations) |candidate| if (std.mem.eql(u8, candidate, id)) return true;
        return false;
    }
};

pub const Proposal = struct {
    receipt: u64,
    edge_id: []const u8,
    origin_id: []const u8,
    trigger: Trigger,
    conditions: []const edges.Condition,
    effects: []const edges.Effect,
    destination: edges.Destination,
    reconstruction: edges.Reconstruction,
    continuation: edges.Continuation,
};
pub const Commit = struct {
    receipt: u64,
    edge_id: []const u8,
    destination: edges.Destination,
    reconstruction: edges.Reconstruction,
    continuation: edges.Continuation,
};
pub const Snapshot = struct {
    version: u8 = 1,
    state: State = .idle,
    edge_id: []const u8 = "",
    receipt: u64 = 0,
    settled_receipt: u64 = 0,
    next_effect: u8 = 0,
    story_before: event_runtime.StoryState = .{},
};

const Pending = struct {
    edge_index: usize,
    trigger: Trigger,
    receipt: u64,
    next_effect: usize,
    story_before: event_runtime.StoryState,
    proposal: Proposal,
};
const Committed = struct {
    edge_index: usize,
    edge_id: []const u8,
    receipt: u64,
};

fn matches(trigger: edges.Trigger, cue: Trigger) bool {
    switch (trigger.kind) {
        .field_rectangle => switch (cue) {
            .field_rectangle => |input| {
                if (input.position.domain != .field_pixel) return false;
                if (trigger.direction) |required| {
                    const requested = input.direction orelse return false;
                    if (requested != required) return false;
                }
                const rect = trigger.rectangle orelse return false;
                return input.position.x >= rect.x and input.position.y >= rect.y and
                    input.position.x < rect.x + rect.w and input.position.y < rect.y + rect.h;
            },
            else => return false,
        },
        .world_point => switch (cue) {
            .world_point => |point| {
                const anchor = trigger.point orelse return false;
                // Source point activation is the inclusive 2x2 block, not a
                // single cell and not the exclusive rectangle rule.
                return point.domain == .world_cell and
                    point.x >= anchor.x and point.x <= anchor.x + 1 and
                    point.y >= anchor.y and point.y <= anchor.y + 1;
            },
            else => return false,
        },
        .ordinary_event => return cue == .ordinary_event,
    }
}

/// A guard bit that the same edge's prefix rewrites is expected to change; every
/// other guard bit must still hold when the host commits. That keeps a real
/// external story change stale without rejecting the source's own final OR.
fn conditionExempt(edge: edges.Edge, condition: edges.Condition) bool {
    const index = edges.scenarioIndex(condition.flag.id) orelse return false;
    for (edge.effects) |effect| {
        if (effect.kind != .story_or) continue;
        const flag = effect.flag orelse continue;
        const effect_index = edges.scenarioIndex(flag.id) orelse continue;
        if (effect_index == index and flag.mask & condition.flag.mask != 0) return true;
    }
    return false;
}

fn stillEligible(edge: edges.Edge, story: *const event_runtime.StoryState) bool {
    for (edge.conditions) |condition| {
        if (conditionExempt(edge, condition)) continue;
        const index = edges.scenarioIndex(condition.flag.id) orelse return false;
        const present = story.scenario[index] & condition.flag.mask != 0;
        if (present != (condition.kind == .story_mask_set)) return false;
    }
    return true;
}

fn validField(position: edges.Coordinate) !void {
    if (position.domain != .field_pixel) return error.InvalidCue;
    if (position.x < 0 or position.y < 0 or position.x > 2040 or position.y > 2040) return error.InvalidCue;
}

pub const Consumer = struct {
    state: State = .idle,
    settled_receipt: u64 = 0,
    pending: ?Pending = null,
    committed: ?Committed = null,

    pub fn begin(
        self: *Consumer,
        packet: *const edges.Packet,
        cue: Cue,
        story: *const event_runtime.StoryState,
        scope: Scope,
    ) !Proposal {
        if (self.state != .idle) return error.CuePending;
        _ = packet.location(cue.origin_id) orelse return error.UnknownOrigin;
        switch (cue.trigger) {
            .field_rectangle => |input| try validField(input.position),
            .world_point => |point| if (point.domain != .world_cell) return error.InvalidCue,
            .ordinary_event => {},
        }
        for (packet.edges, 0..) |edge, index| {
            if (!std.mem.eql(u8, edge.origin.location_id, cue.origin_id)) continue;
            if (!matches(edge.origin.trigger, cue.trigger)) continue;
            if (edge.origin.event_flags_low2_clear and cue.event_flags_low2 != 0) continue;
            if (!story.matches(edge.conditions)) continue;
            const destination = packet.location(edge.destination.location_id) orelse return error.UnknownEdgeDestination;
            // The first eligible edge owns the cue. An unavailable destination is
            // a refusal, never a reason to fall through to another edge.
            if (!scope.includes(destination.id)) return error.UnavailableDestination;
            const receipt = std.math.add(u64, self.settled_receipt, 1) catch return error.ReceiptOverflow;
            const proposal = Proposal{
                .receipt = receipt,
                .edge_id = edge.id,
                .origin_id = edge.origin.location_id,
                .trigger = cue.trigger,
                .conditions = edge.conditions,
                .effects = edge.effects,
                .destination = edge.destination,
                .reconstruction = edge.reconstruction,
                .continuation = edge.continuation,
            };
            self.pending = .{
                .edge_index = index,
                .trigger = cue.trigger,
                .receipt = receipt,
                .next_effect = 0,
                .story_before = story.*,
                .proposal = proposal,
            };
            self.state = .effects_pending;
            return proposal;
        }
        return error.NoMatchingEdge;
    }

    /// Returns the next required effect. Hosts execute it and call again with the
    /// following index; the source order is part of the contract, not a hint.
    pub fn acknowledgeEffect(self: *Consumer, receipt: u64, index: usize) !edges.Effect {
        if (self.state != .effects_pending) return error.NoPendingCue;
        const pending = if (self.pending) |*value| value else return error.NoPendingCue;
        if (pending.receipt != receipt) return error.InvalidReceipt;
        if (index != pending.next_effect) return error.PrefixOutOfOrder;
        if (index >= pending.proposal.effects.len) return error.NoMoreEffects;
        pending.next_effect += 1;
        return pending.proposal.effects[index];
    }

    /// Commits only after every prefix effect and revalidates the source facts.
    /// The caller's story must already contain every `story_or` mask; the
    /// consumer never applies it, so a host that skipped a flag is refused
    /// instead of teleporting on a stale plan.
    pub fn commit(
        self: *Consumer,
        packet: *const edges.Packet,
        receipt: u64,
        story: *const event_runtime.StoryState,
    ) !Commit {
        if (self.state != .effects_pending) return error.NoPendingCue;
        const pending = if (self.pending) |*value| value else return error.NoPendingCue;
        if (pending.receipt != receipt) return error.InvalidReceipt;
        const edge = &packet.edges[pending.edge_index];
        if (pending.next_effect != edge.effects.len) return error.PrefixIncomplete;
        if (!std.mem.eql(u8, edge.id, pending.proposal.edge_id)) return error.InvalidEdgeIdentity;
        if (!stillEligible(edge.*, story)) return error.StaleStory;
        for (edge.effects) |effect| {
            if (effect.kind != .story_or) continue;
            const flag = effect.flag orelse return error.InvalidEdgeEffect;
            const index = edges.scenarioIndex(flag.id) orelse return error.UnknownEdgeStoryValue;
            if (story.scenario[index] & flag.mask == 0) return error.UnexecutedStoryEffect;
        }
        const result = Commit{
            .receipt = receipt,
            .edge_id = edge.id,
            .destination = edge.destination,
            .reconstruction = edge.reconstruction,
            .continuation = edge.continuation,
        };
        const edge_index = pending.edge_index;
        self.pending = null;
        self.committed = .{ .edge_index = edge_index, .edge_id = result.edge_id, .receipt = receipt };
        self.state = .committed;
        return result;
    }

    /// The host calls this once the destination has been constructed and entered.
    /// Only then may a new cue begin, so a repeated input cannot replay the same
    /// exit while its destination is still being built.
    pub fn settle(self: *Consumer, receipt: u64) !void {
        if (self.state != .committed) return error.NoCommittedCue;
        const committed = self.committed orelse return error.NoCommittedCue;
        if (committed.receipt != receipt) return error.InvalidReceipt;
        self.settled_receipt = receipt;
        self.committed = null;
        self.state = .idle;
    }

    /// Drops a pending cue only before any effect was acknowledged, so no host
    /// state can have changed yet.
    pub fn cancel(self: *Consumer, receipt: u64) !void {
        if (self.state != .effects_pending) return error.NoPendingCue;
        const pending = self.pending orelse return error.NoPendingCue;
        if (pending.receipt != receipt) return error.InvalidReceipt;
        if (pending.next_effect != 0) return error.PrefixStarted;
        self.pending = null;
        self.state = .idle;
    }

    pub fn snapshot(self: *const Consumer) Snapshot {
        return switch (self.state) {
            .idle => .{ .state = .idle, .settled_receipt = self.settled_receipt },
            .effects_pending => blk: {
                const pending = self.pending orelse break :blk .{ .state = .idle, .settled_receipt = self.settled_receipt };
                break :blk .{
                    .state = .effects_pending,
                    .edge_id = pending.proposal.edge_id,
                    .receipt = pending.receipt,
                    .settled_receipt = self.settled_receipt,
                    .next_effect = @intCast(pending.next_effect),
                    .story_before = pending.story_before,
                };
            },
            .committed => blk: {
                const committed = self.committed orelse break :blk .{ .state = .idle, .settled_receipt = self.settled_receipt };
                break :blk .{
                    .state = .committed,
                    .edge_id = committed.edge_id,
                    .receipt = committed.receipt,
                    .settled_receipt = self.settled_receipt,
                };
            },
        };
    }

    /// Rebuilds a consumer from its snapshot by replaying the source facts: the
    /// edge must still exist, the cue must still match, and a pending cue must
    /// still satisfy its guard. Restored receipts are never re-invented.
    pub fn restore(
        packet: *const edges.Packet,
        saved: Snapshot,
        cue: Cue,
        story: *const event_runtime.StoryState,
        scope: Scope,
    ) !Consumer {
        if (saved.version != 1) return error.InvalidSnapshot;
        switch (saved.state) {
            .idle => {
                if (saved.edge_id.len != 0 or saved.receipt != 0 or saved.next_effect != 0) return error.InvalidSnapshot;
                return .{ .settled_receipt = saved.settled_receipt };
            },
            .effects_pending => {
                var consumer = Consumer{ .settled_receipt = saved.settled_receipt };
                const proposal = try consumer.begin(packet, cue, story, scope);
                if (!std.mem.eql(u8, proposal.edge_id, saved.edge_id)) return error.InvalidSnapshot;
                if (consumer.pending.?.receipt != saved.receipt) return error.InvalidSnapshot;
                if (saved.next_effect > proposal.effects.len) return error.InvalidSnapshot;
                var index: usize = 0;
                while (index < saved.next_effect) : (index += 1) {
                    _ = try consumer.acknowledgeEffect(saved.receipt, index);
                }
                return consumer;
            },
            .committed => {
                if (saved.next_effect != 0) return error.InvalidSnapshot;
                const edge_index = packet.edgeIndex(saved.edge_id) orelse return error.InvalidSnapshot;
                const edge = &packet.edges[edge_index];
                if (!scope.includes(edge.destination.location_id)) return error.UnavailableDestination;
                return .{
                    .state = .committed,
                    .settled_receipt = saved.settled_receipt,
                    .committed = .{ .edge_index = edge_index, .edge_id = edge.id, .receipt = saved.receipt },
                };
            },
        }
    }
};
