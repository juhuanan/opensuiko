const std = @import("std");
const field = @import("field");
const runtime = @import("event_runtime");
const room2_descriptor = @import("descriptor_release");
const room2_movement = @import("movement_batch");
const room2_text_host = @import("room2_text").host;
const fade = @import("fade");
const population = @import("scene_population");
const dispatch = @import("scene_dispatch");
const motion = @import("opening_audience");
const hero_descriptor = @import("hero_descriptor");
const data = @import("field_events_data");
const ordinary = @import("field_actors");
const village = @import("village_initializer.zig");
const fe = @import("field_events.zig");
const Room2Descriptor = fe.Room2Descriptor;
const TextState = fe.TextState;
const TextSpeed = fe.TextSpeed;
const begin = @import("field_events_begin.zig");
const session = @import("field_events_session.zig");
const handoffs = @import("field_events_playback/handoffs.zig");
const host = @import("field_events_host.zig");
const validation = @import("field_events_validate.zig");
const sources_mod = @import("field_events_sources.zig");
const dispatch_mod = @import("field_events_dispatch.zig");
const storage_mod = @import("field_events_storage.zig");
const semanticEqual = sources_mod.semanticEqual;
const MovementAccess = fe.MovementAccess;
const AudioAccess = fe.AudioAccess;
const AudioRequest = fe.AudioRequest;
const HeroDescriptorState = fe.HeroDescriptorState;
const Binding = fe.Binding;
const Actor = fe.Actor;
const Receipt = fe.Receipt;
const CompletedEvent = fe.CompletedEvent;
const Initialization = fe.Initialization;
const validateConstructedGround = dispatch_mod.validateConstructedGround;
const Reconstruction = dispatch_mod.Reconstruction;
const Blocker = dispatch_mod.Blocker;
const Result = dispatch_mod.Result;
const DialogueBox = fe.DialogueBox;
const TextJob = fe.TextJob;
const SpriteState = fe.SpriteState;
const PartyQueue = fe.PartyQueue;
const StoredInstance = storage_mod.StoredInstance;
const StoredSession = storage_mod.StoredSession;

pub const ScriptedCamera = struct {
    scroll: motion.Point = .{ .x = 0, .y = 0 },
    absolute: bool = false,
    pan: ?motion.Pan = null,

    pub fn validate(self: ScriptedCamera) !void {
        const destination = if (self.pan) |pan| blk: {
            if (pan.remaining == 0) return error.InvalidCameraPan;
            break :blk try pan.end(self.scroll);
        } else self.scroll;
        // Field projection consumes signed screen offsets.
        for ([_]i32{ self.scroll.x, self.scroll.y, destination.x, destination.y }) |coordinate| {
            if (std.math.cast(i16, coordinate) == null) return error.InvalidCameraPan;
        }
    }
};

pub const FieldEffectState = struct {
    schema: []const u8 = "suikoden-field-effect-state/1",
    command: u16,
    position: field.Point,
    model: field.area_effect.Effect,
};
pub const CameraPushState = struct {
    command: u16,
    start: motion.Point,
    model: runtime.camera_push.State,
};

