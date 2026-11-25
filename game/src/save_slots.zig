const std = @import("std");
pub const count = 3;
pub const Label = struct {
    bytes: [32]u8 = @splat(0),
    len: u8 = 0,
    pub fn init(value: []const u8) !Label {
        var result = Label{};
        if (value.len == 0 or value.len > result.bytes.len) return error.InvalidSaveName;
        @memcpy(result.bytes[0..value.len], value);
        result.len = @intCast(value.len);
        try result.validate();
        return result;
    }
    pub fn validate(self: Label) !void {
        if (self.len == 0 or self.len > self.bytes.len) return error.InvalidSaveName;
        if (std.mem.trim(u8, self.text(), " ").len == 0) return error.InvalidSaveName;
        for (self.bytes[0..self.len]) |byte| if (byte < 32 or byte > 126) return error.InvalidSaveName;
    }
    pub fn text(self: *const Label) []const u8 {
        return self.bytes[0..self.len];
    }
    pub fn append(self: *Label, value: []const u8) void {
        for (value) |byte| {
            if (byte < 32 or byte > 126 or self.len == self.bytes.len) continue;
            self.bytes[self.len] = byte;
            self.len += 1;
        }
    }
    pub fn erase(self: *Label) void {
        if (self.len == 0) return;
        self.len -= 1;
        self.bytes[self.len] = 0;
    }
    pub fn jsonStringify(self: Label, writer: anytype) !void {
        try writer.write(self.text());
    }
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Label {
        return init(try std.json.innerParse([]const u8, allocator, source, options)) catch return error.UnexpectedToken;
    }
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Label {
        return init(try std.json.innerParseFromValue([]const u8, allocator, source, options)) catch return error.UnexpectedToken;
    }
};
pub fn defaultLabel(index: usize) Label {
    return Label.init(switch (index) {
        0 => "Adventure 1",
        1 => "Adventure 2",
        else => "Adventure 3",
    }) catch unreachable;
}
pub const Summary = struct {
    status: enum { empty, ready, backup, damaged, future } = .empty,
    name: Label = .{},
    scene: []const u8 = "",
    leader: []const u8 = "",
    level: u8 = 0,
    seconds: u64 = 0,
};
pub fn emptySummaries() [count]Summary {
    var result: [count]Summary = @splat(.{});
    for (&result, 0..) |*entry, i| entry.name = defaultLabel(i);
    return result;
}
