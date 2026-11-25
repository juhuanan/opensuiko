//! Source-backed area callback/scan-buffer model for event opcode 0x4F.
//!
//! MAIN.EXE `area_state_handler_install` @0x801389F4: sel == 1 rewinds while
//! `event_state_flags & 0x8000`; otherwise it allocates the 0x1670-byte trigger
//! scan buffer, raises bit 0x8000 and installs one of six live callbacks into
//! area_state+0x49C. The scan-buffer free path clears the pointer and bit
//! 0x8000. The founding scene's selectors 0/2 also expose their source frame
//! phases and geometry. Rendering and the other four callback bodies remain unbound.
const directions = @import("field_effect_data").rays_q12;

pub const Point = struct { x: i32, y: i32 };
pub const Ray = struct { from: Point, to: Point, intensity: u8, semitransparent: bool };
pub const Quad = struct { points: [4]Point };
pub const Kind = @import("event_runtime").FieldEffect;
pub const active_flag: u16 = 0x8000;

pub const Callback = enum(u8) {
    scan_0 = 0,
    scan_2 = 2,
    scan_3 = 3,
    scan_4 = 4,
    scan_5 = 5,
    scan_6 = 6,
};

pub const Result = union(enum) {
    installed: Callback,
    wait: void,
    invalid: void,
};

pub const Frame = union(enum) {
    idle,
    scatter: u8,
    collapse: u8,
    tail: u8,
    handoff,
};

pub const State = struct {
    callback: ?Callback = null,
    flags: u16 = 0,
    elapsed: u8 = 0,

    pub fn install(self: *State, selector: u8) !Result {
        if (selector == 1) return if (self.flags & active_flag != 0) .{ .wait = {} } else .{ .invalid = {} };
        const callback: Callback = switch (selector) {
            0 => .scan_0,
            2 => .scan_2,
            3 => .scan_3,
            4 => .scan_4,
            5 => .scan_5,
            6 => .scan_6,
            else => return .{ .invalid = {} },
        };
        if (self.callback != null) return error.ScanAlreadyInstalled;
        self.callback = callback;
        self.elapsed = 0;
        self.flags |= active_flag;
        return .{ .installed = callback };
    }

    /// One callback invocation; the returned final frame still draws after free.
    pub fn advance(self: *State) !Frame {
        const current = self.callback orelse return .idle;
        const age = self.elapsed;
        switch (current) {
            .scan_0 => {
                self.elapsed += 1;
                if (self.elapsed == 85) self.finish();
                return .{ .scatter = age };
            },
            .scan_2 => {
                self.elapsed += 1;
                if (age < 20) return .{ .collapse = age };
                // The source changes callbacks on its own update, without drawing.
                if (age == 20) return .handoff;
                if (self.elapsed == 25) self.finish();
                return .{ .tail = age - 21 };
            },
            else => return error.UnimplementedAreaCallback,
        }
    }

    /// Release the installed callback and clear the shared scan flag.
    pub fn finish(self: *State) void {
        self.callback = null;
        self.flags &= ~active_flag;
    }
};

