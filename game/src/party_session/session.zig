//! Private preparation state. All identities and catalogue indices are borrowed from
//! the caller's character rules. The host publishes changes after replay.
const std = @import("std");
const systems = @import("battle_rules");
const character = @import("field").game_state;
const field = @import("field");
const recruitment = @import("recruitment");
const items = field.items;
const Storage = field.game_state.storage.Storage;
pub const view = @import("view.zig");
pub const catalogue = @import("catalogue.zig");
pub const story = @import("story.zig");
pub const selector = @import("selector.zig");

pub const max_owned = 78;
pub const version: u8 = 1;

pub const CharacterExtra = struct {
    member_id: []const u8,
    weapon_element: enum { none, fire, water, wind, thunder, earth } = .none,
    // Fire, water, wind, thunder, earth, in source order.
    weapon_fragments: [5]u8 = @splat(0),
    locked_equipment: [5]bool = @splat(false),
};
pub fn attachWeaponPiece(rules: character.CharacterRules, owner: *character.Character, slot: usize, target: *CharacterExtra, replace: bool) !void {
    if (slot >= owner.inventory.count()) return error.InvalidItem;
    const element: @FieldType(CharacterExtra, "weapon_element") = switch (owner.inventory.slots[slot].?.id) {
        .fire_rune_piece => .fire,
        .water_rune_piece => .water,
        .wind_rune_piece => .wind,
        .thunder_rune_piece => .thunder,
        .earth_rune_piece => .earth,
        else => return error.UnsupportedWeaponPiece,
    };
    const index: usize = @backingInt(element) - 1;
    if (target.weapon_element != .none and target.weapon_element != element and !replace) return error.ReplacementConfirmationRequired;
    const count = target.weapon_fragments[index];
    if ((target.weapon_element == .none or target.weapon_element == element) and count >= 9) return error.WeaponPieceLimit;
    var next = owner.*;
    next.inventory.remove(slot);
    try rules.validate(next);
    owner.inventory = next.inventory;
    target.weapon_element = element;
    target.weapon_fragments = @splat(0);
    target.weapon_fragments[index] = count +% 1;
}

pub const Snapshot = struct {
    schema: u8 = version,
    entry_id: []const u8,
    content_id: []const u8,
    receipt: []const u8,
    baseline_revision: u64,
    members: [max_owned]?character.Character = @splat(null),
    extras: [max_owned]?CharacterExtra = @splat(null),
    eligible: [max_owned]bool = @splat(false),
    active: [6]?[]const u8 = @splat(null),
    forced: [6]?[]const u8 = @splat(null),
    followers: [6]?[]const u8 = @splat(null),
    scene_order: [6]?[]const u8 = @splat(null),
    storage: Storage = .{},
    shared: [7]?[]const u8 = @splat(null),
};

pub const SharedOperation = struct {
    id: []const u8,
    source: []const u8,
    item: []const u8,
    kind: enum { acquire, consume },
    unique: bool = false,
};
pub const SceneOperation = struct {
    id: []const u8,
    source: []const u8,
    scope: enum { durable, area_transient },
    active: [6]?[]const u8,
    forced: [6]?[]const u8 = @splat(null),
    followers: ?[6]?[]const u8 = null,
    eligible: [max_owned]bool = @splat(false),
};
pub const MaasEntry = struct { definition: recruitment.Definition, draws: []const u15, tier: u8, already_recruited: bool, blocked: bool, eligible: bool };
pub const Sources = struct { shared: []const SharedOperation = &.{}, scenes: []const SceneOperation = &.{}, maas: ?MaasEntry = null };
pub const Command = union(enum) {
    recruit_maas: void,
    scene: []const u8,
    weapon_piece: struct { owner: []const u8, slot: usize, target: []const u8, replace: bool = false },
    shared: []const u8,
    select: [6]?[]const u8,
    equip: struct { member: []const u8, slot: systems.EquipmentSlot, equipment: ?usize },
    give: struct { from: []const u8, slot: usize, to: []const u8 },
    swap: struct { first: []const u8, first_slot: usize, second: []const u8, second_slot: usize },
    discard: struct { member: []const u8, slot: usize },
    deposit: struct { member: []const u8, slot: usize },
    withdraw: struct { member: []const u8, item: items.Id },
    attach_rune: struct { member: []const u8, owner: []const u8, slot: usize },
    detach_rune: struct { member: []const u8 },
    transfer_rune: struct { from: []const u8, to: []const u8 },
};
pub const max_commands = 128;
pub const Result = struct {
    schema: u8 = version,
    entry_id: []const u8,
    content_id: []const u8,
    receipt: []const u8,
    baseline_revision: u64,
    commands: [max_commands]?Command = @splat(null),
};
pub const RosterTransaction = Result;
pub const InventoryTransaction = Result;

