//! Enemy policy data model: enemy policy/effect plans and settlement facts as
//! semantic ids and units.
//!
//! Generated from the reviewed A-H overlay parses.  It carries no RAM
//! addresses, LBAs, file offsets or pointer arithmetic.
//!
//! A record either has a recovered decision plan or a typed blocker.  A
//! recovered plan's special action may still have an unresolved effect; that
//! is carried explicitly (`effect.kind == .unresolved` with its blocker), and
//! the adapter never substitutes another rule for it.

const std = @import("std");

pub const schema = "suikoden-enemy-policy/1";
pub const slot_count: usize = 6;
pub const front_below: u8 = 4;
pub const money_cap: u32 = 999999;
pub const money_rune: u8 = 0x17;
pub const max_drop_item: u8 = 179;

pub const Drop = struct { item: u8, rate: u8 };

pub const Position = struct { x: i16, y: i16, z: i16 };

pub const Family = enum {
    random_target,
    target_then_script_chance,
    target_then_special_chance,
    own_row_special,
    target_row_special,
    always_special,
    blocked,
};

pub const DrawKind = enum {
    percent_100,
    scale_100_32767,
    scale_100_32767_mod_100,
};

pub const Scan = struct {
    front_only: bool,
    draw_kind: DrawKind,
    accept_at_least: u8,
};

pub const SecondDraw = struct {
    kind: DrawKind,
    threshold: u8,
};

pub const NoSelection = enum {
    pending_if_any_eligible,
    disabled,
    pending,
};

pub const SpecialKind = enum { script, descriptor, descriptor_callback };

pub const EffectKind = enum { unresolved, double_physical_result_once };

pub const BlockerCode = enum {
    unclassified_callback,
    pre_scan_special,
    unresolved_library_slot_124,
    unresolved_special_effect,
    unresolved_script_effect,
    unresolved_descriptor_effect,
};

pub const Blocker = struct {
    code: BlockerCode,
    detail: []const u8,
};

pub const Effect = struct {
    kind: EffectKind,
    blocker: ?Blocker = null,
};

pub const Special = struct {
    kind: SpecialKind,
    target_required: bool,
    wait_frames: u8,
    descriptor: ?[]const u8 = null,
    callback: ?[]const u8 = null,
    script: ?[]const u8 = null,
    effect: Effect,

    pub fn resolved(self: Special) bool {
        return self.effect.kind != .unresolved;
    }
};

pub const Policy = struct {
    family: Family,
    scan: ?Scan = null,
    second_draw: ?SecondDraw = null,
    own_row_front_below: ?u8 = null,
    target_row_front_below: ?u8 = null,
    no_selection: ?NoSelection = null,
    special: ?Special = null,
    blocker: ?Blocker = null,
};

pub const Record = struct {
    id: []const u8,
    name: []const u8,
    level: u8,
    hp: u16,
    money_encoded: i16,
    drops: [3]Drop,
    policy: Policy,
};

pub const Slot = struct {
    roster_id: u8,
    record: ?[]const u8,
    position: Position,
};

pub const Formation = struct {
    id: []const u8,
    active: u8,
    slots: [slot_count]Slot,
};

pub const Area = struct {
    id: []const u8,
    label: []const u8,
    records: []const Record,
    formations: []const Formation,
};

pub const Catalogue = struct {
    reviewed_commit: []const u8,
    asset_sha256: []const u8,
    asset_canonical_sha256: []const u8,
    module_sha256: []const u8,
};

pub const DropItem = struct {
    id: u8,
    default_uses: u8,
};

pub const Binding = struct {
    battle_profile: []const u8,
    record: []const u8,
};

pub const RowSemantics = struct {
    slot_count: u8,
    front_rule: []const u8,
    front_below: u8,
};

