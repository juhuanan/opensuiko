//! Campaign forced party, temporary departures and small-party
//! ownership through the canonical roster.
//!
//! `packet` is the static source projection (108 identities, 78 combat
//! profiles, twelve source operations).  `roster` applies those operations to
//! `party.Snapshot` and carries the loaded/presence/departure sidecar the
//! canonical snapshot does not.  No member field is fabricated or discarded.
const std = @import("std");

pub const source = @import("source.zig");
pub const roster = @import("roster.zig");
pub const max_members = roster.max_members;
pub const max_active = roster.max_active;
pub const max_noncombatants = roster.max_noncombatants;
pub const schema = source.schema;
pub const save_schema = roster.save_schema;
