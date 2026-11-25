//! Spell and attack effect composition (module surface).
//!
//! Two halves:
//!
//!   * `catalogue` -- the generated, hash-pinned join of presentation resource,
//!     lifetime and phase facts with the spell rules, parsed and validated once;
//!   * `compose` -- the pure timeline that turns that catalogue plus the real
//!     coordinator's contact/finish boundaries into residency/present/actor
//!     requests and one-time contact/finish events.
//!
//! The module owns no scheduler, no action table, no HP write and no random
//! source.

const std = @import("std");

pub const catalogue = @import("catalogue.zig");
pub const compose = @import("compose.zig");
pub const data = @import("combat_systems_data").effect_composition;

pub const version = catalogue.version;
pub const schema = catalogue.schema;
pub const presentation_contract_sha256 = data.presentation_contract_sha256;
pub const presentation_correction_code = data.presentation_correction_code;

pub const Packet = catalogue.Packet;
pub const PresentationContract = catalogue.PresentationContract;
pub const Family = catalogue.Family;
pub const Spell = catalogue.Spell;
pub const Attack = catalogue.Attack;
pub const RuleEffect = catalogue.RuleEffect;
pub const Step = catalogue.Step;
pub const Coverage = catalogue.Coverage;

pub const Kind = compose.Kind;
pub const Phase = compose.Phase;
pub const Blocker = compose.Blocker;
pub const Draw = compose.Draw;
pub const Frame = compose.Frame;
pub const Pending = compose.Pending;
pub const Cue = compose.Cue;
pub const CueKind = compose.CueKind;
pub const Event = compose.Event;
pub const Delivery = compose.Delivery;
pub const Composer = compose.Composer;
pub const Snapshot = compose.Composer.Snapshot;
pub const Error = compose.Error;
pub const max_draws = compose.max_draws;
pub const max_events = compose.max_events;

pub const load = catalogue.load;
pub const validate = catalogue.validate;

pub const beginCast = compose.beginCast;
pub const beginAttack = compose.beginAttack;

/// Load the generated packet embedded in the owned asset module.
pub fn loadAsset(allocator: std.mem.Allocator) !std.json.Parsed(Packet) {
    return catalogue.load(allocator, data.effect_composition_json);
}
