const std = @import("std");
const battle = @import("battle.zig");
const presentation = battle.presentation;
const camera = @import("battle_camera");
const departure = @import("battle_departure_data.zig");

pub const viewport_top = 38;
pub const viewport_height = 298;

pub const FeedbackRows = struct {
    used: std.StaticBitSet(viewport_height) = .empty,

    pub fn place(self: *FeedbackRows, preferred_y: i32, height: i32) ?i32 {
        if (height <= 0 or height > viewport_height) return null;
        const last = viewport_height - height;
        const preferred: usize = @intCast(std.math.clamp(preferred_y, viewport_top, viewport_top + last) - viewport_top);
        const pixels: usize = @intCast(height);
        var row = preferred;
        while (true) : (row -= 1) {
            if (self.claim(row, pixels)) return viewport_top + @as(i32, @intCast(row));
            if (row == 0) break;
        }
        for (preferred + 1..@as(usize, @intCast(last)) + 1) |below| {
            if (self.claim(below, pixels)) return viewport_top + @as(i32, @intCast(below));
        }
        return null;
    }

    fn claim(self: *FeedbackRows, row: usize, height: usize) bool {
        const gap = 2;
        for (row -| gap..@min(viewport_height, row + height + gap)) |pixel| {
            if (self.used.isSet(pixel)) return false;
        }
        self.used.setRangeValue(.{ .start = row, .end = row + height }, true);
        return true;
    }
};

pub fn homePosition(state: *const battle.State, index: usize) battle.Position {
    return if (index < state.partyCount()) state.content.formation_slots[state.formationSlot(index)] else state.content.encounters[state.encounter].positions[index - state.partyCount()];
}
pub fn worldPosition(state: *const battle.State, index: usize) battle.Position {
    if (departurePosition(state, index)) |flight_position| return flight_position;
    if (index < state.partyCount()) if (state.party_knockouts[index].revival) |instance| return instance.origin;
    if (!state.unite_vm.ownsActor(index) and state.unite_vm.idle[index] != null) {
        if (state.spellActorPosition(index)) |spell_position| return spell_position;
    }
    return state.uniteActorPosition(index) orelse state.spellActorPosition(index) orelse ambientWorldPosition(state, index);
}
pub fn departurePosition(state: *const battle.State, index: usize) ?battle.Position {
    if (index >= state.partyCount() or !state.departed[index]) return null;
    const flight = state.departures[index] orelse return null;
    const age = @min(state.camera_ticks -% flight.started_at, departure.offsets.len - 1);
    const offset = departure.offsets[age];
    return .{
        .x = flight.origin.x + @as(f32, @floatFromInt(offset[0])) / 4096,
        .y = flight.origin.y + @as(f32, @floatFromInt(offset[1])) / 4096,
        .z = flight.origin.z + @as(f32, @floatFromInt(offset[2])) / 4096,
    };
}
pub fn ambientWorldPosition(state: *const battle.State, index: usize) battle.Position {
    const p = ambientPositionWithoutOffset(state, index);
    const shift = state.actor_transforms[index].world_offset;
    return .{ .x = p.x + shift.x, .y = p.y + shift.y, .z = p.z + shift.z };
}
fn ambientPositionWithoutOffset(state: *const battle.State, index: usize) battle.Position {
    if (state.content.world_art) |art| return battle.world_art.actorSample(art, state, index).sample.position;
    const home = homePosition(state, index);
    if (formationShiftPosition(state, index)) |shifted| return shifted;
    if (state.uniteReturnFor(index)) |tail| return presentation.actorPosition(home, homePosition(state, tail.target), state.uniteTrack(index).?.motion, state.animationTick(index));
    if (state.active) |*effect| {
        if (state.isActing(index) and !effect.counter_attack and !state.sourcePhysicalRuneOwner(effect.actor) and !state.uniteMemberWaiting(index) and (effect.kind == .attack or effect.kind == .miss or effect.kind == .unite)) {
            const ticks = state.animationTick(index);
            const target = homePosition(state, effect.target);
            if (state.actionMotion(index)) |motion| {
                const start = effect.motion_origin orelse if (effect.followup_from) |previous| presentation.offset(homePosition(state, previous), motion.approach.offset) else home;
                return presentation.actorPositionFrom(start, home, target, motion, ticks);
            }
            // shortcut: enemy movement remains a port lunge; export its actor motion when extending presentation.
            const travel: f32 = if (ticks < 14) @as(f32, @floatFromInt(ticks)) / 14 else if (ticks < 30) 1 else if (ticks < 46) @as(f32, @floatFromInt(46 - ticks)) / 16 else 0;
            return .{ .x = home.x + (target.x - home.x) * 0.7 * travel, .y = home.y + (target.y - home.y) * 0.7 * travel, .z = home.z };
        }
    }
    return home;
}

fn formationShiftPosition(state: *const battle.State, index: usize) ?battle.Position {
    if (state.content.world_art != null or index >= state.partyCount()) return null;
    const shift = state.formation_shifts[index] orelse return null;
    const elapsed = state.camera_ticks -% shift.started_at;
    if (elapsed >= 20) return null;
    const from = state.content.formation_slots[shift.from_slot];
    const home = homePosition(state, index);
    var shifted = from;
    inline for (.{ "x", "y", "z" }) |axis| {
        const velocity = @trunc((@field(home, axis) - @field(from, axis)) * 4096 / 20) / 4096;
        @field(shifted, axis) += velocity * @as(f32, @floatFromInt(elapsed));
    }
    return shifted;
}

fn intPosition(world: battle.Position) [3]i32 {
    return .{ @intFromFloat(@round(world.x)), @intFromFloat(@round(world.y)), @intFromFloat(@round(world.z)) };
}

