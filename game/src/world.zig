const std = @import("std");
const field = @import("field");
const rules = @import("battle_rules");
pub const json = @import("world_data").json;
pub const json_c = @import("world_data").json_c;
pub const Direction = enum { north, east, south, west };
pub const Point = struct { x: i32, y: i32 };
const deltas = [_]Point{ .{ .x = 0, .y = -1 }, .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = -1, .y = 0 } };
pub const Entrance = struct { id: []const u8, x: i32, y: i32, destination: ?[]const u8, spawn_x: i32, spawn_y: i32 };
pub const Enemy = struct { id: []const u8, name: []const u8, level: u8 };
pub const Encounter = struct { id: []const u8, enemies: [6]?[]const u8, enemy_level_sum: u16 };
pub const Content = struct {
    schema: []const u8,
    id: []const u8,
    width: u16,
    height: u16,
    walkable: []const u8,
    points: []const Entrance,
    return_camera: Point,
    field_exit: field.Rect,
    enemies: []const Enemy,
    encounters: []const Encounter,
    field_room: []const u8 = "vb6_village",
    field_exit_event: []const u8 = "village_south_exit",
    pub fn encounter(self: Content, id: []const u8) ?Encounter {
        for (self.encounters) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }
    pub fn validate(self: Content) !void {
        const region_c = std.mem.eql(u8, self.schema, "suikoden-world-travel/2") and std.mem.eql(u8, self.id, "region_c");
        if (!region_c and (!std.mem.eql(u8, self.schema, "suikoden-world-travel/1") or !std.mem.eql(u8, self.id, "region_b"))) return error.UnsupportedWorldContent;
        if (region_c and (!std.mem.eql(u8, self.field_room, "vb6_kobold_village") or !std.mem.eql(u8, self.field_exit_event, "kobold_world_exit"))) return error.UnsupportedWorldEntrance;
        if (self.width != 160 or self.height != 120 or self.walkable.len != 19200 or self.points.len > 64 or self.encounters.len == 0 or self.encounters.len > 64 or self.enemies.len == 0 or self.enemies.len > 64) return error.InvalidWorldContent;
        for (self.walkable) |cell| if (cell != '0' and cell != '1') return error.InvalidWorldContent;
        if (self.return_camera.x < 0 or self.return_camera.y < 0 or self.return_camera.x >= self.width or self.return_camera.y >= self.height) return error.InvalidWorldEntrance;
        if (self.field_exit.x < 0 or self.field_exit.y < 0 or self.field_exit.w <= 0 or self.field_exit.h <= 0 or self.field_exit.x > 2048 or self.field_exit.y > 2048 or self.field_exit.w > 2048 or self.field_exit.h > 2048 or self.field_exit.x + self.field_exit.w > 2048 or self.field_exit.y + self.field_exit.h > 2048) return error.InvalidWorldEntrance;
        for (self.enemies, 0..) |enemy, i| {
            if (enemy.id.len == 0 or enemy.id.len > 64 or enemy.name.len == 0 or enemy.name.len > 64 or enemy.level == 0 or enemy.level > 99) return error.InvalidWorldEnemy;
            for (self.enemies[0..i]) |old| if (std.mem.eql(u8, old.id, enemy.id)) return error.InvalidWorldEnemy;
        }
        for (self.encounters, 0..) |entry, i| {
            if (entry.id.len == 0 or entry.id.len > 64) return error.InvalidWorldEncounter;
            for (self.encounters[0..i]) |old| if (std.mem.eql(u8, old.id, entry.id)) return error.InvalidWorldEncounter;
            var sum: u16 = 0;
            for (entry.enemies) |id| if (id) |enemy_id| {
                const level = for (self.enemies) |enemy| {
                    if (std.mem.eql(u8, enemy.id, enemy_id)) break enemy.level;
                } else return error.UnknownWorldEnemy;
                sum += level;
            };
            if (sum == 0 or sum != entry.enemy_level_sum) return error.InvalidWorldEncounter;
        }
        for (self.points, 0..) |point, i| {
            if (point.id.len == 0 or point.id.len > 64 or point.x < 0 or point.y < 0 or point.x >= self.width or point.y >= self.height) return error.InvalidWorldEntrance;
            for (self.points[0..i]) |old| if (std.mem.eql(u8, old.id, point.id)) return error.InvalidWorldEntrance;
            if (point.destination) |destination| {
                if (region_c) {
                    if (!std.mem.eql(u8, destination, self.field_room) or point.spawn_x != 352 or point.spawn_y != 216) return error.UnsupportedWorldEntrance;
                } else if (!std.mem.eql(u8, destination, "village") or point.spawn_x != 264 or point.spawn_y != 344) return error.UnsupportedWorldEntrance;
            }
        }
    }
    pub fn passable(self: Content, camera: Point, direction: Direction) bool {
        const delta = deltas[@backingInt(direction)];
        const x = camera.x + 10 + delta.x;
        const y = camera.y + 8 + delta.y;
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return false;
        return self.walkable[@intCast(y * self.width + x)] == '1';
    }
};
pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Content) {
    if (bytes.len > 256 * 1024) return error.InvalidWorldContent;
    const parsed = try std.json.parseFromSlice(Content, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}
pub const Decision = struct { heading: Direction, accepted: bool };
pub fn resolve(requested: Direction, heading: Direction, passable: [4]bool) Decision {
    if (passable[@backingInt(requested)]) return .{ .heading = requested, .accepted = true };
    if (passable[@backingInt(heading)]) return .{ .heading = heading, .accepted = true };
    const raw: u8 = @backingInt(requested);
    const alternatives = [2]u8{ if (raw == 0) 3 else raw - 1, raw + 1 };
    for (alternatives) |candidate| {
        // Source probe4 aliases the west cell; its exhausted facing normalizes to north.
        const probe: usize = if (candidate == 4) 3 else candidate;
        if (passable[probe]) return .{ .heading = @fromBackingInt(@as(u2, @intCast(candidate % 4))), .accepted = true };
    }
    return .{ .heading = @fromBackingInt(@as(u2, @intCast((raw + 1) % 4))), .accepted = false };
}
pub fn requestedAxisAllowed(camera: Point, direction: Direction) bool {
    return switch (direction) {
        .north => camera.y > 0,
        .east => camera.x < 140,
        .south => camera.y < 105,
        .west => camera.x > 0,
    };
}
// External BIOS-rand results, not a guessed replacement PRNG. Exhaustion is explicit.
pub const Draws = rules.Draws;

pub fn pick(content: Content, draw: u15, party_level_sum: u16, suppression_rune: bool) ?Encounter {
    const count: u16 = @intCast(content.encounters.len);
    const divisor = 32767 / count;
    const index = @min(count - 1, draw / divisor);
    const entry = content.encounters[index];
    if (suppression_rune and party_level_sum > @as(u32, entry.enemy_level_sum) * 15 / 10) return null;
    return entry;
}
pub const Party = struct {
    members: []field.game_state.Member = &.{},
    level_sum: u16,
    suppression_rune: bool = false,
    step_healing_rune: bool = false,
    pub fn step(self: Party, draws: *Draws) !void {
        if (self.step_healing_rune) for (self.members) |*member| {
            if (member.hp < member.max_hp) {
                member.hp += 1;
                if (member.status == .unconscious) member.status = .healthy;
            }
        };
        for (self.members) |*member| if (member.status == .poisoned) {
            const result = rules.fieldPoison(member.hp, member.max_hp, try draws.next());
            if (result.cured) member.status = .healthy;
            member.hp -= result.damage;
        };
    }
};
pub const Input = struct { direction: ?Direction = null, encounter_arm_suppressed: bool = false };
pub const Event = union(enum) { none, entrance_requested: Entrance, entrance: Entrance, unsupported_entrance: []const u8, battle_requested: Encounter, battle: Encounter };
pub const Outcome = enum { victory, fled, released, defeated };
pub const FootSpeed = enum(u2) { normal = 1, stallion = 2 };
pub const State = struct {
    schema: []const u8 = "suikoden-world-state/2",
    camera: Point,
    heading: Direction,
    speed: FootSpeed = .normal,
    remaining: u8 = 0,
    travel_counter: u16 = 0,
    encounter_pending: bool = false,
    encounters_enabled: bool = true,
    scripted: bool = false,
    boat: bool = false,
    mode: enum { world, field_pending, field, battle_pending, battle } = .world,
    pending_entrance: ?[]const u8 = null,
    selected: ?[]const u8 = null,
    pub fn ready(self: State) bool {
        return self.remaining == 0;
    }
    pub fn originPixels(self: State) Point {
        const delta = deltas[@backingInt(self.heading)];
        const pixels: i32 = @as(i32, self.remaining) * @as(i32, @backingInt(self.speed));
        return .{ .x = self.camera.x * 16 - delta.x * pixels, .y = self.camera.y * 16 - delta.y * pixels };
    }
    pub fn checkEncounter(self: *State, content: Content, draws: *Draws, party_level_sum: u16, suppression_rune: bool) !?Encounter {
        if (content.encounters.len == 0 or !self.encounters_enabled or self.scripted or self.boat or !self.ready() or !self.encounter_pending or self.travel_counter < 5) return null;
        const old_draws = draws.*;
        errdefer draws.* = old_draws;
        const chance = try draws.next();
        var result: ?Encounter = null;
        if (chance % 256 < 8) result = pick(content, try draws.next(), party_level_sum, suppression_rune);
        self.encounter_pending = false;
        if (result) |entry| self.selected = entry.id;
        return result;
    }
    pub fn tick(self: *State, content: Content, input: Input, draws: *Draws, party: Party) !Event {
        if (self.mode == .battle_pending) {
            self.mode = .battle;
            return .{ .battle = content.encounter(self.selected.?).? };
        }
        if (self.mode == .field_pending) {
            const point = for (content.points) |entry| {
                if (std.mem.eql(u8, entry.id, self.pending_entrance.?)) break entry;
            } else return error.UnknownWorldEntrance;
            self.mode = .field;
            return .{ .entrance = point };
        }
        if (self.mode != .world) return .none;
        if (self.boat or self.scripted) return error.UnsupportedWorldTravelMode;
        if (party.members.len > 6) return error.InvalidParty;
        var previous_members: [6]field.game_state.Member = undefined;
        @memcpy(previous_members[0..party.members.len], party.members);
        const before = self.*;
        const old_draws = draws.*;
        errdefer {
            self.* = before;
            draws.* = old_draws;
            @memcpy(party.members, previous_members[0..party.members.len]);
        }
        if (self.ready()) if (input.direction) |direction| if (requestedAxisAllowed(self.camera, direction)) {
            var passable: [4]bool = undefined;
            for (0..4) |i| passable[i] = content.passable(self.camera, @fromBackingInt(@as(u2, @intCast(i))));
            const decision = resolve(direction, self.heading, passable);
            self.heading = decision.heading;
            if (decision.accepted) {
                const delta = deltas[@backingInt(self.heading)];
                self.camera.x += delta.x;
                self.camera.y += delta.y;
                self.remaining = 16 / @as(u8, @backingInt(self.speed));
            }
        };
        if (self.remaining > 0) {
            self.remaining -= 1;
            if (self.remaining == 0) {
                self.encounter_pending = true;
                self.travel_counter +%= 1;
                try party.step(draws);
            }
        }
        // Source point dispatch precedes the encounter gate, even on an interpolating entry step.
        for (content.points) |point| if (self.camera.x >= point.x and self.camera.x <= point.x + 1 and self.camera.y >= point.y and self.camera.y <= point.y + 1) {
            if (point.destination == null) return .{ .unsupported_entrance = point.id };
            self.mode = .field_pending;
            self.pending_entrance = point.id;
            return .{ .entrance_requested = point };
        };
        for (content.points) |point| if (self.camera.x >= point.x - 5 and self.camera.x <= point.x + 4 and self.camera.y >= point.y - 5 and self.camera.y <= point.y + 4) return .none;
        if (try self.checkEncounter(content, draws, party.level_sum, party.suppression_rune)) |entry| if (!input.encounter_arm_suppressed) {
            self.mode = .battle_pending;
            return .{ .battle_requested = entry };
        };
        return .none;
    }
    pub fn leaveField(self: *State, content: Content) !void {
        if (self.mode != .field) return error.NotInWorldField;
        self.camera = content.return_camera;
        self.heading = .east;
        self.pending_entrance = null;
        self.remaining = 0;
        self.travel_counter = 0;
        self.encounter_pending = false;
        self.mode = .world;
    }
    pub fn finishBattle(self: *State, outcome: Outcome) !void {
        if (self.mode != .battle) return error.NotInWorldBattle;
        if (outcome == .defeated) return;
        self.mode = .world;
        self.heading = .east;
        self.remaining = 0;
        self.travel_counter = 0;
        self.encounter_pending = false;
    }
    pub fn validate(self: State, content: Content) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-world-state/2")) return error.UnsupportedWorldState;
        if (self.camera.x < 0 or self.camera.y < 0 or self.camera.x >= content.width or self.camera.y >= content.height or self.remaining >= 16 / @as(u8, @backingInt(self.speed))) return error.InvalidWorldState;
        if (self.selected) |id| if (content.encounter(id) == null) return error.UnknownWorldEncounter;
        if (self.mode == .field or self.mode == .field_pending) {
            const id = self.pending_entrance orelse return error.InvalidWorldState;
            const point = for (content.points) |entry| {
                if (std.mem.eql(u8, entry.id, id)) break entry;
            } else return error.UnknownWorldEntrance;
            if (point.destination == null or self.camera.x < point.x or self.camera.x > point.x + 1 or self.camera.y < point.y or self.camera.y > point.y + 1) return error.InvalidWorldState;
        } else if (self.pending_entrance != null) return error.InvalidWorldState;
        if ((self.mode == .battle or self.mode == .battle_pending) and (self.selected == null or !self.ready())) return error.InvalidWorldState;
    }
    pub fn apply(self: State, content: Content, destination: *State) !void {
        try self.validate(content);
        var next = self;
        next.schema = "suikoden-world-state/2";
        if (self.selected) |id| next.selected = content.encounter(id).?.id;
        if (self.pending_entrance) |id| {
            for (content.points) |point| if (std.mem.eql(u8, point.id, id)) {
                next.pending_entrance = point.id;
                break;
            };
        }
        destination.* = next;
    }
};
pub const Checkpoint = struct {
    schema: []const u8 = "suikoden-world-checkpoint/4",
    state: State,
    random_cursor: usize,
    bios_state: ?u32 = null,
    region: []const u8 = "region_b",
    prng: ?std.Random.DefaultPrng = null,
    pub fn capture(state: State, content: Content, draws: Draws) !Checkpoint {
        try state.validate(content);
        if (!draws.valid()) return error.InvalidRandomCursor;
        return .{ .state = state, .random_cursor = draws.cursor, .bios_state = draws.bios_state, .region = content.id, .prng = draws.prng };
    }
    pub fn apply(self: Checkpoint, content: Content, state: *State, draws: *Draws) !void {
        const legacy = std.mem.eql(u8, self.schema, "suikoden-world-checkpoint/2");
        const current = std.mem.eql(u8, self.schema, "suikoden-world-checkpoint/4");
        if (!legacy and !current and !std.mem.eql(u8, self.schema, "suikoden-world-checkpoint/3")) return error.UnsupportedWorldCheckpoint;
        if (legacy and self.bios_state != null) return error.InvalidRandomCursor;
        if (!current and self.prng != null) return error.InvalidRandomSource;
        if (legacy and !std.mem.eql(u8, self.region, "region_b")) return error.UnknownWorldRegion;
        if (!std.mem.eql(u8, self.region, content.id)) return error.UnknownWorldRegion;
        const restored = try draws.restorePosition(self.random_cursor, self.bios_state, self.prng);
        try self.state.apply(content, state);
        draws.* = restored;
    }
};
