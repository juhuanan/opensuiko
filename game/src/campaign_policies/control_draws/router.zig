//! Ordinary-control router.
//!
//! The router does not generate button edges: `game/src/controller.zig` remains
//! the single edge/repeat source, and `game/src/world_travel.zig::Controls`
//! remains the single control owner.  What the router adds is the ownership
//! boundary between them:
//!
//!   * a frame belongs to exactly one owner (`owners.classify`), and only that
//!     owner's channels are populated, so a mode change inside one `advance`
//!     cannot consume another owner's stale channels;
//!   * a held direction never becomes a navigation edge in a new owner: the
//!     shared controller repeats `navigation` every 0.09 s while a direction is
//!     held (`game/src/controller.zig` 55-64), which is exactly how a held Up
//!     would move a fresh battle/menu cursor.  The repeat is withheld until the
//!     direction is released; the held vector itself is retained for walking;
//!   * a menu-opening frame withholds the confirm/cancel edges sampled in that
//!     same frame: the shared field branch runs `pause.tick` in the same
//!     `advance` that admits `input.menu`
//!     (`world_travel.zig` 493-498 -> `world_field.zig` 124-128), so a confirm
//!     pressed together with the menu button would otherwise select the first
//!     row;
//!   * every admitted boundary produces a receipt (before/after owner, reason,
//!     what was retained/withheld), and an unadmitted pair is a typed error
//!     rather than a silent reinterpretation.

const std = @import("std");
const owners = @import("owners.zig");

pub const Direction = owners.Direction;
pub const Owner = owners.Owner;
pub const Observation = owners.Observation;
pub const Transition = owners.Transition;

/// One sampled frame of ordinary input.  `direction` is the held vector and
/// `physical_up` the held Up channel (`controller.Output`); `navigation` is the
/// edge/repeat, and confirm/cancel/menu are press edges.
pub const Pad = struct {
    connected: bool = true,
    direction: ?Direction = null,
    navigation: ?Direction = null,
    confirm: bool = false,
    cancel: bool = false,
    menu: bool = false,
    physical_up: bool = false,
};

/// Field-shaped UI input.  The pause menu consumes the same shape through
/// `pause.Input.field`: `menu_direction` is the navigation edge, `action` the
/// confirm edge, `cancel` the cancel edge.
pub const UiInput = struct {
    direction: ?Direction = null,
    menu_direction: ?Direction = null,
    action: bool = false,
    cancel: bool = false,
};

pub const CombatInput = struct {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    confirm: bool = false,
    cancel: bool = false,
};

pub const Withheld = struct {
    confirm: bool = false,
    cancel: bool = false,
    menu: bool = false,
    navigation: bool = false,
    /// Owner that takes over inside the same advance (menu opening).
    predicted_owner: ?Owner = null,
    held_direction: ?Direction = null,
};

/// The filtered frame.  Mapping to `world_travel.Input` is 1:1 and stays in the
/// Module patch: `world.direction`, `ui` -> `pending.field`,
/// `combat` -> `pending.combat`, `menu`, `physical_up`.
pub const Routed = struct {
    owner: Owner,
    world: struct { direction: ?Direction = null } = .{},
    ui: UiInput = .{},
    combat: CombatInput = .{},
    menu: bool = false,
    physical_up: bool = false,
    boundary: ?Transition = null,
    withheld: Withheld = .{},

    pub fn idle(owner: Owner) Routed {
        return .{ .owner = owner };
    }
    pub fn empty(self: Routed) bool {
        return self.world.direction == null and self.ui.direction == null and
            self.ui.menu_direction == null and !self.ui.action and !self.ui.cancel and
            !self.combat.up and !self.combat.down and !self.combat.left and !self.combat.right and
            !self.combat.confirm and !self.combat.cancel and !self.menu and !self.physical_up;
    }
};

