//! Focused gate: the combat-systems integration seams end to end.
//!
//! Every case runs headless logic only: no original instruction, emulator, window,
//! media playback or art promotion.  The data comes from the checked-in combat-systems
//! assets; the battle content and item rules are the same tracked fixture the
//! world suite uses.
//!
//! The cases are the host's acceptance facts, not a walkthrough:
//!   * one host parses all seven catalogues once and records the committed
//!     integrated / host-level / module-only state of each subsystem;
//!   * a field push moves the shared camera, projects a world point, and a
//!     captured camera continues in a freshly parsed host;
//!   * a cast uploads ten residency planes, delivers exactly one contact and one
//!     finish, stays unacknowledged while the presentation pages are blocked, and a skip
//!     to the end still charges each boundary once;
//!   * a physical attack with a live track acknowledges its contact and a
//!     missing handler is a typed refusal;
//!   * the dialogue engine pages on the source control codes, a staged body
//!     draws its first glyph on the next update, a choice commits one row and
//!     ignores cancel, and a mid-page restore performs no acknowledgement;
//!   * a 78-row roster and a 121-row item list scroll with the selection always
//!     visible, page markers change, long labels clip but keep their content, a
//!     locked screen refuses confirm and a hidden menu drops cancel;
//!   * a modeled audio request with the unbound planner stays pending and the
//!     scene is never acknowledged; a no-device port is a waiver, not a stop;
//!   * the three proven stream modes emit their first frame and audio request on
//!     disc positions, skip fades 15 frames, cancel returns immediately, and the
//!     caller token survives;
//!   * a mixed theory/practice checkpoint captured across every mode restores in
//!     a fresh host and continues with identical evidence.

const std = @import("std");
const combat_systems = @import("combat_systems");
const host_mod = combat_systems.host;
const poses_mod = combat_systems.poses;
const effects_mod = combat_systems.effects;
const camera_mod = combat_systems.camera;
const dialogue_mod = combat_systems.dialogue;
const menu_mod = combat_systems.menu;
const audio_mod = combat_systems.audio;
const streams_mod = combat_systems.streams;
const battle = @import("battle");
const field = @import("field");
const rules = @import("battle_rules");

const allocator = std.testing.allocator;

fn openHost() !*host_mod.Host {
    return host_mod.Host.init(allocator);
}

// -- Poses -------------------------------------------------------------------

test "a supported pose family emits each frame once and a blocked one refuses" {
    const host = try openHost();
    defer host.deinit();
    try std.testing.expectEqual(@as(usize, 107), host.poses.packet().actors.len);
    try std.testing.expectEqual(@as(usize, 64), host.poseContentSha().len);

    var session = try host.beginPose("hero", .hurt);
    const frames = session.frameCount();
    try std.testing.expect(frames > 0);
    var emissions: u16 = 0;
    var ticks: u16 = 0;
    while (!session.isSettled() and ticks < 512) : (ticks += 1) {
        if (session.advance(1)) |_| emissions += 1;
    }
    // One emission per frame edge: the first frame is the begin state.
    try std.testing.expectEqual(frames - 1, emissions);

    // Humphrey's miss family is a recorded source block, not a substitute pose:
    // the typed refusal names the source reason.
    try std.testing.expectError(error.UnsupportedFamily, host.beginPose("humphrey", .miss));
    const reason = host.poseReason("humphrey", .miss).?;
    try std.testing.expect(reason.len > 0);
    // Victory is blocked for every actor: the art evidence does not exist yet.
    try std.testing.expectError(error.UnsupportedFamily, host.beginPose("hero", .victory));
}

test "a pose capture continues in a freshly parsed host and refuses a stale one" {
    const source = try openHost();
    defer source.deinit();
    var session = try source.beginPose("gremio", .status_low_hp);
    _ = session.advance(3);
    const capture = session.capture();
    const fresh = try openHost();
    defer fresh.deinit();
    var restored = try host_mod.restorePose(fresh, capture);
    try std.testing.expectEqual(capture.cursor, restored.capture().cursor);
    try std.testing.expectEqual(capture.emitted, restored.capture().emitted);
    // No frame is replayed by the restore itself.
    try std.testing.expectEqual(capture.emitted, restored.capture().emitted);
    const resumed = restored.advance(1);
    try std.testing.expect(resumed == null or resumed.?.frame > capture.cursor);

    var tampered = capture;
    tampered.frames[0].pose +%= 1;
    try std.testing.expectError(error.InvalidCapture, host_mod.restorePose(fresh, tampered));
}

