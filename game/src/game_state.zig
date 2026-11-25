const std = @import("std");
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
pub const Member = struct {
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
};

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
