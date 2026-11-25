const std = @import("std");

pub fn fromExecutable(allocator: std.mem.Allocator, directory: []const u8) ![]u8 {
    const bundle = std.mem.eql(u8, std.fs.path.basename(directory), "MacOS") and std.mem.eql(u8, std.fs.path.basename(std.fs.path.dirname(directory) orelse ""), "Contents");
    return std.fs.path.resolve(allocator, if (bundle) &.{ directory, "../Resources/content" } else &.{ directory, "../../../kit/work/build/journey" });
}
