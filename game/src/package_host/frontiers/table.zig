//! Portrait and tablet layout constants.
//! Disc/RAM provenance tables live in `tests/package_host/frontiers_provenance.zig`.

pub const schema = "suikoden-frontiers/1";
pub const version = "frontiers.1";

pub const face_page_bytes: u32 = 16384;
pub const face_quadrant: u16 = 64;
pub const face_page_count: u8 = 27;
pub const tablet_entry_count: u8 = 108;
pub const tablet_cells_per_page: u8 = 4;
