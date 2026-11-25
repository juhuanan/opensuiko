const std = @import("std");
const battle = @import("battle");
const field = @import("field");
const host = battle.actor_host;

const Fixtures = struct {
    content: battle.Content,
    actors: host.Bundle,
    scenes: battle.spell_scene.Packet,
    items: field.items.Rules,

    fn init(alloc: std.mem.Allocator) !Fixtures {
        var base = try std.json.parseFromSlice(std.json.Value, alloc, @embedFile("fixtures/spell_scene_library.json"), .{});
        const patch = try std.json.parseFromSlice(std.json.Value, alloc, @embedFile("fixtures/journey_unite_scenes_patch.json"), .{});
        var it = patch.value.object.iterator();
        while (it.next()) |entry| try base.value.object.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
        return .{
            .content = (try battle.load(alloc, @embedFile("fixtures/journey_unites_battle.json"))).value,
            .actors = (try host.loadBundle(alloc, @embedFile("fixtures/journey_unites_actor_library.json"))).value,
            .scenes = (try battle.spell_scene.load(alloc, try std.json.Stringify.valueAlloc(alloc, base.value, .{}))).value,
            .items = (try field.items.load(alloc, field.items.json)).value,
        };
    }

    fn findEncounter(self: Fixtures, id: []const u8) !usize {
        for (self.content.encounters, 0..) |entry, idx| if (std.mem.eql(u8, entry.id, id)) return idx;
        return error.MissingSourceEncounter;
    }

    fn findEnemy(self: Fixtures, id: []const u8) !battle.Profile {
        for (self.content.enemies) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return error.MissingEnemyProfile;
    }

    fn setupState(self: *const Fixtures, alloc: std.mem.Allocator, encounter_id: []const u8) !struct { state: *battle.State, members: *[6]battle.Member } {
        const members = try alloc.create([6]battle.Member);
        const state = try alloc.create(battle.State);
        state.* = try battle.State.init(self.content, self.items, members, 1234);
        state.encounter = try self.findEncounter(encounter_id);
        state.startEncounter();
        try state.attachUniteActors(&self.actors);
        try state.attachSpellScenes(&self.scenes);
        return .{ .state = state, .members = members };
    }
};

fn prepareDefendingParty(state: *battle.State, members: *[6]battle.Member, hp: u16) void {
    for (members, 0..) |*member, idx| {
        member.max_hp = hp;
        member.hp = hp;
        member.status = .healthy;
        member.balloons = 0;
        member.inventory.slots = @splat(null);
        state.actions[idx] = .defend;
    }
    state.acted = @splat(true);
    for (state.partyCount()..state.partyCount() + state.enemyCount()) |actor| state.acted[actor] = false;
    state.phase = .resolving;
    state.round_start_pending = false;
    state.coordinator = .{ .stage = .select, .current_actor = state.partyCount() };
}

fn collectSound(seen: *std.AutoHashMap(u16, void), state: *const battle.State) !void {
    for (state.unite_vm.sounds[0..state.unite_vm.sound_count]) |sound| try seen.put(sound.id, {});
}

