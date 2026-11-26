//! Coordinates and grid conversions for field rooms.

pub const half_cell_pixels = 8;

pub const FieldPixel = struct { x: i32, y: i32 };

pub const HalfCell = struct {
    x: i32,
    y: i32,

    pub fn toPixels(self: HalfCell) FieldPixel {
        return .{ .x = halfCellsToPixels(self.x), .y = halfCellsToPixels(self.y) };
    }
};

pub fn halfCellsToPixels(cells: i32) i32 {
    return cells * half_cell_pixels;
}

/// For aligned field positions and dimensions.
pub fn pixelsToHalfCells(pixels: i32) i32 {
    return @divTrunc(pixels, half_cell_pixels);
}
