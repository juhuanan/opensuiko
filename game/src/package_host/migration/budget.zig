//! Bounded, arena-backed JSON input for the full-campaign snapshot.
//!
//! Two independent limits apply before any value is constructed:
//!   * the encoded size of the document, and
//!   * the bracket nesting depth, scanned iteratively so a hostile document
//!     cannot exhaust the native stack through a recursive parse.
//! A third limit caps total arena allocation, so a document whose shape is
//! legal but whose expanded form is huge still fails as `OutOfMemory` instead
//! of growing without bound.
//!
//! Port level only: no original instruction, emulator, window, media or real
//! user save is touched.

const std = @import("std");

pub const Limits = struct {
    /// Largest accepted encoded document.
    bytes: usize = 512 * 1024,
    /// Largest accepted arena footprint while decoding.
    arena_bytes: usize = 8 * 1024 * 1024,
    /// Deepest accepted `{`/`[` nesting.
    depth: usize = 24,
};

pub const default_limits: Limits = .{};

pub const ParseError = error{
    DocumentTooLarge,
    DocumentTooDeep,
    DocumentUnbalanced,
    DocumentNotJson,
};

/// Reject an oversized document before it reaches the JSON scanner.
pub fn checkSize(bytes: []const u8, limits: Limits) ParseError!void {
    if (bytes.len > limits.bytes) return error.DocumentTooLarge;
}

/// Iteratively scan bracket nesting outside strings.  This is not a JSON
/// validator; it exists so the recursive parser below can never be handed a
/// document that could exhaust the native stack.
pub fn scanDepth(bytes: []const u8, limits: Limits) ParseError!void {
    var depth: usize = 0;
    var maximum: usize = 0;
    var in_string = false;
    var escaped = false;
    var opened = false;
    for (bytes) |byte| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        switch (byte) {
            '"' => in_string = true,
            '{', '[' => {
                opened = true;
                depth += 1;
                if (depth > maximum) maximum = depth;
            },
            '}', ']' => {
                if (depth == 0) return error.DocumentUnbalanced;
                depth -= 1;
            },
            else => {},
        }
    }
    if (in_string or !opened) return error.DocumentNotJson;
    if (depth != 0) return error.DocumentUnbalanced;
    if (maximum > limits.depth) return error.DocumentTooDeep;
}

/// An allocator wrapper with a hard total-bytes budget.  `ArenaAllocator`
/// asks the parent for chunks, so capping the parent caps the arena.
pub const Budget = struct {
    parent: std.mem.Allocator,
    remaining: usize,

    pub fn init(parent: std.mem.Allocator, capacity: usize) Budget {
        return .{ .parent = parent, .remaining = capacity };
    }

    pub fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(context));
        if (len > self.remaining) return null;
        const memory = self.parent.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.remaining -= len;
        return memory;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Budget = @ptrCast(@alignCast(context));
        if (new_len > memory.len) {
            const growth = new_len - memory.len;
            if (growth > self.remaining) return false;
            if (!self.parent.rawResize(memory, alignment, new_len, ret_addr)) return false;
            self.remaining -= growth;
            return true;
        }
        const shrink = memory.len - new_len;
        if (!self.parent.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.remaining += shrink;
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(context));
        if (new_len > memory.len and new_len - memory.len > self.remaining) return null;
        const result = self.parent.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len > memory.len) {
            self.remaining -= new_len - memory.len;
        } else {
            self.remaining += memory.len - new_len;
        }
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Budget = @ptrCast(@alignCast(context));
        self.parent.rawFree(memory, alignment, ret_addr);
        self.remaining += memory.len;
    }
};

pub fn Parsed(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        arena: *std.heap.ArenaAllocator,
        budget: *Budget,
        value: T,

        pub fn deinit(self: Self) void {
            self.arena.deinit();
            self.allocator.destroy(self.budget);
            self.allocator.destroy(self.arena);
        }
    };
}

/// Decode `T` from `bytes` under all three limits.  The returned value owns an
/// arena and stays valid until `deinit`; it never borrows `bytes`.
pub fn decode(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) !Parsed(T) {
    try checkSize(bytes, limits);
    try scanDepth(bytes, limits);
    const budget = try allocator.create(Budget);
    errdefer allocator.destroy(budget);
    budget.* = Budget.init(allocator, limits.arena_bytes);
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(budget.allocator());
    errdefer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(T, arena.allocator(), bytes, .{});
    return .{ .allocator = allocator, .arena = arena, .budget = budget, .value = value };
}

test "depth scan rejects deep nesting before parsing and ignores braces in strings" {
    const limits: Limits = .{ .depth = 3 };
    try scanDepth("{\"a\":[1,{\"b\":2}]}", limits);
    try std.testing.expectError(error.DocumentTooDeep, scanDepth("{\"a\":[[[[1]]]]}", limits));
    try std.testing.expectError(error.DocumentUnbalanced, scanDepth("{\"a\":1", limits));
    try std.testing.expectError(error.DocumentUnbalanced, scanDepth("}", limits));
    try std.testing.expectError(error.DocumentNotJson, scanDepth("plain text", limits));
    try scanDepth("{\"a\":\"}}}[[[\"}", limits);
    try std.testing.expectError(error.DocumentNotJson, scanDepth("{\"a\":\"unterminated}", limits));
}

test "the allocation budget is a hard cap" {
    var budget = Budget.init(std.testing.allocator, 1024);
    const allocator = budget.allocator();
    const small = try allocator.alloc(u8, 512);
    defer allocator.free(small);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 2048));
    const big = try allocator.alloc(u8, 512);
    allocator.free(big);
    try std.testing.expectError(error.DocumentTooLarge, decode(struct { a: u8 }, std.testing.allocator, "{\"a\":1}", .{ .bytes = 2 }));
}
