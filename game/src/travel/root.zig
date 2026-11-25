//! World/field route edges, boat travel, teleportation, ground geometry, and scene admission.

pub const routes = @import("route_consumer.zig");
pub const edges = @import("route_edges.zig");
pub const boat = @import("boat/root.zig");
pub const teleport = @import("teleport/travel.zig");
pub const ground = @import("ground.zig");
pub const constructor = @import("constructor.zig");
pub const admission = @import("admission/root.zig");
pub const composer = @import("composer.zig");
