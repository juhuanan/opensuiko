//! Qualified ordinary party action adapter.
//!
//! `actions` is the typed, hash-pinned runtime asset derived from the reviewed
//! ordinary-action contract and sprite residency.  `adapter` is the per-owner action
//! consumer called from the existing battle path.

pub const actions = @import("actions.zig");
pub const adapter = @import("adapter.zig");
pub const data = @import("campaign_policies_data").party_actions;

pub const Set = adapter.Set;
pub const Host = adapter.Host;
pub const Command = adapter.Command;
pub const Update = adapter.Update;
pub const Effect = adapter.Effect;
pub const EffectKind = adapter.EffectKind;
pub const Emission = adapter.Emission;
pub const BoundaryName = adapter.BoundaryName;
