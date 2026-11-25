const std = @import("std");
const events = @import("event_runtime");

pub const schema = "suikoden-opening-town/1";

pub const ContentReference = struct {
    path: []const u8,
    content_id: []const u8,
    content_sha256: []const u8,
    program_ids: []const []const u8,
};
pub const Entry = struct {
    room: u8,
    entity: u8,
    flags: u16,
    stream: u32,
    program_id: []const u8,
    status: []const u8,
    executable: bool,
    complete_program_suppressed: ?bool = null,
    reason: ?[]const u8 = null,
    partial_commands_emitted: ?bool = null,
    content_id: ?[]const u8 = null,
    content_sha256: ?[]const u8 = null,
};
pub const Coverage = struct {
    source_ordinary_entries: u16,
    compiled_programs: u16,
    blocked_programs: u16,
    event_bundles: u16,
    population_bundles: u16,
    population_gaps: u16,
};
pub const PopulationGap = struct { room: u8, reason: []const u8 };
pub const Manifest = struct {
    schema: []const u8,
    id: []const u8,
    content_sha256: []const u8,
    contents: []const ContentReference,
    entries: []const Entry,
    population_gaps: []const PopulationGap,
    coverage: Coverage,
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
    if (!std.mem.eql(u8, manifest.schema, schema) or !std.mem.eql(u8, manifest.id, "va1_town_dialogue"))
        return error.InvalidTownManifest;
    if (manifest.content_sha256.len != 64 or manifest.entries.len != 220 or
        manifest.contents.len != 43 or manifest.population_gaps.len != 1 or
        manifest.population_gaps[0].room != 12) return error.InvalidTownCoverage;
    const coverage = manifest.coverage;
    if (coverage.source_ordinary_entries != 220 or coverage.compiled_programs != 220 or
        coverage.blocked_programs != 0 or coverage.event_bundles != 43 or
        coverage.population_bundles != 18 or coverage.population_gaps != 1)
        return error.InvalidTownCoverage;
    var compiled: usize = 0;
    for (manifest.entries, 0..) |entry, index| {
        for (manifest.entries[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.program_id, entry.program_id)) return error.DuplicateTownProgram;
        }
        if (std.mem.eql(u8, entry.status, "compiled")) {
            compiled += 1;
            if (!entry.executable or entry.content_id == null or entry.content_sha256 == null)
                return error.InvalidTownReference;
        } else {
            if (!std.mem.eql(u8, entry.status, "blocked_unsupported") or entry.executable or
                entry.complete_program_suppressed != true or entry.partial_commands_emitted != false or
                entry.reason == null) return error.InvalidTownGap;
        }
    }
    if (compiled != coverage.compiled_programs or manifest.entries.len - compiled != coverage.blocked_programs)
        return error.InvalidTownCoverage;
}

pub fn validateContents(manifest: Manifest, contents: []const events.Content) !void {
    try validateManifest(manifest);
    if (contents.len != manifest.contents.len) return error.InvalidTownEndingount;
    for (manifest.contents, contents) |reference, content| {
        try content.validate();
        if (!std.mem.eql(u8, reference.content_id, content.id) or
            !std.mem.eql(u8, reference.content_sha256, content.content_sha256) or
            reference.program_ids.len != content.programs.len) return error.StaleTownContent;
        for (reference.program_ids, content.programs) |id, program| {
            if (!std.mem.eql(u8, id, program.id)) return error.TownSourceOrderMismatch;
        }
    }
    for (manifest.entries) |entry| {
        if (!std.mem.eql(u8, entry.status, "compiled")) {
            for (contents) |content| {
                if (content.program(entry.program_id) != null) return error.BlockedTownProgramEmitted;
            }
            continue;
        }
        var found = false;
        for (contents) |content| {
            if (!std.mem.eql(u8, entry.content_id.?, content.id)) continue;
            if (!std.mem.eql(u8, entry.content_sha256.?, content.content_sha256)) return error.StaleTownReference;
            if (content.program(entry.program_id) == null) return error.MissingTownProgram;
            found = true;
            break;
        }
        if (!found) return error.MissingTownContent;
    }
}
