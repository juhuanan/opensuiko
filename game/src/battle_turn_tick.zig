const std = @import("std");
const menu = @import("game");
const layout = @import("battle_layout.zig");
const presentation = @import("battle_presentation.zig");
const systems = @import("battle_rules");
const status = @import("battle_status.zig");
const turn = @import("battle_turn.zig");
const battle = @import("battle.zig");
const types_mod = @import("battle_types.zig");
const unite_host_mod = @import("battle_unite_host.zig");
const State = battle.State;
const Action = types_mod.Action;
const Input = types_mod.Input;
const UniteContext = unite_host_mod.UniteContext;
const uniteHost = unite_host_mod.uniteHost;
const departure = @import("battle_departure_data.zig");

pub fn hasDepartureFlights(self: *const State) bool {
    for (self.departures) |flight| if (flight != null) return true;
    return false;
}

fn retireDepartures(self: *State) void {
    for (&self.departures) |*slot| if (slot.*) |flight| {
        if (self.camera_ticks -% flight.started_at >= departure.offsets.len) slot.* = null;
    };
}

pub fn advanceDefeatDeparture(self: *State) void {
    if (self.phase != .defeat or !self.hasDepartureFlights()) return;
    self.camera_ticks +%= 1;
    retireDepartures(self);
}

pub fn startEncounter(self: *State) void {
    self.presentation_tick = 0;
    self.dodge_idle_at = @splat(null);
    self.actor_transforms = @splat(.{});
    self.camera_ticks = 0;
    self.formation_shifts = @splat(null);
    self.roc_cover = false;
    self.roc_attack_from_settled = false;
    self.hero_reaction_offset = false;
    self.front_hurt_at = @splat(null);
    self.front_hurt_repeated = @splat(false);
    self.roc_idle_at = null;
    self.roc_home_restored = false;
    self.round_start_pending = false;
    self.last_round_actor = 0;
    self.round_camera_choice = null;
    self.source_camera_hold = null;
    self.source_camera_return = null;
    self.actor_camera = null;
    self.physical_numerator = 10;
    self.clearTemporaryStats();
    self.enemy_hp = .{ 0, 0, 0, 0, 0, 0 };
    for (0..self.enemyCount()) |index| self.enemy_hp[index] = self.enemy(index).max_hp;
    self.round = 1;
    self.clearSleep();
    self.status_icons = @splat(.{});
    self.unbalanced = @splat(0);
    self.active = null;
    self.coordinator = null;
    self.party_strikes = @splat(null);
    self.front_projectiles = @splat(null);
    self.medicine_action = null;
    self.party_knockouts = @splat(.{});
    self.round_menu_pending = false;
    self.unite_boundaries = @splat(null);
    self.unite_returns = @splat(null);
    self.unite_reactions = @splat(null);
    self.selected_unites = @splat(null);
    self.unite_flags = @splat(0);
    self.unite_vm = .{};
    self.unite_scene = null;
    self.martial_queue = null;
    self.last_targets = @splat(-1);
    self.pending_enemy_actor = null;
    self.pending_party_actor = null;
    self.enemy_branch_selection = null;
    self.enemy_magic_pulse = null;
    self.enemy_magic_damage = @splat(null);
    self.rewards_committed = false;
    self.reward_money = 0;
    self.reward_received = 0;
    self.loot_recipient = null;
    self.drop_received = false;
    self.dropped_item = null;
    self.loot_declined = false;
    self.award_exp = @splat(0);
    self.reward_levels = self.levels;
    self.released_enemies = false;
    self.bribed_enemies = false;
    self.acted = @splat(false);
    self.actions = @splat(null);
    self.enterRoundMenu();
    status.advanceIcons(self);
}
pub fn canSelectItem(self: *const State, actor: usize, slot: usize) bool {
    const inventory = &self.progress.party[actor].inventory;
    if (slot >= inventory.count()) return false;
    const item = inventory.slots[slot].?;
    const rule = self.rules.consumable(item.id) orelse return false;
    return rule.uses == 0 or item.uses != 0;
}

fn firstBattleItem(self: *const State, actor: usize) ?usize {
    for (0..self.progress.party[actor].inventory.count()) |slot| {
        if (self.canSelectItem(actor, slot)) return slot;
    }
    return null;
}

