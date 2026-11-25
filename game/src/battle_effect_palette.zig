// Generated from the recovered BATTLE.BIN packed palette bank.
// Slot mapping: x=928+16*(slot%2), y=384+slot/2.
const std = @import("std");
const rl = @import("raylib");

pub const Palette = [16]rl.Color;

pub const fire: Palette = .{
    .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    .{ .r = 65, .g = 0, .b = 0, .a = 255 },
    .{ .r = 90, .g = 0, .b = 0, .a = 255 },
    .{ .r = 123, .g = 0, .b = 0, .a = 255 },
    .{ .r = 156, .g = 0, .b = 0, .a = 255 },
    .{ .r = 189, .g = 0, .b = 0, .a = 255 },
    .{ .r = 230, .g = 24, .b = 0, .a = 255 },
    .{ .r = 246, .g = 74, .b = 0, .a = 255 },
    .{ .r = 255, .g = 98, .b = 0, .a = 255 },
    .{ .r = 255, .g = 123, .b = 0, .a = 255 },
    .{ .r = 255, .g = 139, .b = 0, .a = 255 },
    .{ .r = 255, .g = 156, .b = 0, .a = 255 },
    .{ .r = 255, .g = 180, .b = 16, .a = 255 },
    .{ .r = 255, .g = 230, .b = 57, .a = 255 },
    .{ .r = 255, .g = 238, .b = 98, .a = 255 },
    .{ .r = 0, .g = 0, .b = 0, .a = 255 },
};

pub const water: Palette = .{
    .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    .{ .r = 0, .g = 0, .b = 82, .a = 255 },
    .{ .r = 0, .g = 24, .b = 131, .a = 255 },
    .{ .r = 0, .g = 49, .b = 172, .a = 255 },
    .{ .r = 0, .g = 74, .b = 213, .a = 255 },
    .{ .r = 0, .g = 98, .b = 255, .a = 255 },
    .{ .r = 0, .g = 131, .b = 255, .a = 255 },
    .{ .r = 0, .g = 156, .b = 255, .a = 255 },
    .{ .r = 0, .g = 180, .b = 255, .a = 255 },
    .{ .r = 0, .g = 205, .b = 255, .a = 255 },
    .{ .r = 65, .g = 222, .b = 255, .a = 255 },
    .{ .r = 131, .g = 238, .b = 255, .a = 255 },
    .{ .r = 156, .g = 246, .b = 255, .a = 255 },
    .{ .r = 189, .g = 246, .b = 255, .a = 255 },
    .{ .r = 213, .g = 255, .b = 255, .a = 255 },
    .{ .r = 246, .g = 255, .b = 255, .a = 255 },
};

pub const wind: Palette = .{
    .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    .{ .r = 0, .g = 74, .b = 74, .a = 255 },
    .{ .r = 0, .g = 90, .b = 74, .a = 255 },
    .{ .r = 0, .g = 115, .b = 82, .a = 255 },
    .{ .r = 0, .g = 123, .b = 90, .a = 255 },
    .{ .r = 0, .g = 139, .b = 106, .a = 255 },
    .{ .r = 0, .g = 156, .b = 115, .a = 255 },
    .{ .r = 0, .g = 180, .b = 139, .a = 255 },
    .{ .r = 0, .g = 197, .b = 156, .a = 255 },
    .{ .r = 0, .g = 213, .b = 164, .a = 255 },
    .{ .r = 49, .g = 230, .b = 180, .a = 255 },
    .{ .r = 106, .g = 246, .b = 197, .a = 255 },
    .{ .r = 156, .g = 255, .b = 205, .a = 255 },
    .{ .r = 189, .g = 255, .b = 222, .a = 255 },
    .{ .r = 213, .g = 255, .b = 238, .a = 255 },
    .{ .r = 246, .g = 255, .b = 255, .a = 255 },
};

