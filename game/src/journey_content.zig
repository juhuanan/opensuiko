const std = @import("std");
const field = @import("field");
const battle = @import("battle");
const journey = @import("journey");
const shared_catalogue = @import("item_ledger").catalogue;
const policies = @import("campaign_policies_data");
const ui_font = @import("ui_font");
const audio_route = @import("audio_route");
pub const BattleRooms = @import("field_events").BattleRooms;
const optional_games = journey.dice.games;
const dice_presentation = @import("dice_presentation");
const world_view = @import("world_view");
pub const duel_presentation = @import("duel_presentation.zig");

fn isWarBattleId(id: []const u8) bool {
    if (!std.mem.startsWith(u8, id, "war:")) return false;
    const scenario_id = id["war:".len..];
    const valid = [_][]const u8{
        "pannu_yakuta",
        "garan",
        "scarleticia_pollen",
        "scarleticia_antidote",
        "teo_before_fire_spear",
        "teo_fire_spear",
        "northern_checkpoint",
        "shasarazade",
        "gregminster",
    };
    for (valid) |candidate| if (std.mem.eql(u8, scenario_id, candidate)) return true;
    return false;
}

fn isDuelBattleId(id: []const u8) bool {
    if (!std.mem.startsWith(u8, id, "duel:")) return false;
    const duel_id = id["duel:".len..];
    for ([_][]const u8{ "pahn_teo", "shu_kwanda", "shu_teo" }) |candidate| {
        if (std.mem.eql(u8, duel_id, candidate)) return true;
    }
    return false;
}

fn isEndingBattleId(id: []const u8) bool {
    return std.mem.eql(u8, id, "ending:main");
}

fn isSpecialBattleId(id: []const u8) bool {
    return isWarBattleId(id) or isDuelBattleId(id) or isEndingBattleId(id);
}

pub const Diagnostic = struct {
    path: []const u8 = "",
    cause: ?anyerror = null,
    path_storage: [1024]u8 = undefined,

    fn record(self: *Diagnostic, path: []const u8, cause: anyerror) anyerror {
        // Failed package loads release their arena before the caller prints this path.
        const count = @min(path.len, self.path_storage.len);
        @memcpy(self.path_storage[0..count], path[0..count]);
        self.path = self.path_storage[0..count];
        self.cause = cause;
        return cause;
    }
};

