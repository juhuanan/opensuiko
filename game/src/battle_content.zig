const std = @import("std");
const validation = @import("validation");
const field = @import("field");
const presentation = @import("battle_presentation.zig");
const world_art = @import("battle_world_art.zig");
const systems = @import("battle_rules");
const types_mod = @import("battle_types.zig");
const Rect = types_mod.Rect;
const Pose = types_mod.Pose;
const Frame = types_mod.Frame;
const Position = types_mod.Position;
const Scenery = types_mod.Scenery;
const Profile = types_mod.Profile;
const Encounter = types_mod.Encounter;
const Protection = types_mod.Protection;
const PartyAttackTiming = types_mod.PartyAttackTiming;
const MedicineTiming = types_mod.MedicineTiming;
const RoundStart = types_mod.RoundStart;
const Ground = types_mod.Ground;
const Battlefield = types_mod.Battlefield;
const UniteGraphic = types_mod.UniteGraphic;
const battleSchemaVersion = types_mod.battleSchemaVersion;

pub const Content = struct {
    pub const max_file_size = 4 * 1024 * 1024;

    unite_graphics: []const UniteGraphic = &.{},
    world_art: ?world_art.Data = null,
    round_start: ?RoundStart = null,
    medicine_timings: []const MedicineTiming = &.{},
    party_attacks: []const PartyAttackTiming = &.{},
    protection: ?Protection = null,
    presentation_ready: bool = true,
    schema: []const u8,
    atlas: []const u8,
    background: []const u8,
    party: []const Profile,
    initial_party: ?[]const []const u8 = null,
    enemies: []const Profile,
    encounters: []const Encounter,
    party_positions: []const Position,
    formation_slots: [6]Position,
    camera: presentation.Camera,
    sprite_scale: f32,
    scenery: []const Scenery,
    ground: ?Ground = null,
    battlefields: []const Battlefield = &.{},
    systems: ?systems.Systems = null,

    pub fn jsonStringify(self: Content, writer: anytype) !void {
        try writer.beginObject();
        inline for (@typeInfo(Content).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "unite_graphics") or std.mem.eql(u8, name, "battlefields")) {
                if (@field(self, name).len != 0) {
                    try writer.objectField(name);
                    try writer.write(@field(self, name));
                }
            } else {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
    pub fn uniteGraphicPose(self: Content, id: []const u8, pose: u16, record: ?u8) ?*const types_mod.UniteGraphicPose {
        if (record) |selected| for (self.unite_graphics) |graphic| {
            if (graphic.record != selected or !std.mem.eql(u8, graphic.id, id)) continue;
            for (graphic.poses) |*entry| if (entry.id == pose) return entry;
        };
        for (self.unite_graphics) |graphic| {
            if (graphic.record != null or !std.mem.eql(u8, graphic.id, id)) continue;
            for (graphic.poses) |*entry| if (entry.id == pose) return entry;
        }
        return null;
    }
    pub fn uniteGraphic(self: Content, id: []const u8, pose: u16) ?Pose {
        return (self.uniteGraphicPose(id, pose, null) orelse return null).sprite;
    }
    pub fn uniteWhiteGraphic(self: Content, id: []const u8, pose: u16) ?Pose {
        return (self.uniteGraphicPose(id, pose, null) orelse return null).white;
    }
    pub fn uniteFlashGraphic(self: Content, id: []const u8, pose: u16, variant: u8) ?Pose {
        if (variant < 1 or variant > 3) return null;
        const variants = (self.uniteGraphicPose(id, pose, null) orelse return null).flash orelse return null;
        return variants[variant - 1];
    }
    pub fn ordinaryActorGraphic(self: Content, id: []const u8, pose: u16) ?Pose {
        return (self.uniteGraphicPose(id, pose, null) orelse return null).ordinary;
    }
    pub fn partyProfile(self: Content, id: []const u8) ?Profile {
        for (self.party) |profile| if (std.mem.eql(u8, profile.id, id)) return profile;
        return null;
    }

    pub fn characterRules(self: Content) field.game_state.CharacterRules {
        return .{
            .tables = self.systems,
            .profiles = if (self.party.len == 0) null else self.party.ptr,
            .profile_count = self.party.len,
            .lookup = characterProfile,
        };
    }

    fn characterProfile(context: *const anyopaque, count: usize, id: []const u8) ?field.game_state.CharacterProfile {
        const profiles: [*]const Profile = @ptrCast(@alignCast(context));
        for (profiles[0..count]) |profile| if (std.mem.eql(u8, profile.id, id)) return .{
            .id = profile.id,
            .name = profile.name,
            .growth = profile.growth,
            .weapon = profile.weapon,
            .weapon_range = profile.weapon_range,
            .rune = profile.rune,
            .rune_locked = profile.rune_locked,
        };
        return null;
    }

    pub fn initialPartyCount(self: Content) usize {
        return if (self.initial_party) |ids| ids.len else self.party.len;
    }
    pub fn initialProfile(self: Content, index: usize) Profile {
        return if (self.initial_party) |ids| self.partyProfile(ids[index]).? else self.party[index];
    }

    pub fn enemyIndex(self: Content, id: []const u8) ?usize {
        for (self.enemies, 0..) |enemy, i| if (std.mem.eql(u8, enemy.id, id)) return i;
        return null;
    }

    pub fn battlefield(self: Content, id: []const u8) ?*const Battlefield {
        for (self.battlefields) |*entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }

    pub fn validateGroundAtlas(self: Content, width: i32, height: i32) !void {
        for (self.battlefields) |entry| {
            const source = entry.ground_atlas;
            validRect(source, width, height) catch return error.InvalidBattleGroundAtlas;
            if (@mod(source.x, Ground.tile_size) != 0 or @mod(source.y, Ground.tile_size) != 0 or
                entry.ground.tileColumns(source.w, source.h) == null) return error.InvalidBattleGroundAtlas;
        }
    }

    pub fn validate(self: Content) !void {
        const parsed_version = battleSchemaVersion(self.schema) orelse return error.UnsupportedBattleSchema;
        // Scoped art covers 78 party/32 enemy defaults and up to six members per Unite record.
        const graphic_limit: usize = if (parsed_version >= 35) 78 + 32 + 32 * 6 else 64;
        if (self.unite_graphics.len > graphic_limit or (self.unite_graphics.len != 0 and parsed_version < 24)) return error.InvalidUniteGraphics;
        for (self.unite_graphics, 0..) |graphic, index| {
            if (graphic.id.len == 0 or graphic.id.len > 128 or graphic.poses.len == 0 or graphic.poses.len > 256) return error.InvalidUniteGraphics;
            if (graphic.record) |record| if (parsed_version < 35 or record >= 32) return error.InvalidUniteGraphics;
            for (self.unite_graphics[0..index]) |other| if (graphic.record == other.record and std.mem.eql(u8, graphic.id, other.id)) return error.InvalidUniteGraphics;
            for (graphic.poses, 0..) |entry, ordinal| {
                if (entry.id >= 256) return error.InvalidUniteGraphics;
                try validPose(entry.sprite, 4096, 4096);
                if (entry.pieces.len != 0) {
                    if (parsed_version < 28 or entry.pieces.len > 256) return error.InvalidUniteGraphics;
                    for (entry.pieces) |piece| try validPose(piece, 4096, 4096);
                }
                if (entry.white) |pose| {
                    if (parsed_version < 26) return error.InvalidUniteGraphics;
                    try validPose(pose, 4096, 4096);
                    const base = entry.ordinary orelse entry.sprite;
                    if (pose.rect.w != base.rect.w or pose.rect.h != base.rect.h or pose.anchor_x != base.anchor_x or pose.anchor_y != base.anchor_y) return error.InvalidUniteGraphics;
                }
                if (entry.flash) |poses| {
                    if (parsed_version < 34) return error.InvalidUniteGraphics;
                    for (poses) |pose| {
                        try validPose(pose, 4096, 4096);
                        if (pose.rect.w != entry.sprite.rect.w or pose.rect.h != entry.sprite.rect.h or pose.anchor_x != entry.sprite.anchor_x or pose.anchor_y != entry.sprite.anchor_y) return error.InvalidUniteGraphics;
                    }
                }
                if (entry.ordinary) |pose| {
                    if (parsed_version < 34) return error.InvalidUniteGraphics;
                    try validPose(pose, 4096, 4096);
                }
                if (entry.trail) |poses| {
                    if (parsed_version < 25) return error.InvalidUniteGraphics;
                    for (poses) |pose| try validPose(pose, 4096, 4096);
                }
                for (graphic.poses[0..ordinal]) |other| if (entry.id == other.id) return error.InvalidUniteGraphics;
            }
        }
        if (self.round_start) |timing| try timing.validate();
        if (self.world_art) |art| {
            try art.validate();
            if (!self.presentation_ready or self.encounters.len != 1 or self.enemies.len != 1 or !std.mem.eql(u8, self.encounters[0].id, art.encounter) or !std.mem.eql(u8, self.enemies[0].id, if (art.c_tracks != null) "kobold_type_2" else "roc")) return error.InvalidWorldBattleArt;
        }
        for (self.medicine_timings, 0..) |timing, index| {
            try timing.validate();
            if (self.partyProfile(timing.id) == null) return error.InvalidMedicineTiming;
            for (self.medicine_timings[0..index]) |other| if (std.mem.eql(u8, timing.id, other.id)) return error.InvalidMedicineTiming;
        }
        for (self.party_attacks, 0..) |timing, i| {
            try timing.validate();
            for (self.party_attacks[0..i]) |previous| if (std.mem.eql(u8, previous.id, timing.id)) return error.InvalidPartyAttackTiming;
            if (self.partyProfile(timing.id) == null) return error.InvalidPartyAttackTiming;
        }
        if (self.protection) |data| try data.validate();
        const schema_version = parsed_version;
        if ((schema_version != 2) != (self.systems != null)) return error.InvalidSystems;
        if (self.systems) |rules| {
            try rules.validate();
            for (rules.spells) |spell| if (spell.kind == .source_rule and schema_version < 16) return error.UnsupportedBattleSchema;
            for (rules.runes) |rune_definition| {
                if (rune_definition.crystal) |id| if (std.meta.stringToEnum(field.items.Id, id) == null) return error.InvalidRune;
                if (rune_definition.allowed_members) |members| for (members) |id| {
                    if (self.partyProfile(id) == null) return error.InvalidRune;
                };
            }
            for (rules.equipment) |gear| if (gear.allowed_members) |members| for (members) |id| {
                if (self.partyProfile(id) == null) return error.InvalidEquipment;
            };
            var all_unites: [17]systems.Unite = undefined;
            all_unites[0] = rules.unite;
            @memcpy(all_unites[1 .. rules.additional_unites.len + 1], rules.additional_unites);
            for (all_unites[0 .. rules.additional_unites.len + 1]) |unite| for (unite.members) |id| {
                if (self.partyProfile(id) == null) return error.InvalidSystems;
            };
        }
        if (!std.mem.eql(u8, self.atlas, "actors.png") or !std.mem.eql(u8, self.background, "floor.png")) return error.InvalidBattleAssets;
        if (self.enemies.len == 0 or self.enemies.len > 256 or self.encounters.len == 0 or self.encounters.len > 512 or self.party.len == 0 or self.party.len > 78 or self.initialPartyCount() == 0 or self.initialPartyCount() > 6 or self.party_positions.len != self.initialPartyCount()) return error.InvalidBattleContent;
        if (schema_version >= 15 and self.initial_party == null) return error.MissingInitialParty;
        if (self.initial_party) |ids| for (ids, 0..) |id, i| {
            if (self.partyProfile(id) == null) return error.UnknownPartyMember;
            for (ids[0..i]) |other| if (std.mem.eql(u8, id, other)) return error.DuplicateFighter;
        };
        if (!std.math.isFinite(self.sprite_scale) or self.sprite_scale < 0.25 or self.sprite_scale > 4) return error.InvalidBattleAssets;
        for (self.camera.transform) |row| for (row) |value| {
            if (!std.math.isFinite(value) or @abs(value) > 8192) return error.InvalidBattleAssets;
        };
        if (!std.math.isFinite(self.camera.focal_length) or self.camera.focal_length < 1 or self.camera.focal_length > 8192 or !std.math.isFinite(self.camera.center_x) or !std.math.isFinite(self.camera.center_y)) return error.InvalidBattleAssets;
        for (self.formation_slots) |position| try validPosition(position);
        for (self.party_positions) |position| try validPosition(position);
        try validateScenery(self.scenery, 4096, 4096);
        if (self.ground) |ground| try ground.validate();
        if (self.battlefields.len != 0 and schema_version < 44) return error.UnsupportedBattleSchema;
        if (self.battlefields.len > 128) return error.InvalidBattleContent;
        for (self.battlefields, 0..) |entry, i| {
            try validText(entry.id);
            try entry.ground.validate();
            try validateScenery(entry.scenery, 4096, 4096);
            for (self.battlefields[0..i]) |other| if (std.mem.eql(u8, entry.id, other.id)) return error.DuplicateBattlefield;
        }
        try self.validateGroundAtlas(4096, 4096);
        for ([_][]const Profile{ self.party, self.enemies }) |profiles| for (profiles) |profile| {
            if (profile.item_art != null and schema_version < 31) return error.UnsupportedBattleSchema;
            if (profile.unite_scenes.len != 0 and schema_version < 19) return error.UnsupportedBattleSchema;
            for (profile.unite_scenes) |scene| if (scene.track.start_after != 0 and schema_version < 20) return error.UnsupportedBattleSchema;
            for (profile.unite_scenes) |scene| if (scene.track.reaction_on_hit and schema_version < 21) return error.UnsupportedBattleSchema;
            for (profile.unite_scenes) |scene| if (scene.track.trail != null and schema_version < 22) return error.UnsupportedBattleSchema;
            if (profile.effect_offset != null and schema_version < 23) return error.UnsupportedBattleSchema;
            for (profile.unite_scenes) |scene| if (scene.track.screen_offsets.len != 0 and schema_version < 23) return error.UnsupportedBattleSchema;
        };
        for (self.party) |profile| {
            if (profile.weapon) |weapon| if (weapon.element != null and schema_version < 33) return error.UnsupportedBattleSchema;
            try validateProfile(profile);
            if (profile.max_hp > 9999) return error.InvalidFighter;
            if (schema_version >= 27 and profile.revival_art == null) return error.MissingRevivalArt;
            if (schema_version >= 31) {
                if (profile.item_art == null) return error.MissingItemArt;
                var timed = false;
                for (self.medicine_timings) |timing| if (std.mem.eql(u8, timing.id, profile.id)) {
                    timed = true;
                };
                if (!timed) return error.InvalidMedicineTiming;
            }

            if (schema_version >= 17 and profile.unite_motion != null) {
                if (profile.unite_motion.?.ready_tick == null) return error.MissingUniteReady;
                for (profile.unite_attack) |frame| if (frame.source_pose == null) return error.MissingUnitePose;
            }
            if (profile.weapon) |weapon| {
                try validateWeapon(weapon);
            }
            if (profile.motion == null and (schema_version < 25 or profile.attack.len != 0 or self.uniteGraphic(profile.id, 0) == null)) return error.InvalidBattleAssets;
            if (schema_version >= 13 and profile.motion != null and profile.motion.?.ready_tick == null) return error.MissingAttackReady;
            if (self.systems != null and profile.weapon_range == null) return error.MissingWeaponRange;
            if (profile.rune) |id| if (self.systems == null or self.systems.?.runeIndex(id) == null) return error.InvalidRune;
        }
        for (self.party, 0..) |profile, index| {
            for (self.party[0..index]) |other| if (std.mem.eql(u8, profile.id, other.id)) return error.DuplicateFighter;
        }
        for (self.enemies, 0..) |profile, i| {
            try validateProfile(profile);
            if (schema_version >= 33 and profile.affinities == null) return error.MissingElementalAffinities;
            if (profile.action_policy == .source_commander and (schema_version < 36 or !std.mem.eql(u8, profile.id, "beast_commander"))) return error.UnsupportedEnemyPresentation;
            if (profile.action_policy == .source_rabbit and (schema_version < 37 or !std.mem.eql(u8, profile.id, "killer_rabbit"))) return error.UnsupportedEnemyPresentation;
            if (profile.action_policy == .source_dagon and (schema_version < 39 or !std.mem.eql(u8, profile.id, "dagon"))) return error.UnsupportedEnemyPresentation;
            if (profile.action_policy == .source_whip_wolf and (schema_version < 40 or !std.mem.eql(u8, profile.id, "whip_wolf"))) return error.UnsupportedEnemyPresentation;
            if (profile.action_policy == .source_holly_fairy and (schema_version < 41 or !std.mem.eql(u8, profile.id, "holly_fairy"))) return error.UnsupportedEnemyPresentation;
            if (profile.action_policy == .source_sorcerer and (schema_version < 42 or !std.mem.eql(u8, profile.id, "sorcerer"))) return error.UnsupportedEnemyPresentation;
            if (profile.action_policy == .source_siren and (schema_version < 42 or !std.mem.eql(u8, profile.id, "siren"))) return error.UnsupportedEnemyPresentation;
            if (profile.action_policy == .source_earth_golem and (schema_version < 42 or !std.mem.eql(u8, profile.id, "earth_golem"))) return error.UnsupportedEnemyPresentation;
            if (profile.action_policy == .source_creeper and (schema_version < 43 or !std.mem.eql(u8, profile.id, "creeper"))) return error.UnsupportedEnemyPresentation;
            if (profile.action_policy == .source_shadow_man and (schema_version < 43 or !std.mem.eql(u8, profile.id, "shadow_man"))) return error.UnsupportedEnemyPresentation;
            if (profile.action_policy == .source_mirage_f and (schema_version < 43 or !std.mem.eql(u8, profile.id, "mirage_f"))) return error.UnsupportedEnemyPresentation;
            if (profile.action_policy == .source_mirage_h and (schema_version < 43 or !std.mem.eql(u8, profile.id, "mirage_h"))) return error.UnsupportedEnemyPresentation;
            if (profile.action_policy == .source_ninja and (schema_version < 38 or !std.mem.eql(u8, profile.id, "ninja_master"))) return error.UnsupportedEnemyPresentation;
            if (profile.action_policy == .source_projectile and schema_version < 32) return error.UnsupportedEnemyPresentation;
            if (profile.action_policy == .source_magic and schema_version < 30) return error.UnsupportedEnemyPresentation;
            if ((profile.action_policy == .source_melee or profile.action_policy == .source_magic or profile.action_policy == .source_projectile) and schema_version < 29) return error.UnsupportedEnemyPresentation;
            if ((profile.action_policy == .source_melee or profile.action_policy == .source_magic or profile.action_policy == .source_projectile or profile.action_policy == .source_commander or profile.action_policy == .source_rabbit or profile.action_policy == .source_ninja or profile.action_policy == .source_dagon or profile.action_policy == .source_whip_wolf or profile.action_policy == .source_holly_fairy or profile.action_policy == .source_sorcerer or profile.action_policy == .source_siren or profile.action_policy == .source_earth_golem or profile.action_policy == .source_creeper or profile.action_policy == .source_shadow_man or profile.action_policy == .source_mirage_f or profile.action_policy == .source_mirage_h) and self.presentation_ready and (self.uniteGraphic(profile.id, 0) == null or self.world_art != null)) return error.UnsupportedEnemyPresentation;
            if ((profile.action_policy == .unsupported or profile.action_policy == .rabbit or profile.action_policy == .commander or (profile.action_policy == .front_projectile and (self.world_art == null or self.world_art.?.c_tracks == null))) and self.presentation_ready) return error.UnsupportedEnemyPresentation;
            for (self.enemies[0..i]) |other| if (std.mem.eql(u8, profile.id, other.id)) return error.DuplicateFighter;
        }
        var experience: u32 = 0;
        for (self.encounters, 0..) |encounter, i| {
            try validText(encounter.id);
            try validText(encounter.title);
            if (encounter.reward_policy != .standard and schema_version < 45) return error.UnsupportedBattleSchema;
            if (encounter.scripted_finish) |finish| {
                if (schema_version < 46) return error.UnsupportedBattleSchema;
                if (encounter.reward_policy != .none or finish.after_round == 0 or finish.wait_ticks == 0 or finish.wait_ticks > 4096) return error.InvalidScriptedFinish;
            }
            if (encounter.battlefield) |id| {
                if (schema_version < 44) return error.UnsupportedBattleSchema;
                if (self.battlefield(id) == null) return error.UnknownBattlefield;
            }
            if (encounter.bribe_cost) |cost| if (cost > 589806) return error.InvalidBribeCost;
            if (encounter.enemies.len == 0 or encounter.enemies.len > 6) return error.InvalidEncounter;
            if (encounter.positions.len != encounter.enemies.len) return error.InvalidEncounter;
            if (encounter.enemy_rows) |rows| {
                if (rows.len != encounter.enemies.len) return error.InvalidEncounter;
            } else if (self.systems != null) return error.MissingEnemyRows;
            if (encounter.source_slots) |slots| {
                if (slots.len != encounter.enemies.len) return error.InvalidEncounter;
                for (slots, 0..) |slot, index| {
                    if (slot >= 6 or (index > 0 and slots[index - 1] >= slot)) return error.InvalidEncounter;
                }
            }
            for (encounter.positions) |position| try validPosition(position);
            for (encounter.enemies) |id| if (self.enemyIndex(id) == null) return error.UnknownEnemy;
            for (self.encounters[0..i]) |other| if (std.mem.eql(u8, encounter.id, other.id)) return error.DuplicateEncounter;
            experience += encounter.experience_per_member;
        }
        // shortcut: keep this level-five trial below a level gain until progression is implemented.
        if (self.systems == null and experience >= 1000) return error.TrialRequiresLevelUp;
    }

    pub fn validateAtlas(self: Content, width: i32, height: i32) !void {
        if (!self.presentation_ready) return error.SimulationOnlyBattleContent;
        for (self.battlefields) |entry| try validateScenery(entry.scenery, width, height);
        for (self.unite_graphics) |graphic| for (graphic.poses) |entry| {
            try validPose(entry.sprite, width, height);
            for (entry.pieces) |piece| try validPose(piece, width, height);
            if (entry.white) |pose| try validPose(pose, width, height);
            if (entry.flash) |poses| for (poses) |pose| try validPose(pose, width, height);
            if (entry.ordinary) |pose| try validPose(pose, width, height);
            if (entry.trail) |poses| for (poses) |pose| try validPose(pose, width, height);
        };
        if (self.world_art) |art| {
            for ([_][]const Profile{ self.party, self.enemies }) |profiles| for (profiles) |profile| {
                for (profile.unite_scenes) |scene| if (scene.track.trail) |trail| for (trail.poses) |pose| try validPose(pose, width, height);
            };
            return art.validateAtlas(width, height);
        }
        for (self.party) |profile| {
            try validPose(profile.sprite, width, height);
            for (profile.attack) |frame| try validPose(frame.pose, width, height);
            for (profile.unite_attack) |frame| try validPose(frame.pose, width, height);
            for (profile.unite_scenes) |scene| for (scene.track.attack) |frame| try validPose(frame.pose, width, height);
            for (profile.unite_scenes) |scene| if (scene.track.trail) |trail| for (trail.poses) |pose| try validPose(pose, width, height);
            for (profile.cast) |frame| try validPose(frame.pose, width, height);
            if (profile.revival_art) |art| for ([_]types_mod.AnimationClip{ art.down, art.recovery }) |clip| for (clip.frames) |frame| try validPose(frame.pose, width, height);
            if (profile.item_art) |art| inline for (.{ "idle", "prepare", "hold", "recover" }) |name| {
                for (@field(art, name).frames) |frame| try validPose(frame.pose, width, height);
            };
        }
        for (self.enemies) |profile| {
            try validPose(profile.sprite, width, height);
            for (profile.attack) |frame| try validPose(frame.pose, width, height);
            for (profile.unite_attack) |frame| try validPose(frame.pose, width, height);
            for (profile.unite_scenes) |scene| for (scene.track.attack) |frame| try validPose(frame.pose, width, height);
            for (profile.unite_scenes) |scene| if (scene.track.trail) |trail| for (trail.poses) |pose| try validPose(pose, width, height);
            for (profile.cast) |frame| try validPose(frame.pose, width, height);
            if (profile.revival_art) |art| for ([_]types_mod.AnimationClip{ art.down, art.recovery }) |clip| for (clip.frames) |frame| try validPose(frame.pose, width, height);
            if (profile.item_art) |art| inline for (.{ "idle", "prepare", "hold", "recover" }) |name| {
                for (@field(art, name).frames) |frame| try validPose(frame.pose, width, height);
            };
        }
        for (self.scenery) |entry| try validPose(entry.sprite, width, height);
    }
};
fn validateScenery(scenery: []const Scenery, width: i32, height: i32) !void {
    if (scenery.len > 32) return error.InvalidBattleAssets;
    for (scenery) |entry| {
        try validPose(entry.sprite, width, height);
        try validPosition(entry.position);
    }
}
fn validText(value: []const u8) !void {
    if (!validation.isPrintableUtf8(value, 80)) return error.InvalidBattleText;
}
pub fn validateWeapon(weapon: systems.Weapon) !void {
    if (weapon.initial_level == 0 or weapon.initial_level > 16) return error.InvalidWeapon;
    for (weapon.names) |name| try validText(name);
    for (weapon.powers) |power| if (power > 9999) return error.InvalidWeapon;
    for (weapon.upgrade_costs, 0..) |price, level| if ((level > 0 and price == 0) or price > 1000000) return error.InvalidWeapon;
}
pub fn validateProfile(profile: Profile) !void {
    if (profile.dodge) |dodge| {
        if (!profile.dodges_attacks) return error.InvalidDodge;
        try dodge.validate();
    }
    try validText(profile.id);
    try validText(profile.name);
    if (profile.max_hp == 0 or profile.max_hp > 32767 or profile.level == 0 or profile.level > 99 or profile.money > 999999) return error.InvalidFighter;
    for ([_]u16{ profile.stats.attack, profile.stats.defense, profile.stats.skill, profile.stats.speed, profile.stats.magic, profile.stats.luck }) |value| if (value > 9999) return error.InvalidFighter;
    try validPose(profile.sprite, 4096, 4096);
    if (profile.revival_art) |art| for ([_]types_mod.AnimationClip{ art.down, art.recovery }) |clip| {
        if (clip.frames.len == 0) return error.InvalidRevivalArt;
        try validTrack(clip.frames, null);
    };
    if (profile.item_art) |art| inline for (.{ "idle", "prepare", "hold", "recover" }) |name| {
        const clip = @field(art, name);
        if (clip.frames.len == 0) return error.InvalidItemArt;
        try validTrack(clip.frames, null);
        for (clip.frames) |frame| if (frame.source_pose == null or frame.source_pose.? > 255) return error.InvalidItemArt;
    };
    if (@abs(@as(i32, profile.foot_offset_y)) > 512) return error.InvalidBattleAssets;
    try validTrack(profile.attack, profile.motion);
    if (profile.effect_offset) |offset| for (offset) |value| if (@abs(@as(i32, value)) > 512) return error.InvalidUniteScreenOffset;
    if (profile.unite_scenes.len > 32 or (profile.unite_scenes.len != 0 and (profile.unite_motion != null or profile.unite_attack.len != 0 or profile.unite_camera.len != 0))) return error.InvalidUniteSceneBinding;
    try validTrack(profile.unite_attack, profile.unite_motion);
    for (profile.unite_scenes, 0..) |scene, index| {
        if (scene.record >= 32 or @as(u32, scene.track.start_after) + scene.track.motion.duration > 1000) return error.InvalidUniteSceneBinding;
        for (profile.unite_scenes[0..index]) |prior| if (scene.record == prior.record) return error.InvalidUniteSceneBinding;
        if (scene.track.trail) |trail| {
            if (trail.start == 0 or trail.start >= trail.stop or trail.stop >= scene.track.motion.duration) return error.InvalidUniteTrail;
            for (trail.poses) |pose| try validPose(pose, 4096, 4096);
        }
        if (scene.track.screen_offsets.len > 8) return error.InvalidUniteScreenOffset;
        var offset_end: u32 = 0;
        for (scene.track.screen_offsets) |offset| {
            const end = @as(u32, offset.start) + offset.updates;
            if (offset.start == 0 or offset.start < offset_end or offset.updates == 0 or offset.updates > 256 or end > scene.track.motion.duration) return error.InvalidUniteScreenOffset;
            for (offset.value) |value| if (@abs(@as(i32, value)) > 512) return error.InvalidUniteScreenOffset;
            offset_end = end;
        }
        try validTrack(scene.track.attack, scene.track.motion);
        if (scene.track.motion.ready_tick == null) return error.MissingUniteReady;
        for (scene.track.attack) |frame| if (frame.source_pose == null) return error.MissingUnitePose;
        try validUniteCamera(scene.track.camera, scene.track.motion);
    }
    try validUniteCamera(profile.unite_camera, profile.unite_motion);
    try validTrack(profile.cast, null);
    if (profile.cast.len > 0) {
        var ticks: u32 = 0;
        for (profile.cast) |frame| ticks += frame.ticks;
        if (profile.cast_impact == 0 or profile.cast_impact >= ticks) return error.InvalidBattleAssets;
    }
    if ((profile.front_projectile != null) != (profile.action_policy == .front_projectile)) return error.InvalidProjectileTiming;
    if (profile.front_projectile) |timing| if (timing.impact_tick <= 1 or timing.impact_tick >= timing.target_release_tick or timing.target_release_tick >= timing.owner_release_tick or timing.owner_release_tick > 4096 or profile.target_policy != .front_first) return error.InvalidProjectileTiming;
    if (profile.front_projectile) |timing| for (timing.dodges, 0..) |dodge, index| {
        try validText(dodge.id);
        if (dodge.target_release_tick <= timing.impact_tick or dodge.target_release_tick > 4096) return error.InvalidProjectileTiming;
        for (timing.dodges[0..index]) |previous| if (std.mem.eql(u8, dodge.id, previous.id)) return error.InvalidProjectileTiming;
    };
    if ((profile.projectile != null) != (profile.action_policy == .rabbit)) return error.InvalidProjectileTiming;
    if (profile.action_policy == .source_rabbit and (!profile.unavoidable_attack or profile.knockout_ticks == null)) return error.InvalidRabbitPolicy;
    if ((profile.ordinary_timing != null) != (profile.action_policy == .rabbit or profile.action_policy == .roc) or ((profile.action_policy == .rabbit or profile.action_policy == .roc) and !profile.unavoidable_attack)) return error.InvalidRabbitPolicy;
    if (profile.ordinary_timing) |timing| if (timing.impact_tick <= 1 or timing.impact_tick >= timing.return_tick or timing.return_tick >= timing.duration or timing.duration > 4096) return error.InvalidOrdinaryTiming;
    if (profile.action_policy == .roc) {
        const timing = profile.ordinary_timing.?;
        const delay = timing.target_release_delay orelse return error.InvalidOrdinaryTiming;
        if (delay == 0 or delay >= timing.duration - timing.impact_tick or profile.knockout_ticks == null) return error.InvalidOrdinaryTiming;
    }
    if (profile.projectile) |timing| if (timing.impact_tick <= 1 or timing.impact_tick >= timing.release_tick or timing.release_tick >= timing.duration or timing.duration > 4096) return error.InvalidProjectileTiming;
    if ((profile.commander != null) != (profile.action_policy == .commander)) return error.InvalidCommanderTiming;
    if (profile.commander) |timing| if (timing.auxiliary_spawn_tick <= 1 or timing.auxiliary_spawn_tick >= timing.auxiliary_release_tick or timing.auxiliary_release_tick != timing.reaction_tick or timing.reaction_tick >= timing.owner_release_tick or timing.owner_release_tick >= timing.status_tick or timing.status_tick >= timing.duration or timing.duration > 4096 or timing.status_percent > 100) return error.InvalidCommanderTiming;
    if (profile.knockout_ticks) |ticks| if (ticks == 0 or ticks > 1024) return error.InvalidKnockoutTiming;
    if ((profile.commander_order != null) != (profile.action_policy == .commander)) return error.InvalidCommanderOrderTiming;
    if (profile.commander_order) |timing| if (timing.launch_tick <= 1 or timing.launch_tick >= timing.owner_release_tick or timing.owner_release_tick > 4096) return error.InvalidCommanderOrderTiming;
    if (profile.ordered_attack) |timing| {
        if (!std.mem.eql(u8, profile.id, "flying_squirrel") or profile.action_policy != .attack or timing.impact_tick <= 1 or timing.impact_tick >= timing.return_tick or timing.return_tick >= timing.status_tick or timing.status_tick >= timing.target_release_tick or timing.target_release_tick >= timing.duration or timing.duration > 4096 or timing.status_percent > 100) return error.InvalidOrderedAttackTiming;
    }
    if (profile.drops) |loot| for (loot) |drop| {
        if (drop.item) |id| {
            if (!drop.identified and !id.decoration()) return error.InvalidDrop;
            if (drop.uses != id.maxUses()) return error.InvalidDrop;
        } else if (drop.uses != 0 or !drop.identified) return error.InvalidDrop;
    };
}
fn validUniteCamera(requests: []const @import("battle_camera").ActorRequest, optional_motion: ?presentation.Motion) !void {
    if (requests.len > 32) return error.InvalidBattleAssets;
    for (requests, 0..) |request, index| {
        try request.validate();
        const motion = optional_motion orelse return error.InvalidBattleAssets;
        if (request.at >= motion.duration or (index > 0 and request.at < requests[index - 1].at)) return error.InvalidBattleAssets;
    }
}

fn validTrack(frames: []const Frame, movement: ?presentation.Motion) !void {
    if (frames.len > 128) return error.InvalidBattleAssets;
    var ticks: u32 = 0;
    for (frames) |frame| {
        try validPose(frame.pose, 4096, 4096);
        if (frame.ticks == 0 or frame.ticks > 256) return error.InvalidBattleAssets;
        ticks += frame.ticks;
    }
    if (ticks > 1000) return error.InvalidBattleAssets;
    if (movement) |motion| {
        if (motion.ready_tick) |ready| if (ready < motion.impact_tick or ready > motion.return_start) return error.InvalidBattleAssets;
        if (motion.approach.ticks < 2 or motion.retreat.ticks < 2 or motion.duration > 1000 or motion.impact_tick < motion.approach_start + @as(u32, motion.approach.ticks) or motion.return_start < motion.impact_tick or motion.return_start + @as(u32, motion.retreat.ticks) > motion.duration or ticks != motion.duration or motion.stages.len > 7) return error.InvalidBattleAssets;
        for ([_]presentation.Leap{ motion.approach, motion.retreat }) |leap| {
            try validPosition(leap.offset);
            try validPosition(leap.velocity);
            if (leap.acceleration_step != 0 and leap.acceleration_step != 1.0 / 4096.0) return error.InvalidBattleAssets;
        }
        var end: u32 = 0;
        for (motion.stages) |stage| {
            if (stage.home or stage.start < end or stage.leap.ticks < 2) return error.InvalidBattleAssets;
            try validPosition(stage.leap.offset);
            try validPosition(stage.leap.velocity);
            if (stage.leap.acceleration_step != 0 and stage.leap.acceleration_step != 1.0 / 4096.0) return error.InvalidBattleAssets;
            end = @as(u32, stage.start) + stage.leap.ticks;
        }
        if (end > motion.return_start) return error.InvalidBattleAssets;
    }
}
pub fn validPosition(position: Position) !void {
    for ([_]f32{ position.x, position.y, position.z }) |value| if (!std.math.isFinite(value) or @abs(value) > 8192) return error.InvalidBattleAssets;
}
fn validPose(pose: Pose, width: i32, height: i32) !void {
    try validRect(pose.rect, width, height);
    if (@abs(@as(i32, pose.anchor_x)) > 512 or @abs(@as(i32, pose.anchor_y)) > 512) return error.InvalidBattleAssets;
}
fn validRect(rect: Rect, width: i32, height: i32) !void {
    if (rect.x < 0 or rect.y < 0 or rect.w <= 0 or rect.h <= 0 or rect.w > width or rect.h > height or rect.x > width - rect.w or rect.y > height - rect.h) return error.InvalidBattleAssets;
}
pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Content) {
    if (bytes.len > Content.max_file_size) return error.BattleContentTooLarge;
    const parsed = try std.json.parseFromSlice(Content, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}