test "regional enemy source admission verifies stats flags drops all 15 formations and schema boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const f = try Fixtures.init(alloc);

    try std.testing.expectEqual(@as(usize, 53), f.content.party.len);
    try std.testing.expectEqual(@as(usize, 32), f.content.enemies.len);
    try std.testing.expectEqual(@as(usize, 96), f.content.encounters.len);

    const creeper = try f.findEnemy("creeper");
    try std.testing.expectEqual(@as(u8, 29), creeper.level);
    try std.testing.expectEqual(@as(u16, 300), creeper.max_hp);
    try std.testing.expectEqualDeep(battle.Stats{ .attack = 210, .skill = 90, .defense = 25, .speed = 73, .magic = 40, .luck = 25 }, creeper.stats);
    try std.testing.expect(creeper.action_policy == .source_creeper and creeper.target_policy == .front_first);
    try std.testing.expect(creeper.dodges_attacks and !creeper.unavoidable_attack);
    try std.testing.expectEqual(field.items.Id.earth_crystal, creeper.drops.?[0].item.?);
    try std.testing.expectEqual(@as(u8, 5), creeper.drops.?[0].rate);

    const shadow = try f.findEnemy("shadow_man");
    try std.testing.expectEqual(@as(u8, 50), shadow.level);
    try std.testing.expectEqual(@as(u16, 400), shadow.max_hp);
    try std.testing.expectEqualDeep(battle.Stats{ .attack = 310, .skill = 150, .defense = 60, .speed = 130, .magic = 60, .luck = 90 }, shadow.stats);
    try std.testing.expect(shadow.action_policy == .source_shadow_man and shadow.target_policy == .front_first);
    try std.testing.expect(shadow.dodges_attacks and shadow.unavoidable_attack);
    try std.testing.expectEqual(field.items.Id.silverlet, shadow.drops.?[0].item.?);
    try std.testing.expectEqual(field.items.Id.rose_brooch, shadow.drops.?[1].item.?);
    var legacy_shadow = f.actors.regionalFor("shadow_man").?.*;
    legacy_shadow.shadow_column = null;
    const legacy_bytes = try std.json.Stringify.valueAlloc(alloc, legacy_shadow, .{});
    try std.testing.expect(std.mem.indexOf(u8, legacy_bytes, "shadow_column") == null);

    for ([_][]const u8{ "mirage_f", "mirage_h" }) |id| {
        const mirage = try f.findEnemy(id);
        try std.testing.expectEqual(@as(u8, 52), mirage.level);
        try std.testing.expectEqual(@as(u16, 400), mirage.max_hp);
        try std.testing.expectEqualDeep(battle.Stats{ .attack = 330, .skill = 130, .defense = 95, .speed = 120, .magic = 175, .luck = 70 }, mirage.stats);
        try std.testing.expect(mirage.target_policy == .any_row and mirage.dodges_attacks and !mirage.unavoidable_attack);
        try std.testing.expectEqual(field.items.Id.speed_ring, mirage.drops.?[0].item.?);
        try std.testing.expectEqual(@as(u8, 6), mirage.drops.?[0].rate);
    }

    const expected_encounters = [_][]const u8{
        "area_d_7", "area_d_8", "area_d_9", "area_d_10", "area_d_12",
        "area_f_4", "area_f_5", "area_f_6", "area_f_7",  "area_f_8",
        "area_h_4", "area_h_5", "area_h_6", "area_h_10", "area_h_12",
    };
    for (expected_encounters) |enc_id| _ = try f.findEncounter(enc_id);

    // Every battle party member must carry clip 3 + pose art and all 78 party_reactions carry return_program.
    const packet = f.actors.counterPacket().?;
    try std.testing.expectEqual(@as(usize, 78), packet.melee.?.party_reactions.len);
    for (packet.melee.?.party_reactions) |reaction| {
        try std.testing.expect(reaction.return_program != null);
        const res = f.actors.animations.find(reaction.id).?;
        try std.testing.expect(res.find(3) != null);
    }
    try std.testing.expectEqualStrings("party_reaction/clive/return", packet.partyReaction("clive").?.return_program.?);
    for (f.content.party) |member| {
        const clip3 = f.actors.animations.find(member.id).?.find(3).?;
        for (clip3.frames) |frame| try std.testing.expect(f.content.uniteGraphicPose(member.id, frame.pose, null) != null);
    }

    // Schema refusals
    var old_content = f.content;
    old_content.schema = "suikoden-battle-trial/42";
    try std.testing.expectError(error.UnsupportedEnemyPresentation, old_content.validate());

    var old_actors = f.actors;
    old_actors.schema = "suikoden-unite-actors/39";
    try std.testing.expectError(error.InvalidUniteBindings, old_actors.validate());
    old_actors.enemy_regional = null;
    try std.testing.expectError(error.InvalidCounterBindings, old_actors.validate());

    var missing_reg = f.actors;
    missing_reg.enemy_regional = null;
    try std.testing.expectError(error.InvalidUniteBindings, missing_reg.validate());

    // Actor program schema/12 must reject hold_coordinator_dispatch and tail_return
    var bad_prog = f.actors.programs;
    bad_prog.schema = "suikoden-actor-programs/12";
    try std.testing.expectError(error.InvalidActorPrograms, bad_prog.validate());
}

