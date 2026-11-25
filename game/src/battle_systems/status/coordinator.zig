//! Action coordinator: locks, impact/status/release lifetimes, one-time
//! protection effects and a restartable snapshot.
//!
//! Source lifetimes used here
//!   0x800F5E90  protection hurt callback: damage to the protector, hurt flag
//!               0x10 set once, ward return dispatched once
//!   0x800F5CD0  ward return callback
//!   0x800E09BC / 0x800E2C90  deferred knockout after the hurt lock
//!   0x800E2C90  status classes 0..8 are cleared when the deferred KO commits
//!
//! A frame reserves its owner and target at `begin`; the protector is reserved
//! at impact, after the selector/eligibility re-check.  A reaction frame is not
//! an action frame: the interaction resolver returns it, and the host turns it
//! into another action through the normal path.

const std = @import("std");
const rules = @import("rules.zig");
const status = @import("status.zig");
const interaction = @import("interaction.zig");
const battle_rules = @import("battle_rules");
const data = @import("constants.zig");

pub const Phase = enum { pending, impacted };

pub const Frame = struct {
    id: u8,
    owner: usize,
    target: usize,
    protector: ?usize = null,
    branch: interaction.Branch,
    impact: u16,
    status_tick: ?u16 = null,
    target_release: u16,
    owner_release: u16,
    protector_release: ?u16 = null,
    ward_return_start: ?u16 = null,
    ward_return_end: ?u16 = null,
    amount: u32,
    critical: bool = false,
    status_attempt: ?status.Attempt = null,
    phase: Phase = .pending,
    impacted: bool = false,
    status_done: bool = false,
    ward_return_done: bool = false,
    /// Set when the protector could not be reserved at impact; the frame then
    /// performs no protector release, no ward return and no HP change.
    protection_failed: bool = false,
    /// The frame actually reserved the protector lock at impact.
    protector_reserved: bool = false,
};

pub const Tag = enum { impact, protection_failed, status, protector_release, ward_return, target_release, owner_release, settled };

pub const Event = struct {
    tag: Tag,
    frame: u8,
    actor: usize,
    amount: u32 = 0,
    knocked_out: bool = false,
    status_result: ?status.Result = null,
    status_class: ?status.Class = null,
};

pub const ActorState = struct {
    hp: u16,
    active: bool,
    locked: bool,
    pending_damage: u16,
    status: status.State,
};

pub const Snapshot = struct {
    schema: u16 = 1,
    now: u16 = 0,
    frame_count: u8 = 0,
    actor_count: u8 = 0,
    frames: [8]Frame = undefined,
    actors: [16]ActorState = undefined,
};

