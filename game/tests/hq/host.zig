//! Focused gate: the integrated headquarters / roster / service /
//! tablet flow.
//!
//! Port level only: no original instruction, emulator, window, media or real
//! save is touched.  The committed HQ assets are the real assets, the
//! roster is the HQ roster engine and every transaction goes through the
//! shared publication owner.  Ordinary input (`hq_mod.Intent`) drives the
//! screens; no test writes a story byte, recruit byte or RNG value after the
//! initial declared checkpoint.
const std = @import("std");
const field = @import("field");
const event_runtime = @import("event_runtime");
const battle = @import("battle");
const party = @import("party_session");
const hq = @import("hq");
const stage_mod = hq.stage;
const scene_mod = hq.scene;
const windows_mod = hq.windows;
const roster_mod = hq.roster;
const services_mod = hq.services;
const tablet_mod = hq.tablet;
const hq_mod = hq;
const windows_data = @import("hq_data").recruitment_windows;
const stages_data = @import("hq_data").stages;

const allocator = std.testing.allocator;

// Sonya's source record id and her two source gates.
const sonya_record: u8 = 10;
const sonya_story_byte: u8 = 31;
const sonya_story_mask: u8 = 0x40;

fn ownedMember(profile: roster_mod.source.Profile, index: usize) battle.OwnedMember {
    var owned: battle.OwnedMember = .{
        .member = .{
            .id = profile.id,
            .name = profile.name,
            .hp = 40 + @as(u16, @intCast(index)),
            .max_hp = 60,
            .status = .healthy,
            .rune_charges = .{ 1, 2, 3, 4 },
            .max_rune_charges = .{ 4, 4, 4, 4 },
            .inventory = .{},
        },
        .level = 9,
        .experience = 100,
        .stats = .{ .attack = 20, .defense = 12, .skill = 10, .speed = 9, .magic = 8, .luck = 7 },
        .weapon_level = 3,
        .loadout = .{},
        .rune = null,
    };
    owned.member.inventory.slots[0] = .{ .id = .medicine, .uses = 1 };
    return owned;
}

fn characterExtra(id: []const u8) party.CharacterExtra {
    return .{
        .member_id = id,
        .weapon_element = .fire,
        .weapon_fragments = .{ 1, 1, 1, 1, 1 },
        .locked_equipment = .{ false, false, false, false, false },
    };
}

fn gameMember(id: []const u8, name: []const u8, index: usize) field.game_state.Member {
    var member = field.game_state.Member{
        .id = id,
        .name = name,
        .hp = 40 + @as(u16, @intCast(index)),
        .max_hp = 60,
        .status = .healthy,
        .rune_charges = .{ 1, 2, 3, 4 },
        .max_rune_charges = .{ 4, 4, 4, 4 },
        .inventory = .{},
    };
    member.inventory.slots[0] = .{ .id = .medicine, .uses = 1 };
    return member;
}

/// Everything a host binds by pointer must live at a stable address, so the
/// fixture is initialised in place instead of returned by value.
const Fixture = struct {
    state: field.State,
    members: [2]field.game_state.Member,
    story: event_runtime.StoryState,
    snapshot: party.Snapshot,
    packet: std.json.Parsed(roster_mod.source.Packet),
    rules: std.json.Parsed(field.items.Rules),
    recruit: [hq_mod.flag_slots]u8,

    fn initInPlace(self: *Fixture, stage_byte: u8) !void {
        self.packet = try roster_mod.source.load(allocator, @import("hq_data").roster.json);
        self.rules = try field.items.load(allocator, field.items.json);
        self.story = .{};
        self.story.scenario[sonya_story_byte] |= sonya_story_mask;
        self.members[0] = gameMember("hero", "Hero", 0);
        self.members[1] = gameMember("gremio", "Gremio", 1);
        // The bag stack must be the full source stack to be sellable.
        self.members[0].inventory.slots[0].?.uses = self.rules.value.medicine.uses;
        self.state = .{
            .room = 0,
            .x = 112,
            .y = 120,
            .destination = .{ .x = 112, .y = 120 },
            .progress = .{
                .money = 2000,
                .party = self.members[0..2],
                .story = .{ .scenario = self.story, .recruitment_tier = stage_byte, .village_south_exit_reached = true },
                .storage = .{},
            },
            .item_rules = self.rules.value,
        };
        @memset(&self.recruit, 0);
        self.recruit[8] = 1; // Hero
        self.recruit[2] = 1; // Gremio
        self.snapshot = .{
            .entry_id = "hq-host-entry",
            .content_id = "hq-host-content",
            .receipt = "hq-host-receipt",
            .baseline_revision = 3,
        };
        // Hero and Gremio active, Sonya's member record present but unrecruited:
        // a new combatant cannot be given invented stats, so the source grant
        // needs an existing record.
        const ids = [_][]const u8{ "hero", "gremio", "sonya" };
        for (ids, 0..) |id, index| {
            const profile = self.packet.value.profile(id) orelse return error.UnknownProfile;
            self.snapshot.members[index] = ownedMember(profile, index);
            self.snapshot.extras[index] = characterExtra(profile.id);
            self.snapshot.eligible[index] = index < 2;
        }
        self.snapshot.active[0] = "hero";
        self.snapshot.active[1] = "gremio";
        self.snapshot.forced[0] = "hero";
        self.snapshot.scene_order[0] = "hero";
        self.snapshot.scene_order[1] = "gremio";
    }

    fn roster(self: *Fixture) !roster_mod.roster.Roster {
        return roster_mod.roster.Roster.init(self.packet.value, self.snapshot, &.{});
    }

    fn deinit(self: *Fixture) void {
        self.rules.deinit();
        self.packet.deinit();
    }
};

