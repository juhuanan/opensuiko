//! Physical-rune bindings and controller; the scene owns HP, RNG and actor updates.
const std = @import("std");
const host = @import("battle_actor_host.zig");
const vm = @import("battle_actor_program.zig");
const camera = @import("battle_camera");
pub const Technique = @import("battle_systems").techniques.physical.Technique;

pub const InitialCamera = struct {
    updates: u16,
    binding: enum { absolute, recipient },
    position_q12: [3]i32,
    angles_q12: [3]i32,
    scale_q12: [3]i32,
    translation_q12: ?[3]i32 = null,
    preserve_translation: bool = false,

    fn target(self: InitialCamera, controller: camera.ActorController, recipient: [3]i32) camera.Q12Block {
        var position = self.position_q12;
        if (self.binding == .recipient) {
            position[0] +%= recipient[0];
            position[1] +%= recipient[1];
        }
        return .{ .focus = position, .angles = self.angles_q12, .translation = if (self.preserve_translation) controller.target[2] else self.translation_q12.?, .scale = self.scale_q12 };
    }
};
pub const Auxiliary = struct {
    owner_value: i16,
    program: []const u8,
    resource: []const u8,
    animation: u16,
    position_offset_q12: [3]i32,
    home: enum { recipient },
    attachment: enum { recipient_current_pose },
};
pub const Binding = struct {
    id: Technique,
    numerator: u16,
    denominator: u16,
    members: []const []const u8,
    owner_program: []const u8,
    recipient_program: []const u8,
    initial_camera: ?InitialCamera,
    recipient_dispatch_signal: u16,
    damage_signal: u16,
    ready_signal: u16,
    recovery_boundaries: u8,
    auxiliary: ?Auxiliary = null,
};
pub const Playback = struct {
    technique: Technique,
    owner: u8,
    recipient: u8,
    start_at: u32,
    action: ?Action = null,
    amount: u32 = 0,
    owner_done: bool = false,
    recipient_done: bool = false,
    knockout_at: ?u32 = null,
};
pub const Packet = struct {
    schema: []const u8,
    programs: vm.Packet,
    animations: host.Resources,
    techniques: []const Binding,

    pub fn find(self: Packet, technique: Technique) ?*const Binding {
        for (self.techniques) |*binding| if (binding.id == technique) return binding;
        return null;
    }
    pub fn library(self: Packet) host.Library {
        return .{ .programs = self.programs, .resources = self.animations };
    }
    pub fn validateProgram(self: Packet, id: []const u8, resource: host.Resource) !void {
        const program = self.programs.find(id) orelse return error.MissingPhysicalProgram;
        for (program.instructions) |instruction| if (instruction == .command and instruction.command == .animation) {
            if (resource.find(instruction.command.animation) == null) return error.MissingActorAnimation;
        };
    }
    pub fn validate(self: Packet) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-physical-actors/2") or self.techniques.len != 6) return error.InvalidPhysicalBindings;
        try self.programs.validate();
        try self.animations.validate();
        for (self.techniques, 0..) |binding, index| {
            for (self.techniques[0..index]) |prior| if (prior.id == binding.id) return error.InvalidPhysicalBindings;
            const expected = @import("battle_systems").techniques.physical.info(binding.id);
            if (binding.numerator != expected.numerator or binding.denominator != 10 or binding.members.len == 0 or binding.members.len > 78 or binding.recipient_dispatch_signal != 2 or binding.damage_signal != 2 or binding.ready_signal != 4 or binding.recovery_boundaries != (if (binding.id == .boar or binding.id == .clone) @as(u8, 2) else 0) or (binding.auxiliary != null) != (binding.id == .hate)) return error.InvalidPhysicalBindings;
            if (self.programs.find(binding.recipient_program) == null) return error.MissingPhysicalProgram;
            for (binding.members, 0..) |id, ordinal| {
                for (binding.members[0..ordinal]) |prior| if (std.mem.eql(u8, prior, id)) return error.InvalidPhysicalBindings;
                const resource = self.animations.find(id) orelse return error.MissingActorResource;
                if (resource.find(0) == null) return error.MissingActorAnimation;
                try self.validateProgram(binding.owner_program, resource);
            }
            if (binding.initial_camera) |request| {
                if (request.updates == 0 or request.updates > 1000 or request.preserve_translation == (request.translation_q12 != null)) return error.InvalidPhysicalBindings;
                const controller = try camera.ActorController.init(camera.standard_battle);
                try request.target(controller, .{ 0, 0, 0 }).validate();
            }
            if (binding.auxiliary) |child| {
                const resource = self.animations.find(child.resource) orelse return error.MissingActorResource;
                if (resource.find(child.animation) == null or child.owner_value != 1) return error.InvalidPhysicalBindings;
                try self.validateProgram(child.program, resource);
                for (child.position_offset_q12) |offset| if (@rem(offset, 4096) != 0 or @divTrunc(offset, 4096) < -32768 or @divTrunc(offset, 4096) > 32767) return error.InvalidPhysicalBindings;
            }
        }
        for (self.programs.programs) |program| for (program.instructions) |instruction| if (instruction == .command and instruction.command == .child) {
            const child = instruction.command.child;
            const resource = self.animations.find(child.resource) orelse return error.MissingActorResource;
            if (resource.find(child.animation) == null) return error.MissingActorAnimation;
            try self.validateProgram(child.program, resource);
        };
        if (self.programs.find("common/decoy_response") == null) return error.MissingPhysicalProgram;
    }
};
pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Packet) {
    if (bytes.len > 16 * 1024 * 1024) return error.InvalidPhysicalBindings;
    const parsed = try std.json.parseFromSlice(Packet, allocator, bytes, .{});
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}