pub const Session = struct {
    schema: []const u8 = "suikoden-field-event/11",
    content_sha256: []const u8,
    population_sha256: []const u8,
    queue_sha256: []const u8,
    dialogue_sha256: []const u8,
    graphics_sha256: []const u8 = "",
    hero_sha256: []const u8 = "",
    serial: u64,
    context_sha256: []const u8 = "",
    selected_program: bool = false,
    retained_selection: ?u8 = null,
    room2_descriptor: ?Room2Descriptor = null,
    ordinary_actors: ?ordinary.State = null,
    construction_ground_identity: []const u8 = "",
    completed_event: ?CompletedEvent = null,
    reconstruction: ?Reconstruction = null,
    position_history: ?ordinary.PositionHistory = null,
    ordinary_track: ?ordinary.TrackJob = null,
    other_tracks: [29]?ordinary.TrackJob = @splat(null),
    hero_flags: u2 = 0,
    hero_descriptor_state: ?HeroDescriptorState = null,
    movement_identity: []const u8 = "",
    movement_camera: ?motion.Point = null,
    scripted_camera: ?ScriptedCamera = null,
    wheel_graphics: ?field.wheel.ActorGraphics = null,
    field_effect: ?FieldEffectState = null,
    camera_push: ?CameraPushState = null,
    delay_remaining: u16 = 0,
    pending_battle: ?[]const u8 = null,
    inn_payment_refused: bool = false,
    fade_state: fade.State = .{},
    audio_identity: []const u8 = "",
    audio_cached_command: ?u16 = null,
    area_command: ?u16 = null,
    audio_request: ?AudioRequest = null,
    // shortcut: one field cue per update; expand when a bound script emits several.
    sound_effect: ?u16 = null,
    inside: bool = true,
    instance: ?runtime.Instance = null,
    receipt: ?Receipt = null,
    initialization_done: bool = false,
    next_initialization: u16 = 0,
    initializations: [3]?Initialization = @splat(null),
    initialization_count: u8 = 0,
    actors: [64]?Actor = @splat(null),
    actor_count: u8 = 0,
    area_party: [6]u8 = @splat(255),
    source_party: [6]u8 = @splat(255),
    active_party_count: u8,
    hero: motion.ActorMotion,
    hero_sprite: ?SpriteState = null,
    alignment: ?motion.Alignment = null,
    facing: field.Direction,
    party_queue: ?PartyQueue = null,
    boxes: [2]DialogueBox = @splat(.{}),
    text_job: ?TextJob = null,
    text_speed: TextSpeed,
    blocker: ?Blocker = null,

    pub fn jsonStringify(self: Session, writer: anytype) !void {
        var stored: StoredSession = undefined;
        inline for (comptime std.meta.fieldNames(StoredSession)) |name| {
            if (comptime std.mem.eql(u8, name, "instance")) {
                stored.instance = if (self.instance != null) StoredInstance.from(&self.instance.?) else null;
            } else if (comptime std.mem.eql(u8, name, "ordinary_actors")) {
                stored.ordinary_actors = if (self.ordinary_actors) |*actors| actors.stored() else null;
            } else @field(stored, name) = @field(self, name);
        }
        try writer.write(stored);
    }
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Session {
        return (try std.json.innerParse(StoredSession, allocator, source, options)).restore() catch return error.UnexpectedToken;
    }
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Session {
        return (try std.json.innerParseFromValue(StoredSession, allocator, source, options)).restore() catch return error.UnexpectedToken;
    }

    pub fn busy(self: *const Session) bool {
        return self.blocker != null or self.audio_request != null or
            (self.instance != null and (self.instance.?.execution.active or self.instance.?.pending != null));
    }
    pub fn validateStory(self: *const Session, story: *const runtime.StoryState) !void {
        if (story.soul_eater_spell_slots < 1 or story.soul_eater_spell_slots > 4) return error.InvalidSoulEaterProgress;
        if (std.mem.eql(u8, self.schema, "suikoden-field-event/16")) if (self.ordinary_actors) |*actors| {
            if ((story.scenario[15] ^ actors.construction_story.scenario[15]) & 0x40 != 0 or (story.scenario[16] ^ actors.construction_story.scenario[16]) & 1 != 0) return error.InvalidFieldEventStory;
        };
        if (self.reconstruction != null) {
            if (story.scenario[15] & 0x68 != 0x68) return error.InvalidFieldEventStory;
            return;
        }
        if (self.completed_event == null) return;
        const instance = self.instance orelse return error.InvalidFieldEventReceipt;
        const value = story.scenario[15];
        if (value & 0x28 != 0x28 or ((value & 0x40 != 0) != (instance.execution.pc > 11))) return error.InvalidFieldEventStory;
    }
    // The live host combines initializer data with the accepted arrival program.
    pub fn dispatchInstance(self: *const Session, binding: Binding) !runtime.Instance {
        try self.validate(binding);
        const policy = binding.dispatch orelse return error.MissingFieldDispatch;
        const instance = self.instance orelse return error.MissingFieldEventOwner;
        const host_program = binding.content.program(instance.program_id) orelse return error.UnknownEventProgram;
        const scene = policy.packet.scene(binding.population.id) orelse return error.InvalidFieldSceneContext;
        const entry = scene.entry(host_program.entity) orelse return error.UnknownDispatchOwner;
        const reference = entry.program orelse return error.UnknownDispatchOwner;
        if (!std.mem.eql(u8, reference.program_id, instance.program_id)) return error.UnknownDispatchOwner;
        const source = for (policy.contents) |content| {
            if (std.mem.eql(u8, content.id, reference.content_id) and std.mem.eql(u8, content.content_sha256, reference.content_sha256)) break content;
        } else return error.MissingDispatchProgramContent;
        const source_program = source.program(reference.program_id) orelse return error.MissingDispatchProgramContent;
        if (!semanticEqual(host_program, source_program)) return error.FieldDispatchProgramMismatch;
        for (source.actors) |actor| {
            const host_actor = binding.content.actor(actor.id) orelse return error.FieldDispatchProgramMismatch;
            if (!semanticEqual(host_actor, actor)) return error.FieldDispatchProgramMismatch;
        }
        for (source.texts) |text| {
            const host_text = binding.content.text(text.id) orelse return error.FieldDispatchProgramMismatch;
            if (!semanticEqual(host_text, text)) return error.FieldDispatchProgramMismatch;
        }
        for (source.tracks) |track| {
            const host_track = binding.content.track(track.id) orelse return error.FieldDispatchProgramMismatch;
            if (!semanticEqual(host_track, track)) return error.FieldDispatchProgramMismatch;
        }
        for (source.story_values) |value| {
            const host_value = binding.content.storyValue(value.id) orelse return error.FieldDispatchProgramMismatch;
            if (!semanticEqual(value, host_value)) return error.FieldDispatchProgramMismatch;
        }
        if (instance.pending) |pending| for (pending.batch.slice()) |effect| {
            if (effect.origin >= source_program.commands.len) return error.FieldDispatchProgramMismatch;
            var expected = source_program.commands[effect.origin];
            expected.origin = effect.origin;
            if (!semanticEqual(effect, expected)) return error.FieldDispatchProgramMismatch;
        };
        var result = instance;
        result.content_id = source.id;
        result.content_sha256 = source.content_sha256;
        try result.validate(source);
        return result;
    }
    pub fn tracks(self: Session) [30]?ordinary.TrackJob {
        var result: [30]?ordinary.TrackJob = @splat(null);
        result[0] = self.ordinary_track;
        @memcpy(result[1..], &self.other_tracks);
        return result;
    }
    pub fn activeTracks(self: Session) usize {
        var count: usize = 0;
        for (self.tracks()) |job| if (job != null and job.?.state.active) {
            count += 1;
        };
        return count;
    }
    pub fn heroTrackCamera(self: *const Session, binding: Binding) motion.Point {
        const room = binding.population.coordinate_contract;
        const width = @as(i32, room.room_half_width) * 8;
        const height = @as(i32, room.room_half_height) * 8;
        const scroll = field.sourceCameraScroll(width, height, self.hero.x + self.hero.offset_x, self.hero.y + self.hero.offset_y);
        return .{ .x = scroll.x, .y = scroll.y };
    }
    pub fn heroAvatar(self: Session) motion.Avatar {
        const sprite = self.hero_sprite.?;
        return .{ .id = "hero", .graphic = "hero", .motion = self.hero, .variant = sprite.variant, .orientation_flags = self.hero_flags, .sprite = sprite.animation, .attached = true };
    }
    pub fn setHeroAvatar(self: *Session, avatar: motion.Avatar) void {
        self.hero = avatar.motion;
        self.hero_flags = avatar.orientation_flags;
        self.hero_sprite.?.variant = @intCast(avatar.variant);
        self.hero_sprite.?.animation = avatar.sprite;
        self.facing = switch (avatar.variant) {
            0 => .down,
            1 => .up,
            2 => .left,
            3 => .right,
            else => unreachable,
        };
    }
    pub fn startHeroDriver(self: *Session, binding: Binding) !void {
        if (self.hero_descriptor_state) |*retained| {
            _ = binding.hero_descriptor orelse return error.MissingHeroDescriptorContext;
            if (retained.entry.phase == .pending) retained.tint_word = 0x80;
            try retained.entry.tick(false);
        }
    }
    pub fn ordinaryReady(self: *const Session) bool {
        return if (self.hero_descriptor_state) |retained| retained.entry.ordinaryReady() else true;
    }
    pub fn fadeOverlay(self: *const Session) ?fade.OverlayDescriptor {
        return self.fade_state.overlay() orelse if (self.hero_descriptor_state) |retained| retained.entry.overlay() else null;
    }
    pub fn resetHeroAux(self: *Session, binding: Binding, target: u2) !void {
        if (self.hero_descriptor_state) |*retained| {
            const source = binding.hero_descriptor orelse return error.MissingHeroDescriptorContext;
            retained.primary_attr_18 = try retained.auxiliary.sequenceReset(binding.hero_animation, target, source.room_byte7, retained.tint_word);
        }
    }
    pub fn tickHeroAux(self: *Session, binding: Binding, ticks: u16) !void {
        if (self.hero_descriptor_state) |*retained| {
            const source = binding.hero_descriptor orelse return error.MissingHeroDescriptorContext;
            for (0..ticks) |_| retained.primary_attr_18 = try retained.auxiliary.pairedTick(binding.hero_animation, source.room_byte7, retained.tint_word);
        }
    }
    pub fn drawHeroAux(self: *Session, binding: Binding) !void {
        if (self.hero_descriptor_state) |*retained| {
            const source = binding.hero_descriptor orelse return error.MissingHeroDescriptorContext;
            _ = try retained.auxiliary.draw(binding.hero_animation, source.room_byte7, 0, retained.tint_word);
        }
    }
    pub fn tickTrack(self: *Session, binding: Binding, job: *ordinary.TrackJob, access: MovementAccess) !void {
        if (!job.state.active) return;
        if (job.actor == 255) {
            var hero = self.heroAvatar();
            var trace: ordinary.HeroTickTrace = .{};
            if (!try job.tickHeroTraced(&hero, binding.hero_animation, binding.content, access, &trace)) return error.MissingFieldMovementAccess;
            if (trace.variant_reset) |reset| try self.resetHeroAux(binding, reset.to);
            try self.tickHeroAux(binding, @as(u16, trace.stationary_select_ticks) + trace.moving_track_ticks);
            self.setHeroAvatar(hero);
        } else {
            const actors = if (self.ordinary_actors) |*value| value else return error.MissingFieldActorConstruction;
            if (!try job.tick(actors, binding.ordinary.?, binding.animations, binding.content, access)) return error.MissingFieldMovementAccess;
        }
    }
    pub noinline fn seed(out: *Session, binding: Binding, state: field.State, serial: u64) !void {
        if (state.remaining != 0 or state.walking) return error.UnsupportedFieldHeroEntry;
        const variant: u2 = switch (state.facing) {
            .down => 0,
            .up => 1,
            .left => 2,
            .right => 3,
        };
        var animation = motion.SpriteAnimation.start(binding.hero_animation.clips[variant]);
        // Preserve the prototype renderer's settled visible pose at the source-scene handoff.
        animation.frame = 1;
        animation.remaining = binding.hero_animation.clips[variant].ticks[1];
        out.* = .{
            .context_sha256 = binding.context.content_sha256,
            .content_sha256 = binding.content.content_sha256,
            .population_sha256 = binding.population.content_sha256,
            .queue_sha256 = binding.queues.content_sha256,
            .dialogue_sha256 = binding.dialogue.content_sha256,
            .graphics_sha256 = if (binding.queues.graphics) |graphics| graphics.content_sha256 else "",
            .hero_sha256 = binding.hero_sha256,
            .hero_descriptor_state = if (binding.hero_descriptor != null) .{ .auxiliary = try hero_descriptor.Auxiliary.init(binding.hero_animation, variant), .entry = .{ .title_hold = binding.hero_descriptor.?.entry_title_hold } } else null,
            .hero_sprite = .{ .variant = variant, .animation = animation, .emitted_frame = 1, .emitted_x = state.x, .emitted_y = state.y },
            .text_speed = binding.dialogue.default_speed,
            .facing = state.facing,
            .hero_flags = switch (state.facing) {
                .down, .left => 0,
                .up => 1,
                .right => 2,
            },
            .serial = serial,
            .active_party_count = @intCast(state.progress.party.len),
            .hero = .{ .x = state.x, .y = state.y, .speed = 2 },
        };
        if (state.scene_view.camera) |camera| out.scripted_camera = .{ .scroll = .{ .x = camera.x, .y = camera.y }, .absolute = true };
        if (state.scene_view.hero) |hero| {
            out.hero_sprite.?.emitted_x = hero.x;
            out.hero_sprite.?.emitted_y = hero.y;
        }
        if (serial == 0 or binding.party.len != state.progress.party.len) return error.InvalidFieldEventBinding;
        @memcpy(out.area_party[0..binding.party.len], binding.party);
        out.source_party = out.area_party;
        return;
    }
    pub noinline fn enter(binding: Binding, state: field.State, serial: u64) !Session {
        var result: Session = undefined;
        try seed(&result, binding, state, serial);
        const story = state.progress.story.scenario orelse return error.MissingSourceStoryState;
        // World sessions construct ordinary actors only for the accepted vb6 arrival.
        // The Opening destination rooms opt in explicitly; every other legacy binding
        // keeps the pre-Opening no-construction path byte for byte.
        const opening_destination = std.mem.eql(u8, binding.content.id, "vaa_room_0") or std.mem.eql(u8, binding.content.id, "vaa_room_10") or
            std.mem.eql(u8, binding.content.id, "va1_room_0") or std.mem.eql(u8, binding.content.id, "va1_room_2");
        if (binding.ordinary != null and (std.mem.eql(u8, binding.content.id, "vb6_room6_arrival") or opening_destination)) {
            // Ordinary actor construction is shared by every validated source host.
            // The source-bound packet and its ground callback retain the same owner.
            try binding.validateContext();
            const access = binding.ground orelse return error.UnsupportedFieldGroundConstruction;
            if (access.identity.len == 0) return error.UnsupportedFieldGroundConstruction;
            const construction = try ordinary.State.constructWithParty(binding.ordinary.?, binding.animations, story, binding.party);
            try validateConstructedGround(&binding, &construction, access, !std.mem.eql(u8, binding.content.id, "vb6_room6_arrival"));
            result.ordinary_actors = construction;
            result.construction_ground_identity = access.identity;
            result.schema = if (std.mem.eql(u8, binding.content.id, "vb6_room6_arrival")) "suikoden-field-event/16" else "suikoden-field-event/19";
        }
        var selected: [population.max_entities]population.Entity = undefined;
        const eligible = try population.select(binding.population, .{ .story = &story, .active_party_count = result.active_party_count, .party = binding.party }, &selected);
        for (eligible.entities) |entity| {
            if (entity.event.program_id) |id| if (binding.content.program(id)) |program| if ((program.owner_actor != null or program.owner_actors != null)) {
                const owned = if (result.ordinary_actors) |actors| for (binding.ordinary.?.actors, 0..) |definition, index| {
                    if (binding.actorOwnsEntity(definition, entity.source_order) and actors.slots[index].?.phase == .active) break true;
                } else false else false;
                if (!owned) continue;
            };
            if (result.actor_count == result.actors.len) return error.TooManyFieldActors;
            result.actors[result.actor_count] = .{ .entity = entity.source_order, .x = entity.position.x, .y = entity.position.y, .placed = entity.position.placement == .placed };
            result.actor_count += 1;
            if (entity.position.placement == .placed and result.blocker == null) {
                const owned = if (result.ordinary_actors) |actors| for (binding.ordinary.?.actors, 0..) |definition, index| {
                    if (binding.actorOwnsEntity(definition, entity.source_order) and actors.slots[index].?.phase == .active) break true;
                } else false else false;
                if (!owned) result.blocker = .{ .entity = entity.source_order, .reason = .unbound_actor };
            }
        }
        if (result.blocker != null) return result;
        try begin.select(&result, binding, &story, .initialization, null);
        if (result.blocker == null and result.instance == null) {
            result.initialization_done = true;
            result.next_initialization = @intCast(binding.population.entities.len);
            try begin.select(&result, binding, &story, .area_entry, null);
        }
        return result;
    }

    pub const beginInteraction = begin.beginInteraction;
    pub const beginOrdinary = begin.beginOrdinary;
    pub const beginRoomEvent = begin.beginRoomEvent;
    pub const beginRoute = begin.beginRoute;
    pub const beginRetainedInteraction = begin.beginRetainedInteraction;
    pub const beginHomeRoute = begin.beginHomeRoute;
    pub const beginRoom2Event = begin.beginRoom2Event;
    pub const beginHomeStairs = begin.beginHomeStairs;
    pub const beginConstructedRoute = begin.beginConstructedRoute;
    pub const beginWorldExit = begin.beginWorldExit;

    pub const takeBattle = handoffs.takeBattle;
    pub const queuedBattle = handoffs.queuedBattle;
    pub const queuedGameplayRequest = handoffs.queuedGameplayRequest;
    pub const queuedFixedDice = handoffs.queuedFixedDice;
    pub const queuedItemOverload = handoffs.queuedItemOverload;
    pub const resumeItemOverload = handoffs.resumeItemOverload;
    pub const queuedPartySelect = handoffs.queuedPartySelect;
    pub const partySelectReservesSlot = handoffs.partySelectReservesSlot;
    pub const resumePartySelect = handoffs.resumePartySelect;
    pub const updateSelectorParty = handoffs.updateSelectorParty;
    pub const pendingFieldMusic = handoffs.pendingFieldMusic;
    pub const resumeFieldMusic = handoffs.resumeFieldMusic;
    pub const resumeFixedDice = handoffs.resumeFixedDice;
    pub const resumeBattleStory = handoffs.resumeBattleStory;
    pub const acknowledgeAudio = handoffs.acknowledgeAudio;

    pub const sourceTedAddRequest = host.sourceTedAddRequest;
    pub const pendingPartyChange = host.pendingPartyChange;
    pub const acknowledgePartyChange = host.acknowledgePartyChange;
    pub const acknowledgePartyLoad = host.acknowledgePartyLoad;
    pub const acknowledgeTedAdd = host.acknowledgeTedAdd;
    pub const pendingWheelSpin = host.pendingWheelSpin;
    pub const acknowledgeWheelSpin = host.acknowledgeWheelSpin;
    pub const pendingPartyEdit = host.pendingPartyEdit;
    pub const acknowledgePartyEdit = host.acknowledgePartyEdit;
    pub const sourceCueRequest = host.sourceCueRequest;
    pub const acknowledgeSourceCue = host.acknowledgeSourceCue;
    pub const proposeRoomTransition = host.proposeRoomTransition;
    pub const acknowledgeRoomTransition = host.acknowledgeRoomTransition;
    pub const acknowledgeWorldExit = host.acknowledgeWorldExit;
    pub const reconstruct = host.reconstruct;

    pub const validate = validation.validate;

    pub const tick = session.tick;
    pub const tickPad = session.tickPad;

    pub fn pendingPartySelectCommand(self: *const Session) ?runtime.Command {
        const instance = if (self.instance) |*value| value else return null;
        if (!instance.pendingPartySelect()) return null;
        return instance.pending.?.batch.effects[0];
    }
    pub fn resumeBattle(self: *Session, binding: Binding, state: *field.State, completed: fe.BattleRequest, outcome: fe.BattleOutcome) !void {
        state.progress.story.scenario = try self.resumeBattleStory(binding, state.progress.story.scenario, completed, outcome);
    }

    pub fn tickField(self: *Session, binding: Binding, state: *field.State, input: field.Input) !Result {
        self.sound_effect = null;
        const direction: u32 = switch (input.menu_direction orelse return self.tick(binding, state, input.action)) {
            .up => 0x1000,
            .down => 0x4000,
            else => 0,
        };
        return self.tickPad(binding, state, direction | @as(u32, if (input.action) 0x40 else 0), 0);
    }

    pub fn advanceWheelGraphics(self: *Session, binding: Binding, state: field.State) !void {
        if (!binding.content.hasWheelMotion()) return;
        const controls_wheel = controls: {
            for (binding.content.programs) |program| for (program.commands) |command|
                if (command.kind == .wheel_spin or command.kind == .wheel_turn) break :controls true;
            break :controls false;
        };
        if (!controls_wheel) return;
        const wheel = state.wheel_state orelse field.wheel.Room{};
        const actors = self.ordinary_actors orelse return;
        const camera = if (self.scripted_camera) |scripted| (if (scripted.absolute) scripted.scroll else self.heroTrackCamera(binding)) else self.heroTrackCamera(binding);
        var selected: ?usize = null;
        for (binding.room_actors, 0..) |art, index| {
            const scene_actor = art.scene_actor orelse continue;
            const slot = actors.slots[index] orelse continue;
            if (slot.phase != .active) continue;
            if (selected != null or scene_actor.character != 8) return error.UnqualifiedWheelActors;
            selected = index;
        }
        const index = selected orelse {
            self.wheel_graphics = null;
            return;
        };
        const clips = binding.room_actors[index].clips orelse return error.UnqualifiedWheelActors;
        const shadow = clips[field.wheel.shadow_variant].frames[field.wheel.shadow_frame];
        if (shadow.rect.w != field.wheel.shadow_sheet_size[0] or shadow.rect.h != field.wheel.shadow_sheet_size[1] or
            shadow.anchor_x != field.wheel.shadow_anchor[0] or shadow.anchor_y != field.wheel.shadow_anchor[1]) return error.UnqualifiedWheelActors;
        const avatar = actors.slots[index].?.avatar.?;
        const pose = avatar.drawPose();
        const ordinary_position: field.wheel.MapPoint = .{ .x = pose.x - camera.x, .y = pose.y - camera.y };
        if (self.wheel_graphics == null or self.wheel_graphics.?.actor != index)
            self.wheel_graphics = field.wheel.ActorGraphics.init(@intCast(index), ordinary_position);
        self.wheel_graphics.?.advance(wheel, ordinary_position, pose.y - avatar.motion.y);
    }

    pub fn fieldCamera(self: *const Session, state: field.State, package: field.Package) field.CameraOffset {
        const room = package.rooms[state.room];
        var position = state.position(package);
        if (self.hero_sprite) |hero| {
            position.x = @floatFromInt(hero.emitted_x);
            position.y = @floatFromInt(hero.emitted_y);
        }
        const source_scroll = field.sourceCameraScroll(room.width, room.height, self.hero.x + self.hero.offset_x, self.hero.y + self.hero.offset_y);
        var camera: field.CameraOffset = if (room.wheel_map != null)
            .{ .x = -@as(f32, @floatFromInt(source_scroll.x)), .y = -@as(f32, @floatFromInt(source_scroll.y)) }
        else
            field.cameraOffset(room.width, room.height, position.x, position.y);
        if (self.scripted_camera) |scripted| {
            if (scripted.absolute) return .{ .x = -@as(f32, @floatFromInt(scripted.scroll.x)), .y = -@as(f32, @floatFromInt(scripted.scroll.y)) };
            camera.x -= @floatFromInt(scripted.scroll.x);
            camera.y -= @floatFromInt(scripted.scroll.y);
        }
        return camera;
    }

    pub fn advanceFieldEffect(self: *Session, state: field.State, package: field.Package) !void {
        const effect = if (self.field_effect) |*value| value else return;
        if (effect.model.clock.callback == null) {
            self.field_effect = null;
            return;
        }
        const camera = self.fieldCamera(state, package);
        try effect.model.advance(.{
            .x = effect.position.x + @as(i32, @intFromFloat(camera.x)) + 8,
            .y = effect.position.y + @as(i32, @intFromFloat(camera.y)) - 8,
        });
    }

    pub fn takeSoundEffect(self: *Session) ?u16 {
        const sound = self.sound_effect;
        self.sound_effect = null;
        return sound;
    }

    /// Advance one ordinary player frame after source initialization. The input
    /// decision and camera are caller-owned facts; only the shared Avatar clock
    /// and actor state are advanced here.
    pub fn tickFree(self: *Session, binding: Binding, state: *field.State, direction: ?motion.Direction) !void {
        try self.validate(binding);
        if (!self.initialization_done or self.busy() or
            (self.instance != null and (self.instance.?.execution.active or self.instance.?.pending != null)) or
            self.ordinary_track != null or self.party_queue != null or self.text_job != null or
            self.boxes[0].phase != .closed or self.boxes[1].phase != .closed or self.fade_state.enabled or self.alignment != null) return error.FieldEventBusy;
        if (self.hero_sprite == null or self.hero.speed == 0) return error.InvalidFieldHeroAnimation;
        var next = self.*;
        var next_state = state.*;
        try next_state.progress.validate();
        const story = next_state.progress.story.scenario orelse return error.MissingSourceStoryState;
        try next.validateStory(&story);
        if (state.x != self.hero.x or state.y != self.hero.y or state.facing != self.facing) return error.FieldEventPositionMismatch;
        if (self.hero.x < 0 or self.hero.x > 2040 or self.hero.y < 0 or self.hero.y > 2040 or
            @mod(self.hero.x, 8) != 0 or @mod(self.hero.y, 8) != 0 or
            @abs(@as(i32, self.hero.offset_x)) > 8 or @abs(@as(i32, self.hero.offset_y)) > 8 or
            (self.hero.offset_x != 0 and self.hero.offset_y != 0)) return error.InvalidFieldActorState;
        const access = binding.movement orelse return error.MissingFieldMovementAccess;
        if (access.event_active) return error.FieldEventMovementActive;
        if (access.identity.len == 0 or access.identity.len > 128 or access.camera.x < 0 or access.camera.y < 0 or access.camera.x > 2040 or access.camera.y > 2040) return error.InvalidFieldMovementAccess;
        const input_owned = next.ordinaryReady();
        try next.startHeroDriver(binding);
        const was_moving = next.hero.moving();
        var started = false;
        if (input_owned and !was_moving) if (direction) |requested| {
            const allowed = access.decide("hero", next.hero, requested) orelse return error.UnsupportedFieldMovementDecision;
            const field_direction: field.Direction = switch (requested) {
                .down => .down,
                .up => .up,
                .left => .left,
                .right => .right,
            };
            next.facing = field_direction;
            const previous_primary = next.hero_sprite.?.variant;
            // Direction selection resets the sequence; the field draw owns its idle tick.
            next.hero_sprite.?.select(binding.hero_animation, requested, true);
            if (next.hero_sprite.?.variant != previous_primary) try next.resetHeroAux(binding, next.hero_sprite.?.variant);
            next.hero_flags = switch (requested) {
                .down => next.hero_flags & 2,
                .up => next.hero_flags | 1,
                .left => next.hero_flags & 1,
                .right => next.hero_flags | 2,
            };
            if (allowed) {
                const target: field.Point = switch (requested) {
                    .down => .{ .x = next.hero.x, .y = next.hero.y + 8 },
                    .up => .{ .x = next.hero.x, .y = next.hero.y - 8 },
                    .left => .{ .x = next.hero.x - 8, .y = next.hero.y },
                    .right => .{ .x = next.hero.x + 8, .y = next.hero.y },
                };
                const width = @as(i32, binding.population.coordinate_contract.room_half_width) * 8;
                const height = @as(i32, binding.population.coordinate_contract.room_half_height) * 8;
                if (target.x < 0 or target.y < 0 or target.x >= width or target.y >= height) return error.InvalidFieldMovementDecision;
                next.hero.step(requested);
                started = true;
            }
        };
        var avatar = next.heroAvatar();
        const primary_ticks = avatar.fieldTickAnimationCount(binding.hero_animation, true, .{
            .camera = access.camera,
            .allow_player_animation = (was_moving or started) and (next.hero_descriptor_state == null or next.hero_descriptor_state.?.tint_word == 0x80),
            .hero_speed = next.hero.speed,
        });
        try next.tickHeroAux(binding, primary_ticks);
        try next.drawHeroAux(binding);
        next.setHeroAvatar(avatar);
        next.hero_sprite.?.emitted_frame = avatar.pose.?.frame;
        next.hero_sprite.?.emitted_x = avatar.pose.?.x;
        next.hero_sprite.?.emitted_y = avatar.pose.?.y;
        if (next.ordinary_actors) |*actors| {
            const packet = binding.ordinary orelse return error.MissingFieldActorConstruction;
            try actors.tickCamera(packet, binding.animations, access.camera);
        }
        next_state.x = next.hero.x;
        next_state.y = next.hero.y;
        next_state.destination = .{ .x = next.hero.x, .y = next.hero.y };
        next_state.walking = next.hero.moving();
        next_state.facing = next.facing;
        next_state.scene_ticks +%= 1;
        if (was_moving or started) next_state.movement_updates +%= 1;
        try next.validate(binding);
        try next.validateStory(&story);
        try next_state.progress.validate();
        self.* = next;
        state.* = next_state;
    }
};