test "D3 Creeper ordinary counter vs Suikomi delay cross_side_pending shrink_spin 3-hit and spit_expand KO" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const f = try Fixtures.init(alloc);

    // 1. Ordinary branch (< 51) can miss and be countered cleanly without delay or shrink.
    {
        const s = try f.setupState(alloc, "area_d_7");
        prepareDefendingParty(s.state, s.members, 4000);
        // slot 0 misses -> countered if hero has counter? Use hero default; test direct ordinary hit & miss.
        var values: [256]u15 = @splat(51);
        values[2] = 0; // < 51 -> ordinary melee (roll 0=priority, roll 1=target 0, roll 2=branch)
        values[3] = 0; // hit
        var draws = battle.systems.Draws{ .values = &values };
        for (0..800) |_| {
            try s.state.tickReplay(.{}, &draws);
            if (s.state.phase != .resolving) break;
        }
        try std.testing.expectEqual(battle.Phase.battle_menu, s.state.phase);
        if (s.members[0].hp == 4000) std.debug.print("D3_ord cursor={d} hp={d},{d},{d} enemy={d}\n", .{ draws.cursor, s.members[0].hp, s.members[1].hp, s.members[2].hp, s.state.enemy_hp[0] });
        try std.testing.expect(s.members[0].hp < 4000);
        try std.testing.expectEqual(@as(i32, 4096), s.state.actor_sizes[0]);
    }

    // 2. Suikomi special (>= 51) holds second Creeper in area_d_8 via cross_side_pending, shrinks, deals 3 hits, expands and commits lethal KO.
    {
        const s = try f.setupState(alloc, "area_d_8");
        prepareDefendingParty(s.state, s.members, 2000);
        s.members[0].hp = 1; // lethal on hit 1 while hits 2 and 3 still roll RNG
        var values: [1024]u15 = @splat(20051);
        values[1] = 20051; // >= 51 -> Suikomi (20051 * 100 / 32767 = 61 >= 51)
        var draws = battle.systems.Draws{ .values = &values };
        var saw_delay = false;
        var saw_cross_hold = false;
        var saw_shrink = false;
        var saw_spin = false;
        var saw_expand = false;
        var min_size: i32 = 4096;
        var sounds = std.AutoHashMap(u16, void).init(alloc);
        var held_actor_down_early = false;
        for (0..2000) |_| {
            s.state.tickReplay(.{}, &draws) catch |err| {
                std.debug.print("D3_spec err={s}\n", .{@errorName(err)});
                return err;
            };
            try collectSound(&sounds, s.state);
            if (s.state.coordinator) |clock| {
                if (clock.remaining == 20 and s.state.enemyCount() > 1 and !s.state.acted[s.state.partyCount() + 1]) saw_delay = true;
                if (clock.cross_side_pending and !s.state.acted[s.state.partyCount() + 1]) saw_cross_hold = true;
            }
            const sz = s.state.actor_sizes[0];
            if (sz < 4096 and !saw_expand) {
                saw_shrink = true;
                min_size = @min(min_size, sz);
                if (s.state.actor_node_angles[0][1] == 1 and s.state.actor_node_angles[0][0] != 0) saw_spin = true;
            }
            if (saw_shrink and sz > min_size) saw_expand = true;
            if (s.state.hp(0) == 0 and s.state.actor_sizes[0] < 4096 and !s.state.knockout_pending[0]) held_actor_down_early = true;
            if (s.state.phase != .resolving) break;
        }
        try std.testing.expectEqual(battle.Phase.battle_menu, s.state.phase);
        try std.testing.expect(!held_actor_down_early);
        try std.testing.expect(saw_delay and saw_cross_hold and saw_shrink and saw_spin and saw_expand);
        try std.testing.expect(min_size < 256);
        try std.testing.expectEqual(@as(i32, 4096), s.state.actor_sizes[0]);
        try std.testing.expectEqualDeep([3]i16{ 0, 0, 0 }, s.state.actor_node_angles[0]);
        try std.testing.expect(!s.state.participates(0));
        for ([_]u16{ 1288, 1399, 1400, 2079 }) |sid| try std.testing.expect(sounds.contains(sid));
    }

    // 3. Suikomi protection=1 negates HP damage while consuming 3 RNG rolls and completes cleanly.
    {
        const s = try f.setupState(alloc, "area_d_7");
        prepareDefendingParty(s.state, s.members, 2000);
        s.state.protection[0] = 1;
        var values: [512]u15 = @splat(20051);
        values[1] = 20051;
        var draws = battle.systems.Draws{ .values = &values };
        for (0..1500) |_| {
            try s.state.tickReplay(.{}, &draws);
            if (s.state.phase != .resolving) break;
        }
        try std.testing.expectEqual(battle.Phase.battle_menu, s.state.phase);
        try std.testing.expectEqual(@as(u16, 2000), s.members[0].hp);
        try std.testing.expect(draws.cursor >= 5); // 1 target draw + 1 branch + 3 hit variance draws
    }

    // 4. A failed later contact preserves the first hit and can resume on the same tick.
    {
        const s = try f.setupState(alloc, "area_d_7");
        prepareDefendingParty(s.state, s.members, 2000);
        const values: [512]u15 = @splat(20051);
        // One priority draw, one target draw, one branch draw and one contact.
        var draws = battle.systems.Draws{ .values = values[0..4] };
        while (draws.cursor < draws.values.len) {
            try s.state.tickReplay(.{}, &draws);
            try std.testing.expectEqual(battle.Phase.resolving, s.state.phase);
            if (s.state.camera_ticks >= 1500) return error.MissingFirstContact;
        }
        const first_hit_hp = s.members[0].hp;
        try std.testing.expect(first_hit_hp < 2000 and first_hit_hp > 0);
        var resumed = false;
        for (0..1500) |_| {
            const before = s.state.*;
            const before_members = s.members.*;
            if (s.state.tickReplay(.{}, &draws)) |_| {} else |err| {
                try std.testing.expectEqual(error.RandomInputExhausted, err);
                try std.testing.expectEqualDeep(before, s.state.*);
                try std.testing.expectEqualDeep(before_members, s.members.*);
                try std.testing.expectEqual(@as(usize, 4), draws.cursor);
                draws.values = &values;
                try s.state.tickReplay(.{}, &draws);
                try std.testing.expectEqual(@as(usize, 5), draws.cursor);
                resumed = true;
                break;
            }
            try std.testing.expectEqual(first_hit_hp, s.members[0].hp);
        }
        try std.testing.expect(resumed);
        for (0..1500) |_| {
            if (s.state.phase != .resolving) break;
            try s.state.tickReplay(.{}, &draws);
        }
        try std.testing.expectEqual(battle.Phase.battle_menu, s.state.phase);
        try std.testing.expectEqual(@as(usize, 6), draws.cursor);
        try std.testing.expectEqual(2000 - 3 * (2000 - first_hit_hp), s.members[0].hp);
    }
}

