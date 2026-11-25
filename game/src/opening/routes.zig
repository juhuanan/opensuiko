const std = @import("std");
const events = @import("event_runtime");

pub const schema = "suikoden-opening-routes/1";

pub const Unsupported = struct {
    offset: u32,
    opcode: u8,
    operands: []const u8,
    reason: []const u8,
};
pub const Gap = struct {
    source_file: []const u8,
    room: u8,
    entity: u8,
    stream: u32,
    program_id: []const u8,
    executable: bool,
    complete_program_suppressed: bool,
    unsupported: Unsupported,
    partial_commands_emitted: bool,
};
pub const Coverage = struct {
    rooms: u8,
    route_candidates: u8,
    compiled_programs: u8,
    blocked_programs: u8,
};
pub const Manifest = struct {
    schema: []const u8,
    id: []const u8,
    content_sha256: []const u8,
    gaps: []const Gap,
    coverage: Coverage,
    integration_blocker: []const u8,
};

pub fn loadManifest(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Manifest) {
    const parsed = try std.json.parseFromSlice(Manifest, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    errdefer parsed.deinit();
    try validateManifest(parsed.value);
    return parsed;
}

pub fn validateManifest(manifest: Manifest) !void {
    if (!std.mem.eql(u8, manifest.schema, schema) or
        !std.mem.eql(u8, manifest.id, "vaa_palace_routes")) return error.InvalidRouteManifest;
    if (manifest.content_sha256.len != 64 or manifest.gaps.len != 2 or
        manifest.coverage.rooms != 4 or manifest.coverage.route_candidates != 10 or
        manifest.coverage.compiled_programs != 8 or manifest.coverage.blocked_programs != 2)
        return error.InvalidRouteCoverage;
    const expected = [_]struct { room: u8, entity: u8, opcode: u8 }{
        .{ .room = 0, .entity = 14, .opcode = 0x06 },
        .{ .room = 10, .entity = 4, .opcode = 0x06 },
    };
    for (manifest.gaps, expected) |gap, wanted| {
        if (gap.room != wanted.room or gap.entity != wanted.entity or
            gap.unsupported.opcode != wanted.opcode or gap.executable or
            !gap.complete_program_suppressed or gap.partial_commands_emitted)
            return error.InvalidRouteGap;
        if (!std.mem.eql(u8, gap.source_file, "DATA/01_AREA.A/VAA.BIN"))
            return error.InvalidRouteSource;
    }
}

pub fn validateContents(contents: [4]events.Content) !void {
    const expected = [_]struct { id: []const u8, programs: usize }{
        .{ .id = "vaa_room0_route_events", .programs = 2 },
        .{ .id = "vaa_room1_route_events", .programs = 2 },
        .{ .id = "vaa_room2_route_events", .programs = 2 },
        .{ .id = "vaa_room10_route_events", .programs = 2 },
    };
    for (contents, expected) |content, wanted| {
        try content.validate();
        if (!std.mem.eql(u8, content.id, wanted.id) or content.programs.len != wanted.programs)
            return error.InvalidRouteContent;
        for (content.programs) |program| {
            if (program.commands.len == 0 or
                program.commands[program.commands.len - 1].kind != .room_transition)
                return error.InvalidRouteProgram;
        }
    }
}

pub fn validate(contents: [4]events.Content, manifest: Manifest) !void {
    try validateContents(contents);
    try validateManifest(manifest);
    for (manifest.gaps) |gap| {
        for (contents) |content| {
            if (content.program(gap.program_id) != null) return error.BlockedProgramWasEmitted;
        }
    }
}
