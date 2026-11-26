//! Shared conversions for signed values with 12 fractional bits.
const std = @import("std");

pub const fraction_bits = 12;

/// Arithmetic shift, including for negative fractions and wide products.
pub fn floorToInt(raw: anytype) @TypeOf(raw) {
    return raw >> fraction_bits;
}

pub fn truncateToInt(raw: i32) i32 {
    return @divTrunc(raw, Value.one);
}

pub const Value = struct {
    raw: i32,

    pub const one: i32 = 1 << fraction_bits;

    /// The shift retains the low 32 bits.
    pub fn fromInt(value: i32) Value {
        return .{ .raw = value << fraction_bits };
    }

    pub fn toInt(self: Value) i32 {
        return floorToInt(self.raw);
    }

    pub fn toFloat(self: Value) f32 {
        return @as(f32, @floatFromInt(self.raw)) / @as(f32, @floatFromInt(Value.one));
    }
};

test "Q12 conversions preserve signed fractions and operand width" {
    try std.testing.expectEqual(@as(i32, -2), floorToInt(@as(i32, -4097)));
    try std.testing.expectEqual(@as(i32, -1), truncateToInt(-4097));
    try std.testing.expectEqual(@as(i64, 524288), floorToInt(@as(i64, 2147483649)));
    try std.testing.expectEqual(std.math.minInt(i32), Value.fromInt(524288).raw);
    try std.testing.expectEqual(@as(f32, -0.5), (Value{ .raw = -2048 }).toFloat());
}