test "F2 Shadow Man front scan camera shake 80-tick fade tail_return on Hero and Clive and lethal KO hold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const f = try Fixtures.init(alloc);

    // 1. Direct attack against Hero: cross_side_pending, camera shake +-0x5000, fade=80 ticks, tail_return -> KO commit after return.
    {
        const s = try f.setupState(alloc, "area_f_4");
        prepareDefendingParty(s.state, s.members, 2000);
        s.state.actions[0] = .defend;
        s.state.protection[0] = 1; // shadow_man is unavoidable_attack & direct (no cover/parry), protection negates HP if buffered
        s.state.protection[0] = 0;
        s.members[0].hp = 1;
        var values: [512]u15 = @splat(51);
        var draws = battle.systems.Draws{ .values = &values };
        var saw_cross = false;
        var saw_shake = false;
        var fade_ticks: usize = 0;
        var visible_ticks: usize = 0;
        var saw_tail_return = false;
        var early_ko = false;
        var sounds = std.AutoHashMap(u16, void).init(alloc);
        for (0..2000) |_| {
            s.state.tickReplay(.{}, &draws) catch |err| {
                std.debug.print("F2 err={s}\n", .{@errorName(err)});
                return err;
            };
            try collectSound(&sounds, s.state);
            if (s.state.coordinator) |clock| if (clock.cross_side_pending) {
                saw_cross = true;
            };
            if (s.state.actor_camera) |cam| if (cam.current[0][2] != 0) {
                saw_shake = true;
            };
            const enemy = &s.state.unite_vm.actors[s.state.partyCount()];
            if (enemy.shadow_fade) |fade| {
                fade_ticks += 1;
                if (enemy.shared_value == 1 or enemy.shared_value == 99) {
                    const frame = s.state.spellSceneFrame();
                    if (fade.updates == 0 or fade.updates >= 64) {
                        try std.testing.expectEqual(@as(usize, 0), frame.count);
                    } else {
                        visible_ticks += 1;
                        try std.testing.expect(s.state.hasSourceEffect());
                        try std.testing.expectEqual(@as(usize, 32), frame.count);
                        const first = frame.commands[0];
                        try std.testing.expect(first.texture == null and first.blend == .additive);
                        try std.testing.expectEqualDeep([4][3]u8{ @splat(128), @splat(128), @splat(0), @splat(0) }, first.colors);
                        const radial: i32 = 1 + @as(i32, fade.updates) * 64;
                        const above = battle.drops.project(battle.layout.currentCamera(s.state.*), .{
                            fade.origin[0] + (120 * radial >> 12), fade.origin[1], fade.origin[2],
                        });
                        try std.testing.expectEqual(battle.spell_scene.Point{ .x = above.x, .y = above.y }, first.vertices[0]);
                        try std.testing.expectEqual(first.vertices[0], frame.commands[31].vertices[1]);
                    }
                }
            }
            if (s.state.unite_vm.scripted_actors[0] != null) if (s.state.unite_vm.actors[0].machine) |m| {
                if (m.instructions.ptr == f.actors.programs.find("party_melee/hero/return").?.instructions.ptr) {
                    saw_tail_return = true;
                    if (!s.state.knockout_pending[0]) early_ko = true;
                }
            };
            if (s.state.phase != .resolving) break;
        }
        try std.testing.expectEqual(battle.Phase.battle_menu, s.state.phase);
        try std.testing.expect(saw_cross and saw_shake and saw_tail_return and !early_ko);
        try std.testing.expect(fade_ticks >= 80);
        try std.testing.expectEqual(@as(usize, 63), visible_ticks);
        try std.testing.expect(!s.state.participates(0));
        try std.testing.expect(sounds.contains(1296) and sounds.contains(1414));
    }

    // 2. Direct execution of party_reaction/clive/return via tail_return on Shadow Man hurt script
    {
        const packet = f.actors.counterPacket().?;
        var actors_buf: [2]host.Actor = .{
            try host.Actor.init(f.actors.animations.find("clive").?, .{ 100 * 4096, 0, 0 }),
            try host.Actor.init(f.actors.animations.find("shadow_man").?, .{ -100 * 4096, 0, 0 }),
        };
        actors_buf[1].regional = f.actors.regionalFor("shadow_man");
        const TailCtx = struct {
            packet_ptr: *const battle.counter.Packet,
            runtime_ptr: *host.Runtime = undefined,
            dispatched: bool = false,
            fn cmd(_: *anyopaque, _: u16, req: battle.actor_program.Command, _: bool) !bool {
                return req == .sound or req == .effect;
            }
            fn tail(raw: *anyopaque, actor: u16) !void {
                const self: *@This() = @ptrCast(@alignCast(raw));
                const ret = self.packet_ptr.partyReaction("clive").?.return_program.?;
                self.dispatched = std.mem.eql(u8, ret, "party_reaction/clive/return");
                try self.runtime_ptr.dispatch(actor, 1, self.packet_ptr.programs.find(ret).?);
            }
        };
        var tail_ctx = TailCtx{ .packet_ptr = &packet };
        var cam = try @typeInfo(@FieldType(battle.State, "actor_camera")).optional.child.init(.{ .position = .{ 0, 0, 0 }, .angles = .{ 0, 0, 0 }, .c = .{ 0, 0, 1024 }, .d = .{ 4096, 4096, 4096 } });
        var children: [4]?host.Actor = @splat(null);
        var rt = host.Runtime{
            .actors = &actors_buf,
            .auxiliary = &children,
            .library = f.actors.library(),
            .camera_controller = &cam,
            .external = .{ .context = &tail_ctx, .command = TailCtx.cmd, .tail_return = TailCtx.tail },
        };
        tail_ctx.runtime_ptr = &rt;
        try rt.dispatch(0, 1, packet.programs.find("melee/shadow_man/hurt").?);
        for (0..400) |_| {
            rt.beginUpdate();
            try rt.stepActor(0);
            for (children, actors_buf.len..) |child, id| {
                if (child != null) try rt.stepActor(@intCast(id));
            }
            if (rt.actors[0].machine == null or rt.actors[0].machine.?.halted) {
                if (tail_ctx.dispatched) break;
            }
        }
        try std.testing.expect(tail_ctx.dispatched);
        try std.testing.expect(rt.actors[0].machine.?.halted);
        try std.testing.expectEqual(@as(u8, 0), rt.actors[0].highlights);
    }
}

