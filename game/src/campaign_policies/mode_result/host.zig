//! Shared mode-result publication and retry transaction.
//!
//! One pending result at a time.  `begin` revalidates a self-contained result
//! against the canonical store and retains it; `stage` revalidates it again and
//! builds the candidate post-state without touching the store; `publish` is the
//! single canonical mutation (store plus cleared pending owner).  `commit` is
//! stage+publish; `retry` repeats stage+publish for a retained pending result.
//!
//! The durable `Snapshot` carries the store and the pending result, including
//! its owner and before-facts, so a pre-result save restores a retryable owner
//! and a post-result save restores the settled receipt without a second award.
const std = @import("std");
const model = @import("model.zig");

pub const max_snapshot_bytes = 256 * 1024;

pub const schema_id: model.Id = blk: {
    var id: model.Id = .{};
    const text = model.schema;
    if (text.len > model.max_id_len) @compileError("mode-result snapshot schema is too long");
    id.len = @intCast(text.len);
    @memcpy(id.bytes[0..text.len], text);
    break :blk id;
};

pub const Pending = struct {
    result: model.Result,
    /// Digest of `result` at admission.  A mutated pending envelope is stale.
    digest: u64,
    /// Retry attempts retained across save/restore.
    attempts: u16 = 0,
};

pub const Staged = struct {
    store: model.Store,
    digest: u64,
    baseline_digest: u64,
    baseline_revision: u64,
    baseline_receipt: u64,
    revision: u64,
    receipt: u64,
    owner: model.Owner,
};

pub const Outcome = struct {
    revision: u64,
    receipt: u64,
    owner: model.Owner,
};

pub const Snapshot = struct {
    schema: model.Id = .{},
    content_sha256: model.Sha = .{},
    store: model.Store = .{},
    pending: ?Pending = null,

    pub fn capture(host: Host) Snapshot {
        return .{
            .schema = schema_id,
            .content_sha256 = host.content_sha256,
            .store = host.store,
            .pending = host.pending,
        };
    }

    /// Revalidate the envelope exactly as a fresh process would.  A snapshot
    /// whose pending owner no longer matches its store is rejected instead of
    /// silently dropping the owner.
    pub fn validate(self: Snapshot, content: model.Sha) !void {
        if (!std.mem.eql(u8, self.schema.slice(), model.schema)) return error.InvalidSnapshotSchema;
        if (!self.content_sha256.eql(content)) return error.SnapshotContentMismatch;
        self.store.validate() catch |err| switch (err) {
            error.InvalidStore, error.InvalidParty, error.InvalidMember => return error.InvalidSnapshot,
        };
        const pending = self.pending orelse return;
        try pending.result.validate();
        if (model.resultDigest(pending.result) != pending.digest) return error.StaleResult;
        try verifyExpected(pending.result.expected, self.store, content);
        const index = model.ownerIndex(pending.result.owner);
        if (pending.result.expected.receipt != self.store.receipts[index]) return error.StaleReceipt;
        if (pending.result.receipt <= self.store.receipts[index]) return error.RepeatedReceipt;
        _ = try candidateAfter(self.store, pending.result);
        if (pending.attempts > model.max_retries) return error.InvalidSnapshot;
    }
};