pub const Coordinator = struct {
    combatants: []interaction.Combatant,
    draws: *battle_rules.Draws,
    log: rules.DrawLog = .{},
    frames: [8]?Frame = @splat(null),
    now: u16 = 0,
    events: [32]Event = undefined,
    event_count: usize = 0,

    pub fn init(combatants: []interaction.Combatant, draws: *battle_rules.Draws) Coordinator {
        return .{ .combatants = combatants, .draws = draws };
    }

    pub fn clearEvents(self: *Coordinator) void {
        self.event_count = 0;
    }

    pub fn eventSlice(self: *const Coordinator) []const Event {
        return self.events[0..self.event_count];
    }

    fn emit(self: *Coordinator, event: Event) void {
        if (self.event_count == self.events.len) return;
        self.events[self.event_count] = event;
        self.event_count += 1;
    }

    fn maxRelease(frame: Frame) u16 {
        var value = @max(frame.target_release, frame.owner_release);
        if (frame.protector_release) |tick| value = @max(value, tick);
        if (frame.ward_return_end) |tick| value = @max(value, tick);
        if (frame.status_tick) |tick| value = @max(value, tick);
        return value;
    }

    fn validateFrame(self: *const Coordinator, frame: Frame, now: u16, allow_settled_release: bool) !void {
        if (frame.owner >= self.combatants.len or frame.target >= self.combatants.len) return error.InvalidFrame;
        if (frame.owner == frame.target) return error.InvalidFrame;
        if (frame.branch != .hit and frame.branch != .critical and frame.branch != .protected) return error.ReactionNotActionable;
        if (frame.impact <= now and frame.phase == .pending) return error.ImpactInPast;
        if (frame.impact >= frame.owner_release) return error.InvalidReleaseOrder;
        if (frame.target_release < frame.impact) return error.InvalidReleaseOrder;
        if (frame.status_attempt != null and frame.status_tick == null) return error.InvalidFrame;
        if (frame.status_tick) |tick| {
            if (tick < frame.impact or tick > maxRelease(frame)) return error.InvalidReleaseOrder;
        }
        if (frame.protector) |protector| {
            if (protector >= self.combatants.len or protector == frame.owner or protector == frame.target) return error.InvalidFrame;
            const protector_exit = frame.protector_release orelse return error.InvalidReleaseOrder;
            const start = frame.ward_return_start orelse return error.InvalidReleaseOrder;
            const end = frame.ward_return_end orelse return error.InvalidReleaseOrder;
            if (frame.branch != .protected) return error.InvalidFrame;
            if (protector_exit < frame.impact) return error.InvalidReleaseOrder;
            if (start != protector_exit + 1) return error.InvalidReleaseOrder;
            if (end != start + data.ward_return_duration) return error.InvalidReleaseOrder;
            if (frame.target_release != end) return error.InvalidReleaseOrder;
        } else if (frame.protector_release != null or frame.ward_return_start != null or frame.ward_return_end != null) {
            return error.InvalidFrame;
        }
        if (!allow_settled_release and frame.phase == .impacted and !frame.impacted) return error.InvalidFrame;
    }

    pub fn begin(self: *Coordinator, frame: Frame) !usize {
        try self.validateFrame(frame, self.now, false);
        for (self.frames) |maybe| if (maybe) |existing| {
            if (existing.id == frame.id) return error.DuplicateFrame;
        };
        var slot: ?usize = null;
        for (self.frames, 0..) |maybe, index| if (maybe == null) {
            slot = index;
            break;
        };
        const index = slot orelse return error.FrameCapacity;
        if (self.combatants[frame.owner].locked) return error.ActorLocked;
        if (self.combatants[frame.target].locked) return error.ActorLocked;
        if (frame.protector) |protector| {
            if (self.combatants[protector].locked) return error.ActorLocked;
        }
        self.combatants[frame.owner].locked = true;
        self.combatants[frame.target].locked = true;
        var stored = frame;
        stored.phase = .pending;
        stored.impacted = false;
        stored.status_done = stored.status_attempt == null;
        stored.ward_return_done = false;
        stored.protection_failed = false;
        stored.protector_reserved = false;
        self.frames[index] = stored;
        return index;
    }

    fn impactFrame(self: *Coordinator, index: usize) !void {
        var frame = self.frames[index].?;
        if (frame.phase != .pending) return error.DoubleImpact;
        if (frame.protector) |protector| {
            const candidate = &self.combatants[protector];
            if (!candidate.eligibleForProtection()) {
                frame.phase = .impacted;
                frame.impacted = true;
                frame.protection_failed = true;
                self.frames[index] = frame;
                self.emit(.{ .tag = .protection_failed, .frame = frame.id, .actor = protector });
                return;
            }
            candidate.locked = true;
            const change = interaction.applyDamage(candidate, frame.amount);
            frame.phase = .impacted;
            frame.impacted = true;
            frame.protector_reserved = true;
            self.frames[index] = frame;
            self.emit(.{ .tag = .impact, .frame = frame.id, .actor = protector, .amount = change.applied, .knocked_out = change.knocked_out });
            return;
        }
        const target = &self.combatants[frame.target];
        const change = interaction.applyDamage(target, frame.amount);
        frame.phase = .impacted;
        frame.impacted = true;
        self.frames[index] = frame;
        self.emit(.{ .tag = .impact, .frame = frame.id, .actor = frame.target, .amount = change.applied, .knocked_out = change.knocked_out });
    }

    fn applyStatus(self: *Coordinator, index: usize) !void {
        var frame = self.frames[index].?;
        if (frame.status_done) return;
        const attempt = frame.status_attempt orelse {
            frame.status_done = true;
            self.frames[index] = frame;
            return;
        };
        const target = &self.combatants[frame.target];
        const outcome = try target.status.apply(
            attempt,
            target.side == .party,
            target.rune == data.turtle_rune,
            target.pointed_hat,
            self.draws,
            &self.log,
        );
        frame.status_done = true;
        self.frames[index] = frame;
        self.emit(.{ .tag = .status, .frame = frame.id, .actor = frame.target, .status_result = outcome.result, .status_class = outcome.class });
    }

    fn release(self: *Coordinator, index: usize, tick: u16) void {
        var frame = self.frames[index].?;
        if (!frame.impacted) return;
        if (!frame.protection_failed and frame.protector_reserved) {
            if (frame.protector_release) |release_tick| if (release_tick == tick) {
                if (frame.protector) |protector| {
                    const knocked = interaction.commitKnockout(&self.combatants[protector]);
                    self.combatants[protector].locked = false;
                    self.emit(.{ .tag = .protector_release, .frame = frame.id, .actor = protector, .knocked_out = knocked });
                }
            };
        }
        if (!frame.protection_failed) if (frame.ward_return_start) |start| if (start == tick and !frame.ward_return_done) {
            frame.ward_return_done = true;
            self.frames[index] = frame;
            self.emit(.{ .tag = .ward_return, .frame = frame.id, .actor = frame.target });
        };
        if (frame.target_release == tick) {
            const knocked = interaction.commitKnockout(&self.combatants[frame.target]);
            self.combatants[frame.target].locked = false;
            self.emit(.{ .tag = .target_release, .frame = frame.id, .actor = frame.target, .knocked_out = knocked });
        }
        if (frame.owner_release == tick) {
            const knocked = interaction.commitKnockout(&self.combatants[frame.owner]);
            self.combatants[frame.owner].locked = false;
            self.emit(.{ .tag = .owner_release, .frame = frame.id, .actor = frame.owner, .knocked_out = knocked });
        }
        frame = self.frames[index].?;
        const status_released = frame.status_tick == null or frame.status_tick.? <= tick;
        if (frame.phase == .impacted and frame.status_done and status_released and
            tick >= frame.target_release and tick >= frame.owner_release and
            (frame.protector_release == null or tick >= frame.protector_release.?) and
            (frame.ward_return_end == null or tick >= frame.ward_return_end.?))
        {
            self.emit(.{ .tag = .settled, .frame = frame.id, .actor = frame.owner });
            self.frames[index] = null;
        }
    }

    fn step(self: *Coordinator, tick: u16) !void {
        var index: usize = 0;
        while (index < self.frames.len) : (index += 1) {
            const frame = self.frames[index] orelse continue;
            if (frame.phase == .pending and frame.impact == tick) try self.impactFrame(index);
        }
        index = 0;
        while (index < self.frames.len) : (index += 1) {
            const frame = self.frames[index] orelse continue;
            if (frame.phase == .impacted and frame.status_tick != null and frame.status_tick.? == tick and !frame.status_done) {
                try self.applyStatus(index);
            }
        }
        index = 0;
        while (index < self.frames.len) : (index += 1) {
            if (self.frames[index] != null) self.release(index, tick);
        }
    }

    pub fn advance(self: *Coordinator, to: u16) !void {
        if (to < self.now) return error.TimeWentBackwards;
        while (self.now < to) {
            self.now += 1;
            try self.step(self.now);
        }
    }

    pub fn snapshot(self: *const Coordinator) Snapshot {
        var result = Snapshot{ .now = self.now, .actor_count = @intCast(self.combatants.len) };
        for (self.combatants, 0..) |combatant, index| {
            result.actors[index] = .{
                .hp = combatant.hp,
                .active = combatant.active,
                .locked = combatant.locked,
                .pending_damage = combatant.pending_damage,
                .status = combatant.status,
            };
        }
        var count: u8 = 0;
        for (self.frames) |maybe| if (maybe) |frame| {
            result.frames[count] = frame;
            count += 1;
        };
        result.frame_count = count;
        return result;
    }

    pub fn restore(self: *Coordinator, state: Snapshot) !void {
        if (state.schema != 1) return error.InvalidSnapshot;
        if (state.actor_count != self.combatants.len or state.frame_count > self.frames.len) return error.InvalidSnapshot;
        self.frames = @splat(null);
        self.events = undefined;
        self.event_count = 0;
        self.log.reset();
        for (self.combatants, 0..) |*combatant, index| {
            const actor = state.actors[index];
            if (actor.hp > combatant.max_hp) return error.InvalidSnapshot;
            combatant.hp = actor.hp;
            combatant.active = actor.active;
            combatant.locked = actor.locked;
            combatant.pending_damage = actor.pending_damage;
            combatant.status = actor.status;
        }
        var seen: [8]bool = @splat(false);
        for (0..state.frame_count) |index| {
            const frame = state.frames[index];
            for (self.frames) |maybe| if (maybe) |existing| {
                if (existing.id == frame.id) return error.InvalidSnapshot;
            };
            try self.validateFrame(frame, state.now, false);
            if (frame.status_tick) |tick| if (!frame.status_done and tick <= state.now) return error.InvalidSnapshot;
            if (frame.ward_return_start) |tick| if (!frame.ward_return_done and tick <= state.now) return error.InvalidSnapshot;
            if (seen[index]) return error.InvalidSnapshot;
            seen[index] = true;
            self.frames[index] = frame;
        }
        // Every locked actor must be reserved by a frame that has not released it.
        for (self.combatants, 0..) |combatant, actor_index| {
            if (!combatant.locked) continue;
            var covered = false;
            for (self.frames) |maybe| if (maybe) |frame| {
                if (frame.owner == actor_index and state.now < frame.owner_release) covered = true;
                if (frame.target == actor_index and state.now < frame.target_release) covered = true;
                if (frame.protector) |protector| {
                    if (protector == actor_index and (frame.protector_release orelse 0) > state.now and frame.phase == .impacted) covered = true;
                }
            };
            if (!covered) return error.InvalidSnapshot;
        }
        self.now = state.now;
    }
};

