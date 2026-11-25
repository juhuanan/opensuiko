//! Stars of Destiny tablet (identity, reveal, paged browsing).
//!
//! Integration surface:
//!   * `View.init(recruit_flags)` takes the persisted 108-byte gs+0x1AF4 array
//!     by value and copies it read-only. The view never writes it.
//!   * `View.apply(Intent)` per ordinary input edge and `View.hold(Direction)`
//!     per held frame drive browsing; up/down/left/right/confirm/cancel are the
//!     only intents.
//!   * `View.page`, `View.row`, `View.col`, `View.listed`, `View.detailEligible`
//!     and `View.lastReveal` feed the existing text/portrait presentation.
//!   * `View.snapshot`/`View.Snapshot.encode`/`decode`/`View.restore` carry the
//!     cursor, page scroll, repeat timers and last reveal across a restart and
//!     refuse a different roster or content asset.
//!   * `data` is the generated, hash-pinned evidence asset (`tablet.json`).

const std = @import("std");

pub const source = @import("source.zig");
pub const view = @import("view.zig");
pub const data = @import("table.zig");

pub const Intent = view.Intent;
pub const Direction = view.Direction;
pub const Reason = view.Reason;
pub const Result = view.Result;
pub const Reveal = view.Reveal;
pub const View = view.View;
pub const Snapshot = view.Snapshot;
pub const NameKind = source.NameKind;

pub const version = view.version;
pub const snapshot_schema = view.snapshot_schema;

pub fn loadView(flags: [data.entry_count]u8) View {
    return View.init(flags);
}

pub fn tabletDocument() []const u8 {
    return data.tablet_json;
}

pub fn header() []const u8 {
    return data.schema;
}
