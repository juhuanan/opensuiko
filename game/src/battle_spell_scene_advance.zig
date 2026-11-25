const rng = @import("battle_rules");
const types = @import("battle_spell_scene_types.zig");
const instance_mod = @import("battle_spell_scene_instance.zig");
const Program = types.Program;
const Instance = instance_mod.Instance;

pub fn advanceTick(self: *Instance, program: Program, draws: *rng.Draws) !void {
    self.elapsed += 1;
    if (program.erosion) |erosion| if (self.elapsed >= erosion.start and self.elapsed < erosion.stop) {
        const levels = self.coverage[0..erosion.levels.len];
        var weight: usize = 0;
        var remaining: usize = 0;
        for (levels, erosion.lower_present) |level, lower| {
            weight += level;
            remaining += @as(usize, @intFromBool(level == 2)) + @as(usize, @intFromBool(level != 0 and lower));
        }
        if (weight < erosion.minimum_weight) {
            @memset(levels, 0);
        } else {
            if (remaining < erosion.budget) return error.InvalidSpellScenes;
            var removed: u16 = 0;
            while (removed < erosion.budget) {
                const cell = try draws.next() % levels.len;
                if (levels[cell] == 0) continue;
                levels[cell] = if (levels[cell] == 2 and erosion.lower_present[cell]) 1 else 0;
                removed += 1;
            }
        }
    };
    for (0..program.emitterCount()) |emitter_index| {
        const emitter = program.emitterAt(emitter_index).*;
        if (self.elapsed < emitter.start or self.elapsed > emitter.stop) continue;
        if (emitter.kind == .ballistic_sprites) {
            if (self.elapsed >= emitter.stop) continue;
            const particles = self.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count];
            for (particles, emitter.spawn_at) |*particle, at| if (self.elapsed == at) {
                const height: i32 = if (emitter.height_range == 0) 0 else try draws.next() % emitter.height_range;
                try particle.circle(emitter.radius, emitter.roots, draws);
                particle.head[2] = (-height << 12) | (particle.head[2] & 4095);
                particle.velocity = .{ emitter.velocity_x, 0, emitter.velocity_z };
                particle.age = 0;
            };
            for (particles) |*particle| {
                if (!particle.active) continue;
                if (emitter.landing_z == 0 and particle.head[2] >> 12 < emitter.min_z) {
                    particle.active = false;
                    continue;
                }
                particle.age += 1;
                particle.velocity[2] += emitter.gravity;
                for (0..3) |axis| particle.head[axis] += particle.velocity[axis];
                if (emitter.landing_z != 0 and particle.head[2] >> 12 >= emitter.landing_z) {
                    particle.active = false;
                    particle.splash_active = true;
                    particle.splash_age = 0;
                    particle.splash_position = particle.head;
                    self.last_landing = self.elapsed;
                    self.last_landing_emitter = @intCast(emitter_index);
                }
            }
            for (particles) |*particle| if (particle.splash_active) {
                particle.splash_age += 1;
                if (particle.splash_age >= program.tracks[emitter.spark_track].len) particle.splash_active = false;
            };
            continue;
        }
        if (emitter.kind == .bouncing_sprites) {
            if (self.elapsed >= emitter.stop) continue;
            const particles = self.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count];
            for (particles, emitter.spawn_at) |*particle, at| if (self.elapsed == at) {
                try particle.circle(emitter.radius, emitter.roots, draws);
                particle.head[2] = emitter.min_z << 12;
                particle.velocity = .{ emitter.velocity_x, 0, 0 };
            };
            for (particles, 0..) |*particle, index| {
                if (!particle.active) continue;
                if (particle.head[2] >> 12 > 0) {
                    particle.head[2] = 0;
                    particle.velocity[2] = @divTrunc(-particle.velocity[2], emitter.bounce_divisor);
                    if (index % emitter.focus_stride == 0) {
                        self.last_landing = self.elapsed;
                        self.last_landing_emitter = @intCast(emitter_index);
                    }
                    if (!particle.splash_active) {
                        particle.splash_age = 0;
                        particle.splash_active = true;
                        particle.splash_position = particle.head;
                    }
                } else particle.velocity[2] += emitter.gravity;
                particle.node_rotation = (particle.node_rotation - @as(i32, try draws.next() % emitter.spin_modulus)) & 65535;
                for (0..3) |axis| particle.head[axis] += particle.velocity[axis];
                particle.age += 1;
                if (particle.head[0] >> 12 < emitter.min_x) particle.active = false;
            }
            for (particles) |*particle| if (particle.splash_active) {
                particle.splash_age += 1;
                if (particle.splash_age >= program.tracks[emitter.spark_track].len) particle.splash_active = false;
            };
            continue;
        }
        if (emitter.kind == .orbiting_sprites or emitter.kind == .drifting_sprites) {
            if (self.elapsed >= emitter.stop) continue;
            const particles = self.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count];
            if (self.elapsed <= emitter.spawn_stop) for (particles, 0..) |*particle, index| {
                if (if (emitter.kind == .orbiting_sprites) self.elapsed != emitter.spawn_at[index] else particle.active) continue;
                const height: i32 = emitter.spawn_height_min + @as(u16, try draws.next() % emitter.height_range);
                try particle.circle(emitter.radius, emitter.roots, draws);
                particle.head[2] = (-height << 12) | (particle.head[2] & 4095);
                particle.age = 0;
                if (emitter.kind == .drifting_sprites) {
                    particle.velocity = .{ emitter.velocity_min + @as(i32, try draws.next() % emitter.velocity_range), 0, emitter.velocity_min + @as(i32, try draws.next() % emitter.velocity_range) };
                    particle.life = @as(u16, try draws.next()) % emitter.life_max;
                }
            };
            for (particles) |*particle| {
                if (!particle.active) continue;
                if (emitter.kind == .drifting_sprites) {
                    if (particle.life == 0 or particle.head[2] >> 12 > 0) {
                        particle.active = false;
                        continue;
                    }
                    for (0..3) |axis| particle.head[axis] += particle.velocity[axis];
                }
                particle.age += 1;
                if (emitter.kind == .orbiting_sprites and particle.age >= emitter.life_max) particle.active = false;
            }
            continue;
        }
        if (emitter.kind == .falling_trails) {
            if (self.elapsed >= emitter.stop) continue;
            const particles = self.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count];
            for (particles, emitter.spawn_at) |*particle, at| if (self.elapsed <= emitter.spawn_stop and ((particle.pending and self.elapsed == at) or (!particle.pending and !particle.active))) {
                try particle.circle(emitter.radius, emitter.roots, draws);
                particle.head[2] = emitter.min_z << 12;
                particle.pending = false;
                particle.age = 0;
            };
            for (particles) |*particle| {
                if (particle.active) {
                    particle.head[2] += emitter.velocity_z;
                    particle.age += 1;
                    if (particle.head[2] >= 0) {
                        self.last_landing = self.elapsed;
                        self.last_landing_emitter = @intCast(emitter_index);
                        particle.active = false;
                        particle.splash_position = particle.head;
                        if (!particle.splash_active) particle.splash_age = 0;
                        particle.splash_active = true;
                    }
                }
                particle.history[0] = .{ .position = particle.head, .visible = particle.active };
                var trail: usize = emitter.trail_count - 1;
                while (trail > 0) : (trail -= 1) particle.history[trail] = particle.history[trail - 1];
                if (particle.splash_active) {
                    particle.splash_age += 1;
                    if (particle.splash_age >= program.tracks[emitter.spark_track].len) particle.splash_active = false;
                }
            }
            continue;
        }
        if (emitter.kind == .cycling_sprites) {
            if (self.elapsed >= emitter.stop) continue;
            const particles = self.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count];
            if (self.elapsed <= emitter.spawn_stop) {
                for (particles) |*particle| if (particle.pending and self.elapsed - emitter.start == particle.life) {
                    try particle.spawnCycle(emitter, draws);
                    if (emitter.focus_on_first) {
                        self.last_landing = self.elapsed;
                        self.last_landing_emitter = @intCast(emitter_index);
                    }
                };
                for (particles) |*particle| if (!particle.pending and !particle.active) {
                    try particle.spawnCycle(emitter, draws);
                    if (emitter.repeat_size_range != 0) particle.size_override = emitter.repeat_size_min + @as(i32, try draws.next() % emitter.repeat_size_range);
                    if (emitter.focus_kick != 0) {
                        self.last_landing = self.elapsed;
                        self.last_landing_emitter = @intCast(emitter_index);
                    }
                };
            }
            for (particles) |*particle| if (particle.active) {
                particle.spawn_scale = program.tracks[emitter.scale_track][self.elapsed].scale;
                particle.age += 1;
                if (particle.age >= emitter.life_max) particle.active = false;
            };
            continue;
        }
        if (emitter.kind == .seeded_spheres) {
            const particles = self.particles[0..emitter.count];
            if (self.elapsed >= emitter.stop) {
                for (particles) |*particle| particle.active = false;
                continue;
            }
            for (particles) |*particle| {
                if (!particle.active and self.elapsed <= emitter.spawn_stop) {
                    try particle.hemisphere(&emitter, draws);
                    particle.age = 0;
                }
                if (!particle.active) continue;
                particle.head[2] = particle.base_z + emitter.oscillation[particle.phase % emitter.oscillation.len];
                particle.phase += 1;
                particle.spawn_scale = program.tracks[emitter.scale_track][self.elapsed].scale;
                particle.age += 1;
                if (particle.age >= emitter.life_max) {
                    if (self.elapsed <= emitter.loop_stop) particle.age = 0 else particle.active = false;
                }
            }
            continue;
        }
        if (emitter.kind == .spherical_sprites) {
            if (self.elapsed >= emitter.stop) continue;
            for (self.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count]) |*particle| {
                if (!particle.active) {
                    try particle.circle(emitter.radius, emitter.roots, draws);
                    const x = particle.head[0] >> 12;
                    const y = particle.head[1] >> 12;
                    const extent: i32 = @as(i32, emitter.roots[@intCast(@as(i32, emitter.radius) * emitter.radius - x * x - y * y)]) + 1;
                    particle.head[2] = -@rem(@as(i32, try draws.next()), extent) << 12;
                    particle.life = try draws.next() % emitter.life_max;
                }
                particle.active = particle.life > 0;
                if (particle.active) {
                    particle.spawn_scale = program.tracks[emitter.scale_track][self.elapsed].scale;
                    particle.age += 1;
                }
            }
            continue;
        }
        if (emitter.kind == .scheduled_pulses) {
            if (self.elapsed >= emitter.stop) continue;
            for (emitter.pulse_spawns) |event| if (event.at == self.elapsed) {
                const particle = &self.particles[emitter.particle_start + event.index];
                const height: i32 = try draws.next() % emitter.height_range;
                try particle.circle(emitter.radius, emitter.roots, draws);
                particle.head[2] = (-height << 12) | (particle.head[2] & 4095);
                particle.splash_position = particle.head;
                particle.pulse_life = emitter.pulse_life;
                particle.pulse_size = 1;
            };
            for (self.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count]) |*particle| if (particle.pulse_life > 0) {
                particle.pulse_size = if (particle.pulse_life > emitter.pulse_fade_at) particle.pulse_size + emitter.pulse_grow else @max(1, particle.pulse_size - emitter.pulse_shrink);
                particle.pulse_life -= 1;
                if (particle.pulse_life == 0) {
                    particle.pulse_size = 1;
                    particle.active = false;
                }
            };
            continue;
        }
        if (emitter.kind == .lightning_bolts) {
            if (self.elapsed >= emitter.stop) continue;
            for (self.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count], emitter.spawn_at, 0..) |*particle, at, index| if (self.elapsed == at) {
                if (emitter.fixed_positions.len != 0) {
                    particle.head = emitter.fixed_positions[index];
                    particle.active = true;
                } else {
                    try particle.circle(emitter.radius, emitter.roots, draws);
                    particle.head[2] = (emitter.min_z << 12) | (particle.head[2] & 4095);
                    if (emitter.spawn_override) |position| particle.head = position;
                }
            };
            if (self.elapsed <= emitter.repeat_until) for (self.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count], emitter.spawn_at) |*particle, at| {
                if (at != emitter.start or particle.active or particle.splash_active) continue;
                try particle.circle(emitter.radius, emitter.roots, draws);
                particle.head[2] = (emitter.min_z << 12) | (particle.head[2] & 4095);
            };
            if (self.elapsed == emitter.strike_at) for (self.targets[0..self.target_count], 0..) |target, index| {
                const particle = &self.particles[@as(usize, emitter.particle_start) + (if (target.formation_slot) |value| @as(usize, value) else index)];
                try particle.circle(emitter.strike_radius, emitter.roots, draws);
                particle.head = .{ target.position[0] << 12, target.position[1] << 12, particle.head[2] & 4095 };
                particle.center = target.center;
            };
            for (self.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count], 0..) |*particle, index| {
                const persistent = emitter.fixed_positions.len != 0 and index >= emitter.persistent_from;
                if (persistent and self.elapsed >= emitter.spark_turn_at and self.elapsed <= emitter.spark_turn_stop) {
                    const angle = @as(i32, self.elapsed - emitter.spark_turn_at + 1) * emitter.spark_turn_step;
                    particle.spark_angle = @min(emitter.spark_turn_limit, angle);
                    if (angle > emitter.spark_turn_limit) particle.splash_active = false;
                }
            }
            for (self.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count]) |*particle| {
                if (self.elapsed >= emitter.flight_stop) particle.active = false;
                if (!particle.active) continue;
                if (!particle.landed) particle.head[2] += emitter.velocity_z;
                if (!particle.landed and particle.head[2] >> 12 > (if (emitter.target_height) self.target[2] else @as(i32, 0))) {
                    self.last_landing = self.elapsed;
                    self.last_landing_emitter = @intCast(emitter_index);
                    particle.head[2] = (particle.head[2] & 4095) | ((if (emitter.target_height) self.target[2] else @as(i32, 0)) << 12);
                    particle.splash_position = particle.head;
                    particle.spark_height = 0;
                    particle.splash_active = true;
                    particle.life = @as(u16, emitter.spark_life_min) + (if (emitter.spark_life_range == 0) @as(u16, 0) else @as(u16, try draws.next() % emitter.spark_life_range));
                    particle.pulse_life = emitter.pulse_life;
                    particle.pulse_size = 1;
                    if (emitter.contact_holds) {
                        particle.landed = true;
                        particle.age += 1;
                    } else particle.active = false;
                } else particle.age += 1;
            }
            for (self.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count], 0..) |*particle, index| {
                const persistent = emitter.fixed_positions.len != 0 and index >= emitter.persistent_from;
                if (emitter.spark_stop != 0 and self.elapsed >= emitter.spark_stop) particle.splash_active = false;
                if (particle.splash_active) {
                    if (!persistent and particle.life > 0) particle.life -= 1;
                    if (particle.life == 0) {
                        if (emitter.spark_velocity_z == 0) particle.splash_active = false else {
                            if (particle.spark_height >> 12 < emitter.spark_min_z) particle.splash_active = false;
                            particle.spark_height += emitter.spark_velocity_z;
                        }
                    }
                    if (particle.splash_active) particle.splash_age += 1;
                }
                if (particle.pulse_life > 0) {
                    particle.pulse_size = if (particle.pulse_life > emitter.pulse_fade_at) particle.pulse_size + emitter.pulse_grow else @max(1, particle.pulse_size - emitter.pulse_shrink);
                    particle.pulse_life -= 1;
                    if (particle.pulse_life == 0) particle.pulse_size = 1;
                }
            }
            continue;
        }
        if (emitter.kind == .falling_lines) {
            if (self.elapsed >= emitter.stop) continue;
            if (self.elapsed <= emitter.spawn_stop) for (self.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count]) |*particle| {
                if (particle.active) continue;
                try particle.circle(emitter.radius, emitter.roots, draws);
                particle.head[2] = (emitter.min_z << 12) | (particle.head[2] & 4095);
                const trail: i32 = @as(i32, emitter.trail_min) + @as(i32, try draws.next() % emitter.trail_range);
                particle.tail = .{ particle.head[0], particle.head[1], ((emitter.min_z - trail) << 12) | (particle.tail[2] & 4095) };
                particle.velocity[2] = emitter.velocity_z + @as(i32, try draws.next() % emitter.speed_range) * 4096;
                _ = try draws.next();
            };
            for (self.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count]) |*particle| {
                if (particle.head[2] >> 12 > 0) {
                    particle.splash_position = particle.head;
                    if (!particle.splash_active) particle.splash_age = 0;
                    particle.splash_active = true;
                    particle.active = false;
                }
                if (particle.active) for (0..3) |axis| {
                    particle.head[axis] += particle.velocity[axis];
                    particle.tail[axis] += particle.velocity[axis];
                };
                if (particle.splash_active) {
                    particle.splash_age += 1;
                    if (particle.splash_age >= program.tracks[emitter.splash_track].len) particle.splash_active = false;
                }
            }
            continue;
        }
        if (emitter.kind == .scheduled_sprites) {
            if (self.elapsed >= emitter.stop) continue;
            if (self.elapsed <= emitter.spawn_stop) {
                for (self.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count]) |*particle| if (particle.pending and particle.life == emitter.spawn_clock[self.elapsed]) {
                    particle.pending = false;
                    try particle.circle(emitter.radius, emitter.roots, draws);
                };
                for (self.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count]) |*particle| if (!particle.pending and !particle.active) try particle.circle(emitter.repeat_radius, emitter.roots, draws);
            }
            for (self.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count]) |*particle| {
                if (!particle.active) continue;
                if ((particle.head[2] >> 12) < emitter.min_z) particle.active = false;
                particle.head[2] += emitter.velocity_z;
                particle.spawn_scale = program.tracks[emitter.scale_track][self.elapsed].scale;
            }
            continue;
        }
        if (emitter.kind == .rising_sprites) {
            if (self.elapsed >= emitter.stop) continue;
            if (self.elapsed <= emitter.spawn_stop) for (self.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count]) |*particle| {
                if (particle.active) continue;
                try particle.circle(emitter.radius, emitter.roots, draws);
                particle.life = @as(u16, try draws.next()) % emitter.life_max;
                particle.active = true;
            };
            for (self.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count]) |*particle| {
                if (particle.life == 0 or (particle.head[2] >> 12) < emitter.min_z) {
                    particle.active = false;
                    continue;
                }
                particle.spawn_scale = program.tracks[emitter.scale_track][self.elapsed].scale;
                particle.head[2] += emitter.velocity_z;
                particle.life -= 1;
            }
            continue;
        }
        if (emitter.kind == .rising_lines) {
            if (self.elapsed >= emitter.stop) continue;
            const particles = self.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count];
            if (self.elapsed <= emitter.spawn_stop) for (particles) |*particle| {
                particle.spawn_scale = program.tracks[emitter.scale_track][self.elapsed].scale;
                if (particle.active) continue;
                const radius: i32 = emitter.radius;
                const x = @rem(@as(i32, try draws.next()), 2 * (radius - 1)) + 1 - radius;
                const extent: i32 = emitter.roots[@intCast(radius * radius - x * x)];
                const y = @rem(@as(i32, try draws.next()), 2 * extent) - extent;
                for ([3]i32{ x, y, 0 }, 0..) |v, axis| particle.head[axis] = (v << 12) | (particle.head[axis] & 4095);
                particle.active = true;
                const trail: i32 = emitter.trail_min + @as(i32, try draws.next() % emitter.trail_range);
                for (0..2) |axis| particle.tail[axis] = (particle.head[axis] & ~@as(i32, 4095)) | (particle.tail[axis] & 4095);
                particle.tail[2] = (-trail << 12) | (particle.tail[2] & 4095);
                particle.velocity = .{ 0, 0, emitter.velocity_z - @as(i32, try draws.next() % emitter.speed_range) * 4096 };
                particle.life = @as(u16, try draws.next()) % emitter.life_max;
            };
            for (particles) |*particle| {
                if (particle.life == 0 or particle.head[2] >> 12 < emitter.min_z) {
                    particle.active = false;
                    continue;
                }
                particle.life -= 1;
                for (0..3) |axis| {
                    particle.head[axis] += particle.velocity[axis];
                    particle.tail[axis] += particle.velocity[axis];
                }
            }
            continue;
        }
        if (emitter.kind == .inward_points) {
            if (self.elapsed >= emitter.stop) continue;
            for (self.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count]) |*particle| {
                if (!particle.active and self.elapsed <= emitter.spawn_stop) {
                    const radius: i32 = emitter.radius;
                    const x = @rem(@as(i32, try draws.next()), 2 * (radius - 1)) + 1 - radius;
                    const extent: i32 = emitter.roots[@intCast(radius * radius - x * x)];
                    const y = @rem(@as(i32, try draws.next()), 2 * extent) - extent;
                    const z = -@as(i32, emitter.roots[@intCast(radius * radius - x * x - y * y)]);
                    const speed: i32 = 128 + @rem(@as(i32, try draws.next()), 64);
                    particle.life = @as(u16, try draws.next()) % 120;
                    for ([3]i32{ x, y, z }, 0..) |v, axis| {
                        particle.head[axis] = (@as(i32, @intCast(@divTrunc(@as(i64, v) * particle.spawn_scale[0], 4096))) << 12) | (particle.head[axis] & 4095);
                        particle.velocity[axis] = -v * speed;
                    }
                    particle.active = true;
                }
                if (particle.life == 0 or @abs(particle.head[0] >> 12) < 5) {
                    particle.active = false;
                    continue;
                }
                particle.life -= 1;
                for (0..3) |axis| particle.head[axis] += particle.velocity[axis];
                particle.spawn_scale = program.tracks[emitter.scale_track][self.elapsed].scale;
            }
            continue;
        }
        for (self.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count]) |*particle| {
            if (!particle.active) {
                if (emitter.spawn_stop != 0 and self.elapsed > emitter.spawn_stop) continue;
                const radius: i32 = emitter.radius;
                const x = @rem(@as(i32, try draws.next()), 2 * (radius - 1)) + 1 - radius;
                const extent: i32 = emitter.roots[@intCast(radius * radius - x * x)];
                if (extent == 0) return error.InvalidSpellScenes;
                const y = @rem(@as(i32, try draws.next()), 2 * extent) - extent;
                const z = -@as(i32, emitter.roots[@intCast(radius * radius - x * x - y * y)]);
                const speed: i32 = 128 + @rem(@as(i32, try draws.next()), 64);
                particle.life = @as(u16, try draws.next()) % 100;
                for ([3]i32{ x, y, z }, 0..) |v, axis| {
                    particle.head[axis] = (v << 12) | (particle.head[axis] & 4095);
                    particle.tail[axis] = (@divTrunc(v * 5, 6) << 12) | (particle.tail[axis] & 4095);
                    particle.velocity[axis] = -v * speed;
                }
                particle.active = true;
            }
            if (self.elapsed == emitter.stop or particle.life == 0 or @abs(particle.tail[0] >> 12) < 5) {
                particle.active = false;
                continue;
            }
            particle.life -= 1;
            for (0..3) |axis| {
                particle.head[axis] += particle.velocity[axis];
                particle.tail[axis] += particle.velocity[axis];
            }
        }
    }
    if (program.scale_noise) |noise| {
        if (self.elapsed >= noise.start and self.elapsed < noise.stop) self.noise_scale += @as(i32, try draws.next() % noise.modulus) + noise.bias;
        // Spawn helpers use the preceding scale; matrix writes follow this update's random scale.
        for (0..program.emitterCount()) |index| {
            const emitter = program.emitterAt(index);
            if (emitter.kind == .cycling_sprites and self.elapsed < program.duration) for (self.particles[emitter.particle_start .. @as(usize, emitter.particle_start) + emitter.count]) |*particle| {
                if (!particle.pending) particle.spawn_scale = self.sampleScale(program.tracks[emitter.scale_track][self.elapsed]);
            };
        }
    }
}
