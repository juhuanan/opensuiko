//! Ordinary-control routing and logical draw state across world, field, party
//! menu and battle.
//!
//! Integration surface:
//!   * `router.Router.begin/finish/reset` sits between the shared
//!     `controller.State` edge output and `world_travel.Controls`; it emits a
//!     filtered `Routed` frame for exactly one owner and a boundary receipt.
//!   * `draws` composes the logical draw plan from the existing view lists and
//!     captures/verifies it against retained resources across a reload.
//!   * `contract` is the hash-pinned description of the shared dispatch the
//!     router mirrors, so drift is a check failure, not a silent behavior
//!     change.

const std = @import("std");

pub const owners = @import("owners.zig");
pub const router = @import("router.zig");
pub const draws = @import("draws.zig");
pub const contract = @import("contract.zig");
pub const data = @import("campaign_policies_data").control_draws;

pub const version = "control-draws.1";

pub const Direction = owners.Direction;
pub const Owner = owners.Owner;
pub const Observation = owners.Observation;
pub const Transition = owners.Transition;
pub const Router = router.Router;
pub const Routed = router.Routed;
pub const Pad = router.Pad;
pub const Receipt = router.Receipt;
pub const Refusal = router.Refusal;
pub const Withheld = router.Withheld;
pub const TravelMode = owners.TravelMode;

pub const Plan = draws.Plan;
pub const Resources = draws.Resources;
pub const DrawState = draws.State;
pub const Entry = draws.Entry;
pub const Kind = draws.Kind;

/// Parse the embedded qualified-resource manifest.  The returned `Parsed` owns
/// the strings the `Resources` table borrows, so the caller keeps it alive for
/// the lifetime of the plan/state it produces.
pub fn loadManifest(allocator: std.mem.Allocator) !std.json.Parsed(draws.Manifest) {
    return std.json.parseFromSlice(draws.Manifest, allocator, data.logical_draws_json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

/// Parse the embedded control contract.
pub fn loadContract(allocator: std.mem.Allocator) !std.json.Parsed(contract.Contract) {
    return contract.Contract.load(allocator, data.control_contract_json);
}

pub fn resources(manifest: *const draws.Manifest) !draws.Resources {
    return draws.Resources.fromManifest(manifest.*);
}

/// Source text of the adapter's own modules, embedded so the focused gate can
/// prove the package never imports a shared owner or the save layer.
pub const review = struct {
    pub const owners_source = @embedFile("owners.zig");
    pub const router_source = @embedFile("router.zig");
    pub const draws_source = @embedFile("draws.zig");
    pub const contract_source = @embedFile("contract.zig");
};

comptime {
    if (owners.Owner.world != @as(owners.Owner, .world)) @compileError("owner enum drift");
}
