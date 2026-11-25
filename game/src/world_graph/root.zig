//! The assembled campaign content graph, as the runtime consumes it.
//!
//! `graph` decodes/validates the immutable content graph and answers reference
//! queries; `residency` owns scene selection lifetime and rebinding.  This root
//! binds the two to the generated graph asset so a caller never supplies a digest by
//! hand and never reaches a development-tree path.
//!
//! The graph asset is compile-time packaged content (`@embedFile`).  No PS1 address,
//! LBA, pointer or filesystem path is part of the runtime interface; the ids are
//! content identities (`scene:vaa_room2`, `actor:16`, `cue:0x422`, ...).

const std = @import("std");
const data = @import("world_graph_data");
const packs_mod = @import("packs.zig");

pub const graph = @import("graph.zig");
pub const residency = @import("residency.zig");

pub const schema = graph.schema;
pub const revision = data.revision;
pub const content_json = data.json;
pub const file_sha256 = data.file_sha256;
pub const body_sha256 = data.body_sha256;
pub const counts = packs_mod.counts;
pub const packs = packs_mod.packs;
pub const Pack = packs_mod.Pack;

pub const Graph = graph.Graph;
pub const Host = residency.Host;
pub const Selection = residency.Selection;
pub const Snapshot = residency.Snapshot;
pub const Node = graph.Node;
pub const Scene = graph.Scene;
pub const CueRef = graph.CueRef;
pub const ActorIdentity = graph.ActorIdentity;
pub const FormationRef = graph.FormationRef;

/// Load the packaged graph and admit the whole qualified set.  The caller owns
/// the returned host (`deinit`).
pub fn open(backing: std.mem.Allocator) !*Host {
    return Host.open(backing, content_json, file_sha256, body_sha256);
}

/// Load a caller-supplied graph with the packaged pins.  A different body is
/// refused; this exists for tests that re-serialise the same rows.
pub fn openWith(backing: std.mem.Allocator, bytes: []const u8) !*Host {
    return Host.open(backing, bytes, file_sha256, body_sha256);
}

/// The canonical field scenes the runtime route already loads.  Kept here as the
/// one declared entry list so a caller cannot invent a scene id.
pub const canonical_scenes = [_][]const u8{ "vaa_room2", "vb6_room0", "vb6_room6" };

pub fn isCanonicalScene(id: []const u8) bool {
    for (canonical_scenes) |candidate| if (std.mem.eql(u8, candidate, id)) return true;
    return false;
}

/// Canonical cue commands resolved by the audio handback.  `resolveCue` refuses an
/// unknown or excluded command instead of defaulting to a silent no-op.
pub const canonical_cues = [_]u32{ 0x404, 0x422, 0x446 };
