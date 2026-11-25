//! Scripted crossing and flight routes own world movement until their landings.
const std = @import("std");
const field = @import("field");
pub const SceneSource = @import("scene_population").Source;
const Program = field.game_state.event_runtime.Program;
const travel = @import("travel_modes");
const boat_core = @import("travel").boat;
const world_map = @import("world");
pub const BoatData = boat_core.Packet;
pub const boat_json = @import("travel_data").navigation.boat_json;
pub const loadBoatData = boat_core.load;
pub const source = travel.first_crossing;
pub const teleport = @import("travel").teleport;
const cell_pixels = 8;
const flight_world = "world_f";

fn flightSelector(origin: SceneSource, entity: u8) ?u8 {
    if (origin.room != 0) return null;
    if (std.mem.endsWith(u8, origin.file, "/VF3.BIN") and (entity == 1 or entity == 3)) return 0;
    if (std.mem.endsWith(u8, origin.file, "/VF2.BIN") and entity == 1) return 1;
    return null;
}

pub fn loadTeleport(allocator: std.mem.Allocator) !teleport.catalogue.Loaded {
    const data = @import("travel_data").teleport;
    return teleport.loadCatalogue(allocator, data.viki_json, data.mirror_json);
}

pub fn beginTeleport(catalogue: *const teleport.catalogue.Loaded, story: field.game_state.event_runtime.StoryState, money: u32, receipt: u64) !teleport.Session {
    const spec = teleport.catalogue;
    return teleport.Session.open(&catalogue.viki.value, &catalogue.mirror.value, .{
        .kind = .viki_event,
        .selector = spec.viki_callback_selector,
        .index = spec.viki_callback_index,
        .callback = spec.viki_request_entry,
        .request_entry = spec.viki_request_entry,
        .room = spec.viki_admission_room,
    }, .{
        .entry_id = "field_teleport",
        .content_sha256 = catalogue.viki.value.content_sha256,
        .receipt = receipt,
        .money = money,
        .story = story,
    });
}

pub fn useMirror(catalogue: *const teleport.catalogue.Loaded, package: field.Package, state: *field.State, member: usize, slot: usize) !void {
    const room = package.rooms[state.room].id;
    var outside = false;
    for (package.world_entries) |entry| {
        if (!std.mem.eql(u8, entry.world_room, room)) continue;
        outside = true;
        break;
    }
    if (!outside) return error.OutsideRequired;
    const bag = &state.progress.party[member].inventory;
    if (slot >= bag.count() or bag.slots[slot].?.id != .blinking_mirror) return error.ItemNotInSlot;
    const spec = teleport.catalogue;
    const story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
    var session = try teleport.Session.open(&catalogue.viki.value, &catalogue.mirror.value, .{
        .kind = .item_use,
        .item_id = spec.blinking_mirror_item,
        .handler = spec.blinking_mirror_handler,
        .slot = @intCast(slot),
    }, .{
        .entry_id = "use_blinking_mirror",
        .content_sha256 = catalogue.viki.value.content_sha256,
        .receipt = 1,
        .money = state.progress.money,
        .story = story,
        .world_mode = 1,
        .castle_stage = story.castle_tier,
        .item = .{ .item_id = spec.blinking_mirror_item, .slot = @intCast(slot), .present = true, .owner = state.progress.party[member].id },
    });
    const proposal = try session.confirmItem();
    try commitTeleport(&session, package, state, proposal);
}

