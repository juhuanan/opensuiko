//! Headquarters roster selection. The host owns windows, loading and mutations.
const std = @import("std");
pub const Window = @import("selector_window.zig").Window;
pub const Windows = @import("selector_windows.zig").Windows;
pub const Kind = @import("selector_windows.zig").Kind;
pub const Details = @import("selector_details.zig").Details;
pub const layout = @import("party_data").selector;

pub const Candidate = struct {
    id: []const u8,
    recruited: bool,
    blocked: bool,
    guest: bool = false,
};
pub const Roster = struct {
    // The extractor's persistent-character order, not display-name order.
    characters: []const Candidate,
    active: []const []const u8,
    forced: []const []const u8,
    reserve_slot: bool = false,

    pub fn validate(self: Roster) !void {
        if (self.characters.len > 78 or self.active.len == 0 or self.active.len > 6 or self.forced.len > 6) return error.InvalidSelectorRoster;
        for (self.characters, 0..) |character, i| {
            if (character.id.len == 0) return error.InvalidSelectorRoster;
            for (self.characters[0..i]) |other| if (same(character.id, other.id)) return error.InvalidSelectorRoster;
        }
        for (self.active, 0..) |id, i| {
            if (contains(self.active[0..i], id)) return error.InvalidSelectorRoster;
            for (self.characters) |character| {
                if (same(character.id, id)) break;
            } else return error.InvalidSelectorRoster;
        }
        if (!contains(self.active, "hero")) return error.InvalidSelectorRoster;
    }

    pub fn ejectable(self: Roster, id: []const u8) bool {
        return !same(id, "hero") and !contains(self.forced, id);
    }
};