// One owner; state borrows these values and must end before deinit.
pub const Bundle = struct {
    arena: *std.heap.ArenaAllocator,
    package: field.Package,
    combat: battle.Content,
    data: journey.Data,
    items: field.items.Rules,
    shared_item_catalogue: shared_catalogue.Packet,
    inn: field.inn.Rules,
    ui: ?ui_font.Font = null,
    battle_host: ?*battle.IntegrationHost = null,
    spell_scenes: ?*const battle.spell_scene.Packet = null,
    unite_actors: ?*const battle.actor_host.Bundle = null,
    room_battles: ?*BattleRooms = null,
    dice_host: ?*optional_games.Host = null,
    teleport_catalogue: ?*const journey.travel.teleport.catalogue.Loaded = null,
    dice_model: ?*const dice_presentation.Packet = null,
    duel_art: ?duel_presentation.Packet = null,
    crossing_art: ?*const world_view.Data = null,
    boat_data: ?*const journey.travel.BoatData = null,
    region_bgm: ?audio_route.RegionBgmContent = null,

    pub fn load(backing: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, diagnostic: *Diagnostic) !Bundle {
        diagnostic.* = .{};
        // Keep allocator handles stable even when the returned bundle moves.
        const arena = try backing.create(std.heap.ArenaAllocator);
        arena.* = .init(backing);
        errdefer {
            arena.deinit();
            backing.destroy(arena);
        }
        const content_allocator = arena.allocator();
        const room_bytes = try read(content_allocator, io, directory, "room.json", field.Package.max_file_size, diagnostic);
        const package = field.load(content_allocator, room_bytes) catch |err| return diagnostic.record("room.json", err);
        const combat_bytes = try read(content_allocator, io, directory, "battle/trial.json", battle.Content.max_file_size, diagnostic);
        const combat = battle.load(content_allocator, combat_bytes) catch |err| return diagnostic.record("battle/trial.json", err);
        const journey_bytes = try read(content_allocator, io, directory, "journey.json", journey.Data.max_file_size, diagnostic);
        const data = journey.load(content_allocator, journey_bytes, package.value, combat.value) catch |err| return diagnostic.record("journey.json", err);
        const region_path = audio_route.RegionBgmContent.manifest_path;
        const region_bytes = directory.readFileAlloc(io, region_path, content_allocator, .limited(audio_route.RegionBgmContent.max_bytes)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return diagnostic.record(region_path, err),
        };
        const region_bgm = if (region_bytes) |bytes|
            (audio_route.loadRegionBgm(content_allocator, bytes) catch |err| return diagnostic.record(region_path, err)).value
        else
            null;
        const items = field.items.load(content_allocator, field.items.json) catch |err| return diagnostic.record("embedded items.json", err);
        const shared_items = shared_catalogue.load(content_allocator, policies.item_ledger.json) catch |err| return diagnostic.record("embedded item_shared_ledger.json", err);
        const ui_bytes = directory.readFileAlloc(io, "ui.json", content_allocator, .limited(256 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        const ui = if (ui_bytes) |bytes| (ui_font.load(content_allocator, bytes) catch |err| return diagnostic.record("ui.json", err)).value else null;
        const scene_bytes = directory.readFileAlloc(io, "battle/spells.json", content_allocator, .limited(battle.spell_scene.max_file_size)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return diagnostic.record("battle/spells.json", err),
        };
        var spell_scenes: ?*battle.spell_scene.Packet = null;
        if (scene_bytes) |bytes| {
            const parsed = battle.spell_scene.load(content_allocator, bytes) catch |err| return diagnostic.record("battle/spells.json", err);
            spell_scenes = try content_allocator.create(battle.spell_scene.Packet);
            spell_scenes.?.* = parsed.value;
        }
        const unite_bytes = directory.readFileAlloc(io, "battle/unites.json", content_allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return diagnostic.record("battle/unites.json", err),
        };
        var unite_actors: ?*battle.actor_host.Bundle = null;
        if (unite_bytes) |bytes| {
            const parsed = battle.actor_host.loadBundle(content_allocator, bytes) catch |err| return diagnostic.record("battle/unites.json", err);
            unite_actors = try content_allocator.create(battle.actor_host.Bundle);
            unite_actors.?.* = parsed.value;
        }
        const event_bytes = directory.readFileAlloc(io, BattleRooms.path, content_allocator, .limited(BattleRooms.max_bytes)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return diagnostic.record(BattleRooms.path, err),
        };
        const room_battles = if (event_bytes) |bytes| rooms: {
            const rooms = BattleRooms.open(content_allocator, bytes, package.value) catch |err| return diagnostic.record(BattleRooms.path, err);
            if (rooms.opening_route) |route| for (route.initial_party) |id| {
                if (combat.value.partyProfile(id) == null)
                    return diagnostic.record(BattleRooms.path, error.UnknownOpeningPartyMember);
            };
            var sounds: ?audio_route.SoundContent = null;
            var field_audio_checked = false;
            var has_headquarters_audio = false;
            var has_founding_audio = false;
            var has_infiltration_audio = false;
            var has_mansion_audio = false;
            var has_wheel_audio = false;
            for (rooms.bindings) |binding| {
                for (binding.content.programs) |program| for (program.commands) |command| {
                    if (command.kind == .field_music and !field_audio_checked) {
                        const manifest = audio_route.FieldContent.manifest_path;
                        const raw = try read(content_allocator, io, directory, manifest, 4096, diagnostic);
                        const packet = audio_route.loadField(content_allocator, raw) catch |err| return diagnostic.record(manifest, err);
                        has_headquarters_audio = packet.value.get(.headquarters) != null;
                        has_founding_audio = packet.value.get(.founding) != null;
                        has_infiltration_audio = packet.value.get(.infiltration) != null;
                        has_mansion_audio = packet.value.get(.mansion) != null;
                        has_wheel_audio = packet.value.get(.wheel) != null;
                        for (packet.value.tracks) |track| {
                            const path = try std.fs.path.join(content_allocator, &.{ "audio", track.path });
                            const wave = try read(backing, io, directory, path, @as(usize, track.frames) * 4 + 44, diagnostic);
                            defer backing.free(wave);
                            if (!track.matches(wave)) return diagnostic.record(path, error.FieldAudioResourceMismatch);
                        }
                        field_audio_checked = true;
                    }
                    if (command.kind == .field_music and command.music == .headquarters and !has_headquarters_audio) return diagnostic.record(audio_route.FieldContent.manifest_path, error.MissingFieldMusic);
                    if (command.kind == .field_music and command.music == .founding and !has_founding_audio) return diagnostic.record(audio_route.FieldContent.manifest_path, error.MissingFieldMusic);
                    if (command.kind == .field_music and command.music == .infiltration and !has_infiltration_audio) return diagnostic.record(audio_route.FieldContent.manifest_path, error.MissingFieldMusic);
                    if (command.kind == .field_music and command.music == .wheel and !has_wheel_audio) return diagnostic.record(audio_route.FieldContent.manifest_path, error.MissingFieldMusic);
                    if (command.kind == .field_music and command.music == .mansion and !has_mansion_audio) return diagnostic.record(audio_route.FieldContent.manifest_path, error.MissingFieldMusic);
                    if (command.kind == .auto_route and command.value != 255) journey.travel.validateContent(package.value, binding.population.source, program) catch |err| return diagnostic.record(BattleRooms.path, err);
                    if (command.kind == .battle and !isSpecialBattleId(command.battle.?) and journey.encounterIndex(combat.value, command.battle.?) == null)
                        return diagnostic.record(BattleRooms.path, error.UnknownEncounter);
                    const implicit_window = binding.content.hasFixedBoxes() and (command.kind == .open_box or command.kind == .open_fixed_box);
                    if (command.kind == .play_sound or implicit_window) {
                        const sound_manifest = audio_route.SoundContent.manifest_path;
                        if (sounds == null) {
                            const raw = try read(content_allocator, io, directory, sound_manifest, audio_route.SoundContent.max_bytes, diagnostic);
                            sounds = (audio_route.loadSounds(content_allocator, raw) catch |err| return diagnostic.record(sound_manifest, err)).value;
                        }
                        if (sounds.?.cueIndex(if (implicit_window) audio_route.SoundContent.window_open else command.cue.?) == null)
                            return diagnostic.record(sound_manifest, error.MissingFieldSoundCue);
                    }
                    if (command.kind == .party_load or command.kind == .advance_character) {
                        if (combat.value.partyProfile(command.character.?) == null) return diagnostic.record(BattleRooms.path, error.UnknownFieldEventPartyMember);
                        if (combat.value.systems == null) return diagnostic.record(BattleRooms.path, error.InvalidSystems);
                    }
                    if (command.kind == .rune_grant) {
                        const profile = combat.value.partyProfile(command.character.?) orelse return diagnostic.record(BattleRooms.path, error.UnknownRuneRecipient);
                        const rules = combat.value.systems orelse return diagnostic.record(BattleRooms.path, error.UnknownStoryRune);
                        const rune = rules.runeIndex(command.rune.?) orelse return diagnostic.record(BattleRooms.path, error.UnknownStoryRune);
                        if (!rules.runes[rune].allows(profile.id)) return diagnostic.record(BattleRooms.path, error.IncompatibleRune);
                        if (profile.rune_locked and (profile.rune == null or !std.mem.eql(u8, profile.rune.?, command.rune.?)))
                            return diagnostic.record(BattleRooms.path, error.RuneLocked);
                    }
                    if (command.kind == .inventory_edit) {
                        if (combat.value.partyProfile(command.character.?) == null) return diagnostic.record(BattleRooms.path, error.UnknownItemRecipient);
                        const edit = command.inventory.?;
                        for ([_]?[]const u8{ edit.give, edit.take }) |name| if (name) |id| {
                            if (std.meta.stringToEnum(field.items.Id, id) == null) return diagnostic.record(BattleRooms.path, error.UnknownStoryItem);
                        };
                    }
                    if (command.kind == .warehouse_deposit and combat.value.partyProfile(command.character.?) == null)
                        return diagnostic.record(BattleRooms.path, error.UnknownItemRecipient);
                    if (command.kind == .shared_inventory_edit) {
                        const edit = command.inventory.?;
                        for ([_]?[]const u8{ edit.give, edit.take }) |name| if (name) |id| {
                            _ = shared_catalogue.sharedKey(shared_items.value, id) catch |err| return diagnostic.record(BattleRooms.path, err);
                        };
                    }
                };
                if (binding.dialogue.anchors.len != 0 or binding.dialogue.texts.len != 0) {
                    const font = ui orelse return diagnostic.record("ui.json", error.MissingUiFont);
                    for (binding.dialogue.texts) |entry| for (entry.tokens) |token| {
                        const text = if (token.kind == .player_name) name: {
                            const hero = combat.value.partyProfile("hero") orelse return diagnostic.record(BattleRooms.path, error.MissingSourcePartyIdentity);
                            break :name hero.name;
                        } else token.text orelse continue;
                        for (text) |byte| if (font.glyph(byte) == null) return diagnostic.record("ui.json", error.MissingOpeningGlyph);
                    };
                }
            }
            break :rooms rooms;
        } else null;
        var dice_host: ?*optional_games.Host = null;
        var teleport_catalogue: ?*journey.travel.teleport.catalogue.Loaded = null;
        var needs_dice_model = false;
        if (room_battles) |rooms| {
            for (rooms.bindings) |binding| for (binding.content.programs) |program| for (program.commands) |command| {
                const service = command.facility;
                if (service == .teleport and teleport_catalogue == null) {
                    teleport_catalogue = try content_allocator.create(journey.travel.teleport.catalogue.Loaded);
                    teleport_catalogue.?.* = try journey.travel.loadTeleport(content_allocator);
                }
                if (command.kind != .fixed_dice and service != .cup_game and service != .card_game) continue;
                needs_dice_model = needs_dice_model or command.kind == .fixed_dice;
                if (dice_host == null) {
                    const embedded = @import("hq_data").optional_games;
                    const rules = try optional_games.contracts.Contracts.parse(content_allocator, embedded.rules_json);
                    dice_host = try content_allocator.create(optional_games.Host);
                    dice_host.?.* = try optional_games.Host.init(content_allocator, embedded.json, .{}, rules);
                }
                if (service == .cup_game or service == .card_game) {
                    _ = journey.side_games.caller(dice_host.?.*, binding, program.entity, service.?) catch |err|
                        return diagnostic.record(BattleRooms.path, err);
                }
            };
        }
        var dice_model: ?*const dice_presentation.Packet = null;
        const has_dice_model = if (needs_dice_model) present: {
            directory.access(io, dice_presentation.path, .{}) catch |err| switch (err) {
                error.FileNotFound => break :present false,
                else => return diagnostic.record(dice_presentation.path, err),
            };
            break :present true;
        } else false;
        if (has_dice_model) {
            const sound_path = audio_route.SoundContent.manifest_path;
            const sound_bytes = try read(content_allocator, io, directory, sound_path, audio_route.SoundContent.max_bytes, diagnostic);
            const sounds = audio_route.loadSounds(content_allocator, sound_bytes) catch |err| return diagnostic.record(sound_path, err);
            for ([_]u16{ audio_route.SoundContent.dice_box_open, audio_route.SoundContent.dice_win, audio_route.SoundContent.dice_landing }) |id| {
                const index = sounds.value.cueIndex(id) orelse return diagnostic.record(sound_path, error.MissingDiceSoundCue);
                const cue = sounds.value.cues[index];
                const bank: u8 = if (id == audio_route.SoundContent.dice_landing) 2 else 0;
                if (cue.bank != bank) return diagnostic.record(sound_path, error.InvalidDiceSoundBank);
                const cue_path = try std.fs.path.join(content_allocator, &.{ "audio/sfx", cue.path });
                const cue_wave = try read(backing, io, directory, cue_path, @as(usize, cue.frames) * 4 + 44, diagnostic);
                defer backing.free(cue_wave);
                if (!cue.matches(cue_wave)) return diagnostic.record(cue_path, error.DiceAudioResourceMismatch);
            }
            const audio_bytes = try read(content_allocator, io, directory, audio_route.DiceContent.manifest_path, 4096, diagnostic);
            const audio_packet = audio_route.loadDice(content_allocator, audio_bytes) catch |err| return diagnostic.record(audio_route.DiceContent.manifest_path, err);
            for (audio_packet.value.tracks) |track| {
                const audio_path = try std.fs.path.join(content_allocator, &.{ "audio", track.path });
                const wave = try read(backing, io, directory, audio_path, @as(usize, track.frames) * 4 + 44, diagnostic);
                defer backing.free(wave);
                if (!track.matches(wave)) return diagnostic.record(audio_path, error.DiceAudioResourceMismatch);
            }
            const bytes = try read(content_allocator, io, directory, dice_presentation.path, 128 * 1024, diagnostic);
            const parsed = dice_presentation.load(content_allocator, bytes) catch |err| return diagnostic.record(dice_presentation.path, err);
            const model_packet = try content_allocator.create(dice_presentation.Packet);
            model_packet.* = parsed.value;
            dice_model = model_packet;
        }
        var crossing_art: ?*world_view.Data = null;
        var boat_data: ?*journey.travel.BoatData = null;
        if (package.value.roomIndex(journey.travel.source.world_room) != null) {
            try journey.travel.validatePackage(package.value);
            const bytes = try read(content_allocator, io, directory, world_view.crossing_path, 256 * 1024, diagnostic);
            const parsed = world_view.load(content_allocator, bytes) catch |err| return diagnostic.record(world_view.crossing_path, err);
            if (!parsed.value.isCrossing()) return diagnostic.record(world_view.crossing_path, error.InvalidWorldArt);
            const png = try read(backing, io, directory, parsed.value.atlas, 4 * 1024 * 1024, diagnostic);
            defer backing.free(png);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(png, &digest, .{});
            const hex = std.fmt.bytesToHex(digest, .lower);
            if (!std.mem.eql(u8, &hex, parsed.value.atlas_sha256.?)) return diagnostic.record(parsed.value.atlas, error.CrossingArtMismatch);
            crossing_art = try content_allocator.create(world_view.Data);
            crossing_art.?.* = parsed.value;
            const water = try journey.travel.loadBoatData(content_allocator, journey.travel.boat_json);
            boat_data = try content_allocator.create(journey.travel.BoatData);
            boat_data.?.* = water.value;
        }
        const duel_art: ?duel_presentation.Packet = art: {
            const bytes = directory.readFileAlloc(io, duel_presentation.path, content_allocator, .limited(2 * 1024 * 1024)) catch |err| switch (err) {
                error.FileNotFound => break :art null,
                else => return diagnostic.record(duel_presentation.path, err),
            };
            const value = std.json.parseFromSliceLeaky(duel_presentation.Packet, content_allocator, bytes, .{}) catch |err| return diagnostic.record(duel_presentation.path, err);
            const rules = try journey.duel.load(backing, journey.duel.content_json);
            defer rules.deinit();
            value.validate(rules.value) catch |err| return diagnostic.record(duel_presentation.path, err);
            if (ui) |font| for (rules.value.duels) |match| {
                for (match.cues) |row| for (row) |cue| {
                    for (cue) |byte| if (byte != '\n' and font.glyph(byte) == null)
                        return diagnostic.record("ui.json", error.MissingDuelGlyph);
                };
                for (match.fighters) |fighter| for (fighter.name) |byte| {
                    if (font.glyph(byte) == null) return diagnostic.record("ui.json", error.MissingDuelGlyph);
                };
            };
            const png = try read(backing, io, directory, duel_presentation.atlas_path, 16 * 1024 * 1024, diagnostic);
            defer backing.free(png);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(png, &digest, .{});
            const hex = std.fmt.bytesToHex(digest, .lower);
            if (!std.mem.eql(u8, &hex, value.atlas_sha256)) return diagnostic.record(duel_presentation.atlas_path, error.DuelAtlasMismatch);
            break :art value;
        };
        if (room_battles) |bindings| for (bindings.bindings) |binding| {
            for (binding.content.programs) |program| for (program.commands) |command| {
                if (command.facility == .music_player and (region_bgm == null or region_bgm.?.jukebox.len == 0))
                    return diagnostic.record(region_path, error.MissingJukeboxPlaylist);
            };
        };
        return .{ .arena = arena, .package = package.value, .combat = combat.value, .data = data.value, .items = items.value, .shared_item_catalogue = shared_items.value, .inn = field.inn.embedded(), .ui = ui, .battle_host = try battle.IntegrationHost.init(content_allocator), .spell_scenes = spell_scenes, .unite_actors = unite_actors, .room_battles = room_battles, .dice_host = dice_host, .dice_model = dice_model, .duel_art = duel_art, .crossing_art = crossing_art, .boat_data = boat_data, .teleport_catalogue = teleport_catalogue, .region_bgm = region_bgm };
    }

    pub fn allocator(self: *const Bundle) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn missingStrikeKnockout(self: *const Bundle, enemy_id: []const u8) bool {
        const counter = (self.unite_actors orelse return false).counter orelse return false;
        if (counter.party_melee == null and counter.ranged == null) return false;
        for (self.combat.encounters) |encounter| {
            for (encounter.enemies) |id| {
                if (!std.mem.eql(u8, id, enemy_id)) continue;
                const scenes = self.spell_scenes orelse return true;
                const reaction = scenes.reactionPose(enemy_id) orelse return true;
                return reaction.knockout == null;
            }
        }
        return false;
    }

    pub fn deinit(self: *Bundle) void {
        const arena = self.arena;
        const backing = arena.child_allocator;
        arena.deinit();
        backing.destroy(arena);
        self.* = undefined;
    }
};

fn read(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, path: []const u8, limit: usize, diagnostic: *Diagnostic) ![]u8 {
    // Zig's stream limit is exclusive; callers supply the maximum accepted file size.
    const bytes = directory.readFileAlloc(io, path, allocator, .limited(limit + 1)) catch |err| return diagnostic.record(path, err);
    if (bytes.len > limit) {
        allocator.free(bytes);
        return diagnostic.record(path, error.StreamTooLong);
    }
    return bytes;
}