pub const lightning: Palette = .{
    .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    .{ .r = 255, .g = 255, .b = 57, .a = 255 },
    .{ .r = 255, .g = 255, .b = 49, .a = 255 },
    .{ .r = 255, .g = 255, .b = 57, .a = 255 },
    .{ .r = 255, .g = 255, .b = 57, .a = 255 },
    .{ .r = 255, .g = 255, .b = 57, .a = 255 },
    .{ .r = 255, .g = 255, .b = 57, .a = 255 },
    .{ .r = 255, .g = 255, .b = 57, .a = 255 },
    .{ .r = 255, .g = 255, .b = 57, .a = 255 },
    .{ .r = 255, .g = 255, .b = 57, .a = 255 },
    .{ .r = 255, .g = 255, .b = 49, .a = 255 },
    .{ .r = 255, .g = 255, .b = 57, .a = 255 },
    .{ .r = 255, .g = 255, .b = 57, .a = 255 },
    .{ .r = 255, .g = 255, .b = 57, .a = 255 },
    .{ .r = 255, .g = 255, .b = 57, .a = 255 },
    .{ .r = 255, .g = 255, .b = 57, .a = 255 },
};

pub const dark: Palette = .{
    .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    .{ .r = 255, .g = 222, .b = 255, .a = 255 },
    .{ .r = 230, .g = 164, .b = 255, .a = 255 },
    .{ .r = 205, .g = 106, .b = 255, .a = 255 },
    .{ .r = 180, .g = 82, .b = 246, .a = 255 },
    .{ .r = 156, .g = 57, .b = 230, .a = 255 },
    .{ .r = 131, .g = 41, .b = 222, .a = 255 },
    .{ .r = 106, .g = 16, .b = 205, .a = 255 },
    .{ .r = 82, .g = 16, .b = 180, .a = 255 },
    .{ .r = 65, .g = 16, .b = 156, .a = 255 },
    .{ .r = 41, .g = 16, .b = 131, .a = 255 },
    .{ .r = 16, .g = 24, .b = 106, .a = 255 },
    .{ .r = 0, .g = 24, .b = 82, .a = 255 },
    .{ .r = 0, .g = 8, .b = 41, .a = 255 },
    .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    .{ .r = 255, .g = 255, .b = 255, .a = 255 },
};

pub const neutral: Palette = .{
    .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    .{ .r = 123, .g = 123, .b = 123, .a = 255 },
    .{ .r = 115, .g = 115, .b = 115, .a = 255 },
    .{ .r = 106, .g = 106, .b = 106, .a = 255 },
    .{ .r = 98, .g = 98, .b = 98, .a = 255 },
    .{ .r = 90, .g = 90, .b = 90, .a = 255 },
    .{ .r = 82, .g = 82, .b = 82, .a = 255 },
    .{ .r = 74, .g = 74, .b = 74, .a = 255 },
    .{ .r = 57, .g = 57, .b = 57, .a = 255 },
    .{ .r = 49, .g = 49, .b = 49, .a = 255 },
    .{ .r = 41, .g = 41, .b = 41, .a = 255 },
    .{ .r = 32, .g = 32, .b = 32, .a = 255 },
    .{ .r = 24, .g = 24, .b = 24, .a = 255 },
    .{ .r = 16, .g = 16, .b = 16, .a = 255 },
    .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    .{ .r = 255, .g = 255, .b = 255, .a = 255 },
};

pub fn forSpell(name: []const u8) Palette {
    if (std.mem.indexOf(u8, name, "Black") != null or std.mem.indexOf(u8, name, "Hell") != null or std.mem.indexOf(u8, name, "Judgment") != null or std.mem.indexOf(u8, name, "Deadly") != null or std.mem.indexOf(u8, name, "Soul") != null) return dark;
    if (std.mem.indexOf(u8, name, "Storm") != null or std.mem.indexOf(u8, name, "Thunder") != null or std.mem.indexOf(u8, name, "Lightning") != null) return lightning;
    if (std.mem.indexOf(u8, name, "Earth") != null or std.mem.indexOf(u8, name, "Clay") != null or std.mem.indexOf(u8, name, "Copper") != null or std.mem.indexOf(u8, name, "Guardian") != null or std.mem.indexOf(u8, name, "Voice") != null) return neutral;
    if (std.mem.indexOf(u8, name, "Water") != null or std.mem.indexOf(u8, name, "Rain") != null or std.mem.indexOf(u8, name, "Ocean") != null or std.mem.indexOf(u8, name, "Kindness") != null or std.mem.indexOf(u8, name, "Fog") != null) return water;
    if (std.mem.indexOf(u8, name, "Wind") != null or std.mem.indexOf(u8, name, "Healing") != null or std.mem.indexOf(u8, name, "Shredding") != null) return wind;
    return fire;
}
