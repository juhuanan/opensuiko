//! Pure bounded replay for the initial VA1 field party and Ted's source 3C.
//! This is not an event-history validator or permission to restore a session.
//! Caller independently authenticates the settled town entry, immutable Hero
//! seed, absence of other party operations, and the exact event history. If
//! `ted_add` is present, authenticated_request must be reconstructed from that
//! history and authenticated pinned content, not from the stored ledger.
const field = @import("field");
const entry = @import("entry.zig");
const records = @import("field_records.zig");
const ted = @import("ted_party_add.zig");

pub const Ledger = union(enum) { initial, ted_add: ted.Request };

/// Compare the complete saved state to a fresh replay. Mutated party records,
/// additional party operations, unloaded Ted, or checkpoints other than the
/// single source add are outside this bounded contract.
pub fn validate(hero: field.game_state.Member, loaded: entry.EntryState, saved: records.State, ledger: Ledger, authenticated_request: ?ted.Request) !void {
    var replay = try records.Owner.init(hero, loaded);
    switch (ledger) {
        .initial => if (authenticated_request != null) return error.InvalidTedPartyHistory,
        .ted_add => |stored_request| {
            const request = authenticated_request orelse return error.InvalidTedPartyHistory;
            if (!entry.same(stored_request, request)) return error.InvalidTedPartyHistory;
            const proposal = try ted.propose(replay, request, 1);
            if (proposal.after.count != 2) return error.UnsupportedTedPartyHistory;
            try ted.commit(&replay, request, proposal);
        },
    }
    const rebound = try records.Owner.restore(saved, hero.name);
    if (!entry.same(replay.state, rebound.state)) return error.InvalidTedPartyCheckpoint;
}
