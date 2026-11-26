const std = @import("std");
const battle = @import("battle");
const field = @import("field");

pub const titles = [_][]const u8{ "Six-member combat", "Formation", "Inventory", "Equipment", "Single-target Rune", "Group Rune", "Healing and revival", "Status effects", "Talisman Unite", "Rewards and leveling", "Escape and defeat", "Extended run / resume" };
pub const hints = [_][]const u8{
    "Six identities, six commands. Try Gremio > BonBon 3.",
    "Short weapons need the front row. Swap Viktor and Hero.",
    "Transfer a used bundle. Tai Ho's bag starts full.",
    "Compare DEF with Bandanna, Headband and no headgear.",
    "Hero: Fire Rune / MGC 65. Flaming Arrows > BonBon 3.",
    "Hero: Fire Rune / MGC 65. Firestorm hits every enemy.",
    "Hero: Water. Gremio: Flowing. Camille: Wind. Q: heal/revive/cure.",
    "Hero: Wind Rune / MGC 115. Q: sleep, then cure poison.",
    "Gremio + Pahn reserve one joint attack and one target.",
    "Win with Hero at 950 EXP. Check level and Medicine drop.",
    "Run / Let go: battle menu. T: weaker foes. L: lock. K: defeat.",
    "Nine fights. P saves; L resumes at a fresh command phase.",
};
pub const Screen = enum { hub, prepare, fight, result };
pub const Session = struct {
    battle: battle.State,
    screen: Screen = .hub,
    demo: usize = 0,
    selection: usize = 0,
    recipient: usize = 1,
    slot: usize = 0,
    discard_pending: bool = false,
    completed: [12]bool = @splat(false),
    message: []const u8 = "",

    pub fn init(content: battle.Content, rules: field.items.Rules, members: []battle.Member) !Session {
        try content.validate();
        if (content.systems == null or content.party.len != 6 or content.encounters.len != 9) return error.InvalidDemoContent;
        const expected_party = [_][]const u8{ "hero", "gremio", "pahn", "viktor", "camille", "tai_ho" };
        for (content.party, expected_party) |profile, id| if (!std.mem.eql(u8, profile.id, id) or profile.max_hp < 20) return error.InvalidDemoContent;
        const expected_spells = [_][]const u8{ "spell_1", "spell_2", "spell_9", "spell_11", "spell_30", "spell_15", "spell_13" };
        const system = content.systems.?;
        if (system.spells.len != expected_spells.len or system.equipment.len != 2) return error.InvalidDemoContent;
        for (system.spells, expected_spells, 0..) |spell, id, i| {
            const valid_kind = switch (spell.kind) {
                .skill_bonus_scale, .defense_bonus_scale, .protection, .source_rule => false,
                .damage => i <= 1,
                .heal => i == 2 or i == 3,
                .revive => i == 4,
                .cure => i == 5,
                .sleep => i == 6,
            };
            if (!std.mem.eql(u8, spell.id, id) or !valid_kind or spell.group != (i == 1 or i == 3 or i == 6)) return error.InvalidDemoContent;
        }
        if (!std.mem.eql(u8, system.unite.members[0], "pahn") or !std.mem.eql(u8, system.unite.members[1], "gremio")) return error.InvalidDemoContent;
        for (content.encounters, 0..) |encounter, i| {
            const count: usize = if (i % 3 == 1) 3 else 1;
            if (encounter.enemies.len != count) return error.InvalidDemoContent;
            for (encounter.enemies) |id| if (!std.mem.eql(u8, id, if (i % 3 == 2) "wild_boar" else "bonbon")) return error.InvalidDemoContent;
        }
        return .{ .battle = try battle.State.init(content, rules, members, battle.trial_seed) };
    }
    pub fn start(self: *Session, demo: usize) void {
        std.debug.assert(demo < titles.len);
        self.demo = demo;
        self.selection = 0;
        self.recipient = 1;
        self.slot = 0;
        self.message = "";
        self.discard_pending = false;
        self.battle.restart();
        self.battle.encounter = if (demo == 11) 0 else if (demo == 10) 2 else 1;
        self.battle.startEncounter();
        self.screen = if (demo >= 1 and demo <= 3) .prepare else .fight;
        if (demo == 2) {
            self.battle.progress.party.at(0).inventory.slots[0].?.uses = 2;
            self.battle.progress.party.at(5).inventory.slots = @splat(.{ .id = .medicine, .uses = 6 });
        }
        if (demo == 6 or demo == 7) {
            self.battle.progress.party.at(0).hp = 20;
            self.battle.progress.party.at(1).status = .poisoned;
        }
        if (demo == 6) {
            self.battle.progress.party.at(2).hp = 0;
            self.battle.progress.party.at(2).status = .unconscious;
        }
        if (demo == 9) {
            self.battle.progress.party.at(0).experience = 950;
            self.battle.reward_drop = true;
        }
        if (demo == 4 or demo == 5) self.setDemoRune(0, "fire", 65);
        if (demo == 6) {
            self.setDemoRune(0, "water", 85);
            self.setDemoRune(1, "flowing", 160);
            self.setDemoRune(4, "wind", 115);
        }
        if (demo == 7) self.setDemoRune(0, "wind", 115);
        self.battle.enterRoundMenu();
    }
    fn setDemoRune(self: *Session, member: usize, id: []const u8, magic: u16) void {
        self.battle.progress.party.at(member).rune = self.battle.content.systems.?.runeIndex(id).?;
        self.battle.progress.party.at(member).base_stats.magic = magic;
        self.battle.refillMagic(member);
    }
    pub fn next(self: *Session) void {
        if (self.demo == titles.len - 1) {
            self.screen = .hub;
            self.selection = 0;
        } else self.start(self.demo + 1);
    }
    pub fn transfer(self: *Session) void {
        self.battle.progress.transfer(self.selection, self.slot, self.recipient) catch |err| {
            self.message = if (err == error.InventoryFull) "Recipient bag is full. Nothing transferred." else "Choose a bundle and a different recipient.";
            return;
        };
        self.message = "Transferred bundle; remaining uses preserved.";
        self.slot = 0;
    }
    pub fn discard(self: *Session, confirm: bool) void {
        if (!self.discard_pending) {
            self.discard_pending = true;
            return;
        }
        self.discard_pending = false;
        if (!confirm) return;
        self.battle.progress.discard(self.selection, self.slot) catch |err| {
            self.message = @errorName(err);
            return;
        };
        self.slot = 0;
        self.message = "Discarded one bundle.";
    }
    pub fn cycleEquipment(self: *Session, backwards: bool) void {
        const count = self.battle.content.systems.?.equipment.len + 1;
        const current = if (self.battle.progress.party.at(self.selection).loadout.head) |item| item + 1 else 0;
        const next_item = (current + if (backwards) count - 1 else 1) % count;
        self.battle.equip(self.selection, if (next_item == 0) null else next_item - 1) catch unreachable;
    }
    pub fn defeatSetup(self: *Session) void {
        for (self.battle.progress.party.items(), 0..) |member, i| {
            member.hp = if (i == 0) 1 else 0;
            member.status = if (i == 0) .healthy else .unconscious;
        }
        self.battle.startEncounter();
        self.message = "Hero has 1 HP. Defend, or Q for the suggested round.";
    }
    pub fn suggested(self: *Session) void {
        const state = &self.battle;
        if (self.screen != .fight or (state.phase != .command and state.phase != .battle_menu)) return;
        state.actions = @splat(null);
        // shortcut: guided rounds are an optional test aid; manual battle commands use the same resolver.
        for (0..state.partyCount()) |i| {
            if (state.hp(i) == 0 or state.actions[i] != null) continue;
            state.actor = i;
            var action: battle.Action = .defend;
            switch (self.demo) {
                4 => if (i == 0 and state.round == 1) {
                    action = .{ .spell = .{ .index = 0, .target = 2 } };
                },
                5 => if (i == 0 and state.round == 1) {
                    action = .{ .spell = .{ .index = 1, .target = 0 } };
                },
                6 => {
                    if (state.round == 1) {
                        if (i == 0) action = .{ .spell = .{ .index = 2, .target = 0 } };
                        if (i == 1) action = .{ .spell = .{ .index = 4, .target = 2 } };
                        if (i == 4) action = .{ .spell = .{ .index = 5, .target = 1 } };
                    }
                },
                7 => {
                    if (state.round == 1 and i == 0) action = .{ .spell = .{ .index = 6, .target = 0 } };
                    if (state.round == 2 and i == 0) action = .{ .spell = .{ .index = 5, .target = 1 } };
                },
                8 => if (i == 1 and state.round == 1 and state.canUnite(i)) {
                    action = .{ .unite = 2 };
                },
                10 => {},
                else => {
                    action = .{ .attack = i % state.enemyCount() };
                },
            }
            if (self.demo >= 4 and self.demo <= 8 and state.round > (if (self.demo == 7) @as(u32, 3) else 1)) action = .{ .attack = i % state.enemyCount() };
            if (action == .attack and !state.canAttackTarget(i, action.attack)) {
                action = if (state.firstAttackTarget(i)) |target| .{ .attack = target } else .defend;
            }
            if (action == .spell and !state.canCast(i, action.spell.index)) action = .defend;
            if (state.hp(i) < state.progress.party.at(i).max_hp / 2 and self.demo != 10 and state.progress.party.at(i).inventory.count() > 0 and action == .attack) action = .{ .item = .{ .slot = 0, .target = i } };
            state.actions[i] = action;
            if (action == .unite) state.actions[state.unitePartner(i).?] = .{ .assist = i };
        }
        state.phase = .confirm_round;
        state.yes = true;
    }
    pub fn tick(self: *Session, input: battle.Input) void {
        if (self.screen != .fight) return;
        if (self.battle.phase == .victory and input.confirm and self.battle.rewardReady()) {
            if (self.demo == 11 and self.battle.encounter + 1 < self.battle.content.encounters.len) {
                self.battle.encounter += 1;
                self.battle.startEncounter();
            } else {
                self.completed[self.demo] = true;
                self.screen = .result;
            }
            return;
        }
        if (self.battle.phase == .escaped and input.confirm) {
            self.completed[self.demo] = true;
            self.screen = .result;
            return;
        }
        if (self.battle.phase == .defeat and (input.confirm or input.restart)) {
            self.start(self.demo);
            return;
        }
        self.battle.tick(input);
        if (self.battle.quit_requested) {
            self.screen = .hub;
            self.selection = self.demo;
        }
    }
};

