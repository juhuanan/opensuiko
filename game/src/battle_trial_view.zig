const std = @import("std");
const rl = @import("raylib");
const battle = @import("battle");
const commands = @import("game");
const ui = @import("ui");
const presentation = battle.presentation;
const command_x = 326;

pub fn fighterLabel(state: *const battle.State, index: usize, buffer: *[96]u8) []const u8 {
    if (index < state.partyCount()) return state.name(index);
    return std.fmt.bufPrint(buffer, "{s} {d}", .{ state.name(index), state.enemySourceSlot(index - state.partyCount()) + 1 }) catch unreachable;
}

pub fn choosingMember(state: battle.State) ?usize {
    return switch (state.phase) {
        .command, .target, .item, .item_target, .spell, .spell_target, .unite_target, .rune_target => state.actor,
        else => null,
    };
}

pub const selectionTarget = battle.State.selectedTargetActor;

pub fn drawTargetMarker(context: *const ui.Context, x: f32, y: f32) void {
    rl.drawEllipseLines(@intFromFloat(x), @intFromFloat(y), 30, 9, .gold);
    context.text(">", @intFromFloat(x - 42), @intFromFloat(y - 32), 22, .gold);
}

fn drawTargetList(context: *const ui.Context, state: *const battle.State, heading: []const u8) void {
    context.text(heading, command_x, 339, 15, .gold);
    const targets = state.targetSelection().?;
    for (0..targets.count) |slot| {
        const fighter = targets.actorAt(slot).?;
        const y = 361 + @as(i32, @intCast(slot)) * 16;
        const enabled = state.canSelectTarget(slot);
        const selected = enabled and slot == state.selection;
        var buffer: [96]u8 = undefined;
        const color: rl.Color = if (selected) .gold else if (enabled) .ray_white else .gray;
        context.numberText("{s}{s}", .{ if (selected) "> " else "  ", fighterLabel(state, fighter, &buffer) }, command_x, y, 12, color);
        const status = if (fighter < state.partyCount() and state.departed[fighter]) "Departed" else if (state.hp(fighter) == 0) "KO" else if (!enabled) "Unavailable" else "";
        if (status.len != 0) context.text(status, 548, y, 11, .light_gray);
    }
}

fn actionText(state: battle.State, member: usize, action: battle.Action, buffer: *[256]u8) []const u8 {
    var target_buffer: [96]u8 = undefined;
    return switch (action) {
        .attack => |target| std.fmt.bufPrint(buffer, "Attack > {s}", .{fighterLabel(&state, target + state.partyCount(), &target_buffer)}) catch unreachable,
        .rune_attack => |target| std.fmt.bufPrint(buffer, "{s} > {s}", .{ if (state.rune(member)) |rune| rune.name else "Rune", fighterLabel(&state, target + state.partyCount(), &target_buffer) }) catch unreachable,
        .defend => "Defend",
        .item => |item| std.fmt.bufPrint(buffer, "{s} > {s}", .{ item.id.name(), if (state.rules.consumable(item.id).?.partyWide()) "All allies" else state.name(item.target) }) catch unreachable,
        .spell => |cast| blk: {
            const spell = state.content.systems.?.spells[cast.index];
            const target = if (spell.group) (if (spell.allies) "All allies" else "All enemies") else fighterLabel(&state, cast.target + if (spell.allies) @as(usize, 0) else state.partyCount(), &target_buffer);
            break :blk std.fmt.bufPrint(buffer, "{s} > {s}", .{ spell.name, target }) catch unreachable;
        },
        .unite => |target| std.fmt.bufPrint(buffer, "{s} > {s}", .{ state.uniteName(member), fighterLabel(&state, target + state.partyCount(), &target_buffer) }) catch unreachable,
        .assist => |partner| std.fmt.bufPrint(buffer, "Unite with {s}", .{state.name(partner)}) catch unreachable,
    };
}

pub fn queuedActionText(state: battle.State, member: usize, buffer: *[256]u8) []const u8 {
    if (state.departed[member]) return "Departed - no action";
    if (state.unbalanced[member] > 0 and state.actions[member] == null) return "Recovering: Item/Defend";
    if (state.actions[member]) |action| return actionText(state, member, action, buffer);
    if (state.hp(member) == 0) return "KO - no action";
    return if (choosingMember(state) == member) "Choosing..." else "Waiting for command";
}

pub fn draftActionText(state: battle.State, buffer: *[256]u8) []const u8 {
    return switch (state.phase) {
        .command => commands.labels[@backingInt(state.picker.selected)],
        .target => actionText(state, state.actor, .{ .attack = state.selection }, buffer),
        .rune_target => actionText(state, state.actor, .{ .rune_attack = state.selection }, buffer),
        .unite_target => actionText(state, state.actor, .{ .unite = state.selection }, buffer),
        .item => blk: {
            const selected = state.progress.party.at(state.actor).inventory.slots[state.selection].?;
            if (selected.id == .dragon_seal_incense) break :blk "Dragon seal incense - reusable, all allies";
            if (selected.id == .sacrificial_buddha) break :blk "Sacrificial Buddha - automatic revival";
            break :blk std.fmt.bufPrint(buffer, "{s} - {d} uses", .{ selected.name(), selected.uses }) catch unreachable;
        },
        .item_target => actionText(state, state.actor, .{ .item = .{ .slot = state.item_slot, .target = state.selection, .id = state.progress.party.at(state.actor).inventory.slots[state.item_slot].?.id } }, buffer),
        .spell => state.rune(state.actor).?.spell_names[state.selection],
        .spell_target => actionText(state, state.actor, .{ .spell = .{ .index = state.spell_slot, .target = state.selection } }, buffer),
        else => "",
    };
}

const effect_palette = @import("battle_effect_palette.zig");
const geometry = battle.layout;
const position = geometry.position;
pub const actorLayout = geometry.actorLayout;
pub const shadowLayout = geometry.shadowLayout;

fn pose(atlas: rl.Texture2D, sprite: battle.Pose, point: presentation.ScreenPoint, scale: f32, tint: rl.Color, flip_y: bool) void {
    const rect = sprite.rect;
    rl.drawTexturePro(atlas, .{ .x = @floatFromInt(rect.x), .y = @floatFromInt(rect.y), .width = @floatFromInt(rect.w), .height = @floatFromInt(if (flip_y) -rect.h else rect.h) }, .{ .x = point.x - @as(f32, @floatFromInt(sprite.anchor_x)) * scale, .y = point.y - @as(f32, @floatFromInt(sprite.anchor_y)) * scale, .width = @as(f32, @floatFromInt(rect.w)) * scale, .height = @as(f32, @floatFromInt(rect.h)) * scale }, .{ .x = 0, .y = 0 }, 0, tint);
}

pub fn drawUniteTrail(state: battle.State, atlas: rl.Texture2D, member: usize) void {
    const quads = geometry.uniteTrail(state, member) orelse return;
    rl.beginBlendMode(.alpha);
    defer rl.endBlendMode();
    for (quads) |quad| pose(atlas, quad.sprite, quad.point, quad.scale, .{ .r = 255, .g = 255, .b = 255, .a = 128 }, false);
}

