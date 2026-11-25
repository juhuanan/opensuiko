//! Pending-item overload menu; inventory publishes with the event receipt on close.
const State = @import("journey.zig").State;
const std = @import("std");
const field = @import("field");
const battle = @import("battle");
const events = @import("field_events");
const pause = @import("pause_menu");
const catalogue = @import("item_ledger").catalogue;
pub const layout = @import("item_overload_data");

pub const Phase = enum { overloaded, offer, members, items, equipped, gave_up, commit, settling };
pub const Active = struct {
    item: field.items.Id,
    receipt: events.Receipt,
    phase: Phase = .overloaded,
    member: usize = 0,
    slot: usize = 0,
    choice: u1 = 0,
    remaining: u8 = 0,
    replacement: ?struct { member: usize, slot: usize } = null,
};

fn wornSlot(state: *const State, member: usize, slot: usize) !?battle.systems.EquipmentSlot {
    if (member >= state.combat.partyCount() or slot >= state.combat.progress.party[member].inventory.count()) return error.InvalidItem;
    if (!state.combat.itemEquipped(member, slot)) return null;
    const id = state.combat.progress.party[member].inventory.slots[slot].?.id;
    const gear = state.combat.gearIndex(id) orelse return error.InvalidEquipment;
    var ordinal: usize = 0;
    for (state.combat.progress.party[member].inventory.slots[0..slot]) |item| if (item != null and item.?.id == id) {
        ordinal += 1;
    };
    for (std.enums.values(battle.systems.EquipmentSlot)) |place| if (state.combat.loadouts[member].get(place) == gear) {
        if (ordinal == 0) return place;
        ordinal -= 1;
    };
    return error.InvalidEquipment;
}

pub fn canDrop(state: *const State, member: usize, slot: usize) !bool {
    if (member >= state.combat.partyCount() or slot >= state.combat.progress.party[member].inventory.count()) return error.InvalidItem;
    const packet = state.shared_item_catalogue orelse return error.MissingSharedItemCatalogue;
    const id = state.combat.progress.party[member].inventory.slots[slot].?.id;
    const item = catalogue.findById(packet, @tagName(id)) orelse return error.UnknownFieldEventItem;
    if (item.ownership != .appraisal and item.price == 0) return false;
    if (try wornSlot(state, member, slot)) |place| if (state.extras[member].locked_equipment[@backingInt(place)]) return false;
    return true;
}

pub fn prepareReplacement(state: *const State, member: usize, slot: usize, incoming: field.items.Id) !battle.OwnedMember {
    if (!try canDrop(state, member, slot)) return error.ItemCannotBeDiscarded;
    var members: [6]battle.Member = undefined;
    const count = state.combat.partyCount();
    @memcpy(members[0..count], state.combat.progress.party);
    var staged = state.combat.*;
    staged.progress.party = members[0..count];
    if (try wornSlot(state, member, slot)) |place| try staged.equipSlotOwned(member, place, null);
    const bag = &members[member].inventory;
    bag.remove(slot);
    if (!try bag.receive(incoming)) return error.InventoryFull;
    const owned = staged.ownedMember(member);
    try staged.validateOwnedMember(owned);
    return owned;
}

pub fn begin(state: *State) !void {
    if (state.item_overload != null or state.mode != .field or state.combat.partyCount() == 0) return error.InvalidItemOverload;
    const owner = state.field_event orelse return error.MissingFieldEvent;
    const request = owner.session.queuedItemOverload() orelse return error.MissingItemOverload;
    const item = std.meta.stringToEnum(field.items.Id, request.item_name) orelse return error.UnknownFieldEventItem;
    for (state.combat.progress.party) |member| {
        try member.inventory.validate();
        if (member.inventory.count() != 9) return error.UnexpectedItemOverload;
    }
    if (state.shared_item_catalogue == null) return error.MissingSharedItemCatalogue;
    state.item_overload = .{ .item = item, .receipt = request.receipt };
}

fn move(cursor: *usize, count: usize, input: pause.Input) bool {
    if (input.field.menu_direction == .up) cursor.* = (cursor.* + count - 1) % count else if (input.field.menu_direction == .down) cursor.* = (cursor.* + 1) % count else return false;
    return true;
}

pub fn tick(state: *State, input: pause.Input) !void {
    var next = state.item_overload orelse return error.MissingItemOverload;
    const owner = state.field_event orelse return error.MissingFieldEvent;
    const request = owner.session.queuedItemOverload() orelse return error.MissingItemOverload;
    if (!std.meta.eql(next.receipt, request.receipt)) return error.InvalidItemOverloadReceipt;
    const confirm = input.field.action;
    const cancel = input.field.cancel;
    var done = false;
    var cue: ?u16 = null;
    switch (next.phase) {
        .overloaded => if (confirm or cancel) {
            next.phase = .offer;
            cue = 0x503;
        },
        .offer => {
            if (input.field.menu_direction == .up or input.field.menu_direction == .down) {
                next.choice ^= 1;
                cue = 0x502;
            }
            if (confirm) {
                next.phase = if (next.choice == 0) .members else .gave_up;
                if (next.choice == 0) {
                    next.member = 0;
                    next.slot = 0;
                }
                next.choice = 0;
                cue = 0x503;
            }
        },
        .members => {
            if (move(&next.member, state.combat.partyCount(), input)) cue = 0x502;
            if (cancel) {
                next.phase = .offer;
                next.choice = 0;
                cue = 0x504;
            } else if (confirm) {
                next.phase = .items;
                next.slot = 0;
                cue = 0x503;
            }
        },
        .items => {
            if (move(&next.slot, state.combat.progress.party[next.member].inventory.count(), input)) cue = 0x502;
            if (cancel) {
                next.phase = .members;
                cue = 0x504;
            } else if (confirm) {
                if (!try canDrop(state, next.member, next.slot)) {
                    cue = 0x505;
                } else {
                    cue = 0x503;
                    next.replacement = .{ .member = next.member, .slot = next.slot };
                    next.choice = 0;
                    next.phase = if (try wornSlot(state, next.member, next.slot) != null) .equipped else .commit;
                }
            }
        },
        .equipped => {
            if (input.field.menu_direction == .up or input.field.menu_direction == .down) {
                next.choice ^= 1;
                cue = 0x502;
            }
            if (confirm or cancel) {
                if (confirm and next.choice == 0) {
                    next.phase = .commit;
                    cue = 0x503;
                } else {
                    next.phase = .items;
                    next.slot = next.choice;
                    next.replacement = null;
                    cue = 0x504;
                }
            }
        },
        .gave_up => done = confirm or cancel,
        .commit => {
            const replacement = next.replacement orelse return error.InvalidItemOverload;
            _ = try prepareReplacement(state, replacement.member, replacement.slot, next.item);
            next.remaining = layout.settle_updates;
            next.phase = .settling;
        },
        .settling => {
            next.remaining -|= 1;
            done = next.remaining == 0 or confirm;
        },
    }
    if (done) {
        const replacement = if (next.replacement) |selection| try prepareReplacement(state, selection.member, selection.slot, next.item) else null;
        try owner.session.resumeItemOverload(owner.binding.*, &state.field_state, next.receipt);
        if (replacement) |owned| state.combat.setOwnedMember(next.replacement.?.member, owned);
        state.item_overload = null;
    } else state.item_overload = next;
    state.item_overload_sound = cue;
}
