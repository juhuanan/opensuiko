//! Production entry point for the headquarters host.
//!
//! The host's packet loading stays in the owner.  This module makes the caller
//! context explicit: a caller either supplies the live field state, a roster
//! snapshot and recruit bytes, or it gets `MissingRosterContext` instead of a
//! fabricated roster.
const std = @import("std");
const hq = @import("host.zig");
const roster_mod = @import("roster/root.zig");
const party = @import("party_session");
const field = @import("field");
const roster_data = @import("hq_data").roster;

pub const Context = union(enum) {
    ready: struct {
        field_state: *field.State,
        snapshot: party.Snapshot,
        recruit: [hq.flag_slots]u8,
    },
    missing_roster,
    missing_recruit,
    from_saved: struct {
        field_state: *field.State,
        snapshot: hq.Snapshot,
    },
};

/// Build the source-qualified roster from an explicit snapshot.
pub fn rosterFrom(
    allocator: std.mem.Allocator,
    snapshot: party.Snapshot,
    noncombatants: []const roster_mod.roster.NoncombatantState,
) !roster_mod.roster.Roster {
    var packet = try roster_mod.source.load(allocator, roster_data.json);
    defer packet.deinit();
    return roster_mod.roster.Roster.init(packet.value, snapshot, noncombatants);
}

/// An explicit empty baseline.  Callers that have no party snapshot must not
/// present this as a real roster; it exists so the roster factory can be
/// exercised without inventing members.
pub fn emptySnapshot() party.Snapshot {
    return .{
        .entry_id = "empty",
        .content_id = "empty",
        .receipt = "empty",
        .baseline_revision = 0,
    };
}

pub fn open(allocator: std.mem.Allocator, context: Context) !*hq.Host {
    return switch (context) {
        .ready => |config| {
            const roster = try rosterFrom(allocator, config.snapshot, &.{});
            return hq.Host.init(allocator, .{
                .field_state = config.field_state,
                .roster = roster,
                .recruit = config.recruit,
            });
        },
        .missing_roster => error.MissingRosterContext,
        .missing_recruit => error.MissingRecruitContext,
        .from_saved => |saved| {
            var packet = try roster_mod.source.load(allocator, roster_data.json);
            defer packet.deinit();
            const roster = try roster_mod.roster.Roster.restore(allocator, packet.value, saved.snapshot.roster_json);
            const host = try hq.Host.init(allocator, .{
                .field_state = saved.field_state,
                .roster = roster,
                .recruit = saved.snapshot.recruit,
            });
            errdefer host.deinit();
            try host.restore(saved.snapshot);
            return host;
        },
    };
}