pub fn commitTeleport(session: *teleport.Session, package: field.Package, state: *field.State, proposal: teleport.Proposal) !void {
    const plan = proposal.plan;
    var buffer: [48]u8 = undefined;
    const file = std.fs.path.basename(plan.area);
    if (!std.mem.endsWith(u8, file, ".BIN") or file.len < 5 or file.len > 16) return error.InvalidTeleportArea;
    const area = std.ascii.lowerString(buffer[0 .. file.len - 4], file[0 .. file.len - 4]);
    var room_buffer: [48]u8 = undefined;
    const id = try std.fmt.bufPrint(&room_buffer, "{s}_room_{d}", .{ area, plan.room });
    const room = package.roomIndex(id) orelse return error.UnknownTeleportRoom;
    const wanted: field.Point = .{ .x = plan.spawn.x, .y = plan.spawn.y };
    const destination = package.rooms[room];
    if (!destination.contains(wanted.x, wanted.y)) return error.InvalidTeleportArrival;
    var spawn = wanted;
    if (!destination.canStand(wanted.x, wanted.y)) {
        var nearest: u32 = std.math.maxInt(u32);
        for (0..9) |row| for (0..9) |column| {
            const dx = (@as(i32, @intCast(column)) - 4) * cell_pixels;
            const dy = (@as(i32, @intCast(row)) - 4) * cell_pixels;
            const distance = @abs(dx) + @abs(dy);
            if (distance >= nearest or !destination.canStand(wanted.x + dx, wanted.y + dy)) continue;
            nearest = distance;
            spawn = .{ .x = wanted.x + dx, .y = wanted.y + dy };
        };
        if (nearest == std.math.maxInt(u32)) return error.InvalidTeleportArrival;
    }
    const worlds = [_][]const u8{ "world_a", "world_b", "world_c", "world_d", "world_e", "world_f", "world_g", "world_h", "", "world_j", "world_k", "world_z" };
    const world = if (plan.selector.region < worlds.len) worlds[plan.selector.region] else return error.UnknownTeleportWorld;
    const return_entry = for (package.world_entries) |entry| {
        if (!std.mem.eql(u8, entry.world_room, world) or !std.mem.eql(u8, entry.area, area)) continue;
        if (plan.selector.kind == .world_point and entry.point != plan.selector.point) continue;
        break entry.id;
    } else return error.UnknownTeleportWorld;
    var verified = session.entry;
    verified.story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
    verified.money = state.progress.money;
    _ = try session.commit(teleport.currentFacts(verified));
    state.enterRoom(room, spawn);
    state.setWorldEntry(package, return_entry);
    state.progress.story.scenario.?.world_mode = 0;
    state.music = null;
}

pub const Boat = struct {
    session: boat_core.Session,
    saved_field_facing: field.Direction,

    pub fn begin(package: field.Package, state: field.State, saved_facing: field.Direction) !Boat {
        const story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
        if (!std.mem.eql(u8, package.rooms[state.room].id, source.world_room) or story.world_mode != 1 or
            state.auto_route_id != null or state.remaining != 0) return error.InvalidBoatDeparture;
        const Id = @FieldType(boat_core.Session, "entry_id");
        return .{ .session = boat_core.Session.begin(.{
            .entry_id = try Id.init("lake_boat"),
            .camera = .{ .x = @divExact(state.x, 8), .y = @divExact(state.y, 8) },
            .heading = .east,
            .upgraded = story.scenario[231] & 32 != 0,
        }, 0, .boat), .saved_field_facing = saved_facing };
    }

    pub fn motion(self: Boat) world_map.State {
        const vessel = self.session.vessel.?;
        return .{ .camera = vessel.camera, .heading = vessel.heading, .remaining = vessel.remaining, .boat = true };
    }

    pub fn validate(self: Boat, packet: BoatData, room: []const u8, x: i32, y: i32, facing: field.Direction, story: @import("field").game_state.event_runtime.StoryState) !void {
        try self.session.validateStructure(packet);
        if (self.session.status != .underway or !std.mem.eql(u8, room, source.world_room) or story.world_mode != 1 or
            self.session.vessel.?.upgraded != (story.scenario[231] & 32 != 0)) return error.InvalidBoatState;
        const vessel = self.session.vessel.?;
        if (vessel.camera.x * 8 != x or vessel.camera.y * 8 != y or vessel.remaining != 0 or vessel.warning != .none) return error.InvalidBoatState;
        const expected: field.Direction = switch (vessel.heading) {
            .north => .up,
            .east => .right,
            .south => .down,
            .west => .left,
        };
        if (facing != expected) return error.InvalidBoatState;
    }

    pub fn tick(self: *Boat, packet: BoatData, package: field.Package, state: *field.State, direction: ?field.Direction) !bool {
        const story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
        if (!std.mem.eql(u8, package.rooms[state.room].id, source.world_room) or story.world_mode != 1 or state.auto_route_id != null) return error.StaleBoatOwner;
        const upgraded = story.scenario[231] & 32 != 0;
        if ((self.session.vessel orelse return error.StaleBoatOwner).upgraded != upgraded) return error.StaleBoatOwner;
        const requested: ?world_map.Direction = if (direction) |d| switch (d) {
            .up => .north,
            .right => .east,
            .down => .south,
            .left => .west,
        } else null;
        var next = self.*;
        var destination = state.*;
        const step = try next.session.steer(packet, requested, .{
            .story = story,
            .recruitment_tier = story.castle_tier,
            .hero_x = @divTrunc(state.x, 8),
            .hero_y = @divTrunc(state.y, 8),
            .pressed = 0,
            .upgrade_flag = upgraded,
        });
        switch (step) {
            .warning => return error.UnsupportedBoatWarning,
            .point => |proposal| {
                const name = proposal.point.destination orelse return error.UnsupportedBoatDestination;
                var buffer: [96]u8 = undefined;
                const id = try std.fmt.bufPrint(&buffer, "{s}_room_{d}", .{ name, proposal.point.room });
                const room = package.roomIndex(id) orelse return error.UnsupportedBoatDestination;
                const point = std.math.cast(u8, proposal.point.index) orelse return error.UnsupportedBoatDestination;
                const spawn: field.Point = .{ .x = proposal.point.spawn_x, .y = proposal.point.spawn_y };
                if (!package.rooms[room].contains(spawn.x, spawn.y) or
                    (!package.rooms[room].canStand(spawn.x, spawn.y) and !package.permitsSourceArrival(id, spawn.x, spawn.y))) return error.InvalidBoatArrival;
                destination.enterRoom(room, spawn);
                destination.reconcileWorldEntry(package, point);
                destination.facing = self.saved_field_facing;
                destination.auto_route_id = null;
                destination.progress.story.scenario.?.world_mode = 0;
                state.* = destination;
                return true;
            },
            .none => {},
        }
        const vessel = next.session.vessel.?;
        destination.destination = .{ .x = vessel.camera.x * 8, .y = vessel.camera.y * 8 };
        destination.x = destination.destination.x;
        destination.y = destination.destination.y;
        if (vessel.remaining != 0) switch (vessel.heading) {
            .north => destination.y += 8,
            .east => destination.x -= 8,
            .south => destination.y -= 8,
            .west => destination.x += 8,
        };
        destination.facing = switch (vessel.heading) {
            .north => .up,
            .east => .right,
            .south => .down,
            .west => .left,
        };
        destination.remaining = vessel.remaining;
        destination.step_duration = 16;
        destination.walking = vessel.remaining != 0;
        destination.action_pending = false;
        destination.animation_ticks +%= 1;
        destination.movement_updates +%= 1;
        destination.scene_ticks +%= 1;
        self.* = next;
        state.* = destination;
        return false;
    }
};

