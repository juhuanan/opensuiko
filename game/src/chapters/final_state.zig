//! Host-free enums for the final-block state.
pub const Stage = enum { canonical_checkpoint, frontier_refused, declared_final_block, ending };
pub const Mode = enum { canonical, supplied };
pub const HandoffState = enum { pending, refused, accepted };

const std = @import("std");

pub const Kind = enum { integration, source, external, human };

pub const Blocked = struct {
    stage: []const u8,
    blocker: []const u8,
    kind: Kind,
    detail: []const u8,
    missing_api: []const []const u8 = &.{},
};

pub const Declaration = struct {
    entry_edge: []const u8,
    destination: []const u8,
    terminal_source: []const u8,
    terminal_sha256: []const u8,
    reachability: []const u8 = "supplied_source_checkpoint",
    canonical_prior: []const u8 = "blocked_at_opening_palace_frontier",
    note: []const u8 = "a supplied source checkpoint is not canonical access",
};

pub const Variant = enum {
    absent,
    recruited,
    recruited_alternate,
    lost,
    lost_alternate,
};

pub const EndingState = struct {
    source_index: u8,
    variant: Variant,
    effect: ?u32,
    death_cause: ?u8,
    death_effect: ?u32,
    execution: []const u8 = "source_overlay_unimplemented",
    visited_entries: u16 = 0,
    phases_completed: u8 = 0,
    return_value: ?i32 = null,
    overlay_context_cleared: bool = false,
    caller_word_cleared: bool = false,
    str_resources_used: u8 = 0,
    committed: bool = true,

    pub fn validate(self: EndingState) !void {
        if (self.source_index >= 108) return error.InvalidEndingState;
        if (!self.committed) return error.InvalidEndingState;
        if (std.mem.eql(u8, self.execution, "source_overlay_unimplemented")) {
            if (self.visited_entries != 0 or self.phases_completed != 0 or self.return_value != null or
                self.overlay_context_cleared or self.caller_word_cleared) return error.InvalidEndingState;
        } else if (std.mem.eql(u8, self.execution, "bounded_hero_recruited_vz7_message")) {
            if (self.source_index != 0 or self.variant != .recruited or self.effect == null or
                self.effect.? != 0x80071024 or self.visited_entries != 108 or self.phases_completed != 6 or
                self.return_value == null or self.return_value.? != -1 or
                !self.overlay_context_cleared or !self.caller_word_cleared)
                return error.InvalidEndingState;
        } else return error.InvalidEndingState;
    }
};

pub const RouteState = struct {
    handoff: HandoffState = .pending,
    mode: Mode = .canonical,
    declaration: ?Declaration = null,
    refusal: ?Blocked = null,

    pub fn validate(self: RouteState) !void {
        if (self.mode == .supplied and self.declaration == null) return error.InvalidRouteState;
        if (self.mode == .canonical and self.declaration != null) return error.InvalidRouteState;
        if (self.handoff == .refused and self.refusal == null) return error.InvalidRouteState;
        if (self.handoff != .refused and self.refusal != null) return error.InvalidRouteState;
        if (self.declaration) |value| {
            if (value.entry_edge.len == 0 or value.destination.len == 0 or
                !std.mem.eql(u8, value.reachability, "supplied_source_checkpoint") or
                !std.mem.eql(u8, value.canonical_prior, "blocked_at_opening_palace_frontier"))
                return error.InvalidRouteState;
        }
        if (self.refusal) |value| {
            if (value.stage.len == 0 or value.blocker.len == 0 or value.detail.len == 0)
                return error.InvalidRouteState;
        }
    }
};

pub const max_id = 63;
pub const party_slots = 6;
pub const Branch = enum { victory, no_reward_end, defeat, battle_open, blocked };
pub const HostAction = union(enum) {
    return_to_field,
    special_module: u8,
    none,
};
pub const Story = enum { none, field_return };
pub const Pending = struct {
    branch: Branch,
    rewards: bool,
    action: HostAction,
    story: Story,
};
pub const HostPhase = enum { idle, active, pending, resolved, blocked, committed };
pub const PartyState = struct {
    charges: [party_slots]u16 = .{ 0, 0, 0, 0, 0, 0 },
    ko: [party_slots]bool = .{ false, false, false, false, false, false },
    members: u8 = 0,
    money: u32 = 0,
};
pub const Receipt = struct {
    formation: [max_id]u8 = undefined,
    formation_len: u8 = 0,
    branch: Branch = .battle_open,
    rewards: bool = false,
    action: HostAction = .none,
    money_after: u32 = 0,
    sequence: u32 = 0,

    pub fn id(self: *const Receipt) []const u8 {
        return self.formation[0..self.formation_len];
    }
};
pub const Capture = struct {
    token: u64,
    phase: HostPhase,
    formation: [max_id]u8,
    formation_len: u8,
    party: PartyState,
    pending: ?Pending,
    committed: ?Receipt,
    commit_count: u32,
    rewards_applied: bool,
    story_committed: bool,
    reloads: u16,
};

pub const OptionalJournal = struct {
    schema: []const u8,
    revision: u64,
    money: u32,
    completed: []const []const u8,
};

pub const final_schema = "suikoden-final-route/1";
pub const max_reloads = 64;

pub const FinalState = struct {
    schema: []const u8 = final_schema,
    revision: []const u8,
    ledger_sha256: []const u8,
    stage: Stage,
    route: RouteState = .{},
    optional: OptionalJournal = .{ .schema = "", .revision = 0, .money = 0, .completed = &.{} },
    optional_json: []const u8 = "",
    battle: ?Capture = null,
    ending: ?EndingState = null,
    reloads: u16 = 0,

    pub fn validateStructure(self: FinalState) !void {
        if (!std.mem.eql(u8, self.schema, final_schema)) return error.UnsupportedEndingRoute;
        if (self.optional.completed.len > 128) return error.InvalidEndingJournal;
        if (self.reloads > max_reloads) return error.InvalidEndingRoute;
        try self.route.validate();
        if (self.route.mode == .canonical and self.stage != .canonical_checkpoint and self.stage != .frontier_refused)
            return error.InvalidEndingRoute;
        if (self.stage == .declared_final_block and self.route.declaration == null) return error.InvalidEndingRoute;
        if (self.stage == .ending and (self.ending == null or self.route.declaration == null)) return error.InvalidEndingRoute;
        if (self.ending) |value| try value.validate();
        if (self.battle) |value| {
            if (value.formation_len == 0 or value.formation_len > max_id) return error.InvalidEndingRoute;
            if (value.phase == .committed and value.committed == null) return error.InvalidEndingRoute;
        }
    }
};
