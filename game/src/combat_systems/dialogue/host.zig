//! Scene host: the production/consumption order around the text engine.
//!
//! One frame runs the event command first, then the box/widget pass, then the
//! staged-body install, then the reveal/ack pass. That order is what makes a
//! body staged during the event tick draw its first glyph on the next eligible
//! update while the event VM stays gated. The host keeps a plain copyable state
//! so a mid-page restore cannot acknowledge a page, advance the script or drop a
//! pending body.

const std = @import("std");
const model = @import("model.zig");
const text = @import("text.zig");

pub const Input = struct {
    /// Raw source button word. Text ack/reveal tests 0x0065, a scene accept
    /// tests 0x0041, and the choice handler compares the masked 0x5041 value.
    mask: u16 = 0,
    /// Port-level cancel. The source choice handler has no cancel arm; the host
    /// reports it as ignored and leaves the choice open.
    cancel: bool = false,
};

pub const Emission = struct {
    speaker: ?u8 = null,
    page_acked: bool = false,
    choice: ?u8 = null,
    cancel_ignored: bool = false,
    completed: bool = false,
    installed: bool = false,
};

pub const Resources = struct {
    custom: []const u8 = &.{},
    party: []const u8 = &.{},

    pub fn has(self: Resources, code: u8) bool {
        for (self.custom) |entry| if (entry == code) return true;
        for (self.party) |entry| if (entry == code) return true;
        return false;
    }
};

pub const Point = struct { x: i32 = -124, y: i32 = 38 };

pub const Phase = enum { closed, opening, open, closing };

pub const Box = struct {
    phase: Phase = .closed,
    transition: u8 = 0,
    origin: Point = .{},
    speaker_code: ?u8 = null,
    name: [32]u8 = @splat(0),
    name_len: u8 = 0,
    prefix_visible: u8 = 0,
    prefix_done: bool = true,
    image_presence: u8 = 0,
    text: text.Engine = .{},

    pub fn open(self: *Box, duration: u8) void {
        self.phase = .opening;
        self.transition = duration;
    }

    pub fn close(self: *Box, duration: u8) void {
        self.phase = .closing;
        self.transition = duration;
        self.image_presence = 0; // source close clears the presence byte
    }

    pub fn tickTransition(self: *Box) void {
        if (self.phase != .opening and self.phase != .closing) return;
        if (self.transition == 0) {
            self.phase = if (self.phase == .opening) .open else .closed;
        } else {
            self.transition -= 1;
        }
    }

    pub fn tickPrefix(self: *Box) void {
        if (self.prefix_done) return;
        if (self.prefix_visible < 255) self.prefix_visible += 1;
        if (self.prefix_visible > self.name_len) self.prefix_done = true;
    }

    pub fn visibleName(self: *const Box) []const u8 {
        const shown = @min(self.prefix_visible, self.name_len);
        return self.name[0..shown];
    }

    /// Source 0x8013FB58/0x8013FA40: code 8 and codes at or above 125 skip the
    /// name prefix, codes below 125 use the name-index search, and the image
    /// lookup sets the slot+1 presence when a custom or loaded-party resource
    /// matches. A no-match leaves presence at 0 without inventing a portrait.
    pub fn beginSpeaker(self: *Box, pipeline: *const model.Pipeline, code: u8, slot: u8, resources: Resources) !void {
        if (code == 0) return error.NullSpeakerCode;
        if (slot >= 2) return error.InvalidBox;
        self.speaker_code = code;
        self.prefix_visible = 0;
        if (code == 8 or code >= pipeline.names.skip_at_or_above) {
            self.name_len = 0;
            self.prefix_done = true;
        } else {
            const name = try pipeline.nameForCode(code) orelse return error.UnknownSpeakerCode;
            if (name.len == 0 or name.len > self.name.len) return error.UnknownSpeakerCode;
            @memset(&self.name, 0);
            @memcpy(self.name[0..name.len], name);
            self.name_len = @intCast(name.len);
            self.prefix_done = false;
        }
        self.image_presence = if (resources.has(code)) slot + 1 else 0;
    }
};

/// Source 0x80144830: (from*k + to*(duration-k)) / duration with integer
/// truncation. The caller decrements k from duration to 0.
pub fn interpolate(from: u8, to: u8, k: u8, duration: u8) u8 {
    if (duration == 0) return to;
    const a: u16 = from;
    const b: u16 = to;
    const remaining: u16 = k;
    const span: u16 = duration;
    return @intCast((a * remaining + b * (span - remaining)) / span);
}

