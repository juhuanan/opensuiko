//! Decoded dice model and its source orthographic screen transform.
const std = @import("std");
const camera = @import("battle_camera");
const audience = @import("opening_audience");

pub const path = "dice/presentation.json";
pub const texture_path = "dice/faces.png";
pub const portrait_texture_path = "dice/portraits.png";
pub const Rectangle = struct { x: i32, y: i32, width: i32, height: i32 };
pub const Cursor = struct { x: i16, y: i16 };
pub const Pose = struct { center_x: i16, center_y: i16, angles: [3]i16 };
pub const Point = struct { x: i16, y: i16, depth: i16 };
pub const Mesh = struct { points: [8]Point, depth_keys: [6]i16 };
pub const Quad = struct { die: u2, face: u3, points: [4]Point, depth_key: i16 };
pub const Face = struct { id: u3, x: u8, y: u8, width: u8, height: u8, vertices: [4]u3 };
pub const Portrait = struct { role: enum { opponent, hero }, x: i32, y: i32, width: i32, height: i32, screen: Rectangle, mirror: bool, depth_key: u8 };
pub const ResultTexts = struct {
    player_hands: [6]audience.Text,
    dealer_hands: [6]audience.Text,
    escaped: audience.Text,
    straight_receive: audience.Text,
    straight_pay: audience.Text,
    storm_pay: audience.Text,
    storm_receive: audience.Text,
    zero_score: audience.Text,
    player_turn: audience.Text,
    dealer_turn: audience.Text,
    farewell: audience.Text,
    player_win: audience.Text,
    dealer_win: audience.Text,
    draw: audience.Text,
    bankrupt: audience.Text,
    tie_notice: audience.Text,
    player_straight_pay: audience.Text,
    player_straight_receive: audience.Text,
};
pub const Packet = struct {
    schema: []const u8,
    faces: [6]Face,
    model: struct { vertices: [8][3]i16, coordinate_divisor: i16, depth_origin: i16 },
    initial_poses: [3]Pose,
    portraits: [2]Portrait,
    settled_angles: [6][3]i16,
    entry_messages: struct { rules_question: audience.Text, rules: audience.Text, fixed_notice: audience.Text },

    result_messages: ResultTexts,
    hud: struct { box: Rectangle, bet_label: []const u8, money_label: []const u8, number_columns: u8 },
    cursor: struct { offsets: [4][2]i16, colors: [4][3]u8 },

    entry_layout: struct {
        box: Rectangle,
        transition_ticks: u8,
        choices: struct { x: i32, y: i32, width: i32, height: i32, text: []const u8 },
        pacing: [3]struct { normal: u8, pressed: u8 },
    },

    pub fn validate(self: Packet) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-dice-presentation/8") or
            self.model.coordinate_divisor != 10 or self.model.depth_origin != 200) return error.InvalidDiceModel;
        if (self.hud.box.x != 170 or self.hud.box.y != 190 or self.hud.box.width != 112 or self.hud.box.height != 24 or
            self.hud.number_columns != 6 or !std.mem.eql(u8, self.hud.bet_label, "BET     ") or !std.mem.eql(u8, self.hud.money_label, "MONEY   ") or
            !std.meta.eql(self.cursor.offsets, [4][2]i16{ .{ 0, 0 }, .{ 0, 0 }, .{ -6, 8 }, .{ 6, 8 } }) or
            !std.meta.eql(self.cursor.colors, [4][3]u8{ .{ 255, 0, 0 }, .{ 255, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 } })) return error.InvalidDiceHud;
        for (self.portraits, 0..) |portrait, i| {
            if (@backingInt(portrait.role) != i or portrait.x != i * 64 or portrait.y != 0 or portrait.width != 64 or portrait.height != 64 or
                portrait.screen.x != 4 or portrait.screen.y != 23 + i * 140 or portrait.screen.width != 64 or portrait.screen.height != 64 or
                !portrait.mirror or portrait.depth_key != 1) return error.InvalidDicePortrait;
        }
        const layout = self.entry_layout;
        if (layout.box.x != 82 or layout.box.y != 34 or layout.box.width != 240 or layout.box.height != 48 or
            layout.transition_ticks != 14 or layout.choices.x != 80 or layout.choices.y != 190 or layout.choices.width != 40 or layout.choices.height != 24 or
            !std.mem.eql(u8, layout.choices.text, " YES\n NO")) return error.InvalidDiceEntryLayout;
        for (layout.pacing, 0..) |pace, i| if (pace.normal != i * 2 + 1 or pace.pressed != i) return error.InvalidDiceEntryLayout;
        for (self.texts()) |message| {
            if (message.id.len == 0 or message.tokens.len == 0 or message.tokens.len > 901) return error.InvalidDiceEntryText;
            for (message.tokens) |token| switch (token.kind) {
                .glyph => {
                    const text = token.text orelse return error.InvalidDiceEntryText;
                    if (text.len == 0 or text.len > 2 or token.value != null) return error.InvalidDiceEntryText;
                    for (text) |byte| if (byte < 32 or byte > 126) return error.InvalidDiceEntryText;
                },
                .newline, .page, .player_name => if (token.text != null or token.value != null) return error.InvalidDiceEntryText,
                else => return error.InvalidDiceEntryText,
            };
        }
        for (self.faces, 0..) |face, i| {
            if (face.id != i + 1 or face.x != i * 16 or face.y != 0 or face.width != 16 or face.height != 16) return error.InvalidDiceFace;
            for (face.vertices, 0..) |vertex, j| {
                for (face.vertices[0..j]) |prior| if (prior == vertex) return error.InvalidDiceFace;
            }
        }
    }

    pub fn formatHud(self: Packet, buffer: []u8, wager: u32, balance: u32) ![]const u8 {
        // The source number helper displays the final six decimal cells.
        return std.fmt.bufPrint(buffer, "{s}{d: >6}\n{s}{d: >6}", .{ self.hud.bet_label, wager % 1_000_000, self.hud.money_label, balance % 1_000_000 });
    }

    pub fn cursorVertices(self: Packet, position: Cursor) [4]Cursor {
        var vertices: [4]Cursor = undefined;
        for (self.cursor.offsets, 0..) |offset, i| vertices[i] = .{ .x = position.x +% offset[0], .y = position.y +% offset[1] };
        return vertices;
    }

    pub fn texts(self: Packet) [31]audience.Text {
        return .{ self.entry_messages.rules_question, self.entry_messages.rules, self.entry_messages.fixed_notice } ++
            self.result_messages.player_hands ++ self.result_messages.dealer_hands ++ .{
            self.result_messages.escaped,
            self.result_messages.straight_receive,
            self.result_messages.straight_pay,
            self.result_messages.storm_pay,
            self.result_messages.storm_receive,
            self.result_messages.zero_score,
            self.result_messages.player_turn,
            self.result_messages.dealer_turn,
            self.result_messages.farewell,
            self.result_messages.player_win,
            self.result_messages.dealer_win,
            self.result_messages.draw,
            self.result_messages.bankrupt,
            self.result_messages.tie_notice,
            self.result_messages.player_straight_pay,
            self.result_messages.player_straight_receive,
        };
    }

    pub fn project(self: Packet, pose: Pose) Mesh {
        const rotation = camera.rotationMatrix(.{ pose.angles[0], pose.angles[1], pose.angles[2] });
        var mesh: Mesh = undefined;
        for (self.model.vertices, 0..) |vertex, index| {
            var rotated: [3]i16 = undefined;
            for (0..3) |axis| {
                var sum: i64 = 0;
                for (0..3) |component| sum += @as(i64, rotation[axis * 3 + component]) * vertex[component];
                rotated[axis] = wrap16(sum >> 12);
            }
            mesh.points[index] = .{
                .x = wrap16(@as(i32, pose.center_x) + @divTrunc(rotated[0], self.model.coordinate_divisor)),
                .y = wrap16(@as(i32, pose.center_y) + @divTrunc(rotated[1], self.model.coordinate_divisor)),
                .depth = wrap16(@as(i32, self.model.depth_origin) + @divTrunc(rotated[2], self.model.coordinate_divisor)),
            };
        }
        for (self.faces, 0..) |face, i| {
            var depth = mesh.points[face.vertices[0]].depth;
            for (face.vertices[1..]) |vertex| depth = @min(depth, mesh.points[vertex].depth);
            mesh.depth_keys[i] = depth;
        }
        return mesh;
    }

    pub fn drawList(self: Packet, poses: [3]Pose) [18]Quad {
        var quads: [18]Quad = undefined;
        for (poses, 0..) |pose, die| {
            const mesh = self.project(pose);
            for (self.faces, 0..) |face, index| {
                var points: [4]Point = undefined;
                for (face.vertices, 0..) |vertex, corner| points[corner] = mesh.points[vertex];
                quads[die * 6 + index] = .{ .die = @intCast(die), .face = @intCast(index), .points = points, .depth_key = mesh.depth_keys[index] };
            }
        }
        std.mem.sort(Quad, &quads, {}, struct {
            fn before(_: void, a: Quad, b: Quad) bool {
                if (a.depth_key != b.depth_key) return a.depth_key > b.depth_key;
                if (a.die != b.die) return a.die > b.die;
                return a.face > b.face;
            }
        }.before);
        return quads;
    }
};

