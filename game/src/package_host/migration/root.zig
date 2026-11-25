//! Full-campaign snapshot schemas, content rebinding, supported
//! migrations, atomic backup/recovery and the source save policy.
//!
//! This namespace is self-contained: it imports only the Zig standard library.
//! The production owners (`world_session_save`, `journey`, `save_slots`,
//! `settings`) stay read-only; the host wires them to `Campaign` and supplies the
//! content identity document plus the gear-index binding (see the pack report).
//!
//! Everything here is port-level.  No original instruction is executed, no
//! emulator/window/media is involved, and tests run against isolated temporary
//! roots only — never a real user save.

const std = @import("std");

pub const ids = @import("ids.zig");
pub const budget = @import("budget.zig");
pub const content = @import("content.zig");
pub const schema = @import("schema.zig");
pub const legacy = @import("legacy.zig");
pub const codec = @import("codec.zig");
pub const store = @import("store.zig");
pub const policy = @import("policy.zig");
pub const host = @import("host.zig");

pub const Snapshot = schema.Snapshot;
pub const Content = content.Content;
pub const ContentDocument = content.Document;
pub const Campaign = host.Campaign;
pub const Store = store.Store;
pub const Limits = budget.Limits;
pub const decode = codec.decode;
pub const loadAny = codec.loadAny;
pub const encode = codec.encode;

test {
    std.testing.refAllDecls(@This());
}