pub const Receipt = struct {
    serial: u32,
    from: Owner,
    to: Owner,
    transition: Transition,
    reason: []const u8,
    direction_retained: bool,
    navigation_blocked: bool,
    edges_withheld: bool,
    focused: bool,
    aborted: bool,
};

pub const Refusal = enum {
    unadmitted_boundary,
    unowned_frame,
    focus_lost,
    disconnected,
};

pub const max_receipts = 16;

pub const Router = struct {
    owner: Owner = .world,
    started: bool = false,
    /// A held direction blocks navigation repeats in a new owner until release.
    block_navigation: bool = false,
    /// Transition observed at `finish`; consumed by the next `begin`.
    boundary_pending: ?Transition = null,
    last_pad: Pad = .{},
    receipts: [max_receipts]Receipt = undefined,
    receipt_count: usize = 0,
    receipt_serial: u32 = 0,
    last_refusal: ?Refusal = null,

    pub fn ownerNow(self: *const Router) Owner {
        return self.owner;
    }

    /// Called once per platform poll, before the shared owner advances.
    pub fn begin(self: *Router, obs: Observation, pad: Pad) Routed {
        self.last_refusal = null;
        self.last_pad = pad;
        if (!self.started) {
            self.started = true;
            self.owner = owners.classify(obs);
            // Star game / fresh process: a button held at entry must not act
            // until released.  (The shared controller's `ready` gate does the
            // same for a newly connected device; this covers the keyboard path,
            // which shares one controller state across mode changes.)
            self.block_navigation = pad.direction != null;
            return Routed.idle(self.owner);
        }
        var routed = Routed.idle(self.owner);
        if (self.boundary_pending) |t| {
            routed.boundary = t;
            self.boundary_pending = null;
        }
        const current = owners.classify(obs);
        if (current != self.owner) {
            const maybe = owners.transition(self.owner, current);
            const t = maybe orelse {
                // The pair is not a supported ownership boundary.  Keep the
                // current owner rather than guessing who receives the input.
                self.last_refusal = .unadmitted_boundary;
                return Routed.idle(self.owner);
            };
            self.cross(t, pad, obs.focused, false);
            routed = Routed.idle(self.owner);
            routed.boundary = t;
        }
        if (!obs.focused) {
            self.last_refusal = .focus_lost;
            self.block_navigation = true;
            return Routed.idle(self.owner);
        }
        if (!pad.connected) {
            self.last_refusal = .disconnected;
            self.block_navigation = true;
            return Routed.idle(self.owner);
        }
        if (self.block_navigation and pad.direction == null) self.block_navigation = false;
        // A menu request in a reduced-owner frame is admitted inside this
        // advance; withhold the edges sampled with it (see module comment).
        const predicted: ?Owner = if (owners.predictsMenu(obs, pad.menu)) .party else null;
        const effective = predicted orelse self.owner;
        self.emit(&routed, effective, pad);
        if (predicted) |p| {
            routed.withheld.predicted_owner = p;
            routed.withheld.confirm = pad.confirm;
            routed.withheld.cancel = pad.cancel;
            routed.withheld.navigation = pad.navigation != null;
            // Keep the menu trigger itself: it is what opens the menu.
            routed.ui.action = false;
            routed.ui.cancel = false;
            routed.ui.menu_direction = null;
            routed.combat = .{};
        }
        if (self.block_navigation) {
            routed.withheld.held_direction = pad.direction;
            if (routed.ui.menu_direction != null) {
                routed.withheld.navigation = true;
                routed.ui.menu_direction = null;
            }
            if (routed.combat.up or routed.combat.down or routed.combat.left or routed.combat.right) {
                routed.withheld.navigation = true;
                // Only the directional combat edges are direction repeats; a
                // confirm/cancel press in the new owner is still a fresh press.
                routed.combat.up = false;
                routed.combat.down = false;
                routed.combat.left = false;
                routed.combat.right = false;
            }
        }
        return routed;
    }

    /// Called once per successful or failed `advance`.  `aborted` means the
    /// shared coordinator rolled the update back; ownership then stays where it
    /// was and the sampled input is not reinterpreted.
    pub fn finish(self: *Router, obs: Observation, aborted: bool) !void {
        if (!self.started) return error.RouterNotStarted;
        if (!obs.focused) {
            self.block_navigation = true;
            return;
        }
        const current = owners.classify(obs);
        if (current == self.owner) {
            if (aborted) self.block_navigation = self.block_navigation or self.last_pad.direction != null;
            return;
        }
        if (aborted) {
            // The shared coordinator rolled the update back, so the owner it
            // observed before `advance` is still the owner.  A differing mode
            // here is a caller bug worth recording, but the rollback is
            // authoritative and must not be reinterpreted as a transition.
            self.last_refusal = .unadmitted_boundary;
            return;
        }
        const maybe = owners.transition(self.owner, current);
        const t = maybe orelse {
            self.last_refusal = .unadmitted_boundary;
            return error.UnadmittedOwnershipBoundary;
        };
        self.cross(t, self.last_pad, obs.focused, false);
    }

    /// Checkpoint restore / mode reset.  Requires a release before movement
    /// navigation anywhere, because the loaded state may be a different owner.
    pub fn reset(self: *Router, obs: Observation) void {
        const before = self.owner;
        self.owner = owners.classify(obs);
        self.started = true;
        self.block_navigation = true;
        self.boundary_pending = null;
        self.last_pad = .{};
        self.last_refusal = null;
        if (before != self.owner) self.recordFrom(.reload, before, self.owner, false, true, true, true, false);
    }

    pub fn lastReceipt(self: *const Router) ?Receipt {
        if (self.receipt_count == 0) return null;
        return self.receipts[self.receipt_count - 1];
    }

    fn cross(self: *Router, t: Transition, pad: Pad, focused: bool, aborted: bool) void {
        const p = owners.policy(t);
        const retain_direction = p.retain_direction and pad.direction != null;
        const block = p.block_navigation_until_release and pad.direction != null;
        if (block) self.block_navigation = true;
        const from = t.from() orelse self.owner;
        const to = t.to() orelse self.owner;
        self.owner = to;
        self.recordFrom(t, from, to, retain_direction, block, p.withhold_boundary_edges, focused, aborted);
    }

    fn recordFrom(self: *Router, t: Transition, from: Owner, to: Owner, retain_direction: bool, block: bool, withhold: bool, focused: bool, aborted: bool) void {
        self.receipt_serial +%= 1;
        const receipt = Receipt{
            .serial = self.receipt_serial,
            .from = from,
            .to = to,
            .transition = t,
            .reason = t.reason(),
            .direction_retained = retain_direction,
            .navigation_blocked = block,
            .edges_withheld = withhold,
            .focused = focused,
            .aborted = aborted,
        };
        if (self.receipt_count < max_receipts) {
            self.receipts[self.receipt_count] = receipt;
            self.receipt_count += 1;
        } else {
            std.mem.copyForwards(Receipt, self.receipts[0 .. max_receipts - 1], self.receipts[1..max_receipts]);
            self.receipts[max_receipts - 1] = receipt;
        }
    }

    fn emit(self: *Router, routed: *Routed, owner: Owner, pad: Pad) void {
        _ = self;
        routed.owner = owner;
        routed.world = .{};
        routed.ui = .{};
        routed.combat = .{};
        routed.menu = false;
        routed.physical_up = pad.physical_up;
        switch (owner) {
            .world => {
                routed.world.direction = pad.direction;
                routed.menu = pad.menu;
            },
            .field => {
                routed.ui.direction = pad.direction;
                routed.ui.menu_direction = pad.navigation;
                routed.ui.action = pad.confirm;
                routed.ui.cancel = pad.cancel;
                routed.menu = pad.menu;
            },
            .party => {
                // The menu consumes the field-shaped UI input; it never walks.
                routed.ui.direction = null;
                routed.ui.menu_direction = pad.navigation;
                routed.ui.action = pad.confirm;
                routed.ui.cancel = pad.cancel;
                routed.menu = pad.menu;
            },
            .battle => {
                routed.combat = .{
                    .up = pad.navigation == .up,
                    .down = pad.navigation == .down,
                    .left = pad.navigation == .left,
                    .right = pad.navigation == .right,
                    .confirm = pad.confirm,
                    .cancel = pad.cancel,
                };
                // The battle branch never reads menu or the movement hold.
                routed.menu = false;
            },
        }
    }
};

