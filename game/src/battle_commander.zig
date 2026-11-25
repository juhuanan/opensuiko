//! Commander callbacks retain source waits; actors own their motion and reactions.
const std = @import("std");
const host = @import("battle_actor_host.zig");

pub const Binding = struct {
    id: []const u8,
    order_program: []const u8,
    solo_program: ?[]const u8 = null,
    recipient_program: ?[]const u8 = null,
    selection_delay: u16,

    pub fn validate(self: Binding, library: host.Library) !void {
        const solo = std.mem.eql(u8, self.id, "beast_commander");
        if ((!solo and !std.mem.eql(u8, self.id, "whip_wolf")) or self.selection_delay != 60 or library.resources.find(self.id) == null) return error.InvalidEnemyOrderBinding;
        if ((self.solo_program != null) != solo or (self.recipient_program != null) != solo) return error.InvalidEnemyOrderBinding;
        for ([_]?[]const u8{ self.order_program, self.solo_program, self.recipient_program }) |maybe| if (maybe) |id| {
            if (id.len == 0 or id.len > 128 or library.programs.find(id) == null) return error.InvalidEnemyOrderBinding;
        };
    }
};

pub const Event = enum { none, orders, recipient };
pub const Playback = struct {
    id: []const u8 = "beast_commander",
    owner: u8,
    recipient: ?u8,
    start_at: u32,
    action: ?Action = null,
    controller_done: bool = false,
    ordered_at: ?u32 = null,
    owner_done: bool = false,
    recipient_done: bool = false,
};
pub const Action = struct {
    owner: u8,
    recipient: ?u8,
    launched: bool = false,

    pub fn begin(binding: Binding, runtime: *host.Runtime, owner: u8, recipient: ?u8) !Action {
        const library = runtime.library orelse return error.MissingActorLibrary;
        try binding.validate(library);
        if (owner >= runtime.actors.len or runtime.actors[owner].resource == null or !std.mem.eql(u8, runtime.actors[owner].resource.?.id, binding.id)) return error.InvalidActorBinding;
        if (recipient) |target| if (target >= runtime.actors.len or target == owner or runtime.actors[target].resource == null) return error.InvalidActorBinding;
        const program = if (recipient == null) binding.order_program else binding.solo_program orelse return error.InvalidActorBinding;
        try runtime.dispatch(owner, recipient orelse owner, library.programs.find(program).?);
        return .{ .owner = owner, .recipient = recipient };
    }

    // Poll before the ascending actor sweep, observing signals from the prior update.
    pub fn advance(self: *Action, binding: Binding, runtime: *host.Runtime) !Event {
        if (self.launched or runtime.actors[self.owner].signals & 2 == 0) return .none;
        if (self.recipient) |target| {
            const program = runtime.library.?.programs.find(binding.recipient_program orelse return error.InvalidActorBinding) orelse return error.MissingActorProgram;
            try runtime.dispatch(target, self.owner, program);
        }
        self.launched = true;
        return if (self.recipient == null) .orders else .recipient;
    }
};
