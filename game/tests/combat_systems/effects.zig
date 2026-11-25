//! Focused gate -- accepted spell/attack composition at coordinator
//! boundaries.
//!
//! The test supplies the coordinator boundaries explicitly (cast 60/120 and
//! attack 20/52 are the existing `battle.State` defaults documented in the
//! packet) and counts delivered events.  It does not execute original
//! instructions, open a window, play media or compose a window.  A synthetic
//! ready-spell copy proves the drawable branch without claiming any source
//! palette or page: the committed packet keeps all 33 presentations blocked.

const std = @import("std");
const effects_mod = @import("combat_systems").effects;
const data = @import("combat_systems_data").effect_composition;

const cast_contact: u16 = 60;
const cast_finish: u16 = 120;
const attack_contact: u16 = 20;
const attack_finish: u16 = 52;

fn load(allocator: std.mem.Allocator) !std.json.Parsed(effects_mod.Packet) {
    return effects_mod.load(allocator, data.effect_composition_json);
}

fn hexDigest(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

fn replaceAll(allocator: std.mem.Allocator, input: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    const size = std.mem.replacementSize(u8, input, needle, replacement);
    const output = try allocator.alloc(u8, size);
    _ = std.mem.replace(u8, input, needle, replacement, output);
    return output;
}

fn countKind(delivery: effects_mod.Delivery, kind: effects_mod.CueKind) usize {
    var count: usize = 0;
    for (delivery.slice()) |event| if (event.kind == kind) {
        count += 1;
    };
    return count;
}

test "asset loads the accepted 33/7/2 join and the presentation typed dependency" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const packet = &parsed.value;

    try std.testing.expectEqual(@as(usize, 33), packet.spells.len);
    try std.testing.expectEqual(@as(usize, 7), packet.families.len);
    try std.testing.expectEqual(@as(usize, 2), packet.attacks.len);
    try std.testing.expectEqual(@as(usize, 4), packet.qualified_families.len);
    try std.testing.expectEqual(@as(u16, 0), packet.coverage.presentation_ready);
    try std.testing.expectEqual(@as(u16, 33), packet.coverage.presentation_blocked);
    try std.testing.expectEqual(@as(u16, 32), packet.coverage.rules_supported);
    try std.testing.expectEqual(@as(u16, 1), packet.coverage.rules_partial);
    try std.testing.expectEqual(@as(u16, 10), packet.atlas.slot_count);
    try std.testing.expectEqual(@as(u16, 1), packet.atlas.planes_per_tick);
    try std.testing.expectEqualStrings("unavailable", packet.presentation.reviewed_correction_status);
    try std.testing.expectEqualStrings("presentation_correction_unavailable", packet.presentation.reviewed_correction_code);
    try std.testing.expectEqualStrings("spell_identity_to_presentation_frames_and_audio", packet.presentation.required_interface);

    const actual = try hexDigest(std.testing.allocator, data.effect_composition_json);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(data.effect_composition_file_sha256, actual);
}

test "a wrong schema, coverage or forged readiness is refused" {
    const allocator = std.testing.allocator;
    {
        const bytes = try replaceAll(allocator, data.effect_composition_json, "suikoden-effect-composition/1", "suikoden-effect-composition/2");
        defer allocator.free(bytes);
        try std.testing.expectError(error.InvalidPacket, effects_mod.load(allocator, bytes));
    }
    {
        const bytes = try replaceAll(allocator, data.effect_composition_json, "\"presentation_blocked\": 33", "\"presentation_blocked\": 32");
        defer allocator.free(bytes);
        try std.testing.expectError(error.InvalidPacket, effects_mod.load(allocator, bytes));
    }
    {
        // Every blocked record claims readiness while still carrying blockers.
        const bytes = try replaceAll(allocator, data.effect_composition_json, "\"presentation_status\": \"blocked\"", "\"presentation_status\": \"ready\"");
        defer allocator.free(bytes);
        try std.testing.expectError(error.ForgedPresentation, effects_mod.load(allocator, bytes));
    }
    {
        const bytes = try replaceAll(allocator, data.effect_composition_json, "\"upload_ticks\": 10", "\"upload_ticks\": 9");
        defer allocator.free(bytes);
        try std.testing.expectError(error.InvalidPacket, effects_mod.load(allocator, bytes));
    }
    {
        const bytes = try replaceAll(allocator, data.effect_composition_json, "palette_data_carrier", "palette_missing");
        defer allocator.free(bytes);
        try std.testing.expectError(error.InvalidPacket, effects_mod.load(allocator, bytes));
    }
}

