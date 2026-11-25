//! In-memory bank lifecycle over hash-verified source bytes. This models source
//! slot/status ordering without claiming that hardware DMA occurred.
const std = @import("std");
const media = @import("raw_media_owner.zig");

pub const Bank = media.BankId;
pub const Status = enum { empty, header_only, resident };
pub const Phase = enum { closed, header_loaded };
pub const Padding = union(enum) { none, unknown_bytes: u8 };

pub const Slot = struct {
    status: Status = .empty,
    bank: ?Bank = null,
    generation: u64 = 0,
};
pub const Pending = struct { bank: Bank, generation: u64, phase: Phase };
pub const State = struct {
    completed: u8 = 0,
    last_generation: u64 = 0,
    pending: ?Pending = null,
    slots: [3]Slot = @splat(.{}),
};

pub const CloseReceipt = struct { bank: Bank, request: u8, slot: u8, generation: u64, status: Status = .empty };
pub const HeaderReceipt = struct { bank: Bank, request: u8, slot: u8, generation: u64, status: Status = .header_only, va_sha256: [64]u8 };
pub const TransferReceipt = struct {
    bank: Bank,
    request: u8,
    slot: u8,
    generation: u64,
    status: Status = .resident,
    va_sha256: [64]u8,
    vb_sha256: [64]u8,
    logical_body_bytes: u32,
    dma_tail: Padding,
};

const Storage = struct { va: []u8, vb: ?[]u8 = null };
const sequence = [_]Bank{ .stay, .orch };

fn request(bank: Bank) u8 {
    return if (bank == .stay) 0x21 else 0x25;
}
fn slot(bank: Bank) usize {
    return if (bank == .stay) 0 else 1;
}
fn expectedBank(completed: u8) Bank {
    return sequence[completed];
}
fn sourceBytes(loaded: media.Loaded) media.Inputs {
    return .{ .stay = loaded.stay, .orch = loaded.orch, .seq = loaded.seq };
}
fn verifySource(loaded: media.Loaded) !media.Receipt {
    const receipt = try media.verify(sourceBytes(loaded));
    try media.validateReceipt(loaded.receipt);
    if (!std.meta.eql(receipt, loaded.receipt)) return error.SourceReceiptMismatch;
    return receipt;
}
fn sourceBank(receipt: media.Receipt, bank: Bank) media.BankReceipt {
    return if (bank == .stay) receipt.stay else receipt.orch;
}
fn sourceData(loaded: media.Loaded, bank: Bank) media.BankBytes {
    return loaded.bankBytes(bank);
}
fn rawDigest(bytes: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}
fn tail(bytes: usize) Padding {
    const remainder = bytes % 64;
    return if (remainder == 0) .none else .{ .unknown_bytes = @intCast(64 - remainder) };
}

fn validateState(state: State) !void {
    if (state.completed > @as(u8, sequence.len)) return error.InvalidLogicalBankState;
    var previous_generation: u64 = 0;
    for (0..state.completed) |index| {
        const expected = sequence[index];
        const value = state.slots[slot(expected)];
        if (value.status != .resident or value.bank != expected or value.generation <= previous_generation)
            return error.InvalidLogicalBankState;
        previous_generation = value.generation;
    }
    if (state.slots[2].status != .empty or state.slots[2].bank != null or state.slots[2].generation != 0)
        return error.InvalidLogicalBankState;

    if (state.pending) |pending| {
        if (state.completed == @as(u8, sequence.len) or pending.bank != expectedBank(state.completed) or
            pending.generation == 0 or pending.generation != state.last_generation or pending.generation <= previous_generation)
            return error.InvalidLogicalBankState;
        const target = state.slots[slot(pending.bank)];
        switch (pending.phase) {
            .closed => if (target.status != .empty or target.bank != null or target.generation != 0) return error.InvalidLogicalBankState,
            .header_loaded => if (target.status != .header_only or target.bank != pending.bank or target.generation != pending.generation) return error.InvalidLogicalBankState,
        }
        const other_index = 1 - slot(pending.bank);
        if (other_index < @as(usize, state.completed) and state.slots[other_index].status != .resident) return error.InvalidLogicalBankState;
        const future_start: usize = @as(usize, state.completed) + 1;
        for (sequence[future_start..]) |bank| {
            const value = state.slots[slot(bank)];
            if (value.status != .empty or value.bank != null or value.generation != 0) return error.InvalidLogicalBankState;
        }
    } else {
        if ((state.completed == 0 and state.last_generation != 0) or
            (state.completed > 0 and state.last_generation != previous_generation)) return error.InvalidLogicalBankState;
        const completed: usize = state.completed;
        for (sequence[completed..]) |bank| {
            const value = state.slots[slot(bank)];
            if (value.status != .empty or value.bank != null or value.generation != 0) return error.InvalidLogicalBankState;
        }
    }
}

/// Structural snapshot check; actual slot bytes must be rebound before use.
pub fn validateSnapshot(state: State) !void {
    try validateState(state);
}