/// Small presentation owner; endpoints are generated without storing 180 packets.
pub const Effect = struct {
    clock: State,
    frame: Frame = .idle,
    center: Point = .{ .x = 0, .y = 0 },
    flash_origin: Point = .{ .x = 0, .y = 0 },

    pub fn init(kind: Kind) Effect {
        var clock: State = .{};
        _ = clock.install(if (kind == .appearance) 0 else 2) catch unreachable;
        return .{ .clock = clock };
    }

    pub fn validate(self: Effect, kind: Kind) !void {
        const elapsed = self.clock.elapsed;
        const duration: u8 = if (kind == .appearance) 85 else 25;
        if (elapsed > duration or self.clock.flags != (if (elapsed < duration) active_flag else @as(u16, 0)) or
            self.clock.callback != (if (elapsed == duration) null else if (kind == .appearance) Callback.scan_0 else Callback.scan_2))
            return error.InvalidAreaEffectState;
        const expected: Frame = if (elapsed == 0) .idle else if (kind == .appearance)
            .{ .scatter = elapsed - 1 }
        else if (elapsed <= 20)
            .{ .collapse = elapsed - 1 }
        else if (elapsed == 21)
            .handoff
        else
            .{ .tail = elapsed - 22 };
        if (!@import("std").meta.eql(expected, self.frame)) return error.InvalidAreaEffectState;
        if (self.center.x < -32768 or self.center.x > 32767 or self.center.y < -32768 or self.center.y > 32767 or
            self.flash_origin.x < -32776 or self.flash_origin.x > 32759 or self.flash_origin.y < -32784 or self.flash_origin.y > 32751)
            return error.InvalidAreaEffectState;
        if (elapsed == 0 and (self.center.x != 0 or self.center.y != 0)) return error.InvalidAreaEffectState;
        if ((kind == .appearance or elapsed <= 15) and (self.flash_origin.x != 0 or self.flash_origin.y != 0)) return error.InvalidAreaEffectState;
    }

    /// Center is already projected into the field's logical screen pixels.
    pub fn advance(self: *Effect, center: Point) !void {
        if (center.x < -32768 or center.x > 32767 or center.y < -32768 or center.y > 32767)
            return error.InvalidAreaEffectCenter;
        self.frame = try self.clock.advance();
        switch (self.frame) {
            .scatter => |age| if (age <= 20) {
                self.center = center;
            },
            .collapse => |age| {
                self.center = center;
                if (age == 15) self.flash_origin = .{ .x = center.x - 8, .y = center.y - 16 };
            },
            else => {},
        }
    }

    pub fn ray(self: Effect, index: usize) ?Ray {
        if (index >= directions.len) return null;
        const radius: i32 = switch (self.frame) {
            .scatter => 25,
            .collapse => |age| 25 - @as(i32, age),
            else => return null,
        };
        const dx = @divTrunc(@as(i32, directions[index][0]) * -radius, 4096);
        const dy = @divTrunc(@as(i32, directions[index][1]) * -radius, 4096);
        var horizontal: i32 = 0;
        var vertical: i32 = 0;
        const intensity: u8 = switch (self.frame) {
            .scatter => |age| if (age <= 20) color: {
                const spread: i32 = 20 - age;
                horizontal = spread * 32;
                vertical = spread * (@as(i32, @intCast(index)) - 82);
                if (index < 90) vertical = -vertical;
                break :color 255 - @as(u8, @intCast(index));
            } else 255 - 2 * (age - 21),
            .collapse => 255,
            else => unreachable,
        };
        const y = screen(self.center.y + dy + vertical);
        return .{
            .from = .{ .x = screen(self.center.x + dx - horizontal), .y = y },
            .to = .{ .x = screen(self.center.x - dx + horizontal), .y = y },
            .intensity = intensity,
            .semitransparent = self.frame == .collapse or self.frame.scatter >= 21,
        };
    }

    /// Submitted last into the shared bucket: the flash draws before the reversed rays.
    pub fn flash(self: Effect) ?Quad {
        const inset: i32 = switch (self.frame) {
            .collapse => |age| if (age >= 16) age - 15 else return null,
            .tail => |age| 5 + @as(i32, age),
            else => return null,
        };
        const left = screen(self.flash_origin.x + inset);
        const right = screen(self.flash_origin.x + 16 - inset);
        const bottom = screen(self.flash_origin.y);
        const top = screen(self.flash_origin.y - 240);
        return .{ .points = .{
            .{ .x = left, .y = bottom }, .{ .x = right, .y = bottom },
            .{ .x = left, .y = top },    .{ .x = right, .y = top },
        } };
    }
};

fn screen(value: i32) i32 {
    return @as(i16, @truncate(value));
}
