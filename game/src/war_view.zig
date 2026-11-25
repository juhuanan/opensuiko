const std = @import("std");
const war = @import("war");
const content = @import("war_content");

pub const width = 320;
pub const height = 240;
pub const pixel_count = width * height;
pub const Color = packed struct { r: u8, g: u8, b: u8, a: u8 };
pub const Frame = struct { pixels: [pixel_count]Color };

fn channel(word: u32, shift: u5) u8 {
    return @intCast(@as(u32, (word >> shift) & 31) * 255 / 31);
}

fn paletteColor(entry: @TypeOf(@import("war_data").entries[0]), index: u8) Color {
    const palette = entry.palette orelse return .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const offset: usize = @as(usize, index) * 2;
    const word = @as(u32, palette[offset]) + @as(u32, palette[offset + 1]) * 256;
    return .{ .r = channel(word, 0), .g = channel(word, 5), .b = channel(word, 10), .a = if (index == 0) 0 else 255 };
}

fn put(frame: *Frame, x: i32, y: i32, color: Color) void {
    if (color.a == 0 or x < 0 or y < 0 or x >= width or y >= height) return;
    const destination = &frame.pixels[@intCast(y * width + x)];
    if (color.a == 255) {
        destination.* = color;
    } else {
        const alpha = @as(u32, color.a);
        destination.* = .{
            .r = @intCast((@as(u32, destination.r) * (255 - alpha) + @as(u32, color.r) * alpha) / 255),
            .g = @intCast((@as(u32, destination.g) * (255 - alpha) + @as(u32, color.g) * alpha) / 255),
            .b = @intCast((@as(u32, destination.b) * (255 - alpha) + @as(u32, color.b) * alpha) / 255),
            .a = 255,
        };
    }
}

pub fn composeMap(frame: *Frame, map: content.Map, camera_x: i32, camera_y: i32) !void {
    if (map.composition.row_stride_cells != map.width) return error.InvalidWarMap;
    for (0..height) |destination_y| for (0..width) |destination_x| {
        const x = @as(i32, @intCast(destination_x)) + camera_x;
        const y = @as(i32, @intCast(destination_y)) + camera_y;
        if (x < 0 or y < 0 or x >= map.composition.pixel_width or y >= map.composition.pixel_height) continue;
        const cell_x: usize = @intCast(@divTrunc(x, 32));
        const cell_y: usize = @intCast(@divTrunc(y, 32));
        const code = map.cells[cell_y * map.width + cell_x];
        const page = try content.resource(map.pages[code >> 6]);
        const tile = code & 63;
        const source_x: usize = @intCast(@divTrunc(@rem(x, 32), 2) + @as(i32, tile % 8) * 16);
        const source_y: usize = @intCast(@divTrunc(@rem(y, 32), 2) + @as(i32, tile / 8) * 16);
        const index = page.data[source_y * 128 + source_x];
        put(frame, @intCast(destination_x), @intCast(destination_y), paletteColor(page, index));
    };
}

pub fn drawResource(frame: *Frame, entry: @TypeOf(@import("war_data").entries[0]), x: i32, y: i32, w: i32, h: i32) void {
    for (0..@intCast(h)) |dy| for (0..@intCast(w)) |dx| {
        const sx: usize = @intCast(dx * 128 / @as(usize, @intCast(w)));
        const sy: usize = @intCast(dy * 128 / @as(usize, @intCast(h)));
        const index = entry.data[sy * 128 + sx];
        put(frame, x + @as(i32, @intCast(dx)), y + @as(i32, @intCast(dy)), paletteColor(entry, index));
    };
}

pub fn drawPose(frame: *Frame, entry: @TypeOf(@import("war_data").entries[0]), pose: content.Pose, x: i32, y: i32) void {
    const source_x = @as(usize, pose.frame % 16) * 8;
    const source_y = @as(usize, pose.frame / 16) * 8;
    for (0..pose.height * 2) |dy| for (0..pose.width * 2) |dx| {
        const index = entry.data[(source_y + dy / 2) * 128 + source_x + dx / 2];
        put(frame, x + @as(i32, @intCast(dx)), y + @as(i32, @intCast(dy)), paletteColor(entry, index));
    };
}