pub const WorldProjection = union(enum) {
    drops: camera.Block,
    world: presentation.Camera,
    standard: camera.Block,

    pub fn point(self: WorldProjection, world: battle.Position) presentation.ScreenPoint {
        const projected = switch (self) {
            .drops => |block| battle.drops.project(block, intPosition(world)),
            .world => |value| return presentation.project(value, world),
            .standard => |block| camera.projectScene(block, intPosition(world), .{}) orelse return .{ .x = 0, .y = 0, .depth = 1 },
        };
        return .{ .x = projected.x * 2, .y = projected.y * 2, .depth = projected.depth };
    }
};

pub fn worldProjection(state: *const battle.State) WorldProjection {
    if (state.hasDrops()) return .{ .drops = selectCamera(state, true) };
    if (state.content.world_art != null) return .{ .world = sceneArt(state.*).camera };
    return .{ .standard = selectCamera(state, true) };
}

pub fn worldPoint(state: battle.State, world: battle.Position) presentation.ScreenPoint {
    return worldProjection(&state).point(world);
}

pub fn position(state: battle.State, index: usize) presentation.ScreenPoint {
    const world = worldPosition(&state, index);
    return worldPoint(state, world);
}

pub fn currentCamera(state: battle.State) camera.Block {
    return selectCamera(&state, true);
}

/// Seed a new transition from the camera beneath the one-frame impact pulse.
pub fn cameraForTransition(state: *const battle.State) camera.Block {
    return selectCamera(state, false);
}

fn selectCamera(state: *const battle.State, include_pulse: bool) camera.Block {
    const block = if (state.content.world_art != null) castCamera(state, camera.sampleAtStandard(state.camera_ticks), include_pulse) else cameraBlock(state, include_pulse);
    return withEnemyMagicPulse(state, block, include_pulse);
}

fn withEnemyMagicPulse(state: *const battle.State, block: camera.Block, include_pulse: bool) camera.Block {
    var result = block;
    if (include_pulse) if (state.enemy_magic_pulse) |pulse| if (state.camera_ticks -% pulse.issued_at == 1) {
        result.focus[2] += pulse.delta_q12 >> 12;
    };
    return result;
}

fn castCamera(state: *const battle.State, original: camera.Block, include_pulse: bool) camera.Block {
    if (state.hasSpellScene()) {
        const instance = &state.active.?.scene.?;
        const program = state.spell_scenes.?.spells[instance.spell].program.?;
        const update = state.effectTicks();
        return if (state.actor_camera) |controller|
            if (include_pulse) battle.spell_scene.withCameraPulses(program, instance, update, controller.sample()) else controller.sample()
        else if (include_pulse)
            battle.spell_scene.instanceCameraAt(program, instance, update)
        else
            battle.spell_scene.cameraAt(program, update, instance.initial_camera);
    }
    const base = if (state.actor_camera) |controller| controller.sample() else if (state.source_camera_return) |change| battle.spell_scene.transition(change.from, battle.drops.initial_camera, @intCast(@min(state.camera_ticks - change.started, 30)), 30) else state.source_camera_hold orelse original;
    if (state.hasDrops()) return battle.drops.cameraAt(state.effectTicks());
    if (state.active) |effect| {
        if (effect.kind == .cast) {
            if (state.content.systems) |systems| {
                if (effect.spell < systems.spells.len) {
                    if (camera.castPreset(systems.spells[effect.spell].name)) |block| {
                        // shortcut: smoothstep envelope into final preset and back; replace with per-phase source camera events.
                        const t = camera.actionEnvelope(state.effectTicks(), state.actionDuration(), 20, 16);
                        return camera.mix(base, block, t);
                    }
                }
            }
        }
    }
    return base;
}

fn cameraBlock(state: *const battle.State, include_pulse: bool) camera.Block {
    const base = castCamera(state, camera.sampleAtStandard(state.camera_ticks), include_pulse);
    if (state.active) |effect| {
        if (effect.counter_attack) return base;
        if (effect.rune_attack and state.sourcePhysicalRuneOwner(effect.actor)) return base;
        if (effect.kind == .unite and (state.actor_camera != null or state.hasLiveUniteActors())) return base;
        if (effect.kind != .attack and effect.kind != .unite and effect.kind != .miss) return base;
        const target = if (effect.actor < state.partyCount()) camera.attack_party else camera.attack_enemy;
        const t = camera.actionEnvelope(state.effectTicks(), state.actionDuration(), 12, 12);
        return camera.mix(base, target, t);
    }
    return base;
}

pub fn sceneCamera(state: *const battle.State) presentation.Camera {
    const block = selectCamera(state, true);
    var cam = presentation.Camera{
        .transform = camera.transform(block),
        .focal_length = 2048,
        .center_x = 320,
        .center_y = 240,
    };
    const zero = presentation.project(cam, .{ .x = 0, .y = 0, .z = 0 });
    const focus = presentation.project(cam, .{ .x = @floatFromInt(block.focus[0]), .y = @floatFromInt(block.focus[1]), .z = @floatFromInt(block.focus[2]) });
    cam.center_x += zero.x - focus.x;
    cam.center_y += zero.y - focus.y;
    return cam;
}

// Share camera selection between native drawing, headless composition and overlays.
pub fn sceneArt(state: battle.State) battle.world_art.Data {
    var data = state.content.world_art.?;
    if (battlefield(&state)) |entry| data.scenery = entry.scenery;
    const block = selectCamera(&state, true);
    data.camera = sceneCamera(&state);
    data.sprite_scale = camera.scaleBlock(block) * 2;
    return data;
}

