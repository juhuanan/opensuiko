//! A source-identified scene order, not a persistent recruitment or party change.
const session = @import("session.zig");

/// VB6 room 6 first arrival, event IR request_area_party_prefix [8, 2, 4].
/// The 04_PLAY identity bridge is Hero=8, Gremio=2, Kirkis=4.
pub const vb6_arrival = session.SceneOperation{
    .id = "vb6_r06_first_arrival_prefix",
    .source = "events/vb6_room6_arrival.json:request_area_party_prefix",
    .scope = .area_transient,
    .active = .{ "hero", "gremio", "kirkis", null, null, null },
};
