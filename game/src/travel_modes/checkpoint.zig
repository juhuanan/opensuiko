const std = @import("std");
const travel = @import("travel_modes");
const routes = @import("route_transitions");
const events = @import("event_runtime");

pub const Pending = struct {
    request: routes.Request,
    construction: events.StoryState,
    current: events.StoryState,
};
pub const Data = struct {
    schema: []const u8 = "suikoden-travel-checkpoint/1",
    entry: travel.TravelEntry,
    state: travel.Snapshot,
    pending: ?Pending = null,
    pub fn capture(controller: travel.Controller) Data {
        return .{
            .entry = controller.entry,
            .state = controller.state,
            .pending = if (controller.pending) |p| .{ .request = p.request, .construction = p.construction_before, .current = p.current_before } else null,
        };
    }
    pub fn validate(self: Data, packet: routes.Packet) !travel.Controller {
        if (!std.mem.eql(u8, self.schema, "suikoden-travel-checkpoint/1") or !std.mem.eql(u8, self.entry.content_sha256, packet.content_sha256)) return error.InvalidTravelCheckpoint;
        try routes.validate(packet);
        if (self.pending) |p| {
            if (self.state.mode != .pending) return error.InvalidTravelCheckpoint;
            return travel.Controller.restorePending(self.entry, self.state, packet, p.construction, p.current, p.request);
        }
        if (self.state.mode == .pending) return error.InvalidTravelCheckpoint;
        return travel.Controller.restore(self.entry, self.state);
    }
};
pub fn encode(allocator: std.mem.Allocator, controller: travel.Controller) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, Data.capture(controller), .{});
}
// Parsed storage must outlive the returned controller's borrowed identity and request strings.
pub const Loaded = struct {
    parsed: std.json.Parsed(Data),
    controller: travel.Controller,
    pub fn deinit(self: *Loaded) void {
        self.parsed.deinit();
    }
};
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, packet: routes.Packet) !Loaded {
    if (bytes.len > 64 * 1024) return error.TravelCheckpointTooLarge;
    const parsed = try std.json.parseFromSlice(Data, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    return .{ .controller = try parsed.value.validate(packet), .parsed = parsed };
}