pub const ItemAnimation = struct { clip: enum { idle, prepare, hold, recover }, elapsed: u32 };
pub fn itemAnimation(state: *const battle.State, index: usize) ?ItemAnimation {
    if (index >= state.partyCount()) return null;
    const item = state.medicine_action orelse return null;
    const timing = item.timing;
    const definition = state.rules.consumable(item.id).?;
    const reset = if (definition.battle) |effect| effect.reset_pose else true;
    if (!reset and index == item.actor and !item.owner_released and item.ticks >= timing.target_start) return .{ .clip = .hold, .elapsed = 0 };
    if (index == item.actor and !item.owner_released and (item.actor != item.target or item.ticks < timing.target_start or item.interrupted(index))) {
        if (item.ticks < timing.target_start - 1) return .{ .clip = .prepare, .elapsed = item.ticks };
        if (item.ticks < timing.target_start + 60) return .{ .clip = .hold, .elapsed = 0 };
        return .{ .clip = .recover, .elapsed = item.ticks - (timing.target_start + 59) };
    }
    if (reset and item.affects(index) and !item.target_released and item.ticks >= timing.target_start and !item.interrupted(index)) return .{ .clip = .idle, .elapsed = state.presentation_tick -% item.started_at -% (timing.target_start - 1) };
    return null;
}
pub fn itemFrame(state: *const battle.State, index: usize) ?battle.Frame {
    const sample = itemAnimation(state, index) orelse return null;
    const art = state.partyProfile(index).item_art orelse return null;
    const clip = switch (sample.clip) {
        .idle => art.idle,
        .prepare => art.prepare,
        .hold => art.hold,
        .recover => art.recover,
    };
    return clip.frameAt(sample.elapsed);
}

pub fn actorLayout(state: battle.State, index: usize) battle.ActorLayout {
    if (state.content.world_art != null) {
        const actor = battle.world_art.actorLayout(sceneArt(state), state, index);
        return actor;
    }
    const profile = if (index < state.partyCount()) state.partyProfile(index) else state.enemy(index - state.partyCount());
    var point = position(state, index);
    const scale = std.math.clamp(camera.scaleBlock(cameraBlock(&state, true)) * 2, 0.5, 8);
    var sprite = profile.sprite;
    const anchors = if (state.spell_scenes) |packet| packet.statusAnchors(profile.id) else null;
    var source_pose: ?u16 = if (anchors) |value| value.idle_pose else null;
    if (state.uniteReturnFor(index) != null or (state.active != null and state.isActing(index) and !state.uniteMemberWaiting(index) and (state.active.?.kind == .attack or state.active.?.kind == .miss or state.active.?.kind == .unite))) {
        var animation_tick = state.attackFrameTick(index);
        for (state.attackFrames(index)) |frame| {
            sprite = frame.pose;
            source_pose = frame.source_pose;
            if (animation_tick < frame.ticks) break;
            animation_tick -= frame.ticks;
        }
    }
    if (state.active) |effect| if (effect.actor == index and effect.kind == .cast and profile.cast.len > 0) {
        var total: u32 = 0;
        for (profile.cast) |frame| total += frame.ticks;
        const limit = if (state.hasSourceEffect() and state.effectTicks() < state.impactTick()) @min(total - 1, profile.cast_impact -| 1) else total - 1;
        var tick = @min(state.effectTicks() -| @as(u16, if (state.hasSourceEffect()) 1 else 0), limit);
        for (profile.cast) |frame| {
            sprite = frame.pose;
            source_pose = frame.source_pose;
            if (tick < frame.ticks) break;
            tick -= frame.ticks;
        }
    };
    if (itemFrame(&state, index)) |frame| {
        sprite = frame.pose;
        source_pose = frame.source_pose;
    }
    const scripted_pose = state.uniteVmPose(index);
    if (scripted_pose) |pose| {
        sprite = pose;
        source_pose = state.unite_vm.pose(index);
    }
    const screen_offset = if (state.revivalAge(index) != null and profile.revival_art != null) [2]i8{ 0, 0 } else state.uniteScreenOffset(index);
    point.x += @as(f32, @floatFromInt(screen_offset[0])) * scale;
    point.y += @as(f32, @floatFromInt(screen_offset[1])) * scale;
    applySpellReaction(state, index, &point, &sprite);
    if (state.spellReaction(index)) |response| if (response.entry != null) {
        source_pose = if (anchors) |value| (if (response.animation == 0) value.idle_pose else value.hurt_pose) else null;
    };
    const enemy_magic_reaction = if (index < state.unite_vm.scripted_actors.len) if (state.unite_vm.scripted_actors[index]) |binding| binding.family == .enemy_magic and scripted_pose != null else false else false;
    if (index < state.partyCount() and state.hp(index) == 0 and !state.party_knockouts[index].pending and !enemy_magic_reaction) if (profile.revival_art) |art| {
        sprite = art.down.frames[0].pose;
        source_pose = art.down.frames[0].source_pose;
    };
    if (state.revivalAge(index)) |age| if (profile.revival_art) |art| {
        const spec = state.rules.automatic_revival.?;
        const frame = if (age < spec.recovery_start) art.down.frameAt(age) else art.recovery.frameAt(age - spec.recovery_start);
        sprite = frame.pose;
        source_pose = frame.source_pose;
        const offset = state.party_knockouts[index].revival.?.screen_offset;
        point.x += @as(f32, @floatFromInt(offset[0])) * scale;
        point.y += @as(f32, @floatFromInt(offset[1])) * scale;
    };
    return .{ .point = point, .scale = scale * state.actorSize(index), .sprite = sprite, .source_pose = source_pose };
}

pub fn battlefield(state: *const battle.State) ?*const battle.Battlefield {
    const id = state.content.encounters[state.encounter].battlefield orelse return null;
    return state.content.battlefield(id);
}

pub fn scenery(state: *const battle.State) []const battle.Scenery {
    return if (battlefield(state)) |entry| entry.scenery else state.content.scenery;
}

