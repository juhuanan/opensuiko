//! Source-qualified village construction; caller owns entry, drawing and lifetime.
const std = @import("std");
const runtime = @import("event_runtime");
const motion = @import("opening_audience");
const ordinary = @import("field_actors");
const data = @import("field_events_data");

const Animations = struct { schema: []const u8, scene: []const u8, animations: []const motion.Animation };
const InitialGround = struct {
    schema: []const u8,
    scene: []const u8,
    actors_sha256: []const u8,
    content_sha256: []const u8,
    actors: []const struct { actor: []const u8, x: i32, y: i32, query: u16 },
};
pub const Source = struct {
    content: std.json.Parsed(runtime.Content),
    packet: std.json.Parsed(ordinary.Packet),
    animations: std.json.Parsed(Animations),
    initial_ground: std.json.Parsed(InitialGround),

    pub fn load(allocator: std.mem.Allocator) !Source {
        var ground_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data.village_initial_ground, &ground_hash, .{});
        if (!std.mem.eql(u8, &std.fmt.bytesToHex(ground_hash, .lower), "58973ba301a26c89621335ddf5b69f83d72eb13370e14d5241cd8953fcb4e324")) return error.InvalidVillageSource;
        const content = try std.json.parseFromSlice(runtime.Content, allocator, data.village_initializer, .{ .allocate = .alloc_always });
        errdefer content.deinit();
        const packet = try std.json.parseFromSlice(ordinary.Packet, allocator, data.village_actors, .{ .allocate = .alloc_always });
        errdefer packet.deinit();
        const animations = try std.json.parseFromSlice(Animations, allocator, data.village_animations, .{ .allocate = .alloc_always });
        errdefer animations.deinit();
        const initial_ground = try std.json.parseFromSlice(InitialGround, allocator, data.village_initial_ground, .{ .allocate = .alloc_always });
        errdefer initial_ground.deinit();
        try content.value.validate();
        try packet.value.validate(animations.value.animations);
        if (!std.mem.eql(u8, content.value.id, "vb6_room0_initializer") or
            !std.mem.eql(u8, packet.value.scene, "vb6_room0") or
            !std.mem.eql(u8, packet.value.event_sha256, content.value.content_sha256) or
            !std.mem.eql(u8, animations.value.schema, "suikoden-field-ordinary-animations/1") or
            !std.mem.eql(u8, animations.value.scene, packet.value.scene) or
            packet.value.actors.len != 3 or !std.mem.eql(u8, packet.value.actors[1].id, "vb6_room0_entity_08")) return error.InvalidVillageSource;
        const facts = initial_ground.value;
        if (!std.mem.eql(u8, facts.schema, "suikoden-vb6-room0-initial-ground/1") or !std.mem.eql(u8, facts.scene, packet.value.scene) or
            !std.mem.eql(u8, facts.actors_sha256, packet.value.content_sha256) or !std.mem.eql(u8, facts.content_sha256, "700dc5a8808975be06c87977ae2d9b1147febb7c8b59f23ac7859e3a917de7d1") or facts.actors.len != packet.value.actors.len) return error.InvalidVillageSource;
        for (facts.actors, packet.value.actors) |fact, actor| {
            if (!std.mem.eql(u8, fact.actor, actor.id) or fact.x != actor.x or fact.y != actor.y) return error.InvalidVillageSource;
        }
        return .{ .content = content, .packet = packet, .animations = animations, .initial_ground = initial_ground };
    }
    pub fn deinit(self: Source) void {
        self.initial_ground.deinit();
        self.animations.deinit();
        self.packet.deinit();
        self.content.deinit();
    }

    // Only constructor positions are proven; movement requires its own ground state.
    pub fn ground(self: *const Source) ordinary.GroundAccess {
        return .{ .identity = self.initial_ground.value.content_sha256, .context = self, .ground_fn = initialGround };
    }
    fn initialGround(context: *const anyopaque, id: []const u8, position: motion.ActorMotion) ?bool {
        const self: *const Source = @ptrCast(@alignCast(context));
        if (position.moving()) return null;
        for (self.initial_ground.value.actors) |fact| if (std.mem.eql(u8, fact.actor, id)) {
            if (position.x == fact.x and position.y == fact.y) return true;
            return null;
        };
        return null;
    }
};