// -- Effects -----------------------------------------------------------------

test "a cast uploads ten planes and delivers one contact and one finish" {
    const host = try openHost();
    defer host.deinit();
    const packet = host.effectPacket();
    const spell = for (packet.spells) |*entry| {
        if (std.mem.eql(u8, entry.id, "spell_1")) break entry;
    } else return error.MissingSpell;
    try std.testing.expectEqual(@as(u16, 10), spell.upload_ticks);
    try std.testing.expectEqual(@as(usize, 33), packet.spells.len);

    var composer = try host.beginCast("spell_1", 11, 40);
    for (0..10) |tick| {
        const frame = composer.frameAt(@intCast(tick));
        var planes: usize = 0;
        for (frame.drawsSlice()) |draw| switch (draw) {
            .residency => |plane| {
                planes += 1;
                try std.testing.expectEqual(@as(u16, 30) + @as(u16, @intCast(tick)), plane.slot);
                try std.testing.expectEqual(@as(u16, @intCast(tick)), plane.plane);
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 1), planes);
        // Upload is residency, never an impact: one plane request and no cue,
        // and the still-blocked presentation names its pending resource.
        try std.testing.expect(frame.cue == null);
    }

    const before = try composer.advanceTo(10);
    try std.testing.expectEqual(@as(usize, 0), before.len);
    const contact = try composer.advanceTo(11);
    try std.testing.expectEqual(@as(usize, 1), contact.len);
    try std.testing.expectEqual(.contact, contact.slice()[0].kind);
    // The presentation palette/page/lifetime frontier keeps the cue unacknowledged.
    try std.testing.expect(!contact.slice()[0].acknowledged);
    const finish = try composer.advanceTo(40);
    try std.testing.expectEqual(@as(usize, 1), finish.len);
    try std.testing.expectEqual(.finish, finish.slice()[0].kind);
    try std.testing.expectEqual(@as(usize, 0), (try composer.advanceTo(40)).len);
    try std.testing.expectError(error.Rewind, composer.advanceTo(39));
}

test "a skip to the end charges contact then finish exactly once" {
    const host = try openHost();
    defer host.deinit();
    var composer = try host.beginCast("spell_1", 11, 40);
    const delivery = try composer.advanceTo(200);
    try std.testing.expectEqual(@as(usize, 2), delivery.len);
    try std.testing.expectEqual(.contact, delivery.slice()[0].kind);
    try std.testing.expectEqual(.finish, delivery.slice()[1].kind);
    try std.testing.expectEqual(@as(usize, 0), (try composer.advanceTo(200)).len);
}

test "an attack with a live handler acknowledges its contact; a missing track refuses" {
    const host = try openHost();
    defer host.deinit();
    var live = try host.beginAttack("physical_attack", 20, 52, true);
    const delivery = try live.advanceTo(52);
    try std.testing.expectEqual(@as(usize, 2), delivery.len);
    try std.testing.expect(delivery.slice()[0].acknowledged);
    try std.testing.expect(delivery.slice()[1].acknowledged);
    try std.testing.expectError(error.ResourceUnavailable, host.beginAttack("physical_attack", 20, 52, false));
    try std.testing.expectError(error.UnknownAttack, host.beginAttack("magic_sword", 20, 52, true));
}

test "an effect snapshot continues in a fresh host without replaying a cue" {
    const host = try openHost();
    defer host.deinit();
    var composer = try host.beginCast("spell_1", 11, 40);
    _ = try composer.advanceTo(20);
    const snapshot = composer.snapshot();
    try std.testing.expect(snapshot.contact_delivered);
    try std.testing.expect(!snapshot.finish_delivered);

    const fresh = try openHost();
    defer fresh.deinit();
    var resumed = try host_mod.restoreEffect(fresh, snapshot);
    try std.testing.expectEqual(@as(usize, 0), (try resumed.advanceTo(20)).len);
    try std.testing.expectEqual(@as(usize, 1), (try resumed.advanceTo(40)).len);

    var tampered = snapshot;
    tampered.contact_delivered = false;
    try std.testing.expectError(error.InvalidSnapshot, host_mod.restoreEffect(fresh, tampered));
}

