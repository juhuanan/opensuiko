//! Trick's callback-driven wave; gameplay applies each crossing through the damage host.
const std = @import("std");
pub const Heights = [50]i16;
pub const Phase = enum { rise, sweep, fall };
pub const Events = struct { hits: u6 = 0, sound: ?u16 = null, returns: bool = false, cleanup: bool = false, clear_trigger: bool = false };
pub const State = struct {
    heights: Heights,
    phase: Phase = .rise,
    age: u16 = 0,
    translation: [3]i32 = .{ 0, 0, 0 },
    local_q12: [8][3]i32 = undefined,
    animation_updates: [8]u16 = @splat(0),
    enabled: u8 = 0,
    settled: u8 = 0,
    hit: u6 = 0,
    finished: bool = false,

    pub fn init(heights: Heights) !State {
        for (heights) |height| if (height < -30 or height > 0) return error.InvalidTrickHeights;
        var result = State{ .heights = heights };
        for (&result.local_q12, 0..) |*position, index| position.* = .{ 0, 100 * 4096 - @as(i32, @intCast(index * 200 * 4096 / 7)), -300 * 4096 };
        return result;
    }
    // Call before the actor sweep. An absent slot differs from an inactive target:
    // the source marks inactive crossings too; its damage helper decides whether to apply HP.
    pub fn advance(self: *State, triggered: bool, enemy_x_q12: [6]?i32) Events {
        var events = Events{};
        if (!triggered or self.finished) return events;
        switch (self.phase) {
            .rise => {
                if (self.age == 0) events.sound = 0x513;
                for (0..8) |index| if (self.age == index * 2) {
                    self.enabled |= @as(u8, 1) << @as(u3, @intCast(index));
                };
                self.age += 1;
                if (self.age == 64) {
                    self.phase = .sweep;
                    self.age = 0;
                }
            },
            .sweep => {
                if (self.age % 16 == 0) events.sound = 0x81B;
                self.translation[0] -= 8;
                self.translation[2] = self.heights[self.age];
                for (enemy_x_q12, 0..) |maybe, index| if (maybe) |x| {
                    const bit = @as(u6, 1) << @as(u3, @intCast(index));
                    if (self.hit & bit == 0 and self.translation[0] < x >> 12) {
                        self.hit |= bit;
                        events.hits |= bit;
                    }
                };
                self.age += 1;
                if (self.age == 50) {
                    self.phase = .fall;
                    self.age = 0;
                }
            },
            .fall => {
                self.translation[2] -= 5;
                self.age += 1;
                if (self.age == 64) {
                    events.returns = true;
                    events.clear_trigger = true;
                    events.cleanup = true;
                    self.finished = true;
                }
            },
        }
        // The source queues this last object update before freeing the controller.
        for (&self.local_q12, 0..) |*position, index| {
            const bit = @as(u8, 1) << @as(u3, @intCast(index));
            if (self.enabled & bit == 0) continue;
            if (self.settled & bit == 0) {
                position[2] += 76800;
                if (position[2] > 0) {
                    position[2] = 0;
                    self.settled |= bit;
                }
            }
            self.animation_updates[index] += 1;
        }
        return events;
    }
};