test "protection redirects damage, keeps the ward HP and fires ward return once" {
    const hero = interaction.Combatant{ .native_id = 8, .side = .party, .source_slot = 1, .hp = 10, .max_hp = 100, .attack = 10, .defense = 10, .skill = 10 };
    const gremio = interaction.Combatant{ .native_id = 2, .side = .party, .source_slot = 2, .hp = 100, .max_hp = 100, .attack = 10, .defense = 40, .skill = 10 };
    const enemy = interaction.Combatant{ .native_id = 9, .side = .enemy, .source_slot = 8, .hp = 100, .max_hp = 100, .attack = 50, .defense = 10, .skill = 10 };
    var party = [_]interaction.Combatant{ hero, gremio, enemy };
    var draws = battle_rules.Draws{ .values = &.{} };
    var coordinator = Coordinator.init(&party, &draws);
    const impact: u16 = 10;
    const protector_release = impact + data.common_hurt_duration - 1;
    const ward_start = protector_release + 1;
    const ward_end = ward_start + data.ward_return_duration;
    _ = try coordinator.begin(.{
        .id = 1,
        .owner = 2,
        .target = 0,
        .protector = 1,
        .branch = .protected,
        .impact = impact,
        .target_release = ward_end,
        .owner_release = 80,
        .protector_release = protector_release,
        .ward_return_start = ward_start,
        .ward_return_end = ward_end,
        .amount = 50,
    });
    try coordinator.advance(impact);
    try std.testing.expectEqual(@as(u16, 10), party[0].hp);
    try std.testing.expectEqual(@as(u16, 50), party[1].hp);
    try std.testing.expect(party[1].locked);
    try std.testing.expectEqual(Tag.impact, coordinator.eventSlice()[0].tag);
    coordinator.clearEvents();
    try coordinator.advance(protector_release);
    try std.testing.expect(!party[1].locked);
    try std.testing.expectEqual(Tag.protector_release, coordinator.eventSlice()[0].tag);
    coordinator.clearEvents();
    try coordinator.advance(ward_start);
    try std.testing.expectEqual(Tag.ward_return, coordinator.eventSlice()[0].tag);
    coordinator.clearEvents();
    try coordinator.advance(ward_end);
    var returns: usize = 0;
    for (coordinator.eventSlice()) |event| if (event.tag == .ward_return) {
        returns += 1;
    };
    try std.testing.expectEqual(@as(usize, 0), returns);
    try std.testing.expect(!party[0].locked);
    try std.testing.expectEqual(@as(u16, 10), party[0].hp);
}

