const std = @import("std");
const rl = @import("raylib");
const settings = @import("pause_menu").settings;
pub fn load(init: std.process.Init, path: ?[]const u8) settings.Value {
    const directory = std.Io.Dir.cwd().openDir(init.io, path orelse return .{}, .{}) catch |err| {
        if (err != error.FileNotFound) std.log.warn("Settings directory: {s}", .{@errorName(err)});
        return .{};
    };
    defer directory.close(init.io);
    return settings.read(init.io, init.gpa, directory) catch |err| {
        if (err != error.FileNotFound) std.log.warn("Settings: {s}; using defaults", .{@errorName(err)});
        return .{};
    };
}
pub fn apply(value: settings.Value) void {
    if (rl.isWindowFullscreen() != value.fullscreen) rl.toggleFullscreen();
    if (value.vsync) rl.setWindowState(.{ .vsync_hint = true }) else rl.clearWindowState(.{ .vsync_hint = true });
}
pub fn save(init: std.process.Init, path: ?[]const u8, value: settings.Value) !void {
    apply(value);
    const directory = try std.Io.Dir.cwd().createDirPathOpen(init.io, path orelse return error.SaveDirectoryUnavailable, .{});
    defer directory.close(init.io);
    try settings.write(init.io, init.gpa, directory, value);
}
