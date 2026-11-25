//! Seven-slot shared item ledger over the *existing* `Snapshot.shared` store.
//!
//! Source behaviour (MAIN.EXE shared append/remove, re-derived by
//! the extraction pipeline):
//!   * capacity seven, slots hold bare item ids and no use counters;
//!   * acquire appends at the tail and rejects a full ledger;
//!   * remove deletes the first matching id and shifts the remainder left;
//!   * duplicates are permitted by the source append; only a source-qualified
//!     operation may declare an acquisition unique;
//!   * query returns the first matching index and the total count.
//!
//! The ledger is a *view*: the caller's `Snapshot.shared` remains the owner.
//! A `Prepared` value is an atomic proposal; `replay` re-checks its receipt and
//! baseline before the owner applies it.
const std = @import("std");
const packet = @import("catalogue.zig");

pub const capacity = packet.shared_capacity;

pub const Op = enum { acquire, remove };

pub const View = struct {
    len: u8 = 0,
    ids: [capacity]u16 = @splat(0),
    revision: u32 = 0,

    pub fn validate(self: View) !void {
        if (self.len > capacity) return error.InvalidLedger;
        for (self.ids, 0..) |value, index| {
            if (index < self.len) {
                if (value == 0 or value > packet.item_count) return error.InvalidLedger;
            } else if (value != 0) return error.InvalidLedger;
        }
    }
    pub fn find(self: View, source_item_id: u16) ?u8 {
        for (self.ids[0..self.len], 0..) |value, index| {
            if (value == source_item_id) return @intCast(index);
        }
        return null;
    }
    pub fn count(self: View, source_item_id: u16) u8 {
        var total: u8 = 0;
        for (self.ids[0..self.len]) |value| if (value == source_item_id) {
            total += 1;
        };
        return total;
    }
    pub fn digest(self: View) u64 {
        var hasher = std.hash.Fnv1a_64.init();
        hasher.update(&.{self.len});
        var buffer: [4]u8 = undefined;
        for (self.ids) |value| {
            std.mem.writeInt(u16, buffer[0..2], value, .little);
            hasher.update(buffer[0..2]);
        }
        std.mem.writeInt(u32, &buffer, self.revision, .little);
        hasher.update(&buffer);
        return hasher.final();
    }
};

pub fn viewOf(p: packet.Packet, shared: [7]?[]const u8, revision: u32) !View {
    var view: View = .{ .revision = revision };
    var ended = false;
    for (shared) |maybe| {
        if (maybe) |id| {
            if (ended) return error.InvalidSharedItems;
            const item = packet.findById(p, id) orelse return error.UnknownIdentity;
            // The source stores bare ids; the runtime names them by stable id.
            if (view.len == capacity) return error.InvalidSharedItems;
            view.ids[view.len] = item.source_item_id;
            view.len += 1;
        } else ended = true;
    }
    try view.validate();
    return view;
}

/// Materialise a ledger view back onto the owner's borrowed-string store.  The
/// returned names are the packet's stable ids, so no allocation is required.
pub fn slotsOf(p: packet.Packet, view: View) ![7]?[]const u8 {
    try view.validate();
    var slots: [7]?[]const u8 = @splat(null);
    for (view.ids[0..view.len], 0..) |source_item_id, index| {
        const item = packet.findBySourceId(p, source_item_id) orelse return error.UnknownIdentity;
        slots[index] = item.id;
    }
    return slots;
}

pub const Applied = struct { view: View, target: u8 };

pub fn apply(view: View, op: Op, source_item_id: u16) !Applied {
    if (source_item_id == 0 or source_item_id > packet.item_count) return error.UnknownIdentity;
    var next = view;
    var target: u8 = 0;
    switch (op) {
        .acquire => {
            if (next.len == capacity) return error.SharedLedgerFull;
            target = next.len;
            next.ids[next.len] = source_item_id;
            next.len += 1;
        },
        .remove => {
            const index = next.find(source_item_id) orelse return error.ItemUnavailable;
            target = index;
            var cursor: usize = index;
            while (cursor + 1 < next.len) : (cursor += 1) next.ids[cursor] = next.ids[cursor + 1];
            next.len -= 1;
            next.ids[next.len] = 0;
        },
    }
    next.revision = std.math.add(u32, next.revision, 1) catch return error.RevisionOverflow;
    try next.validate();
    return .{ .view = next, .target = target };
}

pub const Query = struct { index: ?u8, count: u8, source_item_id: u16 };

pub fn query(p: packet.Packet, view: View, id: []const u8) !Query {
    try view.validate();
    const item = packet.findById(p, id) orelse return error.UnknownIdentity;
    return .{ .index = view.find(item.source_item_id), .count = view.count(item.source_item_id), .source_item_id = item.source_item_id };
}

