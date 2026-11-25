//! Durable storage for the campaign snapshot: a write journal, a rotated
//! backup and recovery that never guesses.
//!
//! Write protocol (`save`):
//!   1. refuse a document that is too large or structurally hostile,
//!   2. write `campaign.json.tmp`, sync it,
//!   3. write `campaign.json.journal` (new digest/length, previous digest),
//!   4. rotate the current `campaign.json` to `campaign.json.bak`,
//!   5. rename `.tmp` over `campaign.json`,
//!   6. delete the journal.
//!
//! Recovery (`recover`) is deterministic from what is on disk:
//!   * journal + matching temp  -> finish step 5 (the new bytes were fully
//!     written and synced before the journal existed),
//!   * journal + matching primary -> the commit already happened, drop the
//!     journal,
//!   * journal + neither -> roll back, keeping the old primary and backup,
//!   * temp without a journal -> discard it; the primary was never touched.
//!
//! `Root.isolatedTest` refuses a non-empty directory, so a test can never be
//! pointed at a real user save by accident.

const std = @import("std");
const validation = @import("validation");
const budget = @import("budget.zig");

pub const file_primary = "campaign.json";
pub const file_backup = "campaign.json.bak";
pub const file_journal = "campaign.json.journal";
pub const file_temp = "campaign.json.tmp";
pub const journal_schema = "suikoden-campaign-journal/1";
pub const max_journal_bytes = 4096;

pub const Fault = enum { none, after_temp_write, after_temp_sync, after_journal_write, after_backup_rotate, before_replace };

pub const SaveOptions = struct {
    /// Rotate the current primary into the backup before writing.  The caller
    /// sets this false when the current primary is corrupt: overwriting a known
    /// good backup with corrupt bytes would destroy the last valid campaign.
    rotate_previous: bool = true,
};
pub const InjectedFailure = error{InjectedWriteFailure};

pub const Recovery = enum { none, completed, already_committed, rolled_back, discarded_temp, blocked };

pub const RootKind = enum { isolated_test, user_data };

pub const Root = struct {
    dir: std.Io.Dir,
    kind: RootKind,

    /// A test root must be empty: it cannot contain a campaign, a backup or a
    /// journal from any other run.
    pub fn isolatedTest(io: std.Io, dir: std.Io.Dir) !Root {
        var iterator = dir.iterate();
        if (try iterator.next(io) != null) return error.TestRootNotEmpty;
        return .{ .dir = dir, .kind = .isolated_test };
    }

    pub fn userData(dir: std.Io.Dir) Root {
        return .{ .dir = dir, .kind = .user_data };
    }
};

pub const Which = enum { primary, backup };