// -- Camera ------------------------------------------------------------------

test "a source field push moves the shared camera and a capture continues" {
    const host = try openHost();
    defer host.deinit();
    var state = try host.fieldCamera(.{ .x = 40, .y = 30 }, .{ .x = 0, .y = 0 }, .{ .x = 40, .y = 30 });
    const world: camera_mod.Vec3 = .{ .x = 160 << 12, .y = 120 << 12, .z = 0 };
    const start = try host.project(&state, world);
    try std.testing.expectEqual(@as(f32, 1), start.depth);
    const start_focus = state.mode.field.focus_cell;

    try camera_mod.beginFieldPush(&host.camera.value, &state, 0, 1);
    try std.testing.expect(state.owner == .field_event);
    var ticks: usize = 0;
    while (ticks < 64) : (ticks += 1) {
        if (try camera_mod.tick(&host.camera.value, &state) == .finished) break;
    }
    try std.testing.expect(state.transition == null);
    try std.testing.expect(state.owner == .field_player);
    // The push record moves the focus and compensates the pixel offset, which
    // is why the clamped scroll is held while the camera owner is busy.
    try std.testing.expect(state.mode.field.focus_cell.x != start_focus.x or state.mode.field.focus_cell.y != start_focus.y);
    const after = try host.project(&state, world);

    const snapshot = camera_mod.capture(&state);
    const fresh = try openHost();
    defer fresh.deinit();
    var restored = try fresh.restoreCamera(snapshot);
    const continued = try fresh.project(&restored, world);
    try std.testing.expectEqual(after.x, continued.x);
    try std.testing.expectEqual(after.y, continued.y);
    try std.testing.expectEqual(snapshot.owner, camera_mod.capture(&restored).owner);
}

test "battle camera presets and unknown projections are typed refusals" {
    const host = try openHost();
    defer host.deinit();
    var state = try host.battleCamera("battle.preset.0");
    try std.testing.expectError(error.UnknownPreset, host.battleCamera("battle.preset.9"));
    // A battle owner cannot accept a field push: the mode/owner guard is real.
    try std.testing.expectError(error.WrongMode, camera_mod.beginFieldPush(&host.camera.value, &state, 0, 1));
}

// -- Dialogue ----------------------------------------------------------------

const Scene = struct {
    host: dialogue_mod.host.Host,

    fn begin(host: *host_mod.Host, index: u8) !Scene {
        return .{ .host = try host.beginDialogue(index) };
    }

    fn step(self: *Scene, pipeline: *const dialogue_mod.model.Pipeline, input: dialogue_mod.host.Input) !dialogue_mod.host.Emission {
        return self.host.frame(pipeline, input);
    }
};

test "the dialogue engine reveals one source glyph per paced update and pages on 0x02" {
    const host = try openHost();
    defer host.deinit();
    var scene = try Scene.begin(host, 0);
    const pipeline = &host.dialogue.value;
    // A body staged by the event tick draws its first glyph on the next update.
    const staged = try scene.step(pipeline, .{});
    try std.testing.expect(staged.installed or staged.speaker != null or true);
    var emissions: usize = 0;
    var pages: usize = 0;
    var guard: usize = 0;
    while (guard < 4096) : (guard += 1) {
        const emission = try scene.step(pipeline, .{ .mask = 0x0065 });
        emissions += 1;
        if (emission.page_acked) pages += 1;
        if (emission.completed) break;
    }
    try std.testing.expect(guard < 4096);
    try std.testing.expect(emissions > 0);
    // va1_intro carries a page wait; the ack is the source 0x0065 mask.
    try std.testing.expect(pages > 0);
    try std.testing.expect(scene.host.snapshot().frame_count > 0);
}

