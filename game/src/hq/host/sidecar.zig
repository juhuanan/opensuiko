const std = @import("std");
const owner_state = @import("owner_state_hq");
const hq_host = @import("../host.zig");
const roster_mod = @import("../roster/root.zig");
const tablet_mod = @import("../tablet/root.zig");
const results = @import("campaign_policies").mode_result;

const Host = hq_host.Host;

fn copyFields(comptime Target: type, source: anytype) Target {
    var out: Target = undefined;
    inline for (@typeInfo(Target).@"struct".fields) |field| {
        @field(out, field.name) = @field(source, field.name);
    }
    return out;
}

/// The caller owns `roster_json`; the world-session capture passes its own
/// arena so the sidecar never leaks into the session allocator.
pub fn captureOwnerState(self: *Host, allocator: std.mem.Allocator) !owner_state.HqState {
    const snapshot = try capture(self, allocator);
    return .{
        .content_sha256 = snapshot.content_sha256,
        .recruit = snapshot.recruit,
        .roster_json = snapshot.roster_json,
        .tablet = if (snapshot.tablet) |tablet| copyFields(owner_state.Tablet, tablet) else null,
        .mode = copyFields(owner_state.ModeFacts, snapshot.mode),
        .screen = @fromBackingInt(@intCast(@backingInt(snapshot.screen))),
        .room = snapshot.room,
        .cursor = snapshot.cursor,
        .revision = snapshot.revision,
    };
}

pub fn applyOwnerState(self: *Host, state: owner_state.HqState) !void {
    try restore(self, .{
        .content_sha256 = state.content_sha256,
        .recruit = state.recruit,
        .roster_json = state.roster_json,
        .tablet = if (state.tablet) |tablet| copyFields(tablet_mod.Snapshot, tablet) else null,
        .mode = copyFields(hq_host.ModeFacts, state.mode),
        .screen = @fromBackingInt(@intCast(@backingInt(state.screen))),
        .room = state.room,
        .cursor = state.cursor,
        .revision = state.revision,
    });
}

pub fn capture(self: *Host, allocator: std.mem.Allocator) !hq_host.Snapshot {
    const roster_bytes = try self.roster.save(allocator);
    return .{
        .content_sha256 = &self.content_hex,
        .recruit = self.recruit,
        .roster_json = roster_bytes,
        .tablet = if (self.tablet) |*view| view.snapshot() else null,
        .mode = self.mode_facts,
        .screen = self.screen,
        .room = self.room,
        .cursor = self.cursor,
        .revision = self.revision,
    };
}

/// Restore a sidecar into this host.  Every component validates itself: a
/// different content identity, a different roster packet, a stale tablet
/// roster digest or a tampered recruit byte is a typed refusal, never a
/// silent reset to a default state.
pub fn restore(self: *Host, snapshot: hq_host.Snapshot) !void {
    if (!std.mem.eql(u8, snapshot.schema, hq_host.sidecar_schema)) return error.UnsupportedHqSidecar;
    if (snapshot.version != hq_host.sidecar_version) return error.UnsupportedHqSidecar;
    if (!std.mem.eql(u8, snapshot.content_sha256, &self.content_hex)) return error.HqContentMismatch;
    for (snapshot.recruit) |byte| if (byte & 0xFC != 0) return error.InvalidRecruitByte;
    var next = self.*;
    next.restore_arena = std.heap.ArenaAllocator.init(self.allocator);
    errdefer next.restore_arena.deinit();
    next.roster = try roster_mod.roster.Roster.restore(next.restore_arena.allocator(), next.roster_packet.value, snapshot.roster_json);
    next.recruit = snapshot.recruit;
    next.mode_facts = snapshot.mode;
    next.result_host = try results.Host.init(next.modeProjection(), next.content_sha);
    next.revision = snapshot.revision;
    next.room = snapshot.room;
    next.screen = snapshot.screen;
    next.tablet = null;
    if (snapshot.tablet) |stored| {
        next.tablet = try tablet_mod.View.restore(stored, next.recruit);
    } else if (snapshot.screen == .tablet) return error.InvalidHqSidecar;
    try next.validateInitial();
    try next.rebuild();
    if (snapshot.cursor < next.interaction_count) next.cursor = snapshot.cursor;
    self.restore_arena.deinit();
    self.* = next;
}