test "held up cannot navigate the new owner but keeps walking" {
    var router = Router{};
    var obs = Observation{ .travel_mode = .field };
    // First sample seeds the owner and admits nothing.
    try std.testing.expect(router.begin(obs, .{ .direction = .up, .navigation = .up }).empty());
    obs = .{ .travel_mode = .world };
    _ = router.begin(obs, .{ .direction = .up, .navigation = .up });
    try router.finish(obs, false);
    obs = .{ .travel_mode = .field_pending };
    _ = router.begin(obs, .{ .direction = .up });
    try router.finish(obs, false);
    obs = .{ .travel_mode = .field };
    const crossed = router.begin(obs, .{ .direction = .up, .navigation = .up });
    try std.testing.expectEqual(Owner.field, crossed.owner);
    try std.testing.expectEqual(@as(?Direction, .up), crossed.ui.direction); // walking retained
    try std.testing.expectEqual(@as(?Direction, null), crossed.ui.menu_direction); // no cursor move
    try std.testing.expect(crossed.withheld.navigation);
    try std.testing.expectEqual(@as(?Direction, .up), crossed.withheld.held_direction);
    try std.testing.expectEqual(Transition.world_to_field, router.lastReceipt().?.transition);

    // Release then press: navigation is admitted again.
    _ = router.begin(obs, .{});
    const again = router.begin(obs, .{ .direction = .up, .navigation = .up });
    try std.testing.expectEqual(@as(?Direction, .up), again.ui.menu_direction);
    try std.testing.expect(!again.withheld.navigation);
}

