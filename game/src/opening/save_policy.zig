const std = @import("std");

pub const schema = "suikoden-opening-save-policy/1";

pub const Rules = struct {
    canonical_user_save_locations: []const []const u8,
    prototype_pause_save_locations: []const []const u8,
    busy_facts: []const []const u8,
    internal_checkpoint: []const u8,
    slot_journal: []const u8,
    load: []const u8,
};
pub const Asset = struct {
    schema: []const u8,
    content_sha256: []const u8,
    rules: Rules,
};

pub const Mode = enum { canonical, prototype_pause };
pub const Place = enum { field, inn, save_orb };
pub const Facts = struct {
    mode: Mode,
    place: Place,
    event_active: bool = false,
    dialogue_busy: bool = false,
    control_locked: bool = false,
    transition_pending: bool = false,
    write_pending: bool = false,
    snapshot_valid: bool = true,
};
pub const Blocker = enum { canonical_pause_unavailable, busy, invalid_snapshot, write_pending };
pub const Decision = union(enum) { allowed, blocked: Blocker };

pub fn open(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Asset) {
    const parsed = try std.json.parseFromSlice(Asset, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    errdefer parsed.deinit();
    try validate(parsed.value);
    return parsed;
}

pub fn validate(asset: Asset) !void {
    if (!std.mem.eql(u8, asset.schema, schema) or asset.content_sha256.len != 64)
        return error.InvalidSavePolicy;
    const rules = asset.rules;
    if (rules.canonical_user_save_locations.len != 2 or
        !std.mem.eql(u8, rules.canonical_user_save_locations[0], "inn") or
        !std.mem.eql(u8, rules.canonical_user_save_locations[1], "save_orb") or
        rules.prototype_pause_save_locations.len != 3 or rules.busy_facts.len != 5)
        return error.InvalidSavePolicy;
    if (!std.mem.eql(u8, rules.internal_checkpoint, "recovery_only_never_a_user_save_or_slot_grant"))
        return error.InvalidSavePolicy;
}

pub fn userSave(facts: Facts) Decision {
    if (facts.event_active or facts.dialogue_busy or facts.control_locked or
        facts.transition_pending or facts.write_pending) return .{ .blocked = .busy };
    if (!facts.snapshot_valid) return .{ .blocked = .invalid_snapshot };
    if (facts.mode == .canonical and facts.place == .field)
        return .{ .blocked = .canonical_pause_unavailable };
    return .allowed;
}

pub fn internalCheckpoint(facts: Facts) Decision {
    if (facts.write_pending) return .{ .blocked = .write_pending };
    if (!facts.snapshot_valid) return .{ .blocked = .invalid_snapshot };
    return .allowed;
}

pub const Journal = struct {
    generation: u64 = 0,
    pending: ?u64 = null,

    pub fn begin(self: *Journal) !u64 {
        if (self.pending != null) return error.WritePending;
        const id = std.math.add(u64, self.generation, 1) catch return error.GenerationExhausted;
        self.pending = id;
        return id;
    }

    pub fn commit(self: *Journal, id: u64) !void {
        if (self.pending == null or self.pending.? != id) return error.StaleWrite;
        self.generation = id;
        self.pending = null;
    }

    pub fn abort(self: *Journal, id: u64) !void {
        if (self.pending == null or self.pending.? != id) return error.StaleWrite;
        self.pending = null;
    }

    pub fn restore(self: *Journal, generation: u64, valid: bool) !void {
        if (self.pending != null) return error.WritePending;
        if (!valid) return error.InvalidSnapshot;
        self.generation = generation;
    }
};