pub fn drawUniteAuxiliary(state: battle.State, atlas: rl.Texture2D, effect_atlas: ?rl.Texture2D, index: usize) void {
    rl.beginBlendMode(.alpha);
    defer rl.endBlendMode();
    var piece: usize = 0;
    while (geometry.uniteAuxiliaryPiece(state, index, piece)) |quad| : (piece += 1) {
        const texture = if (quad.effect) effect_atlas orelse atlas else atlas;
        const color = quad.color;
        const tint = rl.Color{ .r = @intCast(@min(@as(u16, color[0]) * 2, 255)), .g = @intCast(@min(@as(u16, color[1]) * 2, 255)), .b = @intCast(@min(@as(u16, color[2]) * 2, 255)), .a = 255 };
        if (quad.blend != .@"opaque") {
            @import("battle_spell_view.zig").beginBlend(quad.blend);
            drawActorQuad(texture, quad, tint, false);
            rl.endBlendMode();
            rl.beginBlendMode(.alpha);
            continue;
        }
        drawActorQuad(texture, quad, tint, false);
        if (color[0] > 128 or color[1] > 128 or color[2] > 128) {
            rl.beginBlendMode(.additive);
            const excess = rl.Color{ .r = (color[0] -| 128) * 2, .g = (color[1] -| 128) * 2, .b = (color[2] -| 128) * 2, .a = 255 };
            drawActorQuad(texture, quad, excess, false);
            rl.endBlendMode();
            rl.beginBlendMode(.alpha);
        }
    }
}
pub fn drawActorQuad(atlas: rl.Texture2D, quad: geometry.AuxiliaryQuad, tint: rl.Color, flip_y: bool) void {
    var vertices: [4]rl.Vector2 = undefined;
    for (quad.vertices, 0..) |vertex, i| vertices[i] = .{ .x = vertex.x, .y = vertex.y };
    const rect = quad.sprite.rect;
    var color = tint;
    if (quad.translucent) color.a = 128;
    @import("raylib_app").drawTexturedQuad(atlas, .{ .x = @floatFromInt(rect.x), .y = @floatFromInt(rect.y), .width = @floatFromInt(rect.w), .height = @floatFromInt(rect.h) }, vertices, color, flip_y);
}

const Feedback = struct {
    context: *const ui.Context,
    rows: geometry.FeedbackRows = .{},

    fn drawNumber(self: *Feedback, comptime format: []const u8, values: anytype, x: f32, y: f32, size: i32, color: rl.Color) void {
        const row = self.rows.place(@intFromFloat(y), size) orelse return;
        self.context.numberText(format, values, @intFromFloat(x), row, size, color);
    }

    fn drawText(self: *Feedback, label: []const u8, x: f32, y: f32, size: i32, color: rl.Color) void {
        const row = self.rows.place(@intFromFloat(y), size) orelse return;
        self.context.text(label, @intFromFloat(x), row, size, color);
    }
};

fn drawCounterFeedback(state: battle.State, index: usize, x: f32, y: f32, critical_y: f32, feedback: *Feedback) void {
    for (state.unite_vm.counter_actions) |maybe| {
        const counter = maybe orelse continue;
        if (counter.showsMiss(index, state.camera_ticks)) {
            feedback.drawText("MISS", x - 4, y, 18, .ray_white);
        }
        const at = counter.contact_at orelse continue;
        if (counter.victim() == index and state.camera_ticks -% at < 30) {
            if (counter.amount != 0) feedback.drawNumber("-{d}", .{counter.amount}, x, y, 22, .gold);
            if (counter.kind.party() and counter.critical) feedback.drawText("CRITICAL", x - 10, critical_y, 13, .gold);
        }
    }
}

pub fn drawActorFeedback(context: *const ui.Context, state: battle.State, index: usize, x: f32, baseline_y: f32, head_y: f32) void {
    var feedback: Feedback = .{ .context = context };
    if (state.recentItemImpact(index)) |impact| {
        if (impact.revived) {
            feedback.drawNumber("REVIVED +{d}", .{impact.recovered_hp}, x - 46, head_y - 22, 16, .green);
        } else if (impact.recovered_hp != 0) {
            feedback.drawNumber("+{d}", .{impact.recovered_hp}, x - 18, head_y - 22, 22, .green);
        }
        if (impact.cured_poison) feedback.drawText("POISON CURED", x - 46, head_y - 22, 14, .green);
        if (impact.removed_balloon) feedback.drawText("BALLOON REMOVED", x - 56, head_y - 22, 14, .green);
    }
    drawCounterFeedback(state, index, x - 18, head_y - 22, baseline_y - 108, &feedback);
    for (state.party_strikes) |maybe| {
        const strike = maybe orelse continue;
        if (strike.target != index or !strike.showsFeedback(state.partyAttackTiming(strike.actor).?)) continue;
        if (strike.missed) {
            feedback.drawText("MISS", x - 22, head_y - 22, 18, .ray_white);
        } else {
            if (strike.amount != 0) feedback.drawNumber("-{d}", .{strike.amount}, x - 18, head_y - 22, 22, .gold);
            if (strike.critical) feedback.drawText("CRITICAL", x - 28, baseline_y - 108, 13, .gold);
        }
    }
    if (index < state.partyCount()) if (state.enemy_magic_damage[index]) |notice| if (state.camera_ticks -% notice.issued_at < 30) {
        if (notice.amount != 0) feedback.drawNumber("-{d}", .{notice.amount}, x - 18, head_y - 22, 22, .gold);
    };
    if (state.active) |effect| {
        const ticks = state.effectTicks();
        const impact = state.impactTick();
        if (!effect.counter_attack and (effect.protector orelse effect.target) == index and ticks >= impact and ticks - impact < 30) {
            switch (effect.kind) {
                .attack, .group_order => if (effect.amount != 0) feedback.drawNumber("-{d}", .{effect.amount}, x - 18, head_y - 22, 22, .gold),
                .miss => feedback.drawText("MISS", x - 22, head_y - 22, 18, .ray_white),
                else => {},
            }
            if (effect.critical) feedback.drawText("CRITICAL", x - 28, baseline_y - 108, 13, .gold);
        }
    }
    if (state.uniteDamageAmount(index)) |amount| if (amount != 0) feedback.drawNumber("-{d}", .{amount}, x - 18, head_y - 22, 22, .gold);
    if (state.active) |effect| if (effect.enemy_special and state.enemy(effect.actor - state.partyCount()).action_policy == .ant_double_strike and effect.target == index and state.effectTicks() >= state.impactTick() and state.effectTicks() < state.impactTick() + 30) feedback.drawText("DOUBLE STRIKE", x - 40, baseline_y - 108, 13, .gold);
    if (state.active) |effect| if (effect.kind == .cast and effect.affected & (@as(u16, 1) << @intCast(index)) != 0 and state.effectTicks() >= state.impactTick()) {
        const spell = state.content.systems.?.spells[effect.spell];
        const damage = spell.kind == .damage or effect.spell_hp_loss & (@as(u16, 1) << @intCast(index)) != 0;
        const color: rl.Color = if (damage) .orange else if (spell.kind == .sleep) .violet else .green;
        if (effect.amounts[index] > 0) feedback.drawNumber("{s}{d}", .{ if (damage) "-" else "+", effect.amounts[index] }, x - 20, baseline_y - 85, 20, color) else if (spell.kind == .damage or (spell.kind == .sleep and state.actor_conditions[index].sleep_turns == 0)) feedback.drawText("RESIST", x - 24, baseline_y - 85, 15, .light_gray);
    };
}