fn firstSpellTarget(self: *const State, spell: systems.Spell) ?usize {
    if (spell.allies and self.spellValid(spell, self.actor)) return self.actor;
    const start = if (spell.allies) 0 else self.partyCount();
    const count = if (spell.allies) self.partyCount() else self.enemyCount();
    for (0..count) |index| {
        if (self.spellValid(spell, start + index)) return index;
    }
    return null;
}

pub fn canSelectSpell(self: *const State, index: usize) bool {
    if (!self.canCast(self.actor, index)) return false;
    const spell = self.content.systems.?.spells[index];
    return spell.group or firstSpellTarget(self, spell) != null;
}

pub fn choose(self: *State, actor: usize) void {
    unite_host_mod.releaseUniteFor(self, actor);
    if (self.actions[actor]) |prior| if (prior == .unite) {
        if (self.unitePartner(actor)) |partner| self.actions[partner] = null;
    };
    self.actions[actor] = null;
    self.actor = actor;
    if (self.integration != null and self.selected_unites[actor] != null and !self.canUniteIntegrated(actor)) self.selected_unites[actor] = null;
    self.picker = menu.Picker.init(.{ self.firstAttackTarget(actor) != null, true, self.canUseRune(actor), firstBattleItem(self, actor) != null, self.canUnite(actor) }, .attack) catch unreachable;
    self.phase = .command;
    self.selection = 0;
}
pub fn queue(self: *State, action: Action) void {
    std.debug.assert(self.actor < self.partyCount() and self.participates(self.actor));
    if (action == .rune_attack and (!self.canPhysicalRune(self.actor) or action.rune_attack >= self.enemyCount() or self.enemy_hp[action.rune_attack] == 0)) return;
    if (action == .attack and !self.canAttackTarget(self.actor, action.attack)) return;
    if (action == .spell and !self.canCast(self.actor, action.spell.index)) return;
    if (action == .item) {
        const item = action.item;
        const inventory = self.progress.party[self.actor].inventory;
        if (item.target >= self.partyCount() or !self.participates(item.target) or !self.canSelectItem(self.actor, item.slot) or inventory.slots[item.slot].?.id != item.id) return;
    }
    if (action == .unite and self.integration != null) {
        const planned = self.unitePlan(self.actor, action.unite) orelse return;
        var boundary = switch (planned) {
            .boundary => |value| value,
            .refusal => return,
        };
        var ctx = UniteContext{ .state = self, .boundary = &boundary, .leader = self.actor, .target_enemy = action.unite };
        boundary.commit(uniteHost(&ctx)) catch return;
        self.unite_boundaries[self.actor] = boundary;
        self.actions[self.actor] = action;
        self.last_targets[self.actor] = @intCast(self.partyCount() + 1 + action.unite);
    } else {
        if (action == .unite and !self.canUnite(self.actor)) return;
        self.actions[self.actor] = action;
        if (action == .unite) {
            const partner = self.unitePartner(self.actor) orelse unreachable;
            self.actions[partner] = .{ .assist = self.actor };
        }
        if (action == .attack) self.last_targets[self.actor] = @intCast(self.partyCount() + 1 + action.attack);
        if (action == .rune_attack) self.last_targets[self.actor] = @intCast(self.partyCount() + 1 + action.rune_attack);
    }
    for (self.actor + 1..self.partyCount()) |index| if (self.participates(index) and (self.actions[index] == null or self.actions[index].? != .assist)) {
        self.choose(index);
        return;
    };
    self.phase = .confirm_round;
    self.yes = true;
}
pub fn previousActor(self: *const State) ?usize {
    var index = self.actor;
    while (index > 0) {
        index -= 1;
        if (self.participates(index) and (self.actions[index] == null or self.actions[index].? != .assist)) return index;
    }
    return null;
}
pub fn canSelectTarget(self: *const State, slot: usize) bool {
    return switch (self.phase) {
        .target => self.canAttackTarget(self.actor, slot),
        .rune_target, .unite_target => slot < self.enemyCount() and self.participates(self.partyCount() + slot),
        .item_target => slot < self.partyCount() and self.participates(slot),
        .spell_target => blk: {
            const spell = self.content.systems.?.spells[self.spell_slot];
            const count = if (spell.allies) self.partyCount() else self.enemyCount();
            const start = if (spell.allies) 0 else self.partyCount();
            break :blk slot < count and self.spellValid(spell, start + slot);
        },
        else => false,
    };
}
pub fn moveTarget(self: *State, party: bool, backwards: bool) void {
    const count: usize = if (party) self.partyCount() else self.enemyCount();
    for (0..count) |_| {
        self.selection = (self.selection + if (backwards) count - 1 else 1) % count;
        if (self.canSelectTarget(self.selection)) return;
    }
}

