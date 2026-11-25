const std = @import("std");

pub const schema = "suikoden-final-endings/1";

pub const Source = struct { file: []const u8, lba: u32, size: u32, sha256: []const u8 };
pub const RosterSource = struct { path: []const u8, sha256: []const u8 };
pub const Entry = struct {
    source_index: u8,
    character_id: u8,
    member_id: []const u8,
    display_name: []const u8,
    special_dependency: ?u8,
    control: u8,
    presence_rule: []const u8,
    lost_rule: []const u8,
};
pub const Media = struct { path: []const u8, lba: u32, size: u32, role: []const u8 };
pub const BoundedEnding = struct {
    source_index: u8,
    character_id: u8,
    variant: []const u8,
    effect: u32,
    message_offset: u32,
    message_bytes: u16,
    message_sha256: []const u8,
    text: []const u8,
    source_order_callback: u32,
    message_loop_callback: u32,
    phase_barrier_callback: u32,
    main_ending_phases: u8,
    exit_callback: u32,
    return_value: i32,
    str_resources_used: u8,
};
pub const Coverage = struct {
    ending_entries: u16,
    special_dependencies: u16,
    proved_str_resources: u16,
    production_endings: u16,
};
pub const Asset = struct {
    schema: []const u8,
    content_sha256: []const u8,
    source: Source,
    roster_source: RosterSource,
    entry_callback: u32,
    exit_callback: u32,
    final_return: []const u8,
    message_execution: []const u8,
    bounded_ending: BoundedEnding,
    source_order_sha256: []const u8,
    entries: []const Entry,
    effect_table: []const u32,
    special_table0: []const u8,
    special_table1: []const u8,
    death_effects: []const u32,
    media: []const Media,
    coverage: Coverage,
};

