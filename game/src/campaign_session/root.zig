//! Integrated campaign surface.
pub const session = @import("session.zig");
pub const bindings = @import("bindings.zig");

pub const Campaign = session.Campaign;
pub const Snapshot = session.Snapshot;
pub const contentSha = session.contentSha;

pub const review = struct {
    pub const session_source = @embedFile("session.zig");
};