pub fn tick(self: *State, input: Input) void {
    if (self.integration != null and self.replay_draws == null and !input.restart) {
        var draws = systems.Draws{ .prng = self.random };
        self.tickReplay(input, &draws) catch |err| {
            self.presentation_refusal = @errorName(err);
            return;
        };
        self.random = draws.prng.?;
        return;
    }
    self.tickCore(input);
}

fn beginCommandRound(self: *State) void {
    self.round_start_pending = self.content.round_start != null and self.sourceRounds();
    if (!self.round_start_pending) self.acted = @splat(false);
    self.active = null;
    self.phase = .resolving;
}

pub fn tickCore(self: *State, input: Input) void {
    defer status.advanceIcons(self);
    defer self.advanceEnemyIdle();
    self.unite_vm.beginSoundFrame(self.camera_ticks +% 1);
    for (0..self.partyCount() + self.enemyCount()) |member| if (self.unite_vm.ownsActor(member)) {
        self.unite_vm.previous_points[member] = layout.actorLayout(self.*, member).point;
    };
    for (self.unite_vm.auxiliary, 0..) |maybe, index| if (maybe) |actor| {
        self.unite_vm.previous_points[self.unite_vm.actors.len + index] = layout.auxiliaryPoint(self.*, actor);
    };
    var trail_previous: [6]presentation.ScreenPoint = @splat(.{ .x = 0, .y = 0, .depth = 1 });
    if (self.active != null and self.active.?.kind == .unite) for (0..self.partyCount()) |member| {
        if (self.uniteTrack(member)) |track| if (track.trail != null) {
            trail_previous[member] = layout.actorLayout(self.*, member).point;
        };
    };
    defer self.advanceUniteTrails(trail_previous);
    if (self.phase == .defeat and (self.content.world_art != null or self.hasDepartureFlights())) {
        self.advanceDefeatDeparture();
        return;
    }
    if (self.content.world_art != null) self.presentation_tick +%= 1;
    self.camera_ticks +%= 1;
    retireDepartures(self);
    const advance_unite_tail = self.phase != .resolving;
    defer if (advance_unite_tail) {
        if (self.unite_vm.hasActors()) {
            self.advancePhysicalRunes();
            self.advanceActorCamera();
            self.advanceUniteActors();
        } else self.advanceUniteReactionEvents();
    };
    if (input.restart and (self.phase == .complete or self.phase == .defeat)) {
        self.restart();
        return;
    }
    switch (self.phase) {
        .intro => {
            if (input.confirm) self.enterRoundMenu();
            if (input.cancel) {
                self.phase = .confirm_quit;
                self.yes = false;
            }
        },
        .battle_menu => {
            if (input.up) self.selection = (self.selection + 3) % 4;
            if (input.down) self.selection = (self.selection + 1) % 4;
            if (input.cancel) {
                self.phase = .confirm_quit;
                self.yes = false;
            } else if (input.confirm) switch (self.selection) {
                0 => self.choose(self.firstLiving(true).?),
                1 => {
                    self.released_enemies = self.canLetGo();
                    if (self.released_enemies) {
                        self.phase = .escaped;
                    } else {
                        self.actions = @splat(.defend);
                        if (self.canEscape()) {
                            self.acted = @splat(false);
                            self.phase = .resolving;
                            self.action_ticks = 0;
                            const first = self.firstLiving(true).?;
                            self.active = .{ .actor = first, .target = first, .kind = .escape };
                        } else self.phase = .run_refused;
                    }
                },
                2 => if (self.content.encounters[self.encounter].bribe_cost) |cost| {
                    self.actions = @splat(.defend);
                    if (self.canEscape() and self.progress.money >= cost) {
                        self.progress.money -= cost;
                        self.bribed_enemies = true;
                        self.phase = .escaped;
                    } else self.phase = .bribe_refused;
                },
                3 => if (self.canFreeWill()) {
                    self.chooseFreeWill();
                    beginCommandRound(self);
                },
                else => unreachable,
            };
        },
        .command => switch (self.picker.update(.{ .up = input.up, .down = input.down, .confirm = input.confirm, .cancel = input.cancel })) {
            .none => {},
            .cancelled => {
                if (self.previousActor()) |previous| self.choose(previous) else if (self.content.systems != null) {
                    self.actions = @splat(null);
                    self.enterRoundMenu();
                } else {
                    self.phase = .confirm_quit;
                    self.yes = false;
                }
            },
            .confirmed => |command| switch (command) {
                .attack => {
                    self.selection = self.firstAttackTarget(self.actor).?;
                    self.phase = .target;
                },
                .defend => self.queue(.defend),
                .item => {
                    self.selection = firstBattleItem(self, self.actor) orelse return;
                    self.phase = .item;
                },
                .rune => {
                    if (self.canPhysicalRune(self.actor)) {
                        self.selection = self.firstLiving(false).? - self.partyCount();
                        self.phase = .rune_target;
                        return;
                    }
                    self.selection = 0;
                    for (self.rune(self.actor).?.spells, 0..) |slot, tier| if (slot) |spell| if (self.canSelectSpell(spell)) {
                        self.selection = tier;
                        break;
                    };
                    self.phase = .spell;
                },
                .unite => {
                    self.selection = self.firstLiving(false).? - self.partyCount();
                    self.phase = .unite_target;
                },
            },
        },
        .target, .item_target, .unite_target, .rune_target => {
            const party = self.phase == .item_target;
            if (input.cancel) {
                self.phase = if (party) .item else .command;
                if (party) self.selection = self.item_slot;
                return;
            }
            const unite_choice = self.phase == .unite_target and self.integration != null;
            if (unite_choice and (input.left or input.right)) self.cycleUnite(self.actor, input.left);
            if (input.up or (!unite_choice and input.left)) self.moveTarget(party, true);
            if (input.down or (!unite_choice and input.right)) self.moveTarget(party, false);
            if (input.confirm) {
                if (party) {
                    self.queue(.{ .item = .{ .slot = self.item_slot, .target = self.selection, .id = self.progress.party[self.actor].inventory.slots[self.item_slot].?.id } });
                } else if (self.phase == .unite_target) self.queue(.{ .unite = self.selection }) else if (self.phase == .rune_target) self.queue(.{ .rune_attack = self.selection }) else self.queue(.{ .attack = self.selection });
            }
        },
        .item => {
            if (input.cancel) {
                self.phase = .command;
                return;
            }
            const count = self.progress.party[self.actor].inventory.count();
            const first = firstBattleItem(self, self.actor) orelse {
                self.phase = .command;
                return;
            };
            if (!self.canSelectItem(self.actor, self.selection)) self.selection = first;
            if (input.up != input.down) {
                const step = if (input.up) count - 1 else 1;
                for (0..count) |_| {
                    self.selection = (self.selection + step) % count;
                    if (self.canSelectItem(self.actor, self.selection)) break;
                }
            }
            if (input.confirm) {
                const id = self.progress.party[self.actor].inventory.slots[self.selection].?.id;
                const definition = self.rules.consumable(id) orelse return;
                self.item_slot = self.selection;
                if (definition.partyWide()) {
                    self.queue(.{ .item = .{ .slot = self.item_slot, .target = self.actor, .id = id } });
                } else {
                    self.selection = self.actor;
                    self.phase = .item_target;
                }
            }
        },
        .spell => {
            if (input.cancel) {
                self.phase = .command;
                return;
            }
            const owned = self.rune(self.actor) orelse return;
            if (input.up) self.selection = (self.selection + 3) % 4;
            if (input.down) self.selection = (self.selection + 1) % 4;
            if (input.confirm) {
                self.spell_slot = owned.spells[self.selection] orelse return;
                const spell = self.content.systems.?.spells[self.spell_slot];
                if (!self.canCast(self.actor, self.spell_slot)) return;
                if (spell.group) self.queue(.{ .spell = .{ .index = self.spell_slot, .target = 0 } }) else {
                    self.selection = firstSpellTarget(self, spell) orelse return;
                    self.phase = .spell_target;
                }
            }
        },
        .spell_target => {
            const spell = self.content.systems.?.spells[self.spell_slot];
            const selected = if (self.canSelectTarget(self.selection)) self.selection else firstSpellTarget(self, spell);
            if (input.cancel or selected == null) {
                self.phase = .spell;
                self.selection = self.spellTier(self.actor, self.spell_slot) orelse 0;
                return;
            }
            if (self.selection != selected.?) {
                self.selection = selected.?;
                return;
            }
            const back = input.up or input.left;
            const forward = input.down or input.right;
            if (back != forward) self.moveTarget(spell.allies, back);
            if (input.confirm) self.queue(.{ .spell = .{ .index = self.spell_slot, .target = self.selection } });
        },
        .escaped => {
            if (input.confirm) self.phase = .complete;
        },
        .run_refused, .bribe_refused => if (input.confirm) beginCommandRound(self),
        .confirm_round => {
            if (input.left or input.right or input.up or input.down) self.yes = !self.yes;
            if (input.cancel or (input.confirm and !self.yes)) {
                var last = self.partyCount() - 1;
                while ((!self.participates(last) or (self.actions[last] != null and self.actions[last].? == .assist)) and last > 0) last -= 1;
                self.choose(last);
                return;
            }
            if (input.confirm) beginCommandRound(self);
        },
        .resolving => turn.resolveTick(self),
        .loot => {
            if (input.up or input.left) self.selection = (self.selection + self.partyCount() - 1) % self.partyCount();
            if (input.down or input.right) self.selection = (self.selection + 1) % self.partyCount();
            if (input.cancel) {
                self.phase = .confirm_leave_loot;
                self.yes = false;
            }
            if (input.confirm) {
                const inventory = &self.progress.party[self.selection].inventory;
                if (inventory.count() < 9) {
                    inventory.slots[inventory.count()] = self.dropped_item.?;
                    self.drop_received = true;
                    self.loot_recipient = self.selection;
                    self.phase = .victory;
                } else {
                    self.actor = self.selection;
                    self.selection = 0;
                    self.phase = .loot_replace;
                }
            }
        },
        .loot_replace => {
            if (input.up) self.selection = (self.selection + 8) % 9;
            if (input.down) self.selection = (self.selection + 1) % 9;
            if (input.cancel) {
                self.phase = .loot;
                self.selection = self.actor;
            }
            if (input.confirm and !self.itemEquipped(self.actor, self.selection)) {
                self.item_slot = self.selection;
                self.yes = false;
                self.phase = .confirm_loot_replace;
            }
        },
        .confirm_loot_replace, .confirm_leave_loot => {
            const leaving = self.phase == .confirm_leave_loot;
            if (input.up or input.down or input.left or input.right) self.yes = !self.yes;
            if (input.cancel or (input.confirm and !self.yes)) self.phase = if (leaving) .loot else .loot_replace else if (input.confirm) {
                if (leaving) self.loot_declined = true else {
                    self.progress.party[self.actor].inventory.slots[self.item_slot] = self.dropped_item.?;
                    self.drop_received = true;
                    self.loot_recipient = self.actor;
                }
                self.phase = .victory;
            }
        },
        .victory => if (input.confirm) {
            if (!self.rewardReady()) {
                self.phase = .loot;
                self.selection = 0;
                return;
            }
            if (self.encounter + 1 < self.content.encounters.len) {
                self.encounter += 1;
                self.startEncounter();
            } else self.phase = .complete;
        },
        .complete, .defeat => {
            if (input.cancel) self.quit_requested = true;
            if (input.confirm) self.restart();
        },
        .confirm_quit => {
            if (input.left or input.right or input.up or input.down) self.yes = !self.yes;
            if (input.cancel) self.enterRoundMenu() else if (input.confirm) {
                if (self.yes) self.quit_requested = true else self.enterRoundMenu();
            }
        },
    }
}
