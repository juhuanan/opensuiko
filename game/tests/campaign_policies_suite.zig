//! Consolidated campaign policy, ledger, encounter, and session tests.

comptime {
    _ = @import("campaign_policies/content_graph.zig");
    _ = @import("campaign_policies/party_actions.zig");
    _ = @import("campaign_policies/enemy_policy.zig");
    _ = @import("campaign_policies/item_ledger.zig");
    _ = @import("campaign_policies/encounters.zig");
    _ = @import("campaign_policies/mode_result.zig");
    _ = @import("campaign_policies/control_draws.zig");
    _ = @import("campaign_policies/session.zig");
}
