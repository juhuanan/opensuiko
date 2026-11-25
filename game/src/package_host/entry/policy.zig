//! Packaged campaign-entry policy.
//!
//! the embedded campaign asset is the packaged identity
//! the host binds.  This file holds the same facts as compile-time constants
//! (so a screen can draw without an allocator) and `load` validates the packaged
//! document against them.  A drifted asset therefore fails closed at startup
//! instead of silently changing what the title offers.
//!
//! Provenance is part of the data:
//!   * `source_observed` - the original flow is recorded in the registry
//!     (title screen, start menu default cursor, New game -> name -> confirm,
//!     Setup handlers/groups).
//!   * `port_extension` - an added row the source observation does not cover
//!     (Load game, Setup and Quit on the start menu).  The title view must be
//!     able to label these.
//!   * `port_contract` - a packaged boundary (three-slot save contract, the
//!     32-byte printable-ASCII name buffer).
const std = @import("std");
const setup = @import("setup.zig");
const name = @import("name.zig");
const slots = @import("slots.zig");

pub const schema = "suikoden-entry-policy/1";
pub const pack = "entry_policy";
pub const stage = "entry";

pub const title_routine = "SLUS:0x80018488";
pub const title_label = "PRESS START";
pub const menu_routine = "SLUS:0x80016530";
pub const confirm_prompt = "Is this OK?";

pub const RowId = enum { new_game, continue_game, load_game, setup, quit };
pub const Provenance = enum { source_observed, port_extension, port_contract };

pub const Row = struct {
    id: RowId,
    label: []const u8,
    provenance: Provenance,
};

pub const rows = [5]Row{
    .{ .id = .new_game, .label = "New game", .provenance = .source_observed },
    .{ .id = .continue_game, .label = "Continue game", .provenance = .source_observed },
    .{ .id = .load_game, .label = "Load game", .provenance = .port_extension },
    .{ .id = .setup, .label = "Setup", .provenance = .port_extension },
    .{ .id = .quit, .label = "Quit", .provenance = .port_extension },
};

pub const default_row: usize = 1;

pub const name_min: u8 = 1;
pub const name_max: u8 = name.capacity;

pub const slot_count: usize = slots.count;

pub const start_seed_path = "game/assets/opening.json";
pub const start_seed_content = "suikoden-opening/1";
pub const start_seed_money: u32 = 1500;
pub const start_seed_party: usize = 1;
pub const start_seed_room = "vaa_room_2";
pub const start_seed_sha256 = [32]u8{
    0x47, 0x24, 0x3f, 0x2f, 0x86, 0xf9, 0xee, 0xd9,
    0x0d, 0xc4, 0x8a, 0x07, 0x40, 0xe5, 0x1c, 0x19,
    0x25, 0xa3, 0x71, 0xe3, 0xa2, 0x32, 0xcb, 0x21,
    0x6c, 0x52, 0xdf, 0x44, 0xfc, 0x9a, 0xb5, 0x20,
};

pub const setup_routine = "MAIN:0x800D0498";
pub const setup_driver = "MAIN:0x800D06C0";
pub const setup_table = "MAIN:0x800C0E8C";
pub const setup_list = "MAIN:0x800D17EC";
pub const setup_group: u8 = 15;

pub const DependencyId = enum {
    opening_name_and_start_ownership,
    opening_source_save_policy,
    world_roster_windows,
    ending_full_roster,
};

pub const dependencies = [4]struct { id: DependencyId, pack: []const u8 }{
    .{ .id = .opening_name_and_start_ownership, .pack = "opening_start" },
    .{ .id = .opening_source_save_policy, .pack = "opening_save_policy" },
    .{ .id = .world_roster_windows, .pack = "middle_recruitment" },
    .{ .id = .ending_full_roster, .pack = "final_roster" },
};

pub const Policy = struct {
    slot_count: usize = slot_count,
    name_max: u8 = name_max,
    default_row: usize = default_row,
    seed_sha256: [32]u8 = start_seed_sha256,

    pub fn validate(self: Policy) !void {
        if (self.slot_count != slots.count) return error.InvalidPolicy;
        if (self.name_max != name.capacity) return error.InvalidPolicy;
        if (self.default_row >= rows.len) return error.InvalidPolicy;
        if (!std.mem.eql(u8, &self.seed_sha256, &start_seed_sha256)) return error.InvalidPolicy;
    }

    pub fn seedMatches(self: Policy, digest: [32]u8) bool {
        return std.mem.eql(u8, &self.seed_sha256, &digest);
    }

    pub fn rowId(self: Policy, index: usize) RowId {
        _ = self;
        return rows[index].id;
    }
};

const RawRow = struct { id: []const u8, label: []const u8, provenance: []const u8 };
const RawGroup = struct { id: []const u8, label: []const u8, choices: []const []const u8 };
const RawDependency = struct { id: []const u8, pack: []const u8, state: []const u8, interface: []const u8, use: []const u8 };

