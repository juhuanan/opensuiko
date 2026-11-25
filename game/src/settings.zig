const std = @import("std");
pub const filename = "settings.zon";
pub const legacy_filename = "settings.json";
pub const Value = struct {
    schema: []const u8 = "suikoden-settings/1",
    music: u8 = 8,
    effects: u8 = 8,
    fullscreen: bool = false,
    vsync: bool = true,
    pub fn validate(self: Value) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-settings/1")) return error.UnsupportedSettings;
        if (self.music > 10 or self.effects > 10) return error.InvalidVolume;
    }
    pub fn adjust(self: *Value, row: usize, increase: bool) void {
        switch (row) {
            0 => self.music = if (increase) @min(10, self.music +| 1) else self.music -| 1,
            1 => self.effects = if (increase) @min(10, self.effects +| 1) else self.effects -| 1,
            2 => self.fullscreen = !self.fullscreen,
            3 => self.vsync = !self.vsync,
            else => {},
        }
    }
    pub fn musicVolume(self: Value) f32 {
        return @as(f32, @floatFromInt(self.music)) / 10;
    }
    pub fn effectsVolume(self: Value) f32 {
        return @as(f32, @floatFromInt(self.effects)) / 10;
    }
};
pub fn read(io: std.Io, allocator: std.mem.Allocator, directory: std.Io.Dir) !Value {
    const bytes = directory.readFileAlloc(io, filename, allocator, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => return readLegacyJson(io, allocator, directory),
        else => return err,
    };
    defer allocator.free(bytes);
    const source = try allocator.allocSentinel(u8, bytes.len, 0);
    defer allocator.free(source);
    @memcpy(source, bytes);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var value = try std.zon.parse.fromSlice(Value, .{
        .gpa = allocator,
        .arena = arena.allocator(),
        .source = source,
        .diagnostics = &diagnostics,
    });
    try value.validate();
    value.schema = "suikoden-settings/1";
    return value;
}

fn readLegacyJson(io: std.Io, allocator: std.mem.Allocator, directory: std.Io.Dir) !Value {
    const bytes = try directory.readFileAlloc(io, legacy_filename, allocator, .limited(4096));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Value, allocator, bytes, .{});
    defer parsed.deinit();
    try parsed.value.validate();
    var value = parsed.value;
    value.schema = "suikoden-settings/1";
    return value;
}
pub fn write(io: std.Io, allocator: std.mem.Allocator, directory: std.Io.Dir, value: Value) !void {
    try value.validate();
    const bytes = try std.fmt.allocPrint(allocator, "{f}", .{std.zon.fmt(value, .{})});
    defer allocator.free(bytes);
    var atomic = try directory.createFileAtomic(io, filename, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}