pub const Action = struct {
    technique: Technique,
    owner: u8,
    recipient: u8,
    stage: enum { auxiliary, recipient, returning, released },
    damage_pending: bool = false,
    recipient_started: bool = false,

    pub fn begin(packet: Packet, runtime: *host.Runtime, technique: Technique, owner: u8, recipient: u8) !Action {
        if (owner == recipient or owner >= runtime.actors.len or recipient >= runtime.actors.len) return error.InvalidActorBinding;
        const binding = packet.find(technique) orelse return error.InvalidPhysicalBindings;
        const resource = runtime.actors[owner].resource orelse return error.MissingActorResource;
        var allowed = false;
        for (binding.members) |id| allowed = allowed or std.mem.eql(u8, resource.id, id);
        if (!allowed) return error.InvalidPhysicalMember;
        try packet.validateProgram(binding.owner_program, resource);
        const target = runtime.actors[recipient].resource orelse return error.MissingActorResource;
        try packet.validateProgram(binding.recipient_program, target);
        try packet.validateProgram("common/decoy_response", target);
        if (binding.initial_camera) |request| {
            const controller = runtime.camera_controller orelse return error.MissingActorCamera;
            try controller.requestQ12(request.target(controller.*, runtime.actors[recipient].position_q12), request.updates);
        }
        try runtime.dispatch(owner, recipient, packet.programs.find(binding.owner_program).?);
        return .{ .technique = technique, .owner = owner, .recipient = recipient, .stage = if (binding.auxiliary != null) .auxiliary else .recipient };
    }

    // Poll before the ascending actor sweep; the recipient's damage callback is independent.
    pub fn advance(self: *Action, packet: Packet, runtime: *host.Runtime) !void {
        const binding = packet.find(self.technique) orelse return error.InvalidPhysicalBindings;
        const owner = &runtime.actors[self.owner];
        switch (self.stage) {
            .auxiliary => {
                const spec = binding.auxiliary.?;
                if (owner.shared_value != spec.owner_value) return;
                var offset: [3]i16 = undefined;
                for (&offset, spec.position_offset_q12) |*destination, value| destination.* = @intCast(@divTrunc(value, 4096));
                if (!try runtime.spawn(self.owner, .{ .program = spec.program, .resource = spec.resource, .animation = spec.animation, .owner = .self, .home = .parent_owner, .offset = offset }, try runtime.actors[self.recipient].attachment())) return;
                owner.shared_value = 99;
                self.stage = .recipient;
            },
            .recipient => if (owner.signals & binding.recipient_dispatch_signal != 0) {
                runtime.actors[self.recipient].signals = 0;
                try runtime.dispatch(self.recipient, self.owner, packet.programs.find(binding.recipient_program).?);
                self.recipient_started = true;
                self.damage_pending = true;
                self.stage = .returning;
            },
            .returning => if (owner.signals & binding.ready_signal != 0) {
                self.stage = .released;
            },
            .released => {},
        }
    }
    pub fn damageReady(self: Action, packet: Packet, runtime: host.Runtime) bool {
        return self.damage_pending and runtime.actors[self.recipient].signals & packet.find(self.technique).?.damage_signal != 0;
    }
    // A failed HP/RNG transaction leaves both the callback and signal pending.
    pub fn acknowledgeDamage(self: *Action, packet: Packet, runtime: *host.Runtime) !void {
        if (!self.damageReady(packet, runtime.*)) return error.PhysicalDamageNotReady;
        runtime.actors[self.recipient].signals &= ~packet.find(self.technique).?.damage_signal;
        self.damage_pending = false;
    }
};