test "beginCast refuses unknown identities and impossible boundaries" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const packet = &parsed.value;

    try std.testing.expectError(error.UnknownSpell, effects_mod.beginCast(packet, "spell_99", cast_contact, cast_finish));
    try std.testing.expectError(error.InvalidBoundary, effects_mod.beginCast(packet, "spell_1", 0, cast_finish));
    try std.testing.expectError(error.FinishBeforeContact, effects_mod.beginCast(packet, "spell_1", 60, 60));
    // Contact inside the ten-plane upload wait is residency, not an impact.
    try std.testing.expectError(error.ContactDuringUpload, effects_mod.beginCast(packet, "spell_1", 10, cast_finish));
    try std.testing.expectError(error.ContactDuringUpload, effects_mod.beginCast(packet, "spell_1", 5, cast_finish));
    // Contact exactly at the end of the lead (upload+present) is admissible.
    _ = try effects_mod.beginCast(packet, "spell_1", 11, cast_finish);

    // A presentation that would still be running at contact is refused rather
    // than truncated.
    var spells = try std.testing.allocator.dupe(effects_mod.Spell, packet.spells);
    defer std.testing.allocator.free(spells);
    var frames = [_]effects_mod.catalogue.FrameEntry{.{ .piece = 0, .ticks = 5 }};
    spells[0].present_ticks = 5;
    spells[0].lead_ticks = 15;
    spells[0].present_frames = frames[0..];
    var copy = packet.*;
    copy.spells = spells;
    try std.testing.expectError(error.PresentationPastContact, effects_mod.beginCast(&copy, "spell_1", 12, cast_finish));
    _ = try effects_mod.beginCast(&copy, "spell_1", 15, cast_finish);
}

test "cast upload emits exactly one plane per tick and never an impact" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const packet = &parsed.value;

    var composer = try effects_mod.beginCast(packet, "spell_1", cast_contact, cast_finish);
    const delivery = try composer.advanceTo(0);
    try std.testing.expectEqual(@as(usize, 0), delivery.len);

    var tick: u16 = 0;
    while (tick < 10) : (tick += 1) {
        const frame = composer.frameAt(tick);
        try std.testing.expectEqual(effects_mod.Phase.upload, frame.phase);
        try std.testing.expectEqual(@as(usize, 1), frame.draw_count);
        switch (frame.draws[0]) {
            .residency => |residency| {
                try std.testing.expectEqual(@as(u16, 30 + tick), residency.slot);
                try std.testing.expectEqual(tick, residency.plane);
            },
            else => return error.ExpectedResidency,
        }
        try std.testing.expect(frame.acknowledged);
        try std.testing.expect(frame.cue == null);
        try std.testing.expect(frame.pending == null);
    }

    // Upload completion is not contact: no event is delivered at tick 10.
    const after_upload = try composer.advanceTo(10);
    try std.testing.expectEqual(@as(usize, 0), after_upload.len);
}

