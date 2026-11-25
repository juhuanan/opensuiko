//! Headquarters and town services at their real source callers.
//!
//! `contract` is the hash-pinned, source-derived caller contract.  `host` is
//! the admission/return/transaction-routing state machine.  `engines` (a
//! separate module so this package stays free of runtime imports) adapts the
//! current `field`/`game_state`/`storage` engines to the host's transaction
//! interface.
//!
//! This package does not plan service rules; the caller owns rule selection and
//! `host` refuses a service when the caller, area, NPC or stage gate is missing.
const std = @import("std");

pub const contract = @import("contract.zig");
pub const host = @import("host.zig");
pub const engines = @import("engines.zig");

pub const schema_id = contract.schema_id;
pub const Caller = contract.Caller;
pub const Packet = contract.Packet;
pub const OverlayEntry = contract.OverlayEntry;
pub const ServiceFamily = contract.ServiceFamily;
pub const ServiceId = contract.ServiceId;
pub const Limits = contract.Limits;
pub const Blocker = contract.Blocker;

pub const Phase = host.Phase;
pub const Access = host.Access;
pub const BlockReason = host.BlockReason;
pub const Blocked = host.Blocked;
pub const Receipt = host.Receipt;
pub const Outcome = host.Outcome;
pub const Engine = host.Engine;
pub const Host = host.Host;
pub const OpenResult = host.OpenResult;

pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Packet) {
    return contract.load(allocator, bytes);
}

pub fn open(p: *const Packet, caller_id: []const u8, access: Access, revision: u64) OpenResult {
    return Host.open(p, caller_id, access, revision);
}

pub fn openOverlay(p: *const Packet, entry_id: []const u8, access: Access, revision: u64) OpenResult {
    return Host.openOverlay(p, entry_id, access, revision);
}

pub fn replay(p: *const Packet, caller_id: []const u8, access: Access, revision: u64, receipt: Receipt) OpenResult {
    return Host.replay(p, caller_id, access, revision, receipt);
}
