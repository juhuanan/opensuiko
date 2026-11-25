//! Wheel motion in degrees and game updates; graphics and RNG belong to callers.
const data = @import("wheel_data");

pub const Outcome = data.Outcome;
pub const shadow_variant = data.shadow_variant;
pub const shadow_frame = data.shadow_frame;
pub const shadow_shade = data.shadow_shade;
pub const shadow_crop = data.shadow_crop;
pub const shadow_sheet_size = data.shadow_sheet_size;
pub const shadow_anchor = data.shadow_anchor;
pub const Phase = enum { spinning, restoring, timed };
pub const Sample = struct {
    geometry_angles: [2]u16 = @splat(0),
    geometry_count: u2 = 0,
    logical_angle: u16 = 0,
    recentered: bool = false,

    fn geometry(self: *Sample, angle: u16) void {
        self.geometry_angles[self.geometry_count] = angle;
        self.geometry_count += 1;
    }
};

pub fn outcome(angle: u16) Outcome {
    for (data.intervals) |interval| {
        if (angle >= interval.first_degree and angle <= interval.last_degree) return interval.outcome;
    }
    return .nothing;
}

pub fn consumesExtraDraw(start_count: i16) bool {
    return start_count >= data.extra_draw_from_start;
}

/// Packed sprite anchors relative to the map pivot, before the draw environment.
pub const Visual = struct {
    primary_offset: [2]i16,
    auxiliary_offset: [2]i16,
    map_angle_degrees: u16,
    map_sine_q12: i16,
    map_cosine_q12: i16,
    transformed_map: bool,
};

pub const MapPoint = struct { x: i32, y: i32 };

/// Logical screen anchors retained when the visible wheel suppresses ordinary writes.
pub const ActorGraphics = struct {
    actor: u8,
    primary: MapPoint,
    auxiliary: MapPoint,

    pub fn init(actor: u8, ordinary: MapPoint) ActorGraphics {
        return .{ .actor = actor, .primary = ordinary, .auxiliary = .{ .x = ordinary.x + 2, .y = ordinary.y + data.auxiliary_drop_pixels } };
    }

    pub fn shadowPoints(self: ActorGraphics) [4]MapPoint {
        const x = self.auxiliary.x - data.shadow_anchor[0];
        const y = self.auxiliary.y - data.shadow_anchor[1];
        return .{ .{ .x = x, .y = y }, .{ .x = x + data.shadow_extent[0], .y = y }, .{ .x = x, .y = y + data.shadow_extent[1] }, .{ .x = x + data.shadow_extent[0], .y = y + data.shadow_extent[1] } };
    }

    pub fn advance(self: *ActorGraphics, room: Room, ordinary: MapPoint, vertical_offset: i32) void {
        if (!room.clock.visible or vertical_offset != 0) {
            self.primary = ordinary;
            self.auxiliary = .{ .x = ordinary.x + 2, .y = ordinary.y + data.auxiliary_drop_pixels };
        }
        if (room.sample.geometry_count != 0) {
            const origin = room.visual().primary_offset;
            // The source adds the map pivot and then the draw-environment centre.
            self.primary = .{ .x = origin[0] + @as(i32, data.map_viewport_pixels[0]), .y = origin[1] + @as(i32, data.map_viewport_pixels[1]) };
            self.auxiliary = .{ .x = self.primary.x, .y = self.primary.y + data.auxiliary_drop_pixels };
        }
    }
};

pub const MapFragment = struct {
    source: struct { x: u16, y: u16, w: u16, h: u16 },
    vertices: [4]MapPoint,
};

/// Source viewport pixels; the platform owns camera selection and display scale.
pub const MapProjection = struct {
    pub const viewport_pixels = data.map_viewport_pixels;
    map_size: [2]u16,
    sample_origin: [2]i32,
    sine_q12: i16,
    cosine_q12: i16,

    pub fn init(map_size: [2]u16, sample_origin: [2]i32, angle: u16) !MapProjection {
        for (map_size) |size| if (size == 0 or size > 4096 or size % data.map_tile_pixels != 0) return error.InvalidWheelMap;
        for (sample_origin) |coordinate| if (coordinate < -32768 or coordinate > 32767) return error.InvalidWheelMap;
        if (angle >= data.turn_degrees) return error.InvalidWheelMap;
        const basis = data.rotation_basis_q12[angle];
        return .{ .map_size = map_size, .sample_origin = sample_origin, .sine_q12 = basis[0], .cosine_q12 = basis[1] };
    }

    pub fn project(self: MapProjection, x: i32, y: i32) MapPoint {
        const cx = data.map_viewport_pixels[0] / 2;
        const cy = data.map_viewport_pixels[1] / 2;
        const dx = x - cx;
        const dy = y - cy;
        return .{
            .x = cx + @divFloor(@as(i32, self.cosine_q12) * dx - @as(i32, self.sine_q12) * dy, 4096),
            .y = cy + @divFloor(@as(i32, self.sine_q12) * dx + @as(i32, self.cosine_q12) * dy, 4096),
        };
    }

    pub fn fragments(self: MapProjection) MapFragments {
        return .{ .projection = self };
    }
};

