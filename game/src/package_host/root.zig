//! Boot, package validation, save migration, and frontier consumers.

pub const entry = @import("entry/root.zig");
pub const migration = @import("migration/root.zig");
pub const discovery = @import("discovery/root.zig");
pub const bundle = @import("bundle/root.zig");
pub const frontiers = @import("frontiers/root.zig");
pub const host = @import("host.zig");

pub const Diagnostic = host.Diagnostic;
pub const Content = host.Content;
pub const resolveContent = host.resolveContent;
pub const PackageKind = host.PackageKind;
pub const verifyPackage = host.verifyPackage;
pub const stateDirectory = host.stateDirectory;
pub const slotInfos = host.slotInfos;
pub const tabletPortrait = host.tabletPortrait;
pub const StartSeedCheck = host.StartSeedCheck;
pub const verifyStartSeed = host.verifyStartSeed;
pub const WarehouseAdmission = host.WarehouseAdmission;
pub const warehouseAdmission = host.warehouseAdmission;

test {
    _ = entry;
    _ = discovery;
    _ = bundle;
    _ = frontiers;
    _ = host;
}
