//! Actor pose and animation families.
//!
//! Public seam only.  A consumer parses the catalogue once with
//! `Catalogue.load(allocator, data.json)`, asks `Session.begin` for one actor
//! and one family, and renders `Session.draw()` while `Session.advance(ticks)`
//! reports frame starts exactly once.  `Session.capture`/`restore` are the
//! restart seam; both the emitted-before-settle and settled states resume
//! without replaying a frame, and a different content identity is refused.
//!
//! The module is deliberately pure data + validation: it imports no battle,
//! world or save module, so `combat_systems.host` and presentation owners can
//! wire it without a cycle.

const family = @import("family.zig");
const session = @import("session.zig");

pub const schema = family.schema;
pub const Family = family.Family;
pub const Side = family.Side;
pub const State = family.State;
pub const Piece = family.Piece;
pub const Pose = family.Pose;
pub const Palette = family.Palette;
pub const Page = family.Page;
pub const Frame = family.Frame;
pub const Animation = family.Animation;
pub const Auxiliary = family.Auxiliary;
pub const Binding = family.Binding;
pub const Actor = family.Actor;
pub const Packet = family.Packet;
pub const LoadError = family.LoadError;
pub const Catalogue = family.Catalogue;

pub const FrameRef = session.FrameRef;
pub const Emission = session.Emission;
pub const Draw = session.Draw;
pub const Capture = session.Capture;
pub const Session = session.Session;
pub const MAX_FRAMES = session.MAX_FRAMES;

test {
    _ = family;
    _ = session;
}