test "F3 Mirage vs H2 Mirage separate qualification any_row front ordinary rear special and 1-tick wait_100 diff" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const f = try Fixtures.init(alloc);

    // 1. Rear-row special comparison between F3 Mirage (area_f_6) and H2 Mirage (area_h_4)
    var ticks_f: usize = 0;
    var ticks_h: usize = 0;
    var sounds_f = std.AutoHashMap(u16, void).init(alloc);
    var sounds_h = std.AutoHashMap(u16, void).init(alloc);
    for ([2][]const u8{ "area_f_6", "area_h_4" }, 0..) |enc_id, idx| {
        const s = try f.setupState(alloc, enc_id);
        prepareDefendingParty(s.state, s.members, 2000);
        // Disable front row by making slot 3 active in back row; force roll >= 51 on slot 3 only by keeping slot 3 only alive.
        for (0..3) |front_slot| {
            s.members[front_slot].hp = 0;
            s.members[front_slot].status = .unconscious;
        }
        var values: [512]u15 = @splat(20051);
        var draws = battle.systems.Draws{ .values = &values };
        var observed: [5]usize = @splat(0);
        var awaiting_cleanup = false;
        for (0..2000) |_| {
            try s.state.tickReplay(.{}, &draws);
            try collectSound(if (idx == 0) &sounds_f else &sounds_h, s.state);
            if (idx == 0) ticks_f += 1 else ticks_h += 1;
            const enemy = &s.state.unite_vm.actors[s.state.partyCount()];
            if (enemy.mirage_worker) |worker| {
                const boundary: ?u3 = switch (enemy.shared_value) {
                    1 => if (worker.timer == 1) 0 else null,
                    2 => if (worker.timer == 30) 1 else if (worker.timer == 29) 2 else null,
                    99 => 3,
                    100 => 4,
                    else => null,
                };
                if (boundary) |stage| {
                    const first_index = battle.layout.mirage_copy_offset;
                    if (stage == 4) {
                        try std.testing.expect(battle.layout.uniteAuxiliary(s.state.*, first_index) == null);
                        if (awaiting_cleanup) observed[stage] += 1;
                        awaiting_cleanup = false;
                    } else {
                        observed[stage] += 1;
                        if (stage == 3) awaiting_cleanup = true;
                        const tint = [4]u8{ 123, 0, 4, 128 };
                        for (0..7) |copy| {
                            const quad = battle.layout.uniteAuxiliary(s.state.*, first_index + copy).?;
                            try std.testing.expect(quad.translucent and quad.blend == .subtractive);
                            try std.testing.expectEqual(@as([3]u8, @splat(tint[stage])), quad.color);
                            try std.testing.expectEqual(@as(i32, 39), quad.sprite.rect.w);
                            try std.testing.expectEqual(@as(i32, 63), quad.sprite.rect.h);
                        }
                        try std.testing.expect(!s.state.spellReaction(s.state.partyCount()).?.visible);

                        const center = battle.layout.uniteAuxiliary(s.state.*, first_index + 3).?;
                        const first = battle.layout.uniteAuxiliary(s.state.*, first_index).?;
                        const last = battle.layout.uniteAuxiliary(s.state.*, first_index + 6).?;
                        const mid = battle.layout.worldPoint(s.state.*, .{
                            .x = @floatFromInt((worker.origin_q12[0] +% if (stage >= 2) worker.delta_q12[0] else 0) >> 12),
                            .y = @floatFromInt((worker.origin_q12[1] +% if (stage >= 2) worker.delta_q12[1] else 0) >> 12),
                            .z = @floatFromInt((worker.origin_q12[2] +% if (stage >= 2) worker.delta_q12[2] else 0) >> 12),
                        });
                        try std.testing.expectEqual(mid.depth, center.vertices[0].depth);
                        const camera = battle.layout.currentCamera(s.state.*);
                        const scale_x = @divTrunc(camera.d[0] << 10, camera.c[2]);
                        const scale_y = @divTrunc(camera.d[1] << 10, camera.c[2]);
                        try std.testing.expectEqual(mid.x + @as(f32, @floatFromInt(2 * @divTrunc(-28 * scale_x, 4096))), center.vertices[0].x);
                        try std.testing.expectEqual(mid.y + @as(f32, @floatFromInt(2 * @divTrunc(-54 * scale_y, 4096))), center.vertices[0].y);
                        if (stage == 3) {
                            try std.testing.expectEqualDeep(first.vertices, last.vertices);
                        } else if (stage == 2) {
                            try std.testing.expect(first.vertices[0].x != last.vertices[0].x or first.vertices[0].y != last.vertices[0].y);
                        }
                    }
                }
            }
            if (s.state.phase != .resolving) break;
        }
        try std.testing.expectEqual([5]usize{ 2, 2, 2, 2, 2 }, observed);
        try std.testing.expectEqual(battle.Phase.battle_menu, s.state.phase);
        try std.testing.expect(s.members[3].hp < 2000);
        try std.testing.expect(battle.layout.uniteAuxiliary(s.state.*, battle.layout.mirage_copy_offset) == null);
    }
    try std.testing.expect(sounds_f.contains(1443) and !sounds_f.contains(1426));
    try std.testing.expect(sounds_h.contains(1426) and !sounds_h.contains(1443));
    try std.testing.expect(ticks_f > ticks_h);

    // Direct 1v1 program comparison proving exact 1-tick wait_100 difference between mirage_f and mirage_h
    {
        var single_ticks: [2]usize = .{ 0, 0 };
        for ([2][2][]const u8{ .{ "mirage_f", "melee/mirage_f/special" }, .{ "mirage_h", "melee/mirage_h/special" } }, 0..) |pair, idx| {
            var actors_buf: [2]host.Actor = .{
                try host.Actor.init(f.actors.animations.find("hero").?, .{ 100 * 4096, 0, 0 }),
                try host.Actor.init(f.actors.animations.find(pair[0]).?, .{ -100 * 4096, 0, 0 }),
            };
            actors_buf[1].regional = f.actors.regionalFor(pair[0]);
            const Ctx = struct {
                fn cmd(_: *anyopaque, _: u16, req: battle.actor_program.Command, _: bool) !bool {
                    return req == .sound or req == .effect;
                }
            };
            var empty_ctx: u8 = 0;
            var rt = host.Runtime{
                .actors = &actors_buf,
                .library = f.actors.library(),
                .external = .{ .context = &empty_ctx, .command = Ctx.cmd },
            };
            try rt.dispatch(1, 0, f.actors.programs.find(pair[1]).?);
            for (0..400) |_| {
                rt.beginUpdate();
                try rt.stepActor(1);
                single_ticks[idx] += 1;
                if (rt.actors[1].machine != null and rt.actors[1].machine.?.halted) break;
            }
        }
        try std.testing.expectEqual(single_ticks[1] + 1, single_ticks[0]);
    }

    // 2. Front-row ordinary branch can miss and target dodges cleanly
    {
        const s = try f.setupState(alloc, "area_h_4");
        prepareDefendingParty(s.state, s.members, 2000);
        s.state.accuracy_reduced[0] = false;
        const values: [512]u15 = @splat(99); // Pass target selection, then miss the accuracy check.
        var draws = battle.systems.Draws{ .values = &values };
        var saw_miss = false;
        var saw_left_vanish = false;
        for (0..2000) |_| {
            try s.state.tickReplay(.{}, &draws);
            if (s.state.unite_vm.actors[s.state.partyCount()].mirage_worker) |worker| {
                if (worker.kind == .vanish_left and worker.timer == 1 and s.state.unite_vm.actors[s.state.partyCount()].shared_value == 1) {
                    saw_left_vanish = battle.layout.uniteAuxiliary(s.state.*, battle.layout.mirage_copy_offset) != null;
                }
            }
            for (s.state.unite_vm.counter_actions) |maybe| {
                const playback = maybe orelse continue;
                if (playback.kind == .ordinary_miss and playback.attacker == s.state.partyCount() and playback.defender == 0) saw_miss = true;
            }
            if (s.state.phase != .resolving) break;
        }
        try std.testing.expectEqual(battle.Phase.battle_menu, s.state.phase);
        try std.testing.expect(saw_miss);
        try std.testing.expect(saw_left_vanish);
        for (s.members) |member| try std.testing.expectEqual(@as(u16, 2000), member.hp);
    }

    // 3. Full round completion across mixed regional encounters area_d_12, area_f_8, area_h_12
    for ([_][]const u8{ "area_d_12", "area_f_8", "area_h_12" }) |mixed| {
        const s = try f.setupState(alloc, mixed);
        prepareDefendingParty(s.state, s.members, 5000);
        var values: [4096]u15 = @splat(20051);
        var draws = battle.systems.Draws{ .values = &values };
        for (0..6000) |_| {
            try s.state.tickReplay(.{}, &draws);
            if (s.state.phase != .resolving) break;
        }
        try std.testing.expectEqual(battle.Phase.battle_menu, s.state.phase);
        try std.testing.expectEqual(@as(u32, 2), s.state.round);
    }
}