test "protection failure at impact applies no damage and preserves releases" {
    const hero = interaction.Combatant{ .native_id = 8, .side = .party, .source_slot = 1, .hp = 10, .max_hp = 100, .attack = 10, .defense = 10, .skill = 10 };
    const gremio = interaction.Combatant{ .native_id = 2, .side = .party, .source_slot = 2, .hp = 100, .max_hp = 100, .attack = 10, .defense = 40, .skill = 10 };
    const enemy = interaction.Combatant{ .native_id = 9, .side = .enemy, .source_slot = 8, .hp = 100, .max_hp = 100, .attack = 50, .defense = 10, .skill = 10 };
    var party = [_]interaction.Combatant{ hero, gremio, enemy };
    var draws = battle_rules.Draws{ .values = &.{} };
    var coordinator = Coordinator.init(&party, &draws);
    const impact: u16 = 10;
    const protector_release = impact + data.common_hurt_duration - 1;
    const ward_start = protector_release + 1;
    const ward_end = ward_start + data.ward_return_duration;
    _ = try coordinator.begin(.{
        .id = 2,
        .owner = 2,
        .target = 0,
        .protector = 1,
        .branch = .protected,
        .impact = impact,
        .target_release = ward_end,
        .owner_release = 80,
        .protector_release = protector_release,
        .ward_return_start = ward_start,
        .ward_return_end = ward_end,
        .amount = 50,
    });
    party[1].hp = 0;
    party[1].locked = true;
    try coordinator.advance(impact);
    try std.testing.expectEqual(Tag.protection_failed, coordinator.eventSlice()[0].tag);
    try std.testing.expectEqual(@as(u16, 10), party[0].hp);
    try std.testing.expectEqual(@as(u16, 0), party[1].hp);
    try std.testing.expect(party[1].locked);
    try std.testing.expectEqual(@as(usize, 0), coordinator.log.count);
    coordinator.clearEvents();
    try coordinator.advance(ward_end);
    for (coordinator.eventSlice()) |event| {
        try std.testing.expect(event.tag != .protector_release);
        try std.testing.expect(event.tag != .ward_return);
    }
    try std.testing.expect(party[1].locked);
}

