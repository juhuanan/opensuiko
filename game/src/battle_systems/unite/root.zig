//! Unite catalogue and participant lifecycle.
//!
//! Exports:
//!
//!   * `catalogue` -- the complete 32-entry source catalogue, parsed once from
//!     the generated, hash-pinned Unite asset;
//!   * `lifecycle` -- the atomic Unite boundary (plan/commit/impact/finish/undo)
//!     over the existing action coordinator's `battle_rules.Draws` stream;
//!   * `data` -- the generated asset with its digests.
//!
//! The module owns no scheduler, no action table, no enemy policy and no random
//! source. The battle owner integrates these rules with its shared draw stream;
//! imported actor tracks can finish participants separately after controller
//! handoff.

const std = @import("std");

pub const catalogue = @import("catalogue.zig");
pub const lifecycle = @import("lifecycle.zig");
pub const data = @import("battle_systems_data").unite;

pub const version = data.version;
pub const schema = catalogue.schema;
pub const boundary_schema = lifecycle.schema;

pub const Record = catalogue.Record;
pub const Catalogue = catalogue.Catalogue;
pub const TargetRule = catalogue.TargetRule;
pub const EffectGate = catalogue.EffectGate;
pub const Family = catalogue.Family;
pub const Blocker = catalogue.Blocker;
pub const Outcome = catalogue.Outcome;

pub const Slot = lifecycle.Slot;
pub const SlotState = lifecycle.SlotState;
pub const CommandWrite = lifecycle.CommandWrite;
pub const View = lifecycle.View;
pub const Request = lifecycle.Request;
pub const Boundary = lifecycle.Boundary;
pub const Host = lifecycle.Host;
pub const Refusal = lifecycle.Refusal;
pub const Failure = lifecycle.Failure;
pub const Impact = lifecycle.Impact;
pub const PlanResult = lifecycle.PlanResult;
pub const Skip = lifecycle.Skip;
pub const Stage = lifecycle.Stage;
pub const CommandKind = lifecycle.CommandKind;
pub const RecoveryTick = lifecycle.RecoveryTick;
pub const rules = lifecycle.rules;

/// Parse and validate the catalogue embedded in the generated packet.
pub fn load(allocator: std.mem.Allocator) !Catalogue {
    return Catalogue.init(allocator, data.unite_catalogue_json);
}

pub const plan = lifecycle.plan;
pub const commit = lifecycle.commitBoundary;
pub const impact = lifecycle.impactBoundary;
pub const impactSequenceTarget = lifecycle.impactSequenceTarget;
pub const finish = lifecycle.finishBoundary;
pub const undo = lifecycle.undoBoundaryPublic;
pub const tickRecovery = lifecycle.tickRecovery;
pub const allows = lifecycle.allows;
pub const roundReset = lifecycle.roundReset;
pub const memberMark = lifecycle.memberMark;