pub fn validatePackage(package: field.Package) !void {
    const world = package.rooms[package.roomIndex(source.world_room) orelse return error.MissingCrossingWorld];
    const island = package.rooms[package.roomIndex(source.island_room) orelse return error.MissingCrossingIsland];
    if (world.width != 1280 or world.height != 960 or world.boat_walkable == null or
        !island.contains(source.spawn[0], source.spawn[1])) return error.InvalidCrossingPackage;
}

pub fn validateContent(package: field.Package, origin: SceneSource, program: Program) !void {
    if (flightSelector(origin, program.entity)) |number| {
        const world = package.rooms[package.roomIndex(flight_world) orelse return error.InvalidFlightDeparture];
        var in_flight = false;
        var armed = false;
        for (program.commands) |command| switch (command.kind) {
            .world_mode => in_flight = command.code == 0x0D,
            .auto_route => {
                if (!in_flight or armed or command.value != number) return error.InvalidFlightDeparture;
                armed = true;
            },
            .world_transition => {
                if (!armed or !in_flight or !command.retain_world_region or
                    !world.contains(command.x.? * cell_pixels, command.y.? * cell_pixels)) return error.InvalidFlightDeparture;
                return;
            },
            else => {},
        };
        return error.InvalidFlightDeparture;
    }
    try validatePackage(package);
    if (!std.mem.endsWith(u8, origin.file, "/VB2.BIN") or !std.mem.eql(u8, origin.sha256, source.caller_sha256) or
        origin.room != 0 or program.entity != 21) return error.UnsupportedCrossingCaller;
    var boat = false;
    var arrival_music = false;
    var selector = false;
    var transition = false;
    for (program.commands) |command| switch (command.kind) {
        .world_mode => if (command.code == 0x0c) {
            boat = true;
        } else if (command.code == 0x14) {
            arrival_music = true;
        },
        .auto_route => {
            if (!boat or !arrival_music or selector or command.value != source.selector) return error.UnsupportedCrossingRoute;
            selector = true;
        },
        .world_transition => {
            if (!selector or !std.mem.eql(u8, command.destination.?, source.world_room) or
                command.x != source.start[0] or command.y != source.start[1]) return error.InvalidCrossingDeparture;
            transition = true;
        },
        else => {},
    };
    if (!transition) return error.MissingCrossingDeparture;
}