fn actor(context: *const ui.Context, state: battle.State, atlas: rl.Texture2D, effect_atlas: ?rl.Texture2D, index: usize, show_overlays: bool) void {
    if (index < state.partyCount() and state.departed[index] and state.departures[index] == null) return;
    const profile = if (index < state.partyCount()) state.partyProfile(index) else state.enemy(index - state.partyCount());
    const layout = actorLayout(state, index);
    const point = layout.point;
    const scale = layout.scale;
    const sprite = layout.sprite;
    const response = state.spellReaction(index);
    if (response != null and !response.?.visible) return;
    var tint = rl.Color.white;
    if (state.hp(index) == 0) {
        if (index < state.partyCount()) {
            if (state.revivalAge(index) == null and profile.revival_art == null) tint = .gray;
        } else if (response == null and !state.unite_vm.ownsActor(index) and (state.active == null or (state.active.?.target != index and state.active.?.affected & (@as(u16, 1) << @intCast(index)) == 0))) return;
    }
    if (state.active) |effect| {
        const ticks = state.effectTicks();
        if (!effect.counter_attack and !(effect.rune_attack and state.sourcePhysicalRuneOwner(effect.actor)) and effect.target == index and ticks >= state.impactTick() and ticks < state.impactTick() + 18 and (effect.kind == .attack or effect.kind == .unite)) {
            tint = if (ticks % 6 < 3) .red else .white;
        }
        if (response == null and !state.unite_vm.ownsActor(index) and index >= state.partyCount() and state.hp(index) == 0) tint.a = presentation.fadeAlpha(ticks -| state.impactTick());
    }
    if (response) |value| {
        tint = .{ .r = @intCast(@min(@as(u32, value.tint) * value.color[0] / 64, 255)), .g = @intCast(@min(@as(u32, value.tint) * value.color[1] / 64, 255)), .b = @intCast(@min(@as(u32, value.tint) * value.color[2] / 64, 255)), .a = 255 };
        @import("battle_spell_view.zig").beginBlend(value.blend);
    }
    const rotated = geometry.rotatedActorQuad(state, index, sprite, point);
    const sprite_atlas = if (response != null and response.?.entry != null) effect_atlas orelse atlas else atlas;
    if (rotated) |quad| drawActorQuad(sprite_atlas, quad, tint, response != null and response.?.flip_y) else pose(sprite_atlas, sprite, point, scale, tint, response != null and response.?.flip_y);
    if (response) |value| {
        rl.endBlendMode();
        var excess: [3]u8 = undefined;
        for (0..3) |axis| excess[axis] = @intCast((@min(255, @as(u32, value.color[axis]) * value.tint / 128) -| 128) * 2);
        if (excess[0] != 0 or excess[1] != 0 or excess[2] != 0) {
            rl.beginBlendMode(.additive);
            const excess_tint = rl.Color{ .r = excess[0], .g = excess[1], .b = excess[2], .a = 255 };
            if (rotated) |quad| drawActorQuad(sprite_atlas, quad, excess_tint, value.flip_y) else pose(sprite_atlas, sprite, point, scale, excess_tint, value.flip_y);
            rl.endBlendMode();
        }
    }
    if (response == null and state.revivalAge(index) != null) {
        const excess = (battle.revival.revivalLight(state, index) -| 128) * 2;
        if (excess != 0) {
            rl.beginBlendMode(.additive);
            pose(atlas, sprite, point, scale, .{ .r = excess, .g = excess, .b = excess, .a = 255 }, false);
            rl.endBlendMode();
        }
    }
    if (!show_overlays) return;
    drawActorFeedback(context, state, index, point.x, point.y, point.y - @as(f32, @floatFromInt(sprite.anchor_y)) * scale);
    if (index >= state.partyCount() and state.hp(index) > 0) {
        context.numberText("{s} {d}", .{ profile.name, index - state.partyCount() + 1 }, @intFromFloat(point.x - 40), @max(40, @as(i32, @intFromFloat(point.y - @as(f32, @floatFromInt(sprite.anchor_y)) * scale - 18))), 12, .ray_white);
        rl.drawRectangle(@intFromFloat(point.x - 32), @intFromFloat(point.y + 5), 64, 4, .dark_gray);
        rl.drawRectangle(@intFromFloat(point.x - 32), @intFromFloat(point.y + 5), @intCast(@as(u32, state.hp(index)) * 64 / profile.max_hp), 4, .red);
    }
    const source_status = state.hasStatusIconsFor(index);
    if (!source_status and index < state.partyCount() and state.unbalanced[index] > 0 and state.hp(index) > 0) context.text("RECOVERING", @intFromFloat(point.x - 26), @intFromFloat(point.y - 65), 12, .gold);
    if (!source_status and state.actor_conditions[index].sleep_turns > 0 and state.hp(index) > 0) context.text("Zzz", @intFromFloat(point.x), @intFromFloat(point.y - 65), 16, .sky_blue);
    if (!source_status and index < state.partyCount() and state.progress.party.at(index).balloons > 0) context.numberText("BALLOON {d}", .{state.progress.party.at(index).balloons}, @intFromFloat(point.x - 30), @intFromFloat(point.y - 80), 12, .gold);
    if (!source_status and index < state.partyCount() and state.progress.party.at(index).status == .poisoned) context.text("POISON", @intFromFloat(point.x - 20), @intFromFloat(point.y - 65), 12, .violet);
    if (state.actor_conditions[index].protection_rounds > 0) context.text("PROTECT", @intFromFloat(point.x - 24), @intFromFloat(point.y - 104), 12, .sky_blue);
    if (!source_status and state.actor_conditions[index].accuracy_reduced) context.text("ACCURACY DOWN", @intFromFloat(point.x - 38), @intFromFloat(point.y - 92), 10, .gold);
    if (!source_status and state.actor_conditions[index].rune_blocked) context.text("RUNE BLOCKED", @intFromFloat(point.x - 36), @intFromFloat(point.y - 80), 10, .violet);
    if (index < state.partyCount() and state.hp(index) == 0) context.text("KO", @intFromFloat(point.x - 10), @intFromFloat(point.y - 55), 20, .gold);
    if (state.phase == .resolving and index < state.partyCount() and state.actions[index] != null and state.actions[index].? == .defend and state.hp(index) > 0) {
        rl.drawCircleLines(@intFromFloat(point.x), @intFromFloat(point.y - 40), 33, .sky_blue);
    }
    if (state.phase == .resolving and state.active != null and state.active.?.target == index) {
        context.text(">", @intFromFloat(point.x - @as(f32, @floatFromInt(sprite.anchor_x)) * scale - 20), @intFromFloat(point.y - 35), 24, .gold);
        rl.drawEllipseLines(@intFromFloat(point.x), @intFromFloat(point.y), 30, 9, .gold);
    }
}

