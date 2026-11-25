//! Source camera/Hero push clock; the field pass owns interpolation settlement.
pub const Request = struct {
    dx: i16,
    dy: i16,
    updates: u8,
    repeats: u16,

    pub fn validate(self: Request) !void {
        if ((self.dx != -16 and self.dx != -8 and self.dx != 8 and self.dx != 16) or
            (self.dy != -8 and self.dy != 8) or self.updates != 8 or self.repeats == 0 or self.repeats > 256)
            return error.UnsupportedCameraPush;
    }
};

pub const Frame = struct {
    camera_target_x: i32,
    camera_target_y: i32,
    forced_animation_steps: u8 = 2,
};

pub const State = struct {
    request: Request,
    updates_left: u8,
    repeats_left: u16,
    elapsed: u16 = 0,

    pub fn begin(request: Request, hero: anytype) !State {
        try request.validate();
        if (hero.x < 0 or hero.y < 0 or hero.x > 2040 or hero.y > 2040 or @mod(hero.x, 8) != 0 or @mod(hero.y, 8) != 0)
            return error.InvalidCameraPushStart;
        var result: State = .{ .request = request, .updates_left = request.updates, .repeats_left = request.repeats };
        result.applyRecord(hero);
        return result;
    }

    fn applyRecord(self: *State, hero: anytype) void {
        hero.x = @mod(hero.x + self.request.dx, 2048);
        hero.y = @mod(hero.y + self.request.dy, 2048);
        hero.offset_x = -self.request.dx;
        hero.offset_y = -self.request.dy;
        hero.speed = 2;
        self.updates_left = self.request.updates;
    }

    pub fn active(self: State) bool {
        return self.repeats_left != 0;
    }

    pub fn advance(self: *State, hero: anytype) ?Frame {
        if (!self.active()) return null;
        self.updates_left -= 1;
        self.elapsed += 1;
        // Camera sampling precedes field offset settlement and repeat setup.
        const frame: Frame = .{ .camera_target_x = hero.x + hero.offset_x, .camera_target_y = hero.y + hero.offset_y };
        if (self.updates_left == 0) {
            self.repeats_left -= 1;
            if (self.active()) self.applyRecord(hero);
        }
        return frame;
    }

    pub fn validate(self: State) !void {
        try self.request.validate();
        if (self.repeats_left > self.request.repeats or self.updates_left > self.request.updates or
            ((self.repeats_left == 0) != (self.updates_left == 0))) return error.InvalidCameraPushState;
        const remaining: u16 = if (self.active()) (self.repeats_left - 1) * self.request.updates + self.updates_left else 0;
        if (@as(u32, remaining) + self.elapsed != @as(u32, self.request.repeats) * self.request.updates)
            return error.InvalidCameraPushState;
    }
};
