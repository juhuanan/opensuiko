//! Source-byte verification for the two bootstrap VABs and four SEQ handles.
//! No audio playback, decoding, export, or sequence-event execution occurs here.
const std = @import("std");

pub const BankId = enum { stay, orch };
pub const BankBytes = struct { va: []const u8, vb: []const u8 };
pub const Inputs = struct { stay: BankBytes, orch: BankBytes, seq: []const u8 };

pub const BankReceipt = struct {
    id: BankId,
    request: u8,
    slot: u8,
    va_sha256: [64]u8,
    vb_sha256: [64]u8,
    programs: u16,
    tones: u16,
    samples: u16,
    sample_bytes: u32,
};

pub const SequenceSemantics = enum { unsupported };
pub const SequenceHandle = struct {
    index: u8,
    offset: u32,
    length: u32,
    bank_slot: u8,
    ppqn: u16,
    microseconds_per_quarter: u24,
    semantics: SequenceSemantics = .unsupported,
};

pub const Receipt = struct {
    stay: BankReceipt,
    orch: BankReceipt,
    sequence_sha256: [64]u8,
    sequences: [4]SequenceHandle,
};

/// Owns immutable copies of the caller-provided files after they pass verify.
/// The caller retains no mutable alias to these copied buffers.
pub const Loaded = struct {
    allocator: std.mem.Allocator,
    stay: BankBytes,
    orch: BankBytes,
    seq: []u8,
    receipt: Receipt,

    pub fn deinit(self: *Loaded) void {
        self.allocator.free(self.stay.va);
        self.allocator.free(self.stay.vb);
        self.allocator.free(self.orch.va);
        self.allocator.free(self.orch.vb);
        self.allocator.free(self.seq);
        self.* = undefined;
    }

    pub fn bankBytes(self: Loaded, id: BankId) BankBytes {
        return switch (id) {
            .stay => self.stay,
            .orch => self.orch,
        };
    }

    pub fn sequenceBytes(self: Loaded, index: u8) ![]const u8 {
        const ordinal: usize = index;
        if (ordinal >= self.receipt.sequences.len) return error.InvalidSequenceHandle;
        const handle = self.receipt.sequences[ordinal];
        if (handle.index != index) return error.InvalidSequenceHandle;
        const start: usize = handle.offset;
        const length: usize = handle.length;
        if (start > self.seq.len or length > self.seq.len - start) return error.InvalidSequenceHandle;
        return self.seq[start .. start + length];
    }
};

const BankPin = struct {
    id: BankId,
    request: u8,
    slot: u8,
    va_size: usize,
    vb_size: usize,
    va_sha: []const u8,
    vb_sha: []const u8,
};

const stay_pin = BankPin{
    .id = .stay,
    .request = 0x21,
    .slot = 0,
    .va_size = 5152,
    .vb_size = 208768,
    .va_sha = "95051a43cf81d4303633d91379a08e45e13f03e33320bb7b14d2b3b666109952",
    .vb_sha = "10bc5bdeb7fb861208b1f1473cdc28d489fad44a00a5aa484ca2f1bb6b5815bd",
};
const orch_pin = BankPin{
    .id = .orch,
    .request = 0x25,
    .slot = 1,
    .va_size = 8736,
    .vb_size = 108784,
    .va_sha = "cb4be9f6e3a86d522a55f6f62ccb0df8a0dc74d9adc4552fee23fa34af160fea",
    .vb_sha = "b44df918d55cd6c0453acdffa003781255d15f1f290163d830bb1ecf1b6c4979",
};
const seq_size = 71162;
const seq_sha = "ad0bead9bea912e046ddd2947e4c2eaca747bb0af6be1e9baf8723abb3d068c8";
const seq_offsets = [_]usize{ 0, 0x3dc4, 0x8630, 0xad96 };
const seq_slots = [_]u8{ 1, 1, 2, 2 };