const Raw = struct {
    schema: []const u8,
    pack: []const u8,
    stage: []const u8,
    source: struct {
        title: struct { routine: []const u8, label: []const u8, provenance: []const u8, evidence: []const u8 },
        start_menu: struct { routine: []const u8, default_row: usize, rows: []const RawRow, evidence: []const u8 },
        name_entry: struct {
            routine: []const u8,
            min_chars: u8,
            max_chars: u8,
            charset: []const u8,
            confirm_prompt: []const u8,
            confirm_default: []const u8,
            flow_provenance: []const u8,
            buffer_provenance: []const u8,
            source_open_question: []const u8,
        },
        setup: struct {
            routine: []const u8,
            driver: []const u8,
            table: []const u8,
            list: []const u8,
            group: u8,
            groups: []const RawGroup,
            store: []const u8,
            provenance: []const u8,
            evidence: []const u8,
        },
        slot_contract: struct { count: usize, name: []const u8, backup: []const u8, provenance: []const u8, source_slot_table: []const u8 },
        start_seed: struct {
            path: []const u8,
            sha256: []const u8,
            content_id: []const u8,
            money: u32,
            party_count: usize,
            room: []const u8,
            provenance: []const u8,
            evidence: []const u8,
        },
    },
    policy: struct {
        new_game: struct { writes_slot: bool, requires_name: bool, requires_confirm: bool, accepts: []const []const u8, refuses: []const []const u8 },
        continue_game: struct { selects: []const u8, order: []const u8, tie_break: []const u8 },
        load: struct { empty: []const u8, ready: []const u8, backup: []const u8, damaged: []const u8, future: []const u8 },
        save: struct { empty: []const u8, ready: []const u8, backup: []const u8, damaged: []const u8, future: []const u8 },
        setup: struct { cancel: []const u8, confirm: []const u8, write_failure: []const u8, independent_of_campaign: bool, initial: []const u8 },
    },
    dependencies: []const RawDependency,
};

fn expectStr(actual: []const u8, expected: []const u8) !void {
    if (!std.mem.eql(u8, actual, expected)) return error.InvalidPolicy;
}

fn expectList(actual: []const []const u8, expected: []const []const u8) !void {
    if (actual.len != expected.len) return error.InvalidPolicy;
    for (actual, expected) |value, want| try expectStr(value, want);
}

fn nibble(char: u8) !u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        else => error.InvalidPolicy,
    };
}

pub fn parseSha256(hex: []const u8) ![32]u8 {
    if (hex.len != 64) return error.InvalidPolicy;
    var out: [32]u8 = undefined;
    for (&out, 0..) |*byte, index| {
        byte.* = (try nibble(hex[index * 2])) << 4 | try nibble(hex[index * 2 + 1]);
    }
    return out;
}