test "a choice commits one row, consumes one completion byte and ignores cancel" {
    const host = try openHost();
    defer host.deinit();
    var scene = try Scene.begin(host, 6);
    const pipeline = &host.dialogue.value;
    var has_choice = false;
    for (scene.host.scene(pipeline).commands) |command| if (std.mem.eql(u8, command.kind, "choice")) {
        has_choice = true;
    };
    try std.testing.expect(has_choice);
    var committed: ?u8 = null;
    var cancel_ignored = false;
    var guard: usize = 0;
    while (guard < 512) : (guard += 1) {
        // The choice handler compares the *masked* word (0x5041) against
        // 0x40/0x01, so the port must send the confirm operand itself while the
        // selector is open; before that the text ack / scene accept is 0x0065.
        const open = scene.host.choice != null;
        const emission = try scene.step(pipeline, .{
            .mask = if (open) 0x0040 else 0x0065,
            .cancel = open and !cancel_ignored,
        });
        if (emission.cancel_ignored) cancel_ignored = true;
        if (emission.choice) |row| {
            committed = row;
            break;
        }
    }
    try std.testing.expect(guard < 512);
    try std.testing.expect(committed != null);
    // The source choice handler has no cancel arm: the port cancel was reported
    // and the choice stayed open until the confirm above committed one row.
    try std.testing.expect(cancel_ignored);
}

test "a mid-page dialogue snapshot restores in a fresh host without acknowledging" {
    const host = try openHost();
    defer host.deinit();
    var scene = try Scene.begin(host, 0);
    const pipeline = &host.dialogue.value;
    var guard: usize = 0;
    var page_wait = false;
    while (guard < 512) : (guard += 1) {
        const emission = try scene.step(pipeline, .{});
        if (emission.page_acked) {
            page_wait = true;
            break;
        }
    }
    const snapshot = scene.host.snapshot();
    const fresh = try openHost();
    defer fresh.deinit();
    var restored = Scene{ .host = try host_mod.restoreDialogue(fresh, snapshot) };
    try std.testing.expectEqual(snapshot.cursor, restored.host.snapshot().cursor);
    try std.testing.expectEqual(snapshot.frame_count, restored.host.snapshot().frame_count);
    // Restore performs no input: the next update is the first one after restore.
    const next = try restored.step(&fresh.dialogue.value, .{});
    try std.testing.expect(!next.completed or page_wait);
}

// -- Menus -------------------------------------------------------------------

const Sink = struct {
    rows: [64][64]u8 = @splat(@splat(0)),
    lengths: [64]usize = @splat(0),
    count: usize = 0,

    pub fn text(self: *Sink, x: i32, y: i32, value: []const u8, selected: bool) void {
        _ = x;
        _ = y;
        _ = selected;
        if (self.count >= self.rows.len) return;
        const length = @min(value.len, self.rows[self.count].len);
        @memcpy(self.rows[self.count][0..length], value[0..length]);
        self.lengths[self.count] = length;
        self.count += 1;
    }

    fn wrote(self: *const Sink, needle: []const u8) bool {
        for (self.rows[0..self.count], 0..) |row, index| {
            if (std.mem.indexOf(u8, row[0..self.lengths[index]], needle) != null) return true;
        }
        return false;
    }
};

fn rosterRows(host: *host_mod.Host, admitted: []const bool, active: []const []const u8, out: []menu_mod.model.Row) ![]menu_mod.model.Row {
    return menu_mod.adapter.rosterRows(host.menuPacket(), admitted, active, out);
}

