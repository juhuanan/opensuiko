const std = @import("std");
const settings = @import("settings");

test "settings roundtrip as ZON and read legacy JSON" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var value: settings.Value = .{ .music = 7, .effects = 9, .fullscreen = true, .vsync = false };
    try settings.write(io, allocator, temp.dir, value);
    const zon_bytes = try temp.dir.readFileAlloc(io, settings.filename, allocator, .limited(4096));
    defer allocator.free(zon_bytes);
    try std.testing.expect(std.mem.indexOf(u8, zon_bytes, "music") != null);
    const loaded = try settings.read(io, allocator, temp.dir);
    try std.testing.expectEqual(value, loaded);

    value = .{ .music = 3, .effects = 4 };
    try temp.dir.deleteFile(io, settings.filename);
    try temp.dir.writeFile(io, .{ .sub_path = settings.legacy_filename, .data = "{\"schema\":\"suikoden-settings/1\",\"music\":3,\"effects\":4,\"fullscreen\":false,\"vsync\":true}" });
    const legacy = try settings.read(io, allocator, temp.dir);
    try std.testing.expectEqual(value, legacy);
}

test "malformed ZON settings are refused" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = settings.filename, .data = ".{" });
    try std.testing.expectError(error.ParseZon, settings.read(io, allocator, temp.dir));
}

test "unsupported settings schema is refused" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = settings.filename, .data = ".{ .schema = \"suikoden-settings/99\", .music = 1, .effects = 1, .fullscreen = false, .vsync = true }" });
    try std.testing.expectError(error.UnsupportedSettings, settings.read(io, allocator, temp.dir));
}
