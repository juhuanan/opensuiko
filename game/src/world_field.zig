const std = @import("std");
const world = @import("world");
const field = @import("field");
const pause = @import("pause_menu");

// A private source-travel view replaces the old warning; the original episode package is untouched.
pub const Session = struct {
    allocator: std.mem.Allocator,
    content: world.Content,
    package: field.Package,
    owned_rooms: []field.Room,
    village: usize,
    events: []field.Event,
    travel: world.State,
    field_state: field.State,
    field_moving_updates: u32 = 0,
    menu_effect: pause.Effect = .none,
    /// Static ground query bound by the session owner.  Not save state:
    /// it is re-derived from the same reviewed geometry on Load.
    ground: ?field.Ground = null,
    kobold_events: ?[]field.Event = null,

    pub fn enableKoboldExit(self: *Session) !void {
        if (self.kobold_events != null) return error.WorldRegionAlreadyBound;
        const room = self.package.roomIndex("vb6_kobold_village") orelse return error.UnknownRoom;
        const original = self.package.rooms[room].events;
        var removed: usize = 0;
        for (original) |event| if (std.mem.eql(u8, event.id, "kobold_world_exit")) {
            if (event.x != 360 or event.y != 0 or event.w != 8 or event.h != 384) return error.UnsupportedWorldVillageExit;
            removed += 1;
        };
        if (removed != 1) return error.UnsupportedWorldVillageExit;
        const events = try self.allocator.alloc(field.Event, original.len - 1);
        var index: usize = 0;
        for (original) |event| if (!std.mem.eql(u8, event.id, "kobold_world_exit")) {
            events[index] = event;
            index += 1;
        };
        self.owned_rooms[room].events = events;
        self.kobold_events = events;
    }

    pub fn open(allocator: std.mem.Allocator, content: world.Content, package: field.Package, state: field.State, heading: world.Direction) !Session {
        try content.validate();
        try package.validate();
        try state.progress.validate();
        if (std.mem.eql(u8, content.id, "region_c")) {
            const b = try world.load(allocator, world.json);
            defer b.deinit();
            var result = try open(allocator, b.value, package, state, heading);
            errdefer result.deinit();
            try result.enableKoboldExit();
            result.content = content;
            result.travel = .{ .camera = content.return_camera, .heading = heading };
            return result;
        }
        const village = package.roomIndex("vb6_village") orelse package.roomIndex("village") orelse return error.MissingWorldVillage;
        const rooms = try allocator.dupe(field.Room, package.rooms);
        errdefer allocator.free(rooms);
        const events = try allocator.alloc(field.Event, rooms[village].events.len);
        errdefer allocator.free(events);
        var length: usize = 0;
        var removed: usize = 0;
        for (rooms[village].events) |event| {
            if (std.mem.eql(u8, event.id, "village_south_exit")) {
                if (event.flag != .village_south_exit_reached or event.x != content.field_exit.x or event.y != content.field_exit.y or event.w != content.field_exit.w or event.h != content.field_exit.h) return error.UnsupportedWorldVillageExit;
                removed += 1;
            } else {
                events[length] = event;
                length += 1;
            }
        }
        if (removed != 1) return error.UnsupportedWorldVillageExit;
        rooms[village].events = events[0..length];
        var view = package;
        view.rooms = rooms;
        // The selected ordinary Hero field step is8px at speed2, rather than the episode's six-tick tuning.
        view.step_ticks = 4;
        return .{ .allocator = allocator, .content = content, .package = view, .owned_rooms = rooms, .village = village, .events = events, .travel = .{ .camera = content.return_camera, .heading = heading }, .field_state = state };
    }
    pub fn deinit(self: *Session) void {
        self.allocator.free(self.owned_rooms);
        self.allocator.free(self.events);
        if (self.kobold_events) |events| self.allocator.free(events);
    }
    pub fn tickWorld(self: *Session, input: world.Input, draws: *world.Draws, level_sum: u16, suppression_rune: bool, step_healing_rune: bool) !world.Event {
        const before = self.travel;
        errdefer self.travel = before;
        const event = try self.travel.tick(self.content, input, draws, .{ .members = self.field_state.progress.party, .level_sum = level_sum, .suppression_rune = suppression_rune, .step_healing_rune = step_healing_rune });
        if (event == .entrance) {
            const point = event.entrance;
            const room_index = if (std.mem.eql(u8, point.destination.?, "village")) self.village else self.package.roomIndex(point.destination.?) orelse return error.UnknownRoom;
            const room = self.package.rooms[room_index];
            if (!room.canStand(point.spawn_x, point.spawn_y)) return error.InvalidWorldFieldSpawn;
            self.field_moving_updates = 0;
            self.field_state.room = room_index;
            self.field_state.room_scenery = null;
            self.field_state.x = point.spawn_x;
            self.field_state.y = point.spawn_y;
            self.field_state.destination = .{ .x = point.spawn_x, .y = point.spawn_y };
            self.field_state.remaining = 0;
            self.field_state.walking = false;
            self.field_state.action_pending = false;
            self.field_state.dialogue = null;
            self.field_state.animation_ticks = 0;
            self.field_state.scene_ticks = 0;
        }
        return event;
    }
    pub fn tickField(self: *Session, input: field.Input, draws: *world.Draws, step_healing_rune: bool) !bool {
        return self.updateField(.{ .field = input }, draws, step_healing_rune, null, true);
    }
    pub fn tickFieldMenu(self: *Session, input: pause.Input, draws: *world.Draws, step_healing_rune: bool, menu: *pause.State) !bool {
        // The owning coordinator also rolls back combat metadata on failure.
        return self.updateField(input, draws, step_healing_rune, menu, true);
    }
    pub fn tickFieldMenuSource(self: *Session, input: pause.Input, draws: *world.Draws, step_healing_rune: bool, menu: *pause.State) !bool {
        return self.updateField(input, draws, step_healing_rune, menu, false);
    }
    fn updateField(self: *Session, input: pause.Input, draws: *world.Draws, step_healing_rune: bool, menu: ?*pause.State, allow_exit: bool) !bool {
        if (self.travel.mode != .field) return error.NotInWorldField;
        const before = self.field_state;
        const before_progress = before.progress.*;
        const old_updates = self.field_moving_updates;
        const old_draws = draws.*;
        const old_menu: ?pause.State = if (menu) |m| m.* else null;
        const old_effect = self.menu_effect;
        var members: [6]field.game_state.Member = undefined;
        before.progress.party.copyTo(members[0..before.progress.party.len]);
        errdefer {
            self.field_state = before;
            before.progress.* = before_progress;
            self.field_moving_updates = old_updates;
            draws.* = old_draws;
            before.progress.party.copyFrom(members[0..before.progress.party.len]);
            if (menu) |m| m.* = old_menu.?;
            self.menu_effect = old_effect;
        }
        self.menu_effect = .none;
        if (menu) |m| {
            const effect = m.tick(self.package, &self.field_state, input);
            if (effect != .none and effect != .settings_changed and !(m.live_world_context and (effect == .save or effect == .load or effect == .inspect_saves)) and !(input.party_transactions and (effect == .party_give or effect == .party_discard or effect == .party_equip))) return error.UnimplementedWorldMenuEffect;
            self.menu_effect = effect;
        } else self.field_state.tickWithGround(self.package, input.field, self.ground);
        if (before.movement_updates != self.field_state.movement_updates) {
            self.field_moving_updates +%= 1;
            try (world.Party{ .members = self.field_state.progress.party, .level_sum = 0, .step_healing_rune = step_healing_rune and self.field_moving_updates % 3 == 0 }).step(draws);
        }
        const state = &self.field_state;
        if (!allow_exit) return false;
        if (menu) |m| if (m.phase != .closed) return false;
        // Region exits are selected by the owning controller, including cross-forest returns.
        const exit_room = if (std.mem.eql(u8, self.content.id, "region_b")) self.village else self.package.roomIndex(self.content.field_room) orelse return error.UnknownRoom;
        const exit = self.content.field_exit;
        if (state.room != exit_room or state.remaining != 0 or state.dialogue != null or state.x < exit.x or state.x >= exit.x + exit.w or state.y < exit.y or state.y >= exit.y + exit.h) return false;
        state.progress.story.complete(if (std.mem.eql(u8, self.content.id, "region_b")) .village_south_exit_reached else .kobold_world_exit_reached);
        try self.travel.leaveField(self.content);
        state.walking = false;
        state.action_pending = false;
        return true;
    }
    pub fn finishBattle(self: *Session, outcome: world.Outcome, progress: field.game_state.Progress) !void {
        try progress.validate();
        try self.travel.finishBattle(outcome);
        self.field_state.progress.* = progress;
    }
};
