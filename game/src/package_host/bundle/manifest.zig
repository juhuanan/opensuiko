//! Private candidate manifest contract.
//!
//! This module is a pure data contract: it parses the manifest the packaging
//! tool writes, recomputes the declared identity rules, and rejects a manifest
//! that claims something its entries do not support.  It never touches the
//! disc, a window, media or a real user directory.
const std = @import("std");
const validation = @import("validation");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const schema = "suikoden-private-candidate-manifest/1";
pub const hash_rules_schema = "suikoden-private-candidate-hash-rules/1";
pub const signature_schema = "suikoden-private-candidate-signature/1";

pub const FileClass = enum { reviewed, candidate };
pub const FileRole = enum { content, executable, notice, license, provenance, reviewed_asset };

pub const File = struct {
    path: []const u8,
    sha256: []const u8,
    size: u64,
    class: FileClass,
    role: FileRole,
    media: bool,
};

pub const HashRules = struct {
    schema: []const u8,
    algorithm: []const u8,
    file_unit: []const u8,
    entry_line: []const u8,
    order: []const u8,
    identity: []const u8,
    content_identity: []const u8,
    bundle_identity: []const u8,
    path_form: []const u8,
    excluded: []const []const u8,
    no_timestamps: bool,
    no_absolute_paths: bool,
    no_build_host_paths: bool,
    note: []const u8,
};

pub const ExecutableSigning = struct {
    scheme: []const u8,
    receipt: []const u8,
    hashed_by_bundle_rules: bool,
};

pub const Executable = struct {
    path: []const u8,
    sha256: []const u8,
    size: u64,
    role: FileRole,
    class: FileClass,
    headless_check: []const []const u8,
    persistence_check: []const []const u8,
    window_policy: []const u8,
    sha256_note: []const u8,
    signing: ExecutableSigning,

    pub fn validate(self: Executable) !void {
        try safePath(self.path);
        try validateHex(self.sha256);
        if (self.role != .executable) return error.ExecutableRoleMismatch;
        if (self.class != .candidate) return error.ExecutableMustBeCandidate;
        if (self.size == 0) return error.EmptyExecutable;
        if (self.headless_check.len == 0) return error.NoHeadlessCheck;
        if (!std.mem.eql(u8, self.signing.scheme, "adhoc")) return error.UnsupportedSigningScheme;
        try safePath(self.signing.receipt);
        if (!std.mem.endsWith(u8, self.signing.receipt, ".signing.json")) return error.BadReceiptName;
        if (self.signing.hashed_by_bundle_rules) return error.SigningReceiptHashed;
    }
};

pub const UserState = struct {
    schema: []const u8,
    platform: []const u8,
    root_relative_to: []const u8,
    root: []const u8,
    settings: []const u8,
    saves: []const []const u8,
    backups: []const []const u8,
    checks: []const u8,
    isolation: []const u8,
    owner: []const u8,
    rule: []const u8,

    pub fn validate(self: UserState) !void {
        return validateUserState(self);
    }
};

pub const MediaFile = struct { path: []const u8, sha256: []const u8 };

pub const Media = struct {
    schema: []const u8,
    rule: []const u8,
    reviewed: []const MediaFile,
    candidate: []const MediaFile,
};

pub const ReviewedFile = struct {
    path: []const u8,
    sha256: []const u8,
    bytes: u64,
    source: []const u8,
};

pub const ReviewedChange = struct {
    path: []const u8,
    reviewed_sha256: []const u8,
    current_sha256: ?[]const u8,
    source: []const u8,
    reason: []const u8,
};

pub const Reviewed = struct {
    ledger_identity: []const u8,
    files: []const ReviewedFile,
    changed_after_review: []const ReviewedChange,
    packaged: bool,
    note: []const u8,
};

pub const Family = struct {
    id: []const u8,
    stage: []const u8,
    required_for: []const u8,
    blocker: []const u8,
};

pub const FullGame = struct {
    claimed: bool,
    family_status: []const Family,
};

pub const ExcludedFile = struct {
    path: []const u8,
    sha256: []const u8,
    bytes: u64,
    reason: []const u8,
};

pub const FamilyProvenance = struct {
    family: []const u8,
    stage: []const u8,
    class: FileClass,
    manifest: []const u8,
    manifest_sha256: []const u8,
    files: u64,
    excluded: []const ExcludedFile,
};

