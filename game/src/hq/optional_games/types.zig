//! Base vocabulary for the optional-game bridge.

const std = @import("std");

pub const schema = "suikoden-optional-games/1";
pub const rules_schema = "suikoden.optional-games.v1";

pub const Game = enum { dice, coin, karuta };
pub const EntryKind = enum { field_room, special_content_mode4 };
pub const CallerStatus = enum { proven, missing_field_caller };

pub const max_callers = 4;

pub fn parseGame(text: []const u8) !Game {
    if (std.mem.eql(u8, text, "dice")) return .dice;
    if (std.mem.eql(u8, text, "coin")) return .coin;
    if (std.mem.eql(u8, text, "karuta")) return .karuta;
    return error.UnknownGame;
}

pub fn parseEntryKind(text: []const u8) !EntryKind {
    if (std.mem.eql(u8, text, "field_room")) return .field_room;
    if (std.mem.eql(u8, text, "special_content_mode4")) return .special_content_mode4;
    return error.UnknownEntryKind;
}

pub fn parseCallerStatus(text: []const u8) !CallerStatus {
    if (std.mem.eql(u8, text, "proven")) return .proven;
    if (std.mem.eql(u8, text, "missing_field_caller")) return .missing_field_caller;
    return error.UnknownCallerStatus;
}

pub fn parseHex32(text: []const u8) ![32]u8 {
    if (text.len != 64) return error.InvalidHex;
    var out: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, text);
    return out;
}

test "types: the ledger vocabulary is stable" {
    try std.testing.expectEqual(Game.coin, try parseGame("coin"));
    try std.testing.expectEqual(EntryKind.special_content_mode4, try parseEntryKind("special_content_mode4"));
    try std.testing.expectEqual(CallerStatus.missing_field_caller, try parseCallerStatus("missing_field_caller"));
}
