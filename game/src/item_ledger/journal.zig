//! Persisted item/shared publication journal for `item_ledger`.
//!
//! The journal is an *ordered command list*, not an after-state: the host
//! persists it, and a restart replays it against a baseline reconstructed from
//! canonical data.  IDs, receipts and revisions are host-owned.  Strings are
//! borrowed from the encoded document; the parsed document must outlive the
//! replay (the same contract as `party_session.decodeResult`).
const std = @import("std");

pub const schema = "suikoden-item-ledger-journal/1";
pub const max_commands = 32;

pub const Kind = enum {
    give,
    swap,
    equip,
    unequip,
    discard,
    deposit,
    withdraw,
    shared_acquire,
    shared_remove,
    apply_fragment,
    consume,
};

/// One ordinary item operation.  A command names its owners by identity and its
/// bag entries by slot index, exactly like the existing `party_session.Command`.
pub const Command = struct {
    kind: Kind,
    /// Owning member for every single-member operation.
    member: ?[]const u8 = null,
    /// Second member for `give`, `swap` and the fragment target.
    other: ?[]const u8 = null,
    slot: ?u8 = null,
    other_slot: ?u8 = null,
    /// Reviewed packet identity (stable id) for identity-addressed operations.
    item: ?[]const u8 = null,
    /// Source-qualified shared operation id for the ledger operations.
    operation: ?[]const u8 = null,
    /// Character type mask from the host's source-qualified character record.
    character_type: ?u8 = null,
    /// Fragment element change confirmation.
    replace: bool = false,
};

pub const Journal = struct {
    schema: []const u8 = schema,
    entry_id: []const u8,
    content_id: []const u8,
    receipt: []const u8,
    baseline_revision: u64,
    commands: []const Command,
};

/// The persisted document has the same shape; the alias documents intent.
pub const Wire = Journal;

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Wire) {
    if (bytes.len > 256 * 1024) return error.JournalTooLarge;
    return std.json.parseFromSlice(Wire, allocator, bytes, .{ .allocate = .alloc_always });
}

pub fn encode(allocator: std.mem.Allocator, journal: Journal) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, journal, .{ .emit_null_optional_fields = false });
}

/// Bind a decoded document to the replay contract: the schema must match and
/// every command must carry exactly the fields its kind requires.
pub fn fromWire(wire: Wire) !Journal {
    try validate(wire);
    return wire;
}

pub fn validate(journal: Journal) !void {
    if (!std.mem.eql(u8, journal.schema, schema)) return error.InvalidJournalSchema;
    if (journal.entry_id.len == 0 or journal.content_id.len == 0 or journal.receipt.len == 0)
        return error.InvalidJournal;
    if (journal.commands.len == 0 or journal.commands.len > max_commands) return error.InvalidJournal;
    for (journal.commands) |command| {
        const member_required = command.member != null and command.member.?.len > 0;
        switch (command.kind) {
            .give => {
                if (!member_required or command.other == null or command.slot == null) return error.InvalidCommand;
                if (command.item != null or command.other_slot != null or command.character_type != null)
                    return error.InvalidCommand;
            },
            .swap => {
                if (!member_required or command.other == null or command.slot == null or
                    command.other_slot == null) return error.InvalidCommand;
                if (command.item != null or command.character_type != null) return error.InvalidCommand;
            },
            .equip => {
                if (!member_required or command.slot == null or command.item == null or
                    command.character_type == null) return error.InvalidCommand;
                if (command.other != null or command.other_slot != null or command.operation != null)
                    return error.InvalidCommand;
            },
            .unequip => {
                if (!member_required or command.slot == null) return error.InvalidCommand;
                if (command.other != null or command.item != null or command.operation != null or
                    command.other_slot != null or command.character_type != null) return error.InvalidCommand;
            },
            .discard, .deposit, .consume => {
                if (!member_required or command.slot == null) return error.InvalidCommand;
                if (command.other != null or command.item != null or command.operation != null or
                    command.other_slot != null or command.character_type != null) return error.InvalidCommand;
            },
            .withdraw => {
                if (!member_required or command.item == null) return error.InvalidCommand;
                if (command.other != null or command.slot != null or command.operation != null or
                    command.other_slot != null or command.character_type != null) return error.InvalidCommand;
            },
            .shared_acquire, .shared_remove => {
                if (command.operation == null or command.item == null) return error.InvalidCommand;
                if (command.member != null or command.other != null or command.slot != null or
                    command.other_slot != null or command.character_type != null) return error.InvalidCommand;
            },
            .apply_fragment => {
                if (!member_required or command.other == null or command.slot == null)
                    return error.InvalidCommand;
                if (command.item != null or command.operation != null or command.other_slot != null or
                    command.character_type != null) return error.InvalidCommand;
            },
        }
    }
}