test "blocked present intent is composed but never acknowledged as a draw" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const packet = &parsed.value;

    var composer = try effects_mod.beginCast(packet, "spell_1", cast_contact, cast_finish);
    _ = try composer.advanceTo(11);
    const frame = composer.frameAt(10);
    try std.testing.expectEqual(effects_mod.Phase.present, frame.phase);
    try std.testing.expectEqual(@as(usize, 0), frame.draw_count);
    try std.testing.expect(!frame.acknowledged);
    try std.testing.expect(frame.pending != null);
    try std.testing.expectEqual(effects_mod.Blocker.palette_data_carrier, frame.pending.?.blocker);
    try std.testing.expect(frame.cue == null);

    // Every one of the 33 present frames is unacknowledged while the presentation
    // frontier is open.
    for (packet.spells) |spell| {
        var probe = effects_mod.beginCast(packet, spell.id, cast_contact, cast_finish) catch continue;
        _ = try probe.advanceTo(spell.lead_ticks + 1);
        if (spell.present_ticks == 0) continue;
        const present = probe.frameAt(spell.upload_ticks);
        try std.testing.expectEqual(effects_mod.Phase.present, present.phase);
        try std.testing.expect(!present.acknowledged);
        try std.testing.expect(present.pending != null);
    }
}

test "contact is delivered once, stays unacknowledged, and needs simulation" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const packet = &parsed.value;

    var composer = try effects_mod.beginCast(packet, "spell_1", cast_contact, cast_finish);
    // Render pacing ahead of simulation cannot flash an impact.
    const early = composer.frameAt(cast_contact);
    try std.testing.expect(early.cue == null);
    try std.testing.expect(!early.acknowledged);

    const delivery = try composer.advanceTo(cast_contact);
    try std.testing.expectEqual(@as(usize, 1), delivery.len);
    try std.testing.expectEqual(effects_mod.CueKind.contact, delivery.events[0].kind);
    try std.testing.expectEqual(cast_contact, delivery.events[0].at_tick);
    try std.testing.expect(delivery.events[0].rule != null);
    try std.testing.expectEqualStrings("damage", delivery.events[0].rule.?.effect);
    try std.testing.expectEqualStrings("selected", delivery.events[0].rule.?.targets[0]);
    try std.testing.expect(!delivery.events[0].partial);
    try std.testing.expect(!delivery.events[0].acknowledged);

    // A repeated advance at the same tick never re-charges the boundary.
    const again = try composer.advanceTo(cast_contact);
    try std.testing.expectEqual(@as(usize, 0), again.len);

    const frame = composer.frameAt(cast_contact);
    try std.testing.expect(frame.cue != null);
    try std.testing.expect(!frame.cue.?.acknowledged);
    try std.testing.expect(!frame.acknowledged);
    try std.testing.expectEqual(effects_mod.Blocker.impact_timing, frame.pending.?.blocker);
}

test "skip across contact and finish delivers both once in order" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const packet = &parsed.value;

    var composer = try effects_mod.beginCast(packet, "spell_1", cast_contact, cast_finish);
    try std.testing.expect(!composer.contactDelivered());
    const delivery = try composer.advanceTo(200);
    try std.testing.expect(composer.contactDelivered());
    try std.testing.expect(composer.finishDelivered());
    try std.testing.expectEqual(@as(usize, 2), delivery.len);
    try std.testing.expectEqual(effects_mod.CueKind.contact, delivery.events[0].kind);
    try std.testing.expectEqual(effects_mod.CueKind.finish, delivery.events[1].kind);
    try std.testing.expectEqual(cast_contact, delivery.events[0].at_tick);
    try std.testing.expectEqual(cast_finish, delivery.events[1].at_tick);
    try std.testing.expect(delivery.events[1].rule == null);
    try std.testing.expect(!delivery.events[1].acknowledged);

    const frame = composer.frameAt(cast_finish);
    try std.testing.expectEqual(effects_mod.Phase.finish, frame.phase);
    try std.testing.expect(frame.cue != null);
    try std.testing.expectEqual(effects_mod.CueKind.finish, frame.cue.?.kind);
    try std.testing.expectEqual(effects_mod.Blocker.finish_timing, frame.pending.?.blocker);

    const repeated = try composer.advanceTo(200);
    try std.testing.expectEqual(@as(usize, 0), repeated.len);
    const after = composer.frameAt(201);
    try std.testing.expectEqual(effects_mod.Phase.done, after.phase);
    try std.testing.expect(after.acknowledged);
}

