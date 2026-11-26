const std = @import("std");
const damage_rules = @import("battle_damage");
const field = @import("field");
const menu = @import("game");
const battle_systems = @import("battle_systems");
const unite_systems = battle_systems.unite;
const combat_effects = @import("combat_systems").effects;

pub const actor_host = @import("battle_actor_host.zig");
pub const physical = @import("battle_physical.zig");
pub const counter = @import("battle_counter.zig");
pub const enemy_magic = @import("battle_enemy_magic.zig");
pub const commander = @import("battle_commander.zig");
pub const enemy_wave = @import("battle_enemy_wave.zig");
pub const unite_playback = @import("battle_unite_playback.zig");
pub const unite_queue = @import("battle_unite_queue.zig");
pub const unite_trick = @import("battle_unite_trick.zig");
pub const unite_beat = @import("battle_unite_beat.zig");
pub const unite_martial = @import("battle_unite_martial.zig");
pub const actor_program = @import("battle_actor_program.zig");
pub const layout = @import("battle_layout.zig");
pub const drops = @import("battle_drops.zig");
pub const spell_scene = @import("battle_spell_scene.zig");
pub const presentation = @import("battle_presentation.zig");
pub const world_art = @import("battle_world_art.zig");
pub const systems = @import("battle_rules");
const types_mod = @import("battle_types.zig");
const content_mod = @import("battle_content.zig");
pub const Content = content_mod.Content;
pub const battleSchemaVersion = types_mod.battleSchemaVersion;
pub const validateWeapon = content_mod.validateWeapon;
pub const validateProfile = content_mod.validateProfile;
pub const load = content_mod.load;
pub const physicalDamage = damage_rules.physicalDamage;
pub const hits = damage_rules.hits;
pub const hitsWithAccuracyPenalty = damage_rules.hitsWithAccuracyPenalty;
pub const critical = damage_rules.critical;
pub const priority = damage_rules.priority;
pub const Rect = types_mod.Rect;
pub const trial_seed = types_mod.trial_seed;
pub const Member = types_mod.Member;
pub const Stats = types_mod.Stats;
pub const Ailment = types_mod.Ailment;
pub const Pose = types_mod.Pose;
pub const Frame = types_mod.Frame;
pub const ActorLayout = types_mod.ActorLayout;
pub const Position = types_mod.Position;
pub const Scenery = types_mod.Scenery;
pub const Row = types_mod.Row;
pub const WeaponRange = types_mod.WeaponRange;
pub const Drop = types_mod.Drop;
pub const OrdinaryTiming = types_mod.OrdinaryTiming;
pub const DodgeTiming = types_mod.DodgeTiming;
pub const FrontProjectileTiming = types_mod.FrontProjectileTiming;
pub const FrontProjectile = types_mod.FrontProjectile;
pub const ProjectileTiming = types_mod.ProjectileTiming;
pub const CommanderTiming = types_mod.CommanderTiming;
pub const CommanderOrderTiming = types_mod.CommanderOrderTiming;
pub const OrderedAttackTiming = types_mod.OrderedAttackTiming;
pub const UniteTrail = types_mod.UniteTrail;
pub const UniteTrailState = types_mod.UniteTrailState;
pub const ScreenOffset = types_mod.ScreenOffset;
pub const UniteTrack = types_mod.UniteTrack;
pub const UniteScene = types_mod.UniteScene;
pub const Profile = types_mod.Profile;
pub const Encounter = types_mod.Encounter;
pub const OwnedMember = field.game_state.Character;
pub const OwnedMemberRecord = types_mod.OwnedMemberRecord;
pub const equippedStats = battle_stats_mod.equippedStats;
pub const Protection = types_mod.Protection;
pub const PartyAttackTiming = types_mod.PartyAttackTiming;
pub const MedicineAction = types_mod.MedicineAction;
pub const MedicineTiming = types_mod.MedicineTiming;
pub const PartyStrike = types_mod.PartyStrike;
pub const RoundStart = types_mod.RoundStart;
pub const Ground = types_mod.Ground;
pub const Battlefield = types_mod.Battlefield;
pub const UniteGraphicPose = types_mod.UniteGraphicPose;
pub const UniteGraphic = types_mod.UniteGraphic;
pub const Phase = types_mod.Phase;
pub const TemporaryStats = types_mod.TemporaryStats;
pub const Action = types_mod.Action;
pub const Coordinator = types_mod.Coordinator;
pub const OrderedAttack = types_mod.OrderedAttack;
pub const Effect = types_mod.Effect;
pub const Input = types_mod.Input;
pub const IntegrationHost = types_mod.IntegrationHost;
pub const Integration = types_mod.Integration;
pub const Effects = types_mod.Effects;
pub const UniteReturn = types_mod.UniteReturn;
pub const UniteReactionState = types_mod.UniteReactionState;
pub const UniteScenePlayback = types_mod.UniteScenePlayback;
pub const antSpecial = types_mod.antSpecial;

