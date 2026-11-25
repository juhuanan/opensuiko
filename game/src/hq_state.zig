//! Host-free headquarters save state.
pub const sidecar_schema = "suikoden-hq-sidecar/1";
pub const sidecar_version: u8 = 1;
pub const flag_slots = 108;

pub const Screen = enum { field, party, service, tablet, mode, recruit };
pub const ModeFacts = struct {
    net: i32 = 0,
    status: [16]u8 = @splat(0),
    retained: u32 = 0,
    best: [4]u32 = @splat(0),
    draws_cursor: u64 = 0,
    draws_bios: ?u32 = null,
    receipts: [4]u64 = @splat(0),
    revision: u64 = 0,
};
pub const Tablet = struct {
    magic: u32,
    layout: u16,
    reserved: u16,
    tablet_sha256: [32]u8,
    flags_sha256: [32]u8,
    cursor: u8,
    revealed_entry: u8,
    up_counter: u8,
    down_counter: u8,
    up_armed: u8,
    down_armed: u8,
    revision: u32,
    scroll: i16,
    scroll_target: i16,
    checksum: u32,
};
pub const HqState = struct {
    schema: []const u8 = sidecar_schema,
    version: u8 = sidecar_version,
    content_sha256: []const u8 = "",
    recruit: [flag_slots]u8 = @splat(0),
    roster_json: []const u8 = "",
    tablet: ?Tablet = null,
    mode: ModeFacts = .{},
    screen: Screen = .field,
    room: u8 = 0,
    cursor: u8 = 0,
    revision: u64 = 0,
};
