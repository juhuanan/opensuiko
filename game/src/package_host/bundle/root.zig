//! Private release-candidate packaging contract.
//!
//! Public surface for the integrator (module) and for the focused port gate:
//!
//! * `manifest`  — the candidate manifest, its declared identity rules and
//!                 structural validation (missing/extra/relabelled data is an
//!                 error, never a default);
//! * `signature` — HMAC-SHA256 envelope over the exact manifest bytes;
//! * `state`     — the per-user state layout the candidate may touch;
//! * `bundle`    — file verification against the manifest and the signing
//!                 receipt.
//!
//! Nothing here opens a window, reads the disc, plays media or writes a user
//! directory; the packaging tool owns assembly and external execution.
pub const manifest = @import("manifest.zig");
pub const signature = @import("signature.zig");
pub const state = @import("state.zig");
pub const bundle = @import("bundle.zig");