pub const Controls = struct {
    confirm: bool = false,
    cancel: bool = false,
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,

    fn direction(self: Controls) ?enum { up, down, left, right } {
        if (@as(u3, @intFromBool(self.up)) + @intFromBool(self.down) + @intFromBool(self.left) + @intFromBool(self.right) != 1) return null;
        if (self.up) return .up;
        if (self.down) return .down;
        if (self.left) return .left;
        return .right;
    }
};
pub const Action = enum { admit, eject, no_change };
/// Sample once per simulation update, including updates outside the selector.
pub const Sampler = struct {
    held_updates: [6]u8 = @splat(0),
    odd_update: bool = false,

    pub const Sample = struct {
        pressed: Controls = .{},
        repeated: Controls = .{},

        pub fn forPhase(self: Sample, phase: Phase) Controls {
            return switch (phase) {
                .confirmation, .full => self.pressed,
                else => self.repeated,
            };
        }
    };

    pub fn sample(self: *Sampler, held: Controls) Sample {
        self.odd_update = !self.odd_update;
        var result: Sample = .{};
        inline for (comptime std.meta.fieldNames(Controls), 0..) |name, index| {
            const previous = self.held_updates[index];
            self.held_updates[index] = if (@field(held, name)) @min(previous + 1, 30) else 0;
            const pressed = @field(held, name) and previous == 0;
            @field(result.pressed, name) = pressed;
            // The first source sample is odd; repeat begins on sample 30.
            @field(result.repeated, name) = pressed or (!self.odd_update and self.held_updates[index] == 30);
        }
        return result;
    }
};
pub const Phase = enum {
    main_creation,
    main_opening,
    main,
    main_closing,
    main_cleanup,
    action_dispatch,
    list_setup,
    list_creation,
    list_opening,
    list,
    confirmation_opening,
    confirmation,
    confirmation_closing,
    decision,
    loading,
    full_opening,
    full,
    full_closing,
    list_close_request,
    list_closing,
    list_cleanup,
    main_return,
    main_recreate,
    fading,
    cleanup,
    done,
};
pub const Request = struct {
    action: Action,
    character: []const u8,
    before: [6]?[]const u8,
};
pub const Selector = struct {
    phase: Phase = .main_creation,
    action: Action = .admit,
    cursor: usize = 0,
    refuse: bool = false,
    fade: u8 = 128,
    pending: ?Request = null,

    pub fn list(self: Selector, roster: Roster, buffer: *[78][]const u8) []const []const u8 {
        if (self.action == .eject) return roster.active;
        var n: usize = 0;
        for (roster.characters) |character| {
            if (!character.recruited or character.blocked or character.guest or contains(roster.active, character.id)) continue;
            buffer[n] = character.id;
            n += 1;
        }
        return buffer[0..n];
    }

    /// One owner update. Readiness is supplied by the window owner, never a
    /// guessed delay or an input press that skips an opening/closing window.
    pub fn tick(self: *Selector, roster: Roster, controls: Controls, windows_ready: bool) !void {
        try roster.validate();
        var buffer: [78][]const u8 = undefined;
        const choices = self.list(roster, &buffer);
        switch (self.phase) {
            .main_creation => self.phase = .main_opening,
            .main_opening => if (windows_ready) {
                self.phase = .main;
            },
            .main => {
                if (roster.reserve_slot) {
                    self.action = if (roster.active.len == 6) .eject else .no_change;
                    self.phase = .main_closing;
                } else if (controls.confirm or controls.cancel) {
                    if (!controls.confirm) self.action = .no_change;
                    self.phase = .main_closing;
                } else if (controls.direction()) |direction| switch (direction) {
                    .up => self.action = @fromBackingInt(@intCast((@as(usize, @backingInt(self.action)) + 2) % 3)),
                    .down => self.action = @fromBackingInt(@intCast((@as(usize, @backingInt(self.action)) + 1) % 3)),
                    else => {},
                };
            },
            .main_closing => if (windows_ready) {
                self.phase = .main_cleanup;
            },
            .main_cleanup => self.phase = .action_dispatch,
            .action_dispatch => {
                self.cursor = 0;
                self.phase = if (self.action == .no_change) .fading else .list_setup;
            },
            .list_setup => self.phase = .list_creation,
            .list_creation => self.phase = if (self.action == .admit and roster.active.len == 6) .list else .list_opening,
            .list_opening => if (windows_ready) {
                self.phase = .list;
            },
            .list => {
                // The source checks an empty list before the six-member report.
                if (choices.len == 0) {
                    self.phase = .list_close_request;
                    return;
                }
                self.cursor = @min(self.cursor, choices.len - 1);
                if (self.action == .admit and roster.active.len == 6) {
                    self.phase = .full_opening;
                    return;
                }
                if (controls.confirm) {
                    if (self.action == .admit or roster.ejectable(choices[self.cursor])) self.phase = .confirmation_opening;
                } else if (controls.cancel) {
                    self.phase = .list_close_request;
                } else if (controls.direction()) |direction| {
                    const page = self.cursor / 10;
                    switch (direction) {
                        .up => if (self.cursor > page * 10) {
                            self.cursor -= 1;
                        },
                        .down => if (self.cursor + 1 < @min((page + 1) * 10, choices.len)) {
                            self.cursor += 1;
                        },
                        .left => if (page > 0) {
                            self.cursor = (page - 1) * 10;
                        },
                        .right => if ((page + 1) * 10 < choices.len) {
                            self.cursor = (page + 1) * 10;
                        },
                    }
                }
            },
            .confirmation_opening => if (windows_ready) {
                self.refuse = false;
                self.phase = .confirmation;
            },
            .confirmation => {
                if (controls.confirm or controls.cancel) {
                    if (!controls.confirm) self.refuse = true;
                    self.phase = .confirmation_closing;
                } else if (controls.direction()) |direction| switch (direction) {
                    .up, .down => self.refuse = !self.refuse,
                    else => {},
                };
            },
            .confirmation_closing => if (windows_ready) {
                self.phase = .decision;
            },
            .decision => {
                if (self.refuse) {
                    self.phase = .list;
                    return;
                }
                if (self.cursor >= choices.len) return error.StaleSelectorRoster;
                var before: [6]?[]const u8 = @splat(null);
                for (roster.active, 0..) |id, i| before[i] = id;
                self.pending = .{ .action = self.action, .character = choices[self.cursor], .before = before };
                self.phase = .loading;
            },
            .loading => {}, // The host acknowledges only after committing owned records.
            .full_opening => if (windows_ready) {
                self.phase = .full;
            },
            .full => if (controls.confirm or controls.cancel) {
                self.phase = .full_closing;
            },
            .full_closing => if (windows_ready) {
                self.phase = .list_cleanup;
            },
            .list_close_request => self.phase = .list_closing,
            .list_closing => if (windows_ready) {
                self.phase = .list_cleanup;
            },
            .list_cleanup => self.phase = .main_return,
            .main_return => self.phase = .main_recreate,
            .main_recreate => {
                self.action = .admit;
                self.cursor = 0;
                self.phase = .main_creation;
            },
            .fading => {
                if (self.fade < 4) {
                    self.fade = 0;
                    self.phase = .cleanup;
                } else self.fade -= 4;
            },
            .cleanup => self.phase = .done,
            .done => {},
        }
    }

    /// Acknowledgement checks append/removal order, so a stale or partial host
    /// mutation cannot release the selector's loading gate.
    pub fn acknowledge(self: *Selector, roster: Roster) !void {
        try roster.validate();
        const request = self.pending orelse return error.MissingSelectorRequest;
        if (self.phase != .loading) return error.MissingSelectorRequest;
        var expected: [6]?[]const u8 = @splat(null);
        var n: usize = 0;
        var removed = false;
        for (request.before) |maybe| if (maybe) |id| {
            if (request.action == .eject and same(id, request.character)) {
                removed = true;
                continue;
            }
            expected[n] = id;
            n += 1;
        };
        if (request.action == .admit) {
            if (n == 6) return error.PartyFull;
            expected[n] = request.character;
            n += 1;
        } else if (request.action != .eject or !removed) return error.InvalidSelectorRequest;
        if (roster.active.len != n) return error.StaleSelectorRoster;
        for (roster.active, 0..) |id, i| if (!same(id, expected[i].?)) return error.StaleSelectorRoster;
        self.pending = null;
        var buffer: [78][]const u8 = undefined;
        const choices = self.list(roster, &buffer);
        self.cursor = if (choices.len == 0) 0 else @min(self.cursor, choices.len - 1);
        self.phase = if (roster.reserve_slot) .list_close_request else .list;
    }
};

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn contains(ids: []const []const u8, id: []const u8) bool {
    for (ids) |candidate| if (same(candidate, id)) return true;
    return false;
}
