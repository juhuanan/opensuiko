//! Signature envelope.
//!
//! The envelope is a symmetric HMAC-SHA256 seal over the exact manifest bytes.
//! It proves the manifest was sealed with the same key; it is not a public-key
//! authenticity proof and it is not a publication claim.
const std = @import("std");
const validation = @import("validation");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const schema = "suikoden-private-candidate-signature/1";

pub const Envelope = struct {
    schema: []const u8,
    algorithm: []const u8,
    key_id: []const u8,
    manifest_sha256: []const u8,
    value: []const u8,
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Envelope) {
    return std.json.parseFromSlice(Envelope, allocator, bytes, .{ .ignore_unknown_fields = true });
}

pub fn verify(envelope: *const Envelope, manifest_bytes: []const u8, key: []const u8) !void {
    if (!std.mem.eql(u8, envelope.schema, schema)) return error.UnsupportedSignatureSchema;
    if (!std.mem.eql(u8, envelope.algorithm, "hmac-sha256")) return error.UnsupportedAlgorithm;
    if (envelope.manifest_sha256.len != 64 or envelope.value.len != 64) return error.InvalidSignatureLength;
    if (envelope.key_id.len == 0) return error.MissingKeyId;
    const manifest_hex = validation.sha256Hex(manifest_bytes);
    if (!std.mem.eql(u8, &manifest_hex, envelope.manifest_sha256)) return error.ManifestDigestMismatch;
    var expected: [32]u8 = undefined;
    HmacSha256.create(&expected, manifest_bytes, key);
    var actual: [32]u8 = undefined;
    const written = std.fmt.hexToBytes(&actual, envelope.value) catch return error.InvalidSignatureEncoding;
    if (written.len != actual.len) return error.InvalidSignatureEncoding;
    if (!std.crypto.timing_safe.eql([32]u8, expected, actual)) return error.SignatureMismatch;
}

/// Produce an envelope (used by focused tests and by an operator tool that
/// wants to avoid Python).
pub fn sign(allocator: std.mem.Allocator, manifest_bytes: []const u8, key: []const u8, key_id: []const u8) ![]u8 {
    var mac: [32]u8 = undefined;
    HmacSha256.create(&mac, manifest_bytes, key);
    const manifest_hex = validation.sha256Hex(manifest_bytes);
    const mac_hex = std.fmt.bytesToHex(mac, .lower);
    const envelope = Envelope{
        .schema = schema,
        .algorithm = "hmac-sha256",
        .key_id = key_id,
        .manifest_sha256 = &manifest_hex,
        .value = &mac_hex,
    };
    return std.json.Stringify.valueAlloc(allocator, envelope, .{});
}
