//! Build-time canonical package writer. Reached only through
//! `suikoden-journey --export-opening`; the play path never calls it.
const std = @import("std");
const field = @import("field");
const opening_package = @import("opening_package");

fn writeFile(allocator: std.mem.Allocator, io: std.Io, out_path: []const u8, name: []const u8, data: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ out_path, name });
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

pub fn run(init: std.process.Init, scene_path: []const u8, out_path: []const u8) !void {
    const allocator = init.gpa;
    const scene = try std.Io.Dir.cwd().readFileAlloc(init.io, scene_path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(scene);
    const base: field.Package = .{
        .schema = "suikoden-room/6",
        .atlas = "atlas.png",
        .cell_size = 8,
        .start_room = opening_package.start_room,
        .start_x = opening_package.start_x,
        .start_y = opening_package.start_y,
        .step_ticks = 4,
        .interaction_offsets = .{ .{ .x = 0, .y = 16 }, .{ .x = 0, .y = -8 }, .{ .x = -16, .y = 0 }, .{ .x = 16, .y = 0 } },
        .player_clips = &.{},
        .rooms = &.{},
    };
    var bound = try opening_package.bind(allocator, scene, base);
    defer bound.deinit(allocator);
    const rooms = try std.json.Stringify.valueAlloc(allocator, bound.package, .{});
    defer allocator.free(rooms);
    try writeFile(allocator, init.io, out_path, "room.json", rooms);
    const journey_json =
        \\{
        \\  "schema": "suikoden-journey/3",
        \\  "title": "Suikoden",
        \\  "battle": "battle/trial.json",
        \\  "encounters": [
        \\    {"id": "world_patrol", "room": "world_a", "x": 480, "y": 320, "w": 320, "h": 320, "encounter": "area_a_1", "flag": "world_patrol_won"}
        \\  ],
        \\  "treasures": [],
        \\  "recruitment": null
        \\}
    ;
    try writeFile(allocator, init.io, out_path, "journey.json", journey_json);
    try writeFile(allocator, init.io, out_path, "ui.json", bound.ui);
    const scene_dir = std.fs.path.dirname(scene_path) orelse return error.InvalidArguments;
    const atlas_path = try std.fs.path.join(allocator, &.{ scene_dir, "atlas.png" });
    defer allocator.free(atlas_path);
    const atlas = try std.Io.Dir.cwd().readFileAlloc(init.io, atlas_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(atlas);
    try writeFile(allocator, init.io, out_path, "atlas.png", atlas);
}