pub fn drawPortrait(frame: *Frame, entry: @TypeOf(@import("war_data").entries[0]), x: i32, y: i32) void {
    for (0..64) |dy| for (0..64) |dx| {
        const index = entry.data[dy * 64 + dx];
        put(frame, x + @as(i32, @intCast(dx)), y + @as(i32, @intCast(dy)), paletteColor(entry, index));
    };
}

fn rect(frame: *Frame, x: i32, y: i32, w: i32, h: i32, color: Color) void {
    for (0..@intCast(h)) |dy| for (0..@intCast(w)) |dx| put(frame, x + @as(i32, @intCast(dx)), y + @as(i32, @intCast(dy)), color);
}

pub const View = struct {
    scenario: content.Scenario,
    camera_x: i32 = 0,
    camera_y: i32 = 0,
    show_portrait: bool = true,

    pub fn init(manifest: content.Manifest, scenario_id: []const u8) !View {
        return .{ .scenario = try content.scenario(manifest, scenario_id) };
    }

    pub fn render(self: *const View, engine: *const war.Engine, frame: *Frame) !void {
        @memset(&frame.pixels, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
        try composeMap(frame, try content.map(self.scenario, .sky), @divTrunc(self.camera_x, 2), @divTrunc(self.camera_y, 2));
        try composeMap(frame, try content.map(self.scenario, .battlefield), self.camera_x, self.camera_y);
        for (engine.sides, 0..) |side, side_index| {
            const descriptor = self.scenario.atlases[side_index];
            const atlas = try content.resource(descriptor.resource);
            for (side.units, 0..) |unit, index| {
                if (unit.state == .finished or unit.state == .inert) continue;
                const x = unit.x - 8;
                const y = unit.y - 16;
                const pose = descriptor.poses[@min(@as(usize, @backingInt(unit.state)), descriptor.poses.len - 1)];
                drawPose(frame, atlas, pose, x, y);
                if (side_index == engine.selected_side and index == engine.selected_index) {
                    for (0..20) |offset| {
                        put(frame, x - 2 + @as(i32, @intCast(offset)), y - 2, .{ .r = 255, .g = 210, .b = 40, .a = 255 });
                        put(frame, x - 2 + @as(i32, @intCast(offset)), y + 18, .{ .r = 255, .g = 210, .b = 40, .a = 255 });
                    }
                }
            }
        }
        const blue: Color = .{ .r = 24, .g = 70, .b = 150, .a = 220 };
        const red: Color = .{ .r = 150, .g = 35, .b = 45, .a = 220 };
        rect(frame, 0, 0, 150, 24, blue);
        rect(frame, 170, 0, 150, 24, red);
        if (self.show_portrait) {
            const portrait_index: u8 = @intCast(@min(engine.selected_index, 107));
            drawPortrait(frame, try content.portrait(self.scenario, portrait_index), 4, 174);
        }
        rect(frame, 72, 174, 244, 62, .{ .r = 18, .g = 18, .b = 24, .a = 230 });
        rect(frame, 72, 174, 244, 1, .{ .r = 180, .g = 160, .b = 100, .a = 255 });
        rect(frame, 72, 235, 244, 1, .{ .r = 180, .g = 160, .b = 100, .a = 255 });
    }
};

pub fn commandAvailable(engine: *const war.Engine, command: war.Command) bool {
    if (engine.script != null or engine.phase == .result) return false;
    const category: u8 = switch (command) {
        .charge => 0,
        .bow => 1,
        .magic => 2,
        .special => 3,
        .move, .retreat => return false,
    };
    if (!engine.team_alive[engine.selected_index]) return false;
    return war.teamAvailable(engine.scenario, engine.selected_index, category, &engine.recruited) catch false;
}
