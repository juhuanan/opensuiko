//! Action application entry point for the auxiliary, delayed-callback,
//! projectile and interrupted-return families.
//!
//! `content` is the typed, hash-pinned action-application asset; `apply` is
//! the actor-state consumer called from the battle path.

pub const content = @import("content.zig");
pub const apply = @import("apply.zig");
pub const data = @import("battle_systems_data").action_application;

pub const schema = content.schema;
pub const Content = content.Content;
pub const Record = content.Record;
pub const Projectile = content.Projectile;
pub const load = content.load;

pub const Session = apply.Session;
pub const Action = apply.Action;
pub const Actor = apply.Actor;
pub const Host = apply.Host;
pub const Update = apply.Update;
pub const ProjectileState = apply.ProjectileState;
pub const InterruptReason = apply.InterruptReason;
pub const ReleaseReason = apply.ReleaseReason;
pub const Source = apply.Source;
pub const DrawList = apply.DrawList;
pub const max_checkpoint_bytes = apply.max_checkpoint_bytes;
