//! Ordinary-control ownership model.
//!
//! One owner consumes ordinary input at a time: the foot-world traveller, the
//! field scene, the shared pause/party menu, or the combat session.  The
//! classification below is a direct mirror of the dispatch that already exists
//! in `game/src/world_travel.zig::State.advance`:
//!
//!   * `world_menu` (pause menu opened from the world) or a non-closed
//!     `menu.phase` owns the frame (`world_travel.zig` lines 359-376 and
//!     384-389, 493-498 at snapshot 1dba051b);
//!   * otherwise `link.travel.mode` picks the owner (lines 377-407 world,
//!     407-526 field, 527-535 battle);
//!   * `field_pending` and `battle_pending` are still world frames: the world
//!     branch is the one that admits them (lines 377-405).
//!
//! This module is deliberately free of state: it names owners, classifies an
//! observation, and states the clear/retain policy for each real boundary.
//! The exporter (the extraction pipeline) proves the mirrored source
//! facts and hashes them, so a later edit to the shared owner cannot silently
//! invalidate this table.

const std = @import("std");

/// Direction in ordinary-input order, matching `controller.Output.direction`
/// (a `field.Direction`).  The caller maps explicitly to `world.Direction`
/// (`north/east/south/west`) and keeps that mapping in one place.
pub const Direction = enum(u2) { up, right, down, left };

/// The four ordinary control owners.
pub const Owner = enum(u2) {
    world,
    field,
    party,
    battle,

    pub fn name(self: Owner) []const u8 {
        return switch (self) {
            .world => "world",
            .field => "field",
            .party => "party",
            .battle => "battle",
        };
    }
    pub fn usesMovementHold(self: Owner) bool {
        return self == .world or self == .field;
    }
    pub fn usesNavigation(self: Owner) bool {
        return self != .world;
    }
    pub fn usesCombat(self: Owner) bool {
        return self == .battle;
    }
};

/// The shared travel mode, without importing the shared module.
pub const TravelMode = enum(u3) { world, field_pending, field, battle_pending, battle };

/// Everything this package needs to know about the shared owner.  The caller
/// fills these from the live `world_travel.State`; no other field is consulted.
pub const Observation = struct {
    travel_mode: TravelMode = .world,
    world_menu: bool = false,
    menu_closed: bool = true,
    /// Platform focus.  A lost focus ends the current frame's ownership and
    /// requires a release before any button can act again.
    focused: bool = true,
    /// Shared admission gate for opening the pause menu in this frame: false
    /// while a dialogue/service is active, while field motion is pending, or
    /// while rest ticks run (`pause_menu.zig` lines 85-96; `world_travel.zig`
    /// line 493).  Used only for same-frame prediction, never to suppress an
    /// already-open menu.
    menu_admissible: bool = true,
};

pub fn classify(obs: Observation) Owner {
    if (!obs.menu_closed or obs.world_menu) return .party;
    return switch (obs.travel_mode) {
        .world, .field_pending, .battle_pending => .world,
        .field => .field,
        .battle => .battle,
    };
}

/// The boundaries that actually exist in the snapshot's shared dispatch.
/// Anything not listed is not a supported ownership boundary; presenting it is
/// an error, not a silent no-op.
pub const Transition = enum(u4) {
    world_to_field,
    world_to_battle,
    world_to_party,
    field_to_world,
    field_to_party,
    battle_to_world,
    party_to_world,
    party_to_field,
    reload,
    none,

    pub fn from(self: Transition) ?Owner {
        return switch (self) {
            .world_to_field, .world_to_battle, .world_to_party => .world,
            .field_to_world, .field_to_party => .field,
            .battle_to_world => .battle,
            .party_to_world, .party_to_field => .party,
            .reload, .none => null,
        };
    }
    pub fn to(self: Transition) ?Owner {
        return switch (self) {
            .world_to_field, .party_to_field => .field,
            .world_to_battle => .battle,
            .world_to_party, .field_to_party => .party,
            .field_to_world, .battle_to_world, .party_to_world => .world,
            .reload, .none => null,
        };
    }
    pub fn reason(self: Transition) []const u8 {
        return switch (self) {
            .world_to_field => "field_entered",
            .world_to_battle => "battle_started",
            .world_to_party => "world_menu_opened",
            .field_to_world => "world_returned",
            .field_to_party => "field_menu_opened",
            .battle_to_world => "battle_returned",
            .party_to_world => "menu_closed_to_world",
            .party_to_field => "menu_closed_to_field",
            .reload => "checkpoint_loaded",
            .none => "none",
        };
    }
};

/// Return the real boundary, or the empty transition when ownership is
/// unchanged.  `null` means the pair is not an admitted boundary: the caller
/// must keep the current owner and record the refusal.
pub fn transition(from: Owner, to: Owner) ?Transition {
    if (from == to) return .none;
    return switch (from) {
        .world => switch (to) {
            .field => .world_to_field,
            .battle => .world_to_battle,
            .party => .world_to_party,
            .world => .none,
        },
        .field => switch (to) {
            .world => .field_to_world,
            .party => .field_to_party,
            // Source state: a battle is admitted from the foot world only
            // (`world_travel.zig` battle branch; field branch has no battle
            // event).  Field->battle is therefore not an ownership boundary.
            .battle => null,
            .field => .none,
        },
        .battle => switch (to) {
            .world => .battle_to_world,
            // The battle branch never consults `input.menu`, so the menu cannot
            // take ownership during combat in this snapshot.
            .party, .field, .battle => null,
        },
        .party => switch (to) {
            .world => .party_to_world,
            .field => .party_to_field,
            .battle, .party => null,
        },
    };
}

