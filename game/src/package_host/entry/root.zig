//! Canonical title, Setup and save-slot user flows.
//!
//! Pure Zig (standard library only).  The host supplies the slot snapshot, the
//! committed Setup profile and the packaged start-seed identity; the module owns
//! the decisions, refusals and notices.  No raylib, no filesystem, no disc.
//!
//! Entry points:
//!   * `policy.load(allocator, entry_policy_json)` validates the packaged
//!     document against the compiled contract.
//!   * `entry.Entry.init(...)`, `tick(Intent) -> Command`, `acknowledge(...)`.
//!   * `view.*` for render-ready rows and full-length names.
//!   * `setup.Profile.encode/decode` for the independent settings store.
pub const policy = @import("policy.zig");
pub const name = @import("name.zig");
pub const slots = @import("slots.zig");
pub const setup = @import("setup.zig");
pub const entry = @import("entry.zig");
pub const view = @import("view.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
