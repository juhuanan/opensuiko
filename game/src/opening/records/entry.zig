//! VA1 entry resources: standalone state and source-pinned metadata.
const std = @import("std");
const facts = @import("sources.zig");
pub const Source = facts.Source;
pub const sources = facts.sources;
pub const sourceFor = facts.sourceFor;
pub const same = facts.same;

pub const EntryPending = struct { source_id: u8, slot: u8 };
/// The resource owner must validate the original resource before acknowledging it.
pub const EntryAck = struct {
    source_id: u8,
    expected_revision: u64,
    receipt: u64,
    checkpoint: u64,
};

pub const EntryState = struct {
    slots: [6]u8,
    order: [6]u8,
    count: u8,
    loaded: [110]bool = @splat(false),
    init_config: u8,
    pending: ?EntryPending = null,
    revision: u64 = 0,
    receipt: u64 = 0,
    checkpoint: u64 = 0,
};
pub const EntryResource = struct {
    character_id: u8,
    id: []const u8,
    source: struct { file: []const u8, lba: u32, size: u32, sha256: []const u8 },
    clips: [4]struct { flags: u8, ticks: [4]u16, bounds: [4]struct { width: u16, height: u16 } },
    portrait_offset: u32,
    portrait_container_bytes: u32,
    portrait_container_sha256: []const u8,
    portrait_decoded_sha256: []const u8,
    palette_offset: u32,
    palette_sha256: []const u8,
};
pub const entry_resource_json = @import("opening_assets").party_setup.entry.json;
pub const EntryResources = struct { schema: []const u8, initial_config: u8, resources: [4]EntryResource };
/// Input metadata bytes and the parsed owner must remain alive through acknowledgement.
pub const OpenedEntryResources = struct {
    bytes: []const u8,
    parsed: std.json.Parsed(EntryResources),
    pub fn deinit(self: *OpenedEntryResources) void {
        self.parsed.deinit();
    }
};
pub fn openEntryResources(allocator: std.mem.Allocator, bytes: []const u8) !OpenedEntryResources {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), "7ae802773855273267cc8e2da18780345148fb7ea4a571371f167637788f8c9c")) return error.UntrustedEntryResources;
    const parsed = try std.json.parseFromSlice(EntryResources, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.schema, "suikoden-va1-entry-resources/1") or parsed.value.initial_config != 0) return error.UntrustedEntryResources;
    for (parsed.value.resources, [_]u8{ 108, 6, 1, 2 }) |record, id| {
        const expected = try sourceFor(id);
        if (record.character_id != id or !std.mem.eql(u8, record.id, expected.character_id) or
            !std.mem.eql(u8, record.source.sha256, expected.resource_sha256) or
            record.source.lba != expected.resource_lba or record.source.size != expected.resource_size) return error.UntrustedEntryResources;
    }
    return .{ .bytes = bytes, .parsed = parsed };
}
pub const StandaloneEntryRequest = struct { before: EntryState, source: Source, slot: u8, checkpoint: u64 };
pub const Entry = struct {
    state: EntryState,

    pub fn init(slots: [6]u8, order: [6]u8, count: u8, init_config: u8) !Entry {
        if (!std.mem.eql(u8, &slots, &.{ 8, 0xff, 0xff, 0xff, 0xff, 0xff }) or
            !std.mem.eql(u8, &order, &.{ 0, 0xfe, 0xfe, 0xfe, 0xfe, 0xfe }) or count != 1)
            return error.InvalidBootParty;
        var state: EntryState = .{ .slots = slots, .order = order, .count = count, .init_config = init_config };
        state.loaded[8] = true;
        return .{ .state = state };
    }

    pub fn restore(state: EntryState) !Entry {
        if (state.count != 1 or !std.mem.eql(u8, &state.order, &.{ 0, 0xfe, 0xfe, 0xfe, 0xfe, 0xfe }) or
            state.slots[0] != 8 or !state.loaded[8] or state.receipt != state.revision or
            (state.revision == 0) != (state.checkpoint == 0) or state.checkpoint < state.revision) return error.InvalidEntryState;
        var seen: [110]bool = @splat(false);
        for (state.slots) |id| {
            if (id == 0xff) continue;
            if (id >= 110 or seen[id] or !state.loaded[id]) return error.InvalidEntryState;
            if (id != 8) _ = try sourceFor(id);
            seen[id] = true;
        }
        if (!std.mem.eql(bool, &seen, &state.loaded)) return error.InvalidEntryState;
        var loaded_count: u64 = 0;
        var ended = false;
        for ([_]u8{ 108, 6, 1, 2 }, 0..) |id, index| {
            const actual = state.slots[index + 1];
            if (actual == 0xff) {
                ended = true;
                continue;
            }
            if (ended or actual != id) return error.InvalidEntryState;
            loaded_count += 1;
        }
        if (state.slots[5] != 0xff or state.revision != loaded_count * 2 + @intFromBool(state.pending != null) or
            (state.init_config & 0x80 != 0 and (loaded_count != 0 or state.pending != null))) return error.InvalidEntryState;
        if (state.pending) |pending| {
            if (state.init_config & 0x80 != 0 or pending.source_id >= 110 or pending.slot >= 6 or state.slots[pending.slot] != 0xff) return error.InvalidEntryState;
            const expected = for ([_]u8{ 108, 6, 1, 2 }) |id| {
                if (!seen[id]) break id;
            } else return error.InvalidEntryState;
            if (pending.source_id != expected or std.mem.indexOfScalar(u8, &state.slots, 0xff).? != pending.slot) return error.InvalidEntryState;
        }
        return .{ .state = state };
    }

    pub fn propose(self: Entry, checkpoint: u64) !?StandaloneEntryRequest {
        if (checkpoint <= self.state.checkpoint) return error.InvalidCheckpoint;
        if (self.state.pending != null) return error.EntryLoadPending;
        if (self.state.init_config & 0x80 != 0 or self.state.count >= 6) return null;
        for ([_]u8{ 108, 6, 1, 2 }) |id| {
            if (std.mem.indexOfScalar(u8, &self.state.slots, id) != null) continue;
            const slot = std.mem.indexOfScalar(u8, &self.state.slots, 0xff) orelse return null;
            return .{ .before = self.state, .source = try sourceFor(id), .slot = @intCast(slot), .checkpoint = checkpoint };
        }
        return null;
    }
    pub fn start(self: *Entry, request: StandaloneEntryRequest) !void {
        if (!same(self.state, request.before)) return error.StaleBeforeState;
        const canonical = (try self.propose(request.checkpoint)) orelse return error.InvalidEntryRequest;
        if (!same(canonical, request)) return error.InvalidEntryRequest;
        var next = self.state;
        next.pending = .{ .source_id = request.source.operand, .slot = request.slot };
        next.revision = try std.math.add(u64, next.revision, 1);
        next.receipt = try std.math.add(u64, next.receipt, 1);
        next.checkpoint = request.checkpoint;
        self.state = next;
    }
    pub fn acknowledge(self: *Entry, ack: EntryAck, resources: *const OpenedEntryResources) !void {
        const pending = self.state.pending orelse return error.EntryLoadUnavailable;
        if (ack.expected_revision != self.state.revision or ack.receipt != self.state.receipt) return error.StaleBeforeState;
        if (ack.checkpoint <= self.state.checkpoint) return error.InvalidCheckpoint;
        const source = try sourceFor(pending.source_id);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(resources.bytes, &digest, .{});
        if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), "7ae802773855273267cc8e2da18780345148fb7ea4a571371f167637788f8c9c")) return error.UntrustedEntryResources;
        const canonical = try std.json.parseFromSlice(EntryResources, std.heap.page_allocator, resources.bytes, .{ .allocate = .alloc_always });
        defer canonical.deinit();
        if (!same(canonical.value, resources.parsed.value)) return error.UntrustedEntryResources;
        const record = for (resources.parsed.value.resources) |candidate| {
            if (candidate.character_id == pending.source_id) break candidate;
        } else return error.ResourceIdentityMismatch;
        if (ack.source_id != source.operand or !std.mem.eql(u8, record.source.sha256, source.resource_sha256) or
            record.source.lba != source.resource_lba or record.source.size != source.resource_size) return error.ResourceIdentityMismatch;
        var next = self.state;
        next.slots[pending.slot] = pending.source_id;
        next.loaded[pending.source_id] = true;
        next.pending = null;
        next.revision = try std.math.add(u64, next.revision, 1);
        next.receipt = try std.math.add(u64, next.receipt, 1);
        next.checkpoint = ack.checkpoint;
        self.state = next;
    }
};