fn newHost(f: *Fixture) !*hq_mod.Host {
    return hq_mod.Host.init(allocator, .{
        .field_state = &f.state,
        .roster = try f.roster(),
        .recruit = f.recruit,
    });
}

fn selectRecruit(host: *hq_mod.Host, identity: u16) !void {
    for (0..host.interactionList().len + 1) |_| {
        const current = host.currentInteraction() orelse return error.NoInteraction;
        if (current.kind == .recruit and current.identity == identity) return;
        try host.step(.down);
    }
    return error.InteractionNotFound;
}

test "the source-qualified stage-2 headquarters binds the Sonya window" {
    var f: Fixture = undefined;
    try f.initInPlace(2);
    defer f.deinit();
    const host = try newHost(&f);
    defer host.deinit();

    try std.testing.expectEqual(@as(u8, 2), host.stageByte());
    const built = try host.construction();
    try std.testing.expect(built.actors.len > 0);
    var found = false;
    for (built.actors) |actor| {
        if (actor.room == 2 and actor.source_character_id == sonya_record) found = true;
    }
    try std.testing.expect(found);

    try host.enterRoom(2);
    try selectRecruit(host, sonya_record);
    const interaction = host.currentInteraction().?;
    try std.testing.expectEqualStrings("recruit_window_000", interaction.window.?);
    // A service actor of this stage is listed but carries no family claim.
    var unbound = false;
    for (host.interactionList()) |row| {
        if (row.kind == .service_unbound) {
            try std.testing.expect(row.blocker != null);
            unbound = true;
        }
    }
    try std.testing.expect(unbound);
}

test "ordinary input admits and commits the source recruit, and the population follows" {
    var f: Fixture = undefined;
    try f.initInPlace(2);
    defer f.deinit();
    const host = try newHost(&f);
    defer host.deinit();

    try host.enterRoom(2);
    try selectRecruit(host, sonya_record);
    try host.step(.confirm); // opens the admitted window
    try std.testing.expectEqual(hq_mod.Screen.recruit, host.screen);
    try host.step(.confirm); // accepts the source grant
    try std.testing.expectEqual(hq_mod.Screen.field, host.screen);

    // The grant wrote the recruit byte, the roster ledger and re-ran the
    // source promotion (1 present recruit is below every threshold).
    try std.testing.expect(host.recruitFlags()[sonya_record] & 1 == 1);
    try std.testing.expectEqual(@as(u8, 2), host.stageByte());
    const state = host.rosterState().stateOf("sonya").?;
    try std.testing.expectEqual(roster_mod.roster.Presence.reserve, state.presence);

    // The population is rebuilt from the new fact: the actor is gone.
    const built = try host.construction();
    for (built.actors) |actor| {
        if (actor.room == 2 and actor.source_character_id == sonya_record) return error.ActorStillPresent;
    }
    // The window is closed by the same source predicate, not by a host flag.
    var closed = true;
    for (host.interactionList()) |row| {
        if (row.kind == .recruit and row.identity == sonya_record) closed = false;
    }
    try std.testing.expect(closed);
}

