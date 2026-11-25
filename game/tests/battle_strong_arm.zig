const std = @import("std");
const battle = @import("battle");
const host = battle.actor_host;
const counter = battle.counter;
const vm = battle.actor_program;
const allocator = std.testing.allocator;

const Context = struct {
    binding: counter.CooperationBinding,
    cooperation: counter.Cooperation = .{},
    runtime: *host.Runtime = undefined,
    owner: u8,
    candidate: ?u8,
    fn command(raw: *anyopaque, actor: u16, request: vm.Command, _: bool) !bool {
        const self: *Context = @ptrCast(@alignCast(raw));
        if (request == .sound) return true;
        if (actor != self.owner or request != .effect or request.effect.binding != .self or !std.mem.eql(u8, request.effect.id, "ally_throw")) return error.UnboundStrongArmCommand;
        if (self.cooperation.active) return error.DuplicateStrongArmEffect;
        self.cooperation.active = true;
        return true;
    }
    fn after(raw: *anyopaque, actor: u16) !void {
        const self: *Context = @ptrCast(@alignCast(raw));
        if (actor == self.owner) try self.cooperation.advance(self.binding, self.runtime, self.owner, self.candidate);
    }
    fn previous(_: *anyopaque, _: u16) !battle.presentation.ScreenPoint {
        return .{ .x = 0, .y = 0, .depth = 100 };
    }
};

test "Strong Arm source solo and cooperative branches complete for all 78 targets and both ally orders" {
    const parsed = try counter.load(allocator, @embedFile("fixtures/counter_actor_library.json"));
    defer parsed.deinit();
    const packet = parsed.value;
    const binding = packet.cooperation.?;
    var cases: usize = 0;
    for (packet.melee.?.party_reactions) |party| for (0..binding.allies.len + 1) |choice| for (0..2) |order| {
        const owner: u8 = @intCast(1 + order);
        const ally: u8 = 3 - owner;
        var actors: [3]host.Actor = undefined;
        actors[0] = try host.Actor.init(packet.animations.find(party.id).?, .{ 120 * 4096, 40 * 4096, 0 });
        actors[owner] = try host.Actor.init(packet.animations.find(binding.id).?, .{ -150 * 4096, 0, 0 });
        actors[ally] = try host.Actor.init(packet.animations.find(binding.allies[@min(choice, binding.allies.len - 1)]).?, .{ -180 * 4096, 50 * 4096, 0 });
        var children: [4]?host.Actor = @splat(null);
        var context = Context{ .binding = binding, .owner = owner, .candidate = if (choice < binding.allies.len) ally else null };
        var runtime = host.Runtime{ .actors = &actors, .auxiliary = &children, .library = packet.library(), .camera_angles = .{ 100, 200, 300 }, .external = .{ .context = &context, .command = Context.command, .after_actor = Context.after, .previous_screen_position = Context.previous } };
        context.runtime = &runtime;
        var action = try counter.Action.beginFor(packet, &runtime, owner, 0, .ordinary_hit);
        var contacts: usize = 0;
        var saw_projectile = false;
        var completed = false;
        for (0..1200) |_| {
            if (action.stage == .returning) try action.advance(packet, &runtime);
            for (0..actors.len) |actor| {
                if (action.callbackActor() == @as(u8, @intCast(actor))) {
                    try action.advance(packet, &runtime);
                    if (action.stage == .contact) {
                        contacts += 1;
                        try action.acknowledgeContact(packet, &runtime);
                    }
                    if (action.returnReady(runtime)) try action.beginReturn(packet, &runtime);
                }
                try runtime.stepActor(@intCast(actor));
            }
            var live_children = false;
            for (0..children.len) |index| if (children[index] != null) {
                try runtime.stepActor(@intCast(actors.len + index));
                if (children[index]) |child| {
                    live_children = true;
                    if (child.projectile) |kind| if (kind == .fixed) {
                        saw_projectile = true;
                        try std.testing.expectEqualDeep([3]i16{ 0, 0, 0 }, child.draw_angles);
                        try std.testing.expectEqualStrings(binding.id, child.resource.?.id);
                    };
                }
            };
            if (action.stage != .released or context.cooperation.active or live_children) continue;
            if (context.cooperation.assistant != null and (!actors[ally].machine.?.halted or actors[ally].highlights != 0)) continue;
            completed = true;
            break;
        }
        if (!completed) std.debug.print("Strong Arm failed target={s} choice={d} order={d} stage={s} values={any}\n", .{ party.id, choice, order, @tagName(action.stage), .{ actors[owner].shared_value, actors[ally].shared_value } });
        try std.testing.expect(completed);
        try std.testing.expectEqual(@as(usize, 1), contacts);
        try std.testing.expectEqual(choice == binding.allies.len, saw_projectile);
        try std.testing.expectEqual(context.candidate, context.cooperation.assistant);
        for (actors) |actor| {
            if (actor.machine) |machine| try std.testing.expect(machine.halted);
            try std.testing.expectEqual(@as(u8, 0), actor.highlights);
            try std.testing.expectEqualDeep(actor.home_q12, actor.position_q12);
        }
        cases += 1;
    };
    try std.testing.expectEqual(@as(usize, 780), cases);
}