/// What a boundary does to each input family.
///
/// `retain_direction` keeps the held movement vector so walking does not stop
/// or stutter across a field/world handoff; the direction is *not* re-encoded
/// as a navigation edge.  `block_navigation_until_release` is the fix for a
/// held Up: the shared controller repeats `navigation` every 0.09 s while a
/// direction is held, and that repeat must not move a fresh owner's cursor.
/// One-shot edges (confirm/cancel/menu) issued on the boundary frame are
/// withheld because they were aimed at the departing owner or are ambiguous;
/// a later genuine press in the new owner is delivered normally.
pub const Policy = struct {
    retain_direction: bool,
    block_navigation_until_release: bool,
    withhold_boundary_edges: bool,
    retain_physical_up: bool = true,
};

pub fn policy(t: Transition) Policy {
    return switch (t) {
        .reload => .{ .retain_direction = false, .block_navigation_until_release = true, .withhold_boundary_edges = true, .retain_physical_up = false },
        .none => .{ .retain_direction = true, .block_navigation_until_release = false, .withhold_boundary_edges = false },
        .world_to_field, .party_to_field, .field_to_world, .party_to_world, .battle_to_world => .{
            .retain_direction = true,
            .block_navigation_until_release = true,
            .withhold_boundary_edges = true,
        },
        .world_to_party, .field_to_party => .{
            .retain_direction = false,
            .block_navigation_until_release = true,
            .withhold_boundary_edges = true,
        },
        .world_to_battle => .{
            .retain_direction = false,
            .block_navigation_until_release = true,
            .withhold_boundary_edges = true,
        },
    };
}

/// Same-frame prediction of a menu opening.  The shared field branch calls
/// `pause.tick` in the *same* `advance` that admits `input.menu`
/// (`world_travel.zig` 493-498 -> `world_field.zig::updateField` 124-128), so a
/// confirm edge sampled in that frame would select the first menu row.  The
/// same request in the world branch is admitted one frame later, so dropping
/// the edge there is conservative but harmless.
pub fn predictsMenu(obs: Observation, menu_requested: bool) bool {
    if (!obs.focused or !obs.menu_closed or obs.world_menu) return false;
    if (!obs.menu_admissible) return false;
    const current = classify(obs);
    // The battle branch never reads `input.menu`, so there is no same-advance
    // menu to protect there.
    return menu_requested and (current == .world or current == .field);
}

test "classification mirrors the shared dispatch order" {
    const world = Observation{ .travel_mode = .world };
    try std.testing.expectEqual(Owner.world, classify(world));
    try std.testing.expectEqual(Owner.world, classify(.{ .travel_mode = .field_pending }));
    try std.testing.expectEqual(Owner.world, classify(.{ .travel_mode = .battle_pending }));
    try std.testing.expectEqual(Owner.field, classify(.{ .travel_mode = .field }));
    try std.testing.expectEqual(Owner.battle, classify(.{ .travel_mode = .battle }));
    // The menu wins over every travel mode; `world_menu` wins when the mode is
    // temporarily reset to world by the menu-opening branch.
    try std.testing.expectEqual(Owner.party, classify(.{ .travel_mode = .field, .menu_closed = false }));
    try std.testing.expectEqual(Owner.party, classify(.{ .travel_mode = .world, .world_menu = true }));
}

test "only real boundaries are admitted" {
    try std.testing.expectEqual(Transition.world_to_field, transition(.world, .field).?);
    try std.testing.expectEqual(Transition.world_to_battle, transition(.world, .battle).?);
    try std.testing.expectEqual(Transition.field_to_world, transition(.field, .world).?);
    try std.testing.expectEqual(Transition.battle_to_world, transition(.battle, .world).?);
    try std.testing.expectEqual(Transition.party_to_field, transition(.party, .field).?);
    try std.testing.expect(transition(.field, .battle) == null);
    try std.testing.expect(transition(.battle, .party) == null);
    try std.testing.expect(transition(.battle, .field) == null);
    try std.testing.expect(transition(.party, .battle) == null);
    try std.testing.expectEqual(Transition.none, transition(.world, .world).?);
}

test "every admitted transition carries a policy and its owner pair" {
    const all = [_]Transition{ .world_to_field, .world_to_battle, .world_to_party, .field_to_world, .field_to_party, .battle_to_world, .party_to_world, .party_to_field, .reload };
    for (all) |item| {
        const p = policy(item);
        try std.testing.expect(p.withhold_boundary_edges);
        if (item != .reload) {
            const from = item.from().?;
            const to = item.to().?;
            try std.testing.expectEqual(item, transition(from, to).?);
            // Movement hold survives only into an owner that walks.
            try std.testing.expectEqual(to.usesMovementHold(), p.retain_direction);
            try std.testing.expect(p.block_navigation_until_release);
        }
    }
    try std.testing.expect(!policy(.reload).retain_physical_up);
    try std.testing.expect(!policy(.none).withhold_boundary_edges);
}

test "menu prediction is limited to an admissible same-frame open" {
    try std.testing.expect(predictsMenu(.{ .travel_mode = .field }, true));
    try std.testing.expect(!predictsMenu(.{ .travel_mode = .field }, false));
    try std.testing.expect(!predictsMenu(.{ .travel_mode = .field, .menu_closed = false }, true));
    try std.testing.expect(!predictsMenu(.{ .travel_mode = .field, .menu_admissible = false }, true));
    try std.testing.expect(!predictsMenu(.{ .travel_mode = .field, .focused = false }, true));
    try std.testing.expect(!predictsMenu(.{ .travel_mode = .battle }, true));
}
