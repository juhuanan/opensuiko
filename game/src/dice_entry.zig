//! Fixed-game entry questions; text opening, reading and closing stay with the box owner.
pub const Message = enum { rules_question, rules, fixed_notice, ready };
pub const Input = enum { text_ready, text_closed, up, down, confirm, cancel };

message: Message = .rules_question,
selected_yes: bool = true,
text_ready: bool = false,
close_requested: bool = false,

pub fn choicesAvailable(self: @This()) bool {
    return !self.close_requested and (self.message == .rules_question or (self.message == .rules and self.text_ready));
}

pub fn update(self: *@This(), input: Input) !void {
    if (self.message == .ready) return error.DiceEntryComplete;
    switch (input) {
        .text_ready => self.text_ready = true,
        .text_closed => {
            if (!self.close_requested or !self.text_ready) return error.PendingDiceText;
            const next: Message = switch (self.message) {
                .rules_question, .rules => if (self.selected_yes) .rules else .fixed_notice,
                .fixed_notice => .ready,
                .ready => unreachable,
            };
            self.* = .{ .message = next, .selected_yes = false };
        },
        .up => if (self.choicesAvailable()) {
            self.selected_yes = true;
        },
        .down => if (self.choicesAvailable()) {
            self.selected_yes = false;
        },
        .confirm, .cancel => {
            if (self.close_requested or (self.message == .rules and !self.text_ready)) return;
            if (input == .cancel) self.selected_yes = false;
            self.close_requested = true;
        },
    }
}

pub fn finished(self: Entry) bool {
    return self.message == .ready;
}

pub fn acceptsDirections(self: Entry) bool {
    return self.message != .fixed_notice;
}

pub fn textFor(self: Entry, packet: visual.Packet) !audience.Text {
    return messageFor(packet, self.message);
}

pub const Buttons = struct {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    confirm: bool = false,
    cancel: bool = false,
    triangle: bool = false,
    square: bool = false,

    pub fn any(self: Buttons) bool {
        inline for (comptime @import("std").meta.fieldNames(Buttons)) |name| if (@field(self, name)) return true;
        return false;
    }
};
pub const Controls = struct {
    pressed: Buttons = .{},
    held_reveal: bool = false,

    pub fn merge(self: *Controls, other: Controls) void {
        inline for (comptime @import("std").meta.fieldNames(Buttons)) |name| @field(self.pressed, name) = @field(self.pressed, name) or @field(other.pressed, name);
        self.held_reveal = other.held_reveal;
    }
};
pub const Sampler = struct {
    previous: Buttons = .{},
    armed: bool = false,
    device: ?i32 = null,

    pub fn sample(self: *Sampler, held: Buttons, enabled: bool, device: ?i32) Controls {
        if (!enabled or self.device != device) self.* = .{ .device = device };
        defer self.previous = held;
        if (!enabled) return .{};
        if (!self.armed) {
            self.armed = !held.any();
            return .{};
        }
        var result: Controls = .{ .held_reveal = held.confirm or held.triangle };
        inline for (comptime @import("std").meta.fieldNames(Buttons)) |name| @field(result.pressed, name) = @field(held, name) and !@field(self.previous, name);
        return result;
    }
};

const audience = @import("opening").audience;
const visual = @import("dice_presentation");
const Entry = @This();
pub const Dialogue = struct {
    phase: enum { allocate, opening, submit, reading, request_close, closing, finished } = .allocate,
    remaining: u8 = 0,
    text: audience.TextState = .{ .pace = 0 },
    current_pace: u8 = 0,
    page_hold_updates: u8 = 0,

    pub fn tick(self: *Dialogue, flow: anytype, packet: visual.Packet, input: Controls, speed: usize, player_name: []const u8) !void {
        if (speed >= packet.entry_layout.pacing.len) return error.InvalidDiceTextSpeed;
        switch (self.phase) {
            .allocate => {
                self.phase = .opening;
                self.remaining = packet.entry_layout.transition_ticks;
            },
            .opening => if (self.remaining == 0) {
                self.phase = .submit;
            } else {
                self.remaining -= 1;
            },
            .submit => {
                const message = try flow.textFor(packet);
                self.current_pace = packet.entry_layout.pacing[speed].normal;
                self.text = audience.TextState.start(message, self.current_pace);
                self.phase = .reading;
            },
            .reading => {
                // Glyphs run before this update's reveal/page input callback.
                try self.text.tick(try flow.textFor(packet), player_name);
                const buttons = input.pressed;
                const face_press = buttons.confirm or buttons.cancel or buttons.triangle or buttons.square;
                if (self.text.page_wait) {
                    if (face_press) {
                        self.text.acknowledge();
                    } else if (input.held_reveal) {
                        self.page_hold_updates +%= 1;
                        if (self.page_hold_updates >= 31) {
                            self.text.acknowledge();
                            self.page_hold_updates = 0;
                        }
                    }
                } else if (!self.text.done) {
                    const pacing = packet.entry_layout.pacing[speed];
                    if (face_press and self.current_pace != pacing.pressed) {
                        self.current_pace = pacing.pressed;
                        self.text.fast = true;
                    } else self.current_pace = pacing.normal;
                }
                if (self.text.done and !flow.text_ready) try flow.update(.text_ready);
                const count = @as(u8, @intFromBool(buttons.confirm)) + @intFromBool(buttons.cancel) + @intFromBool(buttons.triangle) + @intFromBool(buttons.square) +
                    (if (!flow.acceptsDirections()) @as(u8, 0) else @as(u8, @intFromBool(buttons.up)) + @intFromBool(buttons.down));
                if (count == 1) {
                    if (buttons.confirm) try flow.update(.confirm) else if (buttons.cancel) try flow.update(.cancel) else if (flow.acceptsDirections()) {
                        if (buttons.up) try flow.update(.up) else if (buttons.down) try flow.update(.down);
                    }
                }
                if (flow.close_requested and flow.text_ready) self.phase = .request_close;
            },
            .request_close => {
                self.remaining = packet.entry_layout.transition_ticks;
                self.phase = .closing;
            },
            .closing => if (self.remaining == 0) {
                try flow.update(.text_closed);
                self.* = .{ .phase = if (flow.finished()) .finished else .allocate };
            } else {
                self.remaining -= 1;
            },
            .finished => {},
        }
    }

    pub fn outline(self: Dialogue, packet: visual.Packet) ?visual.Rectangle {
        if (self.phase != .opening and self.phase != .closing) return null;
        const rect = packet.entry_layout.box;
        const duration: i32 = packet.entry_layout.transition_ticks;
        const elapsed: i32 = if (self.phase == .opening) duration - self.remaining else self.remaining;
        return .{ .x = 160 + @divTrunc((@as(i32, rect.x) - 160) * elapsed, duration), .y = 120 + @divTrunc((@as(i32, rect.y) - 120) * elapsed, duration), .width = @divTrunc(@as(i32, rect.width) * elapsed, duration), .height = @divTrunc(@as(i32, rect.height) * elapsed, duration) };
    }
};

pub fn messageFor(packet: visual.Packet, message: Message) !audience.Text {
    return switch (message) {
        .rules_question => packet.entry_messages.rules_question,
        .rules => packet.entry_messages.rules,
        .fixed_notice => packet.entry_messages.fixed_notice,
        .ready => error.DiceEntryComplete,
    };
}
