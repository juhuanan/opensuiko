const std = @import("std");
const field = @import("field");
const runtime = @import("event_runtime");
const records = @import("opening_records");
const ted_party_add = records.ted_party_add;
const field_records = records.field_records;
const room2_descriptor = @import("descriptor_release");
const room2_movement = @import("movement_batch");
const room2_text_host = @import("room2_text").host;
pub const Room2Descriptor = struct {
    history_len: u2 = 0,
    batches: [2]u64 = @splat(0),
    descriptor_16_result: ?u8 = null,
    movement: ?room2_movement.State = null,
    movement_frames: u8 = 0,
};
pub const fade = @import("fade");
const population = @import("scene_population");
pub const source_dispatch = @import("scene_dispatch");
const dispatch = source_dispatch;
const motion = @import("opening_audience");
pub const hero_descriptor = @import("hero_descriptor");
const data = @import("field_events_data");
pub const ordinary = @import("field_actors");
pub const village = @import("village_initializer.zig");
pub const TextState = motion.TextState;
pub const TextSpeed = enum { fast, normal, slow };
const sources_mod = @import("field_events_sources.zig");
const dispatch_mod = @import("field_events_dispatch.zig");
const dq_mod = @import("field_events_dialogue_queue.zig");
const state_mod = @import("field_events_state.zig");

const HeroAnimations = sources_mod.HeroAnimations;
const DispatchBundle = sources_mod.DispatchBundle;
const FieldPredicates = sources_mod.FieldPredicates;
pub const semanticEqual = sources_mod.semanticEqual;
pub const Context = sources_mod.Context;
pub const Sources = sources_mod.Sources;
pub const vb6_sources = sources_mod.vb6_sources;
pub const vaa_sources = sources_mod.vaa_sources;
pub const VillageDialogue = sources_mod.VillageDialogue;
pub const Owned = sources_mod.Owned;
pub const BattleRooms = @import("field_battle_rooms.zig").BattleRooms;
pub const FollowonCandidate = sources_mod.FollowonCandidate;

