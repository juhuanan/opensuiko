//! Package host glue.
//!
//! This file bridges the package_host modules to the shared owners.  It adds no
//! second loader, save owner, input filter or scheduler: each helper calls the
//! underlying module and returns its typed value or error to the owner that
//! already performs the operation.
//!
//! * `resolveContent`   -- standalone resource discovery (no source-tree path).
//! * `verifyPackage`    -- closed manifest/hash/schema validation, used only
//!                         when the root carries its package manifest.
//! * `stateDirectory`   -- per-user layout from a candidate manifest.
//! * `slotInfos`        -- slot snapshot adapter over `save_slots.Summary`.
//! * `tabletPortrait`   -- FACE resource join over the tablet view.
//! * `warehouseEntry`   -- AZUKARI admission, deliberately unreachable from
//!                         ordinary play (the NPC conversation is undecoded).

const std = @import("std");
const entry_mod = @import("entry/root.zig");
const discovery_mod = @import("discovery/root.zig");
const bundle_mod = @import("bundle/root.zig");
const frontiers_mod = @import("frontiers/root.zig");
const frontiers_data = @import("frontiers/table.zig");
const hq_tablet = @import("hq").tablet;
const summaries = @import("pause_menu").save_slots;

pub const Diagnostic = discovery_mod.Diagnostic;

pub const Content = struct {
    location: discovery_mod.Location,

    pub fn deinit(self: *Content) void {
        self.location.deinit();
        self.* = undefined;
    }
};

/// Resolve the content root through package discovery.  `explicit` wins; otherwise the
/// documented executable-relative / environment candidates are used.  There is
/// no repository-relative fallback.
pub fn resolveContent(
    allocator: std.mem.Allocator,
    io: std.Io,
    executable_dir: []const u8,
    explicit: ?[]const u8,
    environ: *const std.process.Environ.Map,
    diagnostic: *discovery_mod.Diagnostic,
) !Content {
    const location = try discovery_mod.discovery.contentRoot(allocator, io, .{
        .explicit = explicit,
        .environment = environ.get("SUIKODEN_CONTENT"),
        .executable_dir = executable_dir,
    }, diagnostic);
    return .{ .location = location };
}

pub const PackageKind = enum { absent, journey_manifest, validated_package };

/// Inspect the content root's manifest.  A package manifest is fully
/// validated (closed file set, byte counts, SHA-256, resource schemas, notice
/// and provenance) before any consumer reads it. Explicit content checks also
/// verify the file hashes and closed directory of a Journey export manifest.
pub fn verifyPackage(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    check_journey_files: bool,
    diagnostic: *discovery_mod.Diagnostic,
) !PackageKind {
    const path = try std.fs.path.join(allocator, &.{ root, "manifest.json" });
    defer allocator.free(path);
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = !check_journey_files, .allow_directory = false }) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        error.SymLinkLoop => return diagnostic.fail(.manifest_symlink, "manifest.json", "manifest must be a regular file", .{}, "restore the package manifest"),
        else => return err,
    };
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const bytes = try reader.interface.allocRemaining(allocator, .limited(256 * 1024));
    defer allocator.free(bytes);
    const Version = struct { schema: []const u8 };
    const parsed = std.json.parseFromSlice(Version, allocator, bytes, .{ .ignore_unknown_fields = true }) catch return error.MalformedManifest;
    defer parsed.deinit();
    if (std.mem.eql(u8, parsed.value.schema, "suikoden-journey-manifest/1")) {
        if (check_journey_files) try discovery_mod.package.verifyJourneyFiles(allocator, io, root, bytes, diagnostic);
        return .journey_manifest;
    }
    if (!std.mem.eql(u8, parsed.value.schema, discovery_mod.schema)) return error.UnsupportedManifestSchema;
    var opened = try discovery_mod.open(allocator, io, root, .{}, diagnostic);
    opened.deinit();
    return .validated_package;
}