pub const Provenance = struct {
    path: []const u8,
    assembler: []const u8,
    content_families: []const FamilyProvenance,
};

pub const Notices = struct {
    notice: []const u8,
    components: []const u8,
    notice_sha256: []const u8,
    components_sha256: []const u8,
    legal: []const []const u8,
};

pub const Signing = struct {
    algorithm: []const u8,
    key_id: []const u8,
    authenticity: []const u8,
};

pub const Candidate = struct {
    name: []const u8,
    bundle_id: []const u8,
    status: []const u8,
};

pub const Manifest = struct {
    schema: []const u8,
    pack: []const u8,
    candidate: Candidate,
    base_commit: []const u8,
    hash_rules: HashRules,
    files: []const File,
    executable: Executable,
    files_identity: []const u8,
    content_identity: []const u8,
    identity: []const u8,
    user_state: UserState,
    media: Media,
    reviewed: Reviewed,
    full_game: FullGame,
    notices: Notices,
    provenance: Provenance,
    signing: Signing,

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Manifest) {
        return std.json.parseFromSlice(Manifest, allocator, bytes, .{ .ignore_unknown_fields = true });
    }

    /// Full structural validation, including both declared identity rules.
    pub fn validate(self: *const Manifest, allocator: std.mem.Allocator) !void {
        if (!std.mem.eql(u8, self.schema, schema)) return error.UnsupportedManifestSchema;
        if (!std.mem.eql(u8, self.hash_rules.schema, hash_rules_schema)) return error.UnsupportedHashRules;
        if (!std.mem.eql(u8, self.hash_rules.algorithm, "sha256")) return error.UnsupportedAlgorithm;
        if (!self.hash_rules.no_absolute_paths or !self.hash_rules.no_build_host_paths) return error.HashRulesAllowHostPaths;
        if (self.files.len == 0) return error.EmptyManifest;
        if (self.base_commit.len != 40) return error.InvalidBaseCommit;

        var content_count: usize = 0;
        for (self.files, 0..) |row, i| {
            try safeResourcesPath(row.path);
            try validateHex(row.sha256);
            if (row.role == .reviewed_asset and row.class != .reviewed) return error.ReviewedRoleNeedsReviewedClass;
            if (row.class == .reviewed and row.role != .reviewed_asset) return error.ReviewedClassNeedsReviewedRole;
            if (row.role == .content) content_count += 1;
            for (self.files[0..i]) |other| {
                if (std.mem.eql(u8, row.path, other.path)) return error.DuplicatePath;
                if (std.mem.eql(u8, row.sha256, other.sha256) and row.class != other.class) return error.IdentityCollision;
            }
        }
        if (content_count == 0) return error.NoContent;

        try self.executable.validate();
        try self.user_state.validate();
        try validateMedia(self);
        try validateReviewed(self);

        var files_hex: Identity = undefined;
        try filesIdentity(allocator, self.files, &files_hex);
        if (!std.mem.eql(u8, &files_hex, self.files_identity)) return error.FilesIdentityMismatch;
        var content_hex: Identity = undefined;
        try contentIdentity(allocator, self.files, &content_hex);
        if (!std.mem.eql(u8, &content_hex, self.content_identity)) return error.ContentIdentityMismatch;
        var bundle_hex: Identity = undefined;
        bundleIdentity(&files_hex, self.executable.sha256, self.base_commit, &bundle_hex);
        if (!std.mem.eql(u8, &bundle_hex, self.identity)) return error.BundleIdentityMismatch;

        for (self.full_game.family_status) |family| {
            if (family.id.len == 0 or family.stage.len == 0 or family.required_for.len == 0 or family.blocker.len == 0) {
                return error.UntypedFamily;
            }
        }
        if (!std.mem.eql(u8, self.notices.notice, "NOTICE.txt") and !std.mem.endsWith(u8, self.notices.notice, "/NOTICE.txt")) return error.UnexpectedNoticePath;
        try validateHex(self.notices.notice_sha256);
        try validateHex(self.notices.components_sha256);
        try safeResourcesPath(self.provenance.path);
    }
};

pub const Identity = [64]u8;

pub fn sha256Hex(bytes: []const u8) Identity {
    return validation.sha256Hex(bytes);
}

fn validateHex(value: []const u8) !void {
    if (!validation.isLowerHex64(value)) return error.InvalidHash;
}