pub const Snapshot = struct {
    schema: []const u8,
    encounter: usize,
    round: u32,
    money: u32,
    party: [6]field.game_state.CharacterRecord,
    levels: [6]u8,
    stats: [6]battle.Stats,
    experience: [6]u32,
    formation: [6]u8,
    equipment: [6]?usize,
    runes: [6]?usize,
    asleep: [12]u8,
    enemy_hp: [6]u16,
    random: std.Random.DefaultPrng,

    pub fn capture(session: Session) !Snapshot {
        if (!canSave(session)) return error.SaveAtRoundStart;
        var asleep: [12]u8 = undefined;
        for (&asleep, session.battle.actor_conditions) |*turns, conditions| turns.* = conditions.sleep_turns;
        var result: Snapshot = .{ .schema = "suikoden-demo-save/2", .encounter = session.battle.encounter, .round = session.battle.round, .money = session.battle.progress.money, .party = undefined, .levels = undefined, .stats = undefined, .experience = undefined, .formation = session.battle.formationOrder(), .equipment = session.battle.headEquipment(), .runes = undefined, .asleep = asleep, .enemy_hp = session.battle.enemy_hp, .random = session.battle.random };
        for (session.battle.progress.party.items(), 0..) |member, i| {
            result.party[i] = member.record();
            result.levels[i] = member.level;
            result.stats[i] = member.base_stats;
            result.experience[i] = member.experience;
            result.runes[i] = member.rune;
        }
        return result;
    }
    pub fn restore(self: Snapshot, session: *Session) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-demo-save/2") or self.encounter >= session.battle.content.encounters.len or self.round == 0 or self.round > 1000000) return error.InvalidDemoSave;
        var party: [6]battle.Member = undefined;
        for (&party, self.party) |*member, record| member.* = record.character();
        var progress = field.game_state.Progress{ .money = self.money, .party = .init(&party) };
        try progress.validate();
        var seen: [6]bool = @splat(false);
        for (0..6) |i| {
            const member = party[i];
            const profile = session.battle.content.partyProfile(member.id) orelse return error.InvalidDemoSave;
            if (!std.mem.eql(u8, member.id, profile.id) or !std.mem.eql(u8, member.name, profile.name) or member.max_hp > 9999 or (member.hp == 0) != (member.status == .unconscious) or self.levels[i] < 1 or self.levels[i] > 99 or self.experience[i] >= 1000 or self.formation[i] >= 6 or seen[self.formation[i]]) return error.InvalidDemoSave;
            seen[self.formation[i]] = true;
            if (self.equipment[i]) |item| if (item >= session.battle.content.systems.?.equipment.len) return error.InvalidDemoSave;
            if (self.runes[i]) |rune| if (rune >= session.battle.content.systems.?.runes.len) return error.InvalidDemoSave;
            for ([_]u16{ self.stats[i].attack, self.stats[i].skill, self.stats[i].defense, self.stats[i].speed, self.stats[i].magic, self.stats[i].luck }) |value| if (value > 9999) return error.InvalidDemoSave;
            const capacity = session.battle.content.systems.?.magicCapacity(self.stats[i].magic);
            if (!std.mem.eql(u16, &member.max_rune_charges, &capacity)) return error.InvalidDemoSave;
            party[i].id = profile.id;
            party[i].name = profile.name;
        }
        var living_enemies = false;
        const encounter = session.battle.content.encounters[self.encounter];
        for (self.enemy_hp, 0..) |hp, i| {
            const max_hp = if (i < encounter.enemies.len) session.battle.content.enemies[session.battle.content.enemyIndex(encounter.enemies[i]).?].max_hp else 0;
            if (hp > max_hp) return error.InvalidDemoSave;
            if (hp > 0) living_enemies = true;
        }
        var living_party = false;
        for (party) |member| {
            if (member.hp > 0) living_party = true;
        }
        if (!living_enemies or !living_party) return error.InvalidDemoSave;
        for (self.asleep) |turns| if (turns > 10) return error.InvalidDemoSave;
        session.start(11);
        session.battle.encounter = self.encounter;
        session.battle.progress.money = self.money;
        for (session.battle.progress.party.items(), party) |member, record| {
            const weapon_level = member.weapon_level;
            member.* = record;
            member.weapon_level = weapon_level;
        }
        session.battle.startEncounter();
        const loadouts = battle.systems.legacyLoadouts(self.equipment);
        for (session.battle.progress.party.items(), 0..) |member, i| {
            member.level = self.levels[i];
            member.base_stats = self.stats[i];
            member.experience = self.experience[i];
            member.loadout = loadouts[i];
            member.rune = self.runes[i];
        }
        session.battle.setFormation(self.formation);
        for (&session.battle.actor_conditions, self.asleep) |*conditions, turns| conditions.sleep_turns = turns;
        session.battle.enemy_hp = self.enemy_hp;
        session.battle.random = self.random;
        session.battle.round = self.round;
        session.battle.enterRoundMenu();
    }
};
pub fn canSave(session: Session) bool {
    if (session.demo != 11 or session.screen != .fight or (session.battle.phase != .command and session.battle.phase != .battle_menu)) return false;
    for (session.battle.actions) |action| if (action != null) return false;
    return true;
}
pub fn save(io: std.Io, allocator: std.mem.Allocator, directory: std.Io.Dir, session: Session) !void {
    const snapshot = try Snapshot.capture(session);
    const bytes = try std.json.Stringify.valueAlloc(allocator, snapshot, .{});
    defer allocator.free(bytes);
    var atomic = try directory.createFileAtomic(io, "demo-slot.json", .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}
pub fn load(io: std.Io, allocator: std.mem.Allocator, directory: std.Io.Dir, session: *Session) !void {
    const bytes = try directory.readFileAlloc(io, "demo-slot.json", allocator, .limited(65536));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Snapshot, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try parsed.value.restore(session);
}
