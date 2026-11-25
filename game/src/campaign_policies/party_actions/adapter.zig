//! Per-owner qualified ordinary party action adapter.
//!
//! This is the consumer half of the party-action contract: it takes the typed
//! runtime data (`actions.zig`), admits only records whose mechanics, reaction
//! and resident art are all qualified, and drives one ordinary
//! action per party owner on the source clock.
//!
//! Semantics preserved from the packet:
//!  * one clock: actor updates, dispatch at 0, first actor update 1;
//!  * event ticks are applied by the acting slot, a coordinator-owned action
//!    mask is observed one update later, actor/presentation state in its own
//!    update (so `impact` is `mask2 write + 1`, `owner_ready` is
//!    `mask4 write + 1`, `return_release` is the flag-clear update, and the
//!    target reaction release is `impact + reaction delay`);
//!  * every typed operand is handed to the presentation/coordinator consumer at
//!    the update the packet declares (motion offset/delta, animation frames and
//!    flag byte, auxiliary flags/animation/table/offset, timers, masks,
//!    selectors, compare values, callbacks, screen offsets and cue ids);
//!  * an auxiliary spawn/release and a reaction release stay scheduled even when
//!    the owner's return flag clears first, so a later boundary is never dropped;
//!  * one action per owner, but different owners overlap.
//!
//! Draws and damage:
//!  * the adapter never draws random numbers.  The only draw it gates is the
//!    impact damage draw, made exactly once, on the update that observes the
//!    impact mask (the existing path's admission hit/critical draws stay in the
//!    caller before `begin`), which keeps the source Action/Draws order;
//!  * the drawn amount is returned as an `impact_damage` effect on that same
//!    update (the coordinator observation of the impact is what applies the
//!    acting slot's damage, C-applies-D); the adapter never mutates hit points.
//!  * if any fallible step of an update fails, the whole update is rolled back:
//!    no action state changes, no effect is returned and no draw is committed.
//!
//! The adapter is transactional by construction: it mutates a copy of its
//! action table, buffers emissions/effects, and commits only after every owner
//! has been processed successfully.

const std = @import("std");
pub const actions = @import("actions.zig");

pub const max_actions = 6;
pub const max_schedule = actions.max_timeline;
pub const max_emissions = 96;
pub const max_effects = 16;
pub const max_dispatch_update = 4096;
pub const max_record_index = 4096;

pub const BoundaryName = enum {
    initial_command,
    impact,
    owner_ready,
    return_release,
    target_reaction,
    auxiliary_spawn,
    auxiliary_contact,
    auxiliary_release,
};

pub const Emission = struct {
    owner: u8,
    event_index: ?u16,
    boundary: ?BoundaryName,
    tick: u16,
    phase: actions.Phase,
};

pub const EffectKind = enum {
    impact_damage,
    target_reaction_start,
    target_release,
    target_down,
    target_missing,
    owner_release,
    auxiliary_spawn,
    auxiliary_release,
    action_complete,
};

pub const Effect = struct {
    owner: u8,
    target: u32,
    kind: EffectKind,
    amount: u32 = 0,
};

pub const Host = struct {
    context: *anyopaque,
    target_alive: *const fn (context: *anyopaque, target: u32) bool,
    target_down: *const fn (context: *anyopaque, target: u32) bool,
    first_available_target: *const fn (context: *anyopaque, owner: usize) ?u32,
    draw_impact_damage: *const fn (context: *anyopaque, owner: usize, target: u32) anyerror!u32,
};

pub const Scheduled = struct {
    update: u16,
    phase: actions.Phase,
    tick: u16,
    rank: u8,
    index: u16,
};

const phaseRank = [_]u8{ 0, 1, 2 };

fn phaseOf(consumer: actions.Consumer) actions.Phase {
    return switch (consumer) {
        .coordinator => .coordinator,
        .actor => .actor,
        .presentation => .presentation,
    };
}

/// The event's dispatch update: coordinator-owned state is consumed one update
/// after the acting slot writes it, except the script's own mask wait, which
/// checks the mask written in the previous update at its own tick.
fn dispatchUpdate(event: actions.Event) u16 {
    if (event.consumer == .coordinator and event.kind != .wait_action_mask) return event.tick + 1;
    return event.tick;
}

