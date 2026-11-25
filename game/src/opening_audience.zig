const std = @import("std");
const validation = @import("validation");
pub const json = @import("audience_data").json;
pub const Direction = enum {
    up,
    right,
    down,
    left,
    fn opposite(self: Direction) Direction {
        return switch (self) {
            .up => .down,
            .down => .up,
            .left => .right,
            .right => .left,
        };
    }
};
pub const TrackCommand = struct {
    kind: enum { move, advance, set_motion, finish, hold, hop },
    direction: ?Direction = null,
    cells: ?u8 = null,
    motion: ?u8 = null,
    updates: ?u16 = null,

    pub fn jsonStringify(self: TrackCommand, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(TrackCommand).@"struct".field_names) |name| {
            const include = if (comptime std.mem.eql(u8, name, "updates")) self.updates != null else true;
            if (include) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
};
pub const Track = struct { id: []const u8, actor: []const u8, commands: []const TrackCommand };
pub const Token = struct { kind: enum { glyph, newline, page, pace, countdown, player_name }, text: ?[]const u8 = null, value: ?u8 = null };
pub const Text = struct { id: []const u8, tokens: []const Token };
pub const Command = struct {
    kind: enum { align_hero, actor_transition, open_box, speaker, text, wait_confirm, close_box, queue_track, wait_tracks, delay, cue, pan, next_variant, previous_variant, wait_variant, set_variant, actor_motion, actor_x, actor_y, release_actor, create_double, choice, jump, branch_choice, label, free_double, follow_character, complete_audience, wait_boxes, finish },
    actor: ?[]const u8 = null,
    character: ?[]const u8 = null,
    box: ?u8 = null,
    image: ?u8 = null,
    name: ?[]const u8 = null,
    text: ?[]const u8 = null,
    track: ?[]const u8 = null,
    transition: ?u2 = null,
    x: ?i32 = null,
    y: ?i32 = null,
    updates: ?u16 = null,
    cue: ?u16 = null,
    dx: ?i32 = null,
    dy: ?i32 = null,
    variant: ?u8 = null,
    value: ?u8 = null,
    options: ?u8 = null,
    target: ?u16 = null,
};
pub const Actor = struct { id: []const u8, graphic: []const u8, x: i32, y: i32, motion: u8, variant: u8, attached: bool, auto_animate: bool = false };
pub const Bounds = struct { width: u8, height: u8 };
pub const AnimationClip = struct { flags: u8, ticks: []const u16, bounds: []const Bounds = &.{} };
pub const Animation = struct { graphic: []const u8, clips: [4]AnimationClip };
pub const Content = struct {
    animations: []const Animation,
    default_text_pace: u8,
    nominal_updates_per_second: u16,
    actors: []const Actor,
    schema: []const u8,
    id: []const u8,
    commands: []const Command,
    tracks: []const Track,
    texts: []const Text,

    pub fn animation(self: Content, graphic: []const u8) ?Animation {
        for (self.animations) |entry| if (std.mem.eql(u8, entry.graphic, graphic)) return entry;
        return null;
    }
    pub fn track(self: Content, id: []const u8) ?Track {
        for (self.tracks) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }
    pub fn text(self: Content, id: []const u8) ?Text {
        for (self.texts) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }
    pub fn validate(self: Content) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-opening-audience/2")) return error.UnsupportedAudienceSchema;
        if (!std.mem.eql(u8, self.id, "palace_audience") or self.commands.len == 0 or self.commands.len > 512 or self.tracks.len > 64 or self.texts.len > 64) return error.InvalidAudience;
        if (self.nominal_updates_per_second != 60) return error.UnsupportedOpeningCadence;
        if (self.animations.len == 0 or self.animations.len > 32) return error.InvalidAudienceAnimation;
        for (self.animations, 0..) |entry, i| {
            try validId(entry.graphic);
            for (self.animations[0..i]) |other| if (std.mem.eql(u8, entry.graphic, other.graphic)) return error.InvalidAudienceAnimation;
            for (entry.clips) |clip| {
                if (clip.ticks.len == 0 or clip.ticks.len > 64) return error.InvalidAudienceAnimation;
                if (clip.bounds.len != clip.ticks.len) return error.InvalidAudienceAnimation;
                for (clip.ticks) |ticks| if (ticks == 0 or ticks > 256) return error.InvalidAudienceAnimation;
            }
        }
        if (self.animation("hero") == null) return error.InvalidAudienceAnimation;
        if (self.actors.len == 0 or self.actors.len > 64) return error.InvalidAudienceActors;
        for (self.actors, 0..) |actor, i| {
            try validId(actor.id);
            try validId(actor.graphic);
            if (self.animation(actor.graphic) == null) return error.InvalidAudienceAnimation;
            if (actor.x < 0 or actor.x > 2040 or actor.y < 0 or actor.y > 2040 or actor.variant > 3) return error.InvalidAudienceActor;
            for (self.actors[0..i]) |other| if (std.mem.eql(u8, actor.id, other.id)) return error.InvalidAudienceActors;
        }
        for (self.tracks, 0..) |entry, i| {
            try validId(entry.id);
            try validId(entry.actor);
            for (self.tracks[0..i]) |other| if (std.mem.eql(u8, other.id, entry.id)) return error.DuplicateAudienceTrack;
            try validateTrack(entry);
            for (entry.commands) |command| if (command.kind == .hold or command.kind == .hop) return error.UnsupportedAudienceTrack;
        }
        for (self.texts, 0..) |entry, i| {
            try validId(entry.id);
            if (entry.tokens.len == 0 or entry.tokens.len > 4096) return error.InvalidAudienceText;
            for (self.texts[0..i]) |other| if (std.mem.eql(u8, other.id, entry.id)) return error.DuplicateAudienceText;
            for (entry.tokens) |token| {
                if ((token.kind == .glyph) != (token.text != null) or (token.kind == .pace or token.kind == .countdown) != (token.value != null)) return error.InvalidAudienceToken;
                if (token.text) |glyph| if (glyph.len > 4 or !std.unicode.utf8ValidateSlice(glyph)) return error.InvalidAudienceToken;
            }
        }
        for (self.commands, 0..) |command, i| {
            if (command.actor) |id| try validId(id);
            if (command.character) |id| try validId(id);
            if (command.updates) |updates| if (updates == 0 or updates > 4096) return error.InvalidAudienceDuration;
            if (command.name) |name| if (name.len > 64 or !std.unicode.utf8ValidateSlice(name)) return error.InvalidAudienceName;
            if (command.box) |box| if (box > 1) return error.InvalidAudienceBox;
            if (command.text) |id| if (self.text(id) == null) return error.UnknownAudienceText;
            if (command.track) |id| if (self.track(id) == null) return error.UnknownAudienceTrack;
            if (command.target) |target| if (target >= self.commands.len) return error.InvalidAudienceBranch;
            if ((command.kind == .finish) != (i == self.commands.len - 1)) return error.InvalidAudienceEnd;
            const valid = switch (command.kind) {
                .align_hero => command.x != null and command.y != null,
                .actor_transition => command.actor != null and command.transition != null,
                .open_box => command.box != null and command.actor != null,
                .speaker => command.box != null and command.image != null and command.name != null,
                .text => command.box != null and command.text != null,
                .close_box => command.box != null,
                .queue_track => command.track != null,
                .delay => command.updates != null,
                .cue => command.cue != null,
                .pan => command.dx != null and command.dy != null and command.updates != null,
                .next_variant, .previous_variant, .wait_variant, .release_actor => command.actor != null,
                .set_variant => command.actor != null and command.variant != null,
                .actor_motion, .actor_x, .actor_y => command.actor != null and command.value != null,
                .create_double => command.actor != null and command.character != null and command.x != null and command.y != null,
                .choice => command.box != null and command.options == 2,
                .jump, .branch_choice => command.target != null,
                .follow_character => command.character != null,
                else => true,
            };
            if (!valid) return error.InvalidAudienceCommand;
        }
    }
};
fn validId(id: []const u8) !void {
    if (!validation.isAsciiId(id, 64, "_")) return error.InvalidAudienceId;
}
fn validateTrack(entry: Track) !void {
    if (entry.commands.len == 0 or entry.commands.len > 64) return error.InvalidAudienceTrack;
    var has_direction = false;
    for (entry.commands, 0..) |command, i| {
        if ((command.kind == .finish) != (i == entry.commands.len - 1)) return error.InvalidAudienceTrack;
        if ((command.kind == .move) != (command.direction != null) or (command.kind == .move or command.kind == .advance) != (command.cells != null) or (command.kind == .set_motion) != (command.motion != null)) return error.InvalidAudienceTrack;
        if (command.kind == .move) has_direction = true;
        if (command.kind == .advance and (!has_direction or command.cells.? == 0)) return error.InvalidAudienceTrack;
        if (command.motion == 255) return error.UnsupportedAudienceMotion;
        if ((command.kind == .hold) != (command.updates != null)) return error.InvalidAudienceTrack;
        if (command.updates) |updates| if (updates == 0 or updates > 1275 or updates % 5 != 0) return error.InvalidAudienceTrack;
    }
}
pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Content) {
    if (bytes.len > 512 * 1024) return error.AudienceTooLarge;
    const parsed = try std.json.parseFromSlice(Content, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

pub const Effect = struct { kind: enum { move, advance, face, vertical_offset }, actor: []const u8, direction: Direction, offset_y: i16 = 0 };
pub const hop_offsets = [_]i16{ -2, -4, -6, -8, -6, -4, -2, 0 };
pub const ActorMotion = struct {
    x: i32,
    y: i32,
    offset_x: i16 = 0,
    offset_y: i16 = 0,
    speed: u8,

    pub fn moving(self: ActorMotion) bool {
        return self.offset_x != 0 or self.offset_y != 0;
    }
    pub fn step(self: *ActorMotion, direction: Direction) void {
        const dx: i16 = switch (direction) {
            .left => -8,
            .right => 8,
            else => 0,
        };
        const dy: i16 = switch (direction) {
            .up => -8,
            .down => 8,
            else => 0,
        };
        self.x = @mod(self.x + dx, 2048);
        self.y = @mod(self.y + dy, 2048);
        self.offset_x = -dx;
        self.offset_y = -dy;
    }
    pub fn tick(self: *ActorMotion) void {
        self.offset_x = settle(self.offset_x, self.speed);
        self.offset_y = settle(self.offset_y, self.speed);
    }
    fn settle(offset: i16, speed: u8) i16 {
        return if (offset > 0) @max(0, offset - speed) else @min(0, offset + speed);
    }
};
pub const SpriteAnimation = struct {
    frame: u8 = 0,
    remaining: u16,
    active: bool,
    repeating: bool,

    pub fn start(clip: AnimationClip) SpriteAnimation {
        return .{ .remaining = clip.ticks[0], .active = clip.flags & 1 != 0, .repeating = clip.flags & 2 != 0 };
    }
    pub fn tick(self: *SpriteAnimation, clip: AnimationClip) void {
        if (!self.active) return;
        self.remaining -= 1;
        if (self.remaining != 0) return;
        if (self.frame + 1 < clip.ticks.len) {
            self.frame += 1;
        } else if (self.repeating) {
            self.frame = 0;
        } else self.active = false;
        self.remaining = clip.ticks[self.frame];
    }
};
pub const Alignment = struct {
    elapsed: u16 = 0,
    horizontal: u8,
    vertical: u8,
    horizontal_direction: Direction,
    vertical_direction: Direction,

    pub fn start(x: i32, y: i32, target_x: i32, target_y: i32) !Alignment {
        if (x < 0 or y < 0 or target_x < 0 or target_y < 0 or x > 2040 or y > 2040 or target_x > 2040 or target_y > 2040 or @mod(x, 8) != 0 or @mod(y, 8) != 0 or @mod(target_x, 8) != 0 or @mod(target_y, 8) != 0) return error.InvalidAudienceAlignment;
        return .{ .horizontal = @intCast(@divTrunc(@abs(target_x - x), 8)), .vertical = @intCast(@divTrunc(@abs(target_y - y), 8)), .horizontal_direction = if (x < target_x) .right else .left, .vertical_direction = if (y < target_y) .down else .up };
    }
    pub fn active(self: Alignment) bool {
        return self.elapsed < (@as(u16, self.horizontal) + self.vertical + 2) * 4;
    }
    pub fn tick(self: *Alignment) ?Direction {
        if (!self.active()) return null;
        const tick_index = self.elapsed;
        self.elapsed += 1;
        if (tick_index % 4 != 0) return null;
        const stage = tick_index / 4;
        if (stage < self.horizontal) return self.horizontal_direction;
        if (stage > self.horizontal and stage <= @as(u16, self.horizontal) + self.vertical) return self.vertical_direction;
        return null;
    }
};

pub const Pan = struct {
    dx: i32,
    dy: i32,
    remaining: u16,

    pub fn end(self: Pan, start: Point) !Point {
        return .{
            .x = std.math.cast(i32, @as(i64, start.x) + @as(i64, self.dx) * self.remaining) orelse return error.InvalidCameraPan,
            .y = std.math.cast(i32, @as(i64, start.y) + @as(i64, self.dy) * self.remaining) orelse return error.InvalidCameraPan,
        };
    }

    pub fn tick(self: *Pan, camera: *Point) bool {
        camera.x += self.dx;
        camera.y += self.dy;
        self.remaining -= 1;
        return self.remaining == 0;
    }
};
pub const TextState = struct {
    id: ?[]const u8 = null,
    cursor: u16 = 0,
    pace: u8,
    countdown: u8 = 0,
    page_wait: bool = false,
    page: u8 = 0,
    done: bool = true,
    fast: bool = false,
    buffer: [4096]u8 = @splat(0),
    length: u16 = 0,

    pub fn start(text_data: Text, pace: u8) TextState {
        return .{ .id = text_data.id, .pace = pace, .done = false };
    }
    pub fn visible(self: *const TextState) []const u8 {
        return self.buffer[0..self.length];
    }
    fn append(self: *TextState, value: []const u8) !void {
        if (value.len > self.buffer.len - self.length) return error.AudienceTextOverflow;
        @memcpy(self.buffer[self.length..][0..value.len], value);
        self.length += @intCast(value.len);
    }
    pub fn acknowledge(self: *TextState) void {
        if (self.done) return;
        if (self.page_wait) {
            self.page_wait = false;
            self.page += 1;
            self.length = 0;
        } else self.fast = true;
    }
    pub fn tick(self: *TextState, text_data: Text, player_name: []const u8) !void {
        if (self.done or self.page_wait) return;
        if (!self.fast) {
            self.countdown -%= 1;
            if (self.countdown != 255) return;
        }
        const unlimited = self.fast;
        self.fast = false;
        while (self.cursor < text_data.tokens.len) {
            const token = text_data.tokens[self.cursor];
            self.cursor += 1;
            switch (token.kind) {
                .glyph => try self.append(token.text.?),
                .newline => try self.append("\n"),
                .player_name => try self.append(player_name),
                .pace => self.pace = token.value.?,
                .countdown => self.countdown = token.value.?,
                .page => self.page_wait = true,
            }
            if (!unlimited) self.countdown = self.pace;
            if (!unlimited or self.page_wait or token.kind == .countdown) break;
        }
        self.done = self.cursor == text_data.tokens.len and !self.page_wait;
    }
};
pub const TrackState = struct {
    cursor: u8 = 0,
    remaining: u8 = 0,
    hold_remaining: u16 = 0,
    hop_remaining: u8 = 0,
    direction: Direction = .down,
    advancing: bool = false,
    active: bool = true,
    motion: u8 = 2,
    saved_motion: u8,

    pub fn jsonStringify(self: TrackState, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(TrackState).@"struct".field_names) |name| {
            const include = if (comptime std.mem.eql(u8, name, "hold_remaining")) self.hold_remaining != 0 else if (comptime std.mem.eql(u8, name, "hop_remaining")) self.hop_remaining != 0 else true;
            if (include) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }

    pub fn start(track_data: Track, motion: u8) !TrackState {
        try validateTrack(track_data);
        return .{ .saved_motion = motion };
    }
    // One queue-consumer update. The actor system owns movement completion.
    pub fn tick(self: *TrackState, track_data: Track, moving: bool) !?Effect {
        try validateTrack(track_data);
        if (self.cursor > track_data.commands.len or (self.active and self.cursor == track_data.commands.len)) return error.InvalidAudienceTrackCursor;
        if (!self.active) return null;
        if (self.hop_remaining != 0) {
            std.debug.assert(self.hop_remaining < hop_offsets.len and self.remaining == 0 and self.hold_remaining == 0 and self.motion == 0);
            self.hop_remaining -= 1;
            if (self.hop_remaining == 0) self.motion = self.saved_motion;
            return .{ .kind = .vertical_offset, .actor = track_data.actor, .direction = self.direction, .offset_y = hop_offsets[hop_offsets.len - 1 - self.hop_remaining] };
        }
        if (moving) return null;
        if (self.hold_remaining != 0) {
            std.debug.assert(self.remaining == 0 and self.motion == 0);
            self.hold_remaining -= 1;
            if (self.hold_remaining == 0) self.motion = self.saved_motion;
            return null;
        }
        if (self.remaining != 0) {
            self.remaining -= 1;
            return .{ .kind = if (self.advancing) .advance else .move, .actor = track_data.actor, .direction = if (self.advancing) self.direction.opposite() else self.direction };
        }
        const command = track_data.commands[self.cursor];
        self.cursor += 1;
        switch (command.kind) {
            .hop => {
                self.motion = 0;
                self.advancing = false;
                self.hop_remaining = hop_offsets.len - 1;
                return .{ .kind = .vertical_offset, .actor = track_data.actor, .direction = self.direction, .offset_y = hop_offsets[0] };
            },
            .hold => {
                self.motion = 0;
                self.advancing = false;
                self.hold_remaining = command.updates.?;
            },
            .set_motion => self.motion = command.motion.?,
            .finish => {
                self.active = false;
                self.motion = self.saved_motion;
            },
            .move, .advance => {
                self.advancing = command.kind == .advance;
                if (command.direction) |direction| self.direction = direction;
                const count = command.cells.?;
                if (count != 0) self.remaining = count - 1;
                return .{ .kind = if (count == 0) .face else if (self.advancing) .advance else .move, .actor = track_data.actor, .direction = if (self.advancing) self.direction.opposite() else self.direction };
            },
        }
        return null;
    }
};

pub const Support = struct { id: []const u8, height: u8, depth: i32 };
pub const Pose = struct { x: i32, y: i32, variant: u8, frame: u8, visible: bool = true };
pub const FieldContext = struct { camera: Point, allow_player_animation: bool, hero_speed: u8 };
pub const Avatar = struct {
    pub const empty: Avatar = .{ .id = "", .graphic = "", .motion = .{ .x = 0, .y = 0, .speed = 0 }, .variant = 0, .sprite = .{ .remaining = 0, .active = false, .repeating = false }, .attached = false };
    id: []const u8,
    graphic: []const u8,
    motion: ActorMotion,
    variant: u8,
    orientation_flags: u2 = 0,
    sprite: SpriteAnimation,
    attached: bool,
    released: bool = false,
    auto_animate: bool = false,
    pose: ?Pose = null,
    support: ?Support = null,

    pub fn drawPose(self: Avatar) Pose {
        return self.pose orelse .{ .x = self.motion.x + self.motion.offset_x, .y = self.motion.y + self.motion.offset_y, .variant = self.variant, .frame = self.sprite.frame };
    }
    // Ground-plane field passes: players interpolate before emission, NPCs after it.
    pub fn fieldTick(self: *Avatar, content: Content, player: bool, context: FieldContext) void {
        self.fieldTickAnimation(content.animation(self.graphic), player, context);
    }
    pub fn fieldTickAnimation(self: *Avatar, animation: ?Animation, player: bool, context: FieldContext) void {
        _ = self.fieldTickAnimationCount(animation, player, context);
    }
    /// Report the primary clock invocations so a retained auxiliary owner can
    /// follow the same source work without owning a second primary clock.
    pub fn fieldTickAnimationCount(self: *Avatar, animation: ?Animation, player: bool, context: FieldContext) u8 {
        var tick_count: u8 = 0;
        if (player) self.motion.tick();
        if (self.attached and !self.released) {
            const clip = animation.?.clips[self.variant];
            const bounds = clip.bounds[self.sprite.frame];
            const x = self.motion.x + self.motion.offset_x;
            const y = self.motion.y + self.motion.offset_y;
            const visible = player or (x - context.camera.x + 24 >= 1 and x - context.camera.x - bounds.width < 320 and y - context.camera.y + bounds.height >= 1 and y - context.camera.y - bounds.height < 240);
            self.pose = .{ .x = x, .y = y, .variant = self.variant, .frame = self.sprite.frame, .visible = visible };
            const ticks: u8 = if (!self.motion.moving())
                @intFromBool((!player and self.auto_animate) or (self.sprite.frame != 1 and self.sprite.frame != 3))
            else if (player)
                (if (context.allow_player_animation) context.hero_speed else 0)
            else
                @intFromBool(visible);
            for (0..ticks) |_| self.sprite.tick(clip);
            tick_count = ticks;
        }
        if (!player) self.motion.tick();
        return tick_count;
    }

    pub fn setVariant(self: *Avatar, content: Content, variant: u8) !void {
        const animation = content.animation(self.graphic) orelse return error.UnknownAudienceGraphic;
        if (variant > 3) return error.UnsupportedAudienceVariant;
        self.variant = variant;
        self.released = false;
        self.sprite = SpriteAnimation.start(animation.clips[variant]);
    }
    pub fn face(self: *Avatar, content: Content, direction: Direction) !void {
        const variant: u8 = switch (direction) {
            .down => 0,
            .up => 1,
            .left => 2,
            .right => 3,
        };
        self.orientation_flags = switch (variant) {
            0 => self.orientation_flags & 2,
            1 => self.orientation_flags | 1,
            2 => self.orientation_flags & 1,
            3 => self.orientation_flags | 2,
            else => unreachable,
        };
        if (self.variant != variant) try self.setVariant(content, variant);
    }
};
pub const Box = struct {
    phase: enum { closed, opening, open, closing } = .closed,
    transition: u8 = 0,
    origin: Point = .{ .x = 0, .y = 0 },
    actor: ?[]const u8 = null,
    image: ?u8 = null,
    name: []const u8 = "",
    prefix_visible: u16 = 0,
    prefix_started: bool = false,
    prefix_done: bool = false,
    text: TextState = .{ .pace = 0 },
    pending_text: ?[]const u8 = null,

    fn changing(self: Box) bool {
        return self.phase == .opening or self.phase == .closing;
    }
    pub fn tickTransition(self: *Box) void {
        if (!self.changing()) return;
        if (self.transition == 0) {
            self.phase = if (self.phase == .opening) .open else .closed;
        } else self.transition -= 1;
    }
    pub fn outline(self: Box) ?struct { x: i32, y: i32, w: i32, h: i32 } {
        if (!self.changing()) return null;
        const opening = self.phase == .opening;
        const from = [4]i32{ self.origin.x - 160, self.origin.y - 120, 3, 3 };
        const to = [4]i32{ -124, 38, 240, 60 };
        var values: [4]i32 = undefined;
        for (from, to, 0..) |start, end, i| {
            values[i] = @divTrunc((if (opening) start else end) * @as(i32, self.transition) + (if (opening) end else start) * (20 - @as(i32, self.transition)), 20);
        }
        return .{ .x = values[0] + 160, .y = values[1] + 120, .w = values[2], .h = values[3] };
    }
};
pub const Follower = struct {
    actor: Avatar,
    previous_hero: Point,

    pub fn start(content: Content, hero: ActorMotion) !Follower {
        const clip = (content.animation("palace_character_110") orelse return error.UnknownAudienceGraphic).clips[0];
        return .{ .actor = .{ .id = "teo_follower", .graphic = "palace_character_110", .motion = .{ .x = hero.x, .y = @mod(hero.y - 16, 2048), .speed = 2 }, .variant = 0, .attached = true, .sprite = SpriteAnimation.start(clip) }, .previous_hero = .{ .x = hero.x, .y = hero.y - 8 } };
    }
    pub fn beforeHeroStep(self: *Follower, content: Content, hero: ActorMotion) !void {
        const motion = &self.actor.motion;
        const direction: Direction = if (motion.y < hero.y) .down else if (motion.y > hero.y) .up else if (motion.x < hero.x) .right else if (motion.x > hero.x) .left else return;
        try self.actor.face(content, direction);
        motion.x = @mod(self.previous_hero.x, 2048);
        motion.y = @mod(self.previous_hero.y, 2048);
        motion.offset_x = switch (direction) {
            .left => 8,
            .right => -8,
            else => 0,
        };
        motion.offset_y = switch (direction) {
            .up => 8,
            .down => -8,
            else => 0,
        };
        self.previous_hero = .{ .x = hero.x, .y = hero.y };
    }
};
pub const Point = struct { x: i32, y: i32 };
pub const Selection = struct {
    row: u8 = 0,
    y: i32 = 156,
    from_y: i32 = 156,
    remaining: u8 = 8,
    moving: bool = true,
    outline_only: bool = true,

    pub fn select(self: *Selection, row: u8) void {
        self.row = row;
        self.from_y = self.y;
        self.remaining = 8;
        self.moving = true;
    }
    pub fn tick(self: *Selection) void {
        self.outline_only = self.moving;
        if (!self.moving) return;
        const target: i32 = 156 + @as(i32, self.row) * 12;
        // The source divides coordinates relative to the viewport centre.
        self.y = @divTrunc((self.from_y - 120) * @as(i32, self.remaining) + (target - 120) * (8 - @as(i32, self.remaining)), 8) + 120;
        if (self.remaining == 0) self.moving = false else self.remaining -= 1;
    }
};
pub const Stage = struct { hero: Point, camera: Point, width: i32, height: i32, player_name: []const u8 };
pub const Input = struct { confirm: bool = false, up: bool = false, down: bool = false };
pub const Emission = struct { cue: ?u16 = null, completed: bool = false };
const Job = struct { track: []const u8, actor: u8, state: TrackState };
pub const State = struct {
    cursor: u16 = 0,
    active: bool = true,
    elapsed: u32 = 0,
    actors: [66]Avatar = @splat(Avatar.empty),
    actor_count: u8,
    hero: u8,
    double: u8,
    jobs: [30]?Job = @splat(null),
    alignment: ?Alignment = null,
    delay: u16 = 0,
    pan: ?Pan = null,
    camera: Point,
    width: i32,
    height: i32,
    player_name: []const u8,
    boxes: [2]Box = @splat(.{}),
    text_box: ?u1 = null,
    choice_open: bool = false,
    choice: u1 = 0,
    selection: ?Selection = null,
    following_teo: bool = false,
    follower: ?Follower = null,
    audience_complete: bool = false,
    cue: u16 = 129,
    cached_cue: ?u16 = null,
    allow_player_animation: bool = true,

    pub fn playerName(self: *const State) []const u8 {
        return self.player_name;
    }

    pub fn start(content: Content, stage: Stage) !State {
        try content.validate();
        if (stage.width < 320 or stage.height < 240 or stage.width > 2048 or stage.height > 2048 or stage.player_name.len == 0 or stage.player_name.len > 32) return error.InvalidAudienceStage;
        const hero_index: u8 = @intCast(content.actors.len);
        var result: State = .{ .actor_count = hero_index + 2, .hero = hero_index, .double = hero_index + 1, .camera = stage.camera, .width = stage.width, .height = stage.height, .player_name = stage.player_name };
        for (content.actors, 0..) |actor, i| result.actors[i] = .{ .id = actor.id, .graphic = actor.graphic, .motion = .{ .x = actor.x, .y = actor.y, .speed = actor.motion }, .variant = actor.variant, .attached = actor.attached, .auto_animate = actor.auto_animate, .sprite = SpriteAnimation.start(content.animation(actor.graphic).?.clips[actor.variant]) };
        result.actors[hero_index] = .{ .id = "hero", .graphic = "hero", .motion = .{ .x = stage.hero.x, .y = stage.hero.y, .speed = 0 }, .variant = 0, .attached = true, .sprite = SpriteAnimation.start(content.animation("hero").?.clips[0]) };
        result.actors[result.double] = result.actors[hero_index];
        result.actors[result.double].id = "audience_double";
        result.actors[result.double].attached = false;
        return result;
    }
    pub fn avatar(self: *State, id: []const u8) !*Avatar {
        for (self.actors[0..self.actor_count]) |*actor| if (std.mem.eql(u8, actor.id, id)) return actor;
        return error.UnknownAudienceActor;
    }
    fn actorIndex(self: State, id: []const u8) !u8 {
        for (self.actors[0..self.actor_count], 0..) |actor, i| if (std.mem.eql(u8, actor.id, id)) return @intCast(i);
        return error.UnknownAudienceActor;
    }
    pub fn tracksBusy(self: State) bool {
        for (self.jobs) |job| if (job != null) return true;
        return false;
    }
    pub fn fieldPass(self: *State, content: Content) void {
        const context: FieldContext = .{ .camera = self.camera, .allow_player_animation = self.allow_player_animation, .hero_speed = self.actors[self.hero].motion.speed };
        self.actors[self.hero].fieldTick(content, true, context);
        if (self.follower) |*follower| follower.actor.fieldTick(content, true, context);
        for (self.actors[0..self.actor_count], 0..) |*actor, i| if (i != self.hero) actor.fieldTick(content, false, context);
    }
    fn stepActor(self: *State, content: Content, index: u8, direction: Direction) !void {
        if (index == self.hero) if (self.follower) |*follower| try follower.beforeHeroStep(content, self.actors[index].motion);
        self.actors[index].motion.step(direction);
    }
    pub fn textBusy(self: State) bool {
        return if (self.text_box) |box| !self.boxes[box].text.done else false;
    }
    fn cameraFromHero(self: *State) void {
        const actor = self.actors[self.hero].motion;
        self.camera = .{ .x = std.math.clamp(actor.x + actor.offset_x - 152, 0, self.width - 320), .y = std.math.clamp(actor.y + actor.offset_y - 112, 0, self.height - 240) };
    }
    fn command(self: *State, content: Content, input: Input, output: *Emission) !void {
        self.allow_player_animation = false;
        const entry = content.commands[self.cursor];
        switch (entry.kind) {
            .align_hero => {
                self.alignment = try Alignment.start(self.actors[self.hero].motion.x, self.actors[self.hero].motion.y, entry.x.?, entry.y.?);
                self.allow_player_animation = true;
            },
            .actor_transition => {
                const actor = try self.avatar(entry.actor.?);
                const transition = entry.transition.?;
                actor.orientation_flags = switch (transition) {
                    0 => actor.orientation_flags & 2,
                    1 => actor.orientation_flags | 1,
                    2 => actor.orientation_flags & 1,
                    3 => actor.orientation_flags | 2,
                };
                if (actor.variant != transition) try actor.setVariant(content, transition);
            },
            .open_box => {
                const box = &self.boxes[entry.box.?];
                if (box.phase != .closed) return;
                const actor = self.actors[try self.actorIndex(entry.actor.?)];
                box.* = .{ .phase = .opening, .transition = 20, .actor = entry.actor.?, .origin = .{ .x = actor.motion.x + 8 - self.camera.x, .y = actor.motion.y - 24 - self.camera.y } };
                output.cue = 0x501;
            },
            .speaker => {
                const box = &self.boxes[entry.box.?];
                if (!box.prefix_started) {
                    box.prefix_started = true;
                    box.name = entry.name.?;
                    box.image = entry.image.?;
                    return;
                }
                if (!box.prefix_done) return;
            },
            .text => self.boxes[entry.box.?].pending_text = entry.text.?,
            .wait_confirm => if (!input.confirm) return,
            .close_box => {
                const box = &self.boxes[entry.box.?];
                box.phase = .closing;
                box.transition = 20;
            },
            .queue_track => {
                const track_data = content.track(entry.track.?).?;
                const index = try self.actorIndex(track_data.actor);
                const actor = &self.actors[index];
                if (!actor.attached) return error.UnattachedAudienceActor;
                var count: usize = 0;
                for (self.jobs) |job| count += @intFromBool(job != null);
                if (count == self.jobs.len) return error.AudienceQueueFull;
                if (self.jobs[count] != null) return error.UnsupportedAudienceQueueOverlap;
                self.jobs[count] = .{ .track = track_data.id, .actor = index, .state = try TrackState.start(track_data, actor.motion.speed) };
                actor.motion.speed = 2;
                actor.motion.offset_x = 0;
                actor.motion.offset_y = 0;
            },
            .wait_tracks => if (self.tracksBusy()) return,
            .delay => self.delay = entry.updates.?,
            .pan => self.pan = .{ .dx = entry.dx.?, .dy = entry.dy.?, .remaining = entry.updates.? },
            .cue => {
                const cue = entry.cue.?;
                if (self.cached_cue != cue) output.cue = cue;
                self.cue = cue;
                if (cue >= 0x201 and cue <= 0x445) self.cached_cue = cue;
            },
            .next_variant, .previous_variant, .set_variant, .wait_variant => {
                const actor = try self.avatar(entry.actor.?);
                if (entry.kind == .wait_variant and actor.sprite.active) return;
                const variant = switch (entry.kind) {
                    .next_variant => actor.variant +% 1,
                    .previous_variant => actor.variant -% 1,
                    .set_variant => entry.variant.?,
                    else => actor.variant,
                };
                try actor.setVariant(content, variant);
            },
            .actor_motion => (try self.avatar(entry.actor.?)).motion.speed = entry.value.?,
            .actor_x => (try self.avatar(entry.actor.?)).motion.x = @as(i32, entry.value.?) * 8,
            .actor_y => (try self.avatar(entry.actor.?)).motion.y = @as(i32, entry.value.?) * 8,
            .release_actor => {
                const actor = try self.avatar(entry.actor.?);
                actor.motion.speed = 0;
                actor.released = true;
                actor.variant = 254;
            },
            .create_double => {
                if (!std.mem.eql(u8, entry.character.?, "hero")) return error.UnsupportedAudienceDouble;
                const actor = &self.actors[self.double];
                actor.attached = true;
                actor.released = false;
                actor.motion = .{ .x = entry.x.?, .y = entry.y.?, .speed = 0 };
                try actor.setVariant(content, 0);
            },
            .choice => {
                if (!self.choice_open) {
                    self.choice_open = true;
                    self.choice = 0;
                    self.selection = .{};
                    return;
                }
                if (input.confirm and !input.up and !input.down) {
                    self.choice_open = false;
                    self.selection = null;
                } else {
                    if (!input.confirm and input.up != input.down) {
                        self.choice ^= 1;
                        self.selection.?.select(self.choice);
                    }
                    return;
                }
            },
            .jump => {
                self.cursor = entry.target.?;
                return;
            },
            .branch_choice => if (self.choice != 0) {
                self.cursor = entry.target.?;
                return;
            },
            .label => {},
            .free_double => self.actors[self.double].attached = false,
            .follow_character => {
                if (!std.mem.eql(u8, entry.character.?, "teo")) return error.UnsupportedAudienceFollower;
                self.following_teo = true;
                self.follower = try Follower.start(content, self.actors[self.hero].motion);
            },
            .complete_audience => self.audience_complete = true,
            .wait_boxes, .finish => {
                for (self.boxes) |box| if (box.changing()) return;
                if (entry.kind == .finish) {
                    self.active = false;
                    self.allow_player_animation = true;
                    output.completed = true;
                }
            },
        }
        self.cursor += 1;
    }
    pub fn tick(self: *State, content: Content, input: Input) !Emission {
        var output: Emission = .{};
        if (!self.active) return output;
        if (self.cursor >= content.commands.len) return error.InvalidAudienceCursor;
        const blocked = self.delay != 0 or self.pan != null or (self.alignment != null and self.alignment.?.active()) or self.textBusy();
        if (!blocked) try self.command(content, input, &output);
        for (&self.boxes) |*box| {
            box.tickTransition();
            if (box.phase != .open) continue;
            if (box.prefix_started and !box.prefix_done) {
                box.prefix_visible += 1;
                box.prefix_done = box.prefix_visible > box.name.len;
            }
            if (box.text.id) |id| try box.text.tick(content.text(id).?, self.player_name);
        }
        if (self.selection) |*selection| selection.tick();
        if (self.alignment) |*alignment| {
            if (alignment.tick()) |direction| {
                const actor = &self.actors[self.hero];
                actor.motion.speed = 2;
                try actor.face(content, direction);
                try self.stepActor(content, self.hero, direction);
            }
            self.cameraFromHero();
            if (!alignment.active()) self.alignment = null;
        }
        if (self.delay != 0) self.delay -= 1;
        if (self.pan) |*pan| if (pan.tick(&self.camera)) {
            self.pan = null;
        };
        var hero_queued = false;
        for (&self.jobs) |*job| if (job.*) |*current| {
            const actor = &self.actors[current.actor];
            const track_data = content.track(current.track).?;
            const was_moving = actor.motion.moving();
            const previous_motion = current.state.motion;
            if (current.actor == self.hero) hero_queued = true;
            if (try current.state.tick(track_data, was_moving)) |effect| {
                if (effect.kind == .vertical_offset) {
                    actor.motion.offset_y = effect.offset_y;
                } else {
                    if (effect.kind != .advance) try actor.face(content, effect.direction);
                    if (effect.kind != .face) try self.stepActor(content, current.actor, effect.direction);
                }
            }
            actor.motion.speed = current.state.motion;
            if (!current.state.active) {
                job.* = null;
            } else if (was_moving and actor.attached and !actor.released) {
                const ticks: u8 = (if (current.actor == self.hero) previous_motion else @as(u8, 0)) + @as(u8, @intFromBool(actor.auto_animate));
                for (0..ticks) |_| actor.sprite.tick(content.animation(actor.graphic).?.clips[actor.variant]);
            }
        };
        if (hero_queued) self.cameraFromHero();
        if (self.text_box) |box| if (input.confirm) self.boxes[box].text.acknowledge();
        for (&self.boxes, 0..) |*box, i| if (box.pending_text) |id| {
            box.text = TextState.start(content.text(id).?, content.default_text_pace);
            box.pending_text = null;
            self.text_box = @intCast(i);
        };
        // The field actor pass follows the event, widget, upload and queue consumers.
        self.fieldPass(content);
        self.elapsed += 1;
        return output;
    }
};
