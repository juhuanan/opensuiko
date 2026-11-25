const std = @import("std");
pub const json = @import("opening_event_data").json;
pub const ActorId = enum { descriptor_0, descriptor_1, descriptor_2, descriptor_3, descriptor_7, descriptor_8, descriptor_9 };
pub const Flags = struct { story_0006: bool = false };
pub const Command = struct {
    kind: enum { select_cue, release_actor, continue_tick, yield_tick, end_stream },
    cue: ?u16 = null,
    actor: ?ActorId = null,
};
pub const Program = struct { id: []const u8, condition: enum { always, story_0006 }, commands: []const Command };
pub const Content = struct {
    schema: []const u8,
    room: []const u8,
    initial_flags: Flags,
    programs: []const Program,
    initialization_order: ?[]const []const u8 = null,

    pub fn program(self: Content, id: []const u8) ?Program {
        for (self.programs) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }
    pub fn validate(self: Content) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-opening-events/1") and !std.mem.eql(u8, self.schema, "suikoden-opening-events/2")) return error.UnsupportedEventSchema;
        if (std.mem.eql(u8, self.schema, "suikoden-opening-events/2") and self.initialization_order == null) return error.MissingInitializationOrder;
        if (!std.mem.eql(u8, self.room, "vaa_room_2") or self.programs.len == 0 or self.programs.len > 2) return error.InvalidEventContent;
        for (self.programs, 0..) |entry, index| {
            if (entry.id.len == 0 or entry.id.len > 64 or entry.commands.len == 0 or entry.commands.len > 32) return error.InvalidEventProgram;
            for (self.programs[0..index]) |other| if (std.mem.eql(u8, entry.id, other.id)) return error.DuplicateEvent;
            var cues: usize = 0;
            var releases: usize = 0;
            for (entry.commands, 0..) |command, i| {
                if ((command.kind == .select_cue) != (command.cue != null) or (command.kind == .release_actor) != (command.actor != null)) return error.InvalidEventCommand;
                if (command.cue) |cue| if (cue != 129) return error.UnsupportedEventCue;
                cues += @intFromBool(command.kind == .select_cue);
                releases += @intFromBool(command.kind == .release_actor);
                if ((command.kind == .end_stream) != (i == entry.commands.len - 1)) return error.InvalidEventEnd;
            }
            if (cues > 1 or releases > 7) return error.TooManyEventEffects;
        }
        if (self.initialization_order) |order| {
            if (order.len != self.programs.len) return error.InvalidInitializationOrder;
            for (order, 0..) |id, i| {
                if (self.program(id) == null) return error.UnknownEvent;
                for (order[0..i]) |other| if (std.mem.eql(u8, id, other)) return error.InvalidInitializationOrder;
            }
        }
    }
};
pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Content) {
    if (bytes.len > 16 * 1024) return error.EventContentTooLarge;
    const parsed = try std.json.parseFromSlice(Content, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}
pub const Actor = struct { attached: bool = false, released: bool = false, state: u8 = 0 };
pub const Effects = struct { queued_cue: ?u16 = null, released: [7]?ActorId = @splat(null), ended: bool = false };
pub const Initialization = struct { programs: [2]?[]const u8 = @splat(null), pumps: [2]?Effects = @splat(null) };
pub const State = struct {
    schema: []const u8 = "suikoden-opening-event-state/2",
    initialized: bool = false,
    selected: ?[]const u8 = null,
    cursor: u16 = 0,
    active: bool = false,
    reloop: bool = false,
    cue: ?u16 = null,
    cached_cue: ?u16 = null,
    flags: Flags = .{},
    actors: [7]Actor = @splat(.{}),

    pub fn init(content: Content) !State {
        try content.validate();
        return .{ .flags = content.initial_flags };
    }
    pub fn validate(self: State, content: Content) !void {
        try content.validate();
        const legacy = std.mem.eql(u8, self.schema, "suikoden-opening-event-state/1");
        if (!legacy and !std.mem.eql(u8, self.schema, "suikoden-opening-event-state/2")) return error.UnsupportedEventState;
        if (legacy and self.initialized) return error.InvalidEventCursor;
        if (self.cue == 65535 or self.cached_cue == 65535) return error.InvalidEventCue;
        if (self.selected) |id| {
            const entry = content.program(id) orelse return error.UnknownEvent;
            if (self.cursor > entry.commands.len or (self.active and self.cursor == entry.commands.len) or (!self.active and !self.initialized and self.cursor != entry.commands.len)) return error.InvalidEventCursor;
        } else if (self.active or self.cursor != 0 or self.reloop) return error.InvalidEventCursor;
    }
    pub fn apply(self: State, content: Content, destination: *State) !void {
        try self.validate(content);
        var restored = self;
        restored.schema = "suikoden-opening-event-state/2";
        if (self.selected) |id| restored.selected = content.program(id).?.id;
        destination.* = restored;
    }
    pub fn initializeRoom(self: *State, content: Content) !Initialization {
        try self.validate(content);
        const order = content.initialization_order orelse return error.MissingInitializationOrder;
        if (self.initialized) return error.RoomAlreadyInitialized;
        if (self.active or self.selected != null) return error.EventBusy;
        var next = self.*;
        var result: Initialization = .{};
        next.initialized = true;
        var count: usize = 0;
        for (order) |id| {
            const entry = content.program(id).?;
            if (entry.condition == .story_0006 and !next.flags.story_0006) continue;
            try next.select(content, id);
            result.programs[count] = entry.id;
            result.pumps[count] = try next.tick(content, 0);
            next.active = false;
            count += 1;
        }
        self.* = next;
        return result;
    }
    pub fn select(self: *State, content: Content, id: []const u8) !void {
        try self.validate(content);
        if (self.active) return error.EventBusy;
        const entry = content.program(id) orelse return error.UnknownEvent;
        if (entry.condition == .story_0006 and !self.flags.story_0006) return error.EventConditionFalse;
        self.selected = entry.id;
        self.cursor = 0;
        self.reloop = false;
        self.active = true;
    }
    // One original stream-pump invocation, independent of host frame cadence.
    pub fn tick(self: *State, content: Content, text_busy_flags: u16) !Effects {
        try self.validate(content);
        var effects: Effects = .{};
        if (!self.active) return effects;
        const entry = content.program(self.selected.?).?;
        var released: usize = 0;
        while (true) {
            const command = entry.commands[self.cursor];
            switch (command.kind) {
                .select_cue => {
                    if (self.cached_cue != command.cue) effects.queued_cue = command.cue;
                    self.cue = command.cue;
                },
                .release_actor => {
                    const id = command.actor.?;
                    const actor = &self.actors[@backingInt(id)];
                    if (actor.attached) {
                        actor.state = 0;
                        actor.released = true;
                        effects.released[released] = id;
                        released += 1;
                    }
                },
                .continue_tick => self.reloop = true,
                .yield_tick => self.reloop = false,
                .end_stream => {
                    if (text_busy_flags & 3 != 0) return effects;
                    self.active = false;
                    effects.ended = true;
                },
            }
            self.cursor += 1;
            if (!self.active or !self.reloop) return effects;
        }
    }
};
