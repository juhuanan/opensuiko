//! Headquarters domain: castle stages, scene assembly, service windows,
//! roster, services, Stars of Destiny tablet, optional games, and host/launch.
pub const stage = @import("stage.zig");
pub const scene = @import("scene.zig");
pub const windows = @import("windows.zig");
pub const roster = @import("roster/root.zig");
pub const services = @import("services/root.zig");
pub const tablet = @import("tablet/root.zig");
pub const optional_games = @import("optional_games/root.zig");
pub const host = @import("host.zig");
pub const launch = @import("launch.zig");

pub const Host = host.Host;
pub const Snapshot = host.Snapshot;
pub const Screen = host.Screen;
pub const Intent = host.Intent;
pub const Entry = host.Entry;
pub const Interaction = host.Interaction;
pub const InteractionKind = host.InteractionKind;
pub const Blocker = host.Blocker;
pub const ServiceAccess = host.ServiceAccess;
pub const ModeDriver = host.ModeDriver;
pub const ModeInput = host.ModeInput;
pub const ModeReceipt = host.ModeReceipt;
pub const ModeFacts = host.ModeFacts;
pub const Construction = host.Host.Construction;

pub const schema = host.schema;
pub const sidecar_schema = host.sidecar_schema;
pub const flag_slots = host.flag_slots;
pub const story_castle_index = host.story_castle_index;
pub const story_castle_mask = host.story_castle_mask;

test {
    _ = host;
}
