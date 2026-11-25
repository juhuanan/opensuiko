//! Module surface used by the campaign-the host.
//!
//! The package modules keep their own dependency names (`rules`, `plan`,
//! `bridge`) because that is the contract their focused gate compiles against.
//! This file only re-exports them so a production owner imports one module.

pub const rules = @import("rules.zig");
pub const plan = @import("plan.zig");
pub const bridge = @import("bridge.zig");
pub const asset = @import("battle_systems_data").spell_rules;

pub const loadRules = rules.load;
pub const max_targets = rules.max_targets;