pub fn filesIdentity(allocator: std.mem.Allocator, files: []const File, out: *Identity) !void {
    const sorted = try allocator.dupe(File, files);
    defer allocator.free(sorted);
    std.mem.sort(File, sorted, {}, struct {
        fn less(_: void, a: File, b: File) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.less);
    var hasher = Sha256.init(.{});
    for (sorted) |row| {
        hasher.update(row.path);
        hasher.update(&[_]u8{0});
        hasher.update(row.sha256);
        hasher.update(&[_]u8{0});
        var size_buffer: [20]u8 = undefined;
        const size_text = try std.fmt.bufPrint(&size_buffer, "{d}", .{row.size});
        hasher.update(size_text);
        hasher.update(&[_]u8{0});
        hasher.update(@tagName(row.class));
        hasher.update(&[_]u8{0});
        hasher.update(@tagName(row.role));
        hasher.update("\n");
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    out.* = std.fmt.bytesToHex(digest, .lower);
}

pub fn contentIdentity(allocator: std.mem.Allocator, files: []const File, out: *Identity) !void {
    var count: usize = 0;
    for (files) |row| {
        if (row.role == .content) count += 1;
    }
    const content = try allocator.alloc(File, count);
    defer allocator.free(content);
    var index: usize = 0;
    for (files) |row| {
        if (row.role == .content) {
            content[index] = row;
            index += 1;
        }
    }
    try filesIdentity(allocator, content, out);
}

pub fn bundleIdentity(files_hex: *const Identity, executable_sha256: []const u8, base_commit: []const u8, out: *Identity) void {
    var hasher = Sha256.init(.{});
    hasher.update("bundle/1\n");
    hasher.update(files_hex);
    hasher.update("\n");
    hasher.update(executable_sha256);
    hasher.update("\n");
    hasher.update(base_commit);
    hasher.update("\n");
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    out.* = std.fmt.bytesToHex(digest, .lower);
}

/// A manifest file path is relative to the bundle's Contents/Resources root.
pub fn safeResourcesPath(path: []const u8) !void {
    try safePath(path);
    if (std.mem.startsWith(u8, path, "Contents/")) return error.PathIsNotResourcesRelative;
}

/// A path made of safe, non-escaping components.  Spaces are legitimate
/// ("Library/Application Support").
pub fn safePath(path: []const u8) !void {
    if (path.len == 0 or path.len > 1024) return error.UnsafePath;
    if (path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null) return error.UnsafePath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.UnsafePath;
    }
}

fn validateMedia(self: *const Manifest) !void {
    if (self.media.reviewed.len != 0) return error.ReviewedMediaNeedsReceipt;
    if (!std.mem.eql(u8, self.media.schema, "suikoden-media-identity/1")) return error.UnsupportedMediaSchema;
    var media_count: usize = 0;
    for (self.files) |row| {
        if (row.media) media_count += 1;
    }
    if (media_count != self.media.candidate.len) return error.MediaCountMismatch;
    for (self.media.candidate) |entry| {
        var found = false;
        for (self.files) |row| {
            if (row.media and std.mem.eql(u8, row.path, entry.path)) {
                if (!std.mem.eql(u8, row.sha256, entry.sha256)) return error.MediaHashMismatch;
                if (row.class != .candidate) return error.CandidateMediaMustBeCandidate;
                found = true;
            }
        }
        if (!found) return error.MediaEntryWithoutFile;
    }
}

fn validateReviewed(self: *const Manifest) !void {
    if (self.reviewed.packaged) return error.ReviewedRowsMayNotBePackaged;
    for (self.reviewed.files) |row| {
        try safePath(row.path);
        try validateHex(row.sha256);
        for (self.files) |packaged| {
            if (std.mem.eql(u8, packaged.path, row.path)) return error.ReviewedPathCollidesWithCandidate;
        }
    }
}

pub fn validateUserState(user_state: UserState) !void {
    if (!std.mem.eql(u8, user_state.schema, "suikoden-user-state/1")) return error.UnsupportedUserState;
    if (!std.mem.eql(u8, user_state.root_relative_to, "HOME")) return error.UnsupportedUserRoot;
    try safePath(user_state.root);
    try safePath(user_state.settings);
    if (user_state.saves.len == 0) return error.NoSaveLayout;
    for (user_state.saves) |name| try safePath(name);
    for (user_state.backups) |name| try safePath(name);
    try safePath(user_state.checks);
}
