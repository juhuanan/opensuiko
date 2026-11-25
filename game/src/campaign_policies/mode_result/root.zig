//! Owned entry point: the shared mode-result publication/retry
//! transaction.  Runtime callers import this module; the durable envelope is
//! `host.Snapshot`.  Asset data is a separate module so the transaction stays
//! free of embedded content.
pub const model = @import("model.zig");
pub const host = @import("host.zig");

pub const schema = model.schema;
pub const result_schema = model.result_schema;
pub const max_effects = model.max_effects;
pub const max_members = model.max_members;
pub const shared_slots = model.shared_slots;
pub const money_cap = model.money_cap;
pub const max_retries = model.max_retries;

pub const Id = model.Id;
pub const Sha = model.Sha;
pub const Owner = model.Owner;
pub const ResultKind = model.ResultKind;
pub const Facing = model.Facing;
pub const Place = model.Place;
pub const Status = model.Status;
pub const Camera = model.Camera;
pub const Stack = model.Stack;
pub const Member = model.Member;
pub const Party = model.Party;
pub const WarehouseEntry = model.WarehouseEntry;
pub const Store = model.Store;
pub const EffectKind = model.EffectKind;
pub const EffectPayload = model.EffectPayload;
pub const Effect = model.Effect;
pub const Expected = model.Expected;
pub const Result = model.Result;

pub const Host = host.Host;
pub const Pending = host.Pending;
pub const Staged = host.Staged;
pub const Outcome = host.Outcome;
pub const Snapshot = host.Snapshot;
pub const verifyExpected = host.verifyExpected;

pub const rosterDigest = model.rosterDigest;
pub const ledgerDigest = model.ledgerDigest;
pub const storyDigest = model.storyDigest;
pub const storeDigest = model.storeDigest;
pub const modeDigest = model.modeDigest;
pub const resultDigest = model.resultDigest;
