//! Consolidated travel, teleport, ground, population, and admission tests.

comptime {
    _ = @import("travel/routes.zig");
    _ = @import("travel/boat.zig");
    _ = @import("travel/teleport.zig");
    _ = @import("travel/ground_geometry.zig");
    _ = @import("travel/populations.zig");
    _ = @import("travel/admission.zig");
    _ = @import("travel/field_layers.zig");
}
