//! Battle status, application, enemy behavior, spells, physical/passive techniques, Unite attacks, and outcomes.

pub const status = @import("status/root.zig");
pub const apply = @import("apply/root.zig");
pub const enemy = @import("enemy/root.zig");
pub const spells = @import("spells/root.zig");
pub const techniques = @import("techniques/root.zig");
pub const unite = @import("unite/root.zig");
pub const outcomes = @import("outcomes.zig");
pub const host = @import("host.zig");
pub const Host = host.Host;