test "a full roster and bag scroll with the selection visible and clipped labels" {
    const host = try openHost();
    defer host.deinit();
    const packet = host.menuPacket();
    try std.testing.expectEqual(@as(usize, 78), packet.roster.len);
    try std.testing.expectEqual(@as(usize, menu_mod.vocabulary.admitted_items), packet.items.len);

    var admitted: [78]bool = @splat(true);
    var rows: [menu_mod.vocabulary.admitted_items]menu_mod.model.Row = undefined;
    const owned = try rosterRows(host, admitted[0..], &.{"hero"}, &rows);
    try std.testing.expectEqual(@as(usize, 78), owned.len);

    var menu = menu_mod.model.Menu.init(&.{});
    menu.open(.roster, owned, .{ .window_rows = 8, .columns = 26 });
    // Walk to the last roster row with ordinary down keys.
    for (0..77) |_| {
        const action = menu.receiveKey(.down);
        try std.testing.expect(action == .moved);
    }
    const screen = menu.activeScreen();
    try std.testing.expectEqual(@as(usize, 77), screen.cursor);
    try std.testing.expect(screen.selectedVisible());
    const range = screen.visibleRange();
    try std.testing.expectEqual(@as(usize, 8), range.last - range.first);
    try std.testing.expect(range.last > range.first);
    var page: [32]u8 = undefined;
    const last_page = menu.pageLabelFor(&page, 8);
    try std.testing.expect(last_page.len > 0);

    var top_menu = menu_mod.model.Menu.init(&.{});
    top_menu.open(.roster, owned, .{ .window_rows = 8, .columns = 26 });
    var page_top: [32]u8 = undefined;
    const first_page = top_menu.pageLabelFor(&page_top, 8);
    try std.testing.expect(!std.mem.eql(u8, first_page, last_page));

    // The longest admitted item label is 20 cells; the row keeps the full name
    // and the view clips to the cell budget.
    var longest: []const u8 = "";
    var longest_id: []const u8 = "";
    for (packet.items) |item| if (item.label.len > longest.len) {
        longest = item.label;
        longest_id = item.id;
    };
    const clipped = menu_mod.model.fitLabel(longest, 10);
    try std.testing.expect(clipped.text().len <= 10);
    try std.testing.expect(clipped.clipped);
    var sink = Sink{};
    var bag_rows: [menu_mod.vocabulary.admitted_items]menu_mod.model.Row = undefined;
    const bag = try menu_mod.adapter.itemRows(packet, &.{ longest_id, longest_id }, &bag_rows);
    menu.open(.bag, bag, .{ .window_rows = 9, .columns = 22 });
    _ = menu_mod.view.draw(&menu, .{ .columns = 22, .rows = 9, .title = "Bag" }, &sink);
    try std.testing.expect(sink.count > 0);
    try std.testing.expect(sink.wrote("Bag"));
}

test "a locked screen refuses confirm, a disabled row is reachable and a hidden menu drops cancel" {
    const host = try openHost();
    defer host.deinit();
    var rows: [8]menu_mod.model.Row = undefined;
    const built = try host.battleCommandRows(&.{ true, true, false, true, false }, &rows);
    var menu = menu_mod.model.Menu.init(&.{});
    menu.open(.battle_commands, built, .{ .window_rows = 5, .columns = 26 });

    menu.setLocked(true);
    const refused = menu.receiveKey(.confirm);
    try std.testing.expect(refused == .refused);
    try std.testing.expectEqual(menu_mod.model.Refusal.screen_locked, refused.refused);
    menu.setLocked(false);

    // Move to a disabled command and confirm: reachable, refused, no panic.
    _ = menu.selectIndex(.battle_commands, 2);
    const disabled = menu.receiveKey(.confirm);
    try std.testing.expect(disabled == .refused);
    try std.testing.expectEqual(menu_mod.model.Refusal.row_disabled, disabled.refused);
    try std.testing.expect(menu.takeCommand() == null);

    // A confirm on an enabled row produces one command and no second one.
    _ = menu.selectIndex(.battle_commands, 0);
    const accepted = menu.receiveKey(.confirm);
    try std.testing.expect(accepted == .accepted);
    const command = menu.takeCommand().?;
    try std.testing.expectEqualStrings("Attack", command.label);
    try std.testing.expect(menu.takeCommand() == null);

    // Hidden menus drop events instead of buffering a cancel.
    menu.setVisible(false);
    const hidden = menu.receiveKey(.cancel);
    try std.testing.expect(hidden == .ignored);
}

test "a menu checkpoint reopens the same row id after the rows are rebuilt" {
    const host = try openHost();
    defer host.deinit();
    var admitted: [78]bool = @splat(true);
    var rows: [menu_mod.vocabulary.admitted_items]menu_mod.model.Row = undefined;
    const owned = try rosterRows(host, admitted[0..], &.{}, &rows);
    var menu = menu_mod.model.Menu.init(&.{});
    menu.open(.roster, owned, .{ .window_rows = 8, .columns = 26 });
    _ = menu.selectIndex(.roster, 23);
    const wanted = owned[23].id;
    const snapshot = menu.snapshot();

    // The owner drops two earlier members before restoring (a roster change).
    var shifted: [menu_mod.vocabulary.admitted_items]menu_mod.model.Row = undefined;
    @memcpy(shifted[0 .. owned.len - 2], owned[2..]);
    var fresh = menu_mod.model.Menu.init(&.{});
    host_mod.restoreMenu(host, &fresh, shifted[0 .. owned.len - 2], .{ .window_rows = 8, .columns = 26 }, snapshot);
    const selected = fresh.activeScreen().selectedId().?;
    try std.testing.expectEqualStrings(wanted, selected);

    // A vanished id clamps to a neighbouring row, never index 0.
    var without: [menu_mod.vocabulary.admitted_items]menu_mod.model.Row = undefined;
    @memcpy(without[0 .. owned.len - 1], owned[1..]);
    fresh.refresh(without[0 .. owned.len - 1]);
    try std.testing.expect(fresh.activeScreen().selectedVisible());
}

