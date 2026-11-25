//! Consolidated world-graph and package/recovery/migration/frontier host tests.

comptime {
    _ = @import("world_graph.zig");
    _ = @import("package_host/entry.zig");
    _ = @import("package_host/platform_recovery.zig");
    _ = @import("package_host/migration.zig");
    _ = @import("package_host/discovery.zig");
    _ = @import("package_host/bundle.zig");
    _ = @import("package_host/frontiers.zig");
    _ = @import("package_host/scenarios.zig");
}
