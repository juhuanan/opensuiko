const std = @import("std");
pub const json = @import("inn_data").json;
pub const zon = @import("inn_zon").data;

pub const Rules = struct {
    schema: []const u8,
    room: []const u8,
    npc: []const u8,
    price_per_member: u16,
    choices: [2][]const u8,
    insufficient_funds: []const u8,

    pub fn validate(self: Rules) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-inn/1")) return error.UnsupportedInnSchema;
        if (self.price_per_member == 0) return error.InvalidInn;
        for ([_][]const u8{ self.room, self.npc, self.choices[0], self.choices[1], self.insufficient_funds }) |value| {
            if (value.len == 0 or value.len > 256 or std.mem.indexOfScalar(u8, value, 0) != null or !std.unicode.utf8ValidateSlice(value)) return error.InvalidInn;
        }
    }
};

pub fn embedded() Rules {
    return .{
        .schema = zon.schema,
        .room = zon.room,
        .npc = zon.npc,
        .price_per_member = zon.price_per_member,
        .choices = .{ zon.choices[0], zon.choices[1] },
        .insufficient_funds = zon.insufficient_funds,
    };
}

pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Rules) {
    if (bytes.len > 4096) return error.InnDataTooLarge;
    const parsed = try std.json.parseFromSlice(Rules, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}
