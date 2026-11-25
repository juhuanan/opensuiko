//! Serializable owner state for the travel campaign host.
//!
//! This module deliberately imports nothing from the host or its packets, so a
//! save owner can name the type without importing the runtime owner.
const std = @import("std");

pub const Mode = enum { none, boat, teleport };

pub const Snapshot = struct {
    mode: Mode = .none,
    boat_ledger_json: ?[]const u8 = null,
    boat_session_json: ?[]const u8 = null,
    teleport_json: ?[]const u8 = null,
};

comptime {
    _ = std;
}