test "render pacing cannot emit events or double-charge a boundary" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const packet = &parsed.value;

    var composer = try effects_mod.beginCast(packet, "spell_2", cast_contact, cast_finish);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const frame = composer.frameAt(cast_contact);
        try std.testing.expect(frame.cue == null);
    }
    const first = try composer.advanceTo(cast_contact);
    try std.testing.expectEqual(@as(usize, 1), first.len);
    i = 0;
    while (i < 100) : (i += 1) _ = composer.frameAt(cast_contact);
    const second = try composer.advanceTo(cast_contact);
    try std.testing.expectEqual(@as(usize, 0), second.len);
    try std.testing.expectError(error.Rewind, composer.advanceTo(cast_contact - 1));
    try std.testing.expectError(error.InvalidBoundary, composer.advanceTo(5000));
}

test "damage group family follows cast/contact/finish with one rule effect" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const packet = &parsed.value;

    var composer = try effects_mod.beginCast(packet, "spell_2", cast_contact, cast_finish);
    const delivery = try composer.advanceTo(cast_finish);
    try std.testing.expectEqual(@as(usize, 1), countKind(delivery, .contact));
    try std.testing.expectEqual(@as(usize, 1), countKind(delivery, .finish));
    const contact = delivery.events[0];
    try std.testing.expectEqualStrings("damage", contact.rule.?.effect);
    try std.testing.expectEqualStrings("all_enemies", contact.rule.?.targets[0]);
    try std.testing.expectEqual(@as(usize, 1), contact.rule.?.steps.len);
    try std.testing.expectEqual(@as(u16, 150), contact.rule.?.steps[0].power);
    try std.testing.expect(contact.rule.?.one_time);

    const qualified = blk: {
        for (packet.qualified_families) |entry| {
            if (std.mem.eql(u8, entry.id, "damage_group")) break :blk entry;
        }
        return error.MissingQualifiedFamily;
    };
    try std.testing.expectEqualStrings("spell_2", qualified.spell.?);
    try std.testing.expectEqualStrings(qualified.rule_effect.effect, contact.rule.?.effect);
    try std.testing.expectEqual(qualified.rule_effect.steps.len, contact.rule.?.steps.len);
}

test "heal/group family follows cast/contact/finish with one rule effect" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const packet = &parsed.value;

    var composer = try effects_mod.beginCast(packet, "spell_12", cast_contact, cast_finish);
    const delivery = try composer.advanceTo(cast_finish);
    const contact = delivery.events[0];
    try std.testing.expectEqualStrings("heal", contact.rule.?.effect);
    try std.testing.expectEqualStrings("all_allies", contact.rule.?.targets[0]);
    try std.testing.expectEqual(@as(usize, 2), contact.rule.?.steps.len);
    try std.testing.expectEqualStrings("heal", contact.rule.?.steps[0].op);
    try std.testing.expectEqualStrings("clear_status", contact.rule.?.steps[1].op);
    try std.testing.expect(contact.rule.?.one_time);
    try std.testing.expect(!contact.acknowledged);
}

test "rule-partial spell keeps the partial marker and never claims completion" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const packet = &parsed.value;

    var composer = try effects_mod.beginCast(packet, "spell_33", cast_contact, cast_finish);
    const delivery = try composer.advanceTo(cast_finish);
    try std.testing.expect(delivery.events[0].partial);
    try std.testing.expectEqualStrings("scale_bonus", delivery.events[0].rule.?.effect);
    try std.testing.expect(!delivery.events[0].acknowledged);
}

test "Charm Arrow composes a rule-only timeline with no present phase" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const packet = &parsed.value;

    const charm = effects_mod.catalogue.findSpell(packet, "spell_8").?;
    try std.testing.expectEqualStrings("direct_single_plane", charm.composition_status);
    try std.testing.expectEqual(@as(?u8, 8), charm.direct_plane);
    try std.testing.expectEqual(@as(u16, 0), charm.upload_ticks);
    try std.testing.expect(charm.present_animation == null);
    var composer = try effects_mod.beginCast(packet, "spell_8", cast_contact, cast_finish);
    const first = composer.frameAt(0);
    try std.testing.expectEqual(effects_mod.Phase.pre_contact, first.phase);
    try std.testing.expectEqual(@as(usize, 0), first.draw_count);
    try std.testing.expect(first.acknowledged);
    const delivery = try composer.advanceTo(cast_finish);
    try std.testing.expectEqual(@as(usize, 1), countKind(delivery, .contact));
    try std.testing.expectEqualStrings("damage", delivery.events[0].rule.?.effect);
    try std.testing.expect(!delivery.events[0].acknowledged);
}