pub const TrailQuad = struct { point: presentation.ScreenPoint, sprite: battle.Pose, scale: f32 };
pub const RevivalQuad = struct { point: presentation.ScreenPoint, sprite: battle.Pose, scale: f32, position: battle.Position, light: [3]u8 };
pub const ItemParticleFrame = struct { quads: [8]RevivalQuad = undefined, count: usize = 0 };
pub fn itemParticles(state: *const battle.State, member: usize) ?ItemParticleFrame {
    if (member >= state.partyCount()) return null;
    const item = state.medicine_action orelse return null;
    if (!item.affects(member) or item.interrupted(member) or item.ticks <= item.timing.target_start or item.ticks >= item.timing.pending_tick - 1) return null;
    const definition = state.rules.consumable(item.id).?;
    const age = item.ticks - item.timing.target_start - 1;
    const origin = item.particle_origins[member] orelse worldPosition(state, member);
    const sprite = item.particle_sprites[member] orelse if (state.content.world_art) |art| art.actors[member].poses[item.particle_poses[member] orelse art.actors[member].animations[0][0].pose] else state.partyProfile(member).sprite;
    var offsets: [8]battle.Position = undefined;
    var count: usize = 0;
    var tint: [3]u8 = .{ 64, 128, 0 };
    if (definition.battle) |effect| {
        tint = effect.particle_tint;
        if (age >= effect.particles.len) return null;
        for (effect.particles[age]) |offset| {
            offsets[count] = .{ .x = offset[0], .y = offset[1], .z = offset[2] };
            count += 1;
        }
    } else if (state.content.world_art) |art| {
        if (age >= art.medicine_particles.len) return null;
        count = 4;
        @memcpy(offsets[0..count], &art.medicine_particles[age]);
    }
    if (count == 0) return null;
    const scale = camera.scaleBlock(currentCamera(state.*)) * 2;
    var result = ItemParticleFrame{ .count = count };
    for (offsets[0..count], result.quads[0..count]) |offset, *quad| {
        const world: battle.Position = .{ .x = origin.x + offset.x, .y = origin.y + offset.y, .z = origin.z + offset.z };
        quad.* = .{ .position = world, .point = worldPoint(state.*, world), .sprite = sprite, .scale = scale, .light = tint };
    }
    return result;
}
pub fn revivalParticles(state: battle.State, member: usize) ?[4]RevivalQuad {
    const positions = battle.revival.revivalParticlePositions(state, member) orelse return null;
    const sprite = if (state.content.world_art) |art| art.actors[member].poses[art.actors[member].animations[3][0].pose] else (state.partyProfile(member).revival_art orelse return null).down.frames[0].pose;
    var quads: [4]RevivalQuad = undefined;
    const scale = camera.scaleBlock(currentCamera(state)) * 2;
    for (&quads, positions) |*quad, world| quad.* = .{ .position = world, .point = worldPoint(state, world), .sprite = sprite, .scale = scale, .light = state.rules.automatic_revival.?.particle_tint };
    return quads;
}
pub fn uniteTrail(state: battle.State, member: usize) ?[8]TrailQuad {
    if (member >= state.partyCount()) {
        const actor = if (member < state.unite_vm.actors.len) body: {
            if (member >= state.partyCount() + state.enemyCount() or !state.unite_vm.ownsActor(member)) return null;
            break :body state.unite_vm.actors[member];
        } else auxiliary: {
            const index = member - state.unite_vm.actors.len;
            if (index >= state.unite_vm.auxiliary.len) return null;
            break :auxiliary state.unite_vm.auxiliary[index] orelse return null;
        };
        const trail = actor.blue_trail orelse return null;
        if (!trail.visible or actor.retired) return null;
        const poses = findTrail(state, actor.resource.?.id, trail.pose, actor.graphic_record) orelse return null;
        var result: [8]TrailQuad = undefined;
        for (&result, 0..) |*quad, ordinal| {
            const age: u3 = @intCast(7 - ordinal);
            const sample = trail.newest(age);
            quad.* = .{ .point = .{ .x = sample.position[0], .y = sample.position[1], .depth = trail.depth }, .sprite = poses[age], .scale = camera.scaleBlock(currentCamera(state)) * 2 };
        }
        return result;
    }
    if (member >= state.partyCount() or !state.unite_trails[member].visible) return null;
    const poses = if (state.unite_vm.ownsActor(member)) live: {
        const actor = state.unite_vm.actors[member];
        const record: ?u8 = if (state.unite_vm.owns(member)) state.unite_vm.members[member].?.record else null;
        if (actor.blue_trail) |trail| if (state.content.uniteGraphicPose(actor.resource.?.id, trail.pose, record)) |pose| {
            if (pose.trail) |poses| break :live poses;
        };
        break :live ((state.uniteTrack(member) orelse return null).trail orelse return null).poses;
    } else ((state.uniteTrack(member) orelse return null).trail orelse return null).poses;
    const ring = state.unite_trails[member];
    const scale = actorLayout(state, member).scale;
    var result: [8]TrailQuad = undefined;
    for (&result, 0..) |*quad, index| {
        const age = 7 - index;
        const slot = (@as(usize, ring.next) + 7 - age) % 8;
        quad.* = .{ .point = ring.points[slot], .sprite = poses[age], .scale = scale };
    }
    return result;
}
fn findTrail(state: battle.State, resource: []const u8, frozen_pose: u16, record: ?u8) ?[8]battle.Pose {
    return (state.content.uniteGraphicPose(resource, frozen_pose, record) orelse return null).trail;
}

