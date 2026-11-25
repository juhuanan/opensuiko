//! Canonical campaign name buffer.
//!
//! The original New Game flow opens a name grid after "New game" and rejects
//! an empty name before the "Is this OK?" yes/no prompt (registry rows
//! extract_A rows 1431-1433).  The grid alphabet and maximum
//! length are *not* derived; the packaged port contract is the same 32-byte
//! printable-ASCII buffer the read-only shared `save_slots.Label` already
//! stores.  Nothing here fabricates a default hero name: a fresh name entry
//! starts empty and the module refuses to start a campaign with an empty one.
const std = @import("std");

pub const capacity: usize = 32;
pub const min_chars: usize = 1;

pub const Name = struct {
    bytes: [capacity]u8 = @splat(0),
    len: u8 = 0,

    pub fn init(value: []const u8) !Name {
        var result = Name{};
        for (value) |byte| switch (result.appendByte(byte)) {
            .accepted => {},
            .full, .rejected_character => return error.InvalidName,
        };
        try result.validate();
        return result;
    }

    pub fn text(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn isEmpty(self: Name) bool {
        return self.len == 0;
    }

    pub fn isFull(self: Name) bool {
        return self.len == capacity;
    }

    pub fn clear(self: *Name) void {
        self.len = 0;
        self.bytes = @splat(0);
    }

    /// Appends one character.  A rejected character or a full buffer is
    /// reported to the caller so the screen can say so instead of silently
    /// dropping input; accepted text is never rewritten.
    pub fn appendByte(self: *Name, byte: u8) Append {
        if (!printable(byte)) return .rejected_character;
        if (self.len == capacity) return .full;
        self.bytes[self.len] = byte;
        self.len += 1;
        return .accepted;
    }

    pub fn append(self: *Name, value: []const u8) Append {
        var worst: Append = .accepted;
        for (value) |byte| {
            const result = self.appendByte(byte);
            if (result == .full) return .full;
            if (result == .rejected_character) worst = .rejected_character;
        }
        return worst;
    }

    pub fn erase(self: *Name) void {
        if (self.len == 0) return;
        self.len -= 1;
        self.bytes[self.len] = 0;
    }

    pub fn validate(self: Name) !void {
        if (self.len < min_chars) return error.EmptyName;
        if (self.len > capacity) return error.NameTooLong;
        for (self.bytes[0..self.len]) |byte| if (!printable(byte)) return error.InvalidNameByte;
    }

    pub fn eql(self: Name, value: []const u8) bool {
        return std.mem.eql(u8, self.text(), value);
    }
};

pub const Append = enum { accepted, rejected_character, full };

pub fn printable(byte: u8) bool {
    return byte >= 0x20 and byte <= 0x7e;
}

/// Number of display lines a name needs at `width` columns.  Presentation uses
/// this instead of clipping: a long name is wrapped, never truncated.
pub fn wrapCount(length: usize, width: usize) usize {
    std.debug.assert(width > 0);
    return if (length == 0) 0 else (length + width - 1) / width;
}

/// Splits `value` into `out` slices of at most `width` bytes and returns their
/// count.  Concatenating the slices reproduces `value` exactly.
pub fn wrap(value: []const u8, width: usize, out: [][]const u8) !usize {
    if (width == 0) return error.InvalidWidth;
    const needed = wrapCount(value.len, width);
    if (out.len < needed) return error.LinesTooShort;
    var start: usize = 0;
    var count: usize = 0;
    while (start < value.len) : (start += width) {
        const end = @min(value.len, start + width);
        out[count] = value[start..end];
        count += 1;
    }
    return count;
}

test "name rejects empty and control bytes" {
    const empty = Name{};
    try std.testing.expectError(error.EmptyName, empty.validate());
    var name = Name{};
    try std.testing.expectEqual(Append.rejected_character, name.appendByte(0x1f));
    try std.testing.expectEqual(Append.rejected_character, name.appendByte(0x7f));
    try std.testing.expectEqual(@as(u8, 0), name.len);
}

test "wrap reproduces every byte" {
    var lines: [capacity][]const u8 = undefined;
    const value = "Abcdefghij klmnopqrstuvwxyz 0123";
    const count = try wrap(value, 5, &lines);
    try std.testing.expectEqual(wrapCount(value.len, 5), count);
    var joined: [capacity]u8 = undefined;
    var at: usize = 0;
    for (lines[0..count]) |line| {
        @memcpy(joined[at..][0..line.len], line);
        at += line.len;
    }
    try std.testing.expectEqualStrings(value, joined[0..at]);
}