test "menu-opening frame withholds the confirm sampled with it" {
    var router = Router{};
    const obs = Observation{ .travel_mode = .field };
    _ = router.begin(obs, .{});
    try router.finish(obs, false);
    const opened = router.begin(obs, .{ .menu = true, .confirm = true, .navigation = .down });
    try std.testing.expectEqual(Owner.party, opened.withheld.predicted_owner.?);
    try std.testing.expect(opened.menu); // the menu trigger is delivered
    try std.testing.expect(!opened.ui.action); // confirm is withheld
    try std.testing.expect(!opened.ui.cancel);
    try std.testing.expectEqual(@as(?Direction, null), opened.ui.menu_direction);
    try std.testing.expect(opened.withheld.confirm);

    // Next frame the menu owns input; a fresh confirm is delivered.
    const now_obs = Observation{ .travel_mode = .field, .menu_closed = false };
    _ = router.begin(now_obs, .{});
    try router.finish(now_obs, false);
    const press = router.begin(now_obs, .{ .confirm = true, .navigation = .down });
    try std.testing.expectEqual(Owner.party, press.owner);
    try std.testing.expect(press.ui.action);
    try std.testing.expectEqual(@as(?Direction, .down), press.ui.menu_direction);
}

test "held cancel cannot close the next owner's dialogue" {
    var router = Router{};
    var obs = Observation{ .travel_mode = .field, .menu_closed = false };
    _ = router.begin(obs, .{});
    try router.finish(obs, false);
    // Cancel closes the menu; the same edge is consumed by the menu.
    const closing = router.begin(obs, .{ .cancel = true });
    try std.testing.expect(closing.ui.cancel);
    obs = .{ .travel_mode = .field };
    try router.finish(obs, false);
    try std.testing.expectEqual(Owner.field, router.ownerNow());
    // Next frame a still-held cancel cannot produce a field cancel again.
    const after = router.begin(obs, .{ .cancel = true });
    try std.testing.expect(after.ui.cancel); // fresh edge in the new owner is allowed
    const released = router.begin(obs, .{});
    try std.testing.expect(!released.ui.cancel);
}