pub fn shadowLayout(state: battle.State, index: usize) presentation.Shadow {
    const home = homePosition(&state, index);
    const actor = worldPosition(&state, index);
    const ground = battle.Position{ .x = actor.x, .y = actor.y, .z = home.z };
    const point = worldPoint(state, ground);
    const home_point = worldPoint(state, home);
    const base_scale = camera.scaleBlock(currentCamera(state)) * 2;
    const depth_ratio = if (point.depth > 1) std.math.clamp(home_point.depth / point.depth, 0.25, 4) else 1;
    const scale = base_scale * depth_ratio;
    return .{ .point = point, .radius_x = 12 * scale, .radius_y = 5 * scale };
}

pub const Bounds = struct {
    left: f32 = std.math.inf(f32),
    top: f32 = std.math.inf(f32),
    right: f32 = -std.math.inf(f32),
    bottom: f32 = -std.math.inf(f32),

    fn include(self: *Bounds, left: f32, top: f32, right: f32, bottom: f32) void {
        self.left = @min(self.left, left);
        self.top = @min(self.top, top);
        self.right = @max(self.right, right);
        self.bottom = @max(self.bottom, bottom);
    }
};

// The complete action envelope keeps framing independent of animation time.
pub fn bounds(state: battle.State) Bounds {
    var result: Bounds = .{};
    var sample = state;
    if (sample.active != null) sample.active.?.started_at = 0;
    const duration = if (state.active != null) state.actionDuration() else 0;
    for (0..@as(usize, duration) + 1) |tick| {
        sample.action_ticks = @intCast(tick);
        for (0..sample.partyCount() + sample.enemyCount()) |index| {
            if (index < sample.partyCount() and sample.departed[index]) continue;
            const actor = actorLayout(sample, index);
            const x = actor.point.x;
            const y = actor.point.y;
            const left = x - @as(f32, @floatFromInt(actor.sprite.anchor_x)) * actor.scale;
            const top = y - @as(f32, @floatFromInt(actor.sprite.anchor_y)) * actor.scale;
            result.include(@min(left - 24, x - 42), @min(top - 46, y - 116), @max(left + @as(f32, @floatFromInt(actor.sprite.rect.w)) * actor.scale, x + 108), @max(top + @as(f32, @floatFromInt(actor.sprite.rect.h)) * actor.scale, y + 12));
            if (index < sample.partyCount()) {
                const shadow = shadowLayout(sample, index);
                result.include(shadow.point.x - shadow.radius_x, shadow.point.y - shadow.radius_y, shadow.point.x + shadow.radius_x, shadow.point.y + shadow.radius_y);
            }
        }
    }
    if (state.active) |effect| if (effect.kind == .cast) {
        const spell = state.content.systems.?.spells[effect.spell];
        const caster = position(state, effect.actor);
        result.include(caster.x - 40, caster.y - 100, caster.x + 40, caster.y + 16);
        const first = if (spell.group) (if (spell.allies) @as(usize, 0) else state.partyCount()) else effect.target;
        const end = if (spell.group) first + (if (spell.allies) state.partyCount() else state.enemyCount()) else first + 1;
        for (first..end) |target| {
            const at = position(state, target);
            // Includes the current authored travel trail and expanding impact ring.
            result.include(at.x - 60, at.y - 140, at.x + 64, at.y + 36);
        }
    };
    return result;
}

pub const Framing = struct {
    zoom: f32 = 1,
    x: f32 = 0,
    y: f32 = 0,

    pub fn fit(area: Bounds) Framing {
        const zoom = @min(1, @min(624 / @max(1, area.right - area.left), 254 / @max(1, area.bottom - area.top)));
        return .{ .zoom = zoom, .x = @max(8 - area.left * zoom, @min(0, 632 - area.right * zoom)), .y = @max(76 - area.top * zoom, @min(0, 330 - area.bottom * zoom)) };
    }
};

pub fn framing(state: battle.State) Framing {
    _ = state;
    return .{};
}

pub fn applySpellReaction(state: battle.State, index: usize, point: *presentation.ScreenPoint, sprite: *battle.Pose) void {
    const reaction = state.spellReaction(index) orelse return;
    const block = currentCamera(state);
    const dx = @divTrunc(@as(i32, reaction.offset[0]) * @divTrunc(block.scale[0] << 10, block.translation[2]), 4096);
    const dy = @divTrunc(@as(i32, reaction.offset[1]) * @divTrunc(block.scale[1] << 10, block.translation[2]), 4096);
    point.x += @as(f32, @floatFromInt(dx)) * 2;
    point.y += @as(f32, @floatFromInt(dy)) * 2;
    if (reaction.entry) |entry_id| {
        const entry = state.spell_scenes.?.entries[entry_id];
        sprite.* = .{ .rect = .{ .x = entry.x, .y = entry.y, .w = entry.w, .h = entry.h }, .anchor_x = @intCast(-entry.dx), .anchor_y = @intCast(-entry.dy) };
    }
    if (reaction.flip_y) sprite.anchor_y = @intCast(sprite.rect.h - sprite.anchor_y);
}

