//! Host-side validation for ordinary preparation, before canonical publication.
const std = @import("std");
const battle = @import("battle");
const journey = @import("journey");
const party = @import("party_session");

pub const Ledger = struct {
    schema: []const u8 = "suikoden-party-ledger/1",
    content_sha256: [64]u8,
    catalogue_sha256: [64]u8 = "32c43243829886c69de039789bb76cf3be1a630cfdb50fed5c19967bebeb948a".*,
    revision: u64 = 0,
    last_receipt: ?u64 = null,
    extras: [party.max_owned]?party.CharacterExtra = @splat(null),
    shared: [7]?[]const u8 = @splat(null),
};

pub fn decodeCatalogue(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(party.catalogue.Catalogue) {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), "32c43243829886c69de039789bb76cf3be1a630cfdb50fed5c19967bebeb948a")) return error.PartyCatalogueMismatch;
    return party.catalogue.decode(allocator, bytes);
}

// The earlier prototype never applied weapon pieces or represented locked slots.
// Only source seeds proving those fields empty may migrate without a sidecar.
pub fn legacyLedger(combat: battle.State, reserves: journey.Reserves, catalogue: party.catalogue.Catalogue, content_sha256: [64]u8) !Ledger {
    var result: Ledger = .{ .content_sha256 = content_sha256 };
    var index: usize = 0;
    for (0..combat.partyCount()) |i| {
        if (index >= result.extras.len) return error.RosterFull;
        result.extras[index] = try legacyExtra(combat.ownedMember(i), catalogue);
        index += 1;
    }
    for (reserves) |maybe| if (maybe) |owned| {
        if (index >= result.extras.len) return error.RosterFull;
        result.extras[index] = try legacyExtra(owned, catalogue);
        index += 1;
    };
    return result;
}

pub fn legacyExtra(owned: battle.OwnedMember, catalogue: party.catalogue.Catalogue) !party.CharacterExtra {
    const character = for (catalogue.characters) |candidate| {
        if (std.mem.eql(u8, candidate.id, owned.id)) break candidate;
    } else return error.UnknownCharacter;
    if (character.seed.weapon_element != .none) return error.UnsupportedLegacyCharacterExtra;
    for (character.seed.weapon_fragments) |count| if (count != 0) return error.UnsupportedLegacyCharacterExtra;
    for (character.seed.inventory) |item| if (item.locked) return error.UnsupportedLegacyCharacterExtra;
    return .{ .member_id = owned.id };
}

// IDs and receipts are host-owned; the journal is never an authority for them.
pub fn baseline(combat: battle.State, reserves: journey.Reserves, ledger: Ledger, entry: []const u8, content: []const u8, receipt: []const u8) !party.Snapshot {
    if (entry.len == 0 or content.len != 64 or receipt.len == 0 or combat.partyCount() == 0 or combat.partyCount() > 6) return error.InvalidPartyEntry;
    if (!std.mem.eql(u8, ledger.schema, "suikoden-party-ledger/1") or !std.mem.eql(u8, &ledger.content_sha256, content) or !std.mem.eql(u8, &ledger.catalogue_sha256, "32c43243829886c69de039789bb76cf3be1a630cfdb50fed5c19967bebeb948a")) return error.InvalidPartyEntry;
    // shortcut: shared operations remain unavailable until source event bindings are admitted.
    for (ledger.shared) |item| if (item != null) return error.PartyServiceUnavailable;
    if (ledger.last_receipt) |last| if (last > ledger.revision) return error.InvalidPartyRevision;
    var result: party.Snapshot = .{ .entry_id = entry, .content_id = content, .receipt = receipt, .baseline_revision = ledger.revision, .storage = combat.progress.storage, .shared = ledger.shared };
    var count: usize = 0;
    for (0..combat.partyCount()) |index| {
        const owned = combat.ownedMember(index);
        result.members[count] = owned;
        result.active[index] = owned.id;
        result.forced[index] = owned.id;
        result.eligible[count] = true;
        count += 1;
    }
    for (reserves) |maybe| if (maybe) |owned| {
        if (count == result.members.len) return error.RosterFull;
        result.members[count] = owned;
        count += 1;
    };
    for (result.members[0..count], 0..) |maybe, index| {
        const owned = maybe.?;
        const extra = for (ledger.extras) |candidate| {
            if (candidate) |value| if (std.mem.eql(u8, value.member_id, owned.id)) break value;
        } else return error.MissingCharacterExtra;
        result.extras[index] = extra;
    }
    for (ledger.extras, 0..) |maybe, index| if (maybe) |extra| {
        for (ledger.extras[0..index]) |previous| if (previous) |value| {
            if (std.mem.eql(u8, value.member_id, extra.member_id)) return error.InvalidCharacterExtra;
        };
        var matches: usize = 0;
        for (result.members[0..count]) |member| if (std.mem.eql(u8, member.?.id, extra.member_id)) {
            matches += 1;
        };
        if (matches != 1) return error.InvalidCharacterExtra;
    };
    _ = try party.Session.init(combat, result, .{});
    return result;
}

pub fn rebindLedger(ledger: *Ledger, combat: battle.State, reserves: journey.Reserves, content: []const u8) !void {
    _ = try baseline(combat, reserves, ledger.*, "world_pause_preparation", content, "1");
    ledger.schema = "suikoden-party-ledger/1";
    for (&ledger.extras) |*maybe| if (maybe.*) |*extra| {
        const profile = combat.content.partyProfile(extra.member_id) orelse return error.UnknownCharacter;
        extra.member_id = profile.id;
    };
}

// Inventory and equipment are available from the pause menu; services and
// roster/story operations need separate source-qualified admission.
pub fn authorizePause(result: party.Result) !void {
    for (result.commands) |maybe| if (maybe) |command| switch (command) {
        .give, .swap, .discard, .equip => {},
        else => return error.PartyServiceUnavailable,
    };
}

pub const Change = struct { snapshot: party.Snapshot, revision: u64, receipt: u64 };
pub fn replayPause(combat: battle.State, reserves: journey.Reserves, ledger: Ledger, content: []const u8, receipt: []const u8, journal: party.Result) !Change {
    const number = std.fmt.parseInt(u64, receipt, 10) catch return error.InvalidPartyReceipt;
    var digits: [20]u8 = undefined;
    const canonical = std.fmt.bufPrint(&digits, "{d}", .{number}) catch return error.InvalidPartyReceipt;
    if (!std.mem.eql(u8, canonical, receipt) or number != (std.math.add(u64, ledger.revision, 1) catch return error.InvalidPartyRevision) or (ledger.last_receipt != null and number <= ledger.last_receipt.?)) return error.InvalidPartyReceipt;
    const current = try baseline(combat, reserves, ledger, "world_pause_preparation", content, receipt);
    try authorizePause(journal);
    const preview = try party.replay(combat, current, .{}, journal);
    return .{ .snapshot = preview.current, .revision = number, .receipt = number };
}
