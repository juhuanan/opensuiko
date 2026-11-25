//! Room 2 entity 2 slot-0 text lifecycle. One pass dispatches before updating.
const std = @import("std");
const slots = @import("native_slots.zig");
const glyph = @import("native_glyph_adapter.zig");
const motion = @import("opening_audience");

pub const Phase = enum { absent, opening, open, closing, release_pending };
pub const Geometry = enum { layout_zero, fixed_10_10_12_2 };
pub const Job = enum { none, prefix, body5, body47 };
pub const Action = union(enum) {
    none,
    open: Geometry,
    native: slots.Request,
    body: enum { entry5, entry47 },
    close_0c,
    close_01,
    fd,
};
pub const Input = struct {
    action: Action = .none,
    /// Source pressed-edge and held input words.
    pressed: u32 = 0,
    held: u32 = 0,
};
pub const Result = enum { advance, wait };
pub const Binding = struct {
    context: slots.Context,
    /// SHA-256 of the verified packet supplying the two body entries.
    body_identity: [32]u8,
    body5: motion.Text,
    body47: motion.Text,
    /// Actual source game-state text speed index, 0..2.
    text_speed: u8,
    player_name: []const u8,
};

pub const State = struct {
    owner: slots.Owner = .{},
    phase: Phase = .absent,
    geometry: ?Geometry = null,
    transition: u8 = 0,
    job: Job = .none,
    text: motion.TextState = .{ .pace = 0 },
    adapter: ?glyph.Adapter = null,
    prefix_offset: u16 = 0,
    current_pace: u8 = 0,
    body_speed: u8 = 0,
    page_repeat: u8 = 0,
    context_generation: u64 = 0,
    body_identity: [32]u8 = @splat(0),
    name_text: [32]u8 = @splat(0),
    name_len: u8 = 0,
    name_ends: [32]u8 = @splat(0),
    name_count: u8 = 0,
    /// Exact ordered facts are retained for snapshot rebind; no pointers saved.
    custom: [16]slots.Resource = @splat(.{ .code = 0, .id = 0, .available = false }),
    custom_count: u8 = 0,
    loaded: [6]slots.Resource = @splat(.{ .code = 0, .id = 0, .available = false }),
    loaded_count: u8 = 0,

    fn sameResources(a: []const slots.Resource, b: []const slots.Resource) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (!std.meta.eql(x, y)) return false;
        return true;
    }
    fn name(binding: Binding, code: u8) !slots.Name {
        for (binding.context.names) |item| if (item.code == code) return item;
        return error.NativeNameRequired;
    }
    fn sourceText(binding: Binding, job: Job) !motion.Text {
        return switch (job) {
            .body5 => binding.body5,
            .body47 => binding.body47,
            else => error.InvalidRoom2TextState,
        };
    }
    fn prefixText(n: slots.Name, buffer: *[33]motion.Token) motion.Text {
        var start: usize = 0;
        for (n.glyph_ends, 0..) |end, i| {
            buffer[i] = .{ .kind = .glyph, .text = n.text[start..end] };
            start = end;
        }
        buffer[n.glyph_ends.len] = .{ .kind = .newline };
        return .{ .id = "room2-native-prefix", .tokens = buffer[0 .. n.glyph_ends.len + 1] };
    }
    fn checkBinding(self: State, binding: Binding) !void {
        _ = try slots.contextFingerprint(binding.context);
        if (binding.text_speed > 2 or self.custom_count > self.custom.len or self.loaded_count > self.loaded.len) return error.InvalidRoom2TextState;
        if (self.phase != .absent and (self.context_generation != binding.context.generation or
            !std.mem.eql(u8, &self.body_identity, &binding.body_identity) or
            !sameResources(self.custom[0..self.custom_count], binding.context.custom_images) or
            !sameResources(self.loaded[0..self.loaded_count], binding.context.loaded_characters))) return error.Room2TextBindingMismatch;
        if (self.phase != .absent) {
            const n = try name(binding, 108);
            if (self.name_len > 32 or self.name_count > 32 or !std.mem.eql(u8, self.name_text[0..self.name_len], n.text) or !std.mem.eql(u8, self.name_ends[0..self.name_count], n.glyph_ends)) return error.Room2TextBindingMismatch;
        }
    }
    fn appendExpected(buffer: *[4096]u8, length: *usize, value: []const u8) !void {
        if (value.len > buffer.len - length.*) return error.InvalidRoom2TextState;
        @memcpy(buffer[length.*..][0..value.len], value);
        length.* += value.len;
    }
    /// Reconstruct the visible text from source tokens, not from saved buffer.
    fn validateBody(self: State, binding: Binding, body: motion.Text) !void {
        if (self.text.cursor > body.tokens.len or self.text.length > self.text.buffer.len or
            self.text.done != (self.text.cursor == body.tokens.len and !self.text.page_wait)) return error.InvalidRoom2TextState;
        const ted = try name(binding, 108);
        var expected: [4096]u8 = undefined;
        var length: usize = 0;
        var pages: usize = 0;
        try appendExpected(&expected, &length, ted.text);
        try appendExpected(&expected, &length, "\n");
        for (body.tokens[0..self.text.cursor], 0..) |token, index| {
            switch (token.kind) {
                .glyph => try appendExpected(&expected, &length, token.text orelse return error.InvalidRoom2TextState),
                .newline => try appendExpected(&expected, &length, "\n"),
                .player_name => try appendExpected(&expected, &length, binding.player_name),
                .page => {
                    const unacknowledged = self.text.page_wait and index + 1 == self.text.cursor;
                    if (!unacknowledged) {
                        pages += 1;
                        length = 0;
                    }
                },
                .countdown => {},
                .pace => return error.InvalidRoom2TextState,
            }
        }
        if (self.text.page_wait and (self.text.cursor == 0 or body.tokens[self.text.cursor - 1].kind != .page)) return error.InvalidRoom2TextState;
        if (pages != self.text.page or length != self.text.length or
            !std.mem.eql(u8, expected[0..length], self.text.buffer[0..self.text.length])) return error.InvalidRoom2TextState;
    }
    pub fn validate(self: State, binding: Binding) !void {
        try self.checkBinding(binding);
        try self.owner.validate();
        const slot = self.owner.slots[0];
        if (self.owner.slots[1].allocated or self.owner.slots[1].waiting != null or self.owner.slots[1].image != null or
            (self.phase == .absent) == slot.allocated or (self.phase == .absent) != (self.geometry == null) or
            self.transition > 20 or ((self.phase == .open or self.phase == .absent or self.phase == .release_pending) and self.transition != 0) or
            self.text.length > self.text.buffer.len or self.body_speed > 2 or self.current_pace > 5 or self.page_repeat > 30) return error.InvalidRoom2TextState;
        if (self.job == .prefix) {
            const adapter = self.adapter orelse return error.InvalidRoom2TextState;
            const n = try name(binding, adapter.request.code);
            try adapter.validate(self.owner, n);
            if (self.prefix_offset > self.text.length or self.text.cursor != adapter.cursor or self.text.countdown != adapter.countdown or
                self.text.done != adapter.done or !std.mem.eql(u8, self.text.buffer[self.prefix_offset..self.text.length], adapter.visible[0..adapter.visible_len])) return error.InvalidRoom2TextState;
        } else if (self.adapter != null) return error.InvalidRoom2TextState;
        if (self.job == .body5 or self.job == .body47) {
            const text = try sourceText(binding, self.job);
            if (self.text.id == null or !std.mem.eql(u8, self.text.id.?, text.id)) return error.InvalidRoom2TextState;
            try self.validateBody(binding, text);
        }
        if (self.phase == .absent and (self.job != .none or slot.image != null)) return error.InvalidRoom2TextState;
    }
    pub fn bodyDone(self: State) bool {
        return (self.job == .body5 or self.job == .body47) and self.text.done;
    }
    pub fn fdReady(self: State) bool {
        return self.phase != .opening and self.phase != .closing and self.phase != .release_pending;
    }
    /// Invoke exactly once per field pass with the one event action selected by
    /// the caller. No action is dispatched while another source driver is busy.
    pub fn pass(self: *State, binding: Binding, input: Input) !Result {
        try self.validate(binding);
        var next = self.*;
        var result: Result = .advance;
        var body_staged = false;
        switch (input.action) {
            .none => {},
            .fd => if (!next.fdReady()) {
                result = .wait;
            },
            .open => |geometry| {
                if (next.phase != .absent) {
                    result = .wait;
                } else {
                    if (binding.context.custom_images.len > next.custom.len or binding.context.loaded_characters.len > next.loaded.len) return error.UnsupportedRoom2Resources;
                    try next.owner.allocate(.first);
                    try next.owner.opened(.first);
                    const n = try name(binding, 108);
                    if (n.text.len > 32 or n.glyph_ends.len > 32) return error.InvalidRoom2TextState;
                    next.context_generation = binding.context.generation;
                    next.body_identity = binding.body_identity;
                    next.name_len = @intCast(n.text.len);
                    next.name_count = @intCast(n.glyph_ends.len);
                    @memset(&next.name_text, 0);
                    @memset(&next.name_ends, 0);
                    @memcpy(next.name_text[0..next.name_len], n.text);
                    @memcpy(next.name_ends[0..next.name_count], n.glyph_ends);
                    next.custom_count = @intCast(binding.context.custom_images.len);
                    next.loaded_count = @intCast(binding.context.loaded_characters.len);
                    @memcpy(next.custom[0..next.custom_count], binding.context.custom_images);
                    @memcpy(next.loaded[0..next.loaded_count], binding.context.loaded_characters);
                    next.geometry = geometry;
                    next.phase = .opening;
                    next.transition = 20;
                    next.text = .{ .pace = 0, .countdown = ([_]u8{ 2, 4, 11 })[binding.text_speed] };
                }
            },
            .native => |request| {
                if (request.slot != .first or request.code != 108 or next.phase == .absent or next.phase == .closing or next.phase == .release_pending) return error.InvalidRoom2TextState;
                const proposal = try next.owner.propose(request, binding.context);
                if (proposal.starts) {
                    if (next.job != .none and !next.text.done) return error.Room2TextBusy;
                    try next.owner.acknowledge(proposal, binding.context);
                    if (proposal.prefix) |n| {
                        var tokens: [33]motion.Token = undefined;
                        const prefix = prefixText(n, &tokens);
                        const countdown = next.text.countdown;
                        next.prefix_offset = next.text.length;
                        next.text.id = prefix.id;
                        next.text.cursor = 0;
                        next.text.pace = 0;
                        next.text.countdown = countdown;
                        next.text.done = false;
                        next.text.page_wait = false;
                        next.text.fast = false;
                        next.job = .prefix;
                        next.adapter = try glyph.Adapter.start(next.owner, request, n, countdown);
                    }
                    result = .wait;
                } else if (proposal.flow == .wait) {
                    result = .wait;
                } else {
                    try next.owner.acknowledge(proposal, binding.context);
                    next.adapter = null;
                    next.job = .none;
                }
            },
            .body => |which| {
                if (next.phase == .absent or next.phase == .closing or next.phase == .release_pending or next.owner.slots[0].waiting != null or (next.job != .none and !next.text.done)) return error.Room2TextBusy;
                next.job = switch (which) {
                    .entry5 => .body5,
                    .entry47 => .body47,
                };
                body_staged = true;
                const body = try sourceText(binding, next.job);
                next.text.id = body.id;
                next.text.cursor = 0;
                next.text.done = false;
                next.text.page_wait = false;
                next.text.page = 0;
                next.text.fast = false;
                next.text.pace = ([_]u8{ 1, 3, 5 })[binding.text_speed];
                next.current_pace = next.text.pace;
                next.body_speed = binding.text_speed;
                next.page_repeat = 0;
            },
            .close_0c, .close_01 => {
                if (next.phase != .open or next.owner.slots[0].waiting != null or (next.job != .none and !next.text.done)) return error.Room2TextBusy;
                if (std.meta.activeTag(input.action) == .close_0c) try next.owner.closing(.first) else try next.owner.closingKeepImage(.first);
                next.phase = .closing;
                next.transition = 20;
                next.job = .none;
                next.adapter = null;
            },
        }
        switch (next.phase) {
            .opening => if (next.transition == 0) {
                next.phase = .open;
            } else {
                next.transition -= 1;
            },
            .closing => if (next.transition == 0) {
                next.phase = .release_pending;
            } else {
                next.transition -= 1;
            },
            .release_pending => {
                try next.owner.released(.first);
                next.phase = .absent;
                next.geometry = null;
                next.job = .none;
            },
            else => {},
        }
        if (next.phase == .open and next.job != .none and !body_staged) {
            if (next.job == .prefix) {
                const adapter = &next.adapter.?;
                const n = try name(binding, adapter.request.code);
                var tokens: [33]motion.Token = undefined;
                const prefix = prefixText(n, &tokens);
                try next.text.tick(prefix, binding.player_name);
                try adapter.observe(&next.owner, n, .{ .generation = adapter.generation, .cursor = @intCast(next.text.cursor), .countdown = next.text.countdown, .done = next.text.done, .visible = next.text.buffer[next.prefix_offset..next.text.length] });
            } else {
                try next.text.tick(try sourceText(binding, next.job), binding.player_name);
            }
        }
        // The dialogue driver runs after the box/glyph updater, including on
        // the body-staging pass. Its input effects apply on the next pass.
        if (next.job == .body5 or next.job == .body47) {
            if (next.text.page_wait) {
                if (input.pressed & 0x65 != 0) {
                    next.text.acknowledge();
                } else if (input.held & 0x41 != 0) {
                    next.page_repeat +%= 1;
                    if (next.page_repeat >= 31) {
                        next.text.acknowledge();
                        next.page_repeat = 0;
                    }
                }
            } else {
                const fast = ([_]u8{ 0, 1, 2 })[next.body_speed];
                if (input.pressed & 0x65 != 0 and next.current_pace != fast) {
                    next.current_pace = fast;
                    next.text.fast = true;
                } else {
                    next.current_pace = ([_]u8{ 1, 3, 5 })[next.body_speed];
                }
            }
        }
        try next.validate(binding);
        self.* = next;
        return result;
    }
};
