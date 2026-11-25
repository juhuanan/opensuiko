//! Combat audio integration module surface.
//!
//! The host is generic over its planner so callers can bind an accepted
//! planner adapter without editing this package: implement the documented
//! protocol (`host.zig` module doc) and instantiate `Host(YourAdapter)`.

pub const plan = @import("plan.zig");
pub const events = @import("events.zig");
pub const trace = @import("trace.zig");
pub const host = @import("host.zig");
pub const planner_double = @import("planner_double.zig");

pub const Unbound = planner_double.Unbound;
pub const Double = planner_double.Double;

pub const Request = host.Request;
pub const Receipt = host.Receipt;
pub const SceneSink = host.SceneSink;
pub const Port = host.Port;
pub const Disposition = host.Disposition;
pub const Service = host.Service;
pub const Playback = host.Playback;
pub const Owners = host.Owners;
pub const BankOwner = host.BankOwner;
pub const Class = host.Class;
pub const Classification = host.Classification;
pub const classifyCommand = host.classifyCommand;

pub fn Host(comptime Planner: type) type {
    return host.Host(Planner);
}
