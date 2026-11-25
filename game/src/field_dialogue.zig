//! Field dialogue page state and reveal timing. The page bytes belong to the
//! room package; this module owns only the runtime reading state.
const std = @import("std");

pub const Speed = enum { fast, normal, slow };

pub const Dialogue = struct {
    source: union(enum) { npc: usize, event: usize, boat_rapids },
    page: usize = 0,
    reveal_started: u32 = 0,
    reveal_complete: bool = false,
    speed: Speed = .normal,
    page_wait: bool = false,
    countdown: u16 = 0,
    phase: enum { pages, choices, insufficient_funds, unavailable, shop, service, recruitment_choices, recruitment_accepted, recruitment_declined, recruitment_joined } = .pages,
    choice: u1 = 0,

    pub fn name(self: Dialogue, room: anytype) []const u8 {
        return switch (self.source) {
            .npc => |i| room.npcs[i].name,
            .event => |i| room.events[i].name,
            .boat_rapids => "Rapids",
        };
    }

    pub fn pages(self: Dialogue, room: anytype) []const []const u8 {
        return switch (self.source) {
            .npc => |i| room.npcs[i].pages,
            .event => |i| room.events[i].pages,
            .boat_rapids => room.boat_rapids.?.pages,
        };
    }

    pub fn pace(self: Dialogue) u8 {
        return switch (self.speed) {
            .fast => 1,
            .normal => 3,
            .slow => 5,
        };
    }

    pub fn revealedLength(self: Dialogue, page_len: usize, ticks: u32) usize {
        if (self.reveal_complete) return page_len;
        return revealedCount(page_len, ticks -| self.reveal_started, self.pace());
    }

    pub fn waitPage(self: *Dialogue, ticks: u16) void {
        self.page_wait = true;
        self.countdown = ticks;
    }
};

/// Source pacing is a per-character tick count. The first character appears on
/// the opening frame, then one more per `pace` scene ticks.
pub fn revealedCount(page_len: usize, elapsed: u32, pace: u8) usize {
    if (pace == 0) return page_len;
    return @min(page_len, elapsed / pace + 1);
}