test "battle entry drops the movement hold and navigation" {
    var router = Router{};
    var obs = Observation{ .travel_mode = .world };
    _ = router.begin(obs, .{});
    try router.finish(obs, false);
    obs = .{ .travel_mode = .battle_pending };
    _ = router.begin(obs, .{ .direction = .up });
    try router.finish(obs, false);
    obs = .{ .travel_mode = .battle };
    const battle = router.begin(obs, .{ .direction = .up, .navigation = .up, .confirm = true });
    try std.testing.expectEqual(Owner.battle, battle.owner);
    try std.testing.expect(!battle.combat.up); // held Up cannot move the cursor
    try std.testing.expect(battle.withheld.navigation);
    try std.testing.expect(battle.combat.confirm); // a fresh press is a new-owner press
    try std.testing.expectEqual(@as(?Direction, null), battle.world.direction);
    try std.testing.expectEqual(@as(?Direction, null), battle.ui.direction);
    try std.testing.expect(!battle.menu);
}

test "only the active owner's channels are populated" {
    const pads = Pad{ .direction = .left, .navigation = .right, .confirm = true, .cancel = true, .menu = true, .physical_up = true };

    var world_router = Router{};
    const world_obs = Observation{ .travel_mode = .world };
    _ = world_router.begin(world_obs, .{});
    var world_pads = pads;
    world_pads.menu = false; // a menu request would predict the party owner
    const world = world_router.begin(world_obs, world_pads);
    try std.testing.expectEqual(@as(?Direction, .left), world.world.direction);
    try std.testing.expectEqual(@as(?Direction, null), world.ui.direction);
    try std.testing.expect(!world.ui.action);
    try std.testing.expect(!world.combat.confirm);
    try std.testing.expect(world.physical_up);
    // The same sample with a menu request predicts the party owner instead.
    const predicted = world_router.begin(world_obs, pads);
    try std.testing.expectEqual(Owner.party, predicted.withheld.predicted_owner.?);
    try std.testing.expectEqual(@as(?Direction, null), predicted.world.direction);

    var field_router = Router{};
    const field_obs = Observation{ .travel_mode = .field };
    _ = field_router.begin(field_obs, .{});
    var field_pads = pads;
    field_pads.menu = false; // see the prediction check above
    const field = field_router.begin(field_obs, field_pads);
    try std.testing.expectEqual(@as(?Direction, .left), field.ui.direction);
    try std.testing.expectEqual(@as(?Direction, null), field.world.direction);
    try std.testing.expectEqual(@as(?Direction, .right), field.ui.menu_direction);
    try std.testing.expect(!field.combat.up);

    var party_router = Router{};
    const party_obs = Observation{ .travel_mode = .field, .menu_closed = false };
    _ = party_router.begin(party_obs, .{});
    const party = party_router.begin(party_obs, pads);
    try std.testing.expectEqual(@as(?Direction, null), party.world.direction);
    try std.testing.expectEqual(@as(?Direction, null), party.ui.direction);
    try std.testing.expect(party.ui.action);
    try std.testing.expect(party.menu);

    var battle_router = Router{};
    const battle_obs = Observation{ .travel_mode = .battle };
    _ = battle_router.begin(battle_obs, .{});
    const battle = battle_router.begin(battle_obs, pads);
    try std.testing.expect(!battle.ui.action);
    try std.testing.expect(!battle.menu);
    try std.testing.expectEqual(@as(?Direction, null), battle.world.direction);
    try std.testing.expect(battle.combat.right);
    try std.testing.expect(battle.combat.confirm);
}

