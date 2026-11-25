const std = @import("std");
const field = @import("field");

test "embedded ZON inn rules match the JSON oracle" {
    const allocator = std.testing.allocator;
    const inn = field.inn.embedded();
    try inn.validate();
    const parsed_inn = try field.inn.load(allocator, field.inn.json);
    defer parsed_inn.deinit();
    try std.testing.expectEqualDeep(parsed_inn.value, inn);
}