pub fn weaponAugment(extra: CharacterExtra) systems.WeaponAugment {
    const rune: systems.WeaponRune = @fromBackingInt(@intCast(@backingInt(extra.weapon_element)));
    return .{ .rune = rune, .fragments = if (rune == .none) 0 else extra.weapon_fragments[@backingInt(rune) - 1] };
}

pub fn weaponAugments(rules: character.CharacterRules, active_members: []const character.Character, snapshot: Snapshot) ![6]systems.WeaponAugment {
    _ = try Session.init(rules, snapshot, .{});
    var result: [6]systems.WeaponAugment = @splat(.{});
    for (snapshot.active, 0..) |active, slot| {
        if (slot >= active_members.len) {
            if (active != null) return error.WorldPartyMismatch;
            continue;
        }
        const id = active orelse return error.WorldPartyMismatch;
        if (!eq(id, active_members[slot].id)) return error.WorldPartyMismatch;
        const index = for (snapshot.members, 0..) |member, i| {
            if (member != null and eq(member.?.id, id)) break i;
        } else return error.UnknownMember;
        result[slot] = weaponAugment(snapshot.extras[index].?);
    }
    return result;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn contains(ids: [6]?[]const u8, id: []const u8) bool {
    for (ids) |candidate| if (candidate) |value| {
        if (eq(value, id)) return true;
    };
    return false;
}
fn validateIds(ids: [6]?[]const u8) !usize {
    var count: usize = 0;
    var ended = false;
    for (ids, 0..) |maybe, i| {
        if (maybe) |id| {
            if (ended or id.len == 0) return error.InvalidIdentityList;
            for (ids[0..i]) |prior| if (prior != null and eq(prior.?, id)) return error.DuplicateMember;
            count += 1;
        } else ended = true;
    }
    return count;
}

pub const Session = struct {
    before: Snapshot,
    current: Snapshot,
    rules: character.CharacterRules,
    commands: [max_commands]?Command = @splat(null),
    sources: Sources,

    pub fn init(rules: character.CharacterRules, snapshot: Snapshot, sources: Sources) !Session {
        const self = Session{ .before = snapshot, .current = snapshot, .rules = rules, .sources = sources };
        try self.validate();
        return self;
    }
    fn memberIndex(self: *const Session, id: []const u8) !usize {
        for (self.current.members, 0..) |maybe, i| if (maybe) |member| {
            if (eq(member.id, id)) return i;
        };
        return error.UnknownMember;
    }
    fn activeIndex(self: *const Session, id: []const u8) !usize {
        const i = try self.memberIndex(id);
        if (!contains(self.current.active, id)) return error.MemberNotActive;
        return i;
    }
    pub fn validate(self: *const Session) !void {
        const s = self.current;
        if (self.rules.tables == null) return error.SystemsUnavailable;
        if (s.schema != version or s.entry_id.len == 0 or s.content_id.len == 0 or s.receipt.len == 0) return error.InvalidEntry;
        try s.storage.validate();
        var shared_ended = false;
        for (s.shared) |item| {
            if (item) |id| {
                if (shared_ended or id.len == 0) return error.InvalidSharedItems;
            } else shared_ended = true;
        }
        for (self.sources.shared, 0..) |op, i| {
            if (op.id.len == 0 or op.source.len == 0 or op.item.len == 0) return error.InvalidSharedOperation;
            for (self.sources.shared[0..i]) |previous| if (eq(previous.id, op.id)) return error.InvalidSharedOperation;
        }

        var ended = false;
        for (s.members, 0..) |maybe, i| {
            if (maybe) |member| {
                if (ended) return error.InvalidRoster;
                try self.rules.validate(member);
                const extra = s.extras[i] orelse return error.MissingCharacterExtra;
                if (!eq(extra.member_id, member.id)) return error.InvalidCharacterExtra;
                const slots = [_]systems.EquipmentSlot{ .head, .body, .shield, .accessory_one, .accessory_two };
                for (extra.locked_equipment, slots) |locked, slot| if (locked and member.loadout.get(slot) == null) return error.InvalidCharacterExtra;
                for (s.members[0..i]) |prior| if (prior != null and eq(prior.?.id, member.id)) return error.DuplicateMember;
            } else {
                ended = true;
                if (s.extras[i] != null) return error.InvalidCharacterExtra;
            }
        }
        const count = try validateIds(s.active);
        if (count == 0) return error.InvalidParty;
        _ = try validateIds(s.forced);
        _ = try validateIds(s.followers);
        _ = try validateIds(s.scene_order);
        for (s.active) |maybe| if (maybe) |id| {
            const i = try self.memberIndex(id);
            if (!s.eligible[i]) return error.MemberIneligible;
        };
        for (s.forced) |maybe| if (maybe) |id| {
            _ = try self.memberIndex(id);
            if (!contains(s.active, id)) return error.ForcedMemberMissing;
        };
        // Followers are scene-only identities and never become roster entries here.
    }
    fn select(self: *Session, active: [6]?[]const u8) !void {
        var next = self.*;
        next.current.active = active;
        try next.validate();
        self.* = next;
    }
    fn equip(self: *Session, id: []const u8, slot: systems.EquipmentSlot, equipment: ?usize) !void {
        var next = self.*;
        const i = try next.activeIndex(id);
        const slot_index: usize = switch (slot) {
            .head => 0,
            .body => 1,
            .shield => 2,
            .accessory_one => 3,
            .accessory_two => 4,
        };
        if (next.current.extras[i].?.locked_equipment[slot_index] and next.current.members[i].?.loadout.get(slot) != equipment) return error.EquipmentLocked;
        try next.rules.equipOwned(&next.current.members[i].?, slot, equipment);
        try next.validate();
        self.* = next;
    }
    fn itemEquipped(self: Session, member: character.Character, slot: usize) bool {
        return self.rules.itemEquipped(member, slot);
    }
    fn give(self: *Session, from: []const u8, slot: usize, to: []const u8) !void {
        var next = self.*;
        const a = try next.activeIndex(from);
        const b = try next.activeIndex(to);
        if (a == b) return error.InvalidRecipient;
        const src = &next.current.members[a].?.inventory;
        const dst = &next.current.members[b].?.inventory;
        if (slot >= src.count()) return error.InvalidItem;
        if (next.itemEquipped(next.current.members[a].?, slot)) return error.EquippedItem;
        const n = dst.count();
        if (n == dst.slots.len) return error.InventoryFull;
        dst.slots[n] = src.slots[slot];
        src.remove(slot);
        try next.validate();
        self.* = next;
    }
    fn swapItems(self: *Session, first: []const u8, first_slot: usize, second: []const u8, second_slot: usize) !void {
        var next = self.*;
        const a = try next.activeIndex(first);
        const b = try next.activeIndex(second);
        if (a == b) return error.InvalidRecipient;
        const src = &next.current.members[a].?.inventory;
        const dst = &next.current.members[b].?.inventory;
        if (first_slot >= src.count() or second_slot >= dst.count()) return error.InvalidItem;
        if (next.itemEquipped(next.current.members[a].?, first_slot) or next.itemEquipped(next.current.members[b].?, second_slot)) return error.EquippedItem;
        std.mem.swap(?items.Stack, &src.slots[first_slot], &dst.slots[second_slot]);
        try next.validate();
        self.* = next;
    }
    fn discard(self: *Session, id: []const u8, slot: usize) !void {
        var next = self.*;
        const i = try next.activeIndex(id);
        const bag = &next.current.members[i].?.inventory;
        if (slot >= bag.count()) return error.InvalidItem;
        if (next.itemEquipped(next.current.members[i].?, slot)) return error.EquippedItem;
        bag.remove(slot);
        try next.validate();
        self.* = next;
    }
    fn deposit(self: *Session, id: []const u8, slot: usize) !void {
        var next = self.*;
        const i = try next.activeIndex(id);
        const bag = &next.current.members[i].?.inventory;
        if (slot >= bag.count()) return error.InvalidItem;
        if (next.itemEquipped(next.current.members[i].?, slot)) return error.EquippedItem;
        try next.current.storage.deposit(bag, slot);
        try next.validate();
        self.* = next;
    }
    fn withdraw(self: *Session, id: []const u8, item: items.Id) !void {
        var next = self.*;
        const i = try next.activeIndex(id);
        try next.current.storage.withdraw(&next.current.members[i].?.inventory, item);
        try next.validate();
        self.* = next;
    }
    // The host supplies the source recruitment definition and the exact draws
    // from its own continuing stream; it owns story/RNG publication atomically.
    fn recruitMaas(self: *Session) !void {
        const entry = self.sources.maas orelse return error.RecruitmentUnavailable;
        if (entry.tier < entry.definition.minimum_tier or entry.already_recruited or entry.blocked) return error.RecruitmentUnavailable;
        if (self.memberIndex("maas")) |_| return error.AlreadyOwned else |err| if (err != error.UnknownMember) return err;
        const owned = try recruitment.prepare(entry.definition, self.rules, entry.draws);
        var next = self.*;
        var free: ?usize = null;
        for (next.current.members, 0..) |member, i| if (member == null) {
            free = i;
            break;
        };
        const i = free orelse return error.RosterFull;
        next.current.members[i] = owned;
        next.current.extras[i] = .{ .member_id = owned.id };
        next.current.eligible[i] = entry.eligible;
        try next.validate();
        self.* = next;
    }
    fn weaponPiece(self: *Session, owner: []const u8, slot: usize, target: []const u8, replace: bool) !void {
        const from = try self.activeIndex(owner);
        const to = try self.activeIndex(target);
        try attachWeaponPiece(self.rules, &self.current.members[from].?, slot, &self.current.extras[to].?, replace);
    }
    fn sceneOperation(self: *Session, id: []const u8) !void {
        var match: ?SceneOperation = null;
        for (self.sources.scenes) |op| if (eq(op.id, id)) {
            if (match != null or op.source.len == 0) return error.InvalidSceneOperation;
            match = op;
        };
        const op = match orelse return error.UnknownSceneOperation;
        var next = self.*;
        switch (op.scope) {
            .area_transient => {
                const requested = try validateIds(op.active);
                const active_count = try validateIds(next.current.active);
                if (requested == 0 or requested > active_count) return error.InvalidAreaPartyPrefix;
                const previous = if (next.current.scene_order[0] == null) next.current.active else next.current.scene_order;
                var order = op.active;
                var count = requested;
                for (previous) |maybe| if (maybe) |member_id| {
                    if (contains(order, member_id)) continue;
                    if (count == active_count) break;
                    order[count] = member_id;
                    count += 1;
                };
                if (count != active_count) return error.InvalidAreaPartyPrefix;
                next.current.scene_order = order;
                if (op.followers) |followers| next.current.followers = followers;
            },
            .durable => {
                next.current.active = op.active;
                next.current.forced = op.forced;
                next.current.eligible = op.eligible;
                if (op.followers) |followers| next.current.followers = followers;
                next.current.scene_order = @splat(null);
            },
        }
        try next.validate();
        self.* = next;
    }
    fn sharedOperation(self: *Session, id: []const u8) !void {
        const operation = for (self.sources.shared) |op| {
            if (eq(op.id, id)) break op;
        } else return error.UnknownSharedOperation;
        var next = self.*;
        var found: ?usize = null;
        var empty: ?usize = null;
        for (next.current.shared, 0..) |item, i| {
            if (item) |name| {
                if (found == null and eq(name, operation.item)) found = i;
            } else if (empty == null) {
                empty = i;
            }
        }
        switch (operation.kind) {
            .acquire => {
                if (operation.unique and found != null) return error.AlreadyOwned;
                next.current.shared[empty orelse return error.SharedInventoryFull] = operation.item;
            },
            .consume => {
                const i = found orelse return error.ItemUnavailable;
                std.mem.copyForwards(?[]const u8, next.current.shared[i..6], next.current.shared[i + 1 .. 7]);
                next.current.shared[6] = null;
            },
        }
        try next.validate();
        self.* = next;
    }
    fn runeService(self: *Session, member: []const u8, owner: ?[]const u8, slot: usize) !void {
        var next = self.*;
        const target = try next.activeIndex(member);
        const crystal_owner = if (owner) |id| try next.activeIndex(id) else target;
        try next.rules.checkRuneTarget(next.current.members[target].?);
        if (owner != null) {
            if (next.current.members[target].?.rune != null) return error.RuneOccupied;
            const inventory = &next.current.members[crystal_owner].?.inventory;
            next.current.members[target].?.rune = try next.rules.attachmentRune(member, inventory.*, slot);
            inventory.remove(slot);
        } else {
            try next.rules.detachRune(&next.current.members[target].?);
        }
        try next.validate();
        self.* = next;
    }
    fn transferRune(self: *Session, from: []const u8, to: []const u8) !void {
        if (eq(from, to)) return error.InvalidRecipient;
        var next = self.*;
        const source = try next.activeIndex(from);
        _ = try next.activeIndex(to);
        const appended = next.current.members[source].?.inventory.count();
        try next.runeService(from, null, 0);
        try next.runeService(to, from, appended);
        self.* = next;
    }
    pub fn execute(self: *Session, command: Command) !void {
        var slot: ?usize = null;
        for (self.commands, 0..) |existing, i| if (existing == null) {
            slot = i;
            break;
        };
        const index = slot orelse return error.TransactionFull;
        var next = self.*;
        switch (command) {
            .shared => |id| try next.sharedOperation(id),
            .scene => |id| try next.sceneOperation(id),
            .recruit_maas => try next.recruitMaas(),
            .weapon_piece => |v| try next.weaponPiece(v.owner, v.slot, v.target, v.replace),
            .select => |ids| try next.select(ids),
            .equip => |v| try next.equip(v.member, v.slot, v.equipment),
            .give => |v| try next.give(v.from, v.slot, v.to),
            .swap => |v| try next.swapItems(v.first, v.first_slot, v.second, v.second_slot),
            .discard => |v| try next.discard(v.member, v.slot),
            .deposit => |v| try next.deposit(v.member, v.slot),
            .withdraw => |v| try next.withdraw(v.member, v.item),
            .attach_rune => |v| try next.runeService(v.member, v.owner, v.slot),
            .detach_rune => |v| try next.runeService(v.member, null, 0),
            .transfer_rune => |v| try next.transferRune(v.from, v.to),
        }
        next.commands[index] = command;
        self.* = next;
    }
    pub fn result(self: Session) Result {
        return .{ .entry_id = self.before.entry_id, .content_id = self.before.content_id, .receipt = self.before.receipt, .baseline_revision = self.before.baseline_revision, .commands = self.commands };
    }
};

/// Replays a bounded command journal against caller-owned canonical state.
/// The host must compare its revision and atomically persist the receipt and
/// replayed state. Never accept a caller-provided after-state as authority.
pub fn replay(rules: character.CharacterRules, baseline: Snapshot, sources: Sources, transaction: Result) !Session {
    if (transaction.schema != version or !eq(baseline.entry_id, transaction.entry_id) or
        !eq(baseline.content_id, transaction.content_id) or
        !eq(baseline.receipt, transaction.receipt) or
        baseline.baseline_revision != transaction.baseline_revision) return error.StaleTransaction;
    var result = try Session.init(rules, baseline, sources);
    var ended = false;
    var applied: usize = 0;
    for (transaction.commands) |maybe| {
        if (maybe) |command| {
            if (ended) return error.InvalidJournal;
            try result.execute(command);
            applied += 1;
        } else ended = true;
    }
    if (applied == 0) return error.EmptyTransaction;
    return result;
}

pub fn decodeResult(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Result) {
    if (bytes.len > 256 * 1024) return error.SaveTooLarge;
    return std.json.parseFromSlice(Result, allocator, bytes, .{ .allocate = .alloc_always });
}