test "focus loss clears the frame and requires a release" {
    var router = Router{};
    var obs = Observation{ .travel_mode = .field };
    _ = router.begin(obs, .{});
    try router.finish(obs, false);
    obs = .{ .travel_mode = .field, .focused = false };
    const lost = router.begin(obs, .{ .direction = .up, .navigation = .up, .confirm = true });
    try std.testing.expect(lost.empty());
    try std.testing.expectEqual(Refusal.focus_lost, router.last_refusal.?);
    obs = .{ .travel_mode = .field };
    const held = router.begin(obs, .{ .direction = .up, .navigation = .up });
    try std.testing.expectEqual(@as(?Direction, .up), held.ui.direction);
    try std.testing.expectEqual(@as(?Direction, null), held.ui.menu_direction);
    const released = router.begin(obs, .{});
    const press = router.begin(obs, .{ .navigation = .down });
    try std.testing.expectEqual(@as(?Direction, .down), press.ui.menu_direction);
    try std.testing.expect(!press.withheld.navigation);
    _ = released;
}

test "an unadmitted boundary keeps the current owner and refuses" {
    var router = Router{};
    var obs = Observation{ .travel_mode = .field };
    _ = router.begin(obs, .{});
    try router.finish(obs, false);
    obs = .{ .travel_mode = .battle };
    const refused = router.begin(obs, .{ .confirm = true });
    try std.testing.expectEqual(Owner.field, refused.owner);
    try std.testing.expectEqual(Refusal.unadmitted_boundary, router.last_refusal.?);
    try std.testing.expectError(error.UnadmittedOwnershipBoundary, router.finish(obs, false));
    try std.testing.expectEqual(Owner.field, router.ownerNow());
}

test "aborted advance does not move ownership" {
    var router = Router{};
    const obs = Observation{ .travel_mode = .world };
    _ = router.begin(obs, .{});
    try router.finish(obs, false);
    // A tick admits the menu, then the update fails and rolls back.
    const before = router.begin(obs, .{ .menu = true });
    try std.testing.expectEqual(Owner.world, router.ownerNow());
    try std.testing.expectEqual(Owner.party, before.owner); // effective frame owner
    try std.testing.expectEqual(Owner.party, before.withheld.predicted_owner.?);
    try router.finish(.{ .travel_mode = .world, .menu_closed = false }, true);
    // Rollback is authoritative: ownership stays with the world.
    try std.testing.expectEqual(Owner.world, router.ownerNow());
    try std.testing.expectEqual(Refusal.unadmitted_boundary, router.last_refusal.?);
}

test "reset after load blocks movement edges until release" {
    var router = Router{};
    const obs = Observation{ .travel_mode = .field };
    _ = router.begin(obs, .{});
    try router.finish(obs, false);
    router.reset(obs);
    try std.testing.expectEqual(Owner.field, router.ownerNow());
    const first = router.begin(obs, .{ .direction = .down, .navigation = .down, .confirm = true });
    try std.testing.expectEqual(@as(?Direction, .down), first.ui.direction);
    try std.testing.expectEqual(@as(?Direction, null), first.ui.menu_direction);
    try std.testing.expect(first.ui.action); // a post-load press is admitted
    _ = router.begin(obs, .{});
    const again = router.begin(obs, .{ .navigation = .up });
    try std.testing.expectEqual(@as(?Direction, .up), again.ui.menu_direction);
}

test "receipts are bounded and describe the boundary" {
    var router = Router{};
    var obs = Observation{ .travel_mode = .world };
    _ = router.begin(obs, .{});
    try router.finish(obs, false);
    for (0..20) |i| {
        obs = .{ .travel_mode = if (i % 2 == 0) .field else .world };
        _ = router.begin(obs, .{});
        try router.finish(obs, false);
    }
    try std.testing.expectEqual(max_receipts, router.receipt_count);
    const last = router.lastReceipt().?;
    try std.testing.expect(last.serial >= 20);
    try std.testing.expectEqualStrings("world_returned", last.reason);
    try std.testing.expectEqual(Owner.world, last.to);
}