pub const Command = struct {
    owner: usize,
    id: []const u8,
    target: ?u32 = null,
    eligible: bool = true,
    awake: bool = true,
    unbalanced: bool = false,
};

pub const Action = struct {
    owner: u8,
    record: u16,
    target: u32,
    elapsed: u16 = 0,
    cursor: u16 = 0,
    schedule: [max_schedule]Scheduled = undefined,
    schedule_len: u16 = 0,
    completion_tick: u16 = 0,
    owner_released: bool = false,
    target_released: bool = false,
    target_down: bool = false,
    auxiliary_alive: bool = false,
    reaction_active: bool = false,
    impact_applied: bool = false,
    complete: bool = false,
};

pub const Update = struct {
    emissions: []const Emission,
    effects: []const Effect,
    /// Acting-slot update count reached this call, per owner.  This is the
    /// source clock value (`event`-relative), independent of how many updates
    /// this particular consumer has driven.
    elapsed: [max_actions]u16 = @splat(0),
    pub fn emissionCount(self: Update) usize {
        return self.emissions.len;
    }
    pub fn effectCount(self: Update) usize {
        return self.effects.len;
    }
};

pub const EncodedAction = struct {
    owner: u8,
    record: u16,
    target: u32,
    elapsed: u16,
    cursor: u16,
    schedule_len: u16,
    flags: u8,
};

const flag_owner_released: u8 = 1 << 0;
const flag_target_released: u8 = 1 << 1;
const flag_target_down: u8 = 1 << 2;
const flag_auxiliary_alive: u8 = 1 << 3;
const flag_reaction_active: u8 = 1 << 4;
const flag_impact_applied: u8 = 1 << 5;
const flag_complete: u8 = 1 << 6;

pub const AdmissionError = error{
    ArtGap,
    ReactionUnresolved,
    MechanicsIncomplete,
    ResidencyUnqualified,
    FalseComplete,
    RecordBlocked,
    InvalidTimeline,
};

/// Admit only a record whose every reviewed qualification holds.  Blocked art
/// and the unresolved Clive reaction are typed, distinct refusals.
pub fn admit(record: actions.Record) AdmissionError!void {
    if (!record.admitted) {
        if (record.blocker) |blocker| switch (blocker.kind) {
            .art_gap => return error.ArtGap,
            .reaction_unresolved => return error.ReactionUnresolved,
            .unresolved => return error.RecordBlocked,
        };
        return error.RecordBlocked;
    }
    if (!record.admission.mechanics_complete or !record.timeline_complete) return error.MechanicsIncomplete;
    if (!record.admission.reaction_resolved or !record.reaction.resolved) return error.ReactionUnresolved;
    if (record.reaction.delay_ticks == null) return error.ReactionUnresolved;
    if (record.boundaries.impact == null or record.boundaries.target_reaction == null) return error.ReactionUnresolved;
    if (!record.admission.residency_qualified) return error.ResidencyUnqualified;
    const residency = record.residency orelse return error.ResidencyUnqualified;
    if (residency.status != .supported) return error.ResidencyUnqualified;
    if (record.boundaries.impact == null or record.boundaries.owner_ready == null or
        record.boundaries.return_release == null) return error.FalseComplete;
    if (record.timeline.len == 0 or record.timeline.len > max_schedule) return error.InvalidTimeline;
    if (record.auxiliary != null) {
        if (record.boundaries.auxiliary_spawn == null or record.boundaries.auxiliary_contact == null or
            record.boundaries.auxiliary_release == null) return error.InvalidTimeline;
    }
    for (record.timeline) |event| {
        actions.validateEvent(event) catch return error.InvalidTimeline;
        if (dispatchUpdate(event) > max_dispatch_update) return error.InvalidTimeline;
    }
    return;
}