const battle_unite_playback_host_mod = @import("battle_unite_playback_host.zig");
const battle_scene_host_mod = @import("battle_scene_host.zig");
const battle_stats_mod = @import("battle_stats.zig");
const battle_gear_runes_mod = @import("battle_gear_runes.zig");
const battle_turn_tick_mod = @import("battle_turn_tick.zig");
const battle_rewards = @import("battle_rewards.zig");
const battle_status = @import("battle_status.zig");
const battle_turn_dispatch_mod = @import("battle_turn_dispatch.zig");
const presentation_flow = @import("battle_presentation_flow.zig");
const battle_coordinator_mod = @import("battle_coordinator.zig");
const battle_actions_mod = @import("battle_actions.zig");
const battle_unite_host_mod = @import("battle_unite_host.zig");
const battle_spell_rewards_mod = @import("battle_spell_rewards.zig");
const battle_physical_host_mod = @import("battle_physical_host.zig");
const battle_counter_host_mod = @import("battle_counter_host.zig");
const battle_enemy_magic_host_mod = @import("battle_enemy_magic_host.zig");
const battle_commander_host_mod = @import("battle_commander_host.zig");
const battle_enemy_wave_host_mod = @import("battle_enemy_wave_host.zig");
pub const revival = @import("battle_revival.zig");

const ActorTransform = struct {
    node_angles: [3]i16 = @splat(0),
    scale_q12: i32 = 4096,
    world_offset: Position = .{ .x = 0, .y = 0, .z = 0 },
    screen_offset: [2]i8 = .{ 0, 0 },
};

const ActorConditions = struct {
    sleep_turns: u8 = 0,
    accuracy_reduced: bool = false,
    rune_blocked: bool = false,
    stat_modifiers: TemporaryStats = .{},
    protection_rounds: u8 = 0,
};

const PartyKnockout = struct {
    pending: bool = false,
    prior_status: ?field.game_state.Status = null,
    revival: ?revival.Revival = null,
};