pub const Prepared = struct {
    operation: Op,
    item_source_id: u16,
    baseline_revision: u32,
    baseline_digest: u64,
    result_len: u8,
    target_index: u8,
    result_digest: u64,
    receipt: u64,
};

fn receipt(operation: Op, item_source_id: u16, baseline_digest: u64, result_digest: u64, result_len: u8, target: u8) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(&.{@backingInt(operation)});
    var buffer: [8]u8 = undefined;
    std.mem.writeInt(u16, buffer[0..2], item_source_id, .little);
    hasher.update(buffer[0..2]);
    std.mem.writeInt(u64, &buffer, baseline_digest, .little);
    hasher.update(&buffer);
    std.mem.writeInt(u64, &buffer, result_digest, .little);
    hasher.update(&buffer);
    hasher.update(&.{ result_len, target });
    return hasher.final();
}

pub fn prepare(p: packet.Packet, view: View, op: Op, stable_id: []const u8) !Prepared {
    try view.validate();
    const item = packet.findById(p, stable_id) orelse return error.UnknownIdentity;
    const applied = try apply(view, op, item.source_item_id);
    const baseline_digest = view.digest();
    const result_digest = applied.view.digest();
    return .{
        .operation = op,
        .item_source_id = item.source_item_id,
        .baseline_revision = view.revision,
        .baseline_digest = baseline_digest,
        .result_len = applied.view.len,
        .target_index = applied.target,
        .result_digest = result_digest,
        .receipt = receipt(op, item.source_item_id, baseline_digest, result_digest, applied.view.len, applied.target),
    };
}

pub fn replay(p: packet.Packet, view: *View, prepared: Prepared) !void {
    _ = p;
    try view.validate();
    if (prepared.item_source_id == 0 or prepared.item_source_id > packet.item_count)
        return error.InvalidPrepared;
    const expected = receipt(prepared.operation, prepared.item_source_id, prepared.baseline_digest, prepared.result_digest, prepared.result_len, prepared.target_index);
    if (expected != prepared.receipt) return error.InvalidPrepared;
    if (prepared.baseline_revision != view.revision or prepared.baseline_digest != view.digest())
        return error.StaleBaseline;
    const applied = try apply(view.*, prepared.operation, prepared.item_source_id);
    if (applied.view.len != prepared.result_len or applied.view.digest() != prepared.result_digest or
        applied.target != prepared.target_index) return error.InvalidPrepared;
    view.* = applied.view;
}

/// Source transfer predicate: appraisal items need an identified entry, every
/// other item must be unworn.
pub const TransferState = struct { identified: bool = false, worn: bool = false };

pub fn transferEligible(item: *const packet.Item, state: TransferState) !bool {
    if (item.appraisal_tier > 0) return state.identified;
    return !state.worn;
}

pub const ConsumePlan = struct {
    item_source_id: u16,
    uses_before: u8,
    uses_after: u8,
    removes_entry: bool,
    reusable: bool,
    receipt: u64,
};

fn consumeReceipt(source_item_id: u16, before: u8, after: u8, removes: bool, reusable: bool) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    var buffer: [4]u8 = undefined;
    std.mem.writeInt(u16, buffer[0..2], source_item_id, .little);
    hasher.update(buffer[0..2]);
    hasher.update(&.{ before, after, @intFromBool(removes), @intFromBool(reusable) });
    return hasher.final();
}

pub fn prepareConsume(p: packet.Packet, stable_id: []const u8, uses_before: u8) !ConsumePlan {
    const item = packet.findById(p, stable_id) orelse return error.UnknownIdentity;
    if (!item.usable) return error.NotUsable;
    var after = uses_before;
    var removes = false;
    var reusable = false;
    if (item.max_uses == 0) {
        if (uses_before != 0) return error.NoUsesRemaining;
        reusable = true;
    } else {
        if (uses_before == 0) return error.NoUsesRemaining;
        if (uses_before > item.max_uses) return error.UsesExceedMaximum;
        after = uses_before - 1;
        removes = after == 0;
    }
    return .{
        .item_source_id = item.source_item_id,
        .uses_before = uses_before,
        .uses_after = after,
        .removes_entry = removes,
        .reusable = reusable,
        .receipt = consumeReceipt(item.source_item_id, uses_before, after, removes, reusable),
    };
}

pub fn verifyConsume(p: packet.Packet, plan: ConsumePlan) !void {
    const item = packet.findBySourceId(p, plan.item_source_id) orelse return error.UnknownIdentity;
    const expected = try prepareConsume(p, item.id, plan.uses_before);
    if (expected.receipt != plan.receipt or expected.uses_after != plan.uses_after or
        expected.removes_entry != plan.removes_entry or expected.reusable != plan.reusable)
        return error.InvalidPrepared;
}