fn spellComposition(state: battle.State) void {
    // The accepted composition packet is the only spell-animation
    // source, and it is consumed at the coordinator's own clock.  A residency
    // tick is a texture upload rather than an impact, and the actor tracks are
    // already drawn by the world-art pass, so neither adds a quad here.  Every
    // spell atlas page is still blocked on palette/page/lifetime, so a blocked
    // spell emits no quad, tint, ring or label: the authored sparkle shortcut is
    // gone rather than kept as a stand-in.
    _ = state.effectFrame(state.effectTicks());
}

fn drawImpactShape(name: []const u8, cx: i32, cy: i32, tick: u16, core: rl.Color, glow: rl.Color) void {
    if (std.mem.indexOf(u8, name, "Water") != null or std.mem.indexOf(u8, name, "Rain") != null or std.mem.indexOf(u8, name, "Ocean") != null or std.mem.indexOf(u8, name, "Kindness") != null) {
        for (0..6) |i| {
            const dx = @as(i32, @intCast(i)) * 11 - 27;
            const h = 8 + @as(i32, @intCast(@mod(@as(i32, @intCast(i)) * 5 + tick, 20)));
            rl.drawCircleV(.{ .x = @floatFromInt(cx + dx), .y = @floatFromInt(cy - h) }, 5, core);
        }
    } else if (std.mem.indexOf(u8, name, "Storm") != null or std.mem.indexOf(u8, name, "Thunder") != null or std.mem.indexOf(u8, name, "Lightning") != null) {
        var y = cy - 40;
        var x = cx - 20;
        for (0..5) |i| {
            const nx = cx + (if (i % 2 == 0) @as(i32, 18) else @as(i32, -18)) + @as(i32, @intCast(i)) * 3;
            rl.drawLine(x, y, nx, y + 10, core);
            x = nx;
            y += 10;
        }
    } else if (std.mem.indexOf(u8, name, "Earth") != null or std.mem.indexOf(u8, name, "Clay") != null or std.mem.indexOf(u8, name, "Copper") != null or std.mem.indexOf(u8, name, "Guardian") != null) {
        for (0..5) |i| {
            const dx = @as(i32, @intCast(i)) * 12 - 24;
            const h = 10 + @as(i32, @intCast(@mod(@as(i32, @intCast(i)) * 9 + tick, 12)));
            rl.drawRectangle(cx + dx - 6, cy - h, 12, h, core);
        }
    } else if (std.mem.indexOf(u8, name, "Black") != null or std.mem.indexOf(u8, name, "Hell") != null or std.mem.indexOf(u8, name, "Judgment") != null or std.mem.indexOf(u8, name, "Deadly") != null) {
        for (0..5) |i| {
            const dx = @as(i32, @intCast(i)) * 13 - 26;
            const h = 10 + @as(i32, @intCast(@mod(@as(i32, @intCast(i)) * 7 + tick, 22)));
            rl.drawCircleV(.{ .x = @floatFromInt(cx + dx), .y = @floatFromInt(cy - h) }, 8, glow);
            rl.drawCircleV(.{ .x = @floatFromInt(cx + dx), .y = @floatFromInt(cy - h) }, 4, core);
        }
    } else {
        for (0..5) |i| {
            const dx = @as(i32, @intCast(i)) * 9 - 18;
            const h = 18 + @as(i32, @intCast(@mod(@as(i32, @intCast(i)) * 7 + tick, 15)));
            rl.drawTriangle(.{ .x = @floatFromInt(cx + dx - 7), .y = @floatFromInt(cy) }, .{ .x = @floatFromInt(cx + dx), .y = @floatFromInt(cy - h) }, .{ .x = @floatFromInt(cx + dx + 7), .y = @floatFromInt(cy) }, core);
        }
    }
    rl.drawCircleV(.{ .x = @floatFromInt(cx), .y = @floatFromInt(cy) }, 30, glow);
}

