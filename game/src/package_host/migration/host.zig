//! The campaign owner: one durable full-campaign snapshot, one transaction.
//!
//! `Campaign` is the consumer seam the host wires to the real session owners.  Its
//! contract is deliberately small:
//!
//!   * `open` loads the newest valid campaign (primary, then backup), migrating
//!     a supported legacy file and reporting whether a re-pin is desirable,
//!   * `queue` records a produced-but-uncommitted mode result,
//!   * `commit` applies it to a *copy*, writes the copy, and only then adopts
//!     it, so a failed/interrupted write preserves both the campaign and the
//!     pending ownership,
//!   * `save` captures the current campaign through an ordinary pause-menu
//!     write, subject to `policy`.
//!
//! No heap ownership is retained by a snapshot: the value is fixed-size, so
//! adoption is a copy and there is nothing to leak on an error path.

const std = @import("std");
const ids = @import("ids.zig");
const budget = @import("budget.zig");
const codec = @import("codec.zig");
const content = @import("content.zig");
const legacy = @import("legacy.zig");
const policy = @import("policy.zig");
const schema = @import("schema.zig");
const store = @import("store.zig");

pub const LoadSource = store.Which;

pub const LoadOutcome = struct {
    source: LoadSource,
    recovery: store.Recovery,
    bind: content.Bind,
    migrated: ?legacy.Source,
    /// The file was valid but its content binding is older than the current
    /// content (or it came from another family); a production caller may
    /// persist the re-pinned bytes.
    needs_rewrite: bool,
};

pub const CommitOutcome = struct {
    revision: u64,
    receipt: u64,
};

pub const New = struct {
    block: ids.Id(32),
    map: ids.Id(32),
};

pub const Opened = struct {
    campaign: Campaign,
    /// Null when a new campaign was created because no save existed.
    outcome: ?LoadOutcome,
};