pub const Actors = struct {
    content_sha256: []const u8,
    construction_story: runtime.StoryState,
    slots: [3]?ordinary.Slot,

    fn from(state: ordinary.State) !Actors {
        if (state.count != 3) return error.InvalidVillageState;
        return .{ .content_sha256 = state.content_sha256, .construction_story = state.construction_story, .slots = state.slots[0..3].* };
    }
    fn expand(self: Actors) ordinary.State {
        var state: ordinary.State = .{ .content_sha256 = self.content_sha256, .construction_story = self.construction_story, .count = 3 };
        @memcpy(state.slots[0..3], &self.slots);
        return state;
    }
    pub fn rebindEquivalent(self: Actors, from_packet: ordinary.Packet, to_packet: ordinary.Packet, animations: []const motion.Animation) !ordinary.State {
        return self.expand().rebindEquivalent(from_packet, to_packet, animations);
    }
    pub fn actorAtLayout(self: *Actors, packet: ordinary.Packet, layout: usize, id: []const u8) !*motion.Avatar {
        if (layout >= self.slots.len or layout >= packet.actors.len or !std.mem.eql(u8, packet.actors[layout].id, id)) return error.UnknownFieldActor;
        const slot = if (self.slots[layout]) |*value| value else return error.InvalidFieldActorState;
        if (slot.phase == .absent) return error.FieldActorNotConstructed;
        if (slot.phase == .released) return error.FieldActorReleased;
        return if (slot.avatar) |*avatar| avatar else error.InvalidFieldActorState;
    }
};

pub const State = struct {
    version: u8 = 2,
    actors: Actors,
    ground_identity: []const u8,
    initializer_batch: ?u64 = null,

    pub fn construct(source: Source, story: runtime.StoryState, ground: ordinary.GroundAccess) !State {
        if (ground.identity.len == 0) return error.UnsupportedVillageGround;
        var result: State = .{ .actors = try Actors.from(try ordinary.State.construct(source.packet.value, source.animations.value.animations, story)), .ground_identity = ground.identity };
        try result.checkGround(ground);
        const content = source.content.value;
        const program = content.program("vb6_r00_init_06") orelse return error.InvalidVillageSource;
        if (story.matches(program.conditions)) {
            var next_story = story;
            var instance = try runtime.start(content, &next_story, program.id);
            const batch = (try runtime.step(content, &instance, &next_story, .{})).batch orelse return error.InvalidVillageInitializer;
            if (batch.id != 1 or batch.effect_count != 1 or batch.effects[0].kind != .release_actor or batch.effects[0].origin != 1 or !std.mem.eql(u8, batch.effects[0].actor orelse return error.InvalidVillageInitializer, "vb6_room0_entity_08")) return error.InvalidVillageInitializer;
            var actors = result.actors.expand();
            try actors.release(source.packet.value, "vb6_room0_entity_08");
            result.actors = try Actors.from(actors);
            try runtime.acknowledge(content, &instance, &next_story, batch.id);
            if (instance.execution.pc != 3 or !std.meta.eql(story, next_story)) return error.InvalidVillageInitializer;
            result.initializer_batch = batch.id;
        }
        return try result.rebind(source, ground);
    }
    fn checkGround(self: State, ground: ordinary.GroundAccess) !void {
        if (ground.identity.len == 0 or !std.mem.eql(u8, self.ground_identity, ground.identity)) return error.UnsupportedVillageGround;
        for (self.actors.slots) |slot| if (slot.?.avatar) |avatar| {
            if (avatar.support != null or ground.ground_fn(ground.context, avatar.id, avatar.motion) != true) return error.UnsupportedVillageGround;
        };
    }
    pub fn rebind(self: State, source: Source, ground: ordinary.GroundAccess) !State {
        if (self.version != 2) return error.InvalidVillageState;
        var result = self;
        result.actors = try Actors.from(try self.actors.expand().rebind(source.packet.value, source.animations.value.animations));
        try result.checkGround(ground);
        result.ground_identity = ground.identity;
        const program = source.content.value.program("vb6_r00_init_06") orelse return error.InvalidVillageSource;
        const eligible = result.actors.construction_story.matches(program.conditions);
        if ((result.initializer_batch != null) != eligible or (eligible and result.initializer_batch.? != 1)) return error.InvalidVillageInitializer;
        const expected_phase: @FieldType(ordinary.Slot, "phase") = if (eligible) .released else .active;
        if (result.actors.slots[1].?.phase != expected_phase or result.actors.slots[2].?.phase != .active or result.actors.slots[0].?.phase == .released) return error.InvalidVillageInitializer;
        return result;
    }
};