test "the recruit and roster sidecar survive a fresh host and a tampered one is refused" {
    var f: Fixture = undefined;
    try f.initInPlace(2);
    defer f.deinit();
    const host = try newHost(&f);
    defer host.deinit();
    try host.enterRoom(2);
    try selectRecruit(host, sonya_record);
    try host.step(.confirm);
    try host.step(.confirm);

    const snapshot = try host.capture(allocator);
    defer allocator.free(snapshot.roster_json);
    try std.testing.expectEqual(@as(u8, 1), snapshot.recruit[sonya_record] & 1);

    // A fresh process: new fixture, new host, then the sidecar.
    var f2: Fixture = undefined;
    try f2.initInPlace(2);
    defer f2.deinit();
    const resumed = try newHost(&f2);
    defer resumed.deinit();
    try resumed.restore(snapshot);
    try std.testing.expect(resumed.recruitFlags()[sonya_record] & 1 == 1);
    try std.testing.expectEqual(roster_mod.roster.Presence.reserve, resumed.rosterState().stateOf("sonya").?.presence);
    try std.testing.expectEqual(@as(u8, 2), resumed.stageByte());
    const built = try resumed.construction();
    for (built.actors) |actor| {
        if (actor.source_character_id == sonya_record) return error.ActorStillPresent;
    }

    // A different content identity is a typed refusal, never a reset.
    var tampered = snapshot;
    tampered.content_sha256 = "00";
    try std.testing.expectError(error.HqContentMismatch, resumed.restore(tampered));
    // A tampered recruit byte is refused as well.
    var bad_bytes = snapshot;
    bad_bytes.recruit[sonya_record] = 0x80;
    try std.testing.expectError(error.InvalidRecruitByte, resumed.restore(bad_bytes));
}

test "stage promotion is produced by the recount and reconstructs the next stage" {
    var f: Fixture = undefined;
    try f.initInPlace(1);
    defer f.deinit();
    // Declared checkpoint: 25 ever-recruited flags and the castle story gate.
    try std.testing.expectEqual(@as(u8, 15), hq_mod.story_castle_index);
    var count: usize = 0;
    for (&f.recruit) |*byte| {
        if (count == 25) break;
        byte.* = 1;
        count += 1;
    }
    f.state.progress.story.scenario.?.scenario[hq_mod.story_castle_index] |= hq_mod.story_castle_mask;
    const host = try newHost(&f);
    defer host.deinit();
    const plan = try host.recountStage();
    try std.testing.expectEqual(stage_mod.Stage.two, plan.stage);
    try std.testing.expectEqual(@as(u8, 2), host.stageByte());
    // The stage-2 area file is what the catalogue binds now.
    const entry = try host.stageEntry();
    try std.testing.expect(std.mem.endsWith(u8, entry.area.file, "VB5BG.BIN"));
}

test "an absence variant reconstructs and survives the sidecar" {
    var f: Fixture = undefined;
    try f.initInPlace(2);
    defer f.deinit();
    // Recruited but temporarily away (`bit0 | bit1`): the actor is absent.
    f.recruit[sonya_record] = 3;
    const host = try newHost(&f);
    defer host.deinit();
    const built = try host.construction();
    for (built.actors) |actor| {
        if (actor.source_character_id == sonya_record) return error.ActorPresentWhileAbsent;
    }
    const snapshot = try host.capture(allocator);
    defer allocator.free(snapshot.roster_json);
    try std.testing.expectEqual(@as(u8, 3), snapshot.recruit[sonya_record]);

    var f2: Fixture = undefined;
    try f2.initInPlace(2);
    defer f2.deinit();
    const resumed = try newHost(&f2);
    defer resumed.deinit();
    try resumed.restore(snapshot);
    const rebuilt = try resumed.construction();
    for (rebuilt.actors) |actor| {
        if (actor.source_character_id == sonya_record) return error.ActorPresentWhileAbsent;
    }
}

