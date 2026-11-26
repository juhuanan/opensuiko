//! Coordinate domains shared by both route packet schemas.

pub const Domain = enum { half_cell, field_pixel, world_cell };
pub const Coordinate = struct { domain: Domain, x: i32, y: i32 };
pub const Rectangle = struct { domain: Domain, x: i32, y: i32, w: i32, h: i32 };

pub const Contracts = struct {
    half_cell: []const u8,
    field_pixel: []const u8,
    world_cell: []const u8,
};