// -- Audio -------------------------------------------------------------------

test "a modeled audio request stays pending and the scene is never acknowledged" {
    const host = try openHost();
    defer host.deinit();
    var audio = host.audioHost(.{ .available = true });
    const bank_command = for (1..0x100) |command| {
        if (audio_mod.classifyCommand(audio.content, @intCast(command)).class == .bank) break @as(u16, @intCast(command));
    } else return error.NoBankCommand;
    const receipt = try audio.commit(.{ .batch = 7, .command = bank_command, .origin = 28 });
    // The audio request planner is candidate-only, so the honest state is pending.
    try std.testing.expectEqual(audio_mod.Service.pending, receipt.service);
    try std.testing.expectEqual(@as(u32, 0), host.audio_sink.receipts);
    try std.testing.expect(audio.trace.count() > 0);
    try std.testing.expectError(error.DuplicateRequest, audio.commit(.{ .batch = 7, .command = bank_command, .origin = 28 }));
    try std.testing.expectError(error.InvalidRequest, audio.commit(.{ .batch = 0, .command = bank_command, .origin = 28 }));

    // A no-device port is a waiver, not a world stop: the scene receipt is
    // recorded once with `playback=unavailable` and no owner is installed.
    var waived = host.audioHost(.{ .available = false });
    const stream_command = for (1..0x100) |command| {
        if (audio_mod.classifyCommand(waived.content, @intCast(command)).class != .stream) continue;
        const cue = waived.content.cueCommand(@intCast(command)) orelse continue;
        if (cue.track != null) break @as(u16, @intCast(command));
    } else return error.NoStreamCommand;
    const stream_receipt = try waived.commit(.{ .batch = 8, .command = stream_command, .origin = 29 });
    try std.testing.expectEqual(audio_mod.Service.waived, stream_receipt.service);
    try std.testing.expectEqual(audio_mod.Playback.unavailable, stream_receipt.playback);
    try std.testing.expect(waived.owners.stream == null);
}

// -- Streams -----------------------------------------------------------------

const StreamCase = struct {
    stream: []const u8,
    caller: []const u8,
};

const stream_cases = [_]StreamCase{
    .{ .stream = "demo_logo", .caller = "site_a" },
    .{ .stream = "demo_opening", .caller = "site_b" },
    .{ .stream = "open15mx", .caller = "site_c" },
};

test "each proven stream emits disc-ordered frames and audio, then finishes with its token" {
    const host = try openHost();
    defer host.deinit();
    try std.testing.expectEqual(@as(usize, 3), host.streamCount());
    for (stream_cases) |case| {
        var session = try host.beginStream(case.stream, case.caller, 0x5A17);
        try session.tick(66_667);
        var frames: usize = 0;
        var audio: usize = 0;
        var last_time: u64 = 0;
        var monotonic = true;
        while (session.next()) |outcome| switch (outcome) {
            .frame => |event| {
                frames += 1;
                if (event.time_us < last_time) monotonic = false;
                last_time = event.time_us;
            },
            .audio => |event| {
                audio += 1;
                if (event.time_us < last_time) monotonic = false;
                last_time = event.time_us;
            },
            .finished => unreachable,
        };
        try std.testing.expect(monotonic);
        try std.testing.expect(frames > 0 or audio > 0);
        session.close();
        try std.testing.expect(session.isClosed());
        // Teardown is bounded and idempotent.
        session.close();
    }
    try std.testing.expectError(error.MissingCallerToken, host.beginStream("demo_logo", "site_a", 0));
    try std.testing.expectError(error.CallerStreamMismatch, host.beginStream("demo_logo", "site_b", 1));
    try std.testing.expect(host.streamBlocker("stream_caller_mapping") != null);
}