pub const MapFragments = struct {
    projection: MapProjection,
    x: u16 = 0,
    y: u16 = 0,

    pub fn next(self: *MapFragments) ?MapFragment {
        if (self.y >= data.map_viewport_pixels[1]) return null;
        const view = self.projection;
        const sx: u16 = @intCast(@mod(view.sample_origin[0] + self.x, view.map_size[0]));
        const sy: u16 = @intCast(@mod(view.sample_origin[1] + self.y, view.map_size[1]));
        const w = @min(data.map_tile_pixels - sx % data.map_tile_pixels, data.map_viewport_pixels[0] - self.x);
        const h = @min(data.map_tile_pixels - sy % data.map_tile_pixels, data.map_viewport_pixels[1] - self.y);
        const result: MapFragment = .{
            .source = .{ .x = sx, .y = sy, .w = w, .h = h },
            .vertices = .{ view.project(self.x, self.y), view.project(self.x + w, self.y), view.project(self.x, self.y + h), view.project(self.x + w, self.y + h) },
        };
        self.x += w;
        if (self.x == data.map_viewport_pixels[0]) {
            self.x = 0;
            self.y += h;
        }
        return result;
    }
};

pub const State = struct {
    angle: u16 = 0,
    turns: u16 = 0,
    speed: u8 = 0,
    distance: i16 = 0,
    slowdown: u8 = 0,
    phase: ?Phase = null,
    visible: bool = false,
    timed_updates: u16 = 0,
    alignment: ?struct { remaining: u16, forward: bool } = null,
    result: ?Outcome = null,

    pub fn start(self: *State, roll: u15) void {
        self.angle = 0;
        self.turns = 0;
        self.speed = data.initial_speed;
        self.distance = data.initial_distance + @as(i16, @intCast(roll / data.random_divisor));
        self.slowdown = 0;
        self.timed_updates = 0;
        self.phase = .spinning;
        self.visible = true;
        self.result = null;
    }

    pub fn restore(self: *State) void {
        self.phase = .restoring;
    }

    pub fn turnFor(self: *State, updates: u8) void {
        self.angle = 0;
        self.turns = 0;
        self.slowdown = 0;
        self.visible = true;
        self.phase = .timed;
        self.timed_updates = @max(1, @as(u16, updates));
    }

    pub fn alignToCenter(self: *State) void {
        const forward = self.angle < data.alignment_angle;
        self.alignment = .{
            .forward = forward,
            .remaining = if (forward) data.alignment_angle - self.angle else self.angle - data.alignment_angle,
        };
    }

    pub fn advance(self: *State) Sample {
        var sample: Sample = .{};
        if (self.alignment) |*alignment| {
            if (alignment.remaining == 0) {
                self.alignment = null;
            } else {
                alignment.remaining -= 1;
                self.angle = if (alignment.forward) self.angle +% 1 else self.angle -% 1;
                sample.geometry(self.angle);
            }
        }
        if (self.phase) |phase| switch (phase) {
            .spinning => {
                sample.geometry(self.angle);
                self.angle +%= self.speed;
                self.distance -%= self.speed;
                if (self.distance < data.slowdown_below) {
                    self.slowdown +%= self.speed;
                    if (self.slowdown >= data.slowdown_threshold) {
                        self.slowdown = 0;
                        self.speed -= 1;
                    }
                }
                if (self.speed == 0) {
                    self.result = outcome(self.angle);
                    self.phase = null;
                } else if (self.angle >= data.turn_degrees) {
                    self.angle = 0;
                    self.turns +%= 1;
                }
            },
            .restoring => {
                self.angle +%= data.continued_speed;
                sample.geometry(self.angle);
                if (self.angle >= data.turn_degrees) {
                    self.angle = 0;
                    self.visible = false;
                    self.phase = null;
                    sample.recentered = true;
                }
            },
            .timed => {
                self.angle +%= data.continued_speed;
                self.timed_updates -= 1;
                if (self.timed_updates == 0) self.phase = null;
            },
        };
        sample.logical_angle = self.angle;
        return sample;
    }
};

/// Lives for one room visit, independently of each event interaction.
pub const Room = struct {
    starts: i16 = 0,
    clock: State = .{},
    geometry_angle: u16 = 0,
    map_angle: u16 = 0,
    sample: Sample = .{},

    pub fn visual(self: Room) Visual {
        const primary = data.orbit_offsets[self.geometry_angle % data.turn_degrees];
        const basis = data.rotation_basis_q12[self.map_angle % data.turn_degrees];
        return .{
            .primary_offset = primary,
            .auxiliary_offset = .{ primary[0], primary[1] + data.auxiliary_drop_pixels },
            .map_angle_degrees = self.map_angle,
            .map_sine_q12 = basis[0],
            .map_cosine_q12 = basis[1],
            .transformed_map = self.clock.visible,
        };
    }

    pub fn startDraws(self: Room) u2 {
        return if (consumesExtraDraw(self.starts +% 1)) 2 else 1;
    }
    pub fn start(self: *Room, roll: u15) void {
        self.starts +%= 1;
        self.clock.start(roll);
        self.geometry_angle = 0;
        self.sample = .{};
    }
    pub fn advance(self: *Room) void {
        const moving_map = self.clock.phase != null;
        self.sample = self.clock.advance();
        if (moving_map) self.map_angle = self.sample.logical_angle;
        for (self.sample.geometry_angles[0..self.sample.geometry_count]) |angle| self.geometry_angle = angle;
    }
    pub fn validate(self: Room) !void {
        if (self.clock.speed > data.initial_speed or self.clock.slowdown >= data.slowdown_threshold or
            self.sample.geometry_count > 2 or self.sample.logical_angle != self.clock.angle)
            return error.InvalidWheelState;
        if (self.clock.phase == .spinning and self.clock.speed == 0) return error.InvalidWheelState;
        if (self.clock.phase == .timed and self.clock.timed_updates == 0) return error.InvalidWheelState;
    }
};
