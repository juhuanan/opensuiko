//! VA1 room2 scenery record 37, file 0x6EE1. Source child word+4 is
//! partially initialized: allocation does not prove the other heap bits.
//! 0x8013809C scans all child-present area/font descriptors, then Hero.
//! Caller must supply a complete current descriptor set, actual scenario[38]
//! and command cache; this owner does not construct or render source objects.
const std = @import("std");
const pass_mask: u32 = 0x00030001;
const entry_bits: u32 = 0x1fe00ff0;
pub const Cell = struct { x: u8, y: u8 };
/// Keep unused cells null. Caller must reject scenes with more than 64
/// child-present descriptors in either source table, never truncate them.
pub const Observation = struct { area: [64]?Cell = @splat(null), font: [64]?Cell = @splat(null), hero: Cell };
pub const WordFacts = struct {
    known_mask: u32,
    value: u32,
    fn valid(self: WordFacts) bool {
        return self.value & ~self.known_mask == 0;
    }
    pub fn afterEntry(self: WordFacts) WordFacts {
        return .{ .known_mask = (self.known_mask & pass_mask) | ~pass_mask, .value = (self.value & pass_mask) | entry_bits };
    }
};
pub const State = struct {
    inside: bool = false,
    child: WordFacts = .{ .known_mask = pass_mask, .value = 0 },
    scenario38: u8,
    command_cache: i16,
    revision: u64 = 0,
    receipt: u64 = 0,
    checkpoint: u64 = 0,
};
pub const Transition = enum { none, enter, exit };
pub const Proposal = struct { before: State, observation: Observation, after: State, transition: Transition, command: ?u16 };
fn inside(c: Cell, was_inside: bool) bool {
    // MAIN 0x80137EB8: narrow mode1 and wider hysteresis mode0.
    return if (was_inside) c.x >= 31 and c.x < 41 and c.y >= 23 and c.y < 27 else c.x >= 32 and c.x < 40 and c.y >= 24 and c.y < 26;
}
fn occupied(o: Observation, was_inside: bool) bool {
    for (o.area) |maybe| if (maybe) |c| {
        if (inside(c, was_inside)) return true;
    };
    for (o.font) |maybe| if (maybe) |c| {
        if (inside(c, was_inside)) return true;
    };
    return inside(o.hero, was_inside);
}
pub const Owner = struct {
    state: State,
    /// The caller owns provenance of the actual story byte and command cache.
    pub fn init(scenario38: u8, command_cache: i16) Owner {
        return .{ .state = .{ .scenario38 = scenario38, .command_cache = command_cache } };
    }
    pub fn restore(state: State) !Owner {
        if (!state.child.valid() or state.receipt != state.revision or (state.revision == 0) != (state.checkpoint == 0) or state.checkpoint < state.revision) return error.InvalidSceneryState;
        const initial = state.child.known_mask == pass_mask and state.child.value == 0;
        const entered = state.child.known_mask == 0xffffffff and state.child.value == entry_bits;
        if ((!initial and !entered) or (state.inside and !entered) or (state.revision == 0 and (state.inside or !initial))) return error.InvalidSceneryState;
        return .{ .state = state };
    }
    pub fn propose(self: Owner, observation: Observation, checkpoint: u64) !Proposal {
        _ = try restore(self.state);
        if (checkpoint <= self.state.checkpoint) return error.InvalidCheckpoint;
        var next = self.state;
        var transition: Transition = .none;
        var command: ?u16 = null;
        const hit = occupied(observation, next.inside);
        if (!next.inside and hit) {
            next.inside = true;
            next.child = next.child.afterEntry();
            transition = .enter;
            const selected: u16 = if ((next.scenario38 & 0x20) != 0) 0x547 else 0x506;
            if ((next.scenario38 & 0x20) != 0) next.scenario38 ^= 0x20;
            // 0x80142440 compares cache before calling 0x800C3104. Neither
            // 0x506 nor 0x547 belongs to the cache-writing range 0x201..0x445.
            if (next.command_cache != @as(i16, @intCast(selected))) command = selected;
        } else if (next.inside and !hit) {
            next.inside = false;
            transition = .exit;
        }
        next.revision = try std.math.add(u64, next.revision, 1);
        next.receipt = try std.math.add(u64, next.receipt, 1);
        next.checkpoint = checkpoint;
        return .{ .before = self.state, .observation = observation, .after = next, .transition = transition, .command = command };
    }
    /// Recheck the current descriptor observation as well as all owner state;
    /// caller stages motion, scenery, story and command delivery atomically.
    pub fn commit(self: *Owner, current: Observation, proposal: Proposal) !void {
        if (!std.meta.eql(self.state, proposal.before) or !std.meta.eql(current, proposal.observation)) return error.StaleSceneryState;
        const expected = try self.propose(current, proposal.after.checkpoint);
        if (!std.meta.eql(expected, proposal)) return error.InvalidSceneryProposal;
        self.state = expected.after;
    }
};