pub const ChoiceState = struct {
    top: u8,
    options: u8,
    state: u8,
    duration: u8,
    from: u8,
    to: u8,
    remaining: u8,
    moving: bool = false,

    pub fn start(top: u8, options: u8, duration: u8) ChoiceState {
        return .{
            .top = top,
            .options = options,
            .state = top,
            .duration = duration,
            .from = top,
            .to = top,
            .remaining = duration,
        };
    }

    pub fn position(self: ChoiceState) u8 {
        if (!self.moving) return self.state;
        return interpolate(self.from, self.to, self.remaining, self.duration);
    }

    pub fn select(self: *ChoiceState, row: u8) void {
        if (row < self.top or row >= self.top + self.options) return;
        if (row == self.state) return;
        const current = self.position();
        self.from = current;
        self.to = row;
        self.state = row;
        self.remaining = self.duration;
        self.moving = true;
    }

    pub fn previous(self: *ChoiceState) void {
        const row = if (self.state == self.top) self.top + self.options - 1 else self.state - 1;
        self.select(row);
    }

    pub fn next(self: *ChoiceState) void {
        const row = if (self.state + 1 >= self.top + self.options) self.top else self.state + 1;
        self.select(row);
    }

    pub fn tick(self: *ChoiceState) void {
        if (!self.moving) return;
        if (self.remaining == 0) {
            self.moving = false;
            return;
        }
        self.remaining -= 1;
        if (self.remaining == 0) self.moving = false;
    }
};

