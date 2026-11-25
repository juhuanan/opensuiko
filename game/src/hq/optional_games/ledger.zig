//! The pinned source mode-entry ledger (parsed from the embedded asset).

const std = @import("std");
const data = @import("hq_data").optional_games;
const types = @import("types.zig");

pub const Game = types.Game;
pub const EntryKind = types.EntryKind;
pub const CallerStatus = types.CallerStatus;
pub const schema = types.schema;
pub const rules_schema = types.rules_schema;

pub const Caller = struct {
    path: []const u8 = "",
    sha256: []const u8 = "",
    room: u16 = 0,
    entity: u16 = 0,
    x: u16 = 0,
    y: u16 = 0,
    npc_id: u8 = 0,
    stream_offset: u32 = 0,
    site: u32 = 0,
    guard: []const u8 = "",
    dice_variant: ?u8 = null,
};

pub const Overlay = struct {
    path: []const u8 = "",
    lba: u32 = 0,
    size: u32 = 0,
    sha256: [32]u8 = @splat(0),
};

pub const Family = struct {
    id: []const u8 = "",
    game: Game = .dice,
    selector: ?u8 = null,
    entry_kind: EntryKind = .field_room,
    entry_status: CallerStatus = .missing_field_caller,
    entry_detail: []const u8 = "",
    overlay: Overlay = .{},
    callers: []const Caller = &.{},

    /// The caller sites this family admits.  A field admission must name one of
    /// them: a selector alone is not an admission.
    pub fn admitsSite(self: Family, site: u32) bool {
        for (self.callers) |caller| if (caller.site == site) return true;
        return false;
    }
};

pub const Ownership = struct {
    frame_owner: []const u8 = "",
    field_owner_suspended: []const u8 = "",
    return_path: []const u8 = "",
    dialogue: []const u8 = "",
    animation: []const u8 = "",
};

pub const ModeEntry = struct {
    mode_word_field: []const u8 = "",
    special_content_value: u8 = 0,
    second_lane_value: u8 = 0,
    selector_field: []const u8 = "",
    table_va: u32 = 0,
    table_entries: u8 = 0,
    loader_va: u32 = 0,
    overlay_entry_word: u32 = 0,
    event_opcode: u8 = 0,
    ff_context_flag: u8 = 0,
    fe_context_flag: u8 = 0,
};

pub const GsFields = struct {
    mode_word: []const u8 = "",
    selector: []const u8 = "",
    money: []const u8 = "",
    status: []const u8 = "",
    recruit: []const u8 = "",
};

pub const Blocker = struct {
    id: []const u8 = "",
    kind: []const u8 = "",
    family: []const u8 = "",
    detail: []const u8 = "",
};