pub const AuxiliaryQuad = struct { vertices: [4]presentation.ScreenPoint, sprite: battle.Pose, translucent: bool, depth: f32, effect: bool = false, color: [3]u8 = @splat(128), blend: battle.spell_scene.Blend = .@"opaque" };
pub fn rotatedActorQuad(state: battle.State, index: usize, sprite: battle.Pose, point: presentation.ScreenPoint) ?AuxiliaryQuad {
    const transform = state.actor_transforms[index];
    const angles = transform.node_angles;
    if (std.mem.eql(i16, &angles, &.{ 0, 0, 0 })) return null;
    var block = currentCamera(state);
    for (&block.scale) |*value| value.* = @intCast(@divTrunc(@as(i64, value.*) * transform.scale_q12, 4096));
    return ordinaryRotatedNodeQuad(block, point, sprite, angles);
}
pub fn uniteAuxiliary(state: battle.State, index: usize) ?AuxiliaryQuad {
    return uniteAuxiliaryPiece(state, index, 0);
}
pub fn uniteAuxiliaryPiece(state: battle.State, index: usize, piece: usize) ?AuxiliaryQuad {
    if (piece != 0 and index >= state.unite_vm.auxiliary.len) return null;
    if (index >= mirage_copy_offset) return mirageCopy(state, index - mirage_copy_offset);
    if (index >= siren_note_offset) return sirenNote(state, index - siren_note_offset);
    if (index >= ivy_graphic_offset) return ivyPart(state, index - ivy_graphic_offset);
    if (index >= state.unite_vm.auxiliary.len + 6 * 5) return uniteTrick(state, index - state.unite_vm.auxiliary.len - 6 * 5);
    if (index >= state.unite_vm.auxiliary.len) return uniteFan(state, index - state.unite_vm.auxiliary.len);
    const actor = state.unite_vm.auxiliary[index] orelse return null;
    // shortcut: vertical flag2 needs its own vertex path before those families are admitted.
    if (!actor.visible or actor.retired or (actor.has_draw_record and actor.record_flags & 2 != 0)) return null;
    const resource = actor.resource orelse return null;
    if (!actor.has_draw_record) {
        if (piece != 0) return null;
        const shared = std.mem.eql(u8, resource.id, "shared_impacts");
        const sprite = if (shared) impact: {
            const packet = state.spell_scenes orelse return null;
            const clip = for (packet.unite_impacts) |clip| {
                if (clip.id == actor.animation) break clip;
            } else return null;
            if (actor.frame >= clip.frames.len) return null;
            const entry = packet.entries[clip.frames[actor.frame].entry];
            break :impact battle.Pose{ .rect = .{ .x = entry.x, .y = entry.y, .w = entry.w, .h = entry.h }, .anchor_x = @intCast(-entry.dx), .anchor_y = @intCast(-entry.dy) };
        } else (state.content.uniteGraphicPose(resource.id, actor.currentFrame().pose, actor.graphic_record) orelse return null).sprite;
        var quad = ordinaryRotatedNodeQuad(currentCamera(state), auxiliaryPoint(state, actor), sprite, actor.draw_angles);
        quad.translucent = actor.translucent or resource.find(actor.animation).?.semitransparent;
        quad.effect = shared;
        quad.color = actor.color orelse @splat(128);
        return quad;
    }
    const sprite = selected: {
        for (state.content.unite_graphics) |graphic| if (graphic.record == null and std.mem.eql(u8, graphic.id, resource.id)) {
            for (graphic.poses) |pose| if (pose.id == actor.currentFrame().pose) {
                if (pose.pieces.len != 0) {
                    if (piece >= pose.pieces.len) return null;
                    break :selected pose.pieces[piece];
                }
                if (piece != 0) return null;
                break :selected pose.sprite;
            };
        };
        return null;
    };
    const block = currentCamera(state);
    const scale = camera.scaleBlock(block);
    const anchor = auxiliaryPoint(state, actor);
    const angles: [3]i32 = if (actor.record_flags & 4 != 0) .{ actor.draw_angles[0], actor.draw_angles[1], actor.draw_angles[2] } else .{ block.angles[0], block.angles[1], 360 };
    const qscale: i32 = @intFromFloat(@round(scale * 4096));
    const local = camera.Block{ .focus = .{ 0, 0, 0 }, .angles = angles, .translation = .{ 0, 0, 1024 }, .scale = @splat(qscale) };
    var quad = AuxiliaryQuad{ .vertices = undefined, .sprite = sprite, .translucent = actor.translucent or resource.find(actor.animation).?.semitransparent, .depth = anchor.depth, .color = actor.color orelse @splat(128) };
    for (&quad.vertices, 0..) |*vertex, corner| {
        const x: i32 = -@as(i32, sprite.anchor_x) + (if (corner & 1 != 0) sprite.rect.w - 1 else @as(i32, 0));
        const y: i32 = -@as(i32, sprite.anchor_y) + (if (corner >= 2) sprite.rect.h - 1 else @as(i32, 0));
        const point = camera.rawProject(local, .{ x, y, 0 });
        vertex.* = .{ .x = anchor.x + @as(f32, @floatFromInt(point[0])) * 2, .y = anchor.y + @as(f32, @floatFromInt(point[1])) * 2, .depth = anchor.depth };
    }
    return quad;
}
pub fn auxiliaryPoint(state: battle.State, actor: battle.actor_host.Actor) presentation.ScreenPoint {
    var point = worldPoint(state, .{ .x = @floatFromInt(actor.position_q12[0] >> 12), .y = @floatFromInt(actor.position_q12[1] >> 12), .z = @floatFromInt(actor.position_q12[2] >> 12) });
    const scale = camera.scaleBlock(currentCamera(state)) * 2;
    point.x += @as(f32, @floatFromInt(actor.screen_offset[0])) * scale;
    point.y += @as(f32, @floatFromInt(actor.screen_offset[1])) * scale;
    return point;
}

// Five controller-owned objects per member, outside the shared script actor pool.
pub const ivy_graphic_offset = 19 + 6 * 5 + 8;
pub const siren_note_offset = ivy_graphic_offset + 19 * 18;
pub const mirage_copy_offset = siren_note_offset + 6 * 16;
pub const mirage_copy_capacity = 6 * battle.actor_host.MirageVisual.max_copies;
pub const unite_graphic_capacity = mirage_copy_offset + mirage_copy_capacity;

