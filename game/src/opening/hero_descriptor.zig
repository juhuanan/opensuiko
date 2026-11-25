//! Retained Hero auxiliary objects at descriptor +0x0C and +0x10.
//! The field session remains the sole owner of the primary animation clock.
const std = @import("std");
const motion = @import("opening_audience");

pub const source_sha256 = "e9fdbee8391cc74349a091428767e208a4255960eeb4a118952cb612088b2428";

pub const Child = struct {
    variant: u2,
    animation: motion.SpriteAnimation,
    attr_18: u8 = 0x80,
    attr_19: u8 = 0,
};
pub const DrawEffect = struct { source_draw_selected: bool };
pub const Auxiliary = struct {
    child_0c: Child,
    child_10: Child,

    /// 0x801347D0 constructs both children from SHU S2 using the retained
    /// 0x80171598 sequence; multi-frame sequences start at frame 1.
    pub fn init(animation: motion.Animation, retained_sequence: u2) !Auxiliary {
        try validateAnimation(animation);
        var clock = motion.SpriteAnimation.start(animation.clips[retained_sequence]);
        clock.frame = 1;
        clock.remaining = animation.clips[retained_sequence].ticks[1];
        const child: Child = .{ .variant = retained_sequence, .animation = clock };
        return .{ .child_0c = child, .child_10 = child };
    }

    pub fn validateState(self: Auxiliary, animation: motion.Animation) !void {
        try validateAnimation(animation);
        for ([_]Child{ self.child_0c, self.child_10 }) |child| {
            const clip = animation.clips[child.variant];
            if (!child.animation.active or !child.animation.repeating or child.animation.frame >= 4 or
                child.animation.remaining == 0 or child.animation.remaining > clip.ticks[child.animation.frame]) return error.InvalidAuxiliaryState;
        }
    }

    fn attributes(self: *Auxiliary, room_byte7: u8) void {
        if (room_byte7 == 1) {
            self.child_0c.attr_18 = 0xa0;
            self.child_0c.attr_19 = 2;
        }
        self.child_10.attr_18 = 0x22;
        self.child_10.attr_19 = 1;
    }

    /// Follow a source primary sequence reset with 0x801343B4(target).
    /// Returns the primary child's +0x18 update. This does not tick either clock.
    pub fn sequenceReset(self: *Auxiliary, animation: motion.Animation, target: u2, room_byte7: u8, tint_word: u32) !u8 {
        try self.validateState(animation);
        var next = self.*;
        next.child_0c = .{ .variant = target, .animation = motion.SpriteAnimation.start(animation.clips[target]) };
        next.attributes(room_byte7);
        self.* = next;
        return @truncate(tint_word);
    }

    /// Follow one actual source primary tick with 0x801343B4(0xFF).
    /// The caller invokes this once for each paired tick, including multi-tick jobs.
    pub fn pairedTick(self: *Auxiliary, animation: motion.Animation, room_byte7: u8, tint_word: u32) !u8 {
        try self.validateState(animation);
        var next = self.*;
        next.child_0c.animation.tick(animation.clips[next.child_0c.variant]);
        next.attributes(room_byte7);
        self.* = next;
        return @truncate(tint_word);
    }

    /// 0x8013C7A4 leaves matching sequences intact. On a change it resets,
    /// then invokes one paired idle tick after resetting the primary to frame 0.
    pub fn opcode11(self: *Auxiliary, animation: motion.Animation, previous_primary: u2, target: u2, room_byte7: u8, tint_word: u32) !?u8 {
        try self.validateState(animation);
        if (previous_primary == target) return null;
        var next = self.*;
        _ = try next.sequenceReset(animation, target, room_byte7, tint_word);
        const primary_attr = try next.pairedTick(animation, room_byte7, tint_word);
        self.* = next;
        return primary_attr;
    }

    /// 0x8012FF24..FFE0 updates the auxiliary's draw attributes only in the
    /// selected room mode and at descriptor level 0. Projection is host-owned.
    pub fn draw(self: *Auxiliary, animation: motion.Animation, room_byte7: u8, descriptor_level: u8, tint_word: u32) !DrawEffect {
        try self.validateState(animation);
        if (room_byte7 != 1 or descriptor_level != 0) return .{ .source_draw_selected = false };
        self.child_0c.attr_18 = if (tint_word == 0) 0 else @truncate(tint_word +% 0x20);
        self.child_0c.attr_19 = 2;
        return .{ .source_draw_selected = true };
    }
};

fn validateAnimation(animation: motion.Animation) !void {
    if (!std.mem.eql(u8, animation.graphic, "hero")) return error.InvalidHeroResource;
    for (animation.clips) |clip| {
        if (clip.flags != 3 or clip.ticks.len != 4 or clip.bounds.len != 4) return error.InvalidHeroResource;
        for (clip.ticks, clip.bounds) |ticks, bounds| {
            if (ticks != 12 or bounds.width != 24 or bounds.height != 48) return error.InvalidHeroResource;
        }
    }
}