test "mid-upload snapshot resumes the identical remaining frames and events" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const packet = &parsed.value;

    var composer = try effects_mod.beginCast(packet, "spell_4", cast_contact, cast_finish);
    _ = try composer.advanceTo(4);
    const saved = composer.snapshot();
    var resumed = try effects_mod.Composer.restore(packet, saved);

    var tick: u16 = 5;
    while (tick < 10) : (tick += 1) {
        const a = composer.frameAt(tick);
        const b = resumed.frameAt(tick);
        try std.testing.expectEqual(a.phase, b.phase);
        try std.testing.expectEqual(a.draw_count, b.draw_count);
        try std.testing.expectEqual(a.acknowledged, b.acknowledged);
        switch (a.draws[0]) {
            .residency => |left| switch (b.draws[0]) {
                .residency => |right| {
                    try std.testing.expectEqual(left.slot, right.slot);
                    try std.testing.expectEqual(left.plane, right.plane);
                },
                else => return error.MismatchedDraw,
            },
            else => return error.MismatchedDraw,
        }
    }

    const original = try composer.advanceTo(cast_finish);
    const continuation = try resumed.advanceTo(cast_finish);
    try std.testing.expectEqual(original.len, continuation.len);
    try std.testing.expectEqual(original.events[0].kind, continuation.events[0].kind);
    try std.testing.expectEqual(original.events[0].at_tick, continuation.events[0].at_tick);
}

test "invalid or mismatched snapshots are refused" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const packet = &parsed.value;

    var composer = try effects_mod.beginCast(packet, "spell_1", cast_contact, cast_finish);
    _ = try composer.advanceTo(30);
    const valid = composer.snapshot();

    var forged = valid;
    forged.cursor = 0;
    forged.contact_delivered = true;
    try std.testing.expectError(error.InvalidSnapshot, effects_mod.Composer.restore(packet, forged));

    var wrong_version = valid;
    wrong_version.version = 2;
    try std.testing.expectError(error.InvalidSnapshot, effects_mod.Composer.restore(packet, wrong_version));

    var wrong_identity = valid;
    wrong_identity.id_len = 3; // "spe": not a packet identity
    try std.testing.expectError(error.SnapshotMismatch, effects_mod.Composer.restore(packet, wrong_identity));

    // A blocked packet cannot be upgraded by a snapshot.
    var forged_drawable = valid;
    forged_drawable.drawable = true;
    try std.testing.expectError(error.InvalidSnapshot, effects_mod.Composer.restore(packet, forged_drawable));

    var attack = try effects_mod.beginAttack(packet, "physical_attack", attack_contact, attack_finish, true);
    _ = try attack.advanceTo(5);
    // Its own snapshot is legitimate; a cast kind over an attack identity is not.
    _ = try effects_mod.Composer.restore(packet, attack.snapshot());
    var crossed = attack.snapshot();
    crossed.kind = .cast;
    try std.testing.expectError(error.SnapshotMismatch, effects_mod.Composer.restore(packet, crossed));
}