fn mirageCopy(state: battle.State, index: usize) ?AuxiliaryQuad {
    const stride = battle.actor_host.MirageVisual.max_copies;
    const enemy_index = index / stride;
    const copy_index = index % stride;
    if (enemy_index >= state.enemyCount()) return null;
    const actor_index = state.partyCount() + enemy_index;
    if (!state.unite_vm.ownsActor(actor_index)) return null;
    const actor = &state.unite_vm.actors[actor_index];
    const worker = actor.mirage_worker orelse return null;
    const binding = actor.regional orelse return null;
    const visual = binding.mirage_visual orelse return null;
    if (copy_index >= visual.copies or (actor.shared_value != 1 and actor.shared_value != 2 and actor.shared_value != 99)) return null;
    if (actor.shared_value == 1 and worker.timer == 0) return null;

    var center = worker.origin_q12;
    // The zero-tint frame at the handoff belongs to the departure phase.
    if (actor.shared_value != 1 and worker.timer < worker.phase_updates) {
        for (&center, worker.delta_q12) |*coordinate, delta| coordinate.* +%= delta;
    }
    const spread_slot = @as(i32, @intCast(copy_index)) - @as(i32, visual.copies / 2);
    center[1] +%= spread_slot * visual.spread_step_q12 * worker.timer;
    const tint: u8 = @intCast(@as(u32, visual.modulation) * (worker.phase_updates - worker.timer) / worker.phase_updates);
    const point = worldPoint(state, .{ .x = @floatFromInt(center[0] >> 12), .y = @floatFromInt(center[1] >> 12), .z = @floatFromInt(center[2] >> 12) });
    var sprite = (state.content.uniteGraphicPose(binding.id, visual.pose, null) orelse return null).sprite;
    const x, const y, const width, const height = visual.crop;
    sprite.rect.x += x;
    sprite.rect.y += y;
    sprite.rect.w = width;
    sprite.rect.h = height;
    sprite.anchor_x -= x;
    sprite.anchor_y -= y;
    const block = currentCamera(state);
    const scale_x = @divTrunc(block.scale[0] << 10, block.translation[2]);
    const scale_y = @divTrunc(block.scale[1] << 10, block.translation[2]);
    const left = point.x + @as(f32, @floatFromInt(2 * @divTrunc(-@as(i32, sprite.anchor_x) * scale_x, 4096)));
    const top = point.y + @as(f32, @floatFromInt(2 * @divTrunc(-@as(i32, sprite.anchor_y) * scale_y, 4096)));
    const right = left + @as(f32, @floatFromInt(2 * @divTrunc(@as(i32, width) * scale_x, 4096)));
    const bottom = top + @as(f32, @floatFromInt(2 * @divTrunc(@as(i32, height) * scale_y, 4096)));
    return .{
        .sprite = sprite,
        .translucent = true,
        .color = @splat(tint),
        .blend = .subtractive,
        .depth = @floatFromInt(std.math.clamp(@as(i32, @intFromFloat(point.depth)) >> 2, 5, 379) * 4),
        .vertices = .{
            .{ .x = left, .y = top, .depth = point.depth },
            .{ .x = right, .y = top, .depth = point.depth },
            .{ .x = left, .y = bottom, .depth = point.depth },
            .{ .x = right, .y = bottom, .depth = point.depth },
        },
    };
}
fn sirenNote(state: battle.State, index: usize) ?AuxiliaryQuad {
    const enemy_index = index / 16;
    const note_index = index % 16;
    if (enemy_index >= state.enemyCount()) return null;
    const slot = state.partyCount() + enemy_index;
    if (slot >= state.unite_vm.enemy_magic_actions.len) return null;
    const action = state.unite_vm.enemy_magic_actions[slot] orelse return null;
    const area = action.area orelse return null;
    if (area != .siren or note_index >= area.siren.notes.len) return null;
    const note = area.siren.notes[note_index];
    if (!note.enabled or action.phase != .running or action.update == 0) return null;
    const bundle = state.unite_actors orelse return null;
    const binding = bundle.areaMagicFor(state.enemy(action.owner - state.partyCount()).id) orelse return null;
    if (action.update >= binding.worker.cleanup_update) return null;
    const waves = binding.worker.waves orelse return null;
    const pose = waves.note_poses[note_index % 4];
    const sprite = (state.content.uniteGraphicPose("siren", pose, null) orelse return null).sprite;
    const world = battle.spell_scene.vectorTransform(waves.note_local, .{ 0, waves.angle_y, note.angle_z }, @splat(note.scale), .{ action.root[0], action.root[1], action.root[2] });
    var block = currentCamera(state);
    const projected = camera.projectScene(block, world, .{}) orelse return null;
    for (&block.scale) |*value| value.* = @intCast(@divTrunc(@as(i64, value.*) * waves.note_size, 4096));
    const point = presentation.ScreenPoint{ .x = projected.x * 2, .y = projected.y * 2, .depth = projected.depth };
    var quad = ordinaryRotatedNodeQuad(block, point, sprite, .{ 0, 0, 0 });
    quad.translucent = true;
    return quad;
}
fn ivyPart(state: battle.State, index: usize) ?AuxiliaryQuad {
    const actor_index = index / 18;
    const part_index = index % 18;
    if (actor_index >= state.unite_vm.actors.len) return null;
    const actor = state.unite_vm.actors[actor_index];
    const vine = actor.ivy_vine orelse return null;
    if (!vine.visible or actor.retired) return null;
    const resource = actor.resource orelse return null;
    const packet = (state.unite_actors orelse return null).counterPacket() orelse return null;
    const art = (packet.meleeEnemy(resource.id) orelse return null).vine_art orelse return null;
    const role = if (part_index < 12) art.strip else art.leaves[(part_index - 12) / 3];
    const sprite = (state.content.uniteGraphicPose(resource.id, role, actor.graphic_record) orelse return null).sprite;
    const block = currentCamera(state);
    var points: [13][3]i32 = undefined;
    for (vine.samples(), &points) |world, *point| {
        const projected = camera.projectScene(block, .{ world[0] >> 12, world[1] >> 12, world[2] >> 12 }, .{}) orelse return null;
        point.* = .{ @intFromFloat(projected.x), @intFromFloat(projected.y), @intFromFloat(projected.depth) };
    }
    const extent = if (part_index < 12) [2]u16{ 16, 8 } else art.leaf_extents[(part_index - 12) / 3];
    const geometry = @import("battle_ivy.zig").quad(points, block, part_index, .{ sprite.anchor_x, sprite.anchor_y }, extent) orelse return null;
    var result = AuxiliaryQuad{ .vertices = undefined, .sprite = sprite, .depth = @floatFromInt(geometry.depth), .translucent = false };
    for (geometry.vertices, &result.vertices) |point, *vertex| vertex.* = .{ .x = @as(f32, @floatFromInt(point[0])) * 2, .y = @as(f32, @floatFromInt(point[1])) * 2, .depth = result.depth };
    return result;
}
fn uniteTrick(state: battle.State, index: usize) ?AuxiliaryQuad {
    const playback = state.trick_wave orelse return null;
    if (index >= 8 or playback.wave.enabled & (@as(u8, 1) << @as(u3, @intCast(index))) == 0 or (playback.wave.finished and playback.updated_at != state.camera_ticks)) return null;
    const bundle = state.unite_actors orelse return null;
    const binding = bundle.find(14).?;
    const resource = bundle.animations.find(binding.members[1].id).?;
    const clip = resource.find(19).?;
    var total: u32 = 0;
    for (clip.frames) |frame| total += frame.updates;
    var elapsed: u32 = playback.wave.animation_updates[index] % total;
    const pose = for (clip.frames) |frame| {
        if (elapsed < frame.updates) break frame.pose;
        elapsed -= frame.updates;
    } else return null;
    const sprite = (state.content.uniteGraphicPose(resource.id, pose, 14) orelse return null).sprite;
    var world = playback.wave.translation;
    for (0..3) |axis| world[axis] += playback.wave.local_q12[index][axis] >> 12;
    const block = currentCamera(state);
    const projected = camera.projectScene(block, world, .{}) orelse return null;
    const point = presentation.ScreenPoint{ .x = projected.x * 2, .y = projected.y * 2, .depth = projected.depth };
    var quad = ordinaryRotatedNodeQuad(block, point, sprite, .{ 0, 0, 0 });
    quad.translucent = clip.semitransparent;
    return quad;
}

