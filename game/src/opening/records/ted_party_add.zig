//! Owner-side staging for VA1 room2 entity2 `3C 6C` (file offset 0x3d1a6).
//! The host MUST independently validate the retained typed VM effect, pinned
//! source mapping, content, program, instance and batch before invoking this.
//! This module does not prove event provenance or acknowledge the VM.
const std = @import("std");
const records = @import("field_records.zig");
const entry = @import("entry.zig");

/// Copied from a host-validated pending VM effect, not a standalone authority.
pub const Request = struct {
    content_id: []const u8,
    content_sha256: []const u8,
    program: []const u8,
    instance: u64,
    batch: u64,
    origin: u16,
    source_offset: u32,
    source_character_id: u8,
};
pub const Proposal = struct {
    request: Request,
    before: records.State,
    after: records.State,
    active_ids: [6]u8,
    area_party: [6]u8,
};
fn checkRequest(request: Request) !void {
    if (!std.mem.eql(u8, request.content_id, "va1_room2_field_events") or
        request.content_sha256.len != 64 or
        !std.mem.eql(u8, request.program, "va1_r02_e02_ordinary") or
        request.instance == 0 or request.batch == 0 or request.source_offset != 0x3d1a6 or
        request.source_character_id != 108) return error.InvalidTedAddRequest;
}
/// Caller validates actual source program and exact pending batch before staging.
/// No party slice is retained: return values own their arrays.
pub fn propose(owner: records.Owner, request: Request, checkpoint: u64) !Proposal {
    try checkRequest(request);
    const operation = try owner.proposeAdd(108, checkpoint);
    const state = operation.after;
    var ids: [6]u8 = @splat(0xff);
    for (state.order[0..state.count], 0..) |slot, i| ids[i] = state.entry.slots[slot];
    return .{ .request = request, .before = operation.before, .after = state, .active_ids = ids, .area_party = state.area_party orelse return error.InvalidTedAddRequest };
}
/// Commit only to a staged owner. Host must stage VM/story and publish together.
/// Rebind field Progress.party after copying or moving the staged owner.
pub fn commit(owner: *records.Owner, current_request: Request, proposal: Proposal) !void {
    if (!entry.same(owner.state, proposal.before) or !entry.same(current_request, proposal.request)) return error.StaleTedAdd;
    const canonical = try propose(owner.*, current_request, proposal.after.checkpoint);
    if (!entry.same(canonical, proposal)) return error.InvalidTedAddProposal;
    const operation = try owner.proposeAdd(108, proposal.after.checkpoint);
    try owner.commitAdd(operation);
}
