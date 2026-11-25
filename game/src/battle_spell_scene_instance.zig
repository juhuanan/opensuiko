const camera = @import("battle_camera");
const rng = @import("battle_rules");
const types = @import("battle_spell_scene_types.zig");
const packet_mod = @import("battle_spell_scene_packet.zig");
const advance_mod = @import("battle_spell_scene_advance.zig");
const Sample = types.Sample;
const CameraEvent = types.CameraEvent;
const Emitter = types.Emitter;
const Program = types.Program;
const Packet = packet_mod.Packet;

pub fn transition(from: camera.Block, target: camera.Block, elapsed: u16, duration: u16) camera.Block {
    var result = from;
    const n: i32 = @min(elapsed, duration);
    inline for (.{ "position", "angles", "c", "d" }) |field| for (0..3) |i| {
        const a = @field(from, field)[i] << 12;
        const b = @field(target, field)[i] << 12;
        @field(result, field)[i] = (if (n == duration) b else a + @divTrunc(b - a, duration) * n) >> 12;
    };
    return result;
}
pub fn baseCameraAt(program: Program, update: u16, initial: camera.Block) camera.Block {
    var from = initial;
    var active: ?CameraEvent = null;
    for (program.cameras) |event| {
        if (update < event.at) break;
        if (active) |prior| from = transition(from, prior.target, event.at - prior.at, prior.updates);
        active = event;
    }
    return if (active) |event| transition(from, event.target, update - event.at + 1, event.updates) else initial;
}
pub fn cameraAt(program: Program, update: u16, initial: camera.Block) camera.Block {
    var result = baseCameraAt(program, update, initial);
    if (update < program.focus_samples.len) if (program.focus_samples[update]) |focus| {
        result.position = focus;
    };
    return result;
}
pub const TrailPoint = struct { position: [3]i32 = @splat(0), visible: bool = false };
pub const Particle = struct {
    phase: u16 = 0,
    base_z: i32 = 0,
    spark_height: i32 = 0,
    node_rotation: i32 = 0,
    size_override: i32 = 0,
    history: [10]TrailPoint = @splat(.{}),
    landed: bool = false,
    spark_angle: i32 = 0,
    center: [2]i32 = .{ 0, 0 },
    age: u16 = 0,
    pulse_life: u16 = 0,
    pulse_size: i32 = 1,
    splash_age: u16 = 0,
    splash_active: bool = false,
    splash_position: [3]i32 = @splat(0),
    pending: bool = false,
    spawn_scale: [3]i32 = @splat(4096),
    head: [3]i32 = @splat(0),
    tail: [3]i32 = @splat(0),
    velocity: [3]i32 = @splat(0),
    life: u16 = 0,
    active: bool = false,
    pub fn spawnCycle(self: *Particle, emitter: Emitter, draws: *rng.Draws) !void {
        const height: i32 = if (emitter.height_range != 0) @as(i32, try draws.next() % emitter.height_range) else 0;
        const z = -@divTrunc(height * self.spawn_scale[2], 4096);
        try self.circle(emitter.radius, emitter.roots, draws);
        self.head[2] = (z << 12) | (self.head[2] & 4095);
        self.age = 0;
        self.life = 0;
        self.pending = false;
    }
    pub fn hemisphere(self: *Particle, emitter: *const Emitter, draws: *rng.Draws) !void {
        const radius: i32 = emitter.radius;
        const x = @rem(@as(i32, try draws.next()), 2 * (radius - 1)) + 1 - radius;
        const edge: i32 = emitter.roots[@intCast(radius * radius - x * x)];
        if (edge == 0) return error.InvalidSpellScenes;
        const y = @rem(@as(i32, try draws.next()), 2 * edge) - edge;
        const depth: i32 = @as(i32, emitter.roots[@intCast(radius * radius - x * x - y * y)]) + 1;
        const z = -@rem(@as(i32, try draws.next()), depth);
        for ([3]i32{ x, y, z }, 0..) |value, axis| self.head[axis] = (@divTrunc(value * self.spawn_scale[axis], 4096) << 12) | (self.head[axis] & 4095);
        self.active = true;
    }
    pub fn circle(self: *Particle, radius: i32, roots: []const u16, draws: *rng.Draws) !void {
        const x = @rem(@as(i32, try draws.next()), 2 * (radius - 1)) + 1 - radius;
        const extent: i32 = roots[@intCast(radius * radius - x * x)];
        if (extent == 0) return error.InvalidSpellScenes;
        const y = @rem(@as(i32, try draws.next()), 2 * extent) - extent;
        for ([3]i32{ x, y, 0 }, 0..) |value, axis| self.head[axis] = (@divTrunc(value * self.spawn_scale[axis], 4096) << 12) | (self.head[axis] & 4095);
        self.active = true;
    }
};
pub const Target = struct { home: ?[3]i32 = null, motion_origin: ?[3]i32 = null, return_origin: ?[3]i32 = null, size_base: i32 = 4096, movable: bool = true, formation_slot: ?u8 = null, actor: ?usize = null, position: [3]i32 = .{ 0, 0, 0 }, center: [2]i32 = .{ 0, 0 } };
pub const Instance = struct {
    coverage: [16384]u2 = @splat(0),
    noise_scale: i32 = 0,
    party: [6]Target = @splat(.{}),
    party_count: u8 = 0,
    flicker_phase: u1 = 0,
    targets: [6]Target = @splat(.{}),
    target_count: u8 = 0,
    spell: usize,
    unite_scene: bool = false,
    draws: [150]u15 = @splat(0),
    caster: [3]i32,
    target: [3]i32,
    target_height: u16 = 0,
    target_idle_center: [2]i32 = .{ 0, 0 },
    target_center: [2]i32 = .{ 0, 0 },
    initial_camera: camera.Block,
    elapsed: u16 = 0,
    last_landing: u16 = 0,
    last_landing_emitter: u8 = 0,
    particles: [90]Particle = @splat(.{}),
    pub fn sampleScale(self: *const Instance, sample: Sample) [3]i32 {
        var scale = sample.scale;
        if (sample.noise_scale) for (&scale) |*value| {
            value.* += self.noise_scale;
        };
        return scale;
    }
    pub fn begin(packet: *const Packet, spell: usize, caster: [3]i32, target: [3]i32, initial: camera.Block, draws: *rng.Draws) !Instance {
        return beginForParty(packet, spell, caster, target, initial, draws, &.{});
    }
    pub fn sceneProgram(self: Instance, packet: *const Packet) Program {
        return (if (self.unite_scene) packet.unite_scenes[self.spell] else packet.spells[self.spell]).program.?;
    }
    pub fn beginUnite(packet: *const Packet, scene: usize, initial: camera.Block, draws: *rng.Draws) !Instance {
        return beginScene(packet, scene, true, .{ 0, 0, 0 }, .{ 0, 0, 0 }, initial, draws, &.{});
    }
    pub fn beginForParty(packet: *const Packet, spell: usize, caster: [3]i32, target: [3]i32, initial: camera.Block, draws: *rng.Draws, party: []const Target) !Instance {
        return beginScene(packet, spell, false, caster, target, initial, draws, party);
    }
    fn beginScene(packet: *const Packet, spell: usize, unite: bool, caster: [3]i32, target: [3]i32, initial: camera.Block, draws: *rng.Draws, party: []const Target) !Instance {
        const scenes = if (unite) packet.unite_scenes else packet.spells;
        if (spell >= scenes.len or scenes[spell].program == null) return error.UnreadySpellScene;
        const program = scenes[spell].program.?;
        for (0..program.emitterCount()) |emitter_index| if (program.emitterAt(emitter_index).target_height) {
            for (target) |value| if (@abs(value) > 32767) return error.InvalidSpellTargets;
        };
        if (party.len > 6 or (program.initial_draws_per_party != 0 and party.len == 0)) return error.InvalidSpellTargets;
        var result = Instance{ .spell = spell, .unite_scene = unite, .caster = caster, .target = target, .initial_camera = initial, .party_count = @intCast(party.len) };
        @memcpy(result.party[0..party.len], party);
        if (program.erosion) |erosion| @memcpy(result.coverage[0..erosion.levels.len], erosion.levels);
        const count = @as(usize, program.initial_draws) + @as(usize, program.initial_draws_per_party) * party.len;
        if (count > result.draws.len) return error.InvalidSpellScenes;
        for (result.draws[0..count]) |*value| value.* = try draws.next();
        for (0..program.emitterCount()) |emitter_index| {
            const emitter = program.emitterAt(emitter_index);
            if (emitter.kind == .seeded_spheres) for (result.particles[0..emitter.count], 0..) |*particle, i| {
                particle.age = result.draws[5 * i] % emitter.initial_warmup;
                particle.phase = result.draws[5 * i + 1] % emitter.initial_phase;
                var seeded = rng.Draws{ .values = result.draws[5 * i + 2 .. 5 * i + 5] };
                try particle.hemisphere(emitter, &seeded);
                particle.base_z = particle.head[2];
            };
            if (emitter.kind == .inward_points) for (result.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count], emitter.point_initial_scales) |*particle, scale| {
                particle.spawn_scale = @splat(scale);
            };
            if (emitter.kind == .scheduled_sprites or (emitter.kind == .cycling_sprites and emitter.initial_delays)) {
                for (result.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count], 0..) |*particle, i| {
                    particle.pending = true;
                    particle.life = result.draws[emitter.initial_delay_draw + i * emitter.delay_stride] % emitter.delay_modulus + emitter.delay_bias;
                }
            }
        }
        for (0..program.emitterCount()) |emitter_index| {
            const emitter = program.emitterAt(emitter_index);
            if (emitter.kind == .falling_trails) for (result.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count]) |*particle| {
                particle.pending = true;
            };
        }
        return result;
    }
    pub fn advance(self: *Instance, packet: *const Packet, update: u16, draws: *rng.Draws) !void {
        const program = self.sceneProgram(packet);
        if (update < self.elapsed or update > program.duration) return error.InvalidSpellSceneTime;
        for (0..program.emitterCount()) |emitter_index| {
            const emitter = program.emitterAt(emitter_index);
            if (emitter.strike_at != 0) {
                if (self.target_count == 0 or self.target_count > self.targets.len) return error.InvalidSpellTargets;
                var slots: u8 = 0;
                for (self.targets[0..self.target_count], 0..) |target, index| {
                    for (target.position ++ target.center) |value| if (@abs(value) > 32767) return error.InvalidSpellTargets;
                    const slot: usize = if (target.formation_slot) |value| value else index;
                    if (slot >= 6 or slot >= emitter.count) return error.InvalidSpellTargets;
                    const bit = @as(u8, 1) << @as(u3, @intCast(slot));
                    if (slots & bit != 0) return error.InvalidSpellTargets;
                    slots |= bit;
                }
            }
        }
        while (self.elapsed < update) {
            try advance_mod.advanceTick(self, program, draws);
        }
    }
};
