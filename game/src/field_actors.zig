const std = @import("std");
const runtime = @import("event_runtime");
const motion = @import("opening_audience");
const population = @import("scene_population");
// The caller owns retained source attachment facts; coordinates alone are insufficient.
pub const GroundAccess = struct {
    identity: []const u8,
    context: *const anyopaque,
    ground_fn: *const fn (*const anyopaque, []const u8, motion.ActorMotion) ?bool,
};
pub const EntryPlacement = struct { conditions: []const runtime.Condition, x: i32, y: i32 };
pub const Definition = struct {
    id: []const u8,
    entity: u8,
    slot: u8,
    resource: []const u8,
    graphic: []const u8,
    x: i32,
    y: i32,
    speed: u8,
    variant: u2,
    auto_animate: bool,
    conditions: []const runtime.Condition,
    source_graphics: enum { child_present, child_null } = .child_present,
    presence: []const population.Term = &.{},
    entry_placement: ?EntryPlacement = null,
    required_party_graphic: ?u8 = null,
    scene_owned: bool = false,

    pub fn partyGraphicAvailable(self: Definition, party: []const u8) bool {
        const character = self.required_party_graphic orelse return true;
        return std.mem.indexOfScalar(u8, party, character) != null;
    }

    pub fn initialPosition(self: Definition, story: runtime.StoryState) Position {
        if (self.entry_placement) |placement| if (story.matches(placement.conditions))
            return .{ .actor = self.slot, .x = placement.x, .y = placement.y };
        return .{ .actor = self.slot, .x = self.x, .y = self.y };
    }

    pub fn selected(self: Definition, story: *const runtime.StoryState, party: []const u8) bool {
        if (!story.matches(self.conditions)) return false;
        const facts: population.Facts = .{ .story = story, .party = party, .active_party_count = @intCast(party.len) };
        for (self.presence) |term| if (!(population.eventTermMatchesWithFacts(term, facts, false, null) orelse false)) return false;
        return true;
    }

    pub fn jsonStringify(self: Definition, writer: anytype) !void {
        try writer.beginObject();
        inline for (std.meta.fieldNames(Definition)) |name| {
            const include = if (comptime std.mem.eql(u8, name, "presence")) self.presence.len != 0 else if (comptime std.mem.eql(u8, name, "entry_placement")) self.entry_placement != null else if (comptime std.mem.eql(u8, name, "required_party_graphic")) self.required_party_graphic != null else if (comptime std.mem.eql(u8, name, "scene_owned")) self.scene_owned else true;
            if (include) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
};
pub const Packet = struct {
    schema: []const u8,
    scene: []const u8,
    binding_sha256: []const u8,
    population_sha256: []const u8,
    event_sha256: []const u8,
    content_sha256: []const u8,
    actors: []const Definition,
    pub fn findAnimation(self: Packet, animations: []const motion.Animation, definition: Definition) !motion.Animation {
        _ = self;
        for (animations) |animation| if (std.mem.eql(u8, animation.graphic, definition.graphic)) return animation;
        return error.MissingFieldActorResource;
    }
    pub fn validate(self: Packet, animations: []const motion.Animation) !void {
        if ((!std.mem.eql(u8, self.schema, "suikoden-field-ordinary-actors/1") and !std.mem.eql(u8, self.schema, "suikoden-field-ordinary-actors/2")) or self.actors.len == 0 or self.actors.len > 64 or self.binding_sha256.len != 64 or self.content_sha256.len != 64 or self.population_sha256.len != 64 or self.event_sha256.len != 64) return error.InvalidFieldActorResource;
        for (self.actors, 0..) |actor, i| {
            if (actor.scene_owned and (!std.mem.eql(u8, self.schema, "suikoden-field-ordinary-actors/2") or actor.source_graphics != .child_present or actor.entry_placement != null or actor.required_party_graphic != null or actor.conditions.len != 0 or actor.presence.len != 0)) return error.InvalidFieldActorResource;
            if (actor.required_party_graphic) |character| if (character == 0 or character == 255 or actor.source_graphics != .child_present) return error.InvalidFieldActorResource;
            if (actor.slot != i or actor.id.len == 0 or actor.resource.len == 0 or actor.x < 0 or actor.x > 2040 or actor.y < 0 or actor.y > 2040 or @mod(actor.x, 8) != 0 or @mod(actor.y, 8) != 0 or actor.speed > (if (actor.scene_owned) @as(u8, 2) else 1)) return error.InvalidFieldActorResource;
            for (self.actors[0..i]) |prior| if (std.mem.eql(u8, prior.id, actor.id) or (prior.entity == actor.entity and !prior.scene_owned and !actor.scene_owned)) return error.InvalidFieldActorResource;
            if (actor.source_graphics == .child_present) {
                const animation = try self.findAnimation(animations, actor);
                for (animation.clips) |clip| {
                    if (clip.ticks.len == 0 or clip.ticks.len > 255 or clip.ticks.len != clip.bounds.len or clip.flags & ~@as(u8, 3) != 0) return error.InvalidFieldActorResource;
                    for (clip.ticks, clip.bounds) |ticks, bounds| if (ticks == 0 or ticks > 256 or bounds.width == 0 or bounds.height == 0 or bounds.width > 128 or bounds.height > 128) return error.InvalidFieldActorResource;
                }
            }
            for (actor.conditions) |condition| if (condition.kind != .story_mask_set and condition.kind != .story_mask_clear) return error.InvalidFieldActorResource;
            if (actor.presence.len > population.max_predicate_terms) return error.InvalidFieldActorResource;
            for (actor.presence) |term| switch (term.kind) {
                .recruit_present, .recruit_absent => if (term.slot == null or term.slot.? >= population.hq_flag_slots or
                    !std.meta.eql(term, population.Term{ .kind = term.kind, .slot = term.slot })) return error.InvalidFieldActorResource,
                .party_excludes => if (term.character_id == null or term.character_id == 255 or
                    !std.meta.eql(term, population.Term{ .kind = .party_excludes, .character_id = term.character_id })) return error.InvalidFieldActorResource,
                .stage_at_least => if (term.stage == null or term.stage.? >= 5 or
                    !std.meta.eql(term, population.Term{ .kind = .stage_at_least, .stage = term.stage })) return error.InvalidFieldActorResource,
                else => return error.UnsupportedFieldActorPresence,
            };
            if (actor.entry_placement) |placement| {
                if (actor.source_graphics != .child_present or placement.conditions.len == 0 or placement.conditions.len > 16 or
                    placement.x < 0 or placement.x > 2040 or placement.y < 0 or placement.y > 2040 or
                    @mod(placement.x, 8) != 0 or @mod(placement.y, 8) != 0) return error.InvalidFieldActorResource;
                for (placement.conditions) |condition| if (condition.flag.scenarioIndex() == null) return error.InvalidFieldActorResource;
            }
        }
    }
};
pub const Slot = struct { phase: enum { absent, active, released }, avatar: ?motion.Avatar = null };

fn sameDefinition(a: Definition, b: Definition) bool {
    if (!std.mem.eql(u8, a.id, b.id) or a.entity != b.entity or a.slot != b.slot or !std.mem.eql(u8, a.resource, b.resource) or !std.mem.eql(u8, a.graphic, b.graphic) or a.x != b.x or a.y != b.y or a.speed != b.speed or a.variant != b.variant or a.auto_animate != b.auto_animate or a.source_graphics != b.source_graphics or a.required_party_graphic != b.required_party_graphic or a.scene_owned != b.scene_owned or a.conditions.len != b.conditions.len or a.presence.len != b.presence.len) return false;
    for (a.conditions, b.conditions) |left, right| {
        if (left.kind != right.kind or left.flag.mask != right.flag.mask or !std.mem.eql(u8, left.flag.id, right.flag.id)) return false;
    }
    for (a.presence, b.presence) |left, right| {
        if (left.kind != right.kind or left.slot != right.slot or left.character_id != right.character_id) return false;
    }
    if ((a.entry_placement != null) != (b.entry_placement != null)) return false;
    if (a.entry_placement) |left| {
        const right = b.entry_placement.?;
        if (left.x != right.x or left.y != right.y or left.conditions.len != right.conditions.len) return false;
        for (left.conditions, right.conditions) |one, other| {
            if (one.kind != other.kind or one.flag.mask != other.flag.mask or !std.mem.eql(u8, one.flag.id, other.flag.id)) return false;
        }
    }
    return true;
}

pub const Position = struct { actor: u8, x: i32, y: i32, motion: ?motion.ActorMotion = null, released: bool = false };
pub const VariantReset = struct { from: u8, to: u2 };
/// Ordered primary sprite-clock work performed by one tracked Hero frame.
/// Callers may mirror this sequence into an auxiliary clock without owning a
/// second primary Hero sprite clock.
pub const HeroTickTrace = struct {
    variant_reset: ?VariantReset = null,
    stationary_select_ticks: u8 = 0,
    moving_track_ticks: u16 = 0,
};
// Receipts cover only the first two, linear coordinate commands of this source program.
pub const PositionHistory = struct {
    actor: u8,
    instance: u64,
    x_batch: u64,
    y_batch: u64 = 0,
    support_identity: []const u8,

    fn expected(self: PositionHistory, packet: Packet, content: runtime.Content, instance: *const runtime.Instance, serial: u64, committed_batch: u64) !Position {
        try instance.validate(content);
        if ((!std.mem.eql(u8, content.id, "vb6_room6_e7") and !std.mem.eql(u8, content.id, "vb6_room6_arrival")) or !std.mem.eql(u8, instance.program_id, "vb6_r06_entity07_followon") or self.instance == 0 or self.instance != serial or self.actor >= packet.actors.len or self.x_batch != 1 or committed_batch < self.x_batch) return error.InvalidFieldActorPositionHistory;
        const commands = content.program(instance.program_id).?.commands;
        if (commands.len < 2 or commands[0].kind != .actor_x or commands[1].kind != .actor_y or commands[0].actor == null or commands[1].actor == null or commands[0].value == null or commands[1].value == null or !std.mem.eql(u8, commands[0].actor.?, packet.actors[self.actor].id) or !std.mem.eql(u8, commands[1].actor.?, packet.actors[self.actor].id) or commands[0].wait != null or commands[1].wait != null or commands[0].requires != null or commands[1].requires != null) return error.InvalidFieldActorPositionHistory;
        if (committed_batch != instance.effect_sequence - @as(u64, if (instance.pending != null) 1 else 0) or (self.y_batch == 0 and committed_batch != 1) or (self.y_batch != 0 and (self.y_batch != 2 or committed_batch < self.y_batch))) return error.InvalidFieldActorPositionHistory;
        if (instance.execution.pc < 1 or (self.y_batch == 0 and instance.execution.pc != 1) or (self.y_batch != 0 and instance.execution.pc < 2)) return error.InvalidFieldActorPositionHistory;
        if (instance.execution.pc > 2 and committed_batch < 3) return error.InvalidFieldActorPositionHistory;
        return .{ .actor = self.actor, .x = @as(i32, commands[0].value.?) * 8, .y = if (self.y_batch != 0) @as(i32, commands[1].value.?) * 8 else packet.actors[self.actor].y };
    }
};
pub const PositionOwnership = struct { history: PositionHistory, instance: *const runtime.Instance, serial: u64, committed_batch: u64 };

fn selectAvatar(avatar: *motion.Avatar, animation: motion.Animation, variant: u2, stationary: bool, trace: ?*HeroTickTrace) void {
    avatar.orientation_flags = switch (variant) {
        0 => avatar.orientation_flags & 2,
        1 => avatar.orientation_flags | 1,
        2 => avatar.orientation_flags & 1,
        3 => avatar.orientation_flags | 2,
    };
    if (avatar.variant != variant) {
        if (trace) |value| value.variant_reset = .{ .from = avatar.variant, .to = variant };
        avatar.variant = variant;
        avatar.sprite = motion.SpriteAnimation.start(animation.clips[variant]);
        if (stationary and animation.clips[variant].ticks.len > 1 and avatar.sprite.frame != 1 and avatar.sprite.frame != 3) {
            avatar.sprite.tick(animation.clips[variant]);
            if (trace) |value| value.stationary_select_ticks += 1;
        }
    }
}

// The caller supplies a collision decision from the actual field; null leaves the job untouched.
pub const TrackJob = struct {
    track: u8,
    actor: u8,
    state: motion.TrackState,

    pub fn validate(self: TrackJob, content: runtime.Content, actor_id: []const u8) !void {
        if (self.track >= content.tracks.len) return error.InvalidFieldActorState;
        const track = content.tracks[self.track];
        if (!std.mem.eql(u8, track.actor, actor_id) or self.state.cursor > track.commands.len or
            self.state.active == (self.state.cursor == track.commands.len)) return error.InvalidFieldActorState;
        if (self.state.remaining != 0) {
            if (self.state.cursor == 0) return error.InvalidFieldActorState;
            const last = track.commands[self.state.cursor - 1];
            if ((last.kind != .move and last.kind != .advance) or last.cells == null or
                self.state.remaining >= last.cells.?) return error.InvalidFieldActorState;
        }
        if (self.state.hold_remaining != 0) {
            if (!self.state.active or self.state.remaining != 0 or self.state.hop_remaining != 0 or self.state.motion != 0 or self.state.cursor == 0) return error.InvalidFieldActorState;
            const last = track.commands[self.state.cursor - 1];
            if (last.kind != .hold or last.updates == null or self.state.hold_remaining > last.updates.?) return error.InvalidFieldActorState;
        }
        if (self.state.hop_remaining != 0) {
            if (!self.state.active or self.state.remaining != 0 or self.state.motion != 0 or self.state.cursor == 0 or self.state.hop_remaining >= motion.hop_offsets.len or track.commands[self.state.cursor - 1].kind != .hop) return error.InvalidFieldActorState;
        }
    }

    pub fn trackData(source: runtime.Track, commands: *[64]motion.TrackCommand) !motion.Track {
        if (source.commands.len == 0 or source.commands.len > commands.len) return error.InvalidFieldActorTrack;
        for (source.commands, 0..) |command, i| commands[i] = .{
            .kind = switch (command.kind) {
                .move => .move,
                .advance => .advance,
                .set_motion => .set_motion,
                .finish => .finish,
                .hold => .hold,
                .hop => .hop,
            },
            .direction = if (command.direction) |direction| switch (direction) {
                .up => .up,
                .right => .right,
                .down => .down,
                .left => .left,
            } else null,
            .cells = command.cells,
            .motion = command.motion,
            .updates = command.updates,
        };
        return .{ .id = source.id, .actor = source.actor, .commands = commands[0..source.commands.len] };
    }

    pub fn start(actors: *State, packet: Packet, content: runtime.Content, id: []const u8) !TrackJob {
        const index = for (content.tracks, 0..) |track, i| {
            if (std.mem.eql(u8, track.id, id)) break i;
        } else return error.UnknownEventTrack;
        if (index > 255) return error.InvalidFieldActorTrack;
        const track = content.tracks[index];
        const slot = for (packet.actors, 0..) |definition, i| {
            if (std.mem.eql(u8, definition.id, track.actor)) break i;
        } else return error.UnknownFieldActor;
        const avatar = try actors.actor(packet, track.actor);
        var commands: [64]motion.TrackCommand = undefined;
        const current = try motion.TrackState.start(try trackData(track, &commands), avatar.motion.speed);
        avatar.motion.speed = 2;
        avatar.motion.offset_x = 0;
        avatar.motion.offset_y = 0;
        return .{ .track = @intCast(index), .actor = @intCast(slot), .state = current };
    }

    pub fn startHero(hero: *motion.Avatar, content: runtime.Content, id: []const u8) !TrackJob {
        const index = for (content.tracks, 0..) |track, i| {
            if (std.mem.eql(u8, track.id, id)) break i;
        } else return error.UnknownEventTrack;
        if (index > 255 or !std.mem.eql(u8, content.tracks[index].actor, "hero")) return error.InvalidFieldActorTrack;
        var commands: [64]motion.TrackCommand = undefined;
        const current = try motion.TrackState.start(try trackData(content.tracks[index], &commands), hero.motion.speed);
        hero.motion.speed = 2;
        hero.motion.offset_x = 0;
        hero.motion.offset_y = 0;
        return .{ .track = @intCast(index), .actor = 255, .state = current };
    }

    pub fn tick(self: *TrackJob, actors: *State, packet: Packet, animations: []const motion.Animation, content: runtime.Content, permit: anytype) !bool {
        if (self.track >= content.tracks.len or self.actor >= packet.actors.len) return error.InvalidFieldActorTrack;
        const track = content.tracks[self.track];
        const definition = packet.actors[self.actor];
        if (!std.mem.eql(u8, track.actor, definition.id)) return error.InvalidFieldActorTrack;
        const avatar = try actors.actor(packet, definition.id);
        return self.tickAvatar(avatar, try packet.findAnimation(animations, definition), track, permit, false, null);
    }

    pub fn tickHero(self: *TrackJob, hero: *motion.Avatar, animation: motion.Animation, content: runtime.Content, permit: anytype) !bool {
        if (self.actor != 255 or self.track >= content.tracks.len or !std.mem.eql(u8, content.tracks[self.track].actor, "hero")) return error.InvalidFieldActorTrack;
        return self.tickAvatar(hero, animation, content.tracks[self.track], permit, true, null);
    }

    /// As tickHero, with a trace of the primary sprite's actual reset and tick
    /// calls for retained-clock synchronization.
    pub fn tickHeroTraced(self: *TrackJob, hero: *motion.Avatar, animation: motion.Animation, content: runtime.Content, permit: anytype, trace: *HeroTickTrace) !bool {
        if (self.actor != 255 or self.track >= content.tracks.len or !std.mem.eql(u8, content.tracks[self.track].actor, "hero")) return error.InvalidFieldActorTrack;
        trace.* = .{};
        return self.tickAvatar(hero, animation, content.tracks[self.track], permit, true, trace);
    }

    fn tickAvatar(self: *TrackJob, avatar: *motion.Avatar, animation: motion.Animation, track: runtime.Track, permit: anytype, hero: bool, trace: ?*HeroTickTrace) !bool {
        var commands: [64]motion.TrackCommand = undefined;
        const source = try trackData(track, &commands);
        const moving = avatar.motion.moving();
        var next = self.state;
        const effect = try next.tick(source, moving);
        if (effect) |action| if (action.kind == .vertical_offset) {
            avatar.motion.offset_y = action.offset_y;
        } else {
            var move = action.kind != .face;
            if (move) {
                const allowed = if (comptime @typeInfo(@TypeOf(permit)) == .@"fn") permit(avatar.motion, action.direction) else permit.decide(avatar.id, avatar.motion, action.direction);
                const decision = allowed orelse return false;
                // shortcut: blocked reverse-advance effects need separate source proof before they can run.
                if (!decision and action.kind == .advance) return false;
                move = decision;
            }
            if (action.kind != .advance) selectAvatar(avatar, animation, switch (action.direction) {
                .down => 0,
                .up => 1,
                .left => 2,
                .right => 3,
            }, action.kind == .face, if (hero) trace else null);
            if (move) avatar.motion.step(action.direction);
        };
        avatar.motion.speed = next.motion;
        if (next.active and moving) {
            const ticks: u8 = (if (hero) self.state.motion else @as(u8, 0)) + @as(u8, @intFromBool(avatar.auto_animate));
            for (0..ticks) |_| {
                avatar.sprite.tick(animation.clips[avatar.variant]);
                if (hero) {
                    if (trace) |value| {
                        value.moving_track_ticks += 1;
                    }
                }
            }
        }
        self.state = next;
        return true;
    }
};
pub const Stored = struct {
    content_sha256: []const u8,
    construction_story: runtime.StoryState,
    count: u8,
    slots: []const ?Slot,
    construction_party: ?[6]u8 = null,
    settled_positions: ?[64]?Position = null,

    pub fn jsonStringify(self: Stored, writer: anytype) !void {
        try writer.beginObject();
        inline for (comptime std.meta.fieldNames(Stored)) |name| {
            if ((!std.mem.eql(u8, name, "construction_party") or self.construction_party != null) and (!std.mem.eql(u8, name, "settled_positions") or self.settled_positions != null)) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
    pub fn restore(self: Stored) !State {
        if (self.count == 0 or self.count > 64 or self.slots.len != self.count) return error.InvalidFieldActorState;
        var result: State = .{ .content_sha256 = self.content_sha256, .construction_story = self.construction_story, .count = self.count, .construction_party = self.construction_party, .settled_positions = self.settled_positions };
        _ = try result.constructionParty();
        @memcpy(result.slots[0..self.count], self.slots);
        return result;
    }
};
pub const State = struct {
    content_sha256: []const u8,
    construction_story: runtime.StoryState,
    count: u8,
    slots: [64]?Slot = @splat(null),
    construction_party: ?[6]u8 = null,
    settled_positions: ?[64]?Position = null,
    pub fn stored(self: *const State) Stored {
        std.debug.assert(self.count > 0 and self.count <= 64);
        return .{ .content_sha256 = self.content_sha256, .construction_story = self.construction_story, .count = self.count, .slots = self.slots[0..self.count], .construction_party = self.construction_party, .settled_positions = self.settled_positions };
    }
    pub fn jsonStringify(self: *const State, writer: anytype) !void {
        try writer.write(self.stored());
    }
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !State {
        return (try std.json.innerParse(Stored, allocator, source, options)).restore() catch return error.UnexpectedToken;
    }
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !State {
        return (try std.json.innerParseFromValue(Stored, allocator, source, options)).restore() catch return error.UnexpectedToken;
    }
    pub fn construct(packet: Packet, animations: []const motion.Animation, story: runtime.StoryState) !State {
        return constructWithParty(packet, animations, story, &.{});
    }

    pub fn constructWithParty(packet: Packet, animations: []const motion.Animation, story: runtime.StoryState, party: []const u8) !State {
        try packet.validate(animations);
        if (!std.mem.eql(u8, story.schema, "suikoden-event-story/1")) return error.InvalidFieldActorState;
        var result: State = .{ .content_sha256 = packet.content_sha256, .construction_story = story, .count = @intCast(packet.actors.len) };
        for (packet.actors) |definition| if (definition.presence.len != 0 or definition.required_party_graphic != null) {
            if (party.len == 0 or party.len > 6) return error.MissingFieldActorParty;
            result.construction_party = @splat(255);
            @memcpy(result.construction_party.?[0..party.len], party);
            _ = try result.constructionParty();
            break;
        };
        for (packet.actors, 0..) |definition, i| {
            if (definition.scene_owned or !try result.matchesPresence(definition)) {
                result.slots[i] = .{ .phase = .absent };
                continue;
            }
            if (!try result.hasPartyGraphic(definition)) return error.FieldActorGraphicsUnavailable;
            if (definition.source_graphics == .child_null) {
                result.slots[i] = .{ .phase = .active };
                continue;
            }
            try result.createAvatar(packet, animations, definition);
        }
        return result;
    }

    fn createAvatar(self: *State, packet: Packet, animations: []const motion.Animation, definition: Definition) !void {
        const animation = try packet.findAnimation(animations, definition);
        const clip = animation.clips[definition.variant];
        var sprite = motion.SpriteAnimation.start(clip);
        sprite.frame = if (clip.ticks.len == 1) 0 else 1;
        sprite.remaining = clip.ticks[sprite.frame];
        const position = definition.initialPosition(self.construction_story);
        self.slots[definition.slot] = .{ .phase = .active, .avatar = .{ .id = definition.id, .graphic = definition.graphic, .motion = .{ .x = position.x, .y = position.y, .speed = definition.speed }, .variant = definition.variant, .orientation_flags = switch (definition.variant) {
            0, 2 => 0,
            1 => 1,
            3 => 2,
        }, .sprite = sprite, .attached = true, .auto_animate = definition.auto_animate } };
    }
    pub fn spawn(self: *State, packet: Packet, animations: []const motion.Animation, id: []const u8) !void {
        for (packet.actors) |definition| if (std.mem.eql(u8, id, definition.id)) {
            if (!definition.scene_owned or self.slots[definition.slot].?.phase != .absent) return error.InvalidFieldActorLifetime;
            try self.createAvatar(packet, animations, definition);
            return;
        };
        return error.UnknownFieldActor;
    }
    pub fn clearSceneActors(self: *State, packet: Packet) void {
        for (packet.actors) |definition| if (definition.scene_owned) {
            self.slots[definition.slot] = .{ .phase = .absent };
        };
    }

    fn constructionParty(self: *const State) ![]const u8 {
        const party = if (self.construction_party) |*value| value else return &.{};
        const count = std.mem.indexOfScalar(u8, party, 255) orelse party.len;
        if (count == 0 or !std.mem.allEqual(u8, party[count..], 255)) return error.InvalidFieldActorState;
        for (party[0..count], 0..) |id, index| if (std.mem.indexOfScalar(u8, party[0..index], id) != null) return error.InvalidFieldActorState;
        return party[0..count];
    }

    fn matchesPresence(self: *const State, definition: Definition) !bool {
        const party = try self.constructionParty();
        if (definition.presence.len != 0 and party.len == 0) return error.MissingFieldActorParty;
        return definition.selected(&self.construction_story, party);
    }
    fn hasPartyGraphic(self: *const State, definition: Definition) !bool {
        return definition.partyGraphicAvailable(try self.constructionParty());
    }
    pub fn actor(self: *State, packet: Packet, id: []const u8) !*motion.Avatar {
        for (packet.actors, 0..) |definition, i| if (std.mem.eql(u8, id, definition.id)) {
            const slot = &self.slots[i].?;
            if (slot.phase == .absent) return error.FieldActorNotConstructed;
            if (slot.phase == .released) return error.FieldActorReleased;
            if (slot.avatar) |*avatar| return avatar;
            return error.FieldActorGraphicsUnavailable;
        };
        return error.UnknownFieldActor;
    }
    pub fn actorAtLayout(self: *State, packet: Packet, layout: usize, id: []const u8) !*motion.Avatar {
        if (layout >= self.count or layout >= packet.actors.len or !std.mem.eql(u8, packet.actors[layout].id, id)) return error.UnknownFieldActor;
        return self.actor(packet, id);
    }
    pub fn place(self: *State, packet: Packet, id: []const u8, x: ?i32, y: ?i32) !void {
        if (x == null and y == null) return error.InvalidFieldActorPositionHistory;
        for ([_]?i32{ x, y }) |axis| if (axis) |value| {
            if (value < 0 or value > 2040 or @mod(value, 8) != 0) return error.InvalidFieldActorPositionHistory;
        };
        const avatar = try self.actor(packet, id);
        if (avatar.support != null or avatar.motion.moving()) return error.FieldActorBusy;
        if (x) |value| avatar.motion.x = value;
        if (y) |value| avatar.motion.y = value;
        avatar.pose = null;
    }
    pub fn restoreMotion(self: *State, packet: Packet, id: []const u8, speed: u8) !void {
        const definition = for (packet.actors) |definition| {
            if (std.mem.eql(u8, definition.id, id)) break definition;
        } else return error.UnknownFieldActor;
        if (speed != definition.speed) return error.InvalidFieldActorState;
        const avatar = try self.actor(packet, id);
        if (avatar.support != null or avatar.motion.moving()) return error.FieldActorBusy;
        avatar.motion.speed = speed;
    }
    pub fn transition(self: *State, packet: Packet, animations: []const motion.Animation, id: []const u8, variant: u2) !void {
        try self.selectVariant(packet, animations, id, variant, true);
    }
    fn selectVariant(self: *State, packet: Packet, animations: []const motion.Animation, id: []const u8, variant: u2, stationary: bool) !void {
        const avatar = try self.actor(packet, id);
        const definition = packet.actors[
            for (packet.actors, 0..) |d, i| {
                if (std.mem.eql(u8, id, d.id)) break i;
            } else unreachable
        ];
        const animation = try packet.findAnimation(animations, definition);
        selectAvatar(avatar, animation, variant, stationary, null);
    }
    pub fn release(self: *State, packet: Packet, id: []const u8) !void {
        for (packet.actors, 0..) |definition, i| if (std.mem.eql(u8, id, definition.id)) {
            const slot = &self.slots[i].?;
            if (slot.phase == .absent) return error.FieldActorNotConstructed;
            if (slot.phase == .released) return error.FieldActorReleased;
            if (slot.avatar) |*avatar| avatar.released = true;
            slot.phase = .released;
            return;
        };
        return error.UnknownFieldActor;
    }
    pub fn initialPosition(self: State, definition: Definition) Position {
        if (self.settled_positions) |positions| if (positions[definition.slot]) |position| return position;
        return definition.initialPosition(self.construction_story);
    }

    /// Call only after validating the completed event and its motion/placement history.
    pub fn settle(self: State, packet: Packet, animations: []const motion.Animation) !State {
        var result = self;
        result.settled_positions = @splat(null);
        for (packet.actors, 0..) |definition, i| {
            const slot = self.slots[i] orelse return error.InvalidFieldActorState;
            if (slot.phase == .absent) continue;
            if (definition.scene_owned) {
                if (slot.phase == .active) return error.UnsupportedSettledFieldActor;
                result.slots[i] = .{ .phase = .absent };
                continue;
            }
            const avatar = slot.avatar orelse continue;
            // shortcut: continuous actor jobs need a room-owned clock before they can settle.
            if (avatar.auto_animate or avatar.support != null or avatar.motion.moving() or avatar.motion.speed != definition.speed)
                return error.UnsupportedSettledFieldActor;
            const pose = avatar.drawPose();
            if (pose.x != avatar.motion.x or pose.y != avatar.motion.y) return error.UnsupportedSettledFieldActor;
            result.settled_positions.?[i] = .{ .actor = @intCast(i), .x = avatar.motion.x, .y = avatar.motion.y, .released = slot.phase == .released };
        }
        try result.validate(packet, animations);
        return result;
    }

    pub fn tick(self: *State, packet: Packet, animations: []const motion.Animation) !void {
        try self.tickCamera(packet, animations, .{ .x = 0, .y = 0 });
    }
    pub fn tickCamera(self: *State, packet: Packet, animations: []const motion.Animation, camera: motion.Point) !void {
        for (self.slots[0..self.count], 0..) |*slot, i| if (slot.*.?.phase == .active) {
            if (slot.*.?.avatar) |*avatar| {
                const animation = try packet.findAnimation(animations, packet.actors[i]);
                avatar.fieldTickAnimation(animation, false, .{ .camera = camera, .allow_player_animation = false, .hero_speed = 2 });
            }
        };
    }
    pub fn validate(self: State, packet: Packet, animations: []const motion.Animation) !void {
        try self.validateOwned(packet, animations, null, null);
        for (packet.actors, 0..) |definition, i| if (definition.scene_owned and self.slots[i].?.phase == .active) return error.InvalidFieldActorLifetime;
    }
    pub fn validateOwned(self: State, packet: Packet, animations: []const motion.Animation, content: ?runtime.Content, job: ?TrackJob) !void {
        const jobs = [_]?TrackJob{job};
        return self.validateTracks(packet, animations, content, &jobs);
    }
    pub fn validateTracks(self: State, packet: Packet, animations: []const motion.Animation, content: ?runtime.Content, jobs: []const ?TrackJob) !void {
        return self.validateTracksAt(packet, animations, content, jobs, null, null);
    }
    pub fn validateTracksAt(self: State, packet: Packet, animations: []const motion.Animation, content: ?runtime.Content, jobs: []const ?TrackJob, ownership: ?PositionOwnership, initialized_position: ?Position) !void {
        if (ownership != null and initialized_position != null) return error.InvalidFieldActorPositionHistory;
        const owned_position = if (ownership) |owner| try owner.history.expected(packet, content orelse return error.InvalidFieldActorPositionHistory, owner.instance, owner.serial, owner.committed_batch) else null;
        return self.validateTracksCore(packet, animations, content, jobs, owned_position, initialized_position, &.{});
    }
    pub fn validateTracksAtMany(self: State, packet: Packet, animations: []const motion.Animation, content: ?runtime.Content, jobs: []const ?TrackJob, ownership: ?PositionOwnership, initialized_positions: []const Position) !void {
        if (ownership != null and initialized_positions.len != 0) return error.InvalidFieldActorPositionHistory;
        var overrides: [64]?Position = @splat(null);
        for (initialized_positions) |position| {
            if (position.actor >= packet.actors.len or position.actor >= overrides.len or position.x < 0 or position.x > 2040 or position.y < 0 or position.y > 2040 or @mod(position.x, 8) != 0 or @mod(position.y, 8) != 0 or overrides[position.actor] != null) return error.InvalidFieldActorPositionHistory;
            if (position.released and (content == null or !content.?.hasActorPositions())) return error.InvalidFieldActorPositionHistory;
            if (packet.actors[position.actor].source_graphics == .child_null) return error.InvalidFieldActorPositionHistory;
            for (jobs) |job| if (job != null and job.?.actor == position.actor) return error.InvalidFieldActorPositionHistory;
            overrides[position.actor] = position;
        }
        const owned_position = if (ownership) |owner| try owner.history.expected(packet, content orelse return error.InvalidFieldActorPositionHistory, owner.instance, owner.serial, owner.committed_batch) else null;
        return self.validateTracksCore(packet, animations, content, jobs, owned_position, null, &overrides);
    }
    fn validateTracksCore(self: State, packet: Packet, animations: []const motion.Animation, content: ?runtime.Content, jobs: []const ?TrackJob, owned_position: ?Position, initialized_position: ?Position, overrides: []const ?Position) !void {
        if (!std.mem.eql(u8, self.content_sha256, packet.content_sha256) or self.count != packet.actors.len or !std.mem.eql(u8, self.construction_story.schema, "suikoden-event-story/1")) return error.InvalidFieldActorState;
        if (self.settled_positions) |positions| for (positions, 0..) |entry, i| if (entry) |position| {
            if (i >= self.count or position.actor != i or position.motion != null or
                position.x < 0 or position.x > 2040 or position.y < 0 or position.y > 2040 or
                @mod(position.x, 8) != 0 or @mod(position.y, 8) != 0 or
                packet.actors[i].scene_owned or packet.actors[i].source_graphics == .child_null or
                self.slots[i] == null or self.slots[i].?.phase == .absent or
                (position.released and self.slots[i].?.phase != .released)) return error.InvalidFieldActorPositionHistory;
        };
        var uses_party = false;
        for (packet.actors) |definition| uses_party = uses_party or definition.presence.len != 0 or definition.required_party_graphic != null;
        if (uses_party != (self.construction_party != null)) return error.InvalidFieldActorState;
        _ = try self.constructionParty();
        for (jobs, 0..) |entry, index| if (entry) |track_job| {
            const source = content orelse return error.InvalidFieldActorState;
            if (track_job.actor != 255 and track_job.actor >= packet.actors.len) return error.InvalidFieldActorState;
            const id = if (track_job.actor == 255) "hero" else packet.actors[track_job.actor].id;
            if (track_job.actor != 255 and packet.actors[track_job.actor].source_graphics == .child_null) return error.InvalidFieldActorState;
            try track_job.validate(source, id);
            for (jobs[0..index]) |prior| if (prior != null and prior.?.actor == track_job.actor) return error.InvalidFieldActorState;
        };
        for (self.slots, 0..) |entry, i| {
            if (i >= self.count) {
                if (entry != null) return error.InvalidFieldActorState;
                continue;
            }
            const slot = entry orelse return error.InvalidFieldActorState;
            const definition = packet.actors[i];
            const present = if (definition.scene_owned) slot.phase != .absent else try self.matchesPresence(definition);
            if (present and !try self.hasPartyGraphic(definition)) return error.InvalidFieldActorState;
            if ((slot.phase == .absent) == present or (slot.phase != .absent and slot.phase != .active and slot.phase != .released)) return error.InvalidFieldActorState;
            if (i < overrides.len) if (overrides[i]) |position| {
                if (!present or (if (position.released) slot.phase != .released else slot.phase != .active)) return error.InvalidFieldActorPositionHistory;
            };
            if (slot.phase == .absent and slot.avatar != null) return error.InvalidFieldActorState;
            if (definition.source_graphics == .child_null) {
                if (slot.avatar != null) return error.InvalidFieldActorState;
                continue;
            }
            if ((slot.avatar != null) != present) return error.InvalidFieldActorState;
            if (slot.avatar) |avatar| {
                const animation = try packet.findAnimation(animations, definition);
                if (avatar.variant > 3) return error.InvalidFieldActorState;
                const clip = animation.clips[avatar.variant];
                if (avatar.support != null or avatar.sprite.repeating != (clip.flags & 2 != 0) or (avatar.sprite.repeating and !avatar.sprite.active)) return error.InvalidFieldActorState;
                if (!std.mem.eql(u8, avatar.id, definition.id) or !std.mem.eql(u8, avatar.graphic, definition.graphic) or !avatar.attached or avatar.released != (slot.phase == .released) or avatar.auto_animate != definition.auto_animate or avatar.sprite.frame >= clip.ticks.len or avatar.sprite.remaining == 0 or avatar.sprite.remaining > clip.ticks[avatar.sprite.frame]) return error.InvalidFieldActorState;
                const owner = for (jobs) |candidate| {
                    if (candidate != null and candidate.?.actor == i) break candidate;
                } else null;
                const owned = owner != null;
                var source_moving = false;
                if (owner) |job| {
                    const released = slot.phase == .released and !job.state.active and content != null and content.?.hasActorPositions();
                    if ((slot.phase != .active and !released) or avatar.motion.speed != job.state.motion or avatar.motion.x < 0 or avatar.motion.x > 2040 or avatar.motion.y < 0 or avatar.motion.y > 2040 or @mod(avatar.motion.x, 8) != 0 or @mod(avatar.motion.y, 8) != 0 or avatar.motion.offset_x < -8 or avatar.motion.offset_x > 8 or avatar.motion.offset_y < -8 or avatar.motion.offset_y > 8 or (avatar.motion.offset_x != 0 and avatar.motion.offset_y != 0)) return error.InvalidFieldActorState;
                    if (!job.state.active and avatar.motion.moving()) return error.InvalidFieldActorState;
                } else {
                    const expected = if (i < overrides.len and overrides[i] != null) overrides[i].? else if (initialized_position != null and initialized_position.?.actor == i) initialized_position.? else if (owned_position != null and owned_position.?.actor == i) owned_position.? else self.initialPosition(definition);
                    if (expected.motion) |source_motion| {
                        if (!std.meta.eql(avatar.motion, source_motion) or source_motion.x != expected.x or source_motion.y != expected.y or
                            @abs(@as(i32, source_motion.offset_x)) > 8 or @abs(@as(i32, source_motion.offset_y)) > 8 or
                            (source_motion.offset_x != 0 and source_motion.offset_y != 0)) return error.InvalidFieldActorState;
                        source_moving = true;
                    } else if (avatar.motion.x != expected.x or avatar.motion.y != expected.y or avatar.motion.speed != definition.speed or avatar.motion.moving()) return error.InvalidFieldActorState;
                }
                if (avatar.pose) |pose| {
                    if (pose.variant != avatar.variant or pose.frame >= clip.ticks.len or @abs(@as(i64, pose.x) - avatar.motion.x) > (if (owned or source_moving) @as(u64, 8) else 0) or @abs(@as(i64, pose.y) - avatar.motion.y) > (if (owned or source_moving) @as(u64, 8) else 0)) return error.InvalidFieldActorState;
                }
            }
        }
    }
    pub fn rebind(self: State, packet: Packet, animations: []const motion.Animation) !State {
        return self.rebindOwned(packet, animations, null, null);
    }
    pub fn rebindOwned(self: State, packet: Packet, animations: []const motion.Animation, content: ?runtime.Content, job: ?TrackJob) !State {
        try self.validateOwned(packet, animations, content, job);
        return self.rebindValidated(packet);
    }
    pub fn rebindTracks(self: State, packet: Packet, animations: []const motion.Animation, content: ?runtime.Content, jobs: []const ?TrackJob) !State {
        try self.validateTracks(packet, animations, content, jobs);
        return self.rebindValidated(packet);
    }
    pub fn rebindTracksAt(self: State, packet: Packet, animations: []const motion.Animation, content: ?runtime.Content, jobs: []const ?TrackJob, ownership: ?PositionOwnership, initialized_position: ?Position) !State {
        try self.validateTracksAt(packet, animations, content, jobs, ownership, initialized_position);
        return self.rebindValidated(packet);
    }
    pub fn rebindTracksAtMany(self: State, packet: Packet, animations: []const motion.Animation, content: ?runtime.Content, jobs: []const ?TrackJob, ownership: ?PositionOwnership, initialized_positions: []const Position) !State {
        try self.validateTracksAtMany(packet, animations, content, jobs, ownership, initialized_positions);
        return self.rebindValidated(packet);
    }
    // Each caller must bind both packet identities to its trusted scene contexts.
    pub fn rebindEquivalent(self: State, from: Packet, to: Packet, animations: []const motion.Animation) !State {
        try from.validate(animations);
        try to.validate(animations);
        try self.validate(from, animations);
        if (!std.mem.eql(u8, from.scene, to.scene) or !std.mem.eql(u8, from.binding_sha256, to.binding_sha256) or !std.mem.eql(u8, from.population_sha256, to.population_sha256) or from.actors.len != to.actors.len) return error.FieldActorConstructionMismatch;
        for (from.actors, to.actors) |left, right| if (!sameDefinition(left, right)) return error.FieldActorConstructionMismatch;
        const result = self.rebindValidated(to);
        try result.validate(to, animations);
        return result;
    }
    fn rebindValidated(self: State, packet: Packet) State {
        var result = self;
        result.content_sha256 = packet.content_sha256;
        result.construction_story.schema = "suikoden-event-story/1";
        for (result.slots[0..result.count], 0..) |*slot, i| if (slot.*.?.avatar) |*avatar| {
            avatar.id = packet.actors[i].id;
            avatar.graphic = packet.actors[i].graphic;
        };
        return result;
    }
};
