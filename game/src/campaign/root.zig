//! Public campaign surface.  The campaign content is private implementation; production code should import
//! this module only.
pub const Campaign = @import("campaign.zig").Campaign;
pub const Status = @import("campaign.zig").Status;
pub const open = @import("campaign.zig").Campaign.open;

/// The existing /13 world-session snapshot, exposed under the campaign name.
pub const CampaignSnapshot = @import("journey").Snapshot;