pub const Campaign = struct {
    allocator: std.mem.Allocator,
    store: store.Store,
    content: *const content.Content,
    limits: budget.Limits,
    snapshot: schema.Snapshot,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, root: store.Root, content_ref: *const content.Content, limits: budget.Limits, new: New) !Opened {
        var campaign: Campaign = .{
            .allocator = allocator,
            .store = store.Store.init(allocator, root, limits),
            .content = content_ref,
            .limits = limits,
            .snapshot = undefined,
        };
        if (campaign.load(io)) |outcome| {
            return .{ .campaign = campaign, .outcome = outcome };
        } else |err| switch (err) {
            error.FileNotFound => {
                campaign.snapshot = try schema.newGame(content_ref, new.block, new.map);
                return .{ .campaign = campaign, .outcome = null };
            },
            else => return err,
        }
    }

    /// Load the campaign from the root.  A malformed primary falls back to the
    /// backup; a future/foreign/downgraded file is a protected error and does
    /// not fall back, because silently loading older bytes would hide it.
    pub fn load(self: *Campaign, io: std.Io) !LoadOutcome {
        const recovery = try self.store.recover(io);
        var first_error: ?anyerror = null;
        const order = [_]LoadSource{ .primary, .backup };
        for (order) |which| {
            const bytes = self.store.read(io, self.allocator, which) catch |err| {
                if (which == .primary) first_error = err;
                continue;
            };
            defer self.allocator.free(bytes);
            const decoded = codec.loadAny(self.allocator, bytes, self.content, self.limits) catch |err| {
                if (protected(err)) return err;
                if (which == .primary) first_error = err;
                continue;
            };
            defer decoded.deinit();
            self.snapshot = decoded.snapshot.*;
            // The decoded value borrows its `schema` string from the arena that
            // `decoded` owns; the adopted copy must point at the compiled
            // constant instead of that freed storage.
            self.snapshot.schema = schema.schema_id;
            return .{
                .source = which,
                .recovery = recovery,
                .bind = decoded.bind,
                .migrated = decoded.migrated,
                .needs_rewrite = decoded.migrated != null or decoded.bind.rebound,
            };
        }
        return first_error orelse error.FileNotFound;
    }

    pub fn capture(self: *const Campaign) schema.Snapshot {
        return self.snapshot;
    }

    /// Encode the current value and verify it round-trips before it can be
    /// written; a capture that cannot be read back is a bug, not a save.
    pub fn encode(self: *const Campaign, allocator: std.mem.Allocator) ![]u8 {
        const bytes = try codec.encode(allocator, self.snapshot, self.limits);
        errdefer allocator.free(bytes);
        return bytes;
    }

    /// Decide whether the current primary may be rotated into the backup.
    /// A protected file (future schema, foreign campaign, downgraded content)
    /// refuses the write outright; a merely corrupt file is not allowed to
    /// overwrite a known good backup.
    fn rotatePrevious(self: *Campaign, io: std.Io) !bool {
        const bytes = self.store.read(io, self.allocator, .primary) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer self.allocator.free(bytes);
        const decoded = codec.loadAny(self.allocator, bytes, self.content, self.limits) catch |err| {
            if (protected(err)) return err;
            return false;
        };
        decoded.deinit();
        return true;
    }

    pub fn save(self: *Campaign, io: std.Io, decision: policy.Decision) !void {
        if (!policy.allowsSlot(decision)) return error.SaveRefused;
        const bytes = try self.encode(self.allocator);
        defer self.allocator.free(bytes);
        const rotate = try self.rotatePrevious(io);
        try self.store.save(io, bytes, .none, .{ .rotate_previous = rotate });
    }

    pub fn queue(self: *Campaign, pending: schema.Pending) !void {
        var probe = self.snapshot;
        probe.pending = pending;
        try probe.validate(self.content);
        self.snapshot.pending = pending;
    }

    pub fn dropPending(self: *Campaign) void {
        self.snapshot.pending = null;
    }

    /// Commit the pending result.  The campaign value is replaced only after
    /// the write succeeds; on any failure the old value (and therefore the
    /// pending ownership) is still there and the result can be retried.
    pub fn commit(self: *Campaign, io: std.Io) !CommitOutcome {
        const pending = self.snapshot.pending orelse return error.NoPendingResult;
        const next = try self.snapshot.applyPending(self.content);
        const bytes = try codec.encode(self.allocator, next, self.limits);
        defer self.allocator.free(bytes);
        const rotate = try self.rotatePrevious(io);
        try self.store.save(io, bytes, .none, .{ .rotate_previous = rotate });
        self.snapshot = next;
        return .{ .revision = next.revision, .receipt = pending.receipt };
    }

    /// Commit with an injected write failure, used by the focused gate to prove
    /// that a failed flush preserves the pending result.  Production callers
    /// use `commit`.
    pub fn commitFaulted(self: *Campaign, io: std.Io, fault: store.Fault) !CommitOutcome {
        const pending = self.snapshot.pending orelse return error.NoPendingResult;
        const next = try self.snapshot.applyPending(self.content);
        const bytes = try codec.encode(self.allocator, next, self.limits);
        defer self.allocator.free(bytes);
        const rotate = try self.rotatePrevious(io);
        try self.store.save(io, bytes, fault, .{ .rotate_previous = rotate });
        self.snapshot = next;
        return .{ .revision = next.revision, .receipt = pending.receipt };
    }

    /// Persist a re-pinned/migrated value after a successful load.
    pub fn rewrite(self: *Campaign, io: std.Io) !void {
        const bytes = try self.encode(self.allocator);
        defer self.allocator.free(bytes);
        const rotate = try self.rotatePrevious(io);
        try self.store.save(io, bytes, .none, .{ .rotate_previous = rotate });
    }

    pub fn summary(self: *const Campaign) Summary {
        return .{
            .revision = self.snapshot.revision,
            .money = self.snapshot.quest.money,
            .block = self.snapshot.quest.block,
            .mode = self.snapshot.mode.kind,
            .party_len = self.snapshot.roster.party.len,
            .pending = self.snapshot.pending != null,
            .content_revision = self.snapshot.content.revision,
        };
    }
};

pub const Summary = struct {
    revision: u64,
    money: u32,
    block: ids.Id(32),
    mode: schema.ModeKind,
    party_len: u8,
    pending: bool,
    content_revision: u32,
};

pub fn protected(err: anyerror) bool {
    return err == error.FutureCampaignSchema or
        err == error.UnsupportedCampaignSchema or
        err == error.UnsupportedContentSchema or
        err == error.ContentDowngraded or
        err == error.ForeignCampaign or
        err == error.ContentDigestMismatch or
        err == error.OutOfMemory or
        err == error.DocumentTooLarge or
        err == error.DocumentTooDeep or
        err == error.LegacySchemaUnsupported or
        err == error.LegacyFormatUnsupported;
}
