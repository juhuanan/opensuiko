//! Item-ledger publication adapter: reviewed item identities, ordinary item
//! operations and the seven-slot shared ledger, published atomically against
//! caller-owned item state.
pub const catalogue = @import("catalogue.zig");
pub const owners = @import("owners.zig");
pub const ledger = @import("ledger.zig");
pub const journal = @import("journal.zig");
pub const publish = @import("publish.zig");
pub const version = owners.version;
pub const item_count = catalogue.item_count;

/// Source text of the adapter's own modules, embedded so the focused gate can
/// prove the adapter never imports the save layer or the global story state.
pub const review = struct {
    pub const catalogue_source = @embedFile("catalogue.zig");
    pub const owners_source = @embedFile("owners.zig");
    pub const ledger_source = @embedFile("ledger.zig");
    pub const journal_source = @embedFile("journal.zig");
    pub const publish_source = @embedFile("publish.zig");
};
pub const shared_capacity = catalogue.shared_capacity;