fn digest(bytes: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

fn u16le(bytes: []const u8, at: usize) !u16 {
    if (at > bytes.len or bytes.len - at < 2) return error.TruncatedVab;
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

/// Validate VAB structure without decoding samples. Hash/length pins are
/// checked by verifyBank before this parser is allowed to produce a receipt.
pub fn inspectVab(va: []const u8, vb: []const u8) !struct { programs: u16, tones: u16, samples: u16, sample_bytes: u32 } {
    if (va.len < 0x820 or !std.mem.eql(u8, va[0..4], "pBAV")) return error.InvalidVabHeader;
    const programs = try u16le(va, 0x12);
    const tones = try u16le(va, 0x14);
    const samples = try u16le(va, 0x16);
    if (programs > 128 or samples > 254) return error.InvalidVabCounts;

    var occupied: u16 = 0;
    var tone_sum: u32 = 0;
    var rank: usize = 0;
    for (0..128) |program| {
        const n = va[0x20 + program * 16];
        if (n == 0) continue;
        occupied += 1;
        if (n > 16) return error.InvalidVabProgram;
        tone_sum += n;
        const block = 0x820 + rank * 0x200;
        const block_end = block + 0x200;
        if (block_end > va.len) return error.TruncatedVab;
        for (0..n) |tone_index| {
            const tone = block + tone_index * 32;
            const owner = try u16le(va, tone + 0x14);
            const sample = try u16le(va, tone + 0x16);
            const owner_index: i16 = @bitCast(owner);
            if (owner_index < 0 or @as(usize, @intCast(owner_index)) != program or sample == 0 or sample > samples)
                return error.InvalidVabToneReference;
        }
        rank += 1;
    }
    if (occupied != programs or tone_sum != tones) return error.InvalidVabCounts;

    const table = 0x820 + @as(usize, programs) * 0x200;
    const table_bytes = (@as(usize, samples) + 1) * 2;
    if (table > va.len or va.len - table < table_bytes) return error.TruncatedVab;
    if (try u16le(va, table) != 0) return error.InvalidVabSampleTable;
    var total: usize = 0;
    const sample_count: usize = samples;
    for (1..sample_count + 1) |index| {
        const extent = @as(usize, try u16le(va, table + index * 2)) * 8;
        if (extent % 16 != 0) return error.InvalidVabSampleTable;
        total = std.math.add(usize, total, extent) catch return error.InvalidVabSampleTable;
    }
    if (total != vb.len or total > std.math.maxInt(u32)) return error.InvalidVabExtent;
    return .{ .programs = programs, .tones = tones, .samples = samples, .sample_bytes = @intCast(total) };
}

fn verifyBank(pin: BankPin, bytes: BankBytes) !BankReceipt {
    if (bytes.va.len != pin.va_size or bytes.vb.len != pin.vb_size) return error.SourceExtentMismatch;
    const va_hash = digest(bytes.va);
    const vb_hash = digest(bytes.vb);
    if (!std.mem.eql(u8, &va_hash, pin.va_sha) or !std.mem.eql(u8, &vb_hash, pin.vb_sha)) return error.SourceHashMismatch;
    const parsed = try inspectVab(bytes.va, bytes.vb);
    return .{ .id = pin.id, .request = pin.request, .slot = pin.slot, .va_sha256 = va_hash, .vb_sha256 = vb_hash, .programs = parsed.programs, .tones = parsed.tones, .samples = parsed.samples, .sample_bytes = parsed.sample_bytes };
}

fn be16(bytes: []const u8, at: usize) u16 {
    return (@as(u16, bytes[at]) << 8) | bytes[at + 1];
}
fn be24(bytes: []const u8, at: usize) u24 {
    return (@as(u24, bytes[at]) << 16) | (@as(u24, bytes[at + 1]) << 8) | bytes[at + 2];
}

fn verifySequence(bytes: []const u8) !struct { hash: [64]u8, handles: [4]SequenceHandle } {
    if (bytes.len != seq_size) return error.SequenceExtentMismatch;
    const hash = digest(bytes);
    if (!std.mem.eql(u8, &hash, seq_sha)) return error.SourceHashMismatch;
    var handles: [4]SequenceHandle = undefined;
    for (seq_offsets, 0..) |offset, index| {
        const end = if (index + 1 < seq_offsets.len) seq_offsets[index + 1] else bytes.len;
        if (end <= offset or end - offset < 16) return error.InvalidSequenceExtent;
        const header = bytes[offset .. offset + 16];
        if (!std.mem.eql(u8, header[0..4], "pQES") or !std.mem.eql(u8, header[4..8], "\x00\x00\x00\x01")) return error.InvalidSequenceHeader;
        const ppqn = be16(header, 8);
        const mpqn = be24(header, 10);
        if (ppqn == 0 or mpqn == 0) return error.InvalidSequenceHeader;
        handles[index] = .{ .index = @intCast(index), .offset = @intCast(offset), .length = @intCast(end - offset), .bank_slot = seq_slots[index], .ppqn = ppqn, .microseconds_per_quarter = mpqn };
    }
    return .{ .hash = hash, .handles = handles };
}

/// Validate serialized metadata against the pinned source receipt. This does
/// not replace rebinding and hashing the actual source bytes after restore.
pub fn validateReceipt(receipt: Receipt) !void {
    const expected: Receipt = .{
        .stay = .{ .id = .stay, .request = 0x21, .slot = 0, .va_sha256 = "95051a43cf81d4303633d91379a08e45e13f03e33320bb7b14d2b3b666109952".*, .vb_sha256 = "10bc5bdeb7fb861208b1f1473cdc28d489fad44a00a5aa484ca2f1bb6b5815bd".*, .programs = 5, .tones = 64, .samples = 44, .sample_bytes = 208768 },
        .orch = .{ .id = .orch, .request = 0x25, .slot = 1, .va_sha256 = "cb4be9f6e3a86d522a55f6f62ccb0df8a0dc74d9adc4552fee23fa34af160fea".*, .vb_sha256 = "b44df918d55cd6c0453acdffa003781255d15f1f290163d830bb1ecf1b6c4979".*, .programs = 12, .tones = 16, .samples = 13, .sample_bytes = 108784 },
        .sequence_sha256 = "ad0bead9bea912e046ddd2947e4c2eaca747bb0af6be1e9baf8723abb3d068c8".*,
        .sequences = .{
            .{ .index = 0, .offset = 0, .length = 15812, .bank_slot = 1, .ppqn = 480, .microseconds_per_quarter = 500000 },
            .{ .index = 1, .offset = 15812, .length = 18540, .bank_slot = 1, .ppqn = 480, .microseconds_per_quarter = 521739 },
            .{ .index = 2, .offset = 34352, .length = 10086, .bank_slot = 2, .ppqn = 480, .microseconds_per_quarter = 717703 },
            .{ .index = 3, .offset = 44438, .length = 26724, .bank_slot = 2, .ppqn = 480, .microseconds_per_quarter = 525854 },
        },
    };
    if (!std.meta.eql(receipt, expected)) return error.InvalidSourceReceipt;
}

/// All input validation completes before a receipt is returned. Nothing is
/// published or mutated on failure; sequence event semantics remain unsupported.
pub fn verify(inputs: Inputs) !Receipt {
    const stay = try verifyBank(stay_pin, inputs.stay);
    const orch = try verifyBank(orch_pin, inputs.orch);
    const sequence = try verifySequence(inputs.seq);
    return .{ .stay = stay, .orch = orch, .sequence_sha256 = sequence.hash, .sequences = sequence.handles };
}

/// Verifies the input and the owned copies; failed allocations or validation
/// release every earlier copy.
pub fn load(allocator: std.mem.Allocator, inputs: Inputs) !Loaded {
    _ = try verify(inputs);
    const stay_va = try allocator.dupe(u8, inputs.stay.va);
    errdefer allocator.free(stay_va);
    const stay_vb = try allocator.dupe(u8, inputs.stay.vb);
    errdefer allocator.free(stay_vb);
    const orch_va = try allocator.dupe(u8, inputs.orch.va);
    errdefer allocator.free(orch_va);
    const orch_vb = try allocator.dupe(u8, inputs.orch.vb);
    errdefer allocator.free(orch_vb);
    const seq = try allocator.dupe(u8, inputs.seq);
    errdefer allocator.free(seq);
    const receipt = try verify(.{ .stay = .{ .va = stay_va, .vb = stay_vb }, .orch = .{ .va = orch_va, .vb = orch_vb }, .seq = seq });
    try validateReceipt(receipt);
    return .{ .allocator = allocator, .stay = .{ .va = stay_va, .vb = stay_vb }, .orch = .{ .va = orch_va, .vb = orch_vb }, .seq = seq, .receipt = receipt };
}