test "regional playback consumes changed target and actor settings from its bundle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var f = try Fixtures.init(alloc);
    const bindings = try alloc.dupe(host.RegionalBinding, f.actors.enemy_regional.?);
    f.actors.enemy_regional = bindings;
    for (bindings) |*binding| {
        if (binding.special_hits != 0) {
            binding.front_roll_threshold = 52;
            binding.shrink_step_q12 = 1024;
            binding.shrink_min_q12 = 1536;
            binding.shrink_spin_angle = 127;
            binding.expand_step_q12 = 512;
            binding.expand_target_q12 = 3584;
        } else if (binding.direct_attack) {
            binding.fade_updates = 0;
            try std.testing.expectError(error.InvalidUniteBindings, f.actors.validate());
            binding.fade_updates = 3;
            binding.camera_shake_z_q12 = 8192;
            binding.shadow_column.?.segments = 33;
            try std.testing.expectError(error.InvalidUniteBindings, f.actors.validate());
            binding.shadow_column.?.segments = 12;
        } else if (binding.rear_triggers_special) {
            binding.vanish_phase_updates = 2;
            binding.vanish_offset_q12 = 7 * 4096;
        }
    }

    const creeper = try f.setupState(alloc, "area_d_7");
    prepareDefendingParty(creeper.state, creeper.members, 2000);
    var scan_draws = battle.systems.Draws{ .values = &.{ 51, 52 } };
    creeper.state.replay_draws = &scan_draws;
    var eligible = false;
    try std.testing.expectEqual(@as(?usize, 1), try creeper.state.scanSourceEnemyTarget(creeper.state.partyCount(), &eligible));
    try std.testing.expect(eligible);
    try std.testing.expectEqual(@as(usize, 2), scan_draws.cursor);
    creeper.state.replay_draws = null;
    const values: [512]u15 = @splat(20052);
    var draws = battle.systems.Draws{ .values = &values };
    var saw_shrink = false;
    var saw_expansion = false;
    var saw_expansion_target = false;
    for (0..1000) |_| {
        try creeper.state.tickReplay(.{}, &draws);
        const recipient = creeper.state.unite_vm.actors[0];
        if (!saw_shrink and recipient.suikomi_phase == .shrink_spin) {
            try std.testing.expectEqual(@as(i32, 3072), recipient.draw_size_q12);
            try std.testing.expectEqual(@as(i16, 127), recipient.draw_angles[0]);
            saw_shrink = true;
        }
        if (recipient.suikomi_phase == .spit_expand and recipient.draw_size_q12 == 1536) saw_expansion = true;
        if (recipient.draw_size_q12 == 3584) saw_expansion_target = true;
        if (creeper.state.phase == .battle_menu) break;
    }
    try std.testing.expect(saw_shrink and saw_expansion and saw_expansion_target);
    try std.testing.expectEqual(battle.Phase.battle_menu, creeper.state.phase);
    try std.testing.expectEqual(@as(i32, 4096), creeper.state.actor_sizes[0]);

    const shadow = try f.setupState(alloc, "area_f_4");
    prepareDefendingParty(shadow.state, shadow.members, 2000);
    draws = .{ .values = &values };
    var saw_shake = false;
    var saw_fade = false;
    for (0..1000) |_| {
        try shadow.state.tickReplay(.{}, &draws);
        if (shadow.state.actor_camera) |camera| {
            if (camera.remaining[0] == 1 and camera.velocity[0][2] == 8192) saw_shake = true;
        }
        const enemy = shadow.state.unite_vm.actors[shadow.state.partyCount()];
        if (enemy.shadow_fade != null and enemy.shared_value == 99) {
            try std.testing.expectEqual(@as(u16, 3), enemy.shadow_fade.?.updates);
            try std.testing.expectEqual(@as(usize, 12), shadow.state.spellSceneFrame().count);
            saw_fade = true;
        }
        if (shadow.state.phase == .battle_menu) break;
    }
    try std.testing.expect(saw_shake and saw_fade);
    try std.testing.expectEqual(battle.Phase.battle_menu, shadow.state.phase);

    const mirage = try f.setupState(alloc, "area_f_6");
    prepareDefendingParty(mirage.state, mirage.members, 2000);
    for (mirage.members[0..3]) |*member| {
        member.hp = 0;
        member.status = .unconscious;
    }
    draws = .{ .values = &values };
    for (0..1000) |_| {
        try mirage.state.tickReplay(.{}, &draws);
        const enemy = mirage.state.unite_vm.actors[mirage.state.partyCount()];
        const worker = enemy.mirage_worker orelse continue;
        if (worker.kind != .vanish_right or enemy.shared_value != 2) continue;
        try std.testing.expectEqual(@as(u16, 2), worker.timer);
        const target_x = mirage.state.unite_vm.actors[enemy.owner.?].position_q12[0];
        try std.testing.expectEqual(target_x + 7 * 4096, enemy.position_q12[0]);
        break;
    } else return error.MissingMirageVanish;
}