test "simultaneous impacts are processed in begin order" {
    const first = interaction.Combatant{ .native_id = 8, .side = .party, .source_slot = 1, .hp = 100, .max_hp = 100, .attack = 10, .defense = 10, .skill = 10 };
    const second = interaction.Combatant{ .native_id = 2, .side = .party, .source_slot = 2, .hp = 100, .max_hp = 100, .attack = 10, .defense = 10, .skill = 10 };
    const enemy_one = interaction.Combatant{ .native_id = 3, .side = .enemy, .source_slot = 8, .hp = 100, .max_hp = 100, .attack = 10, .defense = 10, .skill = 10 };
    const enemy_two = interaction.Combatant{ .native_id = 4, .side = .enemy, .source_slot = 9, .hp = 100, .max_hp = 100, .attack = 10, .defense = 10, .skill = 10 };
    var party = [_]interaction.Combatant{ first, second, enemy_one, enemy_two };
    var draws = battle_rules.Draws{ .values = &.{} };
    var coordinator = Coordinator.init(&party, &draws);
    _ = try coordinator.begin(.{ .id = 1, .owner = 0, .target = 2, .branch = .hit, .impact = 10, .target_release = 20, .owner_release = 30, .amount = 7 });
    _ = try coordinator.begin(.{ .id = 2, .owner = 1, .target = 3, .branch = .hit, .impact = 10, .target_release = 20, .owner_release = 31, .amount = 11 });
    try coordinator.advance(10);
    try std.testing.expectEqual(@as(usize, 2), coordinator.event_count);
    try std.testing.expectEqual(@as(u8, 1), coordinator.eventSlice()[0].frame);
    try std.testing.expectEqual(@as(u32, 7), coordinator.eventSlice()[0].amount);
    try std.testing.expectEqual(@as(u32, 11), coordinator.eventSlice()[1].amount);
    try std.testing.expectEqual(@as(u16, 93), party[2].hp);
    try std.testing.expectEqual(@as(u16, 89), party[3].hp);
}