test "ordinary service play transacts through the real engines and returns to the caller" {
    var f: Fixture = undefined;
    try f.initInPlace(2);
    defer f.deinit();
    const host = try newHost(&f);
    defer host.deinit();

    // The castle interior route is not derived: a canonical entry is refused.
    try std.testing.expectError(error.HqInteriorRouteUnresolved, host.enterArea("vb5b1", .canonical, .{
        .npc_present = true,
        .service_available = true,
        .story_gate = true,
    }));
    try host.enterArea("vb5b1", .declared, .{
        .npc_present = true,
        .service_available = true,
        .story_gate = true,
    });
    try std.testing.expect(host.interactionList().len > 0);
    const caller = host.currentInteraction().?;
    try std.testing.expectEqual(hq_mod.InteractionKind.service_caller, caller.kind);
    try host.step(.confirm);
    try std.testing.expectEqual(hq_mod.Screen.service, host.screen);

    // The shop's second service is `shop_sell`; the real game_state engine
    // prices and removes the bag entry and credits the money.
    const before_money = f.state.progress.money;
    const before_items = f.state.progress.party[0].inventory.count();
    try host.step(.down);
    try host.step(.confirm);
    try std.testing.expect(f.state.progress.money > before_money);
    try std.testing.expectEqual(before_items - 1, f.state.progress.party[0].inventory.count());

    // Cancel returns to the caller's field interaction, not another screen.
    try host.step(.cancel);
    try std.testing.expectEqual(hq_mod.Screen.field, host.screen);
    try std.testing.expectEqualStrings("service_cancelled", host.message);
    // Re-entering replays the same access checks.
    try host.enterArea("vb5b1", .declared, .{
        .npc_present = false,
        .service_available = true,
        .story_gate = true,
    });
    try std.testing.expectError(error.ServiceBlocked, host.step(.confirm));
}

test "the tablet is an ordinary-input view behind a disclosed entry" {
    var f: Fixture = undefined;
    try f.initInPlace(2);
    defer f.deinit();
    const host = try newHost(&f);
    defer host.deinit();

    try std.testing.expectError(error.TabletEntryUnbound, host.openTablet(.canonical));
    try host.openTablet(.declared);
    try std.testing.expectEqual(hq_mod.Screen.tablet, host.screen);
    const view = host.tabletView().?;
    const listed = view.listedCount();
    try std.testing.expect(listed >= 2);

    // Browsing is ordinary input; Hero and Gremio are the only listed stars.
    try host.step(.confirm);
    const revealed = host.tabletView().?.lastReveal().?;
    try std.testing.expectEqualStrings("Hero", revealed.name);

    // A save taken with the tablet open restores the cursor and the reveal.
    const snapshot = try host.capture(allocator);
    defer allocator.free(snapshot.roster_json);
    try std.testing.expect(snapshot.tablet != null);
    var f2: Fixture = undefined;
    try f2.initInPlace(2);
    defer f2.deinit();
    const resumed = try newHost(&f2);
    defer resumed.deinit();
    try resumed.restore(snapshot);
    try std.testing.expectEqual(hq_mod.Screen.tablet, resumed.screen);
    try std.testing.expectEqualStrings("Hero", resumed.tabletView().?.lastReveal().?.name);

    try host.step(.cancel);
    try std.testing.expectEqual(hq_mod.Screen.field, host.screen);
}

test "every unproved canonical entry is disclosed instead of faked" {
    var f: Fixture = undefined;
    try f.initInPlace(2);
    defer f.deinit();
    const host = try newHost(&f);
    defer host.deinit();

    // Optional games need the optional-game driver and the accepted optional-game contracts.
    try std.testing.expectError(error.OptionalGameSeamUnbound, host.admitMode(0x26430));
    try std.testing.expectEqualStrings("optional_game_seam_unbound", host.blockerInfo().?.code);
    // The castle-name producer is still unresolved in the stage plan.
    var glyphs: [8]u8 = @splat(0x11);
    try std.testing.expectError(error.ProducerUnresolved, stage_mod.commitCastleName(&glyphs));
    // The declared tablet entry says so.
    try host.openTablet(.declared);
    try std.testing.expectEqualStrings("tablet_declared_entry", host.message);
}

test "the committed package packets are the ones the host binds" {
    const parsed = try scene_mod.load(allocator, stages_data.stages_json);
    defer parsed.deinit();
    var checked: usize = 0;
    for (parsed.value.stages) |entry| {
        for (entry.rooms) |room| {
            if (!room.materialized or room.entity_count == 0) continue;
            checked += 1;
        }
    }
    try std.testing.expect(checked >= 20);
    var loaded = try windows_mod.open(allocator, windows_data.json);
    defer loaded.deinit();
    try std.testing.expect(loaded.asset().windows.len > 0);
    try std.testing.expect(services_mod.schema_id.len > 0);
    try std.testing.expect(tablet_mod.tabletDocument().len > 0);
}
