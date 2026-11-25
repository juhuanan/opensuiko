//! Campaign-scale roster progression and ownership.
//!
//! The canonical record is the existing `party.Snapshot` (`battle.OwnedMember`
//! plus `party.CharacterExtra`) and the existing HQ roster presence/loaded/
//! departure sidecar.  This module adds only the named-rune sidecar and the
//! source progression operations that the earlier party packages left to a
//! campaign host:
//!
//!   * admit a source seed record (reserve-eligible, not active);
//!   * activate / swap / force-depart / follower selection;
//!   * source growth (1000 EXP per level, two 48-word tables, explicit draws);
//!   * weapon level, rune-piece counters, equipment and rune attach/detach;
//!   * knockout / revive / rest;
//!   * a bounded JSON save/restore round trip.
//!
//! Every mutating operation runs on a copy and validates before replacing the
//! live ledger.  An unknown profile, item, rune or binding, an aliased member
//! id or a mismatched sidecar returns a typed error and leaves the caller's
//! ledger unchanged.  No original instruction, emulator, window or media is
//! involved.
const std = @import("std");
const battle = @import("battle");
const field = @import("field");
const party = @import("party_session");
const hq_roster = @import("hq").roster;
pub const catalogue = @import("catalogue.zig");

pub const max_members = party.max_owned;
pub const max_active = 6;
pub const max_state_bytes = 1024 * 1024;

pub const Element = @FieldType(party.CharacterExtra, "weapon_element");
pub const WeaponPiece = enum { fire, water, wind, thunder, earth };
pub const DepartureKind = hq_roster.roster.LeaveKind;

pub const RetainedItem = struct {
    id: []const u8,
    uses: u16,
    identified: bool,
};

pub const Progress = struct {
    profile: []const u8,
    source_character_id: u16,
    rune_id: ?[]const u8 = null,
    rune_locked: bool = false,
    /// Source stacks whose item id has no `field.items.Id` variant at this
    /// base.  They are retained here, never aliased to another item and never
    /// silently dropped; the host adds the canonical variants.
    retained: [9]?RetainedItem = @splat(null),
};

pub const Bindings = struct {
    /// Index -> named id in the caller's battle systems equipment array.
    equipment: []const []const u8,
    /// Index -> named id in the caller's battle systems rune array.
    runes: []const []const u8,

    pub fn validate(self: Bindings) !void {
        for (self.equipment, 0..) |id, i| {
            if (id.len == 0) return error.InvalidBinding;
            for (self.equipment[0..i]) |previous| if (std.mem.eql(u8, previous, id)) return error.DuplicateBinding;
        }
        for (self.runes, 0..) |id, i| {
            if (id.len == 0) return error.InvalidBinding;
            for (self.runes[0..i]) |previous| if (std.mem.eql(u8, previous, id)) return error.DuplicateBinding;
        }
    }
    pub fn equipmentIndex(self: Bindings, id: []const u8) ?usize {
        for (self.equipment, 0..) |candidate, i| if (std.mem.eql(u8, candidate, id)) return i;
        return null;
    }
    pub fn runeIndex(self: Bindings, id: []const u8) ?usize {
        for (self.runes, 0..) |candidate, i| if (std.mem.eql(u8, candidate, id)) return i;
        return null;
    }
};

pub const Kind = enum {
    admit,
    activate,
    swap,
    depart,
    followers,
    exp,
    weapon,
    piece,
    equip,
    unequip,
    rune,
    knockout,
    revive,
    rest,
};

pub const Receipt = struct {
    revision: u64,
    kind: Kind,
    profile: []const u8,
    detail: u32 = 0,
};

pub const Role = enum { active, reserve, follower, absent };

