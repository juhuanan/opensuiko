const std = @import("std");

pub const Source = struct {
    operand: u8,
    character_id: []const u8,
    name: []const u8,
    source_character_id: u32,
    resource: []const u8,
    resource_sha256: []const u8,
    resource_lba: u32 = 0,
    resource_size: u32 = 0,
};

// VA1 0x3C carries these source character IDs as operands.
pub const sources = [_]Source{
    .{ .operand = 6, .character_id = "pahn", .name = "Pahn", .source_character_id = 6, .resource = "PAN.BIN", .resource_sha256 = "9a7d91cf447765f872329d5f181d14c92cf9de1b96096bb337374dc1e35a2c08", .resource_lba = 87070, .resource_size = 19924 },
    .{ .operand = 1, .character_id = "cleo", .name = "Cleo", .source_character_id = 1, .resource = "CRE.BIN", .resource_sha256 = "9dd723ce147ba56ebe19b46a492f99b8b6fe738a6203feb197226893141b528e", .resource_lba = 86663, .resource_size = 16952 },
    .{ .operand = 2, .character_id = "gremio", .name = "Gremio", .source_character_id = 2, .resource = "GRE.BIN", .resource_sha256 = "57e192f0f4270670c453e1441d72342b36136216099a652c0096502966ff680c", .resource_lba = 86780, .resource_size = 17636 },
    .{ .operand = 108, .character_id = "ted", .name = "Ted", .source_character_id = 108, .resource = "TED.BIN", .resource_sha256 = "6d82c2c6ce8a3b62410876513c3ddb4eea964c8ac63c3aa39504a37b6d4e1b71", .resource_lba = 87216, .resource_size = 14192 },
};

pub fn sourceFor(operand: u8) !Source {
    for (sources) |source| if (source.operand == operand) return source;
    return error.UnsupportedEventPartySelector;
}

// Compare contents of identity slices as well as every value field.
pub fn same(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice) blk: {
            if (a.len != b.len) break :blk false;
            for (a, b) |x, y| if (!same(x, y)) break :blk false;
            break :blk true;
        } else @compileError("unexpected pointer in party state"),
        .array => blk: {
            for (a, b) |x, y| if (!same(x, y)) break :blk false;
            break :blk true;
        },
        .optional => if (a) |x| if (b) |y| same(x, y) else false else b == null,
        .@"struct" => |s| blk: {
            inline for (s.field_names) |name| if (!same(@field(a, name), @field(b, name))) break :blk false;
            break :blk true;
        },
        else => a == b,
    };
}