test "a second frame cannot reserve a locked owner" {
    const actor = interaction.Combatant{ .native_id = 8, .side = .party, .source_slot = 1, .hp = 100, .max_hp = 100, .attack = 10, .defense = 10, .skill = 10 };
    const target = interaction.Combatant{ .native_id = 3, .side = .enemy, .source_slot = 8, .hp = 100, .max_hp = 100, .attack = 10, .defense = 10, .skill = 10 };
    var party = [_]interaction.Combatant{ actor, target };
    var draws = battle_rules.Draws{ .values = &.{} };
    var coordinator = Coordinator.init(&party, &draws);
    _ = try coordinator.begin(.{ .id = 1, .owner = 0, .target = 1, .branch = .hit, .impact = 10, .target_release = 20, .owner_release = 30, .amount = 1 });
    try std.testing.expectError(error.ActorLocked, coordinator.begin(.{ .id = 2, .owner = 0, .target = 1, .branch = .hit, .impact = 11, .target_release = 21, .owner_release = 30, .amount = 1 }));
}

test "snapshot restores mid-round and refuses tampering" {
    const actor = interaction.Combatant{ .native_id = 8, .side = .party, .source_slot = 1, .hp = 100, .max_hp = 100, .attack = 10, .defense = 10, .skill = 10 };
    const target = interaction.Combatant{ .native_id = 3, .side = .enemy, .source_slot = 8, .hp = 100, .max_hp = 100, .attack = 10, .defense = 10, .skill = 10 };
    var party = [_]interaction.Combatant{ actor, target };
    var draws = battle_rules.Draws{ .values = &.{} };
    var original = Coordinator.init(&party, &draws);
    _ = try original.begin(.{ .id = 1, .owner = 0, .target = 1, .branch = .hit, .impact = 10, .target_release = 20, .owner_release = 30, .amount = 25 });
    try original.advance(10);
    const snapshot = original.snapshot();

    var restored_party = [_]interaction.Combatant{ actor, target };
    var restored_draws = battle_rules.Draws{ .values = &.{} };
    var restored = Coordinator.init(&restored_party, &restored_draws);
    try restored.restore(snapshot);
    original.clearEvents();
    try original.advance(30);
    try restored.advance(30);
    try std.testing.expectEqual(party[0].hp, restored_party[0].hp);
    try std.testing.expectEqual(party[1].hp, restored_party[1].hp);
    try std.testing.expectEqual(original.event_count, restored.event_count);

    var tampered = snapshot;
    tampered.frames[0].phase = .pending;
    tampered.frames[0].impact = tampered.now;
    var third_party = [_]interaction.Combatant{ actor, target };
    var third_draws = battle_rules.Draws{ .values = &.{} };
    var third = Coordinator.init(&third_party, &third_draws);
    try std.testing.expectError(error.ImpactInPast, third.restore(tampered));

    var bad_order = snapshot;
    bad_order.frames[0].owner_release = bad_order.frames[0].impact;
    try std.testing.expectError(error.InvalidReleaseOrder, third.restore(bad_order));
}