pub const Packet = struct {
    schema: []const u8,
    catalogue: Catalogue,
    drop_items: []const DropItem,
    areas: []const Area,
    bindings: []const Binding,
    row_semantics: RowSemantics,

    pub fn validate(self: Packet) !void {
        if (!std.mem.eql(u8, self.schema, schema)) return error.UnsupportedEnemyPolicyPacket;
        try validHex(self.catalogue.reviewed_commit, 40);
        try validHex(self.catalogue.asset_sha256, 64);
        try validHex(self.catalogue.asset_canonical_sha256, 64);
        try validHex(self.catalogue.module_sha256, 64);
        if (self.row_semantics.slot_count != slot_count or self.row_semantics.front_below != front_below) return error.UnsupportedRowSemantics;
        if (self.row_semantics.front_rule.len == 0) return error.UnsupportedRowSemantics;

        if (self.areas.len == 0 or self.areas.len > 64) return error.InvalidEnemyAreas;
        var record_count: usize = 0;
        for (self.areas, 0..) |area, a| {
            if (area.id.len == 0 or area.id.len > 64) return error.InvalidEnemyArea;
            if (area.label.len == 0 or area.label.len > 32) return error.InvalidEnemyArea;
            for (self.areas[0..a]) |previous| if (std.mem.eql(u8, previous.id, area.id)) return error.InvalidEnemyArea;
            if (area.records.len == 0) return error.InvalidEnemyArea;
            for (area.records, 0..) |enemy, r| {
                try self.validateRecord(area, enemy);
                for (area.records[0..r]) |previous| if (std.mem.eql(u8, previous.id, enemy.id)) return error.InvalidEnemyRecord;
                record_count += 1;
            }
            for (area.formations, 0..) |roster, f| {
                try self.validateFormation(area, roster);
                for (area.formations[0..f]) |previous| if (std.mem.eql(u8, previous.id, roster.id)) return error.InvalidEnemyFormation;
            }
        }
        if (record_count == 0) return error.InvalidEnemyRecord;

        if (self.drop_items.len == 0) return error.InvalidDropItem;
        for (self.drop_items, 0..) |item, i| {
            if (item.id == 0 or item.id > max_drop_item) return error.InvalidDropItem;
            for (self.drop_items[0..i]) |previous| if (previous.id == item.id) return error.InvalidDropItem;
        }
        for (self.bindings, 0..) |binding, i| {
            if (binding.battle_profile.len == 0 or binding.battle_profile.len > 64) return error.InvalidBinding;
            if (self.record(binding.record) == null) return error.InvalidBinding;
            for (self.bindings[0..i]) |previous| if (std.mem.eql(u8, previous.battle_profile, binding.battle_profile)) return error.InvalidBinding;
        }
    }

    fn validateRecord(self: Packet, area: Area, enemy: Record) !void {
        _ = area;
        if (enemy.id.len == 0 or enemy.id.len > 64) return error.InvalidEnemyRecord;
        if (enemy.name.len == 0 or enemy.name.len > 32) return error.InvalidEnemyRecord;
        if (enemy.level == 0 or enemy.level > 99) return error.InvalidEnemyRecord;
        if (enemy.hp == 0) return error.InvalidEnemyRecord;
        for (enemy.drops) |drop| {
            if (drop.item > max_drop_item) return error.InvalidDropItem;
            if (drop.item != 0 and self.dropItem(drop.item) == null) return error.MissingDropItem;
        }
        const policy = enemy.policy;
        if (policy.family == .blocked) {
            if (policy.blocker == null) return error.BlockedPolicyWithoutBlocker;
            if (policy.scan != null or policy.special != null or policy.second_draw != null) return error.BlockedPolicyWithPlan;
            return;
        }
        if (policy.blocker != null) return error.UnblockedPolicyWithBlocker;
        const scan = policy.scan orelse return error.MissingPolicyScan;
        if (scan.accept_at_least != 51) return error.InvalidPolicyScan;
        if (policy.no_selection == null) return error.MissingNoSelectionPolicy;
        switch (policy.family) {
            .random_target => {
                if (policy.second_draw != null or policy.special != null) return error.InvalidPolicyFamily;
                if (policy.own_row_front_below != null or policy.target_row_front_below != null) return error.InvalidPolicyFamily;
            },
            .target_then_script_chance, .target_then_special_chance => {
                const second = policy.second_draw orelse return error.MissingSecondDraw;
                if (second.threshold == 0 or second.threshold > 100) return error.InvalidSecondDraw;
                const special = policy.special orelse return error.MissingSpecial;
                if (!special.target_required) return error.InvalidSpecialTarget;
                try validateSpecial(special);
                if ((policy.family == .target_then_script_chance) != (special.kind == .script)) return error.InvalidPolicyFamily;
            },
            .own_row_special => {
                if (policy.own_row_front_below == null or policy.own_row_front_below.? != front_below) return error.InvalidPolicyFamily;
                if (policy.second_draw != null or policy.target_row_front_below != null) return error.InvalidPolicyFamily;
                const special = policy.special orelse return error.MissingSpecial;
                if (special.target_required) return error.InvalidSpecialTarget;
                try validateSpecial(special);
            },
            .target_row_special => {
                if (policy.target_row_front_below == null or policy.target_row_front_below.? != front_below) return error.InvalidPolicyFamily;
                if (policy.second_draw != null or policy.own_row_front_below != null) return error.InvalidPolicyFamily;
                const special = policy.special orelse return error.MissingSpecial;
                if (!special.target_required) return error.InvalidSpecialTarget;
                try validateSpecial(special);
            },
            .always_special => {
                if (policy.second_draw != null) return error.InvalidPolicyFamily;
                if (policy.own_row_front_below != null or policy.target_row_front_below != null) return error.InvalidPolicyFamily;
                const special = policy.special orelse return error.MissingSpecial;
                if (!special.target_required) return error.InvalidSpecialTarget;
                try validateSpecial(special);
            },
            .blocked => unreachable,
        }
    }

    fn validateFormation(self: Packet, area: Area, roster: Formation) !void {
        _ = self;
        if (roster.id.len == 0 or roster.id.len > 64) return error.InvalidEnemyFormation;
        if (roster.active == 0 or roster.active > slot_count) return error.InvalidEnemyFormation;
        var active: u8 = 0;
        for (roster.slots) |slot| {
            if (slot.record) |id| {
                active += 1;
                if (slot.roster_id == 0) return error.InvalidEnemyFormation;
                var found = false;
                for (area.records) |enemy| if (std.mem.eql(u8, enemy.id, id)) {
                    found = true;
                };
                if (!found) return error.UnknownFormationRecord;
            } else if (slot.roster_id != 0) return error.InvalidEnemyFormation;
        }
        if (active != roster.active) return error.InvalidEnemyFormation;
    }

    pub fn record(self: *const Packet, id: []const u8) ?*const Record {
        for (self.areas) |*area| for (area.records) |*enemy| {
            if (std.mem.eql(u8, enemy.id, id)) return enemy;
        };
        return null;
    }

    pub fn bind(self: *const Packet, battle_profile: []const u8) ?*const Record {
        for (self.bindings) |binding| {
            if (std.mem.eql(u8, binding.battle_profile, battle_profile)) return self.record(binding.record);
        }
        return null;
    }

    pub fn dropItem(self: Packet, id: u8) ?DropItem {
        for (self.drop_items) |item| if (item.id == id) return item;
        return null;
    }

    pub fn formation(self: *const Packet, id: []const u8) ?*const Formation {
        for (self.areas) |*area| for (area.formations) |*roster| {
            if (std.mem.eql(u8, roster.id, id)) return roster;
        };
        return null;
    }
};

fn validateSpecial(special: Special) !void {
    if (special.effect.kind == .unresolved) {
        if (special.effect.blocker == null) return error.MissingEffectBlocker;
    } else if (special.effect.blocker != null) return error.UnexpectedEffectBlocker;
    if (special.wait_frames > 120) return error.InvalidSpecialWait;
    switch (special.kind) {
        .script => if (special.script == null or special.script.?.len == 0) return error.MissingSpecialResource,
        .descriptor => if (special.descriptor == null or special.descriptor.?.len == 0) return error.MissingSpecialResource,
        .descriptor_callback => {
            if (special.descriptor == null or special.descriptor.?.len == 0) return error.MissingSpecialResource;
            if (special.callback == null or special.callback.?.len == 0) return error.MissingSpecialResource;
        },
    }
}

fn validHex(value: []const u8, length: usize) !void {
    if (value.len != length) return error.InvalidCataloguePin;
    for (value) |c| if (!std.ascii.isHex(c)) return error.InvalidCataloguePin;
}

pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Packet) {
    const parsed = try std.json.parseFromSlice(Packet, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}