/// Resolve the explicit user-data override or the candidate's manifest layout.
/// Returns null when neither applies, so development builds use their existing
/// save directory.
pub fn stateDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    content_root: []const u8,
    executable_dir: []const u8,
    environ: *const std.process.Environ.Map,
    diagnostic: *Diagnostic,
) !?[]u8 {
    if (environ.get("SUIKODEN_USER_DATA")) |override| {
        var user = try discovery_mod.discovery.userDataRoot(allocator, io, .{ .environment = override, .environ = environ }, diagnostic);
        errdefer user.deinit();
        try discovery_mod.discovery.validateSeparation(content_root, user.path, diagnostic);
        if (discovery_mod.discovery.macBundleRoot(executable_dir)) |bundle| {
            const real_bundle = try std.Io.Dir.cwd().realPathFileAlloc(io, bundle, allocator);
            defer allocator.free(real_bundle);
            try discovery_mod.discovery.validateSeparation(real_bundle, user.path, diagnostic);
        }
        return user.path;
    }
    const parent = std.fs.path.dirname(content_root) orelse return null;
    const path = try std.fs.path.join(allocator, &.{ parent, "manifest.json" });
    defer allocator.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(512 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);
    var parsed = bundle_mod.manifest.Manifest.parse(allocator, bytes) catch return null;
    defer parsed.deinit();
    parsed.value.validate(allocator) catch return null;
    const scheme = bundle_mod.state.Scheme.fromManifest(parsed.value) catch return null;
    const home = environ.get("HOME") orelse environ.get("USERPROFILE") orelse return null;
    if (!std.fs.path.isAbsolute(home)) return null;
    return try scheme.rootPath(allocator, home);
}

/// Map the existing save summaries to the entry slot snapshot.  A stored name
/// is used as stored; the prototype `Adventure N` label is not a save identity,
/// so a ready/backup slot that still carries it is reported as damaged instead
/// of being presented as a named save.
pub fn slotInfos(buffer: *[3]entry_mod.slots.SlotInfo, items: []const summaries.Summary) [3]entry_mod.slots.SlotInfo {
    for (items, 0..) |_, index| {
        const entry = &items[index];
        const default = summaries.defaultLabel(index);
        const name = entry.name.text();
        const is_default = std.mem.eql(u8, name, default.text());
        const named = !is_default and name.len != 0;
        buffer[index] = .{
            .status = switch (entry.status) {
                .empty => .empty,
                .ready => if (named) .ready else .damaged,
                .backup => if (named) .backup else .damaged,
                .damaged => .damaged,
                .future => .future,
            },
            .name = if (named) name else "",
            .scene = entry.scene,
            .level = entry.level,
            .seconds = entry.seconds,
            .order = @intCast(entry.seconds),
            .roster_total = 0,
            .party = &.{},
        };
    }
    return buffer.*;
}

/// Resolve the portrait resource for one revealed tablet row.  The reveal gate
/// belongs to `hq.tablet`; this only joins the revealed (page, cell) to the source FACE
/// page descriptor.  No pixels are decoded or cached here.
pub fn tabletPortrait(flags: [frontiers_data.tablet_entry_count]u8, tablet_entry: u8) !?frontiers_mod.FaceResource {
    const session = try frontiers_mod.tablet(flags);
    return session.portrait(tablet_entry);
}

pub const StartSeedCheck = struct {
    ok: bool,
    digest: [32]u8,
};

/// Canonical start provenance: the packaged opening bytes must hash to
/// the policy's start-seed digest before a route may be presented as canonical.
/// A mismatch is a typed refusal, not a silent prototype start.
pub fn verifyStartSeed(opening_json: []const u8) StartSeedCheck {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(opening_json, &digest, .{});
    return .{ .ok = std.mem.eql(u8, &digest, &entry_mod.policy.start_seed_sha256), .digest = digest };
}

pub const WarehouseAdmission = struct {
    allowed: bool = false,
    reason: []const u8 = "",
};

/// The AZUKARI warehouse join.  It is *closed* for ordinary play: the NPC
/// conversation that selects the overlay is not derived, so this helper exists
/// only for the declared/non-canonical path and reports why it refused.
pub fn warehouseAdmission(revision: u64) WarehouseAdmission {
    _ = revision;
    return .{ .allowed = false, .reason = "azukari_npc_conversation_unresolved" };
}

test "a default slot label is not accepted as a save identity" {
    var items: [3]summaries.Summary = summaries.emptySummaries();
    items[0] = .{ .status = .ready, .name = summaries.defaultLabel(0), .scene = "village", .leader = "Hero", .level = 1 };
    var buffer: [3]entry_mod.slots.SlotInfo = undefined;
    const infos = slotInfos(&buffer, items);
    try std.testing.expectEqual(entry_mod.slots.Status.damaged, infos[0].status);
    try std.testing.expectEqualStrings("", infos[0].name);
}
