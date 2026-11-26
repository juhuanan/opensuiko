const std = @import("std");
const character_rules = @import("battle_rules");
pub const event_runtime = @import("event_runtime");
pub const items = @import("items.zig");
pub const storage = @import("storage.zig");

pub const Status = enum { healthy, poisoned, unconscious };
pub const max_money: u32 = 999999;
pub const StoryFlag = enum { village_south_exit_reached, heard_forest_warning, forest_elf_seen, forest_entered, forest_battle_one_won, forest_battle_two_won, forest_battle_three_won, forest_treasure_needle, forest_treasure_water, forest_returned, kobold_world_exit_reached, maas_recruited, maas_recruitment_blocked, vaa_dungeon_rumor, vaa_dungeon_greeting, world_patrol_won };
pub const Story = struct {
    scenario: ?event_runtime.StoryState = null,
    recruitment_tier: u8 = 0,
    maas_recruited: bool = false,
    maas_recruitment_blocked: bool = false,
    castle_name: [8]u8 = @splat(0),
    village_south_exit_reached: bool,
    heard_forest_warning: bool = false,
    forest_elf_seen: bool = false,
    forest_entered: bool = false,
    forest_battle_one_won: bool = false,
    forest_battle_two_won: bool = false,
    forest_battle_three_won: bool = false,
    forest_treasure_needle: bool = false,
    forest_treasure_water: bool = false,
    forest_returned: bool = false,
    kobold_world_exit_reached: bool = false,
    vaa_dungeon_rumor: bool = false,
    vaa_dungeon_greeting: bool = false,
    world_patrol_won: bool = false,
    pub const initial: Story = .{ .village_south_exit_reached = false };
    pub fn jsonStringify(self: Story, writer: anytype) !void {
        try writer.beginObject();
        inline for (comptime std.meta.fieldNames(Story)) |name| {
            if (comptime std.mem.eql(u8, name, "scenario")) {
                if (self.scenario) |value| {
                    try writer.objectField(name);
                    try writer.write(value);
                }
            } else {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
    pub fn castleName(self: *const Story) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.castle_name, 0) orelse self.castle_name.len;
        return self.castle_name[0..end];
    }
    pub fn has(self: Story, flag: StoryFlag) bool {
        return switch (flag) {
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }
    pub fn complete(self: *Story, flag: StoryFlag) void {
        switch (flag) {
            inline else => |tag| @field(self, @tagName(tag)) = true,
        }
    }
};
pub const Stats = struct {
    attack: u16,
    defense: u16,
    skill: u16,
    speed: u16,
    magic: u16 = 0,
    luck: u16 = 0,
};

pub const Character = struct {
    id: []const u8,
    name: []const u8,
    hp: u16,
    max_hp: u16,
    status: Status,
    balloons: u8 = 0,
    // Numeric arrays stay readable in JSON instead of becoming byte strings.
    rune_charges: [4]u16,
    max_rune_charges: [4]u16,
    inventory: items.Inventory = .{},
    level: u8 = 1,
    experience: u32 = 0,
    base_stats: Stats = .{ .attack = 0, .defense = 0, .skill = 0, .speed = 0 },
    weapon_level: u8 = 1,
    loadout: character_rules.Loadout = .{},
    rune: ?usize = null,
    weapon_augment: character_rules.WeaponAugment = .{},

    pub fn runeCapacity(self: *const Character, rules: character_rules.Systems) [4]u16 {
        var equipment_magic: i16 = 0;
        for (std.enums.values(character_rules.EquipmentSlot)) |slot| {
            if (self.loadout.get(slot)) |id| equipment_magic += rules.equipment[id].bonuses[4];
        }
        const magic: u16 = @intCast(std.math.clamp(@as(i32, self.base_stats.magic) + equipment_magic, 0, 9999));
        return rules.magicCapacity(magic);
    }

    pub fn refreshRuneCapacity(self: *Character, rules: character_rules.Systems) void {
        self.max_rune_charges = self.runeCapacity(rules);
        for (&self.rune_charges, self.max_rune_charges) |*current, cap| current.* = @min(current.*, cap);
    }

    pub fn refillRuneCharges(self: *Character, rules: character_rules.Systems) void {
        self.max_rune_charges = self.runeCapacity(rules);
        self.rune_charges = self.max_rune_charges;
    }

    pub fn levelUp(self: *Character, rules: character_rules.Systems, growth: [6]u4, rolls: [7]u15) void {
        if (self.level == 99) return;
        self.level += 1;
        const stats = &self.base_stats;
        const columns = [_]*u16{ &stats.attack, &stats.skill, &stats.defense, &stats.speed, &stats.magic, &stats.luck };
        for (columns, growth, 0..) |column, rate, i| {
            const gain = (rules.stat_growth[character_rules.statIndex(self.level, rate)] + (rolls[i] & 255)) >> 8;
            column.* = @intCast(@min(255, column.* + gain));
        }
        const band: usize = if (self.level < 20) 0 else if (self.level < 60) 1 else 2;
        const hp_gain = (rules.hp_growth[@as(usize, growth[0]) * 3 + band] + (rolls[6] & 511)) >> 8;
        self.max_hp = @intCast(@min(9999, @as(u32, self.max_hp) + hp_gain));
        self.hp = @intCast(@min(self.max_hp, @as(u32, self.hp) + hp_gain));
        self.refreshRuneCapacity(rules);
    }

    pub fn record(self: Character) CharacterRecord {
        return .{
            .id = self.id,
            .name = self.name,
            .hp = self.hp,
            .max_hp = self.max_hp,
            .status = self.status,
            .balloons = self.balloons,
            .rune_charges = self.rune_charges,
            .max_rune_charges = self.max_rune_charges,
            .inventory = self.inventory,
        };
    }
};

pub const Member = Character;

pub const OwnedMemberRecord = struct {
    member: CharacterRecord,
    level: u8,
    experience: u32,
    stats: Stats,
    weapon_level: u8,
    loadout: character_rules.Loadout,
    rune: ?usize,

    pub fn fromCharacter(value: Member) OwnedMemberRecord {
        return .{
            .member = value.record(),
            .level = value.level,
            .experience = value.experience,
            .stats = value.base_stats,
            .weapon_level = value.weapon_level,
            .loadout = value.loadout,
            .rune = value.rune,
        };
    }

    pub fn character(self: OwnedMemberRecord) Member {
        var value = self.member.character();
        value.level = self.level;
        value.experience = self.experience;
        value.base_stats = self.stats;
        value.weapon_level = self.weapon_level;
        value.loadout = self.loadout;
        value.rune = self.rune;
        return value;
    }
};

pub const WeaponRange = enum {
    short,
    medium,
    long,
    pub fn label(self: WeaponRange) []const u8 {
        return switch (self) {
            .short => "Short",
            .medium => "Medium",
            .long => "Long",
        };
    }
    pub fn reaches(self: WeaponRange, from: Row, target: Row) bool {
        return switch (self) {
            .short => from == .front and target == .front,
            .medium => target == .front,
            .long => true,
        };
    }
};

pub const Row = enum {
    front,
    back,
    pub fn label(self: Row) []const u8 {
        return if (self == .front) "Front" else "Back";
    }
};

// Member fields in the existing opening packet and save formats.
pub const CharacterRecord = struct {
    id: []const u8,
    name: []const u8,
    hp: u16,
    max_hp: u16,
    status: Status,
    balloons: u8 = 0,
    // Numeric arrays stay readable in JSON instead of becoming byte strings.
    rune_charges: [4]u16,
    max_rune_charges: [4]u16,
    inventory: items.Inventory = .{},

    pub fn character(self: CharacterRecord) Character {
        return .{
            .id = self.id,
            .name = self.name,
            .hp = self.hp,
            .max_hp = self.max_hp,
            .status = self.status,
            .balloons = self.balloons,
            .rune_charges = self.rune_charges,
            .max_rune_charges = self.max_rune_charges,
            .inventory = self.inventory,
        };
    }
};

pub const CharacterProfile = struct {
    id: []const u8,
    name: []const u8,
    growth: [6]u4,
    weapon: ?character_rules.Weapon,
    weapon_range: ?WeaponRange,
    rune: ?[]const u8,
    rune_locked: bool,
};

/// Borrows immutable profiles from the validated content package.
pub const CharacterRules = struct {
    tables: ?character_rules.Systems,
    profiles: ?*const anyopaque,
    profile_count: usize,
    lookup: *const fn (*const anyopaque, usize, []const u8) ?CharacterProfile,

    pub fn profile(self: CharacterRules, id: []const u8) ?CharacterProfile {
        return self.lookup(self.profiles orelse return null, self.profile_count, id);
    }

    pub fn validate(self: CharacterRules, owned: Character) !void {
        var members = [_]Member{owned};
        try (Progress{ .money = 0, .party = &members }).validate();
        const member = owned;
        const template = self.profile(member.id) orelse return error.InvalidMember;
        if (member.max_hp > 9999 or (member.hp == 0) != (member.status == .unconscious) or !std.mem.eql(u8, member.name, template.name) or owned.level == 0 or owned.level > 99 or owned.experience >= 1000) return error.InvalidMember;
        for ([_]u16{ owned.base_stats.attack, owned.base_stats.defense, owned.base_stats.skill, owned.base_stats.speed, owned.base_stats.magic, owned.base_stats.luck }) |value| if (value > 9999) return error.InvalidMember;
        if (owned.weapon_level == 0 or owned.weapon_level > 16) return error.InvalidWeapon;
        const rules = self.tables orelse return error.SystemsUnavailable;
        for (std.enums.values(character_rules.EquipmentSlot)) |slot| {
            self.checkEquipment(owned, slot, owned.loadout.get(slot)) catch return error.InvalidEquipment;
        }
        if (owned.rune) |id| {
            if (id >= rules.runes.len) return error.InvalidRune;
            const definition = rules.runes[id];
            const original = template.rune != null and std.mem.eql(u8, template.rune.?, definition.id);
            if (template.rune_locked and !original) return error.InvalidRune;
            if (!original and !definition.allows(template.id)) return error.InvalidRune;
        } else if (template.rune_locked) return error.RuneLocked;
        const capacity = owned.runeCapacity(rules);
        if (!std.mem.eql(u16, &capacity, &member.max_rune_charges)) return error.InvalidMagicCapacity;
    }

    pub fn checkEquipment(self: CharacterRules, member: Character, slot: character_rules.EquipmentSlot, item: ?usize) !void {
        const tables = self.tables orelse return error.InvalidEquipment;
        const index = item orelse return;
        if (index >= tables.equipment.len or !tables.equipment[index].allows(member.id, slot)) return error.InvalidEquipment;
        var needed: usize = 1;
        for (std.enums.values(character_rules.EquipmentSlot)) |other| {
            if (other != slot and member.loadout.get(other) == item) needed += 1;
        }
        if (self.gearCount(member, index) < needed) return error.ItemUnavailable;
    }

    pub fn gearCount(self: CharacterRules, member: Character, index: usize) usize {
        const id = std.meta.stringToEnum(items.Id, self.tables.?.equipment[index].id) orelse return 0;
        var count: usize = 0;
        for (member.inventory.slots) |entry| {
            if (entry != null and entry.?.id == id) count += 1;
        }
        return count;
    }

    pub fn itemEquipped(self: CharacterRules, member: Character, slot: usize) bool {
        const tables = self.tables orelse return false;
        return wearsItem(tables.equipment, member, slot);
    }

    pub fn equipOwned(self: CharacterRules, member: *Character, slot: character_rules.EquipmentSlot, item: ?usize) !void {
        try self.checkEquipment(member.*, slot, item);
        member.loadout.set(slot, item);
        member.refreshRuneCapacity(self.tables.?);
    }

    pub fn checkRuneTarget(self: CharacterRules, member: Character) !void {
        if (self.tables == null) return error.InvalidRune;
        if ((self.profile(member.id) orelse return error.InvalidRune).rune_locked) return error.RuneLocked;
    }

    pub fn attachmentRune(self: CharacterRules, member: []const u8, inventory: items.Inventory, slot: usize) !usize {
        const tables = self.tables orelse return error.InvalidRune;
        if (slot >= inventory.count()) return error.InvalidItem;
        const id = @tagName(inventory.slots[slot].?.id);
        for (tables.runes, 0..) |definition, index| {
            if (definition.crystal == null or !std.mem.eql(u8, definition.crystal.?, id)) continue;
            if (!definition.allows(member)) return error.IncompatibleRune;
            return index;
        }
        return error.InvalidItem;
    }

    pub fn detachRune(self: CharacterRules, member: *Character) !void {
        const tables = self.tables orelse return error.InvalidRune;
        const index = member.rune orelse return error.InvalidRune;
        if (index >= tables.runes.len) return error.InvalidRune;
        const definition = tables.runes[index];
        const id = std.meta.stringToEnum(items.Id, definition.crystal orelse return error.RuneLocked) orelse return error.InvalidRune;
        const count = member.inventory.count();
        if (count == member.inventory.slots.len) return error.InventoryFull;
        member.inventory.slots[count] = .{ .id = id, .uses = 0 };
        member.rune = null;
    }
};

pub fn wearsItem(equipment: []const character_rules.Equipment, member: Character, slot: usize) bool {
    const stack = member.inventory.slots[slot] orelse return false;
    var worn: usize = 0;
    for (std.enums.values(character_rules.EquipmentSlot)) |place| if (member.loadout.get(place)) |gear| {
        if (gear < equipment.len and std.mem.eql(u8, @tagName(stack.id), equipment[gear].id)) worn += 1;
    };
    for (member.inventory.slots[0..slot]) |other| {
        if (other != null and other.?.id == stack.id) worn -|= 1;
    }
    return worn > 0;
}

// The caller owns the members; changes survive scene transitions for this session.
pub const Progress = struct {
    storage: storage.Storage = .{},
    money: u32,
    party: []Member,
    story: Story = .initial,

    pub fn validate(self: Progress) !void {
        if (self.story.scenario) |story| if (!std.mem.eql(u8, story.schema, "suikoden-event-story/1")) return error.UnsupportedEventStorySchema;
        if (self.story.scenario) |story| if (story.soul_eater_spell_slots < 1 or story.soul_eater_spell_slots > 4) return error.InvalidSoulEaterProgress;
        if (self.story.recruitment_tier > 4) return error.InvalidRecruitmentTier;
        var ended = false;
        for (self.story.castle_name) |byte| {
            if (byte == 0) ended = true else if (ended or byte < 32 or byte > 126) return error.InvalidCastleName;
        }
        try self.storage.validate();
        if (self.party.len == 0 or self.party.len > 6) return error.InvalidParty;
        for (self.party, 0..) |member, index| {
            try member.inventory.validate();
            if (!validName(member.id) or !validName(member.name) or member.max_hp == 0 or member.hp > member.max_hp or member.balloons > 3) return error.InvalidMember;
            for (self.party[0..index]) |other| {
                if (std.mem.eql(u8, member.id, other.id)) return error.DuplicateMember;
            }
            for (member.rune_charges, member.max_rune_charges) |current, maximum| {
                if (current > maximum) return error.InvalidMember;
            }
        }
    }

    pub fn buyMedicine(self: *Progress, rules: items.Rules, member: usize) !void {
        try self.buyItem(rules, .medicine, member);
    }
    pub fn appraise(self: *Progress, rules: items.Rules, owner: usize, slot: usize) !void {
        try self.validate();
        try rules.validate();
        if (owner >= self.party.len or slot >= self.party[owner].inventory.count()) return error.InvalidItem;
        const item = &self.party[owner].inventory.slots[slot].?;
        if (item.identified or !item.id.decoration()) return error.AlreadyIdentified;
        for (rules.appraisals) |record| if (record.id == item.id) {
            if (self.money < record.fee) return error.InsufficientFunds;
            self.money -= record.fee;
            item.identified = true;
            return;
        };
        return error.AppraisalUnavailable;
    }

    pub fn buyItem(self: *Progress, rules: items.Rules, id: items.Id, member: usize) !void {
        try self.buyFromStock(rules, rules.stock, id, member, false);
    }

    pub fn buyShopGood(self: *Progress, rules: items.Rules, stock: []const items.Id, id: items.Id, member: usize) !void {
        try self.buyFromStock(rules, stock, id, member, true);
    }

    fn buyFromStock(self: *Progress, rules: items.Rules, stock: []const items.Id, id: items.Id, member: usize, allow_equipment: bool) !void {
        try rules.validate();
        try self.validate();
        const item = (if (allow_equipment) rules.offerGood(id) else rules.good(id)) orelse return error.InvalidItem;
        if (item.price == 0) return error.InvalidItem;
        var in_stock = false;
        for (stock) |entry| if (entry == id) {
            in_stock = true;
            break;
        };
        if (!in_stock) return error.InvalidItem;
        if (member >= self.party.len) return error.InvalidMember;
        const inventory = &self.party[member].inventory;
        const count = inventory.count();
        if (count == inventory.slots.len) return error.InventoryFull;
        if (self.money < item.price) return error.InsufficientFunds;
        inventory.slots[count] = .{ .id = id, .uses = item.uses };
        self.money -= item.price;
    }

    pub fn useMedicine(self: *Progress, rules: items.Rules, owner: usize, slot: usize, target: usize) !void {
        if (owner >= self.party.len or slot >= self.party[owner].inventory.count() or self.party[owner].inventory.slots[slot].?.id != .medicine) return error.InvalidItem;
        try self.useItem(rules, owner, slot, target);
    }

    pub fn checkItemTarget(self: Progress, rules: items.Rules, owner: usize, slot: usize, target: usize) !void {
        try rules.validate();
        try self.validate();
        if (owner >= self.party.len or target >= self.party.len or slot >= self.party[owner].inventory.count()) return error.InvalidItem;
        const item = rules.consumable(self.party[owner].inventory.slots[slot].?.id) orelse return error.InvalidItem;
        if (!item.field_usable) return error.BattleOnlyItem;
        const member = self.party[target];
        if (member.status == .unconscious) return error.InvalidTarget;
        if (item.heal_hp > 0 and member.hp == member.max_hp) return error.FullHealth;
        if (item.cure) |cure| switch (cure) {
            .poison => if (member.status != .poisoned) return error.NoEffect,
            .balloon => if (member.balloons == 0) return error.NoEffect,
        };
    }

    pub fn useItem(self: *Progress, rules: items.Rules, owner: usize, slot: usize, target: usize) !void {
        try self.checkItemTarget(rules, owner, slot, target);
        const item = rules.consumable(self.party[owner].inventory.slots[slot].?.id).?;
        const inventory = &self.party[owner].inventory;
        try inventory.spendUse(slot, item.id);
        _ = item.applyTo(&self.party[target], false);
    }

    pub fn salePrice(self: Progress, rules: items.Rules, owner: usize, slot: usize) !u32 {
        return self.salePriceWithCatalog(rules, false, owner, slot);
    }

    pub fn shopSalePrice(self: Progress, rules: items.Rules, owner: usize, slot: usize) !u32 {
        return self.salePriceWithCatalog(rules, true, owner, slot);
    }

    fn salePriceWithCatalog(self: Progress, rules: items.Rules, allow_equipment: bool, owner: usize, slot: usize) !u32 {
        try rules.validate();
        try self.validate();
        if (owner >= self.party.len or slot >= self.party[owner].inventory.count()) return error.InvalidItem;
        if (!self.party[owner].inventory.slots[slot].?.identified) return error.CannotSell;
        const id = self.party[owner].inventory.slots[slot].?.id;
        const item = (if (allow_equipment) rules.offerGood(id) else rules.good(id)) orelse return error.CannotSell;
        if (item.price == 0) return error.CannotSell;
        if (self.party[owner].inventory.slots[slot].?.uses != item.uses) return error.CannotSell;
        return item.price / 2;
    }

    pub fn sellItem(self: *Progress, rules: items.Rules, owner: usize, slot: usize) !void {
        const price = try self.salePrice(rules, owner, slot);
        if (price > max_money or self.money > max_money - price) return error.MoneyLimit;
        self.party[owner].inventory.remove(slot);
        self.money += price;
    }

    pub fn sellShopItem(self: *Progress, rules: items.Rules, owner: usize, slot: usize) !void {
        const price = try self.shopSalePrice(rules, owner, slot);
        if (price > max_money or self.money > max_money - price) return error.MoneyLimit;
        self.party[owner].inventory.remove(slot);
        self.money += price;
    }

    pub fn transfer(self: *Progress, owner: usize, slot: usize, recipient: usize) !void {
        try self.validate();
        if (owner >= self.party.len or recipient >= self.party.len or owner == recipient or slot >= self.party[owner].inventory.count()) return error.InvalidItem;
        const destination = &self.party[recipient].inventory;
        const count = destination.count();
        if (count == destination.slots.len) return error.InventoryFull;
        destination.slots[count] = self.party[owner].inventory.slots[slot];
        self.party[owner].inventory.remove(slot);
    }

    pub fn discard(self: *Progress, owner: usize, slot: usize) !void {
        try self.validate();
        if (owner >= self.party.len or slot >= self.party[owner].inventory.count()) return error.InvalidItem;
        self.party[owner].inventory.remove(slot);
    }

    pub fn cost(self: Progress, price_per_member: u16) u32 {
        return @as(u32, @intCast(self.party.len)) * @as(u32, price_per_member);
    }

    pub fn stay(self: *Progress, price_per_member: u16) !void {
        try self.validate();
        const price = self.cost(price_per_member);
        if (self.money < price) return error.InsufficientFunds;
        self.money -= price;
        self.restoreMembers();
    }

    pub fn restoreParty(self: *Progress, hp_only: bool) !void {
        try self.validate();
        if (!hp_only) return self.restoreMembers();
        for (self.party) |*member| {
            member.hp = member.max_hp;
            if (member.status == .unconscious) member.status = .healthy;
        }
    }

    fn restoreMembers(self: *Progress) void {
        for (self.party) |*member| {
            member.hp = member.max_hp;
            member.status = .healthy;
            member.balloons = 0;
            member.rune_charges = member.max_rune_charges;
        }
    }
};
fn validName(value: []const u8) bool {
    if (value.len == 0 or value.len > 64 or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (byte < 32 or byte == 127) return false;
    return true;
}
