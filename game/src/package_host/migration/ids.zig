//! Fixed-capacity identity primitives for the full-campaign snapshot.
//!
//! Every identifier and every variable-length list in the snapshot has a
//! compile-time bound, so a decoded campaign is a value with no heap
//! ownership: capture is a copy, a failed write cannot leave a half-updated
//! campaign behind, and a hostile file cannot make the parser allocate more
//! than the enclosing arena/limit allows.
//!
//! Port level only.  No original instruction, emulator, window, media or real
//! user save is involved.

const std = @import("std");

/// Longest snapshot identifier (roster/profile, room, service, duel, minigame).
pub const max_id = 32;
/// Longest block/chapter identifier.
pub const max_block = 32;

pub fn Id(comptime n: usize) type {
    return struct {
        const Self = @This();

        bytes: [n]u8 = @splat(0),
        len: u8 = 0,

        pub fn init(source_text: []const u8) !Self {
            var result = Self{};
            if (source_text.len == 0 or source_text.len > n) return error.InvalidIdentifier;
            @memcpy(result.bytes[0..source_text.len], source_text);
            result.len = @intCast(source_text.len);
            try result.validate();
            return result;
        }

        pub fn validate(self: Self) !void {
            if (self.len == 0 or self.len > n) return error.InvalidIdentifier;
            for (self.bytes[0..self.len]) |byte| switch (byte) {
                'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '\'' => {},
                else => return error.InvalidIdentifier,
            };
        }

        pub fn text(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn isSet(self: Self) bool {
            return self.len != 0;
        }

        pub fn eql(self: Self, other: []const u8) bool {
            return std.mem.eql(u8, self.text(), other);
        }

        pub fn jsonStringify(self: Self, writer: anytype) !void {
            try writer.write(self.text());
        }

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Self {
            return jsonParseFromValue(allocator, try std.json.innerParse(std.json.Value, allocator, source, options), options);
        }

        pub fn jsonParseFromValue(_: std.mem.Allocator, value: std.json.Value, _: std.json.ParseOptions) !Self {
            if (value != .string) return error.UnexpectedToken;
            // The empty string is the explicit "unset" value for optional
            // identities (world.room, hq.room, effect.id); a non-empty string
            // must still be a valid identifier.
            if (value.string.len == 0) return .{};
            return init(value.string) catch return error.UnexpectedToken;
        }
    };
}

/// A byte string encoded as lowercase hex in JSON.  Used for the 108-bit
/// recruit/presence map, the 240-byte source scenario and content digests.
pub fn HexBytes(comptime n: usize) type {
    return struct {
        const Self = @This();

        bytes: [n]u8 = @splat(0),

        pub fn jsonStringify(self: Self, writer: anytype) !void {
            const encoded = std.fmt.bytesToHex(self.bytes, .lower);
            try writer.write(&encoded);
        }

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Self {
            return jsonParseFromValue(allocator, try std.json.innerParse(std.json.Value, allocator, source, options), options);
        }

        pub fn jsonParseFromValue(_: std.mem.Allocator, value: std.json.Value, _: std.json.ParseOptions) !Self {
            if (value != .string) return error.UnexpectedToken;
            if (value.string.len != n * 2) return error.LengthMismatch;
            var result = Self{};
            const written = std.fmt.hexToBytes(&result.bytes, value.string) catch return error.UnexpectedToken;
            if (written.len != n) return error.LengthMismatch;
            return result;
        }

        pub fn eql(self: Self, other: Self) bool {
            return std.mem.eql(u8, &self.bytes, &other.bytes);
        }
    };
}

/// A bounded JSON array.  `items` past `len` are never read or written, so a
/// decoded value has no allocator and survives a struct copy.
pub fn List(comptime capacity: usize, comptime T: type) type {
    return struct {
        const Self = @This();

        items: [capacity]T = undefined,
        len: u8 = 0,

        pub fn slice(self: *const Self) []const T {
            return self.items[0..self.len];
        }

        pub fn mutableSlice(self: *Self) []T {
            return self.items[0..self.len];
        }

        pub fn append(self: *Self, item: T) !void {
            if (self.len == capacity) return error.TooManyEntries;
            self.items[self.len] = item;
            self.len += 1;
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        pub fn indexOf(self: Self, item: T) ?usize {
            for (self.slice(), 0..) |candidate, index| {
                if (std.meta.eql(candidate, item)) return index;
            }
            return null;
        }

        pub fn contains(self: Self, item: T) bool {
            return self.indexOf(item) != null;
        }

        pub fn removeAt(self: *Self, index: usize) void {
            std.debug.assert(index < self.len);
            var cursor = index;
            while (cursor + 1 < self.len) : (cursor += 1) self.items[cursor] = self.items[cursor + 1];
            self.len -= 1;
        }

        pub fn jsonStringify(self: *const Self, writer: anytype) !void {
            try writer.beginArray();
            for (self.slice()) |item| try writer.write(item);
            try writer.endArray();
        }

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Self {
            return jsonParseFromValue(allocator, try std.json.innerParse(std.json.Value, allocator, source, options), options);
        }

        pub fn jsonParseFromValue(allocator: std.mem.Allocator, value: std.json.Value, options: std.json.ParseOptions) !Self {
            if (value != .array) return error.UnexpectedToken;
            if (value.array.items.len > capacity) return error.LengthMismatch;
            var result = Self{};
            for (value.array.items) |entry| {
                const parsed = try std.json.innerParseFromValue(T, allocator, entry, options);
                result.items[result.len] = parsed;
                result.len += 1;
            }
            return result;
        }
    };
}

pub fn isHexLower(text: []const u8, comptime n: usize) bool {
    if (text.len != n * 2) return false;
    for (text) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

test "identifiers reject control, separators and overflow" {
    const id = try Id(8).init("vb6_room");
    try std.testing.expect(id.eql("vb6_room"));
    try std.testing.expectError(error.InvalidIdentifier, Id(8).init(""));
    try std.testing.expectError(error.InvalidIdentifier, Id(8).init("has space"));
    try std.testing.expectError(error.InvalidIdentifier, Id(8).init("sch/room"));
    try std.testing.expectError(error.InvalidIdentifier, Id(3).init("toolong"));
}

test "bounded lists never exceed capacity and round-trip through json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var list = List(2, u8){};
    try list.append(1);
    try list.append(2);
    try std.testing.expectError(error.TooManyEntries, list.append(3));
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, list, .{});
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("[1,2]", encoded);
    const decoded = try std.json.parseFromSliceLeaky(List(2, u8), allocator, encoded, .{});
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, decoded.slice());
    try std.testing.expectError(error.LengthMismatch, std.json.parseFromSliceLeaky(List(2, u8), allocator, "[1,2,3]", .{}));
}

test "hex bytes require the exact width and reject uppercase/non-hex" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const digest = try std.json.parseFromSliceLeaky(HexBytes(2), allocator, "\"00ff\"", .{});
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0xff }, &digest.bytes);
    try std.testing.expectError(error.LengthMismatch, std.json.parseFromSliceLeaky(HexBytes(2), allocator, "\"00ff00\"", .{}));
    try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSliceLeaky(HexBytes(2), allocator, "\"0x0F\"", .{}));
}