fn drawCastVfx(state: battle.State) void {
    if (state.hasSourceEffect()) return;
    const effect = state.active orelse return;
    if (effect.kind == .unite) {
        const a = actorLayout(state, effect.actor).point;
        const b = if (effect.partner) |partner| actorLayout(state, partner).point else a;
        const t = actorLayout(state, effect.target).point;
        const mx = t.x;
        const my = t.y - 30;
        const pulse = 18 + @as(i32, @intCast(@mod(state.effectTicks(), 16)));
        const gold = rl.Color{ .r = 255, .g = 210, .b = 80, .a = 255 };
        for (0..12) |i| {
            const angle = @as(f32, @floatFromInt(i)) * std.math.pi / 6.0;
            const r = @as(f32, @floatFromInt(pulse));
            rl.drawCircleV(.{ .x = mx + @cos(angle) * r, .y = my + @sin(angle) * r }, 4, gold);
        }
        rl.drawLine(@intFromFloat(a.x), @intFromFloat(a.y - 20), @intFromFloat(b.x), @intFromFloat(b.y - 20), gold);
        return;
    }
    if (effect.kind != .cast) return;
    const systems = state.content.systems orelse return;
    if (effect.spell >= systems.spells.len) return;
    const spell = systems.spells[effect.spell];
    const name = spell.name;
    const support = spell.allies;
    const damaging = spell.kind == .damage;
    const caster_layout = actorLayout(state, effect.actor);
    const caster = caster_layout.point;
    const target = actorLayout(state, effect.target).point;
    const rune_y = caster.y - @as(f32, @floatFromInt(caster_layout.sprite.anchor_y)) * caster_layout.scale - 8;
    const tick = state.effectTicks();
    const impact = state.impactTick();
    const projectile_start = impact -| 8;
    const palette = effect_palette.forSpell(name);
    const core = palette[8];
    var glow = palette[12];
    glow.a = 220;
    if (support) {
        if (tick < impact) {
            const cx = @as(i32, @intFromFloat(caster.x));
            const cy = @as(i32, @intFromFloat(rune_y));
            rl.drawCircleLines(cx, cy, 16, core);
            rl.drawCircleLines(cx, cy, 22, glow);
        } else {
            const cx = @as(i32, @intFromFloat(std.math.clamp(target.x, 24, 616)));
            const cy = @as(i32, @intFromFloat(std.math.clamp(target.y - 20, 70, 310)));
            for (0..5) |i| {
                const dx = @as(i32, @intCast(i)) * 10 - 20;
                const rise = @as(i32, @intCast(@mod(@as(i32, @intCast(i)) * 11 + tick, 28)));
                rl.drawCircleV(.{ .x = @floatFromInt(cx + dx), .y = @floatFromInt(cy - rise) }, 5, core);
            }
            rl.drawCircleLines(cx, cy + 16, 24, glow);
        }
        return;
    }
    if (!damaging and !support) {
        if (tick < impact) {
            const cx = @as(i32, @intFromFloat(caster.x));
            const cy = @as(i32, @intFromFloat(rune_y));
            rl.drawCircleV(.{ .x = @floatFromInt(cx), .y = @floatFromInt(cy) }, 5, core);
            for (0..8) |i| {
                const angle = @as(f32, @floatFromInt(i)) * std.math.pi / 4.0;
                rl.drawCircleV(.{ .x = @as(f32, @floatFromInt(cx)) + @cos(angle) * 18, .y = @as(f32, @floatFromInt(cy)) + @sin(angle) * 18 }, 3, core);
            }
        } else {
            const cx = @as(i32, @intFromFloat(std.math.clamp(target.x, 24, 616)));
            const cy = @as(i32, @intFromFloat(std.math.clamp(target.y - 24, 80, 310)));
            for (0..8) |i| {
                const angle = @as(f32, @floatFromInt(i)) * std.math.pi / 4.0;
                rl.drawCircleV(.{ .x = @as(f32, @floatFromInt(cx)) + @cos(angle) * 26, .y = @as(f32, @floatFromInt(cy)) + @sin(angle) * 16 }, 5, core);
            }
            rl.drawCircleV(.{ .x = @as(f32, @floatFromInt(cx)), .y = @as(f32, @floatFromInt(cy)) }, 8, glow);
        }
        return;
    }
    if (tick < projectile_start) {
        const cx = @as(i32, @intFromFloat(caster.x));
        const cy = @as(i32, @intFromFloat(rune_y));
        const pulse = 14 + @as(i32, @intCast(tick / 4));
        rl.drawCircleLines(cx, cy, @floatFromInt(pulse), core);
        rl.drawCircleLines(cx, cy, @floatFromInt(pulse + 6), glow);
        if (tick % 4 < 2) rl.drawCircleV(.{ .x = @floatFromInt(cx), .y = @floatFromInt(cy) }, 3, core);
    } else if (tick < impact) {
        const f = @as(f32, @floatFromInt(tick - projectile_start)) / @as(f32, @floatFromInt(@max(impact - projectile_start, 1)));
        const x = caster.x + (target.x - caster.x) * f;
        const y = caster.y + (target.y - caster.y) * f - 34.0;
        rl.drawCircleV(.{ .x = x, .y = y }, 8, glow);
        rl.drawCircleV(.{ .x = x, .y = y }, 3, core);
    } else {
        const cx = @as(i32, @intFromFloat(target.x));
        const cy = @as(i32, @intFromFloat(target.y - 30));
        drawImpactShape(name, cx, cy, tick, core, glow);
        const burst = @as(i32, @intCast(tick - impact));
        if (burst < 8) rl.drawCircleLines(cx, cy, @floatFromInt(26 + burst * 5), core);
    }
}
fn drawScene(context: *const ui.Context, state: battle.State, atlas: rl.Texture2D, floor: rl.Texture2D, ground_texture: ?rl.Texture2D, effect_atlas: ?rl.Texture2D, dynamic: ?*@import("battle_spell_view.zig").DynamicTexture, minimum_depth: ?u16) void {
    rl.clearBackground(if (minimum_depth != null) .blank else .black);
    const frame = geometry.framing(state);
    rl.beginScissorMode(0, 0, 640, 480);
    rl.beginMode2D(.{ .offset = .{ .x = frame.x, .y = frame.y }, .target = .{ .x = 0, .y = 0 }, .rotation = 0, .zoom = frame.zoom });
    @import("battle_ground_view.zig").draw(&state, floor, ground_texture, minimum_depth orelse 0);
    // Ground decals precede every billboard, so they cannot darken another actor or prop.
    if ((minimum_depth orelse 0) <= 380) for (0..state.partyCount()) |index| {
        if (state.departed[index]) continue;
        const shadow = shadowLayout(state, index);
        rl.drawEllipse(@intFromFloat(shadow.point.x), @intFromFloat(shadow.point.y), shadow.radius_x, shadow.radius_y, .{ .r = 0, .g = 0, .b = 0, .a = 140 });
    };
    const Entry = struct { scenery: bool, effect: bool = false, trail: bool = false, auxiliary: bool = false, revival: ?u2 = null, item_particle: ?u3 = null, index: usize, depth: f32 };
    var entries: [battle.spell_scene.Frame.capacity + 105 + 24 + 19 + 48 + 16 + geometry.mirage_copy_capacity]Entry = undefined;
    const source_frame: ?battle.spell_scene.Frame = if (state.hasSourceEffect() or state.hasStatusIcons()) state.spellSceneFrame() else null;
    var count: usize = 0;
    const scenery = geometry.scenery(&state);
    for (scenery, 0..) |prop, index| {
        entries[count] = .{ .scenery = true, .index = index, .depth = geometry.worldPoint(state, prop.position).depth };
        count += 1;
    }
    for (0..state.partyCount() + state.enemyCount()) |index| {
        entries[count] = .{ .scenery = false, .index = index, .depth = position(state, index).depth };
        count += 1;
        if (geometry.uniteTrail(state, index)) |trail| {
            const depth = if (index >= state.partyCount()) trail[0].point.depth else if (state.unite_vm.ownsActor(index)) state.unite_trails[index].points[0].depth else position(state, index).depth;
            entries[count] = .{ .scenery = false, .trail = true, .index = index, .depth = depth + 8 };
            count += 1;
        }
    }
    for (0..state.partyCount()) |member| if (geometry.revivalParticles(state, member)) |quads| for (quads, 0..) |quad, index| {
        entries[count] = .{ .scenery = false, .revival = @intCast(index), .index = member, .depth = quad.point.depth };
        count += 1;
    };
    for (0..state.partyCount()) |member| if (geometry.itemParticles(&state, member)) |particles| for (particles.quads[0..particles.count], 0..) |quad, index| {
        entries[count] = .{ .scenery = false, .item_particle = @intCast(index), .index = member, .depth = quad.point.depth };
        count += 1;
    };
    for (0..battle.layout.unite_graphic_capacity) |index| if (geometry.uniteAuxiliary(state, index)) |quad| {
        entries[count] = .{ .scenery = false, .auxiliary = true, .index = index, .depth = quad.depth };
        count += 1;
    };
    for (0..state.unite_vm.auxiliary.len) |index| if (geometry.uniteTrail(state, state.unite_vm.actors.len + index)) |trail| {
        entries[count] = .{ .scenery = false, .trail = true, .index = state.unite_vm.actors.len + index, .depth = trail[0].point.depth + 8 };
        count += 1;
    };
    if (source_frame) |source| for (source.commands[0..source.count], 0..) |command, i| {
        if (!command.drawsInPass(minimum_depth)) continue;
        entries[count] = .{ .scenery = false, .effect = true, .index = i, .depth = @floatFromInt(command.depth * 4) };
        count += 1;
    };
    std.mem.sort(Entry, entries[0..count], {}, struct {
        fn before(_: void, a: Entry, b: Entry) bool {
            if (a.depth == b.depth) {
                if (a.effect != b.effect) return a.effect;
                return a.index > b.index;
            }
            return a.depth > b.depth;
        }
    }.before);
    for (entries[0..count]) |entry| {
        if (minimum_depth) |minimum| if (entry.depth < @as(f32, @floatFromInt(@as(u32, minimum) * 4))) continue;
        if (entry.item_particle) |clone| {
            const quad = geometry.itemParticles(&state, entry.index).?.quads[clone];
            rl.beginBlendMode(.alpha);
            pose(atlas, quad.sprite, quad.point, quad.scale, .{ .r = @intCast(@min(@as(u16, quad.light[0]) * 2, 255)), .g = @intCast(@min(@as(u16, quad.light[1]) * 2, 255)), .b = @intCast(@min(@as(u16, quad.light[2]) * 2, 255)), .a = 128 }, false);
            rl.endBlendMode();
        } else if (entry.revival) |clone| {
            const quad = geometry.revivalParticles(state, entry.index).?[clone];
            pose(atlas, quad.sprite, quad.point, quad.scale, .{ .r = @intCast(@min(@as(u16, quad.light[0]) * 2, 255)), .g = @intCast(@min(@as(u16, quad.light[1]) * 2, 255)), .b = @intCast(@min(@as(u16, quad.light[2]) * 2, 255)), .a = 255 }, false);
        } else if (entry.auxiliary) {
            drawUniteAuxiliary(state, atlas, effect_atlas, entry.index);
        } else if (entry.trail) {
            drawUniteTrail(state, atlas, entry.index);
        } else if (entry.effect) {
            @import("battle_spell_view.zig").drawCommand(state, effect_atlas orelse atlas, dynamic, source_frame.?.commands[entry.index]);
        } else if (entry.scenery) {
            const prop = scenery[entry.index];
            const prop_scale = if (state.hasSourceEffect()) @as(f32, @floatFromInt(geometry.currentCamera(state).scale[0])) / 2048 else state.content.sprite_scale;
            pose(atlas, prop.sprite, geometry.worldPoint(state, prop.position), prop_scale, .white, false);
        } else actor(context, state, atlas, effect_atlas, entry.index, minimum_depth == null);
    }
    if (minimum_depth == null) if (selectionTarget(&state)) |target| {
        const layout = actorLayout(state, target);
        drawTargetMarker(context, layout.point.x, layout.point.y);
    };
    if (minimum_depth == null) if (choosingMember(state)) |member| {
        const layout = actorLayout(state, member);
        const tip = rl.Vector2{ .x = layout.point.x, .y = layout.point.y - @as(f32, @floatFromInt(layout.sprite.anchor_y)) * layout.scale - 4 };
        rl.drawTriangle(.{ .x = tip.x - 7, .y = tip.y - 12 }, tip, .{ .x = tip.x + 7, .y = tip.y - 12 }, .sky_blue);
        context.text(state.name(member), @intFromFloat(tip.x + 10), @intFromFloat(tip.y - 15), 14, .sky_blue);
    };
    if (minimum_depth == null) if (source_frame) |source| {
        @import("battle_spell_view.zig").beginBlend(source.wash_blend);
        rl.drawRectangle(0, 0, 640, 480, .{ .r = source.wash[0], .g = source.wash[1], .b = source.wash[2], .a = 255 });
        rl.endBlendMode();
    };
    if (minimum_depth == null) drawCastVfx(state);
    if (minimum_depth == null) spellComposition(state);
    rl.endMode2D();
    rl.endScissorMode();
}

