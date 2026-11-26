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

pub const DialogueData = struct {
    pub const room_portrait_schema = "suikoden-field-dialogue/8";
    pub const party_schema = "suikoden-field-dialogue/9";
    pub const interaction_schema = "suikoden-field-dialogue/10";
    const Prefix = struct { program: []const u8, command: u16, box: u8, text: ?u16 = null, absent_character: ?u8 = null, image: ?u8 = null };

    schema: []const u8,
    content_sha256: []const u8,
    anchors: []const struct { program: []const u8, command: u16, box: u8, follower: ?u8 = null, actor: ?[]const u8 = null, point: ?field.Point = null, interaction_actor: ?bool = null },
    texts: []const motion.Text,
    prefixes: []const Prefix,
    images: []const struct { id: []const u8, character: u8, width: u8, height: u8, plane_sha256: []const u8, palette_sha256: []const u8, domain: enum { active_party, area_custom, room } = .active_party, resource: ?[]const u8 = null, atlas_rect: ?field.Rect = null },
    descriptor_changes: []const struct { program: []const u8, command: u16, follower: u8, direction: motion.Direction },
    configuration: [3]struct { normal_pace: u8, pressed_pace: u8 },
    default_speed: TextSpeed,
    allow_pages: bool = false,
    allow_substitution: bool = false,

    pub fn usesPartySchema(self: DialogueData) bool {
        return std.mem.eql(u8, self.schema, party_schema) or std.mem.eql(u8, self.schema, interaction_schema);
    }

    pub fn hasFollowerBindings(self: DialogueData) bool {
        if (self.descriptor_changes.len != 0) return true;
        for (self.anchors) |anchor| if (anchor.follower != null) return true;
        return false;
    }

    pub fn prefixFor(self: DialogueData, program: []const u8, command: usize) ?Prefix {
        for (self.prefixes) |entry| if (entry.command == command and std.mem.eql(u8, entry.program, program)) return entry;
        return null;
    }

    pub fn validate(self: DialogueData, content: runtime.Content) !void {
        if (std.mem.eql(u8, self.schema, interaction_schema) and !content.hasActorOwners()) return error.InvalidFieldDialogue;
        const party = self.usesPartySchema();
        if (party and !content.hasPartyScene()) return error.InvalidFieldDialogue;
        const room_portraits = party or std.mem.eql(u8, self.schema, room_portrait_schema);
        const room_anchors = room_portraits or std.mem.eql(u8, self.schema, "suikoden-field-dialogue/7");
        const extended = room_anchors or std.mem.eql(u8, self.schema, "suikoden-field-dialogue/6");
        if ((!extended and !std.mem.eql(u8, self.schema, "suikoden-field-dialogue/5")) or self.content_sha256.len != 64 or self.anchors.len > 1024 or self.texts.len > 1024 or self.prefixes.len > 1024 or self.images.len > 64 or self.descriptor_changes.len > 64) return error.InvalidFieldDialogue;
        if (!extended and (self.allow_pages or self.allow_substitution)) return error.InvalidFieldDialogue;
        for (self.configuration) |entry| if (entry.normal_pace == 0 or entry.normal_pace > 5 or entry.pressed_pace > 2) return error.InvalidFieldDialogue;
        for (self.anchors) |anchor| {
            const program = content.program(anchor.program) orelse return error.InvalidFieldDialogue;
            const anchor_count = @as(u8, @intFromBool(anchor.follower != null)) + @as(u8, @intFromBool(anchor.actor != null)) + @as(u8, @intFromBool(anchor.point != null)) + @as(u8, @intFromBool(anchor.interaction_actor != null));
            if (anchor.interaction_actor) |enabled| if (!enabled or !std.mem.eql(u8, self.schema, interaction_schema) or (program.owner_actors == null and program.owner_actor == null)) return error.InvalidFieldDialogue;
            if (anchor.command >= program.commands.len or anchor.box > 1 or anchor_count != 1 or (anchor.follower != null and anchor.follower.? > @as(u8, if (party) 4 else 1)) or program.commands[anchor.command].kind != .open_box or program.commands[anchor.command].box != anchor.box) return error.InvalidFieldDialogue;
            if (party) if (anchor.follower) |follower| {
                const command = program.commands[anchor.command];
                const index = runtime.partyActorIndex(command.actor orelse return error.InvalidFieldDialogue) orelse return error.InvalidFieldDialogue;
                if (!content.hasPartyScene() or index != follower) return error.InvalidFieldDialogue;
            };
            if (anchor.point) |point| {
                if (!room_anchors or point.x < 0 or point.x > 2040 or point.y < 0 or point.y > 2040 or @mod(point.x, 8) != 0 or @mod(point.y, 8) != 0 or program.commands[anchor.command].actor != null) return error.InvalidFieldDialogue;
            }
            if (anchor.actor) |id| {
                if (!extended) return error.InvalidFieldDialogue;
                const command = program.commands[anchor.command];
                if (command.actor) |expected| {
                    if (!std.mem.eql(u8, id, expected)) return error.InvalidFieldDialogue;
                } else if (command.layout == null or command.layout.? >= 64) return error.InvalidFieldDialogue;
            }
        }
        for (self.prefixes) |prefix| {
            const program = content.program(prefix.program) orelse return error.InvalidFieldDialogue;
            if (prefix.command >= program.commands.len or prefix.box > 1) return error.InvalidFieldDialogue;
            const command = program.commands[prefix.command];
            if ((command.kind != .start_or_wait_dialogue and command.kind != .speaker) or command.box != prefix.box) return error.InvalidFieldDialogue;
            if (prefix.text) |text| {
                if (text >= self.texts.len) return error.InvalidFieldDialogue;
                for (self.texts[text].tokens) |token| if (token.kind == .pace) return error.InvalidFieldDialogue;
            } else if (!room_portraits or command.kind != .start_or_wait_dialogue or prefix.image == null or command.wait != null) return error.InvalidFieldDialogue;
            if (prefix.image) |image| {
                if (image >= self.images.len or prefix.absent_character != null) return error.InvalidFieldDialogue;
                if (command.kind == .speaker and command.image != self.images[image].character) return error.InvalidFieldDialogue;
            } else if (prefix.absent_character == null) return error.InvalidFieldDialogue;
        }
        for (self.images) |image| {
            if (image.width != 64 or image.height != 64 or image.plane_sha256.len != 64 or image.palette_sha256.len != 64 or (!extended and image.domain != .active_party)) return error.InvalidFieldDialogue;
            if (image.atlas_rect) |rect| {
                if (!room_portraits or image.domain == .area_custom or image.resource != null or rect.x < 0 or rect.y < 0 or rect.w != 64 or rect.h != 64) return error.InvalidFieldDialogue;
            } else if (image.domain == .room) return error.InvalidFieldDialogue;
        }
        for (self.texts) |text| for (text.tokens) |token| {
            if (token.kind == .player_name and !self.allow_substitution) return error.UnsupportedFieldTextSubstitution;
            if (token.kind == .page and !self.allow_pages) return error.UnsupportedFieldTextSubstitution;
            switch (token.kind) {
                .glyph => if (token.text == null or token.text.?.len != 1 or token.value != null) return error.InvalidFieldDialogue,
                .newline, .page, .player_name => if (token.text != null or token.value != null) return error.InvalidFieldDialogue,
                .countdown, .pace => if (token.value == null or token.text != null) return error.InvalidFieldDialogue,
            }
        };
        for (self.descriptor_changes) |change| {
            const program = content.program(change.program) orelse return error.InvalidFieldDialogue;
            if (change.command >= program.commands.len or change.follower > 1 or program.commands[change.command].kind != .descriptor_flags) return error.InvalidFieldDialogue;
        }
    }
};
pub const DialogueBox = struct {
    phase: @FieldType(motion.Box, "phase") = .closed,
    transition: u8 = 0,
    anchor: ?field.Point = null,
    fixed: ?field.Rect = null,
    speaker: ?u16 = null,
    image: ?u8 = null,
    pub fn jsonStringify(self: DialogueBox, writer: anytype) !void {
        try writer.beginObject();
        inline for (comptime std.meta.fieldNames(DialogueBox)) |name| {
            const emit = if (comptime std.mem.eql(u8, name, "fixed")) self.fixed != null else true;
            if (emit) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
    pub fn changing(self: DialogueBox) bool {
        return self.phase == .opening or self.phase == .closing;
    }
    pub fn tick(self: *DialogueBox) void {
        var box: motion.Box = .{ .phase = self.phase, .transition = self.transition };
        box.tickTransition();
        self.phase = box.phase;
        self.transition = box.transition;
        if (self.phase == .closed) {
            self.anchor = null;
            self.fixed = null;
            self.speaker = null;
            self.image = null;
        }
    }
};
pub const TextJob = struct {
    box: u8,
    text: u16,
    state: motion.TextState,
    kind: enum { prefix, body_staged, body, body_done } = .prefix,
    current_pace: u8 = 0,

    pub fn hasChoiceRows(self: *const TextJob, slot: u8) bool {
        if (self.box != slot or self.kind != .body_done) return false;
        var iter = std.mem.splitScalar(u8, self.state.visible(), '\n');
        var count: u8 = 0;
        while (iter.next()) |line| {
            if (line.len == 0) return false;
            count +|= 1;
        }
        return count >= 2 and count <= 4;
    }
};

pub const QueueData = struct {
    pub const room_schema = "suikoden-field-party-queue/2";
    schema: []const u8,
    content_sha256: []const u8,
    anchor: field.Point,
    graphics: ?GraphicsData = null,
    tracks: []const motion.Track,
    pub fn isRoom(self: QueueData) bool {
        return std.mem.eql(u8, self.schema, room_schema);
    }
    pub fn validate(self: QueueData) !void {
        if (self.graphics) |graphics| try graphics.validate();
        if ((!self.isRoom() and !std.mem.eql(u8, self.schema, "suikoden-field-party-queue/1")) or self.content_sha256.len != 64 or self.tracks.len != 40) return error.InvalidFieldPartyQueue;
        if (self.isRoom()) {
            if (self.anchor.x < 24 or self.anchor.x > 2016 or self.anchor.y < 24 or self.anchor.y > 2016 or @mod(self.anchor.x, 8) != 0 or @mod(self.anchor.y, 8) != 0) return error.InvalidFieldPartyQueue;
        } else if (self.anchor.x != 216 or self.anchor.y != 200) return error.InvalidFieldPartyQueue;
        for (self.tracks) |track| {
            for (track.commands) |command| if (command.kind == .hold or command.kind == .hop) return error.InvalidFieldPartyQueue;
            _ = try motion.TrackState.start(track, 2);
            if (self.isRoom()) {
                var x: i32 = 0;
                var y: i32 = 0;
                for (track.commands) |command| switch (command.kind) {
                    .move => {
                        if (command.cells.? > 3) return error.InvalidFieldPartyQueue;
                        const distance = field.halfCellsToPixels(command.cells.?);
                        switch (command.direction.?) {
                            .left => x -= distance,
                            .right => x += distance,
                            .up => y -= distance,
                            .down => y += distance,
                        }
                        if (x < -24 or x > 24 or y < -24 or y > 24) return error.InvalidFieldPartyQueue;
                    },
                    .finish => {},
                    else => return error.InvalidFieldPartyQueue,
                };
            }
        }
    }
};
pub const GraphicsResource = struct { character: u8, id: []const u8, clips: [4]motion.AnimationClip };
pub const GraphicsData = struct {
    schema: []const u8,
    resources: []const GraphicsResource,
    content_sha256: []const u8,
    pub fn resource(self: GraphicsData, character: u8) ?GraphicsResource {
        for (self.resources) |entry| if (entry.character == character) return entry;
        return null;
    }
    pub fn validate(self: GraphicsData) !void {
        const library = std.mem.eql(u8, self.schema, "suikoden-field-party-graphics/3");
        const room = library or std.mem.eql(u8, self.schema, "suikoden-field-party-graphics/2");
        if ((!room and !std.mem.eql(u8, self.schema, "suikoden-field-party-graphics/1")) or self.resources.len == 0 or self.resources.len > (if (library) @as(usize, 255) else 5) or (!room and self.resources.len != 4) or self.content_sha256.len != 64) return error.InvalidFieldPartyGraphics;
        for (self.resources, 0..) |entry, i| {
            if (room) {
                if (entry.character == 255 or entry.id.len == 0 or entry.id.len > 64) return error.InvalidFieldPartyGraphics;
                for (entry.id) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.InvalidFieldPartyGraphics;
            } else {
                const name = switch (entry.character) {
                    2 => "gremio",
                    6 => "pahn",
                    35 => "viktor",
                    38 => "yam_koo",
                    else => return error.InvalidFieldPartyGraphics,
                };
                if (!std.mem.eql(u8, entry.id, name)) return error.InvalidFieldPartyGraphics;
            }
            for (self.resources[0..i]) |prior| if (entry.character == prior.character or std.mem.eql(u8, entry.id, prior.id)) return error.InvalidFieldPartyGraphics;
            for (entry.clips) |clip| {
                if (clip.ticks.len != 4 or clip.bounds.len != 4 or clip.flags != 3) return error.InvalidFieldPartyGraphics;
                for (clip.ticks, clip.bounds) |ticks, bounds| if (ticks == 0 or ticks > 256 or bounds.width == 0 or bounds.height == 0 or bounds.width > 128 or bounds.height > 128) return error.InvalidFieldPartyGraphics;
            }
        }
    }
};
pub const SpriteState = struct {
    variant: u2 = 0,
    animation: motion.SpriteAnimation,
    emitted_frame: u8 = 0,
    emitted_x: i32 = 0,
    emitted_y: i32 = 0,
    pub fn select(self: *SpriteState, graphics: anytype, direction: motion.Direction, moving: bool) void {
        const variant = graphicVariant(direction);
        if (variant == self.variant) return;
        self.variant = variant;
        self.animation = motion.SpriteAnimation.start(graphics.clips[variant]);
        if (!moving and self.animation.frame != 1 and self.animation.frame != 3) self.animation.tick(graphics.clips[variant]);
    }
};
pub fn graphicVariant(direction: motion.Direction) u2 {
    return switch (direction) {
        .down => 0,
        .up => 1,
        .left => 2,
        .right => 3,
    };
}
pub const PartyFollower = struct {
    character: u8,
    position: motion.ActorMotion,
    flags: u2 = 0,
    facing: motion.Direction = .down,
    track: motion.TrackState,
    custom_track: ?u8 = null,
    sprite: ?SpriteState = null,
    pub fn jsonStringify(self: PartyFollower, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(PartyFollower).@"struct".field_names) |name| {
            const value = @field(self, name);
            const include = if (comptime std.mem.eql(u8, name, "custom_track")) value != null else if (comptime @typeInfo(@TypeOf(value)) == .optional) value != null or writer.options.emit_null_optional_fields else true;
            if (include) {
                try writer.objectField(name);
                try writer.write(value);
            }
        }
        try writer.endObject();
    }
    pub fn face(self: *PartyFollower, direction: motion.Direction) void {
        self.flags = switch (direction) {
            .down => self.flags & 2,
            .up => self.flags | 1,
            .left => self.flags & 1,
            .right => self.flags | 2,
        };
        self.facing = direction;
    }
    pub fn selectFacing(self: *PartyFollower, graphics: ?GraphicsData, direction: motion.Direction, moving: bool) !void {
        self.face(direction);
        if (self.sprite) |*sprite| {
            const resources = graphics orelse return error.InvalidFieldPartyGraphics;
            sprite.select(resources.resource(self.character) orelse return error.InvalidFieldPartyGraphics, direction, moving);
        }
    }
};
pub const PartyQueue = struct {
    phase: enum { spread, returning } = .spread,
    facing: field.Direction,
    count: u8,
    followers: [5]?PartyFollower = @splat(null),

    pub fn trackIndex(self: PartyQueue, index: usize) usize {
        return @as(usize, if (self.phase == .spread) 0 else 20) + @as(usize, @backingInt(self.facing)) * 5 + index;
    }
    pub fn active(self: PartyQueue) u8 {
        var result: u8 = 0;
        for (self.followers[0..self.count]) |follower| result += @intFromBool(follower.?.track.active);
        return result;
    }
    pub fn tick(self: *PartyQueue, packet: QueueData) !void {
        return self.tickTracks(packet, null);
    }
    pub fn startTrack(self: *PartyQueue, content: runtime.Content, id: []const u8) !bool {
        if (!content.hasPartyTracks()) return error.UnsupportedFieldPartyQueue;
        const index = for (content.tracks, 0..) |track, index| {
            if (std.mem.eql(u8, track.id, id)) break index;
        } else return error.UnknownEventTrack;
        const source = content.tracks[index];
        const follower_index = runtime.partyActorIndex(source.actor) orelse return error.UnknownFieldActor;
        if (follower_index >= self.count) return false;
        const follower = &self.followers[follower_index].?;
        if (follower.track.active) return false;
        var commands: [64]motion.TrackCommand = undefined;
        const previous_motion = follower.position.speed;
        follower.track = try motion.TrackState.start(try ordinary.TrackJob.trackData(source, &commands), previous_motion);
        follower.custom_track = @intCast(index);
        follower.position.offset_x = 0;
        follower.position.offset_y = 0;
        follower.position.speed = 2;
        std.debug.assert(follower.track.active and follower.track.cursor == 0 and follower.track.motion == 2 and follower.track.saved_motion == previous_motion and !follower.position.moving());
        return true;
    }
    pub fn tickTracks(self: *PartyQueue, packet: QueueData, content: ?runtime.Content) !void {
        for (self.followers[0..self.count], 0..) |*slot, index| {
            const follower = &slot.*.?;
            if (follower.sprite != null and (packet.graphics == null or packet.graphics.?.resource(follower.character) == null)) return error.InvalidFieldPartyGraphics;
            var commands: [64]motion.TrackCommand = undefined;
            const track = if (follower.custom_track) |custom| blk: {
                const source = content orelse return error.MissingFieldPartyTrack;
                if (!packet.isRoom() or !source.hasPartyTracks() or custom >= source.tracks.len) return error.InvalidFieldPartyQueue;
                const target = runtime.partyActorIndex(source.tracks[custom].actor) orelse return error.InvalidFieldPartyQueue;
                if (target != index) return error.InvalidFieldPartyQueue;
                break :blk try ordinary.TrackJob.trackData(source.tracks[custom], &commands);
            } else packet.tracks[self.trackIndex(index)];
            if (try follower.track.tick(track, follower.position.moving())) |effect| {
                if (effect.kind == .vertical_offset) {
                    follower.position.offset_y = effect.offset_y;
                } else {
                    if (effect.kind != .advance) {
                        try follower.selectFacing(packet.graphics, effect.direction, effect.kind != .face);
                    }
                    if (effect.kind != .face) follower.position.step(effect.direction);
                }
            }
            follower.position.speed = follower.track.motion;
            if (follower.sprite) |*sprite| {
                sprite.emitted_frame = sprite.animation.frame;
                sprite.emitted_x = follower.position.x + follower.position.offset_x;
                sprite.emitted_y = follower.position.y + follower.position.offset_y;
                if (follower.position.moving() or (sprite.animation.frame != 1 and sprite.animation.frame != 3)) sprite.animation.tick(packet.graphics.?.resource(follower.character).?.clips[sprite.variant]);
            }
            follower.position.tick();
        }
    }
};

// Persist only populated commands; the debug parser otherwise copies deeply nested 64-command arrays.