pub const Host = struct {
    content_sha256: model.Sha,
    store: model.Store,
    pending: ?Pending = null,

    pub fn init(store: model.Store, content_sha256: model.Sha) !Host {
        if (content_sha256.isZero()) return error.StaleContent;
        store.validate() catch |err| switch (err) {
            error.InvalidStore, error.InvalidParty, error.InvalidMember => return error.InvalidStore,
        };
        return .{ .content_sha256 = content_sha256, .store = store };
    }

    pub fn storeDigest(self: Host) u64 {
        return model.storeDigest(self.store);
    }

    /// Admit one result.  The caller keeps no transaction object: the host owns
    /// the pending owner and its exact before-facts until commit or abandon.
    pub fn begin(self: *Host, result: model.Result) !void {
        if (self.pending != null) return error.PendingOwnerBusy;
        try result.validate();
        try verifyExpected(result.expected, self.store, self.content_sha256);
        const index = model.ownerIndex(result.owner);
        const settled = self.store.receipts[index];
        if (result.receipt <= settled) return error.RepeatedReceipt;
        if (result.expected.receipt != settled) return error.StaleReceipt;
        // Reject a result that could not publish later for a static reason.
        _ = try candidateAfter(self.store, result);
        self.pending = .{ .result = result, .digest = model.resultDigest(result) };
    }

    /// Revalidate the retained result and build the candidate store without
    /// mutating live state.  Any error leaves the pending owner retryable.
    pub fn stage(self: *Host) !Staged {
        const pending = self.pending orelse return error.NoPendingResult;
        if (model.resultDigest(pending.result) != pending.digest) return error.StaleResult;
        try pending.result.validate();
        try verifyExpected(pending.result.expected, self.store, self.content_sha256);
        const index = model.ownerIndex(pending.result.owner);
        const settled = self.store.receipts[index];
        if (pending.result.receipt <= settled) return error.RepeatedReceipt;
        if (pending.result.expected.receipt != settled) return error.StaleReceipt;
        const candidate = try candidateAfter(self.store, pending.result);
        return .{
            .store = candidate,
            .digest = pending.digest,
            .baseline_digest = model.storeDigest(self.store),
            .baseline_revision = self.store.revision,
            .baseline_receipt = settled,
            .revision = candidate.revision,
            .receipt = pending.result.receipt,
            .owner = pending.result.owner,
        };
    }

    /// The one canonical mutation: publish the staged store and clear the owner.
    pub fn publish(self: *Host, staged: Staged) !Outcome {
        const pending = self.pending orelse return error.NoPendingResult;
        if (staged.digest != pending.digest or staged.owner != pending.result.owner) return error.StaleResult;
        if (self.store.revision != staged.baseline_revision) return error.StaleRevision;
        if (self.store.receipts[model.ownerIndex(pending.result.owner)] != staged.baseline_receipt) return error.StaleReceipt;
        if (model.storeDigest(self.store) != staged.baseline_digest) return error.StaleResult;
        self.store = staged.store;
        self.pending = null;
        return .{ .revision = staged.revision, .receipt = staged.receipt, .owner = staged.owner };
    }

    pub fn commit(self: *Host) !Outcome {
        const staged = try self.stage();
        return self.publish(staged);
    }

    /// Retry a valid pending result after a transient failure or a restore.
    pub fn retry(self: *Host) !Outcome {
        if (self.pending) |*pending| {
            if (pending.attempts >= model.max_retries) return error.RetryExhausted;
            pending.attempts += 1;
        } else return error.NoPendingResult;
        const staged = try self.stage();
        return self.publish(staged);
    }

    /// Explicit rejection by the host that owns the pending result.
    pub fn abandon(self: *Host, owner: model.Owner) !void {
        const pending = self.pending orelse return error.NoPendingResult;
        if (pending.result.owner != owner) return error.PendingOwnerMismatch;
        self.pending = null;
    }

    pub fn save(self: Host, allocator: std.mem.Allocator) ![]u8 {
        const snapshot = Snapshot.capture(self);
        try snapshot.validate(self.content_sha256);
        return std.json.Stringify.valueAlloc(allocator, snapshot, .{});
    }

    /// Rebuild a host from a host-owned envelope value (the world-session save
    /// path already holds the parsed value, so it does not reserialize).
    pub fn fromSnapshot(snapshot: Snapshot, content_sha256: model.Sha) !Host {
        try snapshot.validate(content_sha256);
        return .{ .content_sha256 = content_sha256, .store = snapshot.store, .pending = snapshot.pending };
    }

    pub fn load(allocator: std.mem.Allocator, bytes: []const u8, content_sha256: model.Sha) !Host {
        if (bytes.len > max_snapshot_bytes) return error.SnapshotTooLarge;
        const parsed = std.json.parseFromSlice(Snapshot, allocator, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidSnapshot,
        };
        defer parsed.deinit();
        return fromSnapshot(parsed.value, content_sha256);
    }
};

/// Revalidate every before-fact in a fixed order.  Each mismatch has its own
/// typed error so a stale quoted price is not reported as a stale result.
pub fn verifyExpected(expected: model.Expected, store: model.Store, content: model.Sha) !void {
    if (!expected.content_sha256.eql(content)) return error.StaleContent;
    if (expected.revision != store.revision) return error.StaleRevision;
    if (expected.money != store.money) return error.StaleMoney;
    if (expected.price) |price| {
        if (store.price_quote == null or store.price_quote.? != price) return error.StalePrice;
    }
    if (expected.roster != model.rosterDigest(store)) return error.StaleRoster;
    if (expected.ledger != model.ledgerDigest(store)) return error.StaleLedger;
    if (expected.story != model.storyDigest(store)) return error.StaleStory;
    if (!std.meta.eql(expected.camera, store.camera)) return error.StaleCamera;
    if (expected.pending_owner != null) return error.StalePendingOwner;
    // An optional-game result pins the mode projection; every other family
    // leaves `mode` at zero and is unaffected by these facts.
    if (expected.mode != 0 and expected.mode != model.modeDigest(store)) return error.StaleMode;
}

fn candidateAfter(store: model.Store, result: model.Result) !model.Store {
    var candidate = store;
    for (result.effects[0..result.effect_count]) |effect| try effect.apply(&candidate);
    candidate.revision = std.math.add(u64, result.expected.revision, 1) catch return error.InvalidResult;
    candidate.receipts[model.ownerIndex(result.owner)] = result.receipt;
    candidate.validate() catch |err| switch (err) {
        error.InvalidStore, error.InvalidParty, error.InvalidMember => return error.InvalidResult,
    };
    return candidate;
}
