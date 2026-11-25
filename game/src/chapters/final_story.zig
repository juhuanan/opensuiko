const std = @import("std");
const story = @import("middle_story.zig");

pub const schema = "suikoden-final-story/1";

pub const StorySource = struct { path: []const u8, sha256: []const u8 };
pub const Blocked = struct { program_id: []const u8, reason: []const u8 };
pub const Terminal = struct {
    source_file: []const u8,
    source_sha256: []const u8,
    main_ending: u32,
    ending_exit: u32,
    state: []const u8,
};
pub const Coverage = struct {
    compiled: u16,
    blocked: u16,
    source_files: u16,
    production_programs: u16,
};
pub const Asset = struct {
    schema: []const u8,
    content_sha256: []const u8,
    story_source: StorySource,
    compiled_ids: []const []const u8,
    blocked: []const Blocked,
    terminal: Terminal,
    coverage: Coverage,
};

pub fn open(allocator: std.mem.Allocator, bytes: []const u8, manifest: story.Manifest) !std.json.Parsed(Asset) {
    const parsed = try std.json.parseFromSlice(Asset, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    errdefer parsed.deinit();
    try validate(parsed.value, manifest);
    return parsed;
}

pub fn entryById(manifest: story.Manifest, id: []const u8) ?story.Entry {
    for (manifest.entries) |entry| {
        if (std.mem.eql(u8, entry.program_id, id)) return entry;
    }
    return null;
}

pub fn validate(asset: Asset, manifest: story.Manifest) !void {
    try story.validateManifest(manifest);
    if (!std.mem.eql(u8, asset.schema, schema) or asset.content_sha256.len != 64)
        return error.InvalidFinalStorySchema;
    if (!std.mem.eql(u8, asset.story_source.sha256, "c61efcb3b3a41dc6f6b5ac6a66873f778b01170ef508a7c8e9839fb0ff746e85"))
        return error.StaleFinalStorySource;
    if (asset.compiled_ids.len != 144 or asset.blocked.len != 293 or
        asset.coverage.compiled != 144 or asset.coverage.blocked != 293 or
        asset.coverage.source_files != 6 or asset.coverage.production_programs != 0)
        return error.InvalidFinalStoryCoverage;
    if (asset.terminal.main_ending != 0x80010EE8 or asset.terminal.ending_exit != 0x800103B8 or
        !std.mem.eql(u8, asset.terminal.source_file, "DATA/15_AREA.Z/VZ7.BIN") or
        !std.mem.eql(u8, asset.terminal.state, "source_only_not_event_ir"))
        return error.InvalidFinalTerminal;
    var seen = std.StringHashMap(void).init(std.heap.page_allocator);
    defer seen.deinit();
    for (asset.compiled_ids) |id| {
        if (seen.contains(id)) return error.DuplicateFinalProgram;
        try seen.put(id, {});
        const entry = entryById(manifest, id) orelse return error.MissingFinalProgram;
        if (!std.mem.eql(u8, entry.status, "compiled") or !entry.executable or
            entry.content_id == null or entry.content_sha256 == null or
            !std.mem.eql(u8, entry.runtime_state, "compiled_not_host_bound"))
            return error.InvalidFinalProgram;
    }
    for (asset.blocked) |blocked| {
        if (seen.contains(blocked.program_id)) return error.DuplicateFinalProgram;
        try seen.put(blocked.program_id, {});
        const entry = entryById(manifest, blocked.program_id) orelse return error.MissingFinalProgram;
        if (!std.mem.eql(u8, entry.status, "blocked_unsupported") or entry.executable or
            entry.complete_program_suppressed != true or entry.partial_commands_emitted != false or
            !std.mem.eql(u8, entry.runtime_state, "source_only") or
            !std.mem.eql(u8, entry.reason.?, blocked.reason)) return error.InvalidFinalBlocker;
    }
}

pub const Decision = union(enum) {
    selected: story.Entry,
    blocked: Blocked,
};

pub fn plan(asset: Asset, manifest: story.Manifest, program_id: []const u8) !Decision {
    const entry = entryById(manifest, program_id) orelse return error.MissingFinalProgram;
    if (std.mem.eql(u8, entry.status, "compiled")) return .{ .selected = entry };
    for (asset.blocked) |blocked| {
        if (std.mem.eql(u8, blocked.program_id, program_id)) return .{ .blocked = blocked };
    }
    return error.InvalidFinalBlocker;
}