pub const MovementAccess = struct {
    identity: []const u8,
    camera: motion.Point,
    event_active: bool,
    context: *const anyopaque,
    decide_fn: *const fn (*const anyopaque, []const u8, motion.ActorMotion, motion.Direction) ?bool,
    pub fn decide(self: MovementAccess, id: []const u8, actor: motion.ActorMotion, direction: motion.Direction) ?bool {
        return self.decide_fn(self.context, id, actor, direction);
    }
};
// The caller validates and owns the candidate stream; this is not playback.
pub const AudioAccess = struct { identity: []const u8, audience_path: []const u8, initial_cached_command: ?u16 = null };
pub const AudioRequest = struct { batch: u64, command: u16, origin: u16, track: enum { audience } };
/// A source cue is a logical command request. The caller may hand it to its
/// source command owner; event execution never requires decoded media or a timer.
pub const SourceCueRequest = struct {
    content_id: []const u8,
    content_sha256: []const u8,
    program: []const u8,
    instance: u64,
    batch: u64,
    origin: u16,
    cue: u16,
};
pub const RoomTransitionProposal = struct {
    content_id: []const u8,
    content_sha256: []const u8,
    program: []const u8,
    instance: u64,
    batch: u64,
    origin: u16,
    destination: []const u8,
    x: i32,
    y: i32,
    arrival_facing: ?field.Direction = null,
};
pub fn fieldDirection(direction: runtime.Direction) field.Direction {
    return switch (direction) {
        .up => .up,
        .down => .down,
        .left => .left,
        .right => .right,
    };
}
pub const TransitionCommit = struct { state: field.State, event: Session };
pub const GroundAccess = ordinary.GroundAccess;
pub const FieldEffectBlend = enum { half };
pub const RoomActor = struct {
    id: []const u8,
    entity: u8,
    facing: field.Direction = .down,
    poses: [4]field.Frame,
    clips: ?[4]field.Clip = null,
    entry_placement: ?ordinary.EntryPlacement = null,
    required_party_graphic: ?u8 = null,
    scene_actor: ?struct { character: u8, x: i32, y: i32 } = null,
    speed: ?u1 = null,
    pub fn jsonStringify(self: RoomActor, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(RoomActor).@"struct".field_names) |name| {
            const include = if (comptime std.mem.eql(u8, name, "clips")) self.clips != null else if (comptime std.mem.eql(u8, name, "entry_placement")) self.entry_placement != null else if (comptime std.mem.eql(u8, name, "required_party_graphic")) self.required_party_graphic != null else if (comptime std.mem.eql(u8, name, "scene_actor")) self.scene_actor != null else if (comptime std.mem.eql(u8, name, "speed")) self.speed != null else true;
            if (include) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
};
pub const PartyActor = struct { character: u8, id: []const u8, clips: [4]field.Clip };
const DispatchData = struct { packet: dispatch.Packet, bundle: DispatchBundle, predicates: FieldPredicates, contents: []const runtime.Content };
pub const SpatialSourceContext = struct { source_sha256: []const u8, room: u8, levels: []const u8 };
pub const HeroDescriptorContext = struct { room_byte7: u8, entry_title_hold: bool };
pub const HeroDescriptorState = struct {
    auxiliary: hero_descriptor.Auxiliary,
    tint_word: u32 = 0,
    entry: fade.Entry,
    primary_attr_18: u8 = 0x80,
};

pub const ItemPresence = struct { carried: []const u16, equipped: []const u16 };

pub const Binding = struct {
    field_effect_blend: ?FieldEffectBlend = null,
    scripted_motion: bool = false,
    room_package: ?field.Package = null,
    player_name: ?[]const u8 = null,
    // Zero denotes no stored character record; positive levels come from seeds or owned members.
    character_levels: ?*const [population.hq_level_slots]u8 = null,
    item_presence: ?ItemPresence = null,
    room_actors: []const RoomActor = &.{},
    party_actors: []const PartyActor = &.{},
    room2_text_source: ?*const room2_text_host.Opened = null,
    room2_player_name: []const u8 = "",
    room2_native_pad: bool = false,
    hero_descriptor: ?HeroDescriptorContext = null,
    spatial_source: ?SpatialSourceContext = null,
    ordinary: ?ordinary.Packet = null,
    movement: ?MovementAccess = null,
    ground: ?GroundAccess = null,
    audio: ?AudioAccess = null,
    dispatch: ?DispatchData = null,
    animations: []const motion.Animation,
    room: []const u8,
    context: Context,
    content: runtime.Content,
    population: population.Packet,
    party: []const u8,
    queues: QueueData,
    dialogue: DialogueData,
    hero_animation: motion.Animation,
    hero_sha256: []const u8,

    pub fn actorOwnsEntity(self: Binding, definition: ordinary.Definition, entity: u8) bool {
        if (definition.scene_owned) return false;
        for (self.population.entities) |source| if (source.source_order == entity) {
            if (source.event.program_id) |id| if (self.content.program(id)) |program| if (program.owner_actors) |owners| {
                return owners.len == 1 and std.mem.eql(u8, definition.id, owners[0]);
            };
            if (source.event.program_id) |id| if (self.content.program(id)) |program| if (program.owner_actor) |owner|
                return std.mem.eql(u8, owner, definition.id);
            break;
        };
        return definition.entity == entity;
    }

    pub fn interactionPosition(self: Binding, entity: u8, construction: ?*const ordinary.State) ?field.Point {
        if (entity >= self.population.entities.len) return null;
        const source = self.population.entities[entity];
        if (self.ordinary) |packet| for (packet.actors, 0..) |definition, index| {
            if (!self.actorOwnsEntity(definition, entity)) continue;
            const actors = construction orelse return null;
            if (index >= actors.count) return null;
            const slot = actors.slots[index] orelse return null;
            if (slot.phase != .active) return null;
            const avatar = slot.avatar orelse return null;
            return .{ .x = avatar.motion.x, .y = avatar.motion.y };
        };
        if (source.event.program_id) |id| if (self.content.program(id)) |program| if (program.owner_actor != null or program.owner_actors != null) return null;
        if (source.position.placement != .placed) return null;
        return .{ .x = source.position.x, .y = source.position.y };
    }

    pub fn constructRoomActors(self: Binding, story: runtime.StoryState) !?ordinary.State {
        if (self.room_actors.len == 0) return null;
        return try ordinary.State.constructWithParty(self.ordinary.?, self.animations, story, self.party);
    }

    pub fn needsFreshRoomActors(self: Binding, constructed: runtime.StoryState, current: ?runtime.StoryState) bool {
        const story = current orelse return false;
        // The end of the Sarady tea scene hands the room to its morning residents.
        return std.mem.eql(u8, self.room, "va8_room_10") and constructed.scenario[8] & 8 == 0 and story.scenario[8] & 8 != 0;
    }

    pub fn validateContext(self: Binding) !void {
        if (self.item_presence) |items| {
            for (items.carried) |id| if (id == 0 or id > 255) return error.InvalidFieldItemPresence;
            for (items.equipped) |id| if (std.mem.indexOfScalar(u16, items.carried, id) == null) return error.InvalidFieldItemPresence;
        }
        if (self.character_levels) |levels| for (levels) |level| {
            if (level > 99) return error.InvalidFieldCharacterLevel;
        };
        if (self.spatial_source) |source| {
            if (!std.mem.eql(u8, self.room, "va1_room_0") or source.room != 0 or source.levels.len != 253 or
                !std.mem.eql(u8, source.source_sha256, "dcca6119f28f3863250f31be8cd164d4795eaa493aeec5b51ca0737690979fed")) return error.UnsupportedSpatialSourceContext;
            for (source.levels) |level| if (level != 1) return error.UnsupportedSpatialSourceContext;
        }
        const context = self.context;
        if (self.dialogue.usesPartySchema() and
            (!self.content.hasPartyScene() or (self.dialogue.hasFollowerBindings() and (!self.queues.isRoom() or !context.party_queue)))) return error.InvalidFieldSceneContext;
        if (!std.mem.eql(u8, context.schema, "suikoden-field-scene-context/1") or context.content_sha256.len != 64 or !std.mem.eql(u8, self.room, context.room) or !std.mem.eql(u8, self.content.id, context.event_id) or !std.mem.eql(u8, self.content.content_sha256, context.event_sha256) or !std.mem.eql(u8, self.population.id, context.population_id) or !std.mem.eql(u8, self.population.content_sha256, context.population_sha256) or !std.mem.eql(u8, self.dialogue.content_sha256, context.dialogue_sha256)) return error.InvalidFieldSceneContext;
        if ((self.ordinary != null) != (context.ordinary_sha256 != null)) return error.InvalidFieldSceneContext;
        if (self.dispatch) |policy| {
            try dispatch.validate(policy.packet);
            const scene = policy.packet.scene(self.population.id) orelse return error.InvalidFieldSceneContext;
            if (!std.mem.eql(u8, policy.bundle.id, scene.bundle.content_id) or !std.mem.eql(u8, policy.bundle.content_sha256, scene.bundle.content_sha256) or !std.mem.eql(u8, policy.bundle.population.content_id, self.population.id) or !std.mem.eql(u8, policy.bundle.population.content_sha256, self.population.content_sha256) or !std.mem.eql(u8, policy.bundle.source.sha256, self.population.source.sha256) or policy.bundle.source.room != self.population.source.room) return error.InvalidFieldSceneContext;
            try policy.predicates.validate(self.population);
        }
        if (self.ordinary) |actors| {
            try actors.validate(self.animations);
            if (!std.mem.eql(u8, actors.content_sha256, context.ordinary_sha256.?) or !std.mem.eql(u8, actors.population_sha256, context.population_sha256) or !std.mem.eql(u8, actors.event_sha256, context.event_sha256)) return error.InvalidFieldSceneContext;
            for (actors.actors) |actor| {
                if (actor.entity >= self.population.entities.len) return error.InvalidFieldSceneContext;
                if (actor.scene_owned) {
                    if (!self.content.hasSceneActors() or self.content.actor(actor.id) == null) return error.InvalidFieldSceneContext;
                    continue;
                }
                const definition = self.population.entities[actor.entity];
                if (definition.source_order != actor.entity or definition.resource_id == null or !std.mem.eql(u8, definition.resource_id.?, actor.resource) or actor.x != definition.position.x or actor.y != definition.position.y) return error.InvalidFieldSceneContext;
                if (definition.classification.pointer_state != .present or actor.conditions.len + actor.presence.len != definition.classification.terms.len) return error.InvalidFieldSceneContext;
                var ci: usize = 0;
                var pi: usize = 0;
                for (definition.classification.terms) |term| {
                    if (term.kind != .story_mask_set and term.kind != .story_mask_clear) {
                        if (pi >= actor.presence.len or !std.meta.eql(actor.presence[pi], term)) return error.InvalidFieldSceneContext;
                        pi += 1;
                        continue;
                    }
                    if (ci >= actor.conditions.len) return error.InvalidFieldSceneContext;
                    const condition = actor.conditions[ci];
                    ci += 1;
                    const expected: @FieldType(runtime.Condition, "kind") = switch (term.kind) {
                        .story_mask_set => .story_mask_set,
                        .story_mask_clear => .story_mask_clear,
                        else => return error.InvalidFieldSceneContext,
                    };
                    const flag = term.flag orelse return error.InvalidFieldSceneContext;
                    if (condition.kind != expected or !std.mem.eql(u8, condition.flag.id, flag.id) or condition.flag.mask != flag.mask) return error.InvalidFieldSceneContext;
                }
                if (ci != actor.conditions.len or pi != actor.presence.len) return error.InvalidFieldSceneContext;
            }
        }
        for (self.content.programs) |program| if (program.owner_actor) |owner| {
            const actors = self.ordinary orelse return error.InvalidFieldSceneContext;
            const definition = for (actors.actors) |actor| {
                if (std.mem.eql(u8, actor.id, owner)) break actor;
            } else return error.InvalidFieldSceneContext;
            if (definition.scene_owned or program.entity >= self.population.entities.len) return error.InvalidFieldSceneContext;
            const entity = self.population.entities[program.entity];
            if (entity.event.program_id == null or !std.mem.eql(u8, entity.event.program_id.?, program.id)) return error.InvalidFieldSceneContext;
        };
        for (self.content.programs) |program| if (program.owner_actors) |owners| {
            const actors = self.ordinary orelse return error.InvalidFieldSceneContext;
            if (program.entity >= self.population.entities.len) return error.InvalidFieldSceneContext;
            const source = self.population.entities[program.entity];
            if (source.event.program_id == null or !std.mem.eql(u8, source.event.program_id.?, program.id)) return error.InvalidFieldSceneContext;
            var previous_entity = program.entity;
            for (owners) |owner| {
                for (actors.actors) |actor| {
                    if (std.mem.eql(u8, actor.id, owner) and !actor.scene_owned) {
                        if (actor.entity >= previous_entity) return error.InvalidFieldSceneContext;
                        previous_entity = actor.entity;
                        break;
                    }
                } else return error.InvalidFieldSceneContext;
            }
        };
        const counts = [_]usize{ self.dialogue.anchors.len, self.dialogue.texts.len, self.dialogue.prefixes.len, self.dialogue.images.len, self.dialogue.descriptor_changes.len };
        for (counts, context.dialogue_counts) |actual, declared| if (actual != declared) return error.InvalidFieldSceneContext;
        for (self.dialogue.anchors) |anchor| if (anchor.actor) |id| {
            if (std.mem.eql(u8, id, "hero") and self.content.program(anchor.program).?.commands[anchor.command].actor != null) continue;
            const actors = self.ordinary orelse return error.InvalidFieldSceneContext;
            var found = false;
            for (actors.actors) |actor| found = found or std.mem.eql(u8, actor.id, id);
            if (!found) return error.InvalidFieldSceneContext;
        };
        for (self.dialogue.images) |image| if (image.domain == .area_custom) {
            const resource = image.resource orelse return error.InvalidFieldSceneContext;
            const actors = self.ordinary orelse return error.InvalidFieldSceneContext;
            var found = false;
            for (actors.actors) |actor| if (std.mem.eql(u8, actor.resource, resource)) {
                found = self.population.entities[actor.entity].source_character_id == image.character;
            };
            if (!found) return error.InvalidFieldSceneContext;
        };
    }

    pub fn validate(self: Binding, package: field.Package, count: usize) !void {
        try self.validateContext();
        try self.content.validate();
        try population.validate(self.population);
        try self.queues.validate();
        try self.dialogue.validate(self.content);
        if (!std.mem.eql(u8, self.hero_animation.graphic, "hero") or self.hero_sha256.len != 64) return error.InvalidFieldHeroAnimation;
        for (self.hero_animation.clips, package.player_clips) |animation, clip| {
            if (animation.flags != 3 or clip.idle_frame != 1 or animation.ticks.len != clip.frames.len or animation.bounds.len != clip.frames.len) return error.InvalidFieldHeroAnimation;
            for (animation.ticks, animation.bounds, clip.frames) |ticks, bounds, frame| if (ticks == 0 or ticks > 256 or ticks != frame.ticks or bounds.width != frame.rect.w or bounds.height != frame.rect.h) return error.InvalidFieldHeroAnimation;
        }
        try self.validateRoom(package.rooms[package.roomIndex(self.room) orelse return error.UnknownEventRoom], count);
    }
    pub fn validateRoom(self: Binding, room: field.Room, count: usize) !void {
        if (self.party.len != count or count == 0 or count > 6) return error.InvalidFieldEventBinding;
        try self.validateRoomScene(room);
    }
    pub fn validateRoomScene(self: Binding, room: field.Room) !void {
        try self.validateContext();
        if (!std.mem.eql(u8, room.id, self.room)) return error.UnknownEventRoom;
        if (room.width != self.population.coordinate_contract.room_half_width * 8 or room.height != self.population.coordinate_contract.room_half_height * 8) return error.InvalidFieldEventBinding;
        for (self.population.programs) |program| {
            if (!std.mem.eql(u8, program.content_id, self.content.id) or self.content.program(program.id) == null) return error.UnknownEventProgram;
        }
        for (self.population.entities) |entity| if (entity.event.status == .resolved) {
            const program = self.content.program(entity.event.program_id.?) orelse return error.UnknownEventProgram;
            if (program.entity != entity.source_order) return error.InvalidFieldEventBinding;
        };
    }
};
// Selected definitions retain their placement role; they are not permission to draw an actor.
pub const Actor = struct { entity: u8, x: i32, y: i32, placed: bool };
pub const ItemOverloadRequest = struct { item_name: []const u8, receipt: Receipt };
pub const GameplayRequest = union(enum) {
    battle: BattleRequest,
    dice: Receipt,
    party_selection: Receipt,
    item_overload: ItemOverloadRequest,
    field_music: runtime.FieldMusic,
};

pub const Receipt = struct { content_sha256: []const u8, program: []const u8, instance: u64, batch: u64 };
pub const BattleRequest = struct { id: []const u8, receipt: Receipt, defeat_target: ?u16 = null, defeat_ends_run: bool = false };
pub const BattleOutcome = enum { victory, escape, defeat };
pub const CompletedEvent = struct {
    execution: runtime.Execution,
    effect_sequence: u64,
    receipt: Receipt,
};
pub const Initialization = struct {
    entity: u8,
    kind: enum { effect_ack, pure_pump } = .effect_ack,
    receipt: ?Receipt = null,
    // Pure pumps have no effect batch to acknowledge. Retain their source
    // program and instance explicitly instead of manufacturing a receipt.
    program: []const u8 = "",
    instance: u64 = 0,
    pump_pc: u16,

    pub fn jsonStringify(self: Initialization, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("entity");
        try writer.write(self.entity);
        if (self.kind == .effect_ack) {
            try writer.objectField("receipt");
            try writer.write(self.receipt);
        } else {
            try writer.objectField("kind");
            try writer.write(self.kind);
            try writer.objectField("program");
            try writer.write(self.program);
            try writer.objectField("instance");
            try writer.write(self.instance);
        }
        try writer.objectField("pump_pc");
        try writer.write(self.pump_pc);
        try writer.endObject();
    }
};

pub const pureInitializationProgram = dispatch_mod.pureInitializationProgram;
pub const pureInitializationPump = dispatch_mod.pureInitializationPump;
pub const retainedE27Program = dispatch_mod.retainedE27Program;
pub const validateConstructedGround = dispatch_mod.validateConstructedGround;
pub const Reconstruction = dispatch_mod.Reconstruction;
pub const Blocker = dispatch_mod.Blocker;
pub const Result = dispatch_mod.Result;
pub const DispatchInput = dispatch_mod.DispatchInput;
pub const DispatchTracker = dispatch_mod.DispatchTracker;

pub const DialogueData = dq_mod.DialogueData;
pub const DialogueBox = dq_mod.DialogueBox;
pub const TextJob = dq_mod.TextJob;
pub const QueueData = dq_mod.QueueData;
pub const GraphicsResource = dq_mod.GraphicsResource;
pub const GraphicsData = dq_mod.GraphicsData;
pub const SpriteState = dq_mod.SpriteState;
pub const graphicVariant = dq_mod.graphicVariant;
pub const PartyFollower = dq_mod.PartyFollower;
pub const PartyQueue = dq_mod.PartyQueue;

pub const Session = state_mod.Session;

// Internal restart unit only; this does not grant a pause-menu save during an event.
const checkpoint = @import("field_events_checkpoint.zig");
pub const Checkpoint = checkpoint.Checkpoint;
pub const rebind = checkpoint.rebind;