test "physical attack composes actor-track draws at the member boundaries" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const packet = &parsed.value;

    var composer = try effects_mod.beginAttack(packet, "physical_attack", attack_contact, attack_finish, true);
    const first = composer.frameAt(0);
    try std.testing.expectEqual(effects_mod.Phase.pre_contact, first.phase);
    try std.testing.expectEqual(@as(usize, 1), first.draw_count);
    switch (first.draws[0]) {
        .actor_track => |track| {
            try std.testing.expectEqualStrings("attack", track.track);
            try std.testing.expectEqualStrings("hurt", track.target_track);
            try std.testing.expectEqual(@as(u16, 0), track.track_tick);
        },
        else => return error.ExpectedActorTrack,
    }
    try std.testing.expect(first.acknowledged);

    const delivery = try composer.advanceTo(attack_contact);
    try std.testing.expectEqual(@as(usize, 1), delivery.len);
    try std.testing.expect(delivery.events[0].acknowledged);
    try std.testing.expectEqualStrings("physical_damage", delivery.events[0].rule.?.effect);
    const contact = composer.frameAt(attack_contact);
    try std.testing.expect(contact.cue.?.acknowledged);

    const finish = try composer.advanceTo(attack_finish);
    try std.testing.expectEqual(@as(usize, 1), finish.len);
    try std.testing.expectEqual(effects_mod.CueKind.finish, finish.events[0].kind);
    const ended = composer.frameAt(attack_finish);
    try std.testing.expectEqual(@as(usize, 0), ended.draw_count);
    try std.testing.expect(ended.acknowledged);
}

test "attack refuses a missing handler resource and unknown identities" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const packet = &parsed.value;

    try std.testing.expectError(error.ResourceUnavailable, effects_mod.beginAttack(packet, "physical_attack", attack_contact, attack_finish, false));
    try std.testing.expectError(error.UnknownAttack, effects_mod.beginAttack(packet, "spell_1", attack_contact, attack_finish, true));
    try std.testing.expectError(error.FinishBeforeContact, effects_mod.beginAttack(packet, "physical_attack", 50, 20, true));
    _ = try effects_mod.beginAttack(packet, "front_projectile", 30, 60, true);
}

test "projectile attack uses its own coordinator boundary names" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const packet = &parsed.value;

    var composer = try effects_mod.beginAttack(packet, "front_projectile", 30, 60, true);
    const frame = composer.frameAt(29);
    switch (frame.draws[0]) {
        .actor_track => |track| try std.testing.expectEqualStrings("projectile", track.track),
        else => return error.ExpectedActorTrack,
    }
    const delivery = try composer.advanceTo(60);
    try std.testing.expectEqual(@as(usize, 2), delivery.len);
    try std.testing.expectEqual(@as(u16, 30), delivery.events[0].at_tick);
    try std.testing.expectEqual(@as(u16, 60), delivery.events[1].at_tick);
}

test "synthetic ready vector composes a drawable piece and acknowledged contact" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const packet = &parsed.value;

    // Hand-authored test vector, not source evidence: flip one accepted spell
    // to the shape a reviewed presentation correction would produce.
    var ready = packet.spells[0];
    ready.presentation_status = "ready";
    ready.blockers = &.{};
    ready.palette_status = "resolved";
    ready.page_status = "ready";
    ready.lifetime_status = "ready";
    var one = [1]effects_mod.Spell{ready};
    var copy = packet.*;
    copy.spells = one[0..];

    // A forged "ready" without frames is refused even though it carries no blockers.
    var frameless = ready;
    frameless.present_animation = null;
    frameless.present_ticks = 0;
    frameless.present_frames = &.{};
    frameless.present_pieces = &.{};
    var frameless_spells = [1]effects_mod.Spell{frameless};
    var frameless_packet = copy;
    frameless_packet.spells = frameless_spells[0..];
    try std.testing.expectError(error.InvalidPacket, effects_mod.beginCast(&frameless_packet, "spell_1", cast_contact, cast_finish));

    var composer = try effects_mod.beginCast(&copy, "spell_1", cast_contact, cast_finish);
    _ = try composer.advanceTo(10);
    const frame = composer.frameAt(10);
    try std.testing.expectEqual(@as(usize, 1), frame.draw_count);
    try std.testing.expect(frame.acknowledged);
    switch (frame.draws[0]) {
        .presentation => |draw| {
            try std.testing.expectEqual(@as(u16, 0), draw.piece);
            try std.testing.expectEqual(@as(u16, 0), draw.frame);
            try std.testing.expectEqual(@as(u16, 30), draw.slot_base);
            try std.testing.expectEqual(@as(u8, 102), draw.palette_row);
            try std.testing.expect(draw.size[0] > 0 and draw.size[1] > 0);
        },
        else => return error.ExpectedPresentation,
    }

    const delivery = try composer.advanceTo(cast_contact);
    try std.testing.expect(delivery.events[0].acknowledged);
    try std.testing.expect(composer.frameAt(cast_contact).cue.?.acknowledged);
}