pub const Owner = struct {
    allocator: std.mem.Allocator,
    state: State = .{},
    storage: [3]?Storage = @splat(null),
    source_receipt: ?media.Receipt = null,

    pub fn init(allocator: std.mem.Allocator) Owner {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Owner) void {
        for (&self.storage) |*entry| if (entry.*) |stored| {
            self.allocator.free(stored.va);
            if (stored.vb) |body| self.allocator.free(body);
            entry.* = null;
        };
        self.* = undefined;
    }

    pub fn snapshot(self: Owner) !State {
        try validateOwned(self);
        return self.state;
    }

    /// Rebuilds resident logical slot bytes from pinned sources, not snapshot claims.
    /// Reconstructs the logical byte slots from authenticated sources. This
    /// validates stored identity, not prior scheduler execution or hardware IO.
    pub fn rebind(allocator: std.mem.Allocator, loaded: media.Loaded, state: State) !Owner {
        try validateState(state);
        const verified = try verifySource(loaded);
        var owner = Owner.init(allocator);
        errdefer owner.deinit();
        owner.state = state;
        if (state.completed != 0 or state.pending != null) owner.source_receipt = verified;
        for (state.slots, 0..) |value, index| {
            if (value.status == .empty) continue;
            const bank = value.bank orelse return error.InvalidLogicalBankState;
            const pinned = sourceBank(verified, bank);
            const bytes = sourceData(loaded, bank);
            const va = try allocator.dupe(u8, bytes.va);
            owner.storage[index] = .{ .va = va };
            if (!std.mem.eql(u8, &rawDigest(va), &pinned.va_sha256)) return error.SourceIdentityMismatch;
            if (value.status == .resident) {
                const vb = try allocator.dupe(u8, bytes.vb);
                if (!std.mem.eql(u8, &rawDigest(vb), &pinned.vb_sha256)) {
                    allocator.free(vb);
                    return error.SourceIdentityMismatch;
                }
                owner.storage[index].?.vb = vb;
            }
        }
        try validateOwned(owner);
        return owner;
    }

    fn acceptSource(self: Owner, loaded: media.Loaded) !media.Receipt {
        const source = try verifySource(loaded);
        if (self.source_receipt) |bound| if (!std.meta.eql(bound, source)) return error.SourceIdentityMismatch;
        try validateOwned(self);
        return source;
    }

    /// Models the source's slot close before loading a bank header.
    pub fn closeSlot(self: *Owner, loaded: media.Loaded, request_byte: u8, generation: u64) !CloseReceipt {
        const source = try self.acceptSource(loaded);
        if (self.state.pending != null) return error.LogicalBankTransferPending;
        if (self.state.completed >= @as(u8, sequence.len) or generation == 0 or generation <= self.state.last_generation)
            return error.StaleLogicalBankTransfer;
        const bank = expectedBank(self.state.completed);
        const pinned = sourceBank(source, bank);
        if (request_byte != request(bank) or pinned.request != request_byte or pinned.slot != @as(u8, @intCast(slot(bank)))) return error.SourceIdentityMismatch;
        const target = slot(bank);
        if (self.state.slots[target].status != .empty or self.storage[target] != null) return error.InvalidLogicalBankState;

        var next = self.state;
        next.last_generation = generation;
        next.pending = .{ .bank = bank, .generation = generation, .phase = .closed };
        self.source_receipt = source;
        self.state = next;
        return .{ .bank = bank, .request = request_byte, .slot = @intCast(target), .generation = generation };
    }

    /// Header availability is status2, which remains unavailable to selectors.
    pub fn loadHeader(self: *Owner, loaded: media.Loaded, request_byte: u8, generation: u64) !HeaderReceipt {
        const source = try self.acceptSource(loaded);
        const pending = self.state.pending orelse return error.NoLogicalBankTransfer;
        if (pending.phase != .closed or request_byte != request(pending.bank) or generation != pending.generation)
            return error.StaleLogicalBankTransfer;
        const pinned = sourceBank(source, pending.bank);
        const bytes = sourceData(loaded, pending.bank);
        if (pinned.request != request_byte or pinned.slot != @as(u8, @intCast(slot(pending.bank)))) return error.SourceIdentityMismatch;
        const va = try self.allocator.dupe(u8, bytes.va);
        errdefer self.allocator.free(va);
        if (!std.mem.eql(u8, &rawDigest(va), &pinned.va_sha256)) return error.SourceIdentityMismatch;

        const target = slot(pending.bank);
        var next = self.state;
        next.pending = .{ .bank = pending.bank, .generation = generation, .phase = .header_loaded };
        next.slots[target] = .{ .status = .header_only, .bank = pending.bank, .generation = generation };
        self.storage[target] = .{ .va = va };
        self.state = next;
        return .{ .bank = pending.bank, .request = request_byte, .slot = @intCast(target), .generation = generation, .va_sha256 = pinned.va_sha256 };
    }

    /// Body bytes are stored at their logical length. Physical DMA tail bytes
    /// are represented only as an unknown count, never synthesized.
    pub fn loadBody(self: *Owner, loaded: media.Loaded, request_byte: u8, generation: u64) !TransferReceipt {
        const source = try self.acceptSource(loaded);
        const pending = self.state.pending orelse return error.NoLogicalBankTransfer;
        if (pending.phase != .header_loaded or request_byte != request(pending.bank) or generation != pending.generation)
            return error.StaleLogicalBankTransfer;
        const pinned = sourceBank(source, pending.bank);
        const bytes = sourceData(loaded, pending.bank);
        const target = slot(pending.bank);
        const retained = self.storage[target] orelse return error.InvalidLogicalBankState;
        if (retained.vb != null or !std.mem.eql(u8, retained.va, bytes.va) or pinned.request != request_byte or pinned.slot != @as(u8, @intCast(target)))
            return error.SourceIdentityMismatch;
        if (pinned.sample_bytes != bytes.vb.len) return error.SourceExtentMismatch;
        const vb = try self.allocator.dupe(u8, bytes.vb);
        errdefer self.allocator.free(vb);
        if (!std.mem.eql(u8, &rawDigest(vb), &pinned.vb_sha256)) return error.SourceIdentityMismatch;

        const body_bytes: u32 = @intCast(vb.len);
        const receipt: TransferReceipt = .{ .bank = pending.bank, .request = request_byte, .slot = @intCast(target), .generation = generation, .va_sha256 = pinned.va_sha256, .vb_sha256 = pinned.vb_sha256, .logical_body_bytes = body_bytes, .dma_tail = tail(vb.len) };
        var next = self.state;
        next.slots[target] = .{ .status = .resident, .bank = pending.bank, .generation = generation };
        next.completed += 1;
        next.pending = null;
        self.storage[target].?.vb = vb;
        self.state = next;
        return receipt;
    }

    /// Borrow the actual verified resident body for this exact transfer.
    pub fn retainedBody(self: Owner, receipt: TransferReceipt) ![]const u8 {
        try validateOwned(self);
        if (receipt.slot >= 2) return error.InvalidLogicalBankSlot;
        const index: usize = receipt.slot;
        const state = self.state.slots[index];
        const bank = state.bank orelse return error.InvalidLogicalBankStorage;
        const source = self.source_receipt orelse return error.InvalidLogicalBankStorage;
        const pinned = sourceBank(source, bank);
        const body = (self.storage[index] orelse return error.InvalidLogicalBankStorage).vb orelse return error.InvalidLogicalBankStorage;
        const expected: TransferReceipt = .{ .bank = bank, .request = request(bank), .slot = @intCast(index), .generation = state.generation, .va_sha256 = pinned.va_sha256, .vb_sha256 = pinned.vb_sha256, .logical_body_bytes = @intCast(body.len), .dma_tail = tail(body.len) };
        if (state.status != .resident or !std.meta.eql(receipt, expected)) return error.StaleLogicalBankTransfer;
        return body;
    }

    pub fn status(self: Owner, slot_index: u8) !Status {
        if (slot_index >= @as(u8, self.state.slots.len)) return error.InvalidLogicalBankSlot;
        try validateOwned(self);
        return self.state.slots[slot_index].status;
    }

    pub fn selectorAvailable(self: Owner, slot_index: u8) !bool {
        return (try self.status(slot_index)) == .resident;
    }
};

