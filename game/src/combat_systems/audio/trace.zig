//! Bounded, deterministic trace sink.
//!
//! One row per observable host act, in the exact grammar the independent
//! Python model emits (the extraction pipeline).  The gate compares
//! row for row, so formatting is part of the contract.

const std = @import("std");

pub const capacity = 128;
pub const max_row = 192;

pub const Trace = struct {
    rows: [capacity][max_row]u8 = @splat(@splat(0)),
    lens: [capacity]usize = @splat(0),
    len: usize = 0,

    pub fn append(self: *Trace, comptime fmt: []const u8, args: anytype) !void {
        if (self.len == capacity) return error.TraceFull;
        var body: [max_row]u8 = undefined;
        const text = try std.fmt.bufPrint(&body, fmt, args);
        const text_row = try std.fmt.bufPrint(&self.rows[self.len], "{d:0>3}|{s}", .{ self.len, text });
        self.lens[self.len] = text_row.len;
        self.len += 1;
    }

    pub fn count(self: *const Trace) usize {
        return self.len;
    }

    pub fn row(self: *const Trace, index: usize) []const u8 {
        return self.rows[index][0..self.lens[index]];
    }

    pub fn join(self: *const Trace, allocator: std.mem.Allocator) ![]u8 {
        var total: usize = 0;
        for (0..self.len) |index| {
            total += self.lens[index];
            if (index + 1 < self.len) total += 1;
        }
        const bytes = try allocator.alloc(u8, total);
        var cursor: usize = 0;
        for (0..self.len) |index| {
            @memcpy(bytes[cursor..][0..self.lens[index]], self.row(index));
            cursor += self.lens[index];
            if (index + 1 < self.len) {
                bytes[cursor] = '\n';
                cursor += 1;
            }
        }
        return bytes;
    }

    pub fn expectRows(self: *const Trace, expected: []const []const u8) !void {
        try std.testing.expectEqual(expected.len, self.len);
        for (expected, 0..) |want, index| {
            try std.testing.expectEqualStrings(want, self.row(index));
        }
    }
};
