const std = @import("std");
const events = @import("event_runtime");

pub const schema = "suikoden-middle-story/1";

pub const ContentReference = struct {
    path: []const u8,
    content_id: []const u8,
    content_sha256: []const u8,
    program_ids: []const []const u8,
};
pub const Entry = struct {
    source_file: []const u8,
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
    runtime_state: []const u8,
    content_id: ?[]const u8 = null,
    content_sha256: ?[]const u8 = null,
};
pub const Coverage = struct {
    source_files: u16,
    source_ordinary_entries: u16,
    compiled_programs: u16,
    blocked_programs: u16,
    event_bundles: u16,
    population_bundles: u16,
    population_gaps: u16,
    host_bound_programs: u16,
};
pub const PopulationGap = struct { source_file: []const u8, room: u8, reason: []const u8 };
pub const Manifest = struct {
    schema: []const u8,
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
    if (!std.mem.eql(u8, manifest.schema, schema) or manifest.content_sha256.len != 64)
        return error.InvalidStoryManifest;
    const coverage = manifest.coverage;
    if (coverage.source_files != 89 or coverage.source_ordinary_entries != 4839 or
        coverage.compiled_programs != 1130 or coverage.blocked_programs != 3709 or
        coverage.event_bundles != 318 or coverage.population_bundles != 223 or
        coverage.population_gaps != 5 or coverage.host_bound_programs != 0 or
        manifest.entries.len != 4839 or manifest.contents.len != 318 or
        manifest.population_gaps.len != 5) return error.InvalidStoryCoverage;
    var compiled: usize = 0;
    for (manifest.entries, 0..) |entry, index| {
        for (manifest.entries[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.program_id, entry.program_id)) return error.DuplicateStoryProgram;
        }
        if (std.mem.eql(u8, entry.status, "compiled")) {
            compiled += 1;
            if (!entry.executable or entry.content_id == null or entry.content_sha256 == null or
                !std.mem.eql(u8, entry.runtime_state, "compiled_not_host_bound"))
                return error.InvalidStoryReference;
        } else {
            if (!std.mem.eql(u8, entry.status, "blocked_unsupported") or entry.executable or
                entry.complete_program_suppressed != true or entry.partial_commands_emitted != false or
                entry.reason == null or !std.mem.eql(u8, entry.runtime_state, "source_only"))
                return error.InvalidStoryGap;
        }
    }
    if (compiled != coverage.compiled_programs or manifest.entries.len - compiled != coverage.blocked_programs)
        return error.InvalidStoryCoverage;
}

pub fn validateContents(manifest: Manifest, contents: []const events.Content) !void {
    try validateManifest(manifest);
    if (contents.len != manifest.contents.len) return error.InvalidStoryEndingount;
    for (manifest.contents, contents) |reference, content| {
        try content.validate();
        if (!std.mem.eql(u8, reference.content_id, content.id) or
            !std.mem.eql(u8, reference.content_sha256, content.content_sha256) or
            reference.program_ids.len != content.programs.len) return error.StaleStoryContent;
        for (reference.program_ids, content.programs) |id, program| {
            if (!std.mem.eql(u8, id, program.id)) return error.StorySourceOrderMismatch;
        }
    }
    for (manifest.entries) |entry| {
        if (!std.mem.eql(u8, entry.status, "compiled")) {
            for (contents) |content| {
                if (content.program(entry.program_id) != null) return error.BlockedStoryProgramEmitted;
            }
            continue;
        }
        var found = false;
        for (contents) |content| {
            if (!std.mem.eql(u8, entry.content_id.?, content.id)) continue;
            if (!std.mem.eql(u8, entry.content_sha256.?, content.content_sha256)) return error.StaleStoryReference;
            if (content.program(entry.program_id) == null) return error.MissingStoryProgram;
            found = true;
            break;
        }
        if (!found) return error.MissingStoryContent;
    }
}
