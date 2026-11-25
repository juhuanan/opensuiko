const std = @import("std");
const items = @import("items.zig");
pub const capacity = 254;
const Counts = std.enums.EnumFieldStruct(items.Id, u16, 0);

pub const Storage = struct {
    counts: Counts = .{},
    pub fn quantity(self: Storage, id: items.Id) u16 {
        return switch (id) {
            inline else => |tag| @field(self.counts, @tagName(tag)),
        };
    }
    fn counter(self: *Storage, id: items.Id) *u16 {
        return switch (id) {
            inline else => |tag| &@field(self.counts, @tagName(tag)),
        };
    }
    pub fn validate(self: Storage) !void {
        for (std.enums.values(items.Id)) |id| if (self.quantity(id) > capacity) return error.InvalidStorage;
    }
    pub fn count(self: Storage) usize {
        var result: usize = 0;
        for (std.enums.values(items.Id)) |id| if (self.quantity(id) > 0) {
            result += 1;
        };
        return result;
    }
    pub fn itemAt(self: Storage, selection: usize) ?items.Id {
        var index: usize = 0;
        for (std.enums.values(items.Id)) |id| {
            if (self.quantity(id) > 0) {
                if (index == selection) return id;
                index += 1;
            }
        }
        return null;
    }
    pub fn deposit(self: *Storage, inventory: *items.Inventory, slot: usize) !void {
        try self.validate();
        try inventory.validate();
        if (slot >= inventory.count()) return error.InvalidItem;
        const item = inventory.slots[slot].?;
        if (!item.identified) return error.AppraisalRequired;
        if (self.quantity(item.id) == capacity) return error.StorageFull;
        self.counter(item.id).* += 1;
        inventory.remove(slot);
    }
    pub fn withdraw(self: *Storage, inventory: *items.Inventory, id: items.Id) !void {
        try self.validate();
        try inventory.validate();
        if (self.quantity(id) == 0) return error.ItemNotStored;
        const index = inventory.count();
        if (index == inventory.slots.len) return error.InventoryFull;
        inventory.slots[index] = .{ .id = id, .uses = id.maxUses() };
        self.counter(id).* -= 1;
    }
};
