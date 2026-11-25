//! Opening chapter route controller.
//!
//! Source order, not the order in the old prompt:
//!   opening -> opening dungeon (VAA room0) -> palace -> first town -> world.
//!
//! Opening battles and the initial-party joins are milestones inside those
//! stages, not standalone rooms: the battle caller belongs to the opening
//! dungeon, and the opening event-joins happen in the first town.  The world handoff
//! requires both milestones as well as all four stages.
const std = @import("std");
const field = @import("field");

pub const schema = "suikoden-opening-route-controller/1";

pub const Stage = enum {
    opening,
    dungeon,
    palace,
    first_town,
    world,

    pub fn label(self: Stage) []const u8 {
        return @tagName(self);
    }
};

pub const RouteError = error{
    OutOfOrderStage,
    StageAlreadyComplete,
    RouteAlreadyAtWorld,
    MissingWorldCheckpoint,
    MissingOpeningBattle,
    MissingInitialParty,
};

/// Source opening-battle outcomes. Only a returned victory satisfies the milestone;
/// defeat and an unsettled/aborted session do not.
pub const BattleOutcome = enum { unsettled, victory_returned, defeat_game_over };

pub const Milestones = struct {
    opening_battles: bool = false,
    initial_party: bool = false,
};

pub const Checkpoint = struct {
    schema: []const u8 = schema,
    stage: Stage = .opening,
    completed: u8 = 0,
    journal: u64 = 0,
    milestones: Milestones = .{},

    pub fn validate(self: Checkpoint) !void {
        if (!std.mem.eql(u8, self.schema, schema)) return error.InvalidOpeningRouteCheckpoint;
        if (self.completed > order.len) return error.InvalidOpeningRouteCheckpoint;
        if (@backingInt(self.stage) != self.completed) return error.InvalidOpeningRouteCheckpoint;
    }
};

const order = [_]Stage{
    .opening,
    .dungeon,
    .palace,
    .first_town,
    .world,
};

pub fn initial(package: field.Package) Controller {
    if (std.mem.eql(u8, package.start_room, "vaa_room_1")) return .{ .stage = .palace, .completed = 2 };
    return .{};
}

pub const Controller = struct {
    stage: Stage = .opening,
    completed: u8 = 0,
    journal: u64 = 0,
    milestones: Milestones = .{},

    pub fn complete(self: *Controller, stage: Stage) RouteError!Stage {
        if (self.stage == .world) return error.RouteAlreadyAtWorld;
        if (stage != self.stage) return error.OutOfOrderStage;
        const index: u8 = @backingInt(self.stage);
        if (index >= order.len - 1) return error.RouteAlreadyAtWorld;
        self.completed = index + 1;
        self.stage = order[self.completed];
        self.journal += 1;
        return self.stage;
    }

    /// The accepted opening dungeon is VAA room0.
    pub fn completeDungeon(self: *Controller, room: []const u8) RouteError!Stage {
        if (!std.mem.eql(u8, room, "vaa_room_0")) return error.OutOfOrderStage;
        return self.complete(.dungeon);
    }

    pub fn completeFirstTown(self: *Controller, room: []const u8) RouteError!Stage {
        if (!std.mem.startsWith(u8, room, "va1_")) return error.OutOfOrderStage;
        return self.complete(.first_town);
    }

    /// The opening-battle caller reports its settled battle outcome.
    pub fn noteOpeningBattle(self: *Controller, outcome: BattleOutcome) void {
        self.milestones.opening_battles = outcome == .victory_returned;
    }

    /// The opening event-join caller reports applied joins.
    pub fn noteInitialParty(self: *Controller, applied: bool) void {
        self.milestones.initial_party = applied;
    }

    pub fn worldReady(self: *const Controller) bool {
        return self.stage == .world and self.completed == order.len - 1 and
            self.milestones.opening_battles and self.milestones.initial_party;
    }

    pub fn checkpoint(self: *const Controller) Checkpoint {
        return .{ .stage = self.stage, .completed = self.completed, .journal = self.journal, .milestones = self.milestones };
    }

    pub fn restore(saved: Checkpoint) !Controller {
        try saved.validate();
        return .{ .stage = saved.stage, .completed = saved.completed, .journal = saved.journal, .milestones = saved.milestones };
    }
};

test "source order is opening, dungeon, palace, first town, world" {
    var route: Controller = .{};
    try std.testing.expectEqual(Stage.dungeon, try route.complete(.opening));
    try std.testing.expectError(error.OutOfOrderStage, route.completeDungeon("vaa_room_1"));
    try std.testing.expectEqual(Stage.palace, try route.completeDungeon("vaa_room_0"));
    try std.testing.expectEqual(Stage.first_town, try route.complete(.palace));
    try std.testing.expectEqual(Stage.world, try route.completeFirstTown("va1_room_0"));
    try std.testing.expect(!route.worldReady());
    route.noteOpeningBattle(.victory_returned);
    route.noteInitialParty(true);
    try std.testing.expect(route.worldReady());
}

test "milestones survive the checkpoint but are required for world" {
    var route: Controller = .{};
    _ = try route.complete(.opening);
    _ = try route.completeDungeon("vaa_room_0");
    _ = try route.complete(.palace);
    _ = try route.completeFirstTown("va1_room_0");
    route.noteOpeningBattle(.victory_returned);
    var saved = route.checkpoint();
    const restored = try Controller.restore(saved);
    try std.testing.expect(restored.worldReady() == false);
    saved.milestones.initial_party = true;
    const complete = try Controller.restore(saved);
    try std.testing.expect(complete.worldReady());
}
