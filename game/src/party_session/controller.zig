//! Host-facing ordinary-input controller; drawing is supplied by the platform.
const std = @import("std");
const session = @import("session.zig");

pub const Input = enum { up, down, confirm, cancel };
pub const Controller = struct {
    cursor: usize = 0,
    last_error: ?[]const u8 = null,
    done: bool = false,

    pub fn count(self: Controller, state: session.Session) usize {
        _ = self;
        for (state.current.members, 0..) |item, i| if (item == null) return i;
        return session.max_owned;
    }
    pub fn selected(self: Controller, state: session.Session) ?[]const u8 {
        if (self.cursor >= self.count(state)) return null;
        return state.current.members[self.cursor].?.id;
    }
    pub fn active(state: session.Session, id: []const u8) bool {
        for (state.current.active) |maybe| if (maybe) |value| {
            if (std.mem.eql(u8, value, id)) return true;
        };
        return false;
    }
    pub fn input(self: *Controller, state: *session.Session, key: Input) void {
        self.last_error = null;
        const n = self.count(state.*);
        switch (key) {
            .up => if (n > 0) {
                self.cursor = if (self.cursor == 0) n - 1 else self.cursor - 1;
            },
            .down => if (n > 0) {
                self.cursor = (self.cursor + 1) % n;
            },
            .cancel => {
                self.done = true;
            },
            .confirm => {
                const id = self.selected(state.*) orelse return;
                var ids = state.current.active;
                if (active(state.*, id)) {
                    for (ids, 0..) |maybe, i| if (maybe != null and std.mem.eql(u8, maybe.?, id)) {
                        std.mem.copyForwards(?[]const u8, ids[i..5], ids[i + 1 .. 6]);
                        ids[5] = null;
                        break;
                    };
                } else {
                    var added = false;
                    for (&ids) |*maybe| if (maybe.* == null) {
                        maybe.* = id;
                        added = true;
                        break;
                    };
                    if (!added) {
                        self.last_error = "PartyFull";
                        return;
                    }
                }
                state.execute(.{ .select = ids }) catch |err| {
                    self.last_error = @errorName(err);
                };
            },
        }
    }
};
