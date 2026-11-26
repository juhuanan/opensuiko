//! Adapter from the caller host to the current transaction engines.
//!
//! The host is deliberately engine-agnostic.  This adapter is the only file in
//! the pack that imports `field`; it maps the packet's native item ids to the
//! current `items.Id` enum and delegates to `game_state.Progress` and
//! `storage.Storage`.  An identity the current enum does not carry is refused
//! as `UnsupportedItem` rather than substituted.
const host = @import("host.zig");
const field = @import("field");

pub const Adapter = struct {
    state: *field.State,

    pub fn engine(self: *Adapter) host.Engine {
        return .{
            .ctx = @ptrCast(self),
            .buy = buy,
            .sell = sell,
            .deposit = deposit,
            .withdraw = withdraw,
            .appraise = appraise,
            .sharpen = sharpen,
            .attach = attach,
            .detach = detach,
        };
    }

    fn rules(self: *Adapter) !field.items.Rules {
        return self.state.item_rules orelse error.EngineUnavailable;
    }

    fn item(native_id: u16) ?field.items.Id {
        return switch (native_id) {
            25 => .medicine,
            26 => .antitoxin,
            71 => .needle,
            72 => .mega_medicine,
            else => null,
        };
    }

    fn buy(ctx: *anyopaque, member: usize, native_id: u16) anyerror!void {
        const self: *Adapter = @ptrCast(@alignCast(ctx));
        const id = item(native_id) orelse return error.UnsupportedItem;
        try self.state.progress.buyItem(try self.rules(), id, member);
    }

    fn sell(ctx: *anyopaque, member: usize, slot: usize) anyerror!void {
        const self: *Adapter = @ptrCast(@alignCast(ctx));
        try self.state.progress.sellItem(try self.rules(), member, slot);
    }

    fn deposit(ctx: *anyopaque, member: usize, slot: usize) anyerror!void {
        const self: *Adapter = @ptrCast(@alignCast(ctx));
        if (member >= self.state.progress.party.len) return error.InvalidMember;
        try self.state.progress.storage.deposit(&self.state.progress.party.at(member).inventory, slot);
    }

    fn withdraw(ctx: *anyopaque, member: usize, native_id: u16) anyerror!void {
        const self: *Adapter = @ptrCast(@alignCast(ctx));
        if (member >= self.state.progress.party.len) return error.InvalidMember;
        const id = item(native_id) orelse return error.UnsupportedItem;
        try self.state.progress.storage.withdraw(&self.state.progress.party.at(member).inventory, id);
    }

    fn appraise(ctx: *anyopaque, member: usize, slot: usize) anyerror!void {
        const self: *Adapter = @ptrCast(@alignCast(ctx));
        try self.state.progress.appraise(try self.rules(), member, slot);
    }

    fn sharpen(ctx: *anyopaque, member: usize, limit: u8) anyerror!void {
        _ = ctx;
        _ = member;
        _ = limit;
        return error.EngineUnavailable;
    }

    fn attach(ctx: *anyopaque, target: usize, rune_index: u8, crystal_slot: usize) anyerror!void {
        _ = ctx;
        _ = target;
        _ = rune_index;
        _ = crystal_slot;
        return error.EngineUnavailable;
    }

    fn detach(ctx: *anyopaque, member: usize) anyerror!void {
        _ = ctx;
        _ = member;
        return error.EngineUnavailable;
    }
};