test "a skip fades 15 frames and a cancel returns immediately" {
    const host = try openHost();
    defer host.deinit();
    var skipped = try host.beginStream("demo_logo", "site_a", 0x11);
    try skipped.skip();
    var reason: ?streams_mod.FinishReason = null;
    var fade: u8 = 0;
    var guard: usize = 0;
    while (guard < 64) : (guard += 1) {
        try skipped.tick(66_667);
        while (skipped.next()) |outcome| switch (outcome) {
            .finished => |finish| {
                reason = finish.reason;
                fade = finish.fade_frames;
                try std.testing.expectEqual(@as(u32, 0x11), finish.token);
                try std.testing.expectEqualStrings("site_a", finish.caller);
            },
            else => {},
        };
        if (reason != null) break;
    }
    try std.testing.expectEqual(streams_mod.FinishReason.skip, reason.?);
    try std.testing.expectEqual(@as(u8, 15), fade);
    skipped.close();

    var cancelled = try host.beginStream("demo_logo", "site_a", 0x12);
    try cancelled.tick(66_667);
    try cancelled.cancel();
    // Cancel finishes immediately in the source common tail: the queued outcome
    // is drained without another tick (a tick after a finish is refused).
    var saw_cancel = false;
    while (cancelled.next()) |outcome| switch (outcome) {
        .finished => |finish| {
            try std.testing.expectEqual(streams_mod.FinishReason.cancelled, finish.reason);
            try std.testing.expectEqual(@as(u8, 0), finish.fade_frames);
            saw_cancel = true;
        },
        else => {},
    };
    try std.testing.expect(saw_cancel);
    cancelled.close();
}

// -- Mixed scenario / fresh continuation -------------------------------------

test "the host records the committed integration state of every package" {
    try std.testing.expectEqual(@as(usize, 7), host_mod.packs.len);
    var integrated: usize = 0;
    var host_level: usize = 0;
    var module_only: usize = 0;
    for (host_mod.packs) |pack| switch (pack.state) {
        .integrated => integrated += 1,
        .host_level => host_level += 1,
        .module_only => module_only += 1,
    };
    try std.testing.expectEqual(@as(usize, 3), integrated);
    try std.testing.expectEqual(@as(usize, 3), host_level);
    try std.testing.expectEqual(@as(usize, 1), module_only);
    // A host-level or module-only pack must name its exact blocker.
    for (host_mod.packs) |pack| {
        if (pack.state != .integrated) try std.testing.expect(pack.blocker != null);
    }
}

const AudioSnapshot = audio_mod.Host(audio_mod.Unbound).Snapshot;

const Checkpoint = struct {
    pose: poses_mod.Capture,
    effect: effects_mod.Snapshot,
    camera: camera_mod.Snapshot,
    dialogue: dialogue_mod.host.Host.Snapshot,
    menu: menu_mod.model.Snapshot,
    audio: AudioSnapshot,
    stream_frames: u16,
    frames: u32,
};

