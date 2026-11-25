//! Event admission and completion facts.
//!
//! Integration surface:
//!   * `host.Host.observe` is called once at the source caller with the raw
//!     frame fields and the canonical owner. It derives the phase, free/VM
//!     gates, a single dispatch decision and the completion fact.
//!   * `host.Host.snapshot/save/restore` carries construction progress, frame
//!     watermarks, completion receipt and owner identity across a process
//!     restart. Restore refuses a different owner instead of reselecting.
//!   * `source` holds the raw field/gate rules and the predicate resolver; it
//!     has no caller-supplied admission enum.
//!   * `data` is the generated, hash-pinned evidence asset.

const std = @import("std");

pub const source = @import("source.zig");
pub const host = @import("host.zig");
pub const data = @import("travel_data").admission;

pub const dispatch = @import("scene_dispatch");
pub const population = @import("scene_population");
pub const runtime = @import("event_runtime");

pub const version = host.version;
pub const schema = host.schema;
pub const snapshot_schema = host.snapshot_schema;

pub const Phase = source.Phase;
pub const Frame = source.Frame;
pub const FreeGate = source.FreeGate;
pub const FreeReason = source.FreeReason;
pub const VmGate = source.VmGate;
pub const VmReason = source.VmReason;
pub const Callback = source.Callback;

pub const Binding = host.Binding;
pub const OwnerView = host.OwnerView;
pub const OwnerState = host.OwnerState;
pub const OwnerHistory = host.OwnerHistory;
pub const Selection = host.Selection;
pub const Completion = host.Completion;
pub const CompletionReceipt = host.CompletionReceipt;
pub const Result = host.Result;
pub const Action = host.Action;
pub const Reason = host.Reason;
pub const Host = host.Host;
pub const Snapshot = host.Host.Snapshot;

pub fn loadHost(binding: Binding) !Host {
    return Host.init(binding);
}

pub fn admissionDocument() []const u8 {
    return data.event_admission_json;
}

pub fn conformanceDocument() []const u8 {
    return data.conformance_json;
}