pub const Host = struct {
    content_sha: [32]u8 = @splat(0),
    scene_index: u8 = 0,
    cursor: u16 = 0,
    boxes: [2]Box = .{ .{}, .{} },
    choice: ?ChoiceState = null,
    choice_height: u8 = 1,
    pending: [text.max_body]u8 = @splat(0),
    pending_len: u16 = 0,
    pending_text: u8 = 0,
    pending_box: u8 = 0,
    has_pending: bool = false,
    finished: bool = false,
    state_byte: u8 = 0,
    frame_count: u32 = 0,
    speaker_started: bool = false,
    speaker_box: u8 = 0,
    active_text: u8 = 0,
    resources: Resources = .{},
    player_name_bytes: [8]u8 = @splat(0),
    player_name_len: u8 = 0,
    castle_name_bytes: [8]u8 = @splat(0),
    castle_name_len: u8 = 0,

    pub fn init(pipeline: *const model.Pipeline, scene_index: u8, content_sha: [32]u8) !Host {
        if (scene_index >= pipeline.scenes.len) return error.UnknownScene;
        var host = Host{};
        host.content_sha = content_sha;
        host.scene_index = scene_index;
        const player = try text.encodeAscii(pipeline.substitutions.player_name, &host.player_name_bytes);
        host.player_name_len = @intCast(player.len);
        const castle = try text.encodeAscii(pipeline.substitutions.castle_name, &host.castle_name_bytes);
        host.castle_name_len = @intCast(castle.len);
        return host;
    }

    pub fn scene(self: *const Host, pipeline: *const model.Pipeline) *const model.Scene {
        return &pipeline.scenes[self.scene_index];
    }

    pub fn activeTextBox(self: *const Host) ?usize {
        for (self.boxes, 0..) |box, index| {
            if (box.text.len > 0 and !box.text.done) return index;
        }
        return null;
    }

    fn vmBlocked(self: *const Host) bool {
        return self.has_pending or self.activeTextBox() != null or self.choice != null or self.finished;
    }

    pub fn frame(self: *Host, pipeline: *const model.Pipeline, input: Input) !Emission {
        var emission = Emission{};
        if (self.finished) return emission;
        const current = self.scene(pipeline);
        if (self.cursor > current.commands.len) return error.InvalidCursor;

        // 1. Event command or choice input.
        if (self.choice) |*choice| {
            try self.choiceInput(pipeline, choice, input, &emission);
            // choiceInput clears the optional on commit; do not keep using the
            // payload pointer after that.
            if (self.choice) |*remaining| remaining.tick();
        } else if (!self.vmBlocked()) {
            try self.execute(pipeline, current, input, &emission);
        }

        // 2. Box/widget pass (transitions, prefix, installed body).
        for (&self.boxes) |*box| {
            box.tickTransition();
            if (box.phase != .open) continue;
            box.tickPrefix();
            if (!box.text.done) try box.text.tick(pipeline, self.substitutions(pipeline));
        }

        // 3. Staged body installs after the glyph pass.
        if (self.has_pending) try self.installPending(pipeline, &emission);

        // 4. Reveal/acknowledge pass.
        if (self.activeTextBox()) |index| {
            const ack = self.boxes[index].text.acknowledge(pipeline, input.mask);
            if (ack == .page) emission.page_acked = true;
        }

        self.frame_count +%= 1;
        return emission;
    }

    fn substitutions(self: *const Host, pipeline: *const model.Pipeline) text.Substitutions {
        _ = pipeline;
        return .{
            .player_name = self.player_name_bytes[0..self.player_name_len],
            .castle_name = self.castle_name_bytes[0..self.castle_name_len],
        };
    }

    fn execute(self: *Host, pipeline: *const model.Pipeline, current: *const model.Scene, input: Input, emission: *Emission) !void {
        if (self.cursor >= current.commands.len) {
            self.finished = true;
            return;
        }
        const command = current.commands[self.cursor];
        const kind = try model.commandKind(command);
        switch (kind) {
            .open_box => {
                const slot = command.box.?;
                if (self.boxes[slot].phase == .closed) {
                    self.boxes[slot].open(pipeline.box.open_close_duration);
                    return; // the source open opcode rewinds until the box is live
                }
                if (self.boxes[slot].phase != .open) return;
                self.cursor += 1;
            },
            .speaker => {
                const slot = command.box.?;
                const code = command.code.?;
                if (!self.speaker_started) {
                    try self.boxes[slot].beginSpeaker(pipeline, code, slot, self.resources);
                    self.speaker_started = true;
                    self.speaker_box = slot;
                    emission.speaker = code;
                    return; // source rewinds once while the slot becomes active
                }
                if (!self.boxes[slot].prefix_done) return;
                self.speaker_started = false;
                self.cursor += 1;
            },
            .text => {
                const slot = command.box.?;
                const index = command.text.?;
                if (self.has_pending or self.activeTextBox() != null) return error.TextStageBusy;
                if (self.boxes[slot].phase != .open) return error.BoxNotOpen;
                const spec = current.texts[index];
                const decoded = try text.decodeHex(spec.bytes_hex, &self.pending);
                self.pending_len = @intCast(decoded.len);
                self.pending_text = index;
                self.pending_box = slot;
                self.active_text = index;
                self.has_pending = true;
                self.cursor += 1;
            },
            .wait_confirm => {
                if (input.mask & 0x41 == 0) return;
                self.cursor += 1;
            },
            .close_box => {
                const slot = command.box.?;
                if (self.has_pending or self.activeTextBox() != null) return error.CloseDuringText;
                self.boxes[slot].close(pipeline.box.open_close_duration);
                self.cursor += 1;
            },
            .wait_boxes => {
                for (self.boxes) |box| if (box.phase != .closed) return;
                self.cursor += 1;
            },
            .choice => {
                if (self.choice != null) return;
                const top_operand = command.top.?;
                const top = top_operand & 0x7F;
                self.choice = ChoiceState.start(top, command.options.?, pipeline.choices.duration);
                self.choice_height = if (top_operand & 0x80 != 0) pipeline.choices.height.bit_set else pipeline.choices.height.bit_clear;
                // The source consumes the operands and rewinds while active; the
                // cursor stays on the command until confirmation consumes the
                // completion byte.
            },
            .branch_choice => {
                if (self.state_byte == command.on.?) {
                    self.cursor = command.target.?;
                } else {
                    self.cursor += 1;
                }
            },
            .jump => self.cursor = command.target.?,
            .label => self.cursor += 1,
            .finish => {
                if (self.has_pending or self.activeTextBox() != null) return;
                for (self.boxes) |box| if (box.phase != .closed) return;
                self.finished = true;
                emission.completed = true;
                self.cursor += 1;
            },
        }
    }

    fn choiceInput(self: *Host, pipeline: *const model.Pipeline, choice: *ChoiceState, input: Input, emission: *Emission) !void {
        if (input.cancel) {
            emission.cancel_ignored = true;
            return;
        }
        const masked = input.mask & pipeline.choices.mask;
        if (masked == pipeline.choices.up) {
            choice.previous();
        } else if (masked == pipeline.choices.down) {
            choice.next();
        } else if (masked == pipeline.choices.confirm[0] or masked == pipeline.choices.confirm[1]) {
            self.state_byte = choice.state;
            emission.choice = choice.state;
            self.choice = null;
            self.cursor += 1; // the source consumes one completion byte
        }
    }

    fn installPending(self: *Host, pipeline: *const model.Pipeline, emission: *Emission) !void {
        const box = &self.boxes[self.pending_box];
        if (box.phase != .open) return error.PendingBoxClosed;
        try box.text.begin(
            self.pending[0..self.pending_len],
            pipeline.pacing.default_normal,
            pipeline.pacing.default_pressed,
        );
        self.has_pending = false;
        self.pending_len = 0;
        emission.installed = true;
    }

    pub const Snapshot = struct {
        content_sha: [32]u8,
        scene_index: u8,
        cursor: u16,
        boxes: [2]Box,
        choice: ?ChoiceState,
        choice_height: u8,
        active_text: u8,
        pending: [text.max_body]u8,
        pending_len: u16,
        pending_text: u8,
        pending_box: u8,
        has_pending: bool,
        finished: bool,
        state_byte: u8,
        frame_count: u32,
        speaker_started: bool,
        speaker_box: u8,
    };

    pub fn snapshot(self: *const Host) Snapshot {
        return .{
            .content_sha = self.content_sha,
            .scene_index = self.scene_index,
            .cursor = self.cursor,
            .boxes = self.boxes,
            .choice = self.choice,
            .choice_height = self.choice_height,
            .active_text = self.active_text,
            .pending = self.pending,
            .pending_len = self.pending_len,
            .pending_text = self.pending_text,
            .pending_box = self.pending_box,
            .has_pending = self.has_pending,
            .finished = self.finished,
            .state_byte = self.state_byte,
            .frame_count = self.frame_count,
            .speaker_started = self.speaker_started,
            .speaker_box = self.speaker_box,
        };
    }

    /// Restore is a validation gate plus a plain copy. It performs no input, no
    /// acknowledgement and no staging, so a mid-page snapshot stays mid-page.
    pub fn restore(self: *Host, pipeline: *const model.Pipeline, saved: Snapshot) !void {
        if (!std.mem.eql(u8, self.content_sha[0..], saved.content_sha[0..])) return error.ContentMismatch;
        if (saved.scene_index != self.scene_index) return error.SceneMismatch;
        if (saved.scene_index >= pipeline.scenes.len) return error.UnknownScene;
        const current = &pipeline.scenes[saved.scene_index];
        if (saved.cursor > current.commands.len) return error.InvalidCursor;
        if (saved.choice_height != 1 and saved.choice_height != 2) return error.InvalidSnapshot;
        if (saved.has_pending) {
            if (saved.pending_len == 0 or saved.pending_len > text.max_body) return error.InvalidSnapshot;
            if (saved.pending_text >= current.texts.len or saved.pending_box >= 2) return error.InvalidSnapshot;
            if (saved.boxes[saved.pending_box].phase != .open) return error.InvalidSnapshot;
        } else if (saved.pending_len != 0) return error.InvalidSnapshot;
        for (saved.boxes) |box| {
            if (box.name_len > box.name.len) return error.InvalidSnapshot;
            if (box.prefix_visible > box.name_len + 1) return error.InvalidSnapshot;
            if (box.name_len == 0 and !box.prefix_done) return error.InvalidSnapshot;
            if (box.image_presence > 2) return error.InvalidSnapshot;
            if (box.phase == .closed and box.image_presence != 0) return error.InvalidSnapshot;
            const engine = box.text;
            if (engine.len > text.max_body or engine.cursor > engine.len) return error.InvalidSnapshot;
            if (engine.len == 0 and !engine.done) return error.InvalidSnapshot;
            if (engine.grid.column > text.max_columns or engine.grid.row >= text.max_rows) return error.InvalidSnapshot;
            if (engine.page_wait and engine.done) return error.InvalidSnapshot;
            var page_count: u16 = 1;
            for (engine.bytes[0..engine.len]) |byte| if (byte == 0x02) {
                page_count += 1;
            };
            if (engine.page_index > page_count) return error.InvalidSnapshot;
        }
        if (saved.choice) |choice| {
            if (choice.options != 2 or choice.duration != pipeline.choices.duration) return error.InvalidSnapshot;
            if (choice.top + choice.options > pipeline.grid.rows) return error.InvalidSnapshot;
            if (choice.state < choice.top or choice.state >= choice.top + choice.options) return error.InvalidSnapshot;
            if (choice.remaining > choice.duration) return error.InvalidSnapshot;
            if (choice.moving and choice.duration == 0) return error.InvalidSnapshot;
        }
        if (saved.speaker_started and saved.speaker_box >= 2) return error.InvalidSnapshot;
        if (saved.finished and saved.cursor > current.commands.len) return error.InvalidSnapshot;
        self.content_sha = saved.content_sha;
        self.scene_index = saved.scene_index;
        self.cursor = saved.cursor;
        self.boxes = saved.boxes;
        self.choice = saved.choice;
        self.choice_height = saved.choice_height;
        self.active_text = saved.active_text;
        self.pending = saved.pending;
        self.pending_len = saved.pending_len;
        self.pending_text = saved.pending_text;
        self.pending_box = saved.pending_box;
        self.has_pending = saved.has_pending;
        self.finished = saved.finished;
        self.state_byte = saved.state_byte;
        self.frame_count = saved.frame_count;
        self.speaker_started = saved.speaker_started;
        self.speaker_box = saved.speaker_box;
    }
};
