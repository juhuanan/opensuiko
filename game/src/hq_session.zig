//! Production constructor for the headquarters host.
const std = @import("std");
const hq = @import("hq");
const launch = hq.launch;
const journey = @import("journey");

pub fn create(allocator: std.mem.Allocator, context: launch.Context) !*hq.Host {
    return launch.open(allocator, context);
}

pub fn attachJourney(host: *hq.Host, state: *journey.State) !void {
    _ = host;
    _ = state;
}