pub const Active = struct {
    controller: travel.Controller,
    saved_field_facing: field.Direction,
    flight: bool = false,

    pub fn begin(package: field.Package, world: field.State, origin: SceneSource, program: Program) !Active {
        try validateContent(package, origin, program);
        const story = world.progress.story.scenario orelse return error.MissingSourceStoryState;
        if (flightSelector(origin, program.entity)) |number| {
            if (!std.mem.eql(u8, package.rooms[world.room].id, flight_world) or
                world.auto_route_id != number or story.world_mode != 2 or world.remaining != 0 or
                world.dialogue != null) return error.InvalidFlightDeparture;
            var controller = try travel.Controller.open(.{
                .id = program.id,
                .content_sha256 = origin.sha256,
                .location = flight_world,
                .position = .{ .x = @intCast(@divExact(world.x, cell_pixels)), .y = @intCast(@divExact(world.y, cell_pixels)) },
                .heading = if (number == 0) .west else .east,
            });
            try controller.startRoute(number);
            return .{ .controller = controller, .saved_field_facing = world.facing, .flight = true };
        }
        if (!std.mem.eql(u8, package.rooms[world.room].id, source.world_room) or
            world.auto_route_id != source.selector or story.world_mode != 1 or
            world.remaining != 0 or world.dialogue != null or
            world.x != source.start[0] * cell_pixels or world.y != source.start[1] * cell_pixels or
            story.scenario[12] & 1 == 0 or story.scenario[12] & 32 != 0 or
            world.progress.story.recruitment_tier != 0 or story.scenario[29] & 32 != 0 or
            story.scenario[231] & 32 != 0 or
            story.scenario[38] & 8 == 0) return error.InvalidCrossingDeparture;
        var controller = try travel.Controller.open(.{ .id = program.id, .content_sha256 = origin.sha256, .location = source.world_room, .position = .{ .x = source.start[0], .y = source.start[1] }, .heading = .west });
        try controller.startRoute(source.selector);
        return .{ .controller = controller, .saved_field_facing = world.facing };
    }

    pub fn motion(self: *const Active) world_map.State {
        const controller = self.controller.state;
        return .{
            .camera = .{ .x = controller.position.x, .y = controller.position.y },
            .heading = switch (controller.heading) {
                .north => .north,
                .east => .east,
                .south => .south,
                .west => .west,
            },
            .remaining = controller.remaining,
            .boat = true,
            .scripted = true,
        };
    }

    pub fn tick(self: *Active, package: field.Package, world: *field.State) !bool {
        const current = world.progress.story.scenario orelse return error.MissingSourceStoryState;
        if (!std.mem.eql(u8, package.rooms[world.room].id, self.controller.entry.location) or
            world.auto_route_id != self.controller.state.selector or
            current.world_mode != @as(u8, if (self.flight) 2 else 1)) return error.StaleCrossingOwner;
        var next = self.*;
        const complete = try next.controller.tickRoute();
        const crossing = next.controller.state;
        if (!self.flight and crossing.position.x >= source.point[0] and crossing.position.x <= source.point[0] + 1 and
            crossing.position.y >= source.point[1] and crossing.position.y <= source.point[1] + 1)
        {
            const story = if (world.progress.story.scenario) |*value| value else return error.MissingSourceStoryState;
            if (world.progress.story.recruitment_tier != 0 or story.scenario[29] & 32 != 0) return error.StaleCrossingArrival;
            world.enterRoom(package.roomIndex(source.island_room).?, .{ .x = source.spawn[0], .y = source.spawn[1] });
            world.facing = self.saved_field_facing;
            world.auto_route_id = null;
            story.world_mode = 0;
            story.scenario[38] &= ~@as(u8, 8);
            return true;
        }
        if (complete) return error.MissingCrossingArrival;
        world.destination = .{ .x = @as(i32, crossing.position.x) * cell_pixels, .y = @as(i32, crossing.position.y) * cell_pixels };
        world.x = world.destination.x;
        world.y = world.destination.y;
        world.facing = switch (crossing.heading) {
            .north => .up,
            .east => .right,
            .south => .down,
            .west => .left,
        };
        if (crossing.remaining != 0) switch (crossing.heading) {
            .north => world.y += cell_pixels,
            .east => world.x -= cell_pixels,
            .south => world.y -= cell_pixels,
            .west => world.x += cell_pixels,
        };
        world.remaining = crossing.remaining;
        world.step_duration = 16;
        world.walking = true;
        world.action_pending = false;
        world.animation_ticks +%= 1;
        world.movement_updates +%= 1;
        world.scene_ticks +%= 1;
        if (self.flight and world.remaining == 0) {
            const before = world.room;
            world.finishStepArrival(package);
            if (world.room != before) {
                world.auto_route_id = null;
                world.progress.story.scenario.?.world_mode = 0;
                return true;
            }
        }
        self.* = next;
        return false;
    }
};
