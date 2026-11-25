const std = @import("std");
const travel = @import("middle_travel.zig");

pub const schema = "suikoden-final-travel/1";
pub const z_prefix = "DATA/15_AREA.Z/";

pub const TravelSource = struct { path: []const u8, sha256: []const u8 };
pub const Terminal = struct {
    source_file: []const u8,
    source_sha256: []const u8,
    main_ending: u32,
    ending_exit: u32,
    state: []const u8,
};
pub const Coverage = struct {
    incoming: u16,
    region_edges: u16,
    external_returns: u16,
    production_edges: u16,
};
pub const Asset = struct {
    schema: []const u8,
    content_sha256: []const u8,
    travel_source: TravelSource,
    incoming_ids: []const []const u8,
    region_ids: []const []const u8,
    return_policy: []const u8,
    terminal: Terminal,
    coverage: Coverage,
};

pub fn open(allocator: std.mem.Allocator, bytes: []const u8, parent: travel.Asset) !std.json.Parsed(Asset) {
    const parsed = try std.json.parseFromSlice(Asset, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    errdefer parsed.deinit();
    try validate(parsed.value, parent);
    return parsed;
}

pub fn edgeById(parent: travel.Asset, id: []const u8) ?travel.Edge {
    for (parent.edges) |edge| {
        if (std.mem.eql(u8, edge.id, id)) return edge;
    }
    return null;
}

fn contains(ids: []const []const u8, id: []const u8) bool {
    for (ids) |candidate| {
        if (std.mem.eql(u8, candidate, id)) return true;
    }
    return false;
}

pub fn validate(asset: Asset, parent: travel.Asset) !void {
    try travel.validate(parent);
    if (!std.mem.eql(u8, asset.schema, schema) or asset.content_sha256.len != 64)
        return error.InvalidFinalTravelSchema;
    if (!std.mem.eql(u8, asset.travel_source.sha256, "28cdef9a158086a92574738cc60a619f22aaa70d2869747a04232f6a4a61f2ac"))
        return error.StaleFinalTravelSource;
    if (!std.mem.eql(u8, asset.return_policy, "no_external_return_edges_in_source_graph") or
        asset.coverage.incoming != 2 or asset.coverage.region_edges != 144 or
        asset.coverage.external_returns != 0 or asset.coverage.production_edges != 0 or
        asset.incoming_ids.len != 2 or asset.region_ids.len != 144)
        return error.InvalidFinalTravelCoverage;
    if (asset.terminal.main_ending != 0x80010EE8 or asset.terminal.ending_exit != 0x800103B8 or
        !std.mem.eql(u8, asset.terminal.source_file, "DATA/15_AREA.Z/VZ7.BIN") or
        !std.mem.eql(u8, asset.terminal.state, "source_only_not_a_travel_edge"))
        return error.InvalidFinalTerminal;
    var seen = std.StringHashMap(void).init(std.heap.page_allocator);
    defer seen.deinit();
    for (asset.incoming_ids) |id| {
        if (seen.contains(id)) return error.DuplicateFinalReference;
        try seen.put(id, {});
        const edge = edgeById(parent, id) orelse return error.MissingFinalReference;
        if (std.mem.startsWith(u8, edge.source_file, z_prefix)) return error.InvalidFinalEntrance;
        const destination = edge.destination.area_file orelse return error.InvalidFinalEntrance;
        if (!std.mem.startsWith(u8, destination, z_prefix)) return error.InvalidFinalEntrance;
    }
    for (asset.region_ids) |id| {
        if (seen.contains(id)) return error.DuplicateFinalReference;
        try seen.put(id, {});
        const edge = edgeById(parent, id) orelse return error.MissingFinalReference;
        if (!std.mem.startsWith(u8, edge.source_file, z_prefix) or
            !std.mem.eql(u8, edge.destination.kind, "room")) return error.InvalidFinalEdge;
        if (edge.destination.area_file) |destination| {
            if (!std.mem.startsWith(u8, destination, z_prefix)) return error.InventedFinalReturn;
        }
    }
}

pub const Decision = union(enum) {
    selected: travel.Edge,
    outside_final_scope,
    blocked_destination,
};

pub fn plan(asset: Asset, parent: travel.Asset, id: []const u8) !Decision {
    if (!contains(asset.incoming_ids, id) and !contains(asset.region_ids, id)) return .outside_final_scope;
    const edge = edgeById(parent, id) orelse return error.MissingFinalReference;
    if (!std.mem.eql(u8, edge.destination.kind, "room")) return .blocked_destination;
    return .{ .selected = edge };
}