fn uniteFan(state: battle.State, index: usize) ?AuxiliaryQuad {
    const slot = index / 5;
    if (slot >= state.unite_vm.members.len) return null;
    const member = state.unite_vm.members[slot] orelse return null;
    const fan = member.fan orelse return null;
    if (!fan.visible) return null;
    const bundle = state.unite_actors orelse return null;
    const resource = bundle.animations.resources[member.resource];
    const spec = for (bundle.find(member.record).?.members) |candidate| {
        if (std.mem.eql(u8, candidate.id, resource.id)) break candidate.fan orelse return null;
    } else return null;
    const sprite = (state.content.uniteGraphicPose(resource.id, resource.find(spec.animation).?.frames[0].pose, member.record) orelse return null).sprite;
    const world = uniteFanPosition(fan.local_x_q12, fan.anchor, spec.rolls[index % 5]);
    const block = currentCamera(state);
    const point = camera.projectScene(block, world, .{}).?;
    const anchor = presentation.ScreenPoint{ .x = point.x * 2, .y = point.y * 2, .depth = point.depth };
    return ordinaryRotatedNodeQuad(block, anchor, sprite, spec.node_angles);
}
pub fn uniteFanPosition(local_x_q12: i32, anchor: [3]i32, roll: i16) [3]i32 {
    const rotation = camera.scaledRot(.{ .focus = .{ 0, 0, 0 }, .angles = .{ 0, 0, roll }, .translation = .{ 0, 0, 0 }, .scale = @splat(4096) });
    var world = anchor;
    for (0..3) |axis| {
        const value = @as(i64, anchor[axis]) + ((@as(i64, rotation[axis * 3]) * (local_x_q12 >> 12)) >> 12);
        world[axis] = @as(i16, @bitCast(@as(u16, @truncate(@as(u64, @bitCast(value))))));
    }
    return world;
}
pub fn ordinaryRotatedNodeQuad(block: camera.Block, anchor: presentation.ScreenPoint, sprite: battle.Pose, angles: [3]i16) AuxiliaryQuad {
    const qscale = @divTrunc(block.scale[0] << 10, block.translation[2]);
    const local = camera.Block{ .focus = .{ 0, 0, 0 }, .angles = .{ angles[0], angles[1], angles[2] }, .translation = .{ 0, 0, 1024 }, .scale = @splat(qscale) };
    var quad = AuxiliaryQuad{ .vertices = undefined, .sprite = sprite, .translucent = false, .depth = @floatFromInt(std.math.clamp(@as(i32, @intFromFloat(anchor.depth)) >> 2, 5, 379) * 4) };
    for (&quad.vertices, 0..) |*vertex, corner| {
        const x = -@as(i32, sprite.anchor_x) + (if (corner & 1 != 0) sprite.rect.w else @as(i32, 0));
        const y = -@as(i32, sprite.anchor_y) + (if (corner >= 2) sprite.rect.h else @as(i32, 0));
        const point = camera.rawProject(local, .{ x, y, 0 });
        vertex.* = .{ .x = anchor.x + @as(f32, @floatFromInt(point[0])) * 2, .y = anchor.y + @as(f32, @floatFromInt(point[1])) * 2, .depth = anchor.depth };
    }
    return quad;
}
