const std = @import("std");

/// Return true when `text` is a 64-character hexadecimal string.
pub fn isHex64(text: []const u8) bool {
    if (text.len != 64) return false;
    for (text) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

/// Return true when `text` is a 64-character lowercase hexadecimal string.
pub fn isLowerHex64(text: []const u8) bool {
    if (text.len != 64) return false;
    for (text) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return false;
    }
    return true;
}

/// Return true when `id` has length `1..max_len` and contains only ASCII
/// alphanumeric bytes or characters present in `extra`.
pub fn isAsciiId(id: []const u8, max_len: usize, extra: []const u8) bool {
    if (id.len == 0 or id.len > max_len) return false;
    for (id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, extra, byte) == null) {
            return false;
        }
    }
    return true;
}

/// Return true when `text` has length `min_len..max_len`, contains no NUL bytes,
/// and is valid UTF-8.
pub fn isUtf8Text(text: []const u8, min_len: usize, max_len: usize) bool {
    if (text.len < min_len or text.len > max_len) return false;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return false;
    return std.unicode.utf8ValidateSlice(text);
}

/// Return true when `text` has length `1..max_len`, contains no ASCII control
/// characters (`< 32` or `127`), and is valid UTF-8.
pub fn isPrintableUtf8(text: []const u8, max_len: usize) bool {
    if (text.len == 0 or text.len > max_len or !std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |byte| {
        if (byte < 32 or byte == 127) return false;
    }
    return true;
}

/// Parse a fixed-width `"scenario_NNNN"` identifier into its scenario number.
pub fn parseScenarioId(id: []const u8) ?u16 {
    if (id.len != 13 or !std.mem.startsWith(u8, id, "scenario_")) return null;
    return std.fmt.parseInt(u16, id[9..], 10) catch null;
}

/// Compute the raw 32-byte SHA-256 digest of `bytes`.
pub fn sha256(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

/// Compute the 64-character lowercase hexadecimal SHA-256 digest of `bytes`.
pub fn sha256Hex(bytes: []const u8) [64]u8 {
    return std.fmt.bytesToHex(sha256(bytes), .lower);
}

/// Compute the heap-allocated 64-character lowercase SHA-256 digest of `bytes`.
pub fn allocSha256Hex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const hex = sha256Hex(bytes);
    return allocator.dupe(u8, &hex);
}
