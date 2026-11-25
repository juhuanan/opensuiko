//! Member-ordered target claims and a shared finishing clock.
pub const Timing = struct { recipient_return: u16, damage: u16, cleanup: u16 };
pub const Events = struct {
    claims: [3]?u8 = @splat(null),
    returns: u3 = 0,
    reactions: [3]?u8 = @splat(null),
    consumed: [3]u16 = @splat(0),
    recipient_return: bool = false,
    damage: bool = false,
    cleanup: bool = false,
};
pub const State = struct {
    timing: Timing,
    pending: [6]bool,
    targets: [3]?u8 = @splat(null),
    returning: u3 = 0,
    finish_age: u16 = 0,
    finished: bool = false,

    pub fn init(timing: Timing, pending: [6]bool) !State {
        if (timing.recipient_return == 0 or timing.recipient_return >= timing.damage or timing.damage >= timing.cleanup or timing.cleanup > 1000) return error.InvalidUniteQueueTiming;
        return .{ .timing = timing, .pending = pending };
    }

    pub fn advance(self: *State, signals: [3]u16) Events {
        var events = Events{};
        if (self.finished) return events;
        for (signals, 0..) |flags, member| {
            if (flags & 16 == 0) continue;
            events.consumed[member] |= 16;
            const target = for (self.pending, 0..) |pending, index| {
                if (pending) break index;
            } else null;
            if (target) |index| {
                self.pending[index] = false;
                self.targets[member] = @intCast(index);
                events.claims[member] = @intCast(index);
            } else {
                const bit = @as(u3, 1) << @as(u2, @intCast(member));
                self.returning |= bit;
                events.returns |= bit;
            }
        }
        for (signals, 0..) |flags, member| {
            if (flags & 2 == 0) continue;
            events.consumed[member] |= 2;
            events.reactions[member] = self.targets[member];
        }
        if (self.returning != 7) return events;
        events.recipient_return = self.finish_age == self.timing.recipient_return;
        events.damage = self.finish_age == self.timing.damage;
        events.cleanup = self.finish_age >= self.timing.cleanup;
        if (events.cleanup) self.finished = true else self.finish_age += 1;
        return events;
    }
};
