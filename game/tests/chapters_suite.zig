//! Consolidated middle-game and endgame chapter tests.

comptime {
    _ = @import("chapters/middle_travel.zig");
    _ = @import("chapters/middle_story.zig");
    _ = @import("chapters/middle_battle_graph.zig");
    _ = @import("chapters/middle_progression.zig");
    _ = @import("chapters/middle_recruitment.zig");
    _ = @import("chapters/middle_duel_adapter.zig");
    _ = @import("chapters/middle_war_adapter.zig");
    _ = @import("chapters/final_travel.zig");
    _ = @import("chapters/final_story.zig");
    _ = @import("chapters/final_map.zig");
    _ = @import("chapters/endings.zig");
    _ = @import("chapters/roster_progression.zig");
}