fn validateOwned(owner: Owner) !void {
    try validateState(owner.state);
    const occupied = owner.state.completed != 0 or owner.state.pending != null;
    if (!occupied) {
        if (owner.source_receipt != null) return error.InvalidLogicalBankStorage;
    } else {
        const source = owner.source_receipt orelse return error.InvalidLogicalBankStorage;
        try media.validateReceipt(source);
    }
    for (owner.state.slots, owner.storage) |state_slot, stored_opt| {
        if (state_slot.status == .empty) {
            if (stored_opt != null) return error.InvalidLogicalBankStorage;
            continue;
        }
        const stored = stored_opt orelse return error.InvalidLogicalBankStorage;
        const bank = state_slot.bank orelse return error.InvalidLogicalBankStorage;
        const source = owner.source_receipt orelse return error.InvalidLogicalBankStorage;
        const pinned = sourceBank(source, bank);
        if (!std.mem.eql(u8, &rawDigest(stored.va), &pinned.va_sha256)) return error.InvalidLogicalBankStorage;
        switch (state_slot.status) {
            .empty => unreachable,
            .header_only => if (stored.vb != null) return error.InvalidLogicalBankStorage,
            .resident => {
                const vb = stored.vb orelse return error.InvalidLogicalBankStorage;
                if (vb.len != pinned.sample_bytes or !std.mem.eql(u8, &rawDigest(vb), &pinned.vb_sha256)) return error.InvalidLogicalBankStorage;
                const parsed = media.inspectVab(stored.va, vb) catch return error.InvalidLogicalBankStorage;
                if (parsed.programs != pinned.programs or parsed.tones != pinned.tones or parsed.samples != pinned.samples or parsed.sample_bytes != pinned.sample_bytes)
                    return error.InvalidLogicalBankStorage;
            },
        }
    }
}