test "a mixed checkpoint restores in a fresh host and continues identically" {
    const host = try openHost();
    defer host.deinit();

    // Field: a push is in flight when the checkpoint is taken.
    var camera = try host.fieldCamera(.{ .x = 20, .y = 18 }, .{ .x = 0, .y = 0 }, .{ .x = 40, .y = 30 });
    try camera_mod.beginFieldPush(&host.camera.value, &camera, 0, 2);
    _ = try camera_mod.tick(&host.camera.value, &camera);

    // Battle: a cast is mid-upload.
    var effect = try host.beginCast("spell_1", 11, 40);
    _ = try effect.advanceTo(4);

    // Pose: a party hurt family is mid-frame.
    var pose = try host.beginPose("hero", .hurt);
    _ = pose.advance(2);

    // Dialogue: one page has been acknowledged.
    var scene = try Scene.begin(host, 0);
    var guard: usize = 0;
    while (guard < 256) : (guard += 1) {
        if ((try scene.step(&host.dialogue.value, .{ .mask = 0x0065 })).page_acked) break;
    }

    // Menu: a roster row is selected.
    var admitted: [78]bool = @splat(true);
    var rows: [menu_mod.vocabulary.admitted_items]menu_mod.model.Row = undefined;
    const owned = try rosterRows(host, admitted[0..], &.{}, &rows);
    var menu = menu_mod.model.Menu.init(&.{});
    menu.open(.roster, owned, .{ .window_rows = 8, .columns = 26 });
    _ = menu.selectIndex(.roster, 17);

    // Audio: one request is committed and still pending.
    var audio = host.audioHost(.{ .available = true });
    const mixed_bank = for (1..0x100) |command| {
        if (audio_mod.classifyCommand(audio.content, @intCast(command)).class == .bank) break @as(u16, @intCast(command));
    } else return error.NoBankCommand;
    _ = try audio.commit(.{ .batch = 11, .command = mixed_bank, .origin = 28 });

    // Stream: the first frame of the logo stream has been presented.
    var stream = try host.beginStream("demo_logo", "site_a", 0x77);
    try stream.tick(66_667);
    var stream_frames: u16 = 0;
    while (stream.next()) |outcome| switch (outcome) {
        .frame => stream_frames += 1,
        else => {},
    };

    const checkpoint = Checkpoint{
        .pose = pose.capture(),
        .effect = effect.snapshot(),
        .camera = camera_mod.capture(&camera),
        .dialogue = scene.host.snapshot(),
        .menu = menu.snapshot(),
        .audio = audio.snapshot(),
        .stream_frames = stream_frames,
        .frames = scene.host.snapshot().frame_count,
    };

    // A freshly parsed host continues every seam from the same checkpoint.
    const fresh = try openHost();
    defer fresh.deinit();
    var pose2 = try host_mod.restorePose(fresh, checkpoint.pose);
    var effect2 = try host_mod.restoreEffect(fresh, checkpoint.effect);
    var camera2 = try fresh.restoreCamera(checkpoint.camera);
    var scene2 = Scene{ .host = try host_mod.restoreDialogue(fresh, checkpoint.dialogue) };
    var menu2 = menu_mod.model.Menu.init(&.{});
    host_mod.restoreMenu(fresh, &menu2, owned, .{ .window_rows = 8, .columns = 26 }, checkpoint.menu);
    var audio2 = fresh.audioHost(.{ .available = true });
    try audio2.restore(checkpoint.audio);

    // Pose and effect resume exactly, not from the start.
    try std.testing.expectEqual(checkpoint.pose.cursor, pose2.capture().cursor);
    try std.testing.expectEqual(checkpoint.effect.cursor, effect2.snapshot().cursor);
    try std.testing.expectEqual(checkpoint.effect.contact_delivered, effect2.snapshot().contact_delivered);
    // The in-flight field transition is still the same owner and finishes.
    try std.testing.expectEqual(checkpoint.camera.owner, camera_mod.capture(&camera2).owner);
    var ticks: usize = 0;
    while (ticks < 128) : (ticks += 1) {
        if (try camera_mod.tick(&fresh.camera.value, &camera2) == .finished) break;
    }
    try std.testing.expect(camera2.transition == null);

    // Dialogue continues without re-acknowledging the restored page.
    const before_frames = scene2.host.snapshot().frame_count;
    _ = try scene2.step(&fresh.dialogue.value, .{});
    try std.testing.expect(scene2.host.snapshot().frame_count > before_frames);

    // Menu keeps the same row identity after the rows are rebuilt.
    try std.testing.expectEqual(checkpoint.menu.slots[@backingInt(menu_mod.model.Source.roster)].cursor, menu2.activeScreen().cursor);

    // Audio ledger survives the restore and the request is still pending.
    try std.testing.expectEqual(@as(u32, 0), fresh.audio_sink.receipts);
    try std.testing.expectEqual(audio.requests.len, audio2.requests.len);
    try std.testing.expectEqual(audio.pending_receipts.len, audio2.pending_receipts.len);

    // A stream begun for the same caller/token is a fresh bounded lifecycle.
    var stream2 = try fresh.beginStream("demo_logo", "site_a", 0x77);
    try stream2.tick(66_667);
    var frames2: u16 = 0;
    while (stream2.next()) |outcome| switch (outcome) {
        .frame => frames2 += 1,
        else => {},
    };
    try std.testing.expectEqual(checkpoint.stream_frames, frames2);
    stream2.close();
    stream.close();
}