test "all 33 spells begin at the default cast boundaries and deliver one contact and finish" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const packet = &parsed.value;

    var acknowledged_contacts: usize = 0;
    for (packet.spells) |spell| {
        var composer = try effects_mod.beginCast(packet, spell.id, cast_contact, cast_finish);
        const delivery = try composer.advanceTo(cast_finish);
        try std.testing.expectEqual(@as(usize, 1), countKind(delivery, .contact));
        try std.testing.expectEqual(@as(usize, 1), countKind(delivery, .finish));
        try std.testing.expectEqual(cast_contact, delivery.events[0].at_tick);
        try std.testing.expectEqual(cast_finish, delivery.events[1].at_tick);
        if (delivery.events[0].acknowledged) acknowledged_contacts += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), acknowledged_contacts);
}

test "qualified families cover damage, heal and the accepted attack" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const packet = &parsed.value;

    var damage_individual = false;
    var damage_group = false;
    var heal_group = false;
    var attack_physical = false;
    for (packet.qualified_families) |entry| {
        if (std.mem.eql(u8, entry.id, "damage_individual")) {
            damage_individual = true;
            try std.testing.expectEqualStrings("spell_1", entry.spell.?);
        } else if (std.mem.eql(u8, entry.id, "damage_group")) {
            damage_group = true;
            try std.testing.expectEqualStrings("spell_2", entry.spell.?);
        } else if (std.mem.eql(u8, entry.id, "heal_group")) {
            heal_group = true;
            try std.testing.expectEqualStrings("spell_12", entry.spell.?);
        } else if (std.mem.eql(u8, entry.id, "attack_physical")) {
            attack_physical = true;
            try std.testing.expectEqualStrings("physical_attack", entry.attack.?);
        }
        try std.testing.expect(entry.rule_effect.one_time);
        try std.testing.expect(entry.rule_effect.steps.len > 0);
    }
    try std.testing.expect(damage_individual and damage_group and heal_group and attack_physical);
}

test "anchors, atlas and presentation frontier are the accepted values" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const packet = &parsed.value;

    try std.testing.expect(packet.anchors.len >= 23);
    for (packet.anchors) |anchor| {
        try std.testing.expectEqual(@as(usize, 64), anchor.sha256.len);
        try std.testing.expect(anchor.line > 0);
    }
    try std.testing.expectEqual(@as(u16, 30), packet.atlas.slot_base);
    try std.testing.expectEqual(@as(u16, 10), packet.atlas.ticks);
    try std.testing.expectEqualStrings("slots_30_to_39_replaced_by_next_spell_registration", packet.atlas.lifetime);
    try std.testing.expectEqual(@as(usize, 7), packet.presentation.frontier.len);
    for (packet.presentation.frontier) |code| {
        try std.testing.expect(effects_mod.Blocker.fromCode(code) != null);
    }
    try std.testing.expectEqualStrings(data.presentation_contract_sha256, packet.presentation.contract_sha256);
}

test "the two presentation blockers page and lifetime stay in every spell" {
    var parsed = try load(std.testing.allocator);
    defer parsed.deinit();
    const packet = &parsed.value;

    for (packet.spells) |spell| {
        try std.testing.expectEqualStrings("blocked", spell.page_status);
        try std.testing.expectEqualStrings("blocked", spell.lifetime_status);
        var page = false;
        var lifetime = false;
        for (spell.blockers) |code| {
            if (std.mem.eql(u8, code, "page_lifetime_unproven")) page = true;
            if (std.mem.eql(u8, code, "presentation_termination")) lifetime = true;
            if (std.mem.eql(u8, code, "impact_timing")) {}
        }
        try std.testing.expect(page and lifetime);
    }
}