/// Parses and validates the packaged policy document.  The returned value keeps
/// only the facts the entry machine needs; every string is checked against the
/// compiled constants above before it is discarded.
pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !Policy {
    if (bytes.len > 64 * 1024) return error.PolicyTooLarge;
    const parsed = try std.json.parseFromSlice(Raw, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const raw = parsed.value;

    try expectStr(raw.schema, schema);
    try expectStr(raw.pack, pack);
    try expectStr(raw.stage, stage);

    try expectStr(raw.source.title.routine, title_routine);
    try expectStr(raw.source.title.label, title_label);
    try expectStr(raw.source.title.provenance, "source_observed");

    try expectStr(raw.source.start_menu.routine, menu_routine);
    if (raw.source.start_menu.default_row != default_row) return error.InvalidPolicy;
    if (raw.source.start_menu.rows.len != rows.len) return error.InvalidPolicy;
    for (raw.source.start_menu.rows, rows) |row, want| {
        try expectStr(row.id, @tagName(want.id));
        try expectStr(row.label, want.label);
        try expectStr(row.provenance, @tagName(want.provenance));
    }

    try expectStr(raw.source.name_entry.routine, menu_routine);
    if (raw.source.name_entry.min_chars != name_min) return error.InvalidPolicy;
    if (raw.source.name_entry.max_chars != name_max) return error.InvalidPolicy;
    try expectStr(raw.source.name_entry.charset, "printable_ascii");
    try expectStr(raw.source.name_entry.confirm_prompt, confirm_prompt);
    try expectStr(raw.source.name_entry.confirm_default, "No");
    try expectStr(raw.source.name_entry.flow_provenance, "source_observed");
    try expectStr(raw.source.name_entry.buffer_provenance, "port_contract");
    if (raw.source.name_entry.source_open_question.len == 0) return error.InvalidPolicy;

    try expectStr(raw.source.setup.routine, setup_routine);
    try expectStr(raw.source.setup.driver, setup_driver);
    try expectStr(raw.source.setup.table, setup_table);
    try expectStr(raw.source.setup.list, setup_list);
    if (raw.source.setup.group != setup_group) return error.InvalidPolicy;
    try expectStr(raw.source.setup.store, setup.schema);
    try expectStr(raw.source.setup.provenance, "source_observed");
    if (raw.source.setup.groups.len != setup.group_count) return error.InvalidPolicy;
    for (raw.source.setup.groups, setup.groups) |group, want| {
        try expectStr(group.id, @tagName(want.id));
        try expectStr(group.label, want.label);
        try expectList(group.choices, want.choices);
    }

    if (raw.source.slot_contract.count != slots.count) return error.InvalidPolicy;
    try expectStr(raw.source.slot_contract.provenance, "port_contract");
    if (raw.source.slot_contract.name.len == 0 or raw.source.slot_contract.backup.len == 0) return error.InvalidPolicy;
    if (raw.source.slot_contract.source_slot_table.len == 0) return error.InvalidPolicy;

    try expectStr(raw.source.start_seed.path, start_seed_path);
    try expectStr(raw.source.start_seed.content_id, start_seed_content);
    if (raw.source.start_seed.money != start_seed_money) return error.InvalidPolicy;
    if (raw.source.start_seed.party_count != start_seed_party) return error.InvalidPolicy;
    try expectStr(raw.source.start_seed.room, start_seed_room);
    try expectStr(raw.source.start_seed.provenance, "source_observed");

    const digest = try parseSha256(raw.source.start_seed.sha256);
    if (!std.mem.eql(u8, &digest, &start_seed_sha256)) return error.InvalidPolicy;

    const rules = raw.policy;
    if (rules.new_game.writes_slot or !rules.new_game.requires_name or !rules.new_game.requires_confirm) return error.InvalidPolicy;
    try expectList(rules.new_game.accepts, &.{"canonical_packaged"});
    try expectList(rules.new_game.refuses, &.{ "prototype_authored", "canonical_seed_unavailable", "canonical_seed_mismatch" });

    try expectStr(rules.continue_game.selects, "latest_loadable");
    try expectStr(rules.continue_game.order, "slot.order descending");
    try expectStr(rules.continue_game.tie_break, "lowest_slot");

    try expectStr(rules.load.empty, "notice");
    try expectStr(rules.load.ready, "load");
    try expectStr(rules.load.backup, "load_from_backup");
    try expectStr(rules.load.damaged, "notice");
    try expectStr(rules.load.future, "notice");

    try expectStr(rules.save.empty, "direct");
    try expectStr(rules.save.ready, "confirm_then_backup");
    try expectStr(rules.save.backup, "confirm_then_backup");
    try expectStr(rules.save.damaged, "confirm_replace");
    try expectStr(rules.save.future, "refused");

    try expectStr(rules.setup.cancel, "discard_draft");
    try expectStr(rules.setup.confirm, "atomic_replace");
    try expectStr(rules.setup.write_failure, "keep_previous");
    if (!rules.setup.independent_of_campaign) return error.InvalidPolicy;
    try expectStr(rules.setup.initial, "unset");

    if (raw.dependencies.len != dependencies.len) return error.InvalidPolicy;
    for (raw.dependencies, dependencies) |dependency, want| {
        try expectStr(dependency.id, @tagName(want.id));
        try expectStr(dependency.pack, want.pack);
        try expectStr(dependency.state, "unavailable");
        if (dependency.interface.len == 0 or dependency.use.len == 0) return error.InvalidPolicy;
    }

    const policy = Policy{ .slot_count = raw.source.slot_contract.count, .name_max = raw.source.name_entry.max_chars, .default_row = raw.source.start_menu.default_row, .seed_sha256 = digest };
    try policy.validate();
    return policy;
}

test "the compiled rows keep their source/port provenance" {
    try std.testing.expectEqual(RowId.new_game, rows[0].id);
    try std.testing.expectEqual(Provenance.source_observed, rows[0].provenance);
    try std.testing.expectEqual(RowId.continue_game, rows[1].id);
    try std.testing.expectEqual(default_row, 1);
    try std.testing.expectEqual(Provenance.port_extension, rows[2].provenance);
    try std.testing.expectEqual(Provenance.port_extension, rows[3].provenance);
    try std.testing.expectEqual(@as(u8, 15), setup_group);
}

test "sha256 parsing rejects a wrong digest length" {
    try std.testing.expectError(error.InvalidPolicy, parseSha256("47243f2f"));
    const digest = try parseSha256("47243f2f86f9eed90dc48a0740e51c1925a371e3a232cb216c52df44fc9ab520");
    try std.testing.expectEqualSlices(u8, &start_seed_sha256, &digest);
}
