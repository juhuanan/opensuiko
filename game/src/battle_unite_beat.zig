//! Beat'em up callback order over the shared source actor runtime.
const std = @import("std");
const host = @import("battle_actor_host.zig");
const vm = @import("battle_actor_program.zig");

pub const Binding = struct { id: []const u8, entry: []const u8, followup: ?[]const u8 = null };
pub const Events = struct { child: bool = false, transition: bool = false, first_reaction: bool = false, damage: bool = false, cleanup: bool = false };
pub fn spawnChild(runtime: *host.Runtime, parent: u16, target: u16, child: vm.Child) !bool {
    if (runtime.actors[parent].shared_value != 1) return false;
    const attachment = try runtime.actors[target].attachment();
    if (!try runtime.spawn(parent, child, attachment)) return error.ActorPoolExhausted;
    runtime.actors[parent].shared_value = 99;
    return true;
}
pub const State = struct {
    bindings: [2]Binding,
    members: [2]u16,
    target: u16,
    child: vm.Child,
    ready: u2 = 0,
    started: bool = false,
    finished: bool = false,

    pub fn init(runtime: *const host.Runtime, bindings: [2]Binding, members: [2]u16, target: u16, child: vm.Child) !State {
        const library = runtime.library orelse return error.MissingActorLibrary;
        if (members[0] == members[1] or target >= runtime.actors.len or target == members[0] or target == members[1]) return error.InvalidActorBinding;
        for (bindings, members) |binding, member| {
            if (member >= runtime.actors.len) return error.InvalidActorBinding;
            const resource = runtime.actors[member].resource orelse return error.MissingActorResource;
            if (!std.mem.eql(u8, resource.id, binding.id)) return error.InvalidActorBinding;
            _ = library.programs.find(binding.entry) orelse return error.MissingUniteProgram;
        }
        _ = library.programs.find(bindings[1].followup orelse return error.MissingUniteProgram) orelse return error.MissingUniteProgram;
        const resource = library.resources.find(child.resource) orelse return error.MissingActorResource;
        if (!std.mem.eql(u8, child.resource, bindings[1].id) or child.owner != .self or child.home != .parent_owner) return error.InvalidActorBinding;
        _ = resource.find(child.animation) orelse return error.MissingActorAnimation;
        _ = library.programs.find(child.program) orelse return error.MissingActorChildProgram;
        return .{ .bindings = bindings, .members = members, .target = target, .child = child };
    }
    pub fn start(self: *State, runtime: *host.Runtime) !void {
        if (self.started) return error.ActorAlreadyOwned;
        for (self.bindings, self.members) |binding, member| try runtime.dispatch(member, self.target, runtime.library.?.programs.find(binding.entry).?);
        self.started = true;
    }
    // Invoke before the ascending actor sweep; the host applies the recipient/HP events.
    pub fn advance(self: *State, runtime: *host.Runtime) !Events {
        if (!self.started) return error.InvalidActorPlayback;
        var events = Events{};
        if (self.finished) return events;
        const pahn = &runtime.actors[self.members[0]];
        const bell = &runtime.actors[self.members[1]];
        events.child = try spawnChild(runtime, self.members[1], self.target, self.child);
        if (pahn.signals & 16 != 0) {
            try runtime.dispatch(self.members[1], self.target, runtime.library.?.programs.find(self.bindings[1].followup.?).?);
            pahn.signals &= ~@as(u16, 16);
            events.transition = true;
        }
        if (pahn.signals & 2 != 0) {
            pahn.signals &= ~@as(u16, 2);
            events.first_reaction = true;
        }
        if (bell.signals & 2 != 0) {
            pahn.signals &= ~@as(u16, 2);
            bell.signals &= ~@as(u16, 2);
            events.damage = true;
        }
        for (self.members, 0..) |member, index| if (runtime.actors[member].signals & 4 != 0) {
            self.ready |= @as(u2, 1) << @as(u1, @intCast(index));
        };
        if (self.ready == 3) {
            self.finished = true;
            events.cleanup = true;
        }
        return events;
    }
};