pub fn validateAtlas(width: i32, height: i32) !void {
    if (width != 96 or height != 16) return error.InvalidDiceAtlas;
}

pub fn validatePortraitAtlas(width: i32, height: i32) !void {
    if (width != 128 or height != 64) return error.InvalidDicePortraitAtlas;
}

fn wrap16(value: i64) i16 {
    return @bitCast(@as(u16, @truncate(@as(u64, @bitCast(value)))));
}

pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Packet) {
    if (bytes.len > 128 * 1024) return error.DiceModelTooLarge;
    const parsed = try std.json.parseFromSlice(Packet, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

const Phase = enum { flight, orbit, holding, escaping };
const Die = struct {
    pose: Pose,
    position_tenths: [2]i16,
    velocity_tenths: [2]i16,
    spin_rate: i16,
    orbit_angle: i16 = 0,
    phase: Phase = .flight,
};
pub const RollStart = struct {
    poses: [3]Pose,
    pips: [3]u8,
    target_x: i16,
    target_y: i16,
    strength: u16,
    escaped: bool = false,
};
pub const Frame = struct { poses: [3]Pose, landed: [3]bool = @splat(false), complete: bool = false };

pub const Animation = struct {
    dice: [3]Die,
    pips: [3]u8,
    settled_angles: [6][3]i16,
    target_x: i16,
    escaped: bool,
    angle_step: i16 = 150,
    radius_pixels: i16 = 16,
    wait_ticks: u8 = 0,
    escape_ticks: u8 = 0,
    complete: bool = false,

    pub fn init(packet: Packet, start: RollStart) !Animation {
        try packet.validate();
        if (start.strength < 32 or start.strength > 96 or start.strength % 4 != 0) return error.InvalidDiceStrength;
        if (start.escaped and start.target_x >= 144 and start.target_x <= 176) return error.InvalidDiceEscape;
        for (start.pips) |pip| if (pip < 1 or pip > 6) return error.InvalidDieFace;
        var result: Animation = .{ .dice = undefined, .pips = start.pips, .settled_angles = packet.settled_angles, .target_x = start.target_x, .escaped = start.escaped };
        const flight_updates = [3]i32{ 20, 40, 30 };
        const horizontal_divisors = [3]i16{ 2, 4, 3 };
        for (start.poses, 0..) |pose, i| {
            const frames = flight_updates[i];
            const dx = wrap16(@as(i32, pose.center_x) - start.target_x);
            const dy = wrap16(@as(i32, start.target_y) - pose.center_y);
            const fall = @divTrunc(3 * frames * (frames + 1), 2);
            result.dice[i] = .{
                .pose = pose,
                .position_tenths = .{ wrap16(@as(i32, pose.center_x) * 10), wrap16(@as(i32, pose.center_y) * 10) },
                .velocity_tenths = .{ -@divTrunc(dx, horizontal_divisors[i]), @intCast(@divTrunc(@as(i32, wrap16(@as(i32, dy) * 10 - fall)), frames)) },
                .spin_rate = @intCast(start.strength),
            };
        }
        return result;
    }

    pub fn poses(self: Animation) [3]Pose {
        return .{ self.dice[0].pose, self.dice[1].pose, self.dice[2].pose };
    }

    fn advancePosition(die: *Die) void {
        die.position_tenths[0] +%= die.velocity_tenths[0];
        die.pose.center_x = @divTrunc(die.position_tenths[0], 10);
        die.velocity_tenths[1] +%= 3;
        die.position_tenths[1] +%= die.velocity_tenths[1];
        die.pose.center_y = @divTrunc(die.position_tenths[1], 10);
    }

    fn settleFace(self: *Animation, index: usize) void {
        self.dice[index].spin_rate = 0;
        self.dice[index].pose.angles = self.settled_angles[self.pips[index] - 1];
    }

    pub fn tick(self: *Animation) Frame {
        if (self.complete) return .{ .poses = self.poses(), .complete = true };
        for (&self.dice, 0..) |*die, i| {
            spin(&die.pose, die.spin_rate, i);
        }
        // The source draws after spin and before this update's position changes.
        var frame: Frame = .{ .poses = self.poses() };
        for (&self.dice, 0..) |*die, i| switch (die.phase) {
            .flight => {
                if (self.target_x > 176 and @as(i32, die.pose.center_x) < @as(i32, self.target_x) + 8) {
                    if (i == 0 and self.escaped) {
                        die.velocity_tenths = .{ -80, -40 };
                        die.phase = .escaping;
                        self.escape_ticks = 0;
                    } else die.velocity_tenths[0] -%= 20;
                } else if (self.target_x < 144 and @as(i32, die.pose.center_x) < @as(i32, self.target_x) + 8) {
                    if (i == 0 and self.escaped) {
                        die.velocity_tenths[1] = -40;
                        die.phase = .escaping;
                        self.escape_ticks = 0;
                    } else die.velocity_tenths[0] = -%die.velocity_tenths[0];
                }
                advancePosition(die);
                if (die.pose.center_y >= 145) {
                    frame.landed[i] = true;
                    die.phase = .orbit;
                    self.wait_ticks = 40;
                    die.orbit_angle = switch (i) {
                        0 => 2048,
                        1 => if (self.escaped) self.dice[2].orbit_angle +% 2048 else self.dice[0].orbit_angle +% 2730,
                        else => self.dice[0].orbit_angle +% 1365,
                    };
                }
            },
            .orbit => {
                if (i == 1) {
                    if (self.wait_ticks == 0) self.angle_step -%= 2 else self.wait_ticks -= 1;
                }
                die.orbit_angle +%= self.angle_step;
                const rotation = camera.rotationMatrix(.{ 0, 0, die.orbit_angle });
                die.pose.center_x = wrap16(160 + ((@as(i64, rotation[0]) * self.radius_pixels) >> 12));
                die.pose.center_y = wrap16(136 + ((@as(i64, rotation[3]) * self.radius_pixels) >> 12));
                if (self.angle_step < 75 and self.dice[0].spin_rate != 0) {
                    self.settleFace(0);
                    self.radius_pixels -%= 1;
                }
                if (self.angle_step < 45 and self.dice[1].spin_rate != 0) {
                    self.settleFace(1);
                    self.radius_pixels -%= 1;
                }
                if (self.angle_step < 16) {
                    self.settleFace(2);
                    for (&self.dice) |*other| other.phase = .holding;
                }
            },
            .holding => {
                for (&self.dice) |*other| other.phase = .holding;
                if (i == 2) {
                    self.wait_ticks +%= 1;
                    self.complete = self.wait_ticks == 100;
                }
            },
            .escaping => {
                advancePosition(die);
                self.escape_ticks +%= 1;
            },
        };
        frame.complete = self.complete;
        return frame;
    }
};

pub fn spin(pose: *Pose, rate: i16, die: usize) void {
    const delta: [2]i16 = switch (die) {
        0 => .{ rate *% 2, rate },
        1 => .{ -%rate, -%(rate *% 2) },
        else => .{ rate *% 3, @divTrunc(rate, 2) },
    };
    pose.angles[0] +%= delta[0];
    pose.angles[1] +%= delta[1];
}