pub const State = struct {
    content: Content,
    progress: field.game_state.Progress,
    rules: field.items.Rules,
    random: std.Random.DefaultPrng,
    drops_art: ?drops.Art = null,
    spell_scenes: ?*const spell_scene.Packet = null,
    unite_actors: ?*const actor_host.Bundle = null,
    unite_vm: unite_playback.State = .{},
    physical_numerator: u16 = 10,
    unite_scene: ?UniteScenePlayback = null,
    trick_wave: ?struct { owner: usize, wave: unite_trick.State, updated_at: ?u32 = null } = null,
    martial_queue: ?struct { owner: usize, queue: unite_queue.State, updated_at: ?u32 = null } = null,
    source_camera_hold: ?@import("battle_camera").Block = null,
    source_camera_return: ?struct { from: @import("battle_camera").Block, started: u32 } = null,
    unite_trails: [6]UniteTrailState = @splat(.{}),
    actor_camera: ?@import("battle_camera").ActorController = null,
    replay_draws: ?*systems.Draws = null,
    replay_exhausted: bool = false,
    replay_unsupported: ?enum { enemy_policy, missing_protection, coordinator_action, phero_fallback } = null,
    /// Integration host and its per-action boundary.  A session without
    /// a host keeps the base battle behaviour on every path.
    integration: ?Integration = null,
    /// One pending Unite boundary per party leader.  Two disjoint Unite
    /// groups may be selected in the same round; a participant can only be in
    /// one because `unitePlan` sees the committed command word.
    unite_boundaries: [6]?unite_systems.Boundary = @splat(null),
    unite_returns: [6]?UniteReturn = @splat(null),
    unite_reactions: [12]?UniteReactionState = @splat(null),
    unite_flags: [12]u16 = @splat(0),
    selected_unites: [6]?u8 = @splat(null),
    last_targets: [6]i8 = @splat(-1),
    presentation_tick: u32 = 0,
    camera_ticks: u32 = 0,
    actor_transforms: [12]ActorTransform = @splat(.{}),
    formation_shifts: [6]?struct { from_slot: usize, started_at: u32 } = @splat(null),
    pending_enemy_actor: ?usize = null,
    pending_party_actor: ?usize = null,
    enemy_branch_selection: ?struct { owner: u8, recipient: u8 } = null,
    enemy_magic_pulse: ?struct { issued_at: u32, delta_q12: i32 } = null,
    enemy_magic_damage: [6]?struct { issued_at: u32, amount: u32 } = @splat(null),
    coordinator: ?Coordinator = null,
    // The second half retains target reactions after a Double-Beat owner repeats.
    party_strikes: [12]?PartyStrike = @splat(null),
    front_projectiles: [6]?FrontProjectile = @splat(null),
    medicine_action: ?MedicineAction = null,
    item_impacts: [6]?types_mod.ItemImpact = @splat(null),
    party_knockouts: [6]PartyKnockout = @splat(.{}),
    round_menu_pending: bool = false,
    roc_cover: bool = false,
    roc_attack_from_settled: bool = false,
    hero_reaction_offset: bool = false,
    front_hurt_at: [6]?u32 = @splat(null),
    front_hurt_repeated: [6]bool = @splat(false),
    dodge_idle_at: [6]?u32 = @splat(null),
    roc_idle_at: ?u32 = null,
    roc_home_restored: bool = false,
    round_start_pending: bool = false,
    last_round_actor: usize = 0,
    round_camera_choice: ?u8 = null,
    encounter: usize = 0,
    phase: Phase = .intro,
    actor: usize = 0,
    selection: usize = 0,
    picker: menu.Picker,
    actions: [6]?Action = @splat(null),
    enemy_hp: [6]u16 = .{ 0, 0, 0, 0, 0, 0 },
    acted: [12]bool = @splat(false),
    round: u32 = 1,
    active: ?Effect = null,
    /// The accepted spell/attack composition packet and the one
    /// composer for the current action.  A session without a packet keeps the
    /// base presentation behaviour on every path, and the composer never owns a rule
    /// effect: `resolveTick`'s impact branch stays the single rule owner.
    effects: ?Effects = null,
    presentation: ?combat_effects.Composer = null,
    /// The last typed composition refusal, as an error name.  This is evidence,
    /// not a substitute pose or a synthetic acknowledgement.
    presentation_refusal: []const u8 = "",
    action_ticks: u16 = 0,
    yes: bool = true,
    reward_money: u32 = 0,
    reward_received: u32 = 0,
    loot_recipient: ?usize = null,
    quit_requested: bool = false,
    seed: u64,
    item_slot: usize = 0,
    spell_slot: usize = 0,
    formation: [6]u8 = .{ 0, 1, 2, 3, 4, 5 },
    double_beat_pending: [6]bool = @splat(false),
    spark_pending: bool = false,
    departed: [6]bool = @splat(false),
    departures: [6]?struct { started_at: u32, origin: Position } = @splat(null),
    actor_conditions: [12]ActorConditions = @splat(.{}),
    status_icons: [6]battle_status.IconClock = @splat(.{}),
    unbalanced: [6]u8 = @splat(0),
    escape_allowed: bool = true,
    rewards_committed: bool = false,
    reward_drop: bool = false,
    drop_received: bool = false,
    dropped_item: ?field.items.Stack = null,
    loot_declined: bool = false,
    award_exp: [6]u32 = @splat(0),
    reward_levels: [6]u8 = @splat(1),
    released_enemies: bool = false,
    bribed_enemies: bool = false,

    pub fn init(content: Content, rules: field.items.Rules, members: []Member, seed: u64) !State {
        try content.validate();
        try rules.validate();
        if (members.len != content.initialPartyCount()) return error.InvalidParty;
        var result = State{ .content = content, .progress = .{ .money = 350, .party = members }, .rules = rules, .random = .init(seed), .seed = seed, .picker = try menu.Picker.init(.{ true, true, false, true, false }, .attack) };
        result.restart();
        return result;
    }

    pub fn restart(self: *State) void {
        for (self.progress.party, 0..) |*member, i| {
            const profile = self.content.initialProfile(i);
            member.* = .{
                .id = profile.id,
                .name = profile.name,
                .hp = profile.max_hp,
                .max_hp = profile.max_hp,
                .status = .healthy,
                .rune_charges = @splat(0),
                .max_rune_charges = @splat(0),
                .level = profile.level,
                .weapon_level = if (profile.weapon) |weapon| weapon.initial_level else 1,
                .base_stats = profile.stats,
                .rune = if (self.content.systems) |rules| if (profile.rune) |id| rules.runeIndex(id) else null else null,
            };
            for (0..2) |slot| member.inventory.slots[slot] = .{ .id = .medicine, .uses = self.rules.medicine.uses };
            if (self.content.systems != null) self.refillMagic(i);
        }
        self.formation = .{ 0, 1, 2, 3, 4, 5 };
        self.unbalanced = @splat(0);
        self.escape_allowed = true;
        self.reward_drop = false;
        self.progress.money = 350;
        self.encounter = 0;
        self.random = .init(self.seed);
        self.quit_requested = false;
        self.startEncounter();
        self.phase = .intro;
    }

    pub fn clearSleep(self: *State) void {
        for (&self.actor_conditions) |*conditions| conditions.sleep_turns = 0;
    }

    pub fn partyCount(self: *const State) usize {
        return self.progress.party.len;
    }
    pub fn partyProfile(self: *const State, member: usize) Profile {
        return self.content.partyProfile(self.progress.party[member].id) orelse unreachable;
    }
    pub fn ownedMember(self: *const State, index: usize) OwnedMember {
        return self.progress.party[index];
    }
    pub fn noteItemImpact(self: *State, actor: usize, before: Member) void {
        const member = &self.progress.party[actor];
        const impact: types_mod.ItemImpact = .{
            .issued_at = self.camera_ticks,
            .recovered_hp = member.hp -| before.hp,
            .cured_poison = before.status == .poisoned and member.status == .healthy,
            .removed_balloon = member.balloons < before.balloons,
            .revived = before.hp == 0 and member.hp > 0,
        };
        if (impact.recovered_hp != 0 or impact.cured_poison or impact.removed_balloon) self.item_impacts[actor] = impact;
    }
    pub fn recentItemImpact(self: *const State, actor: usize) ?types_mod.ItemImpact {
        if (actor >= self.partyCount()) return null;
        const impact = self.item_impacts[actor] orelse return null;
        return if (self.camera_ticks -% impact.issued_at < 30) impact else null;
    }
    pub fn setOwnedMember(self: *State, index: usize, owned: OwnedMember) void {
        const profile = self.content.partyProfile(owned.id).?;
        self.progress.party[index] = owned;
        self.progress.party[index].id = profile.id;
        self.progress.party[index].name = profile.name;
    }
    pub fn validateOwnedMember(self: *const State, owned: OwnedMember) !void {
        var members = [_]Member{owned};
        try (field.game_state.Progress{ .money = 0, .party = &members }).validate();
        const member = owned;
        const profile = self.content.partyProfile(member.id) orelse return error.InvalidMember;
        if (member.max_hp > 9999 or (member.hp == 0) != (member.status == .unconscious) or !std.mem.eql(u8, member.name, profile.name) or owned.level == 0 or owned.level > 99 or owned.experience >= 1000) return error.InvalidMember;
        for ([_]u16{ owned.base_stats.attack, owned.base_stats.defense, owned.base_stats.skill, owned.base_stats.speed, owned.base_stats.magic, owned.base_stats.luck }) |value| if (value > 9999) return error.InvalidMember;
        if (owned.weapon_level == 0 or owned.weapon_level > 16) return error.InvalidWeapon;
        const rules = self.content.systems.?;
        for (std.enums.values(systems.EquipmentSlot)) |slot| if (owned.loadout.get(slot)) |id| {
            if (id >= rules.equipment.len or !rules.equipment[id].allows(profile.id, slot)) return error.InvalidEquipment;
            var needed: usize = 0;
            for (std.enums.values(systems.EquipmentSlot)) |other| if (owned.loadout.get(other) == id) {
                needed += 1;
            };
            const gear_id = std.meta.stringToEnum(field.items.Id, rules.equipment[id].id) orelse return error.InvalidEquipment;
            var owned_count: usize = 0;
            for (member.inventory.slots) |item| if (item != null and item.?.id == gear_id) {
                owned_count += 1;
            };
            if (owned_count < needed) return error.InvalidEquipment;
        };
        if (owned.rune) |id| {
            if (id >= rules.runes.len) return error.InvalidRune;
            const definition = rules.runes[id];
            const original = profile.rune != null and std.mem.eql(u8, profile.rune.?, definition.id);
            if (profile.rune_locked and !original) return error.InvalidRune;
            if (!original and !definition.allows(profile.id)) return error.InvalidRune;
        } else if (profile.rune_locked) return error.RuneLocked;
        const capacity = owned.runeCapacity(rules);
        if (!std.mem.eql(u16, &capacity, &member.max_rune_charges)) return error.InvalidMagicCapacity;
    }

    pub const enemyCount = battle_unite_playback_host_mod.enemyCount;
    pub const enemy = battle_unite_playback_host_mod.enemy;
    pub const name = battle_unite_playback_host_mod.name;
    pub const hp = battle_unite_playback_host_mod.hp;
    pub const participates = battle_unite_playback_host_mod.participates;
    pub const isActing = battle_unite_playback_host_mod.isActing;
    pub const activeUniteMember = battle_unite_playback_host_mod.activeUniteMember;
    pub const uniteMemberWaiting = battle_unite_playback_host_mod.uniteMemberWaiting;
    pub const memberImpact = battle_unite_playback_host_mod.memberImpact;
    pub const hasUniteTracks = battle_unite_playback_host_mod.hasUniteTracks;
    pub const uniteTrack = battle_unite_playback_host_mod.uniteTrack;
    pub const uniteTargetReleaseTick = battle_unite_playback_host_mod.uniteTargetReleaseTick;
    pub const advanceActorCamera = battle_unite_playback_host_mod.advanceActorCamera;
    pub fn requestRoundCamera(self: *State, choice: u8, updates: u16) !void {
        const camera = @import("battle_camera");
        if (self.actor_camera == null) self.actor_camera = try camera.ActorController.init(layout.cameraForTransition(self));
        try self.actor_camera.?.requestBlock(camera.round_cameras[choice], updates);
    }

    pub const issueUniteCameraRequests = battle_unite_playback_host_mod.issueUniteCameraRequests;
    pub const uniteHandoffTick = battle_unite_playback_host_mod.uniteHandoffTick;
    pub const uniteReturnFor = battle_unite_playback_host_mod.uniteReturnFor;
    pub const hasUniteReturns = battle_unite_playback_host_mod.hasUniteReturns;
    pub const handoffUnite = battle_unite_playback_host_mod.handoffUnite;
    pub const advanceActiveUniteReturns = battle_unite_playback_host_mod.advanceActiveUniteReturns;
    pub const advanceUniteReturns = battle_unite_playback_host_mod.advanceUniteReturns;
    pub const advanceUniteReturn = battle_unite_playback_host_mod.advanceUniteReturn;
    pub const finishUniteMember = battle_unite_playback_host_mod.finishUniteMember;
    pub const memberDuration = battle_unite_playback_host_mod.memberDuration;
    pub const hasDrops = battle_unite_playback_host_mod.hasDrops;
    pub const dropsFrame = battle_unite_playback_host_mod.dropsFrame;
    pub const hasLiveUniteActors = battle_unite_playback_host_mod.hasLiveUniteActors;
    pub const uniteProgramPose = battle_unite_playback_host_mod.uniteProgramPose;
    pub const uniteVmPose = battle_unite_playback_host_mod.uniteVmPose;
    pub const uniteVmHome = battle_unite_playback_host_mod.uniteVmHome;
    pub const beginUniteActors = battle_unite_playback_host_mod.beginUniteActors;
    pub const prepareUniteImpactEffect = battle_unite_playback_host_mod.prepareUniteImpactEffect;
    pub const advanceUniteActors = battle_unite_playback_host_mod.advanceUniteActors;
    pub const hasSourceEnemyIdle = @import("battle_enemy_idle.zig").hasSourceEnemyIdle;
    pub const stepEnemyIdleActor = @import("battle_enemy_idle.zig").stepEnemyIdleActor;
    pub const advanceEnemyIdle = @import("battle_enemy_idle.zig").advanceEnemyIdle;
    pub const prepareUniteScene = battle_unite_playback_host_mod.prepareUniteScene;
    pub const advanceUniteScene = battle_unite_playback_host_mod.advanceUniteScene;
    pub const stepUniteScene = battle_unite_playback_host_mod.stepUniteScene;
    pub const applyUniteReactionSignals = battle_unite_playback_host_mod.applyUniteReactionSignals;
    pub const advanceUniteReactionEvents = battle_unite_playback_host_mod.advanceUniteReactionEvents;
    pub const issueUniteReactionCamera = battle_unite_playback_host_mod.issueUniteReactionCamera;
    pub const attachUniteActors = battle_scene_host_mod.attachUniteActors;
    pub const attachSpellScenes = battle_scene_host_mod.attachSpellScenes;
    pub const hasSpellScene = battle_scene_host_mod.hasSpellScene;
    pub const hasSourceEffect = battle_scene_host_mod.hasSourceEffect;
    pub const hasStatusIcons = battle_scene_host_mod.hasStatusIcons;
    pub const hasStatusIconsFor = battle_scene_host_mod.hasStatusIconsFor;
    pub const hasUniteScene = battle_scene_host_mod.hasUniteScene;
    pub const hasUniteReactionBinding = battle_scene_host_mod.hasUniteReactionBinding;
    pub const advanceUniteTransition = battle_scene_host_mod.advanceUniteTransition;
    pub const uniteAssistAfterDamage = battle_scene_host_mod.uniteAssistAfterDamage;
    pub const resolveUniteAssistReactions = battle_scene_host_mod.resolveUniteAssistReactions;
    pub const uniteReactionProgram = battle_scene_host_mod.uniteReactionProgram;
    pub const uniteRecipientLocked = battle_scene_host_mod.uniteRecipientLocked;
    pub const uniteReactionPose = battle_scene_host_mod.uniteReactionPose;
    pub const uniteActorPosition = battle_scene_host_mod.uniteActorPosition;
    pub const hasUniteReactionEffects = battle_scene_host_mod.hasUniteReactionEffects;
    pub const spellReaction = battle_scene_host_mod.spellReaction;
    pub const effectEntry = battle_scene_host_mod.effectEntry;
    pub const spellActorPosition = battle_scene_host_mod.spellActorPosition;
    pub const actorSize = battle_scene_host_mod.actorSize;
    pub const hasBackgroundWarp = battle_scene_host_mod.hasBackgroundWarp;
    pub const backgroundCaptureMinimum = battle_scene_host_mod.backgroundCaptureMinimum;
    pub const effectPixels = battle_scene_host_mod.effectPixels;
    pub const spellSceneFrame = battle_scene_host_mod.spellSceneFrame;
    pub const appendUniteImpacts = battle_scene_host_mod.appendUniteImpacts;
    pub const advanceSpellScene = battle_scene_host_mod.advanceSpellScene;
    pub const holdSpellCamera = battle_scene_host_mod.holdSpellCamera;
    pub const issueSpellCameraRequest = battle_scene_host_mod.issueSpellCameraRequest;
    pub const uniteDamageAmount = battle_scene_host_mod.uniteDamageAmount;
    pub const impactTick = battle_stats_mod.impactTick;
    pub const animationTick = battle_stats_mod.animationTick;
    pub const attackFrameTick = battle_stats_mod.attackFrameTick;
    pub const actionDuration = battle_stats_mod.actionDuration;
    pub const canEscape = battle_stats_mod.canEscape;
    pub const canLetGo = battle_stats_mod.canLetGo;
    pub const runSucceeds = battle_stats_mod.runSucceeds;
    pub const enterRoundMenu = battle_stats_mod.enterRoundMenu;
    pub const openAfterRound = battle_stats_mod.openAfterRound;
    pub const stats = battle_stats_mod.stats;
    pub const withTemporaryStats = battle_stats_mod.withTemporaryStats;
    pub const clearTemporaryStats = battle_stats_mod.clearTemporaryStats;
    pub const formationSlot = battle_stats_mod.formationSlot;
    pub const partyRow = battle_stats_mod.partyRow;
    pub const effectTicks = battle_stats_mod.effectTicks;
    pub const partyInactive = battle_stats_mod.partyInactive;
    pub const enemyInactive = battle_stats_mod.enemyInactive;
    pub const partyStrike = battle_stats_mod.partyStrike;
    pub const partyTargetDown = battle_stats_mod.partyTargetDown;
    pub const enemyRow = battle_stats_mod.enemyRow;
    pub const weaponRange = battle_stats_mod.weaponRange;
    pub const canStartAttack = battle_stats_mod.canStartAttack;
    pub const combatOutcome = battle_stats_mod.combatOutcome;
    pub const canAttackTarget = battle_stats_mod.canAttackTarget;
    pub const firstAttackTarget = battle_stats_mod.firstAttackTarget;
    pub const canFreeWill = battle_stats_mod.canFreeWill;
    pub const chooseFreeWill = battle_stats_mod.chooseFreeWill;
    pub const promoteRearMembers = battle_stats_mod.promoteRearMembers;
    pub const swapFormation = battle_stats_mod.swapFormation;
    pub const weaponName = battle_stats_mod.weaponName;
    pub const sharpenPrice = battle_stats_mod.sharpenPrice;
    pub const sharpen = battle_stats_mod.sharpen;
    pub const headEquipment = battle_gear_runes_mod.headEquipment;
    pub const equip = battle_gear_runes_mod.equip;
    pub const equipSlot = battle_gear_runes_mod.equipSlot;
    pub const rune = battle_gear_runes_mod.rune;
    pub const checkRuneAttachment = battle_gear_runes_mod.checkRuneAttachment;
    pub const attachRune = battle_gear_runes_mod.attachRune;
    pub const detachRune = battle_gear_runes_mod.detachRune;
    pub const hasRune = battle_gear_runes_mod.hasRune;
    pub const statusImmune = battle_status.statusImmune;
    pub const requestUniteRecovery = battle_status.requestUniteRecovery;
    pub const requestActorStatus = battle_status.requestActorStatus;
    pub const inflictStatus = battle_status.inflictStatus;
    pub const runeHint = battle_gear_runes_mod.runeHint;
    pub const spellTier = battle_gear_runes_mod.spellTier;
    pub const canCast = battle_gear_runes_mod.canCast;
    pub const physicalRune = battle_gear_runes_mod.physicalRune;
    pub const canPhysicalRune = battle_gear_runes_mod.canPhysicalRune;
    pub const canUseRune = battle_gear_runes_mod.canUseRune;
    pub const hasMagic = battle_gear_runes_mod.hasMagic;
    pub const refillMagic = battle_gear_runes_mod.refillMagic;
    pub const uniteDefinition = battle_gear_runes_mod.uniteDefinition;
    pub const uniteName = battle_gear_runes_mod.uniteName;
    pub const unitePartner = battle_gear_runes_mod.unitePartner;
    pub const actionMotion = battle_gear_runes_mod.actionMotion;
    pub const attackFrames = battle_gear_runes_mod.attackFrames;
    pub const canUnite = battle_gear_runes_mod.canUnite;
    pub const roll = battle_gear_runes_mod.roll;
    pub const tickReplay = battle_gear_runes_mod.tickReplay;
    pub const uniteScreenOffset = battle_gear_runes_mod.uniteScreenOffset;
    pub const advanceUniteTrails = battle_gear_runes_mod.advanceUniteTrails;
    pub const enemySourceSlot = battle_gear_runes_mod.enemySourceSlot;
    pub const firstLiving = battle_gear_runes_mod.firstLiving;
    pub const startEncounter = battle_turn_tick_mod.startEncounter;
    pub const choose = battle_turn_tick_mod.choose;
    pub const canSelectItem = battle_turn_tick_mod.canSelectItem;
    pub const canSelectSpell = battle_turn_tick_mod.canSelectSpell;
    pub const queue = battle_turn_tick_mod.queue;
    pub const previousActor = battle_turn_tick_mod.previousActor;
    pub const moveTarget = battle_turn_tick_mod.moveTarget;
    pub const canSelectTarget = battle_turn_tick_mod.canSelectTarget;
    pub const targetSelection = battle_turn_tick_mod.targetSelection;
    pub const selectedTargetActor = battle_turn_tick_mod.selectedTargetActor;
    pub const tick = battle_turn_tick_mod.tick;
    pub const tickCore = battle_turn_tick_mod.tickCore;
    pub const sharedPartyMelee = battle_turn_dispatch_mod.sharedPartyMelee;
    pub const sourceRounds = battle_turn_dispatch_mod.sourceRounds;
    pub const beginDeparture = battle_turn_dispatch_mod.beginDeparture;
    pub const advanceDefeatDeparture = battle_turn_tick_mod.advanceDefeatDeparture;
    pub const hasDepartureFlights = battle_turn_tick_mod.hasDepartureFlights;
    pub const advanceStatusIcons = battle_status.advanceIcons;
    pub const applyRoundBoundaryStatuses = battle_status.applyRoundBoundaryStatuses;
    pub const attachEffects = presentation_flow.attachEffects;
    pub const advancePresentation = presentation_flow.advancePresentation;
    pub const effectFrame = presentation_flow.effectFrame;
    pub const beginSpellAction = battle_turn_dispatch_mod.beginSpellAction;
    pub const beginUniteAction = battle_turn_dispatch_mod.beginUniteAction;
    pub const startUniteAction = battle_turn_dispatch_mod.startUniteAction;
    pub const beginRuneAttack = battle_turn_dispatch_mod.beginRuneAttack;
    pub const sourcePhysicalRuneOwner = battle_physical_host_mod.sourcePhysicalRuneOwner;
    pub const beginSourcePhysicalRune = battle_physical_host_mod.beginSourcePhysicalRune;
    pub const preparePhysicalRune = battle_physical_host_mod.preparePhysicalRune;
    pub const advancePhysicalRunes = battle_physical_host_mod.advancePhysicalRunes;
    pub const finishPhysicalRuneController = battle_physical_host_mod.finishPhysicalRuneController;
    pub const applyPhysicalRuneContact = battle_physical_host_mod.applyPhysicalRuneContact;
    pub const finishPhysicalRuneActors = battle_physical_host_mod.finishPhysicalRuneActors;
    pub const physicalRunePose = battle_physical_host_mod.physicalRunePose;
    pub const physicalRuneReaction = battle_physical_host_mod.physicalRuneReaction;
    pub const counterAvailable = battle_counter_host_mod.counterAvailable;
    pub const beginCounter = battle_counter_host_mod.beginCounter;
    pub const beginCover = battle_counter_host_mod.beginCover;
    pub const advanceCoverActor = battle_counter_host_mod.advanceCoverActor;
    pub const beginStrongArmCooperation = battle_counter_host_mod.beginStrongArmCooperation;
    pub const advanceStrongArmActor = battle_counter_host_mod.advanceStrongArmActor;
    pub const releaseProjectileTurn = battle_counter_host_mod.releaseProjectileTurn;
    pub const parryAvailable = battle_counter_host_mod.parryAvailable;
    pub const beginParry = battle_counter_host_mod.beginParry;
    pub const beginMelee = battle_counter_host_mod.beginMelee;
    pub const hasSourceRabbit = battle_counter_host_mod.hasSourceRabbit;
    pub const beginRabbitProjectile = battle_counter_host_mod.beginRabbitProjectile;
    pub const beginPartyMelee = battle_counter_host_mod.beginPartyMelee;
    pub const startMeleeStrike = battle_coordinator_mod.startMeleeStrike;
    pub const beginRanged = battle_counter_host_mod.beginRanged;
    pub const repeatCounter = battle_counter_host_mod.repeatCounter;
    pub const prepareCounter = battle_counter_host_mod.prepareCounter;
    pub const applyCounterContact = battle_counter_host_mod.applyCounterContact;
    pub const finishCounterController = battle_counter_host_mod.finishCounterController;
    pub const finishCounterActors = battle_counter_host_mod.finishCounterActors;
    pub const holdRegionalDispatch = battle_counter_host_mod.holdRegionalDispatch;
    pub const dispatchPartyTailReturn = battle_counter_host_mod.dispatchPartyTailReturn;
    pub const syncRegionalActorVisuals = battle_counter_host_mod.syncRegionalActorVisuals;
    pub const beginEnemyMagic = battle_enemy_magic_host_mod.beginEnemyMagic;
    pub const prepareEnemyMagic = battle_enemy_magic_host_mod.prepareEnemyMagic;
    pub const beginEnemyMagicEffect = battle_enemy_magic_host_mod.beginEnemyMagicEffect;
    pub const advanceEnemyMagicActor = battle_enemy_magic_host_mod.advanceEnemyMagicActor;
    pub const finishEnemyMagicActors = battle_enemy_magic_host_mod.finishEnemyMagicActors;
    pub const hasSourceCommander = battle_commander_host_mod.hasSourceCommander;
    pub const beginSourceCommander = battle_commander_host_mod.beginSourceCommander;
    pub const advanceCommander = battle_commander_host_mod.advanceCommander;
    pub const finishCommanderActors = battle_commander_host_mod.finishCommanderActors;
    pub const hasSourceEnemyWave = battle_enemy_wave_host_mod.hasSourceEnemyWave;
    pub const beginSourceEnemyWave = battle_enemy_wave_host_mod.beginSourceEnemyWave;
    pub const advanceEnemyWave = battle_enemy_wave_host_mod.advanceEnemyWave;
    pub const finishEnemyWaveActors = battle_enemy_wave_host_mod.finishEnemyWaveActors;
    pub const scanSourceEnemyTarget = battle_actions_mod.scanSourceEnemyTarget;
    pub const nextAction = battle_turn_dispatch_mod.nextAction;
    pub const commanderDecision = battle_turn_dispatch_mod.commanderDecision;
    pub const coordinatorLocked = battle_coordinator_mod.coordinatorLocked;
    pub const coordinatorActed = battle_coordinator_mod.coordinatorActed;
    pub const primaryEffectBusy = battle_coordinator_mod.primaryEffectBusy;
    pub const coordinatorChoice = battle_coordinator_mod.coordinatorChoice;
    pub const retireDefeatedEnemyTurn = battle_coordinator_mod.retireDefeatedEnemyTurn;
    pub const advanceCoordinator = battle_coordinator_mod.advanceCoordinator;
    pub const beginMedicine = battle_coordinator_mod.beginMedicine;
    pub const advanceMedicine = battle_coordinator_mod.advanceMedicine;
    pub const partyAttackTiming = battle_coordinator_mod.partyAttackTiming;
    pub const resolvePhysicalDamage = battle_stats_mod.resolvePhysicalDamage;
    pub const startRangedStrike = battle_coordinator_mod.startRangedStrike;
    pub const advancePartyStrike = battle_coordinator_mod.advancePartyStrike;
    pub const markPartyKnockout = revival.markPartyKnockout;
    pub const commitPartyKnockout = revival.commitPartyKnockout;
    pub const hasPendingRevival = revival.hasPendingRevival;
    pub const advanceRevivals = revival.advanceRevivals;
    pub const revivalAge = revival.revivalAge;
    pub const revivalAllowsWard = revival.revivalAllowsWard;
    pub const resolveCommanderOrder = battle_actions_mod.resolveCommanderOrder;
    pub const protectorReleaseTick = battle_actions_mod.protectorReleaseTick;
    pub const wardReturnTick = battle_actions_mod.wardReturnTick;
    pub const coverDuration = battle_actions_mod.coverDuration;
    pub const protector = battle_actions_mod.protector;
    pub const integratedProtector = battle_actions_mod.integratedProtector;
    pub const integrationHost = battle_actions_mod.integrationHost;
    pub const protectionFailure = battle_actions_mod.protectionFailure;
    pub const frontProjectileDecision = battle_actions_mod.frontProjectileDecision;
    pub const sourceEnemyDecision = battle_actions_mod.sourceEnemyDecision;
    pub const hasSourceAnt = battle_actions_mod.hasSourceAnt;
    pub const sourceEnemyAttack = battle_actions_mod.sourceEnemyAttack;
    pub const beginEnemySpecial = battle_counter_host_mod.beginEnemySpecial;
    pub const advanceFrontProjectiles = battle_actions_mod.advanceFrontProjectiles;
    pub const rocDecision = battle_actions_mod.rocDecision;
    pub const rabbitDecision = battle_actions_mod.rabbitDecision;
    pub const nextDoubleBeatTarget = battle_actions_mod.nextDoubleBeatTarget;
    pub const followupTarget = battle_actions_mod.followupTarget;
    pub const usesProfileAttack = battle_actions_mod.usesProfileAttack;
    pub const beginAttack = battle_actions_mod.beginAttack;
    pub const recoverSleep = battle_status.recoverSleep;
    pub const chooseEnemyTarget = battle_actions_mod.chooseEnemyTarget;
    pub const applyFieldStatuses = battle_actions_mod.applyFieldStatuses;
    pub const castFieldSpell = battle_actions_mod.castFieldSpell;
    pub const gearIndex = battle_actions_mod.gearIndex;
    pub const depositToStorage = battle_actions_mod.depositToStorage;
    pub const gearCount = battle_actions_mod.gearCount;
    pub const itemEquipped = battle_actions_mod.itemEquipped;
    pub const equipOwned = battle_actions_mod.equipOwned;
    pub const equipSlotOwned = battle_actions_mod.equipSlotOwned;
    pub const checkEquipment = battle_actions_mod.checkEquipment;
    pub const characterId = battle_unite_host_mod.characterId;
    pub const runeByteFor = battle_unite_host_mod.runeByteFor;
    pub const uniteReactionOriginQ12 = battle_unite_host_mod.uniteReactionOriginQ12;
    pub const startUniteReaction = battle_unite_host_mod.startUniteReaction;
    pub const uniteView = battle_unite_host_mod.uniteView;
    pub const unitePlan = battle_unite_host_mod.unitePlan;
    pub const selectUnite = battle_unite_host_mod.selectUnite;
    pub const cycleUnite = battle_unite_host_mod.cycleUnite;
    pub const canUniteIntegrated = battle_unite_host_mod.canUniteIntegrated;
    pub const uniteBoundaryFor = battle_unite_host_mod.uniteBoundaryFor;
    pub const activeUniteBoundary = battle_unite_host_mod.activeUniteBoundary;
    pub const clearUniteFlags = battle_unite_host_mod.clearUniteFlags;
    pub const releaseUniteFor = battle_unite_host_mod.releaseUniteFor;
    pub const discardUnite = battle_unite_host_mod.discardUnite;
    pub const hasUniteSequence = battle_unite_host_mod.hasUniteSequence;
    pub const resolveUniteImpact = battle_unite_host_mod.resolveUniteImpact;
    pub const beginTrickWave = battle_unite_host_mod.beginTrickWave;
    pub const beginMartialQueue = battle_unite_host_mod.beginMartialQueue;
    pub const finishUnite = battle_unite_host_mod.finishUnite;
    pub const enemyAffinity = battle_spell_rewards_mod.enemyAffinity;
    pub const spellValid = battle_spell_rewards_mod.spellValid;
    pub const spellRuleIndex = battle_spell_rewards_mod.spellRuleIndex;
    pub const runeSpells = battle_spell_rewards_mod.runeSpells;
    pub const spellTarget = battle_spell_rewards_mod.spellTarget;
    pub const spellStatus = battle_spell_rewards_mod.spellStatus;
    pub const applySpellBridge = battle_spell_rewards_mod.applySpellBridge;
    pub const applySpell = battle_spell_rewards_mod.applySpell;
    pub const rewardReady = battle_rewards.rewardReady;
    pub const commitRewards = battle_rewards.commitRewards;
    pub const experienceAward = battle_rewards.experienceAward;
    pub const applyExperience = battle_spell_rewards_mod.applyExperience;
    pub const sceneExperience = battle_spell_rewards_mod.sceneExperience;
    pub const levelUp = battle_spell_rewards_mod.levelUp;
};