pub const Set = struct {
    actions: [max_actions]?Action = @splat(null),
    emissions: [max_emissions]Emission = undefined,
    emission_count: usize = 0,
    effects: [max_effects]Effect = undefined,
    effect_count: usize = 0,
    /// Committed impact damage draws.  Exactly one per applied impact.
    draws: u32 = 0,
    /// Count of committed updates; every action advances once per call.
    updates: u32 = 0,

    /// The adapter owns no content pointer: the caller passes the parsed packet
    /// on every call so a moved/reloaded content value cannot dangle.
    pub fn init() Set {
        return .{};
    }

    pub fn reset(self: *Set) void {
        self.actions = @splat(null);
        self.emission_count = 0;
        self.effect_count = 0;
        self.draws = 0;
        self.updates = 0;
    }

    pub fn recordOf(self: *const Set, content: *const actions.Content, owner: usize) ?*const actions.Record {
        const action = self.actions[owner] orelse return null;
        return &content.records[action.record];
    }

    pub fn actionOf(self: *const Set, owner: usize) ?Action {
        return self.actions[owner];
    }

    pub fn available(self: *const Set, owner: usize) bool {
        return self.actions[owner] == null;
    }

    pub fn released(self: *const Set, owner: usize) bool {
        const action = self.actions[owner] orelse return true;
        return action.owner_released;
    }

    fn buildSchedule(record: actions.Record, action: *Action) !void {
        if (record.timeline.len == 0 or record.timeline.len > max_schedule) return error.InvalidTimeline;
        var length: usize = 0;
        for (record.timeline, 0..) |event, index| {
            const scheduled = Scheduled{
                .update = dispatchUpdate(event),
                .phase = phaseOf(event.consumer),
                .tick = event.tick,
                .rank = actions.trackRank(event.track),
                .index = @intCast(index),
            };
            var position = length;
            while (position > 0) : (position -= 1) {
                const previous = action.schedule[position - 1];
                if (!scheduleLess(scheduled, previous)) break;
                action.schedule[position] = previous;
            }
            action.schedule[position] = scheduled;
            length += 1;
        }
        action.schedule_len = @intCast(length);
        var completion = if (length == 0) 0 else action.schedule[length - 1].update;
        const all = [_]?actions.Boundary{
            record.boundaries.initial_command,
            record.boundaries.impact,
            record.boundaries.owner_ready,
            record.boundaries.return_release,
            record.boundaries.target_reaction,
            record.boundaries.auxiliary_spawn,
            record.boundaries.auxiliary_contact,
            record.boundaries.auxiliary_release,
        };
        for (all) |maybe| {
            const bound = maybe orelse continue;
            if (bound.ticks > completion) completion = bound.ticks;
        }
        action.completion_tick = completion;
    }

    fn scheduleLess(left: Scheduled, right: Scheduled) bool {
        if (left.update != right.update) return left.update < right.update;
        const left_phase = phaseRank[@backingInt(left.phase)];
        const right_phase = phaseRank[@backingInt(right.phase)];
        if (left_phase != right_phase) return left_phase < right_phase;
        if (left.tick != right.tick) return left.tick < right.tick;
        if (left.rank != right.rank) return left.rank < right.rank;
        return left.index < right.index;
    }

    /// Start one ordinary action for `command.owner`.
    ///
    /// A missing/blocked action family, an unacceptable command, or a missing
    /// target is refused without changing any live state.  A dead preferred
    /// target is retargeted by the caller's `first_available_target` policy; if
    /// that returns null the action is refused (KO / no target).
    pub fn begin(self: *Set, content: *const actions.Content, host: Host, command: Command) !void {
        if (command.owner >= max_actions) return error.InvalidOwner;
        if (self.actions[command.owner] != null) return error.OwnerBusy;
        const record_index = try actions.lookup(content.*, command.id);
        try self.beginRecord(host, command, record_index, content.records[record_index]);
    }

    /// Begin from an explicitly supplied record.  `begin` resolves the record by
    /// id; this entry point exists for hand-authored clock/operand cases and for
    /// consumers that already hold the record index.  Admission and target
    /// policy are identical.
    pub fn beginRecord(self: *Set, host: Host, command: Command, record_index: usize, record: actions.Record) !void {
        if (command.owner >= max_actions) return error.InvalidOwner;
        if (self.actions[command.owner] != null) return error.OwnerBusy;
        if (!command.eligible or !command.awake or command.unbalanced) return error.CommandNotEligible;
        if (record_index >= max_record_index) return error.InvalidRecordIndex;
        try admit(record);
        var target: u32 = 0;
        if (command.target) |preferred| {
            if (host.target_alive(host.context, preferred)) {
                target = preferred;
            } else {
                target = host.first_available_target(host.context, command.owner) orelse return error.NoTarget;
                if (!host.target_alive(host.context, target)) return error.NoTarget;
            }
        } else {
            target = host.first_available_target(host.context, command.owner) orelse return error.NoTarget;
            if (!host.target_alive(host.context, target)) return error.NoTarget;
        }
        var action = Action{ .owner = @intCast(command.owner), .record = @intCast(record_index), .target = target };
        try buildSchedule(record, &action);
        self.actions[command.owner] = action;
        return;
    }

    fn emit(self: *Set, emission: Emission) !void {
        if (self.emission_count >= self.emissions.len) return error.TooManyEmissions;
        self.emissions[self.emission_count] = emission;
        self.emission_count += 1;
    }

    fn effect(self: *Set, effect_value: Effect) !void {
        if (self.effect_count >= self.effects.len) return error.TooManyEffects;
        self.effects[self.effect_count] = effect_value;
        self.effect_count += 1;
    }

    fn boundaryOf(record: actions.Record, name: BoundaryName) ?actions.Boundary {
        return switch (name) {
            .initial_command => record.boundaries.initial_command,
            .impact => record.boundaries.impact,
            .owner_ready => record.boundaries.owner_ready,
            .return_release => record.boundaries.return_release,
            .target_reaction => record.boundaries.target_reaction,
            .auxiliary_spawn => record.boundaries.auxiliary_spawn,
            .auxiliary_contact => record.boundaries.auxiliary_contact,
            .auxiliary_release => record.boundaries.auxiliary_release,
        };
    }

    fn boundaryPhase(boundary: actions.Boundary) actions.Phase {
        return switch (boundary.consumer orelse .coordinator) {
            .coordinator => .coordinator,
            .actor => .actor,
            .presentation => .presentation,
        };
    }

    fn boundaryPriority(name: BoundaryName) u8 {
        return @backingInt(name);
    }

    const Marker = struct { name: BoundaryName, tick: u16 };

    fn processBoundaries(self: *Set, action: *Action, record: actions.Record, phase: actions.Phase, host: Host) !void {
        const names = [_]BoundaryName{
            .impact,
            .auxiliary_contact,
            .owner_ready,
            .target_reaction,
            .auxiliary_spawn,
            .auxiliary_release,
            .return_release,
        };
        var markers: [names.len]Marker = undefined;
        var count: usize = 0;
        for (names) |name| {
            const boundary = boundaryOf(record, name) orelse continue;
            if (boundary.ticks != action.elapsed) continue;
            if (boundaryPhase(boundary) != phase) continue;
            markers[count] = .{ .name = name, .tick = boundary.ticks };
            count += 1;
        }
        // deterministic order by tick, then declared boundary priority
        var i: usize = 1;
        while (i < count) : (i += 1) {
            const current = markers[i];
            var j = i;
            while (j > 0 and (markers[j - 1].tick > current.tick or
                (markers[j - 1].tick == current.tick and boundaryPriority(markers[j - 1].name) > boundaryPriority(current.name)))) : (j -= 1)
            {
                markers[j] = markers[j - 1];
            }
            markers[j] = current;
        }
        for (markers[0..count]) |marker| {
            try self.emit(.{ .owner = action.owner, .event_index = null, .boundary = marker.name, .tick = marker.tick, .phase = phase });
            switch (marker.name) {
                .impact, .auxiliary_contact => {
                    if (action.impact_applied) continue;
                    action.impact_applied = true;
                    if (!host.target_alive(host.context, action.target)) {
                        action.target_down = true;
                        try self.effect(.{ .owner = action.owner, .target = action.target, .kind = .target_missing });
                        continue;
                    }
                    const amount = try host.draw_impact_damage(host.context, action.owner, action.target);
                    try self.effect(.{ .owner = action.owner, .target = action.target, .kind = .impact_damage, .amount = amount });
                    action.reaction_active = true;
                    try self.effect(.{ .owner = action.owner, .target = action.target, .kind = .target_reaction_start });
                },
                .target_reaction => {
                    action.reaction_active = false;
                    if (host.target_down(host.context, action.target)) {
                        action.target_down = true;
                        action.target_released = true;
                        try self.effect(.{ .owner = action.owner, .target = action.target, .kind = .target_down });
                    } else {
                        action.target_released = true;
                        try self.effect(.{ .owner = action.owner, .target = action.target, .kind = .target_release });
                    }
                },
                .owner_ready => {},
                .auxiliary_spawn => {
                    action.auxiliary_alive = true;
                    try self.effect(.{ .owner = action.owner, .target = action.target, .kind = .auxiliary_spawn });
                },
                .auxiliary_release => {
                    action.auxiliary_alive = false;
                    try self.effect(.{ .owner = action.owner, .target = action.target, .kind = .auxiliary_release });
                },
                .return_release => {
                    action.owner_released = true;
                    try self.effect(.{ .owner = action.owner, .target = action.target, .kind = .owner_release });
                },
                .initial_command => {},
            }
        }
    }

    fn process(self: *Set, content: *const actions.Content, action: *Action, host: Host) !void {
        const record = content.records[action.record];
        var index: usize = action.cursor;
        for ([_]actions.Phase{ .coordinator, .actor, .presentation }) |phase| {
            while (index < action.schedule_len) {
                const scheduled = action.schedule[index];
                if (scheduled.update != action.elapsed or scheduled.phase != phase) break;
                try self.emit(.{
                    .owner = action.owner,
                    .event_index = scheduled.index,
                    .boundary = null,
                    .tick = scheduled.tick,
                    .phase = phase,
                });
                index += 1;
            }
            try self.processBoundaries(action, record, phase, host);
        }
        action.cursor = @intCast(index);
        if (action.cursor == action.schedule_len and action.elapsed >= action.completion_tick and !action.complete) {
            action.complete = true;
            try self.effect(.{ .owner = action.owner, .target = action.target, .kind = .action_complete });
        }
    }

    /// Advance every active action by one update.  The whole update commits
    /// atomically; on error the set is unchanged and no draw is committed.
    pub fn advance(self: *Set, content: *const actions.Content, host: Host) !Update {
        var working = self.actions;
        self.emission_count = 0;
        self.effect_count = 0;
        var draws: u32 = 0;
        var elapsed: [max_actions]u16 = @splat(0);
        for (&working, 0..) |*slot, owner| {
            if (slot.*) |*action| {
                action.elapsed += 1;
                if (action.elapsed > max_dispatch_update) return error.InvalidUpdate;
                const before = self.effect_count;
                try self.process(content, action, host);
                for (self.effects[before..self.effect_count]) |value| {
                    if (value.kind == .impact_damage) draws += 1;
                }
                elapsed[owner] = action.elapsed;
                if (action.complete) slot.* = null;
            }
        }
        self.actions = working;
        self.updates +%= 1;
        self.draws +%= draws;
        return .{ .emissions = self.emissions[0..self.emission_count], .effects = self.effects[0..self.effect_count], .elapsed = elapsed };
    }

    pub fn encodeAction(action: Action) EncodedAction {
        var flags: u8 = 0;
        if (action.owner_released) flags |= flag_owner_released;
        if (action.target_released) flags |= flag_target_released;
        if (action.target_down) flags |= flag_target_down;
        if (action.auxiliary_alive) flags |= flag_auxiliary_alive;
        if (action.reaction_active) flags |= flag_reaction_active;
        if (action.impact_applied) flags |= flag_impact_applied;
        if (action.complete) flags |= flag_complete;
        return .{ .owner = action.owner, .record = action.record, .target = action.target, .elapsed = action.elapsed, .cursor = action.cursor, .schedule_len = action.schedule_len, .flags = flags };
    }

    /// Small check-point record for one active owner; the schedule itself is
    /// rebuilt from the pinned packet, so only the cursor and latches persist.
    pub fn cursorOf(self: *const Set, owner: usize) ?EncodedAction {
        const action = self.actions[owner] orelse return null;
        return encodeAction(action);
    }

    fn applyCursor(working: *[max_actions]?Action, content: *const actions.Content, encoded: EncodedAction) !void {
        const owner: usize = encoded.owner;
        if (owner >= max_actions or working[owner] != null) return error.InvalidSerializedState;
        if (encoded.record >= content.records.len) return error.InvalidSerializedState;
        if (encoded.flags & ~@as(u8, 0x7F) != 0) return error.InvalidSerializedState;
        const record = content.records[encoded.record];
        try admit(record);
        var action = Action{ .owner = encoded.owner, .record = encoded.record, .target = encoded.target };
        try buildSchedule(record, &action);
        if (encoded.schedule_len != action.schedule_len or encoded.cursor > action.schedule_len) return error.InvalidSerializedState;
        if (encoded.elapsed > action.completion_tick and encoded.cursor != action.schedule_len) return error.InvalidSerializedState;
        action.elapsed = encoded.elapsed;
        action.cursor = encoded.cursor;
        action.owner_released = encoded.flags & flag_owner_released != 0;
        action.target_released = encoded.flags & flag_target_released != 0;
        action.target_down = encoded.flags & flag_target_down != 0;
        action.auxiliary_alive = encoded.flags & flag_auxiliary_alive != 0;
        action.reaction_active = encoded.flags & flag_reaction_active != 0;
        action.impact_applied = encoded.flags & flag_impact_applied != 0;
        action.complete = encoded.flags & flag_complete != 0;
        working[owner] = action;
    }

    /// Restore one action from its check-point record (JSON/checkpoint shape).
    pub fn restoreCursor(self: *Set, content: *const actions.Content, encoded: EncodedAction) !void {
        var working = self.actions;
        try applyCursor(&working, content, encoded);
        self.actions = working;
    }

    pub fn encode(self: *const Set, buffer: []u8) ![]const u8 {
        var length: usize = 0;
        const header = try std.fmt.bufPrint(buffer[length..], "v1", .{});
        length += header.len;
        for (self.actions, 0..) |maybe, owner| {
            const action = maybe orelse continue;
            const piece = try std.fmt.bufPrint(buffer[length..], "|{d},{d},{d},{d},{d},{d},{d}", .{
                owner, action.record, action.target, action.elapsed, action.cursor, action.schedule_len, encodeAction(action).flags,
            });
            length += piece.len;
        }
        return buffer[0..length];
    }

    pub fn decode(self: *Set, content: *const actions.Content, text: []const u8) !void {
        var working: [max_actions]?Action = @splat(null);
        var pieces = std.mem.splitScalar(u8, text, '|');
        const header = pieces.next() orelse return error.InvalidSerializedState;
        if (!std.mem.eql(u8, header, "v1")) return error.InvalidSerializedState;
        while (pieces.next()) |piece| {
            var fields = std.mem.splitScalar(u8, piece, ',');
            const owner_text = fields.next() orelse return error.InvalidSerializedState;
            const record_text = fields.next() orelse return error.InvalidSerializedState;
            const target_text = fields.next() orelse return error.InvalidSerializedState;
            const elapsed_text = fields.next() orelse return error.InvalidSerializedState;
            const cursor_text = fields.next() orelse return error.InvalidSerializedState;
            const length_text = fields.next() orelse return error.InvalidSerializedState;
            const flags_text = fields.next() orelse return error.InvalidSerializedState;
            if (fields.next() != null) return error.InvalidSerializedState;
            const encoded = EncodedAction{
                .owner = std.fmt.parseInt(u8, owner_text, 10) catch return error.InvalidSerializedState,
                .record = std.fmt.parseInt(u16, record_text, 10) catch return error.InvalidSerializedState,
                .target = std.fmt.parseInt(u32, target_text, 10) catch return error.InvalidSerializedState,
                .elapsed = std.fmt.parseInt(u16, elapsed_text, 10) catch return error.InvalidSerializedState,
                .cursor = std.fmt.parseInt(u16, cursor_text, 10) catch return error.InvalidSerializedState,
                .schedule_len = std.fmt.parseInt(u16, length_text, 10) catch return error.InvalidSerializedState,
                .flags = std.fmt.parseInt(u8, flags_text, 10) catch return error.InvalidSerializedState,
            };
            try applyCursor(&working, content, encoded);
        }
        self.actions = working;
        self.emission_count = 0;
        self.effect_count = 0;
    }
};

test "adapter constants stay aligned with the packet" {
    try std.testing.expectEqual(@as(usize, 6), max_actions);
    try std.testing.expect(max_schedule >= actions.max_timeline);
}
