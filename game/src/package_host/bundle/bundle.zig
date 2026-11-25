//! Bundle verifier.
//!
//! Reads the packaged resources through an opened directory handle and checks
//! every declared file, its size and its sha256.  Reviewed rows are declared
//! dependencies, not shipped bytes: they are counted and skipped, and a
//! candidate file that collides with one is rejected by the manifest contract.
const std = @import("std");
const manifest = @import("manifest.zig");

pub const Report = struct {
    files: usize = 0,
    content_files: usize = 0,
    media_files: usize = 0,
    reviewed_dependencies: usize = 0,
    bytes: u64 = 0,
};

pub const Options = struct {
    /// Refuse a single file larger than this; a private candidate's content is
    /// small enough that an unbounded read is a red flag, not a feature.
    max_file_bytes: usize = 16 * 1024 * 1024,
};

pub fn verifyFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    resources: std.Io.Dir,
    value: *const manifest.Manifest,
    options: Options,
) !Report {
    var report = Report{ .reviewed_dependencies = value.reviewed.files.len };
    for (value.files) |row| {
        if (row.class == .reviewed or row.role == .reviewed_asset) return error.ReviewedRowPackaged;
        const bytes = resources.readFileAlloc(io, row.path, allocator, .limited(options.max_file_bytes)) catch |err| switch (err) {
            error.FileNotFound => return error.MissingFile,
            else => return err,
        };
        defer allocator.free(bytes);
        if (bytes.len != row.size) return error.SizeMismatch;
        const digest = manifest.sha256Hex(bytes);
        if (!std.mem.eql(u8, &digest, row.sha256)) return error.HashMismatch;
        report.files += 1;
        report.bytes += bytes.len;
        if (row.role == .content) report.content_files += 1;
        if (row.media) report.media_files += 1;
    }
    if (report.files == 0) return error.NoPackagedFiles;
    return report;
}

/// The signed copy's hash lives in the sibling receipt, so the bundle verifier
/// checks the receipt binding instead of the pre-sign manifest hash.
pub fn verifySigningReceipt(
    io: std.Io,
    allocator: std.mem.Allocator,
    directory: std.Io.Dir,
    receipt_path: []const u8,
    value: *const manifest.Manifest,
    manifest_bytes: []const u8,
    executable_bytes: []const u8,
) !void {
    const receipt_bytes = directory.readFileAlloc(io, receipt_path, allocator, .limited(64 * 1024)) catch return error.MissingSigningReceipt;
    defer allocator.free(receipt_bytes);
    const parsed = std.json.parseFromSlice(Receipt, allocator, receipt_bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidSigningReceipt;
    defer parsed.deinit();
    const receipt = parsed.value;
    if (!std.mem.eql(u8, receipt.schema, "suikoden-private-candidate-signing/1")) return error.InvalidSigningReceipt;
    if (!std.mem.eql(u8, receipt.scheme, "adhoc")) return error.InvalidSigningReceipt;
    const manifest_hex = manifest.sha256Hex(manifest_bytes);
    if (!std.mem.eql(u8, &manifest_hex, receipt.manifest_sha256)) return error.SigningReceiptManifestMismatch;
    const executable_hex = manifest.sha256Hex(executable_bytes);
    if (!std.mem.eql(u8, &executable_hex, receipt.executable_sha256)) return error.SignedExecutableMismatch;
    if (!std.mem.endsWith(u8, receipt.bundle, ".app")) return error.SigningReceiptBundleMismatch;
    _ = value;
}

const Receipt = struct {
    schema: []const u8,
    scheme: []const u8,
    bundle: []const u8,
    manifest_sha256: []const u8,
    executable_sha256: []const u8,
    codesign_verify: []const u8,
    hashed_by_bundle_rules: bool = false,
};