pub const Ledger = struct {
    arena: std.heap.ArenaAllocator,
    schema: []const u8,
    base: []const u8,
    rules_module: []const u8,
    rules_schema: []const u8,
    entry: ModeEntry,
    gs: GsFields,
    ownership: Ownership,
    families: []const Family,
    blockers: []const Blocker,
    host_integration: []const u8,
    asset_sha256: [32]u8,

    pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !Ledger {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const expected = comptimeHex(data.sha256_hex);
        if (!std.mem.eql(u8, &digest, &expected)) return error.AssetIdentityMismatch;

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const parsed = try std.json.parseFromSliceLeaky(Wire, arena.allocator(), bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });

        if (!std.mem.eql(u8, parsed.schema, schema)) return error.UnsupportedSchema;
        if (!std.mem.eql(u8, parsed.rules_contract.schema, rules_schema)) return error.UnsupportedRulesSchema;
        if (parsed.core.module_table.entries.len != 16) return error.InvalidLedger;

        var families = try arena.allocator().alloc(Family, parsed.families.len);
        for (parsed.families, 0..) |wire, index| {
            const overlay_sha = try types.parseHex32(wire.overlay.sha256);
            var callers = try arena.allocator().alloc(Caller, wire.callers.len);
            for (wire.callers, 0..) |caller, caller_index| {
                if (caller.dice_variant != null and caller.dice_variant.? > 2) return error.InvalidLedger;
                _ = try types.parseHex32(caller.sha256);
                callers[caller_index] = .{
                    .path = caller.path,
                    .sha256 = caller.sha256,
                    .room = caller.room,
                    .entity = caller.entity,
                    .x = caller.x,
                    .y = caller.y,
                    .npc_id = caller.npc_id,
                    .stream_offset = caller.stream_offset,
                    .site = caller.site,
                    .guard = caller.guard,
                    .dice_variant = caller.dice_variant,
                };
            }
            families[index] = .{
                .id = wire.id,
                .game = try types.parseGame(wire.game),
                .selector = wire.selector,
                .entry_kind = try types.parseEntryKind(wire.entry_kind),
                .entry_status = try types.parseCallerStatus(wire.entry_status),
                .entry_detail = wire.entry_detail,
                .overlay = .{
                    .path = wire.overlay.path,
                    .lba = wire.overlay.lba,
                    .size = wire.overlay.size,
                    .sha256 = overlay_sha,
                },
                .callers = callers,
            };
        }

        var blockers = try arena.allocator().alloc(Blocker, parsed.blockers.len);
        for (parsed.blockers, 0..) |wire, index| {
            blockers[index] = .{ .id = wire.id, .kind = wire.kind, .family = wire.family, .detail = wire.detail };
        }

        const ledger = Ledger{
            .arena = arena,
            .schema = parsed.schema,
            .base = parsed.base,
            .rules_module = parsed.rules_contract.module,
            .rules_schema = parsed.rules_contract.schema,
            .entry = .{
                .mode_word_field = parsed.core.mode_word.field,
                .special_content_value = parsed.core.mode_word.special_content_value,
                .second_lane_value = parsed.core.mode_word.second_lane_value,
                .selector_field = parsed.core.selector.field,
                .table_va = parsed.core.module_table.va_number,
                .table_entries = @intCast(parsed.core.module_table.entries.len),
                .loader_va = parsed.core.loader.va_number,
                .overlay_entry_word = parsed.core.loader.overlay_entry_word_number,
                .event_opcode = parsed.core.event_opcode.op,
                .ff_context_flag = parsed.core.event_opcode.ff_context_flag,
                .fe_context_flag = parsed.core.event_opcode.fe_context_flag,
            },
            .gs = .{
                .mode_word = parsed.core.gs_fields.mode_word,
                .selector = parsed.core.gs_fields.selector,
                .money = parsed.core.gs_fields.money,
                .status = parsed.core.gs_fields.status,
                .recruit = parsed.core.gs_fields.recruit,
            },
            .ownership = .{
                .frame_owner = parsed.core.ownership.frame_owner,
                .field_owner_suspended = parsed.core.ownership.field_owner_suspended,
                .return_path = parsed.core.ownership.return_path,
                .dialogue = parsed.core.ownership.dialogue,
                .animation = parsed.core.ownership.animation,
            },
            .families = families,
            .blockers = blockers,
            .host_integration = parsed.host_integration,
            .asset_sha256 = digest,
        };
        try ledger.validate();
        return ledger;
    }

    pub fn deinit(self: *Ledger) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn family(self: Ledger, game: Game) ?*const Family {
        for (self.families) |*row| if (row.game == game) return row;
        return null;
    }

    pub fn requireFamily(self: Ledger, game: Game) !*const Family {
        return self.family(game) orelse error.UnknownGame;
    }

    fn validate(self: Ledger) !void {
        if (self.families.len != 3) return error.InvalidLedger;
        if (self.entry.event_opcode != 0x47) return error.InvalidLedger;
        if (self.entry.ff_context_flag != 0x08 or self.entry.fe_context_flag != 0x10) return error.InvalidLedger;
        if (self.entry.special_content_value != 4 or self.entry.second_lane_value != 5) return error.InvalidLedger;
        if (self.entry.table_entries != 16) return error.InvalidLedger;
        if (!std.mem.eql(u8, self.gs.money, "gs+0x1C")) return error.InvalidLedger;
        if (!std.mem.eql(u8, self.gs.status, "gs+0x230")) return error.InvalidLedger;
        if (!std.mem.eql(u8, self.gs.recruit, "gs+0x1AF4")) return error.InvalidLedger;

        const coin = try self.requireFamily(.coin);
        if (coin.entry_status != .proven) return error.InvalidLedger;
        if (coin.selector != 11) return error.InvalidLedger;
        if (coin.callers.len != 2) return error.InvalidLedger;
        if (!coin.admitsSite(0x26430) or !coin.admitsSite(0x31641)) return error.InvalidLedger;
        for (coin.callers) |caller| {
            if (caller.room != 0) return error.InvalidLedger;
            if (!std.mem.eql(u8, caller.guard, "interaction")) return error.InvalidLedger;
        }
        if (!std.mem.endsWith(u8, coin.overlay.path, "COIN.BIN")) return error.InvalidLedger;

        const karuta = try self.requireFamily(.karuta);
        if (karuta.entry_status != .proven) return error.InvalidLedger;
        if (karuta.selector != 15) return error.InvalidLedger;
        if (karuta.callers.len != 1 or !karuta.admitsSite(0x3162D)) return error.InvalidLedger;
        if (!std.mem.endsWith(u8, karuta.overlay.path, "KARUTA.BIN")) return error.InvalidLedger;

        const dice = try self.requireFamily(.dice);
        if (dice.entry_status != .proven) return error.InvalidLedger;
        if (dice.callers.len != 2 or dice.callers[0].dice_variant != 1 or dice.callers[1].dice_variant != 2) return error.InvalidLedger;
        if (dice.selector != null) return error.InvalidLedger;
        if (dice.entry_kind != .field_room) return error.InvalidLedger;
        if (!std.mem.endsWith(u8, dice.overlay.path, "VB2.BIN")) return error.InvalidLedger;
    }
};

