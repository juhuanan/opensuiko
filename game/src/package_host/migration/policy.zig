//! Source save policy for the campaign envelope.
//!
//! The port exposes Save and Load in the Suikoden-style pause menu; the
//! innkeeper only handles staying; saving at floating orbs is a later gameplay
//! feature and must not be invented from a source text label (AGENTS.md §9).
//! Setup is a separate settings owner and never writes a campaign slot.
//!
//! The policy is a pure decision function so tests can enumerate every cause
//! and mode without an I/O or content dependency.

const std = @import("std");

pub const Cause = enum {
    pause_menu_save,
    pause_menu_load,
    inn_stay,
    floating_orb,
    block_checkpoint,
    setup_change,
    post_battle_auto,
};

pub const Presence = enum {
    title,
    world,
    field,
    field_busy,
    battle,
    duel,
    minigame,
    war,
    ending,
    credits,
};

pub const Kind = enum {
    /// An ordinary pause-menu slot write.
    campaign_slot,
    /// Staying at the inn restores HP/status and never writes a campaign slot.
    stay_only,
    /// A block-boundary checkpoint that cannot overwrite a player slot.
    checkpoint_only,
};

pub const Refusal = enum {
    not_a_save,
    setup_is_separate,
    orb_not_source_supported,
    mode_busy,
    pending_uncommitted,
    checkpoint_unavailable,
    no_source_autosave,
};

pub const Decision = union(enum) {
    allow: Kind,
    refuse: Refusal,
};

pub const Input = struct {
    cause: Cause,
    presence: Presence,
    /// A mode result produced but not committed.
    pending: bool = false,
    /// The current block has not yet been checkpointed.
    checkpoint_available: bool = false,
};

pub fn decide(input: Input) Decision {
    switch (input.cause) {
        .inn_stay => return .{ .allow = .stay_only },
        .setup_change => return .{ .refuse = .setup_is_separate },
        .floating_orb => return .{ .refuse = .orb_not_source_supported },
        .post_battle_auto => return .{ .refuse = .no_source_autosave },
        else => {},
    }
    const idle = switch (input.presence) {
        .world, .field => true,
        else => false,
    };
    if (!idle) return .{ .refuse = .mode_busy };
    if (input.pending) return .{ .refuse = .pending_uncommitted };
    switch (input.cause) {
        .pause_menu_save, .pause_menu_load => return .{ .allow = .campaign_slot },
        .block_checkpoint => {
            if (!input.checkpoint_available) return .{ .refuse = .checkpoint_unavailable };
            return .{ .allow = .checkpoint_only };
        },
        else => return .{ .refuse = .not_a_save },
    }
}

pub fn allowsSlot(decision: Decision) bool {
    return switch (decision) {
        .allow => |kind| kind == .campaign_slot,
        .refuse => false,
    };
}

test "the pause menu is the only ordinary slot writer" {
    const idle: Input = .{ .cause = .pause_menu_save, .presence = .field };
    try std.testing.expect(allowsSlot(decide(idle)));
    try std.testing.expect(allowsSlot(decide(.{ .cause = .pause_menu_load, .presence = .world })));
    try std.testing.expect(!allowsSlot(decide(.{ .cause = .pause_menu_save, .presence = .battle })));
    try std.testing.expect(!allowsSlot(decide(.{ .cause = .pause_menu_save, .presence = .field_busy })));
    try std.testing.expectEqual(Refusal.pending_uncommitted, decide(.{ .cause = .pause_menu_save, .presence = .field, .pending = true }).refuse);
}

test "inn, orbs, Setup and autosave have distinct non-slot outcomes" {
    try std.testing.expectEqual(Kind.stay_only, decide(.{ .cause = .inn_stay, .presence = .field }).allow);
    try std.testing.expectEqual(Refusal.orb_not_source_supported, decide(.{ .cause = .floating_orb, .presence = .world }).refuse);
    try std.testing.expectEqual(Refusal.setup_is_separate, decide(.{ .cause = .setup_change, .presence = .title }).refuse);
    try std.testing.expectEqual(Refusal.no_source_autosave, decide(.{ .cause = .post_battle_auto, .presence = .world }).refuse);
    try std.testing.expectEqual(Refusal.checkpoint_unavailable, decide(.{ .cause = .block_checkpoint, .presence = .world }).refuse);
    try std.testing.expectEqual(Kind.checkpoint_only, decide(.{ .cause = .block_checkpoint, .presence = .world, .checkpoint_available = true }).allow);
}