pub const Ledger = struct {
    base: hq_roster.roster.Roster,
    progress: [max_members]?Progress = @splat(null),
    source_digest: [32]u8,

    const Persisted = struct {
        schema: []const u8,
        source_digest: [64]u8,
        base_source_digest: [64]u8,
        snapshot: party.Snapshot,
        states: [max_members]hq_roster.roster.MemberState,
        noncombatants: [hq_roster.max_noncombatants]?hq_roster.roster.NoncombatantState,
        progress: [max_members]?Progress,
        revision: u64,
        last_receipt: ?u64,
    };

    /// Seed the canonical Hero record and bind it to the source roster data.
    pub fn init(roster_asset: catalogue.Asset, roster_source: hq_roster.source.Packet, bindings: Bindings, initial_id: []const u8) !Ledger {
        try catalogue.validate(roster_asset);
        try roster_source.validate();
        try bindings.validate();
        const profile = catalogue.profile(roster_asset, initial_id) orelse return error.UnknownProfile;
        _ = roster_source.profile(initial_id) orelse return error.UnknownProfile;
        var snapshot: party.Snapshot = .{
            .schema = party.version,
            .entry_id = "roster-seed",
            .content_id = roster_asset.content_sha256,
            .receipt = "roster-seed-genesis",
            .baseline_revision = 0,
        };
        snapshot.storage = .{};
        snapshot.members[0] = try seedMember(roster_asset, bindings, profile);
        snapshot.extras[0] = try seedExtra(roster_asset, profile);
        snapshot.eligible[0] = true;
        snapshot.active[0] = initial_id;
        const base = try hq_roster.roster.Roster.init(roster_source, snapshot, &.{});
        var result = Ledger{ .base = base, .source_digest = digestAsset(roster_asset) };
        result.progress[0] = try seedProgress(roster_asset, profile);
        try result.validate(roster_asset, roster_source, bindings);
        return result;
    }

    pub fn memberCount(self: *const Ledger) usize {
        var count: usize = 0;
        for (self.base.snapshot.members) |maybe| if (maybe != null) {
            count += 1;
        };
        return count;
    }
    pub fn activeCount(self: *const Ledger) usize {
        return self.base.activeCount();
    }
    pub fn find(self: *const Ledger, id: []const u8) ?usize {
        for (self.base.snapshot.members, 0..) |maybe, i| if (maybe) |member| {
            if (std.mem.eql(u8, member.member.id, id)) return i;
        };
        return null;
    }
    pub fn firstFree(self: *const Ledger) ?usize {
        for (self.base.snapshot.members, 0..) |maybe, i| if (maybe == null) return i;
        return null;
    }
    pub fn owned(self: *const Ledger, id: []const u8) ?battle.OwnedMember {
        const index = self.find(id) orelse return null;
        return self.base.snapshot.members[index];
    }
    pub fn extra(self: *const Ledger, id: []const u8) ?party.CharacterExtra {
        const index = self.find(id) orelse return null;
        return self.base.snapshot.extras[index];
    }
    pub fn progressOf(self: *const Ledger, id: []const u8) ?Progress {
        const index = self.find(id) orelse return null;
        return self.progress[index];
    }
    pub fn role(self: *const Ledger, id: []const u8) Role {
        if (self.base.isActive(id)) return .active;
        for (self.base.snapshot.followers) |maybe| if (maybe) |value| {
            if (std.mem.eql(u8, value, id)) return .follower;
        };
        const index = self.find(id) orelse return .absent;
        return if (self.base.snapshot.eligible[index]) .reserve else .absent;
    }
    pub fn isEligible(self: *const Ledger, id: []const u8) bool {
        const index = self.find(id) orelse return false;
        return self.base.snapshot.eligible[index];
    }

    pub fn admit(self: *Ledger, roster_asset: catalogue.Asset, roster_source: hq_roster.source.Packet, bindings: Bindings, id: []const u8, source_text: []const u8) !Receipt {
        if (source_text.len == 0) return error.InvalidSource;
        var next = self.*;
        const profile = catalogue.profile(roster_asset, id) orelse return error.UnknownProfile;
        _ = roster_source.profile(id) orelse return error.UnknownProfile;
        if (next.find(id) != null) return error.AlreadyOwned;
        const slot = next.firstFree() orelse return error.RosterFull;
        next.base.snapshot.members[slot] = try seedMember(roster_asset, bindings, profile);
        next.base.snapshot.extras[slot] = try seedExtra(roster_asset, profile);
        next.progress[slot] = try seedProgress(roster_asset, profile);
        next.base.snapshot.eligible[slot] = true;
        next.bump();
        try next.validate(roster_asset, roster_source, bindings);
        self.* = next;
        return .{ .revision = self.base.revision, .kind = .admit, .profile = id };
    }

    pub fn activate(self: *Ledger, roster_asset: catalogue.Asset, roster_source: hq_roster.source.Packet, bindings: Bindings, id: []const u8, source_text: []const u8) !Receipt {
        var next = self.*;
        try loadMember(&next.base, roster_source, id, source_text);
        next.bump();
        try next.validate(roster_asset, roster_source, bindings);
        self.* = next;
        return .{ .revision = self.base.revision, .kind = .activate, .profile = id };
    }

    pub fn rejoin(self: *Ledger, roster_asset: catalogue.Asset, roster_source: hq_roster.source.Packet, bindings: Bindings, id: []const u8, source_text: []const u8) !Receipt {
        var next = self.*;
        try next.base.rejoin(roster_source, id, false, source_text);
        next.bump();
        try next.validate(roster_asset, roster_source, bindings);
        self.* = next;
        return .{ .revision = self.base.revision, .kind = .activate, .profile = id };
    }

    /// Leave the active six and load a reserve member in one transaction.
    pub fn swap(self: *Ledger, roster_asset: catalogue.Asset, roster_source: hq_roster.source.Packet, bindings: Bindings, out_id: []const u8, in_id: []const u8, source_text: []const u8) !Receipt {
        if (std.mem.eql(u8, out_id, in_id)) return error.InvalidRecipient;
        var next = self.*;
        try next.base.leave(roster_source, out_id, .temporary, source_text);
        try loadMember(&next.base, roster_source, in_id, source_text);
        next.bump();
        try next.validate(roster_asset, roster_source, bindings);
        self.* = next;
        return .{ .revision = self.base.revision, .kind = .swap, .profile = out_id, .detail = @intCast(next.find(in_id) orelse 0) };
    }

    pub fn forceDepart(self: *Ledger, roster_asset: catalogue.Asset, roster_source: hq_roster.source.Packet, bindings: Bindings, id: []const u8, kind: DepartureKind, source_text: []const u8) !Receipt {
        var next = self.*;
        try next.base.leave(roster_source, id, kind, source_text);
        next.bump();
        try next.validate(roster_asset, roster_source, bindings);
        self.* = next;
        return .{ .revision = self.base.revision, .kind = .depart, .profile = id };
    }

    pub fn setFollowers(self: *Ledger, roster_asset: catalogue.Asset, roster_source: hq_roster.source.Packet, bindings: Bindings, followers: [max_active]?[]const u8) !Receipt {
        var next = self.*;
        try next.base.setFollowers(roster_source, followers);
        next.bump();
        try next.validate(roster_asset, roster_source, bindings);
        self.* = next;
        return .{ .revision = self.base.revision, .kind = .followers, .profile = "" };
    }

    pub fn awardExp(self: *Ledger, roster_asset: catalogue.Asset, roster_source: hq_roster.source.Packet, bindings: Bindings, id: []const u8, amount: u32, rolls: []const u16) !Receipt {
        var next = self.*;
        try next.awardExpInner(roster_asset, id, amount, rolls);
        next.bump();
        try next.validate(roster_asset, roster_source, bindings);
        self.* = next;
        return .{ .revision = self.base.revision, .kind = .exp, .profile = id, .detail = amount };
    }

    pub fn raiseWeapon(self: *Ledger, roster_asset: catalogue.Asset, roster_source: hq_roster.source.Packet, bindings: Bindings, id: []const u8) !Receipt {
        var next = self.*;
        try next.raiseWeaponInner(roster_asset, id);
        next.bump();
        try next.validate(roster_asset, roster_source, bindings);
        self.* = next;
        return .{ .revision = self.base.revision, .kind = .weapon, .profile = id };
    }

    pub fn applyWeaponPiece(self: *Ledger, roster_asset: catalogue.Asset, roster_source: hq_roster.source.Packet, bindings: Bindings, id: []const u8, piece: WeaponPiece, replace: bool) !Receipt {
        var next = self.*;
        try next.applyWeaponPieceInner(roster_asset, id, piece, replace);
        next.bump();
        try next.validate(roster_asset, roster_source, bindings);
        self.* = next;
        return .{ .revision = self.base.revision, .kind = .piece, .profile = id, .detail = @backingInt(piece) + 1 };
    }

    pub fn equip(self: *Ledger, roster_asset: catalogue.Asset, roster_source: hq_roster.source.Packet, bindings: Bindings, id: []const u8, slot: battle.systems.EquipmentSlot, item_id: []const u8) !Receipt {
        var next = self.*;
        try next.equipInner(roster_asset, bindings, id, slot, item_id);
        next.bump();
        try next.validate(roster_asset, roster_source, bindings);
        self.* = next;
        return .{ .revision = self.base.revision, .kind = .equip, .profile = id };
    }

    pub fn unequip(self: *Ledger, roster_asset: catalogue.Asset, roster_source: hq_roster.source.Packet, bindings: Bindings, id: []const u8, slot: battle.systems.EquipmentSlot) !Receipt {
        var next = self.*;
        try next.unequipInner(roster_asset, id, slot);
        next.bump();
        try next.validate(roster_asset, roster_source, bindings);
        self.* = next;
        return .{ .revision = self.base.revision, .kind = .unequip, .profile = id };
    }

    pub fn attachRune(self: *Ledger, roster_asset: catalogue.Asset, roster_source: hq_roster.source.Packet, bindings: Bindings, id: []const u8, rune_id: []const u8) !Receipt {
        var next = self.*;
        try next.attachRuneInner(roster_asset, bindings, id, rune_id);
        next.bump();
        try next.validate(roster_asset, roster_source, bindings);
        self.* = next;
        return .{ .revision = self.base.revision, .kind = .rune, .profile = id };
    }

    pub fn detachRune(self: *Ledger, roster_asset: catalogue.Asset, roster_source: hq_roster.source.Packet, bindings: Bindings, id: []const u8) !Receipt {
        var next = self.*;
        try next.detachRuneInner(roster_asset, id);
        next.bump();
        try next.validate(roster_asset, roster_source, bindings);
        self.* = next;
        return .{ .revision = self.base.revision, .kind = .rune, .profile = id };
    }

    pub fn knockout(self: *Ledger, roster_asset: catalogue.Asset, roster_source: hq_roster.source.Packet, bindings: Bindings, id: []const u8, source_text: []const u8) !Receipt {
        var next = self.*;
        try next.base.knockout(roster_source, id, source_text);
        next.bump();
        try next.validate(roster_asset, roster_source, bindings);
        self.* = next;
        return .{ .revision = self.base.revision, .kind = .knockout, .profile = id };
    }

    pub fn revive(self: *Ledger, roster_asset: catalogue.Asset, roster_source: hq_roster.source.Packet, bindings: Bindings, id: []const u8, source_text: []const u8) !Receipt {
        var next = self.*;
        try next.base.revive(roster_source, id, source_text);
        next.bump();
        try next.validate(roster_asset, roster_source, bindings);
        self.* = next;
        return .{ .revision = self.base.revision, .kind = .revive, .profile = id };
    }

    pub fn rest(self: *Ledger, roster_asset: catalogue.Asset, roster_source: hq_roster.source.Packet, bindings: Bindings, id: []const u8) !Receipt {
        var next = self.*;
        try next.restInner(roster_asset, id);
        next.bump();
        try next.validate(roster_asset, roster_source, bindings);
        self.* = next;
        return .{ .revision = self.base.revision, .kind = .rest, .profile = id };
    }

    pub fn capture(self: *const Ledger, allocator: std.mem.Allocator) ![]u8 {
        const persisted = Persisted{
            .schema = catalogue.state_schema,
            .source_digest = std.fmt.bytesToHex(self.source_digest, .lower),
            .base_source_digest = std.fmt.bytesToHex(self.base.source_digest, .lower),
            .snapshot = self.base.snapshot,
            .states = self.base.states,
            .noncombatants = self.base.noncombatants,
            .progress = self.progress,
            .revision = self.base.revision,
            .last_receipt = self.base.last_receipt,
        };
        return std.json.Stringify.valueAlloc(allocator, persisted, .{});
    }

    /// Restore is arena-backed: parsed strings live in `allocator` for the
    /// lifetime of the returned ledger.  A failed restore mutates nothing.
    pub fn restore(allocator: std.mem.Allocator, roster_asset: catalogue.Asset, roster_source: hq_roster.source.Packet, bindings: Bindings, bytes: []const u8) !Ledger {
        if (bytes.len > max_state_bytes) return error.SaveTooLarge;
        try catalogue.validate(roster_asset);
        try roster_source.validate();
        try bindings.validate();
        const parsed = try std.json.parseFromSliceLeaky(Persisted, allocator, bytes, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        if (!std.mem.eql(u8, parsed.schema, catalogue.state_schema)) return error.InvalidSave;
        const expected = std.fmt.bytesToHex(digestAsset(roster_asset), .lower);
        if (!std.mem.eql(u8, &parsed.source_digest, &expected)) return error.InvalidSave;
        const source_digest = std.fmt.bytesToHex(hq_roster.source.digest(roster_source), .lower);
        if (!std.mem.eql(u8, &parsed.base_source_digest, &source_digest)) return error.InvalidSave;
        const base = hq_roster.roster.Roster{
            .snapshot = parsed.snapshot,
            .states = parsed.states,
            .noncombatants = parsed.noncombatants,
            .source_digest = hq_roster.source.digest(roster_source),
            .revision = parsed.revision,
            .last_receipt = parsed.last_receipt,
        };
        var result = Ledger{ .base = base, .progress = parsed.progress, .source_digest = digestAsset(roster_asset) };
        try result.validate(roster_asset, roster_source, bindings);
        return result;
    }

    pub fn validate(self: *Ledger, roster_asset: catalogue.Asset, roster_source: hq_roster.source.Packet, bindings: Bindings) !void {
        try self.base.validate(roster_source);
        try bindings.validate();
        if (!std.mem.eql(u8, &self.source_digest, &digestAsset(roster_asset))) return error.SourceDigestMismatch;
        var ended = false;
        var count: usize = 0;
        for (self.base.snapshot.members, 0..) |maybe, i| {
            if (maybe) |member| {
                if (ended) return error.InvalidRoster;
                const profile = catalogue.profile(roster_asset, member.member.id) orelse return error.UnknownProfile;
                const source_profile = roster_source.profile(member.member.id) orelse return error.UnknownProfile;
                if (!std.mem.eql(u8, profile.name, member.member.name) or
                    profile.source_character_id != source_profile.source_character_id or
                    profile.identity != source_profile.identity) return error.ProfileMismatch;
                const progress = self.progress[i] orelse return error.MissingProgress;
                if (!std.mem.eql(u8, progress.profile, member.member.id)) return error.AliasedMember;
                if (progress.source_character_id != profile.source_character_id) return error.ProfileMismatch;
                const sidecar = self.base.snapshot.extras[i] orelse return error.MissingCharacterExtra;
                if (!std.mem.eql(u8, sidecar.member_id, member.member.id)) return error.AliasedSidecar;
                try validateMember(roster_asset, bindings, profile, member, sidecar, progress);
                count += 1;
            } else {
                ended = true;
                if (self.progress[i] != null) return error.InvalidProgress;
            }
        }
        if (count == 0) return error.EmptyRoster;
        for (self.base.snapshot.active) |maybe| if (maybe) |id| {
            const index = self.find(id) orelse return error.UnknownMember;
            if (!self.base.snapshot.eligible[index]) return error.MemberIneligible;
        };
        for (self.base.snapshot.followers) |maybe| if (maybe) |id| {
            if (!self.base.isActive(id) and catalogue.guest(roster_asset, id) == null) return error.InvalidSceneMember;
        };
    }

    fn bump(self: *Ledger) void {
        self.base.revision += 1;
        self.base.snapshot.baseline_revision = self.base.revision;
        self.base.last_receipt = self.base.revision;
    }

    fn awardExpInner(self: *Ledger, roster_asset: catalogue.Asset, id: []const u8, amount: u32, rolls: []const u16) !void {
        if (amount == 0) return;
        const slot = self.find(id) orelse return error.UnknownMember;
        if (!self.base.isActive(id)) return error.MemberNotActive;
        const profile = catalogue.profile(roster_asset, id) orelse return error.UnknownProfile;
        const record = &self.base.snapshot.members[slot].?;
        var total: u32 = @as(u32, record.experience) + amount;
        var cursor: usize = 0;
        while (total >= @as(u32, roster_asset.rules.exp_per_level)) {
            if (record.level >= roster_asset.rules.max_level) return error.LevelCapped;
            if (cursor + 7 > rolls.len) return error.RollsExhausted;
            total -= @as(u32, roster_asset.rules.exp_per_level);
            record.level += 1;
            const power = profile.seed.weapon.powers[@as(usize, record.weapon_level - 1)];
            var attack_base = std.math.sub(u16, record.stats.attack, power) catch return error.InvalidStats;
            for (0..6) |i| {
                const index = statIndex(roster_asset, record.level, profile.growth[i]);
                const gain: u16 = @intCast((roster_asset.rules.stat_table[index] + (rolls[cursor] & 0xFF)) >> 8);
                cursor += 1;
                switch (i) {
                    0 => attack_base = clampStat(attack_base, gain),
                    1 => record.stats.skill = clampStat(record.stats.skill, gain),
                    2 => record.stats.defense = clampStat(record.stats.defense, gain),
                    3 => record.stats.speed = clampStat(record.stats.speed, gain),
                    4 => record.stats.magic = clampStat(record.stats.magic, gain),
                    5 => record.stats.luck = clampStat(record.stats.luck, gain),
                    else => unreachable,
                }
            }
            record.stats.attack = std.math.add(u16, attack_base, power) catch return error.StatOverflow;
            const hp_gain: u16 = @intCast((roster_asset.rules.hp_table[hpIndex(roster_asset, record.level, profile.growth[0])] + (rolls[cursor] & 0x1FF)) >> 8);
            cursor += 1;
            record.member.max_hp = std.math.add(u16, record.member.max_hp, hp_gain) catch return error.HpOverflow;
            record.member.hp = std.math.add(u16, record.member.hp, hp_gain) catch return error.HpOverflow;
            record.member.max_rune_charges = catalogue.magicCapacity(roster_asset, record.stats.magic);
        }
        record.experience = total;
    }

    fn raiseWeaponInner(self: *Ledger, roster_asset: catalogue.Asset, id: []const u8) !void {
        const slot = self.find(id) orelse return error.UnknownMember;
        if (!self.base.isActive(id)) return error.MemberNotActive;
        const profile = catalogue.profile(roster_asset, id) orelse return error.UnknownProfile;
        const record = &self.base.snapshot.members[slot].?;
        if (record.weapon_level >= roster_asset.rules.weapon_max_level) return error.WeaponMaxed;
        const old_power = profile.seed.weapon.powers[@as(usize, record.weapon_level - 1)];
        const base_attack = std.math.sub(u16, record.stats.attack, old_power) catch return error.InvalidStats;
        record.weapon_level += 1;
        const new_power = profile.seed.weapon.powers[@as(usize, record.weapon_level - 1)];
        record.stats.attack = std.math.add(u16, base_attack, new_power) catch return error.StatOverflow;
    }

    fn applyWeaponPieceInner(self: *Ledger, roster_asset: catalogue.Asset, id: []const u8, piece: WeaponPiece, replace: bool) !void {
        _ = roster_asset;
        const slot = self.find(id) orelse return error.UnknownMember;
        if (!self.base.isActive(id)) return error.MemberNotActive;
        const sidecar = &self.base.snapshot.extras[slot].?;
        const index: usize = @backingInt(piece);
        const target = std.meta.stringToEnum(Element, @tagName(piece)) orelse return error.InvalidWeapon;
        if (sidecar.weapon_element != .none and sidecar.weapon_element != target and !replace) return error.ReplacementConfirmationRequired;
        if ((sidecar.weapon_element == .none or sidecar.weapon_element == target) and sidecar.weapon_fragments[index] >= 9) return error.WeaponPieceLimit;
        for (&sidecar.weapon_fragments, 0..) |*count, i| if (i != index) {
            count.* = 0;
        };
        sidecar.weapon_fragments[index] +%= 1;
        sidecar.weapon_element = target;
    }

    fn equipInner(self: *Ledger, roster_asset: catalogue.Asset, bindings: Bindings, id: []const u8, slot: battle.systems.EquipmentSlot, item_id: []const u8) !void {
        const index = self.find(id) orelse return error.UnknownMember;
        if (!self.base.isActive(id)) return error.MemberNotActive;
        const record = catalogue.equipment(roster_asset, item_id) orelse return error.UnknownResource;
        if (!std.mem.eql(u8, record.class, slotClass(slot))) return error.SlotMismatch;
        if (!catalogue.allows(roster_asset, id, item_id)) return error.EquipmentNotAllowed;
        const equipment_index = bindings.equipmentIndex(item_id) orelse return error.UnknownResource;
        const member_record = &self.base.snapshot.members[index].?;
        const sidecar = &self.base.snapshot.extras[index].?;
        if (sidecar.locked_equipment[slotIndex(slot)] and member_record.loadout.get(slot) != equipment_index) return error.EquipmentLocked;
        if (!inventoryHas(member_record.*, item_id)) return error.ItemNotOwned;
        member_record.loadout.set(slot, equipment_index);
    }

    fn unequipInner(self: *Ledger, roster_asset: catalogue.Asset, id: []const u8, slot: battle.systems.EquipmentSlot) !void {
        _ = roster_asset;
        const index = self.find(id) orelse return error.UnknownMember;
        if (!self.base.isActive(id)) return error.MemberNotActive;
        const member_record = &self.base.snapshot.members[index].?;
        const sidecar = &self.base.snapshot.extras[index].?;
        if (sidecar.locked_equipment[slotIndex(slot)]) return error.EquipmentLocked;
        member_record.loadout.set(slot, null);
    }

    fn attachRuneInner(self: *Ledger, roster_asset: catalogue.Asset, bindings: Bindings, id: []const u8, rune_id: []const u8) !void {
        const index = self.find(id) orelse return error.UnknownMember;
        if (!self.base.isActive(id)) return error.MemberNotActive;
        const progress = &self.progress[index].?;
        if (progress.rune_locked) return error.RuneLocked;
        _ = catalogue.rune(roster_asset, rune_id) orelse return error.UnknownResource;
        const rune_index = bindings.runeIndex(rune_id) orelse return error.UnknownResource;
        self.base.snapshot.members[index].?.rune = rune_index;
        progress.rune_id = rune_id;
    }

    fn detachRuneInner(self: *Ledger, roster_asset: catalogue.Asset, id: []const u8) !void {
        _ = roster_asset;
        const index = self.find(id) orelse return error.UnknownMember;
        if (!self.base.isActive(id)) return error.MemberNotActive;
        const progress = &self.progress[index].?;
        if (progress.rune_locked) return error.RuneLocked;
        self.base.snapshot.members[index].?.rune = null;
        progress.rune_id = null;
    }

    fn restInner(self: *Ledger, roster_asset: catalogue.Asset, id: []const u8) !void {
        _ = roster_asset;
        const index = self.find(id) orelse return error.UnknownMember;
        if (!self.base.isActive(id)) return error.MemberNotActive;
        const member = &self.base.snapshot.members[index].?.member;
        member.hp = member.max_hp;
        member.status = .healthy;
        member.balloons = 0;
    }
};

fn loadMember(base: *hq_roster.roster.Roster, roster_source: hq_roster.source.Packet, id: []const u8, source_text: []const u8) !void {
    const index = base.memberIndex(id) orelse return error.UnknownMember;
    if (base.states[index].presence == .temporary_absent) {
        return base.rejoin(roster_source, id, false, source_text);
    }
    return base.loadJoin(roster_source, id, false, source_text);
}

fn seedProgress(roster_asset: catalogue.Asset, profile: *const catalogue.Profile) !Progress {
    var retained: [9]?RetainedItem = @splat(null);
    for (profile.seed.inventory, 0..) |item, i| {
        if (std.meta.stringToEnum(field.items.Id, item.id) != null) continue;
        _ = catalogue.unmapped(roster_asset, item.id) orelse return error.UnknownResource;
        retained[i] = .{ .id = item.id, .uses = item.uses, .identified = item.identified };
    }
    return .{
        .profile = profile.id,
        .source_character_id = profile.source_character_id,
        .rune_id = if (profile.seed.rune) |rune_seed| rune_seed.id else null,
        .rune_locked = if (profile.seed.rune) |rune_seed| rune_seed.locked else false,
        .retained = retained,
    };
}

fn seedExtra(roster_asset: catalogue.Asset, profile: *const catalogue.Profile) !party.CharacterExtra {
    const element = std.meta.stringToEnum(Element, profile.seed.weapon_element) orelse return error.InvalidSeed;
    var sidecar: party.CharacterExtra = .{
        .member_id = profile.id,
        .weapon_element = element,
        .weapon_fragments = profile.seed.weapon_fragments,
        .locked_equipment = @splat(false),
    };
    for (profile.seed.inventory) |item| {
        const slot_name = item.slot orelse {
            if (item.locked) return error.InvalidSeed;
            continue;
        };
        const slot = parseSlot(slot_name) orelse return error.InvalidSeed;
        const record = catalogue.equipment(roster_asset, item.id) orelse return error.UnknownResource;
        if (!std.mem.eql(u8, record.class, slotClass(slot))) return error.SlotMismatch;
        sidecar.locked_equipment[slotIndex(slot)] = item.locked;
    }
    return sidecar;
}

// Source quantities on automatic/equipment items are not manual charges.
fn seedUses(id: field.items.Id, quantity: u16) u16 {
    return if (id.maxUses() == 0) 0 else if (quantity == 0) id.maxUses() else quantity;
}

fn seedMember(roster_asset: catalogue.Asset, bindings: Bindings, profile: *const catalogue.Profile) !battle.OwnedMember {
    if (profile.seed.inventory.len > 9) return error.InvalidSeed;
    const level = profile.seed.level;
    if (level == 0 or level > roster_asset.rules.max_level) return error.InvalidSeed;
    const weapon_level = profile.seed.weapon.level;
    if (weapon_level == 0 or weapon_level > roster_asset.rules.weapon_max_level) return error.InvalidSeed;
    const attack = std.math.add(u16, profile.seed.stats[0], profile.seed.weapon.powers[@as(usize, weapon_level - 1)]) catch return error.InvalidSeed;
    var owned: battle.OwnedMember = .{
        .member = .{
            .id = profile.id,
            .name = profile.name,
            .hp = profile.seed.hp,
            .max_hp = profile.seed.max_hp,
            .status = .healthy,
            .rune_charges = profile.seed.charges,
            .max_rune_charges = catalogue.magicCapacity(roster_asset, profile.seed.stats[4]),
            .inventory = .{},
        },
        .level = level,
        .experience = profile.seed.experience,
        .stats = .{
            .attack = attack,
            .skill = profile.seed.stats[1],
            .defense = profile.seed.stats[2],
            .speed = profile.seed.stats[3],
            .magic = profile.seed.stats[4],
            .luck = profile.seed.stats[5],
        },
        .weapon_level = weapon_level,
        .loadout = .{},
        .rune = null,
    };
    for (profile.seed.inventory, 0..) |item, i| {
        const item_id = std.meta.stringToEnum(field.items.Id, item.id) orelse {
            _ = catalogue.unmapped(roster_asset, item.id) orelse return error.UnknownResource;
            continue;
        };
        const uses = seedUses(item_id, item.uses);
        if (uses > item_id.maxUses()) return error.InvalidSeed;
        owned.member.inventory.slots[i] = .{ .id = item_id, .uses = uses, .identified = item.identified };
        const slot_name = item.slot orelse {
            if (item.locked) return error.InvalidSeed;
            continue;
        };
        const slot = parseSlot(slot_name) orelse return error.InvalidSeed;
        const record = catalogue.equipment(roster_asset, item.id) orelse return error.UnknownResource;
        if (!std.mem.eql(u8, record.class, slotClass(slot))) return error.SlotMismatch;
        const equipment_index = bindings.equipmentIndex(item.id) orelse return error.UnknownResource;
        if (owned.loadout.get(slot) != null) return error.DuplicateEquipment;
        owned.loadout.set(slot, equipment_index);
    }
    if (profile.seed.rune) |rune_seed| {
        const rune_index = bindings.runeIndex(rune_seed.id) orelse return error.UnknownResource;
        _ = catalogue.rune(roster_asset, rune_seed.id) orelse return error.UnknownResource;
        owned.rune = rune_index;
    }
    return owned;
}

fn validateMember(roster_asset: catalogue.Asset, bindings: Bindings, profile: *const catalogue.Profile, owned: battle.OwnedMember, sidecar: party.CharacterExtra, progress: Progress) !void {
    var members = [_]field.game_state.Member{owned.member};
    try (field.game_state.Progress{ .money = 0, .party = &members }).validate();
    if (owned.level == 0 or owned.level > roster_asset.rules.max_level or owned.experience >= 1000) return error.InvalidMember;
    if (owned.weapon_level == 0 or owned.weapon_level > roster_asset.rules.weapon_max_level) return error.InvalidWeapon;
    if (owned.member.max_hp > 9999) return error.InvalidMember;
    for ([_]u16{ owned.stats.attack, owned.stats.defense, owned.stats.skill, owned.stats.speed, owned.stats.magic, owned.stats.luck }) |value| {
        if (value > 9999) return error.InvalidMember;
    }
    const power = profile.seed.weapon.powers[@as(usize, owned.weapon_level - 1)];
    const base_attack = std.math.sub(u16, owned.stats.attack, power) catch return error.InvalidStats;
    if (base_attack > 9999) return error.InvalidStats;
    const capacity = catalogue.magicCapacity(roster_asset, owned.stats.magic);
    if (!std.mem.eql(u16, &capacity, &owned.member.max_rune_charges)) return error.InvalidMagicCapacity;
    for (owned.member.rune_charges, capacity) |charge, maximum| if (charge > maximum) return error.InvalidMagicCapacity;
    const slots = [_]battle.systems.EquipmentSlot{ .head, .body, .shield, .accessory_one, .accessory_two };
    for (slots) |slot| if (owned.loadout.get(slot)) |equipment_index| {
        if (equipment_index >= bindings.equipment.len) return error.UnknownResource;
        const item_id = bindings.equipment[equipment_index];
        const record = catalogue.equipment(roster_asset, item_id) orelse return error.UnknownResource;
        if (!std.mem.eql(u8, record.class, slotClass(slot))) return error.SlotMismatch;
        if (!catalogue.allows(roster_asset, profile.id, item_id) and !seedEquipped(profile, item_id, slot)) return error.EquipmentNotAllowed;
        var worn: usize = 0;
        for (slots) |other| if (owned.loadout.get(other)) |index| {
            if (index == equipment_index) worn += 1;
        };
        var stacks: usize = 0;
        for (owned.member.inventory.slots) |maybe| if (maybe) |stack| {
            if (std.mem.eql(u8, @tagName(stack.id), item_id)) stacks += 1;
        };
        if (worn > stacks) return error.EquipmentNotOwned;
    };
    for (profile.seed.inventory, 0..) |item, i| {
        if (std.meta.stringToEnum(field.items.Id, item.id)) |item_id| {
            const stack = owned.member.inventory.slots[i] orelse return error.ItemNotOwned;
            if (stack.id != item_id or stack.uses != seedUses(item_id, item.uses) or stack.identified != item.identified) return error.ItemMismatch;
            if (progress.retained[i] != null) return error.ItemMismatch;
        } else {
            _ = catalogue.unmapped(roster_asset, item.id) orelse return error.UnknownResource;
            const retained = progress.retained[i] orelse return error.ItemNotOwned;
            if (!std.mem.eql(u8, retained.id, item.id) or retained.uses != item.uses or retained.identified != item.identified) return error.ItemMismatch;
            if (owned.member.inventory.slots[i] != null) return error.ItemMismatch;
        }
    }
    for (profile.seed.inventory.len..owned.member.inventory.slots.len) |i| {
        if (owned.member.inventory.slots[i] != null) return error.ItemMismatch;
        if (progress.retained[i] != null) return error.ItemMismatch;
    }
    if (progress.rune_id) |rune_id| {
        const rune_index = owned.rune orelse return error.InvalidRune;
        if (rune_index >= bindings.runes.len or !std.mem.eql(u8, bindings.runes[rune_index], rune_id)) return error.InvalidRune;
        _ = catalogue.rune(roster_asset, rune_id) orelse return error.UnknownResource;
    } else if (owned.rune != null) return error.InvalidRune;
    const seed_locked = if (profile.seed.rune) |rune_seed| rune_seed.locked else false;
    if (progress.rune_locked != seed_locked) return error.InvalidRune;
    if (progress.rune_locked) {
        const seed = profile.seed.rune orelse return error.InvalidRune;
        if (progress.rune_id == null or !std.mem.eql(u8, progress.rune_id.?, seed.id)) return error.RuneLocked;
    }
    if (sidecar.weapon_element == .none) {
        for (sidecar.weapon_fragments) |count| if (count != 0) return error.InvalidWeapon;
    }
    if (sidecar.weapon_element != .none) {
        const raw = @backingInt(sidecar.weapon_element);
        if (raw == 0) return error.InvalidWeapon;
        const index: usize = raw - 1;
        if (index >= sidecar.weapon_fragments.len) return error.InvalidWeapon;
    }
}

fn seedEquipped(profile: *const catalogue.Profile, item_id: []const u8, slot: battle.systems.EquipmentSlot) bool {
    for (profile.seed.inventory) |item| {
        const name = item.slot orelse continue;
        if (std.mem.eql(u8, name, @tagName(slot)) and std.mem.eql(u8, item.id, item_id)) return true;
    }
    return false;
}

fn inventoryHas(owned: battle.OwnedMember, item_id: []const u8) bool {
    for (owned.member.inventory.slots) |maybe| if (maybe) |stack| {
        if (std.mem.eql(u8, @tagName(stack.id), item_id)) return true;
    };
    return false;
}

fn parseSlot(name: []const u8) ?battle.systems.EquipmentSlot {
    if (std.mem.eql(u8, name, "head")) return .head;
    if (std.mem.eql(u8, name, "body")) return .body;
    if (std.mem.eql(u8, name, "shield")) return .shield;
    if (std.mem.eql(u8, name, "accessory_one")) return .accessory_one;
    if (std.mem.eql(u8, name, "accessory_two")) return .accessory_two;
    return null;
}
fn slotClass(slot: battle.systems.EquipmentSlot) []const u8 {
    return switch (slot) {
        .head => "head",
        .body => "body",
        .shield => "shield",
        .accessory_one, .accessory_two => "accessory",
    };
}
fn slotIndex(slot: battle.systems.EquipmentSlot) usize {
    return switch (slot) {
        .head => 0,
        .body => 1,
        .shield => 2,
        .accessory_one => 3,
        .accessory_two => 4,
    };
}
fn clampStat(current: u16, gain: u16) u16 {
    const sum = current +| gain;
    return if (sum >= 0x100) 0xFF else sum;
}
fn statIndex(roster_asset: catalogue.Asset, level: u8, rate: u8) usize {
    const bands = roster_asset.rules.stat_tiers[@as(usize, rate)];
    const tier: usize = if (level < bands[0]) 0 else if (level < bands[1]) 1 else 2;
    return @as(usize, rate) * 3 + tier;
}
fn hpIndex(roster_asset: catalogue.Asset, level: u8, growth: u8) usize {
    const bands = roster_asset.rules.hp_tiers;
    const tier: usize = if (level < bands[0]) 0 else if (level < bands[1]) 1 else 2;
    return @as(usize, growth) * 3 + tier;
}
fn digestAsset(roster_asset: catalogue.Asset) [32]u8 {
    var out: [32]u8 = undefined;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(roster_asset.content_sha256);
    hash.final(&out);
    return out;
}