pub fn open(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Asset) {
    const parsed = try std.json.parseFromSlice(Asset, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    errdefer parsed.deinit();
    try validate(parsed.value);
    return parsed;
}

fn expectedDependency(character_id: u8) ?u8 {
    return switch (character_id) {
        2, 6 => character_id,
        33 => 63,
        80 => 14,
        83 => 82,
        else => null,
    };
}

pub fn validate(asset: Asset) !void {
    if (!std.mem.eql(u8, asset.schema, schema) or asset.content_sha256.len != 64 or
        asset.source_order_sha256.len != 64) return error.InvalidEndingSchema;
    if (!std.mem.eql(u8, asset.roster_source.sha256, "ce615fe3fa7cb3bb79c63cb4c6008e856ca1d306eff4e09a6980026bb74baf29"))
        return error.StaleEndingRoster;
    if (asset.entry_callback != 0x80010EE8 or asset.exit_callback != 0x800103B8 or
        !std.mem.eql(u8, asset.final_return, "clear_overlay_context_and_caller_word_return_minus_1") or
        !std.mem.eql(u8, asset.message_execution, "bounded_hero_recruited_vz7_message"))
        return error.InvalidEndingCallbacks;
    if (asset.entries.len != 108 or asset.coverage.ending_entries != 108 or
        asset.coverage.special_dependencies != 5 or asset.coverage.proved_str_resources != 3 or
        asset.coverage.production_endings != 1 or asset.media.len != 3 or
        asset.effect_table.len != 113 or asset.special_table0.len != 113 or
        asset.special_table1.len != 113 or asset.death_effects.len != 16)
        return error.InvalidEndingCoverage;
    var seen = std.mem.zeroes([108]bool);
    var special: u16 = 0;
    for (asset.entries, 0..) |entry, index| {
        if (entry.source_index != index or entry.character_id >= 108 or seen[entry.character_id] or
            entry.special_dependency != expectedDependency(entry.character_id) or
            !std.mem.eql(u8, entry.presence_rule, "flag_bit0_or_bit1") or
            !std.mem.eql(u8, entry.lost_rule, "flag_bit1")) return error.InvalidEndingEntry;
        seen[entry.character_id] = true;
        if (entry.special_dependency != null) special += 1;
    }
    if (special != 5) return error.InvalidEndingCoverage;
    for (seen) |present| {
        if (!present) return error.InvalidEndingCoverage;
    }
    const bounded = asset.bounded_ending;
    if (bounded.source_index != 0 or bounded.character_id != 8 or
        !std.mem.eql(u8, bounded.variant, "recruited") or bounded.effect != 0x80071024 or
        bounded.message_offset != 0x61024 or bounded.message_bytes != 52 or
        bounded.message_sha256.len != 64 or
        !std.mem.eql(u8, bounded.text, "Become the President of the \nToran Republic, and...") or
        bounded.source_order_callback != 0x80011714 or bounded.message_loop_callback != 0x80011E40 or
        bounded.phase_barrier_callback != 0x800110DC or bounded.main_ending_phases != 6 or
        bounded.exit_callback != asset.exit_callback or bounded.return_value != -1 or
        bounded.str_resources_used != 0 or asset.entries[0].control != 0 or
        asset.effect_table[0] != bounded.effect) return error.InvalidBoundedEnding;
    const roles = [_][]const u8{ "logo_not_ending", "opening_not_ending", "opening_war_montage_not_ending" };
    const paths = [_][]const u8{ "DEMO/573LOGO.STR", "DEMO/SUIKODEN.STR", "OPEN15MX.STR" };
    for (asset.media, roles, paths) |media, role, path| {
        if (!std.mem.eql(u8, media.role, role) or !std.mem.eql(u8, media.path, path))
            return error.InvalidEndingMedia;
    }
}

pub const Variant = @import("final_state.zig").Variant;

pub fn variant(asset: Asset, source_index: usize, recruit_flags: *const [108]u8) !Variant {
    if (source_index >= asset.entries.len) return error.EndingSourceIndexOutOfRange;
    const entry = asset.entries[source_index];
    const flags = recruit_flags[entry.character_id];
    if ((flags & 3) == 0) return .absent;
    const alternate = if (entry.special_dependency) |dependency|
        (recruit_flags[dependency] & 2) != 0
    else
        false;
    if ((flags & 2) != 0) return if (alternate) .lost_alternate else .lost;
    return if (alternate) .recruited_alternate else .recruited;
}

pub const MessagePlan = struct {
    variant: Variant,
    effect: ?u32,
    death_cause: ?u8,
    death_effect: ?u32,
};

pub fn plan(asset: Asset, source_index: usize, recruit_flags: *const [108]u8) !MessagePlan {
    if (source_index >= asset.entries.len) return error.EndingSourceIndexOutOfRange;
    const entry = asset.entries[source_index];
    const flags = recruit_flags[entry.character_id];
    var effect: ?u32 = null;
    if (entry.special_dependency) |dependency| {
        const table_index = entry.control & 0x7F;
        const selector = if ((recruit_flags[dependency] & 2) != 0)
            asset.special_table0[table_index]
        else
            asset.special_table1[table_index];
        if (selector >= asset.effect_table.len) return error.UnsupportedEndingEffect;
        effect = asset.effect_table[selector];
    } else if (entry.control < asset.effect_table.len) {
        effect = asset.effect_table[entry.control];
    }
    const death_cause: ?u8 = if ((flags & 2) != 0) flags >> 4 else null;
    return .{
        .variant = try variant(asset, source_index, recruit_flags),
        .effect = effect,
        .death_cause = death_cause,
        .death_effect = if (death_cause) |cause| asset.death_effects[cause] else null,
    };
}

pub const Census = struct {
    absent: u16 = 0,
    recruited: u16 = 0,
    recruited_alternate: u16 = 0,
    lost: u16 = 0,
    lost_alternate: u16 = 0,
};

pub fn census(asset: Asset, recruit_flags: *const [108]u8) !Census {
    var result: Census = .{};
    for (asset.entries, 0..) |_, index| {
        switch (try variant(asset, index, recruit_flags)) {
            .absent => result.absent += 1,
            .recruited => result.recruited += 1,
            .recruited_alternate => result.recruited_alternate += 1,
            .lost => result.lost += 1,
            .lost_alternate => result.lost_alternate += 1,
        }
    }
    return result;
}

pub const Execution = struct {
    source_index: u8,
    variant: Variant,
    effect: u32,
    text: []const u8,
    visited_entries: u16,
    phases_completed: u8,
    exit_callback: u32,
    return_value: i32,
    overlay_context_cleared: bool,
    caller_word_cleared: bool,
    str_resources_used: u8,
};

pub fn executeBounded(asset: Asset, recruit_flags: *const [108]u8) !Execution {
    try validate(asset);
    for (recruit_flags, 0..) |flag, character_id| {
        const expected: u8 = if (character_id == 8) 1 else 0;
        if (flag != expected) return error.UnsupportedBoundedEndingFlags;
    }
    var visited: u16 = 0;
    for (asset.entries, 0..) |_, index| {
        const message = try plan(asset, index, recruit_flags);
        visited += 1;
        if (index == 0) {
            if (message.variant != .recruited or message.effect == null or
                message.effect.? != asset.bounded_ending.effect) return error.InvalidBoundedEnding;
        } else if (message.variant != .absent) return error.UnsupportedBoundedEndingVariant;
    }
    return .{
        .source_index = 0,
        .variant = .recruited,
        .effect = asset.bounded_ending.effect,
        .text = asset.bounded_ending.text,
        .visited_entries = visited,
        .phases_completed = asset.bounded_ending.main_ending_phases,
        .exit_callback = asset.exit_callback,
        .return_value = asset.bounded_ending.return_value,
        .overlay_context_cleared = true,
        .caller_word_cleared = true,
        .str_resources_used = asset.bounded_ending.str_resources_used,
    };
}
