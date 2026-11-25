//! Public surface: source mode entry, ownership and the atomic
//! optional-game settlement bridge. The rule loops themselves are the accepted
//! optional-game contracts module (`@import("optional_game_contracts")`); nothing here
//! re-implements dice, cup or card rules.

pub const types = @import("types.zig");
pub const ledger = @import("ledger.zig");
pub const settle = @import("settle.zig");
pub const host = @import("host.zig");

pub const contracts = @import("optional_game_contracts");

pub const Game = types.Game;
pub const EntryKind = types.EntryKind;
pub const CallerStatus = types.CallerStatus;
pub const Ledger = ledger.Ledger;
pub const Family = ledger.Family;
pub const Caller = ledger.Caller;
pub const Wallet = settle.Wallet;
pub const Effect = settle.Effect;
pub const Settlement = settle.Settlement;
pub const Host = host.Host;
pub const Admission = host.Admission;

pub const schema = types.schema;

test {
    _ = types;
    _ = ledger;
    _ = settle;
    _ = host;
}