// EndTextureMode restores the screen framebuffer, so capture before entering the final canvas.
pub fn prepare(context: *const ui.Context, state: battle.State, atlas: rl.Texture2D, floor: rl.Texture2D, ground_texture: ?rl.Texture2D, effect_atlas: ?rl.Texture2D, dynamic: ?*@import("battle_spell_view.zig").DynamicTexture) void {
    if (state.content.world_art != null) {
        @import("battle_world_view.zig").prepare(context, state, atlas, floor, ground_texture, effect_atlas, dynamic);
    } else {
        if (state.backgroundCaptureMinimum()) |minimum| if (dynamic) |cache| {
            rl.beginTextureMode(cache.background);
            drawScene(context, state, atlas, floor, ground_texture, effect_atlas, dynamic, minimum);
            rl.endTextureMode();
        };
    }
}

pub fn draw(context: *const ui.Context, state: battle.State, atlas: rl.Texture2D, floor: rl.Texture2D, ground_texture: ?rl.Texture2D, effect_atlas: ?rl.Texture2D, dynamic: ?*@import("battle_spell_view.zig").DynamicTexture) void {
    if (state.content.world_art != null) {
        @import("battle_world_view.zig").draw(context, state, atlas, floor, ground_texture, effect_atlas, dynamic);
    } else {
        drawScene(context, state, atlas, floor, ground_texture, effect_atlas, dynamic, null);
    }
    if (state.active) |effect| if (effect.kind == .cast) {
        context.window(100, 40, 440, 27);
        context.numberText("{s} - {s}", .{ state.name(effect.actor), state.content.systems.?.spells[effect.spell].name }, 112, 47, 16, .sky_blue);
    };
    if (state.presentation_refusal.len != 0) {
        context.window(6, 64, 628, 24);
        context.text(state.presentation_refusal, 16, 70, 14, .orange);
    }
    context.window(6, 5, 628, 32);
    context.text(state.content.encounters[state.encounter].title, 16, 14, 16, .gold);
    context.numberText("{d} bits", .{state.progress.money}, 540, 14, 12, .gold);
    if (state.phase != .resolving) {
        context.window(8, 330, 300, 142);
        for (state.progress.party.items(), 0..) |member, index| {
            const row_y: i32 = 337 + @as(i32, @intCast(index)) * 21;
            const active = choosingMember(state) == index;
            const color: rl.Color = if (active) .sky_blue else if (state.participates(index)) .ray_white else .gray;
            context.numberText("{s}{s}", .{ if (active) "> " else "  ", member.name }, 17, row_y, 14, color);
            context.numberText("{d}/{d}", .{ member.hp, member.max_hp }, 205, row_y, 13, color);
        }
        context.window(314, 330, 318, 142);
    }
    switch (state.phase) {
        .battle_menu => {
            const labels = [_][]const u8{ "Fight", if (state.canLetGo()) "Let go" else "Run", "Bribe", "Free Will" };
            for (labels, 0..) |label, i| {
                const enabled = (i != 2 or state.content.encounters[state.encounter].bribe_cost != null) and (i != 3 or state.canFreeWill());
                context.numberText("{s}{s}", .{ if (state.selection == i) "> " else "  ", label }, command_x, 338 + @as(i32, @intCast(i)) * 23, 15, if (!enabled) .gray else if (state.selection == i) .gold else .ray_white);
            }
            context.text(switch (state.selection) {
                0 => "Choose action.",
                1 => if (!state.canEscape()) "Escape blocked." else "Release foes.",
                2 => if (state.content.encounters[state.encounter].bribe_cost != null) "Pay bribe." else "No bribe.",
                else => if (state.canFreeWill()) "Free Will." else "Unavailable.",
            }, command_x, 438, 11, .light_gray);
        },
        .command => {
            for (commands.labels, 0..) |label, index| {
                const y: i32 = 337 + @as(i32, @intCast(index)) * 20;
                if (@backingInt(state.picker.selected) == index) context.text(">", command_x, y, 14, .gold);
                context.text(label, command_x + 16, y, 13, if (state.picker.enabled[index]) .ray_white else .gray);
            }
        },
        .target, .unite_target, .rune_target => {
            const heading = if (state.phase == .unite_target) state.uniteName(state.actor) else if (state.phase == .rune_target) state.rune(state.actor).?.name else "Attack target";
            drawTargetList(context, &state, heading);
            if (state.phase == .unite_target and state.integration != null) context.text("Left/right: Unite   Up/down: target", command_x, 454, 10, .light_gray);
        },
        .item => {
            context.text("Item", command_x, 339, 15, .gold);
            for (state.progress.party.at(state.actor).inventory.slots, 0..) |slot, index| {
                const item = slot orelse break;
                const color: rl.Color = if (!state.canSelectItem(state.actor, index)) .gray else if (index == state.selection) .gold else .ray_white;
                const cursor = if (index == state.selection) "> " else "  ";
                const y = 358 + @as(i32, @intCast(index)) * 12;
                if (item.id == .sacrificial_buddha) context.numberText("{s}{s}: automatic", .{ cursor, item.name() }, command_x, y, 11, color) else if (item.id == .dragon_seal_incense) context.numberText("{s}{s}: reusable", .{ cursor, item.name() }, command_x, y, 11, color) else context.numberText("{s}{s}: {d}", .{ cursor, item.name(), item.uses }, command_x, y, 11, color);
            }
        },
        .item_target => drawTargetList(context, &state, state.progress.party.at(state.actor).inventory.slots[state.item_slot].?.name()),
        .spell => {
            const owned = state.rune(state.actor).?;
            context.numberText("{s}  MGC {d}", .{ owned.name, state.stats(state.actor).magic }, command_x, 339, 15, .gold);
            for (owned.spell_names, owned.spells, 0..) |name, slot, i| {
                const color: rl.Color = if (slot == null or !state.canSelectSpell(slot.?)) .gray else if (state.selection == i) .gold else .ray_white;
                context.numberText("{s}T{d} {s}  {d}/{d}", .{ if (state.selection == i) "> " else "  ", i + 1, name, state.progress.party.at(state.actor).rune_charges[i], state.progress.party.at(state.actor).max_rune_charges[i] }, command_x, 362 + @as(i32, @intCast(i)) * 20, 13, color);
            }
            if (owned.spells[state.selection]) |spell| {
                if (!state.canCast(state.actor, spell)) context.text("Spell unavailable.", command_x, 447, 12, .light_gray) else if (!state.canSelectSpell(spell)) context.text("No valid target.", command_x, 447, 12, .light_gray);
            } else context.text("Spell unavailable.", command_x, 447, 12, .light_gray);
        },
        .spell_target => {
            const spell = state.content.systems.?.spells[state.spell_slot];
            drawTargetList(context, &state, spell.name);
        },
        .escaped => {
            context.window(110, 110, 420, 160);
            if (state.bribed_enemies) context.numberText("Paid {d} bits", .{state.content.encounters[state.encounter].bribe_cost.?}, 130, 140, 22, .gold) else context.text(if (state.released_enemies) "Let go - no battle rewards" else "Escaped - no battle rewards", 130, 140, 22, .gold);
            context.text("Enter: finish", 130, 222, 18, .ray_white);
        },
        .run_refused, .bribe_refused => {
            context.window(110, 110, 420, 160);
            context.text(if (state.phase == .run_refused) "Escape blocked" else "You failed to make a deal", 130, 140, 22, .gold);
            context.text("Enter: the party defends this round", 130, 222, 18, .ray_white);
        },
        .resolving => {
            context.numberText("Round {d}", .{state.round}, 18, 352, 17, .gold);
            context.text(if (state.active != null and state.active.?.kind == .unite) "UNITE" else "ACTING", 18, 382, 12, .sky_blue);
            const acting = if (state.partyStrike()) |strike| state.name(strike.actor) else if (state.active) |effect| state.name(effect.actor) else if (state.medicine_action) |item| (if (!item.owner_released) state.name(item.actor) else "Next actor...") else "Next actor...";
            context.text(acting, 18, 400, 18, .sky_blue);
            if (state.active == null and state.partyStrike() == null) if (state.medicine_action) |item| if (!item.owner_released) {
                context.window(6, 456, 628, 24);
                context.numberText("{s} uses {s} on {s}.", .{ state.name(item.actor), item.id.name(), if (state.rules.consumable(item.id).?.partyWide()) "all allies" else state.name(item.target) }, 16, 462, 14, .green);
            };
            if (state.active) |effect| if (effect.kind == .unite) if (effect.partner) |partner| context.numberText("+ {s}", .{state.name(partner)}, 18, 423, 18, .sky_blue);
            if (state.active) |effect| {
                context.window(6, 456, 628, 24);
                var target_buffer: [96]u8 = undefined;
                const target = fighterLabel(&state, effect.target, &target_buffer);
                if (effect.retargeted_from) |original| {
                    var original_buffer: [96]u8 = undefined;
                    context.numberText("{s}: {s} {s} -> {s}{s}", .{ state.name(effect.actor), fighterLabel(&state, original, &original_buffer), if (state.hp(original) == 0) "down" else "out of reach", target, if (effect.kind == .miss) " (miss)" else "" }, 16, 462, 14, .gold);
                } else {
                    switch (effect.kind) {
                        .attack => context.numberText("{s}: {s} > {s} - {d} HP", .{ state.name(effect.actor), if (effect.rune_attack) state.rune(effect.actor).?.name else if (effect.followup_from != null) "Double-beat" else if (effect.enemy_special and state.enemy(effect.actor - state.partyCount()).action_policy == .ant_double_strike) "Double strike" else if (effect.critical) "Critical" else "Attack", target, effect.amount }, 16, 462, 14, .ray_white),
                        .miss => context.numberText("{s}'s attack on {s} missed.", .{ state.name(effect.actor), target }, 16, 462, 14, .ray_white),
                        .defend => context.numberText("{s} defends.", .{state.name(effect.actor)}, 16, 462, 14, .sky_blue),
                        .item => context.numberText("{s} uses {s} on {s}.", .{ state.name(effect.actor), effect.item_id.name(), state.name(effect.target) }, 16, 462, 14, .green),
                        .cast => context.numberText("{s}: {s}", .{ state.name(effect.actor), state.content.systems.?.spells[effect.spell].name }, 16, 462, 14, .gold),
                        .enemy_magic => context.numberText("{s} casts magic at {s}.", .{ state.name(effect.actor), target }, 16, 462, 14, .gold),
                        .unite => context.numberText("{s}: {s} > {s}", .{ state.name(effect.actor), state.uniteName(effect.actor), target }, 16, 462, 14, .gold),
                        .group_order => context.numberText("{s} issues an order.", .{state.name(effect.actor)}, 16, 462, 14, .sky_blue),
                        .enemy_command => if (effect.target == effect.actor) context.numberText("{s} issues an order.", .{state.name(effect.actor)}, 16, 462, 14, .sky_blue) else context.numberText("{s} targets {s}.", .{ state.name(effect.actor), target }, 16, 462, 14, .sky_blue),
                        .status_attack => context.numberText("{s} targets {s}.", .{ state.name(effect.actor), state.name(effect.target) }, 16, 462, 14, .sky_blue),
                        .sleeping => context.numberText("{s} is asleep.", .{state.name(effect.actor)}, 16, 462, 14, .sky_blue),
                        .escape_failed => context.text("Run failed - party defends this round.", 16, 462, 14, .gold),
                        .escape => context.text("Trying to escape...", 16, 462, 14, .ray_white),
                        .unavailable => context.text("No effect. No item or rune charge consumed.", 16, 462, 14, .light_gray),
                    }
                }
            }
        },
        .confirm_round, .confirm_quit => {
            context.window(110, 60, 420, 270);
            context.text(if (state.phase == .confirm_round) "Begin this round?" else "Leave the battle trial?", 132, 76, 22, .gold);
            if (state.phase == .confirm_round) {
                for (0..state.partyCount()) |index| {
                    var buffer: [256]u8 = undefined;
                    context.numberText("{s}: {s}", .{ state.name(index), queuedActionText(state, index, &buffer) }, 132, 112 + @as(i32, @intCast(index)) * 26, 17, if (state.hp(index) == 0) .gray else .ray_white);
                }
                if (state.content.systems != null) context.text("Turn order uses SPD; spells may follow attacks.", 132, 283, 15, .sky_blue);
            } else context.text("Trial progress will be discarded.", 132, 156, 17, .ray_white);
            context.text(if (state.yes) "> Yes       No" else "  Yes     > No", 158, 298, 20, .ray_white);
        },
        .intro => {
            context.window(72, 76, 496, 225);
            context.text("Three-battle trial", 94, 96, 26, .gold);
            context.text(if (state.partyCount() == 2) "Hero and Gremio - level-five test party" else "Six-member systems test party", 94, 141, 19, .ray_white);
            context.text("1 BonBon -> 3 BonBons -> Wild boar", 94, 176, 19, .ray_white);
            context.text("HP and Medicine carry between fights.", 94, 210, 17, .ray_white);
            context.text("Z/Enter: begin    X/Esc: leave", 94, 262, 17, .gold);
        },
        .loot, .loot_replace, .confirm_loot_replace, .confirm_leave_loot => {
            context.window(72, 58, 496, 274);
            context.numberText("Found {s}", .{state.dropped_item.?.name()}, 94, 76, 23, .gold);
            if (state.phase == .loot) {
                context.text("Choose a recipient or press X to leave it.", 94, 116, 17, .ray_white);
                for (state.progress.party.items(), 0..) |member, i| context.numberText("{s}{s}  {d}/9 items", .{ if (state.selection == i) "> " else "  ", member.name, member.inventory.count() }, 94, 147 + @as(i32, @intCast(i)) * 25, 18, .ray_white);
            } else if (state.phase == .loot_replace) {
                context.numberText("{s}'s bag is full. Choose an item to replace.", .{state.name(state.actor)}, 94, 111, 16, .ray_white);
                for (state.progress.party.at(state.actor).inventory.slots, 0..) |slot, i| context.numberText("{s}{s}{s}", .{ if (state.selection == i) "> " else "  ", slot.?.name(), if (state.itemEquipped(state.actor, i)) " [worn]" else "" }, 94, 139 + @as(i32, @intCast(i)) * 20, 17, if (state.itemEquipped(state.actor, i)) .gray else .ray_white);
            } else {
                context.text(if (state.phase == .confirm_leave_loot) "Leave this reward behind?" else "Discard the selected item and take this reward?", 94, 140, 18, .ray_white);
                context.text(if (state.yes) "> Yes      No" else "  Yes    > No", 110, 240, 20, .ray_white);
            }
        },
        .victory, .defeat, .complete => {
            if (state.phase == .defeat and state.hasDepartureFlights()) return;
            const short_victory = state.phase == .victory and state.content.encounters[state.encounter].reward_policy == .none;
            context.window(72, 58, 496, if (short_victory) 106 else 274);
            context.text(switch (state.phase) {
                .victory => "Victory!",
                .defeat => "Party defeated",
                else => "Trial complete",
            }, 94, 74, 26, .gold);
            if (short_victory) {
                context.text("Z/Enter: continue", 94, 122, 18, .gold);
            } else if (state.phase == .victory) {
                context.numberText("Earned {d} bits", .{state.reward_money}, 94, 107, 18, .ray_white);
                if (state.reward_received < state.reward_money) context.numberText("Kept {d} - wallet limit", .{state.reward_received}, 330, 110, 12, .gold);
                context.text("Member", 94, 134, 15, .sky_blue);
                context.text("Level", 215, 134, 15, .sky_blue);
                context.text("Gained", 331, 134, 15, .sky_blue);
                context.text("EXP", 447, 134, 15, .sky_blue);
                for (0..state.partyCount()) |i| {
                    const y = 157 + @as(i32, @intCast(i)) * 20;
                    context.text(state.name(i), 94, y, 16, if (!state.participates(i)) .gray else .ray_white);
                    if (state.reward_levels[i] != state.progress.party.at(i).level) context.numberText("{d} -> {d}", .{ state.reward_levels[i], state.progress.party.at(i).level }, 215, y, 16, .gold) else context.numberText("{d}", .{state.progress.party.at(i).level}, 215, y, 16, .ray_white);
                    context.numberText("+{d}{s}", .{ state.award_exp[i], if (state.departed[i]) " (departed)" else if (state.hp(i) == 0) " (KO)" else "" }, 331, y, 16, if (!state.participates(i)) .gray else .green);
                    if (state.progress.party.at(i).level == 99) context.text("MAX", 447, y, 16, .gold) else context.numberText("{d}/1000", .{state.progress.party.at(i).experience}, 447, y, 16, .ray_white);
                }
                if (state.dropped_item) |item| context.numberText("{s}: {s}", .{ item.name(), if (state.drop_received) (if (state.loot_recipient) |member| state.name(member) else "added to inventory") else if (state.loot_declined) "left behind" else "choose recipient on Continue" }, 94, 282, 16, if (state.drop_received) .green else .gold);
                context.text("Z/Enter: continue", 94, 308, 18, .gold);
            } else if (state.phase == .defeat and state.content.world_art != null) {
                context.text("No rewards. Close the window to leave.", 94, 145, 18, .ray_white);
            } else {
                context.numberText("Balance: {d} bits", .{state.progress.money}, 118, 145, 20, .ray_white);
                const companion_exp = if (state.partyCount() > 1) state.progress.party.at(1).experience else 0;
                context.numberText("Earned EXP: Hero {d} / Gremio {d}", .{ state.progress.party.at(0).experience, companion_exp }, 118, 185, 17, .ray_white);
                context.text("Z/Enter/R: restart    X/Esc: leave", 118, 264, 18, .gold);
            }
        },
    }
}
