const std = @import("std");
const field = @import("field");
const runtime = @import("event_runtime");
const records = @import("opening_records");
const ted_party_add = records.ted_party_add;
const field_records = records.field_records;
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
const dispatch_mod = @import("field_events_dispatch.zig");
const AudioRequest = fe.AudioRequest;
const HeroDescriptorState = fe.HeroDescriptorState;
const Actor = fe.Actor;
const Receipt = fe.Receipt;
const CompletedEvent = fe.CompletedEvent;
const Initialization = fe.Initialization;
const Reconstruction = dispatch_mod.Reconstruction;
const Blocker = dispatch_mod.Blocker;
const DialogueBox = fe.DialogueBox;
const TextJob = fe.TextJob;
const SpriteState = fe.SpriteState;
const PartyQueue = fe.PartyQueue;
const Session = fe.Session;

pub const StoredInstance = struct {
    schema: []const u8,
    content_id: []const u8,
    content_sha256: []const u8,
    program_id: []const u8,
    execution: runtime.Execution,
    effect_sequence: u64,
    pending: ?struct {
        batch: struct { id: u64, effects: []const runtime.Command },
        next: runtime.Execution,
        story_writes: []const runtime.StoryWrite,
    },
    pub fn from(instance: *const runtime.Instance) StoredInstance {
        return .{ .schema = instance.schema, .content_id = instance.content_id, .content_sha256 = instance.content_sha256, .program_id = instance.program_id, .execution = instance.execution, .effect_sequence = instance.effect_sequence, .pending = if (instance.pending) |*pending| .{ .batch = .{ .id = pending.batch.id, .effects = pending.batch.slice() }, .next = pending.next, .story_writes = pending.story_writes[0..pending.story_write_count] } else null };
    }
    pub fn restore(self: StoredInstance) !runtime.Instance {
        var instance: runtime.Instance = .{ .schema = self.schema, .content_id = self.content_id, .content_sha256 = self.content_sha256, .program_id = self.program_id, .execution = self.execution, .effect_sequence = self.effect_sequence };
        if (self.pending) |pending| {
            if (pending.batch.effects.len == 0 or pending.batch.effects.len > runtime.max_batch_effects or pending.story_writes.len > 4) return error.InvalidEventBatch;
            var restored: runtime.PendingBatch = .{ .batch = .{ .id = pending.batch.id, .effect_count = @intCast(pending.batch.effects.len) }, .next = pending.next, .story_write_count = @intCast(pending.story_writes.len) };
            @memcpy(restored.batch.effects[0..pending.batch.effects.len], pending.batch.effects);
            @memcpy(restored.story_writes[0..pending.story_writes.len], pending.story_writes);
            instance.pending = restored;
        }
        return instance;
    }
};
pub const StoredSession = struct {
    schema: []const u8,
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
    ordinary_actors: ?ordinary.Stored = null,
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
    scripted_camera: ?@import("field_events_state.zig").ScriptedCamera = null,
    wheel_graphics: ?field.wheel.ActorGraphics = null,
    field_effect: ?@import("field_events_state.zig").FieldEffectState = null,
    camera_push: ?@import("field_events_state.zig").CameraPushState = null,
    delay_remaining: u16 = 0,
    pending_battle: ?[]const u8 = null,
    fade_state: fade.State = .{},
    audio_identity: []const u8 = "",
    audio_cached_command: ?u16 = null,
    area_command: ?u16 = null,
    audio_request: ?AudioRequest = null,
    inside: bool,
    instance: ?StoredInstance,
    receipt: ?Receipt,
    initialization_done: bool,
    next_initialization: u16,
    initializations: [3]?Initialization,
    initialization_count: u8,
    actors: [64]?Actor,
    actor_count: u8,
    area_party: [6]u8,
    source_party: [6]u8,
    active_party_count: u8,
    hero: motion.ActorMotion,
    hero_sprite: ?SpriteState = null,
    alignment: ?motion.Alignment,
    facing: field.Direction,
    party_queue: ?PartyQueue,
    boxes: [2]DialogueBox,
    text_job: ?TextJob,
    text_speed: TextSpeed,
    blocker: ?Blocker,
    pub fn jsonStringify(self: StoredSession, writer: anytype) !void {
        try writer.beginObject();
        inline for (comptime std.meta.fieldNames(StoredSession)) |name| {
            if (comptime std.mem.eql(u8, name, "construction_ground_identity")) {
                if (std.mem.eql(u8, self.schema, "suikoden-field-event/16") or std.mem.eql(u8, self.schema, "suikoden-field-event/17") or std.mem.eql(u8, self.schema, "suikoden-field-event/18") or std.mem.eql(u8, self.schema, "suikoden-field-event/19") or std.mem.eql(u8, self.schema, "suikoden-field-event/20") or std.mem.eql(u8, self.schema, "suikoden-field-event/21") or std.mem.eql(u8, self.schema, "suikoden-field-event/22")) {
                    try writer.objectField(name);
                    try writer.write(self.construction_ground_identity);
                }
            } else if (comptime std.mem.eql(u8, name, "camera_push")) {
                if (self.camera_push) |push| {
                    try writer.objectField(name);
                    try writer.write(push);
                }
            } else if (comptime std.mem.eql(u8, name, "field_effect")) {
                if (self.field_effect) |effect| {
                    try writer.objectField(name);
                    try writer.write(effect);
                }
            } else if (comptime std.mem.eql(u8, name, "scripted_camera")) {
                if (self.scripted_camera) |camera| {
                    try writer.objectField(name);
                    try writer.write(camera);
                }
            } else if (comptime std.mem.eql(u8, name, "completed_event")) {
                if (std.mem.eql(u8, self.schema, "suikoden-field-event/17")) {
                    try writer.objectField(name);
                    try writer.write(self.completed_event);
                }
            } else if (comptime std.mem.eql(u8, name, "reconstruction")) {
                if (std.mem.eql(u8, self.schema, "suikoden-field-event/18")) {
                    try writer.objectField(name);
                    try writer.write(self.reconstruction);
                }
            } else if (comptime std.mem.eql(u8, name, "position_history")) {
                if (std.mem.eql(u8, self.schema, "suikoden-field-event/15") or std.mem.eql(u8, self.schema, "suikoden-field-event/17")) {
                    try writer.objectField(name);
                    try writer.write(self.position_history);
                }
            } else if (comptime std.mem.eql(u8, name, "audio_identity") or std.mem.eql(u8, name, "audio_cached_command") or std.mem.eql(u8, name, "area_command") or std.mem.eql(u8, name, "audio_request")) {
                if (std.mem.eql(u8, self.schema, "suikoden-field-event/14")) {
                    try writer.objectField(name);
                    try writer.write(@field(self, name));
                }
            } else if (comptime std.mem.eql(u8, name, "wheel_graphics")) {
                if (self.wheel_graphics != null) {
                    try writer.objectField(name);
                    try writer.write(self.wheel_graphics);
                }
            } else if (comptime std.mem.eql(u8, name, "room2_descriptor")) {
                if (std.mem.eql(u8, self.schema, "suikoden-field-event/22")) {
                    try writer.objectField(name);
                    try writer.write(self.room2_descriptor);
                }
            } else if (comptime std.mem.eql(u8, name, "retained_selection")) {
                if (std.mem.eql(u8, self.schema, "suikoden-field-event/21") or std.mem.eql(u8, self.schema, "suikoden-field-event/22")) {
                    try writer.objectField(name);
                    try writer.write(self.retained_selection);
                }
            } else {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
    pub fn restore(self: StoredSession) !Session {
        var result: Session = undefined;
        inline for (comptime std.meta.fieldNames(Session)) |name| {
            if (comptime std.mem.eql(u8, name, "instance")) {
                result.instance = if (self.instance) |instance| try instance.restore() else null;
            } else if (comptime std.mem.eql(u8, name, "ordinary_actors")) {
                result.ordinary_actors = if (self.ordinary_actors) |actors| try actors.restore() else null;
            } else if (comptime std.mem.eql(u8, name, "sound_effect")) {
                result.sound_effect = null;
            } else if (comptime std.mem.eql(u8, name, "inn_payment_refused")) {
                result.inn_payment_refused = false;
            } else @field(result, name) = @field(self, name);
        }
        return result;
    }
};