pub const Store = struct {
    allocator: std.mem.Allocator,
    root: Root,
    limits: budget.Limits = .{},

    pub fn init(allocator: std.mem.Allocator, root: Root, limits: budget.Limits) Store {
        return .{ .allocator = allocator, .root = root, .limits = limits };
    }

    pub fn save(self: *Store, io: std.Io, bytes: []const u8, fault: Fault, options: SaveOptions) !void {
        try budget.checkSize(bytes, self.limits);
        try budget.scanDepth(bytes, self.limits);
        _ = try self.recover(io);
        const new_digest = sha256Hex(bytes);
        const previous = self.root.dir.readFileAlloc(io, file_primary, self.allocator, .limited(self.limits.bytes)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (previous) |old| self.allocator.free(old);
        var previous_digest: [64]u8 = @splat(0);
        if (previous) |old| previous_digest = sha256Hex(old);

        var temp = try self.root.dir.createFile(io, file_temp, .{ .truncate = true });
        var temp_open = true;
        defer if (temp_open) temp.close(io);
        try temp.writeStreamingAll(io, bytes);
        if (fault == .after_temp_write) return error.InjectedWriteFailure;
        try temp.sync(io);
        if (fault == .after_temp_sync) return error.InjectedWriteFailure;
        temp.close(io);
        temp_open = false;

        const journal = try std.json.Stringify.valueAlloc(self.allocator, Journal{ .sha256 = new_digest, .len = bytes.len, .previous_sha256 = previous_digest }, .{});
        defer self.allocator.free(journal);
        try atomicWrite(io, self.root.dir, file_journal, journal);
        if (fault == .after_journal_write) return error.InjectedWriteFailure;

        if (previous) |old| {
            if (options.rotate_previous) try atomicWrite(io, self.root.dir, file_backup, old);
        }
        if (fault == .after_backup_rotate) return error.InjectedWriteFailure;
        if (fault == .before_replace) return error.InjectedWriteFailure;

        try self.root.dir.rename(file_temp, self.root.dir, file_primary, io);
        deleteIfPresent(io, self.root.dir, file_journal) catch |err| return err;
    }

    /// Resolve whatever a previous process left behind.  Returns `.blocked`
    /// when the root cannot be modified (read-only or full): nothing is
    /// destroyed and the caller may still read the existing campaign.
    pub fn recover(self: *Store, io: std.Io) !Recovery {
        const journal_bytes = self.root.dir.readFileAlloc(io, file_journal, self.allocator, .limited(max_journal_bytes)) catch |err| switch (err) {
            error.FileNotFound => {
                const has_temp = tempExists(io, self.root.dir);
                if (has_temp) {
                    self.deleteWithRecovery(io, file_temp) catch return .blocked;
                    return .discarded_temp;
                }
                return .none;
            },
            else => return err,
        };
        defer self.allocator.free(journal_bytes);
        const parsed = std.json.parseFromSlice(Journal, self.allocator, journal_bytes, .{}) catch {
            self.deleteWithRecovery(io, file_temp) catch return .blocked;
            self.deleteWithRecovery(io, file_journal) catch return .blocked;
            return .rolled_back;
        };
        defer parsed.deinit();
        const journal = parsed.value;
        if (!std.mem.eql(u8, journal.schema, journal_schema) or journal.len > self.limits.bytes) {
            self.deleteWithRecovery(io, file_temp) catch return .blocked;
            self.deleteWithRecovery(io, file_journal) catch return .blocked;
            return .rolled_back;
        }
        if (try self.matches(io, file_temp, journal)) {
            self.root.dir.rename(file_temp, self.root.dir, file_primary, io) catch |err| switch (err) {
                error.AccessDenied, error.ReadOnlyFileSystem, error.NoSpaceLeft => return .blocked,
                else => return err,
            };
            self.deleteWithRecovery(io, file_journal) catch return .blocked;
            return .completed;
        }
        if (try self.matches(io, file_primary, journal)) {
            self.deleteWithRecovery(io, file_temp) catch return .blocked;
            self.deleteWithRecovery(io, file_journal) catch return .blocked;
            return .already_committed;
        }
        self.deleteWithRecovery(io, file_temp) catch return .blocked;
        self.deleteWithRecovery(io, file_journal) catch return .blocked;
        return .rolled_back;
    }

    fn matches(self: *Store, io: std.Io, name: []const u8, journal: Journal) !bool {
        const bytes = self.root.dir.readFileAlloc(io, name, self.allocator, .limited(self.limits.bytes)) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer self.allocator.free(bytes);
        if (bytes.len != journal.len) return false;
        const digest = sha256Hex(bytes);
        return std.mem.eql(u8, &digest, &journal.sha256);
    }

    fn deleteWithRecovery(self: *Store, io: std.Io, name: []const u8) !void {
        self.root.dir.deleteFile(io, name) catch |err| switch (err) {
            error.FileNotFound => {},
            error.AccessDenied, error.ReadOnlyFileSystem => return error.AccessDenied,
            else => return err,
        };
    }

    /// Read one file as-is.  Validation is the caller's job because only the
    /// caller holds the content binding.
    pub fn read(self: *Store, io: std.Io, allocator: std.mem.Allocator, which: Which) ![]u8 {
        const name = switch (which) {
            .primary => file_primary,
            .backup => file_backup,
        };
        return self.root.dir.readFileAlloc(io, name, allocator, .limited(self.limits.bytes));
    }

    pub fn exists(self: *Store, io: std.Io, which: Which) bool {
        const name = switch (which) {
            .primary => file_primary,
            .backup => file_backup,
        };
        return dirHas(self.root.dir, io, name);
    }
};

const Journal = struct {
    schema: []const u8 = journal_schema,
    sha256: [64]u8,
    len: usize,
    previous_sha256: [64]u8,
};

fn tempExists(io: std.Io, dir: std.Io.Dir) bool {
    return dirHas(dir, io, file_temp);
}

fn dirHas(dir: std.Io.Dir, io: std.Io, name: []const u8) bool {
    _ = dir.statFile(io, name, .{}) catch return false;
    return true;
}

fn deleteIfPresent(io: std.Io, dir: std.Io.Dir, name: []const u8) !void {
    dir.deleteFile(io, name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn atomicWrite(io: std.Io, dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    var atomic = try dir.createFileAtomic(io, name, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    return validation.sha256Hex(bytes);
}