fn comptimeHex(comptime text: []const u8) [32]u8 {
    @setEvalBranchQuota(4000);
    if (text.len != 64) @compileError("optional_games_data.sha256_hex must be 64 hex characters");
    var out: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        out[i] = comptimeNibble(text[i * 2]) * 16 + comptimeNibble(text[i * 2 + 1]);
    }
    return out;
}

fn comptimeNibble(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => unreachable,
    };
}

// ---------------------------------------------------------------------------
// JSON wire types (only the fields this consumer needs; the digest pins the rest)
// ---------------------------------------------------------------------------

const Wire = struct {
    schema: []const u8,
    base: []const u8,
    rules_contract: struct {
        commit: []const u8,
        module: []const u8,
        schema: []const u8,
    },
    core: struct {
        mode_word: struct {
            field: []const u8,
            special_content_value: u8,
            second_lane_value: u8,
        },
        selector: struct { field: []const u8 },
        module_table: struct {
            va: []const u8,
            va_number: u32,
            entries: [16]struct {
                selector: u8,
                size: u32,
                lba: u32,
                path: []const u8,
                family: []const u8,
            },
        },
        loader: struct {
            va: []const u8,
            va_number: u32,
            install_site: []const u8,
            overlay_entry_word: []const u8,
            overlay_entry_word_number: u32,
            overlay_base: []const u8,
            frame_callback_table: []const u8,
        },
        event_opcode: struct {
            op: u8,
            handler: []const u8,
            ff_context_flag: u8,
            ff_selects: bool,
            fe_context_flag: u8,
            fe_selects: bool,
        },
        mode_literals: struct {
            mode4_site: []const u8,
            mode5_site: []const u8,
        },
        ownership: struct {
            frame_owner: []const u8,
            field_owner_suspended: []const u8,
            return_path: []const u8,
            dialogue: []const u8,
            animation: []const u8,
        },
        field_callers: std.json.Value,
        overlay_hashes: std.json.Value,
        gs_fields: struct {
            mode_word: []const u8,
            selector: []const u8,
            money: []const u8,
            status: []const u8,
            recruit: []const u8,
            status_flags: ?[]const u8 = null,
            recruit_flags: ?[]const u8 = null,
        },
    },
    families: []const struct {
        id: []const u8,
        game: []const u8,
        selector: ?u8 = null,
        entry_kind: []const u8,
        entry_status: []const u8,
        entry_detail: []const u8,
        overlay: struct {
            path: []const u8,
            lba: u32,
            size: u32,
            sha256: []const u8,
        },
        callers: []const struct {
            path: []const u8,
            lba: u32,
            size: u32,
            sha256: []const u8,
            room: u16,
            entity: u16,
            x: u16,
            y: u16,
            npc_id: u8,
            stream_offset: u32,
            site: u32,
            opcode_hex: []const u8,
            guard: []const u8,
            dice_variant: ?u8 = null,
        },
        candidate_sites: ?[]const std.json.Value = null,
        publication: std.json.Value,
    },
    blockers: []const struct {
        id: []const u8,
        kind: []const u8,
        family: []const u8,
        detail: []const u8,
    },
    host_integration: []const u8,
};

test "ledger: the pinned asset parses its proven caller sites" {
    var ledger = try Ledger.load(std.testing.allocator, data.json);
    defer ledger.deinit();
    try std.testing.expectEqualStrings(schema, ledger.schema);
    try std.testing.expectEqual(@as(u8, 0x47), ledger.entry.event_opcode);
    try std.testing.expectEqual(@as(u8, 16), ledger.entry.table_entries);
    try std.testing.expectEqual(@as(u32, 0x8016F258), ledger.entry.table_va);
    try std.testing.expectEqual(@as(usize, 2), (ledger.requireFamily(.coin) catch unreachable).callers.len);
    try std.testing.expect((ledger.requireFamily(.coin) catch unreachable).admitsSite(0x26430));
    try std.testing.expect((ledger.requireFamily(.karuta) catch unreachable).admitsSite(0x3162D));
    try std.testing.expectEqual(CallerStatus.proven, (ledger.requireFamily(.dice) catch unreachable).entry_status);
    try std.testing.expect(ledger.blockers.len >= 3);
}

test "ledger: a mutated asset fails the identity check before parsing" {
    const bytes = try std.testing.allocator.dupe(u8, data.json);
    defer std.testing.allocator.free(bytes);
    bytes[bytes.len - 2] ^= 0x01;
    try std.testing.expectError(error.AssetIdentityMismatch, Ledger.load(std.testing.allocator, bytes));
}
