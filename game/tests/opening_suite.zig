//! Consolidated opening-sequence and canonical-package tests.

comptime {
    _ = @import("canonical_package.zig");
    _ = @import("opening/area_host.zig");
    _ = @import("opening/audio.zig");
    _ = @import("opening/battles.zig");
    _ = @import("opening/descriptors.zig");
    _ = @import("opening/dungeon.zig");
    _ = @import("opening/first_town.zig");
    _ = @import("opening/hero_descriptor.zig");
    _ = @import("opening/movement_batch.zig");
    _ = @import("opening/native_slots.zig");
    _ = @import("opening/palace.zig");
    _ = @import("opening/palace_collision.zig");
    _ = @import("opening/palace_destination.zig");
    _ = @import("opening/party.zig");
    _ = @import("opening/party_creation.zig");
    _ = @import("opening/party_event_join.zig");
    _ = @import("opening/records.zig");
    _ = @import("opening/room2_text.zig");
    _ = @import("opening/room2_text_binding.zig");
    _ = @import("opening/room2_text_host.zig");
    _ = @import("opening/routes.zig");
}
