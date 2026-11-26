//! Focused, headless port checks.
//!
//! These cases drive the recovery layer with already-sampled logical frames and
//! a compile-only audio backend double.  They never open a window, initialize a
//! device, play media, execute original instructions or touch a user save.

const std = @import("std");
const recovery_mod = @import("platform_recovery");
const controller = @import("pause_menu");
const field = @import("field");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;

test "mode fade exchanges canvases at black and retains its opacity when interrupted" {
    const ModeFade = recovery_mod.display.ModeFade;
    var fade: ModeFade = .{};
    try expectEqual(@as(u8, 0), fade.alpha());
    fade.begin();
    for (0..ModeFade.half_ticks) |tick| {
        try expect(fade.showsOutgoing());
        try expectEqual(@as(u8, @intCast(tick * 255 / ModeFade.half_ticks)), fade.alpha());
        fade.advance(1);
    }
    try expect(!fade.showsOutgoing());
    try expectEqual(@as(u8, 255), fade.alpha());
    fade.advance(1);
    const opacity = fade.alpha();
    fade.begin();
    try expect(fade.showsOutgoing());
    try expectEqual(opacity, fade.alpha());
    fade.advance(ModeFade.half_ticks);
    fade.advance(ModeFade.half_ticks);
    try expect(!fade.showsOutgoing());
    try expectEqual(@as(u8, 0), fade.alpha());
}

test "mode fade presents black when a frame catches up on several updates" {
    const ModeFade = recovery_mod.display.ModeFade;
    var fade: ModeFade = .{};
    fade.begin();
    fade.advance(ModeFade.half_ticks - 1);
    try expect(fade.showsOutgoing());
    fade.advance(3);
    try expect(!fade.showsOutgoing());
    try expectEqual(@as(u8, 255), fade.alpha());
    fade.advance(3);
    try expect(fade.alpha() < 255);
}

test "frames without gameplay ticks leave both halves of a mode fade in place" {
    const ModeFade = recovery_mod.display.ModeFade;
    var fade: ModeFade = .{};
    fade.begin();
    fade.advance(3);
    const outgoing = fade;
    fade.advance(0);
    try expectEqual(outgoing, fade);

    fade.advance(ModeFade.half_ticks);
    fade.advance(3);
    const incoming = fade;
    fade.advance(0);
    try expectEqual(incoming, fade);
}

// ---------------------------------------------------------------------------
// Compile-only device/audio doubles.  They implement the same typed backend the
// platform loop supplies to the real audio player; no platform symbol is linked.
// ---------------------------------------------------------------------------

const FakeAudio = struct {
    plays: [8]recovery_mod.audio.Id = undefined,
    play_count: usize = 0,
    stops: [8]recovery_mod.audio.Id = undefined,
    stop_count: usize = 0,
    fail_plays: usize = 0,

    fn play(context: *anyopaque, id: recovery_mod.audio.Id) anyerror!void {
        const self: *FakeAudio = @ptrCast(@alignCast(context));
        if (self.fail_plays > 0) {
            self.fail_plays -= 1;
            return error.AudioStreamUnavailable;
        }
        self.plays[self.play_count] = id;
        self.play_count += 1;
    }

    fn stop(context: *anyopaque, id: recovery_mod.audio.Id) void {
        const self: *FakeAudio = @ptrCast(@alignCast(context));
        self.stops[self.stop_count] = id;
        self.stop_count += 1;
    }

    fn backend(self: *FakeAudio) recovery_mod.AudioBackend {
        return .{ .context = self, .play = play, .stop = stop };
    }
};

const FakeDisplay = struct {
    fullscreen: bool = false,
    vsync: bool = true,
    fullscreen_calls: u32 = 0,
    vsync_calls: u32 = 0,
    fail_fullscreen: bool = false,
    fail_vsync: bool = false,
    last_fullscreen: bool = false,
    last_vsync: bool = true,

    fn setFullscreen(context: *anyopaque, value: bool) anyerror!void {
        const self: *FakeDisplay = @ptrCast(@alignCast(context));
        self.fullscreen_calls += 1;
        self.last_fullscreen = value;
        if (self.fail_fullscreen) return error.DisplayModeUnavailable;
        self.fullscreen = value;
    }

    fn setVsync(context: *anyopaque, value: bool) anyerror!void {
        const self: *FakeDisplay = @ptrCast(@alignCast(context));
        self.vsync_calls += 1;
        self.last_vsync = value;
        if (self.fail_vsync) return error.DisplayModeUnavailable;
        self.vsync = value;
    }

    fn sink(self: *FakeDisplay) recovery_mod.PreferenceSink {
        return .{ .context = self, .set_fullscreen = setFullscreen, .set_vsync = setVsync };
    }
};

fn armored(r: *recovery_mod.Recovery) void {
    r.focus(true);
    _ = r.frame(.{});
    std.debug.assert(r.input.armed);
}

fn confirmFrames(r: *recovery_mod.Recovery, count: usize) u32 {
    var seen: u32 = 0;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const out = r.frame(.{ .confirm = true, .cancel = true, .menu = true, .direction = .down, .navigation = .down });
        if (out.confirm) seen += 1;
        if (out.cancel or out.menu or out.direction != null or out.navigation != null) {
            std.debug.panic("a held transition leaked a non-confirm action on frame {d}", .{index});
        }
    }
    return seen;
}

// ---------------------------------------------------------------------------
// Focus, held inputs and controller reconnect.
// ---------------------------------------------------------------------------

test "focus loss and regain never turns a held confirm into an ordinary press" {
    var r: recovery_mod.Recovery = .{};
    _ = r.begin(.field);
    armored(&r);

    var out = r.frame(.{ .confirm = true });
    try expect(out.confirm);

    r.focus(false);
    out = r.frame(.{ .confirm = true, .direction = .down });
    try expect(!out.confirm);
    try expect(out.direction == null);

    r.focus(true);
    try expectEqual(@as(u32, 0), confirmFrames(&r, 3));

    // Releasing is what re-arms the gate; only then does a new press count.
    _ = r.frame(.{});
    out = r.frame(.{ .confirm = true });
    try expect(out.confirm);
    try expect(r.report().suppressed_confirms >= 4);
}

test "a direction held across focus loss is released before movement resumes" {
    var r: recovery_mod.Recovery = .{};
    _ = r.begin(.field);
    armored(&r);

    var out = r.frame(.{ .direction = .down, .navigation = .down });
    try expect(out.direction == .down);
    try expect(out.navigation == .down);

    r.focus(false);
    r.focus(true);
    out = r.frame(.{ .direction = .down, .navigation = .down });
    try expect(out.direction == null);
    try expect(out.navigation == null);
    try expect(r.report().suppressed_directions >= 1);

    _ = r.frame(.{});
    out = r.frame(.{ .direction = .down, .navigation = .down });
    try expect(out.direction == .down);
}

test "a mode change closes the gate and drops the held frame" {
    var r: recovery_mod.Recovery = .{};
    _ = r.begin(.field);
    armored(&r);
    _ = r.frame(.{ .confirm = true, .direction = .right });

    const entry = r.begin(.menu);
    try expect(entry.changed);
    try expect(entry.released_held);
    try expectEqual(recovery_mod.Mode.menu, entry.current);

    try expectEqual(@as(u32, 0), confirmFrames(&r, 2));
    _ = r.frame(.{});
    const after = r.frame(.{ .confirm = true });
    try expect(after.confirm);
}

test "repeating the same mode is idempotent and does not swallow input" {
    var r: recovery_mod.Recovery = .{};
    _ = r.begin(.field);
    armored(&r);
    _ = r.frame(.{ .direction = .left, .navigation = .left });
    const changes = r.input.counters.mode_changes;
    const acquisitions = r.input.lease.acquisitions;

    var index: usize = 0;
    while (index < 1000) : (index += 1) {
        const entry = r.begin(.field);
        try expect(!entry.changed);
    }
    try expectEqual(changes, r.input.counters.mode_changes);
    try expectEqual(acquisitions, r.input.lease.acquisitions);

    const out = r.frame(.{ .direction = .left, .navigation = .left });
    try expect(out.direction == .left);
}

test "repeated mode changes keep exactly one logical lease and no held action" {
    var r: recovery_mod.Recovery = .{};
    _ = r.begin(.field);
    armored(&r);
    const first = r.input.lease.acquisitions - r.input.lease.releases;

    var index: usize = 0;
    var leaked_confirms: u32 = 0;
    while (index < 2000) : (index += 1) {
        const next: recovery_mod.Mode = if (index % 2 == 0) .menu else .battle;
        _ = r.begin(next);
        leaked_confirms += confirmFrames(&r, 1);
    }
    const outstanding = r.input.lease.acquisitions - r.input.lease.releases;
    try expectEqual(@as(u32, 1), outstanding);
    try expectEqual(first, outstanding);
    try expect(r.input.lease.held);
    try expectEqual(@as(u32, 0), leaked_confirms);
    try expect(r.input.counters.suppressed_confirms >= 2000);
}

test "repeated controller reconnects leak no confirm and keep no stale device" {
    var r: recovery_mod.Recovery = .{};
    _ = r.begin(.field);
    armored(&r);
    r.device(true, 0);

    var leaks: u32 = 0;
    var index: usize = 0;
    while (index < 500) : (index += 1) {
        r.device(false, null);
        leaks += confirmFrames(&r, 1);
        r.device(true, @intCast(index % 4));
        leaks += confirmFrames(&r, 1);
        if (index % 3 == 0) _ = r.frame(.{});
    }
    try expectEqual(@as(u32, 0), leaks);
    try expectEqual(@as(u32, 1), r.input.lease.acquisitions - r.input.lease.releases);
    const report = r.report();
    try expectEqual(@as(usize, 0), report.audio_leases);
    try expect(report.reconnects >= 500);
    try expect(report.device_present);
}

test "an unchanged device id every frame never closes the gate" {
    var r: recovery_mod.Recovery = .{};
    _ = r.begin(.field);
    armored(&r);
    r.device(true, 3);
    _ = r.frame(.{});
    var index: usize = 0;
    while (index < 200) : (index += 1) {
        r.device(true, 3);
        const out = r.frame(.{ .confirm = true });
        try expect(out.confirm);
    }
}

test "the gate never fabricates an action the adapter did not report" {
    var r: recovery_mod.Recovery = .{};
    _ = r.begin(.field);
    armored(&r);
    const input: controller.Output = .{ .direction = .left, .cancel = true, .physical_up = true };
    const forwarded = r.frame(input);
    try expectEqual(input.direction, forwarded.direction);
    try expect(forwarded.cancel);
    try expect(forwarded.physical_up);
    const neutral: controller.Output = .{};
    try expect(recovery_mod.input.isNeutral(r.frame(neutral)));
}

// ---------------------------------------------------------------------------
// Audio availability.
// ---------------------------------------------------------------------------

test "an unavailable audio device is a waiver with one coalesced pending cue" {
    var fake: FakeAudio = .{};
    var r: recovery_mod.Recovery = .{};
    r.attachAudio(fake.backend());
    r.setAudioReady(false);

    var out = r.cue(0x81);
    try expectEqual(recovery_mod.audio.Result.waived, out.result);
    try expect(out.track == null);
    try expect(out.pending);
    try expect(out.diagnostic.?.message.len > 20);
    try expect(std.mem.indexOf(u8, out.diagnostic.?.message, "waiver") != null);

    out = r.cue(0x422);
    try expectEqual(recovery_mod.audio.Result.waived, out.result);
    try expect(out.track == null);
    try expectEqual(@as(u32, 1), r.audio.counters.coalesced);
    try expectEqual(@as(u32, 0), fake.play_count);
    try expectEqual(@as(usize, 0), r.audio.deviceLeases());
}

test "a restored device applies the pending cue exactly once" {
    var fake: FakeAudio = .{};
    var r: recovery_mod.Recovery = .{};
    r.attachAudio(fake.backend());
    r.setAudioReady(false);
    _ = r.cue(0x422);
    _ = r.cue(0x81);

    r.setAudioReady(true);
    var out = r.retryAudio();
    try expectEqual(recovery_mod.audio.Result.applied, out.result);
    try expectEqual(recovery_mod.audio.Id.palace, out.track.?);
    try expectEqual(@as(usize, 1), fake.play_count);
    try expectEqual(recovery_mod.audio.Id.palace, fake.plays[0]);
    try expect(r.audio.pending == null);

    out = r.retryAudio();
    try expectEqual(recovery_mod.audio.Result.unchanged, out.result);
    try expectEqual(@as(usize, 1), fake.play_count);
}

test "a failed stream start rolls the logical track back and stays retryable" {
    var fake: FakeAudio = .{};
    fake.fail_plays = 1;
    var r: recovery_mod.Recovery = .{};
    r.attachAudio(fake.backend());
    r.setAudioReady(true);

    var out = r.cue(0x81);
    try expectEqual(recovery_mod.audio.Result.retryable, out.result);
    try expect(out.track == null);
    try expect(out.pending);
    try expectEqual(@as(u32, 0), r.audio.counters.plays);
    try expectEqual(@as(usize, 0), r.audio.deviceLeases());
    try expect(std.mem.indexOf(u8, r.lastDiagnostic().?.message, "retryable") != null);

    out = r.retryAudio();
    try expectEqual(recovery_mod.audio.Result.applied, out.result);
    try expectEqual(recovery_mod.audio.Id.palace, out.track.?);
    try expectEqual(@as(usize, 1), fake.play_count);
}

test "device loss stops one stream, keeps the logical track and resumes it" {
    var fake: FakeAudio = .{};
    var r: recovery_mod.Recovery = .{};
    r.attachAudio(fake.backend());
    r.setAudioReady(true);
    var out = r.cue(0x81);
    try expectEqual(recovery_mod.audio.Result.applied, out.result);

    r.setAudioReady(false);
    r.setAudioReady(false);
    try expectEqual(@as(usize, 1), fake.stop_count);
    try expectEqual(@as(usize, 0), r.audio.deviceLeases());
    try expectEqual(recovery_mod.audio.Id.palace, r.audio.state.track.?);

    r.setAudioReady(true);
    out = r.resumeAudio();
    try expectEqual(recovery_mod.audio.Result.applied, out.result);
    try expectEqual(@as(usize, 2), fake.play_count);
    try expectEqual(@as(usize, 1), r.audio.deviceLeases());
}

test "detach stops the owned stream once and is idempotent" {
    var fake: FakeAudio = .{};
    var r: recovery_mod.Recovery = .{};
    r.attachAudio(fake.backend());
    r.setAudioReady(true);
    _ = r.cue(0x81);
    r.detachAudio();
    r.detachAudio();
    try expectEqual(@as(usize, 1), fake.stop_count);
    try expect(!r.audio.ready);
    try expectEqual(@as(usize, 0), r.audio.deviceLeases());
}

test "an unknown cue changes neither the track nor the pending request" {
    var r: recovery_mod.Recovery = .{};
    const out = r.cue(0x777);
    try expectEqual(recovery_mod.audio.Result.unchanged, out.result);
    try expect(!out.pending and r.audio.pending == null);
    try expect(r.audio.state.track == null);
}

// ---------------------------------------------------------------------------
// Display scaling.
// ---------------------------------------------------------------------------

const LegacyLayout = struct { scale: i32, x: i32, y: i32, width: i32, height: i32 };

fn legacyInteger(canvas_width: i32, canvas_height: i32, top: i32, window_width: i32, window_height: i32) LegacyLayout {
    const scale = @max(1, @min(@divTrunc(window_width, canvas_width), @divTrunc(window_height - top, canvas_height)));
    const width = canvas_width * scale;
    const height = canvas_height * scale;
    return .{
        .scale = scale,
        .x = @divTrunc(window_width - width, 2),
        .y = top + @divTrunc(window_height - top - height, 2),
        .width = width,
        .height = height,
    };
}

fn expectLayout(canvas: recovery_mod.Canvas, window: recovery_mod.Window, legacy: LegacyLayout) !void {
    const actual = try recovery_mod.display.resolve(canvas, window);
    try expectEqual(legacy.scale, actual.scale);
    try expectEqual(legacy.x, actual.x);
    try expectEqual(legacy.y, actual.y);
    try expectEqual(legacy.width, actual.width);
    try expectEqual(legacy.height, actual.height);
}

test "supported field scaling matches the current loop formula exactly" {
    const widths = [_]i32{ 512, 513, 640, 800, 1023, 1024, 1280, 1440, 1920, 2560, 3840 };
    const heights = [_]i32{ 432, 433, 528, 720, 768, 864, 1008, 1080, 1440, 2160 };
    for (widths) |width| {
        for (heights) |height| {
            try expectLayout(.field, .{ .width = width, .height = height }, legacyInteger(512, 432, 0, width, height));
        }
    }
}

test "supported journey and battle scaling matches the current loop formula" {
    const widths = [_]i32{ 640, 641, 800, 960, 1280, 1600, 1920, 2560 };
    const heights = [_]i32{ 480, 481, 600, 720, 960, 1080, 1440 };
    for (widths) |width| {
        for (heights) |height| {
            try expectLayout(.journey, .{ .width = width, .height = height }, legacyInteger(640, 480, 0, width, height));
            try expectLayout(.battle, .{ .width = width, .height = height }, legacyInteger(640, 480, 0, width, height));
        }
    }
}

test "supported replay scaling matches the current HUD-reserved formula" {
    const widths = [_]i32{ 640, 641, 959, 960, 1280, 1920, 2560 };
    const heights = [_]i32{ 528, 529, 720, 800, 1008, 1080, 1440 };
    for (widths) |width| {
        for (heights) |height| {
            try expectLayout(.replay_world, .{ .width = width, .height = height }, legacyInteger(320, 240, 48, width, height));
            try expectLayout(.replay_field, .{ .width = width, .height = height }, legacyInteger(512, 432, 48, width, height));
        }
    }
}

test "unsupported window sizes are typed errors instead of a clipped 1x frame" {
    try expectError(error.UnsupportedWindowSize, recovery_mod.display.resolve(.field, .{ .width = 511, .height = 432 }));
    try expectError(error.UnsupportedWindowSize, recovery_mod.display.resolve(.field, .{ .width = 1280, .height = 431 }));
    try expectError(error.UnsupportedWindowSize, recovery_mod.display.resolve(.journey, .{ .width = 639, .height = 480 }));
    try expectError(error.UnsupportedWindowSize, recovery_mod.display.resolve(.replay_field, .{ .width = 640, .height = 527 }));
    try expectError(error.InvalidWindowSize, recovery_mod.display.resolve(.field, .{ .width = 0, .height = 432 }));
    try expectError(error.InvalidWindowSize, recovery_mod.display.resolve(.field, .{ .width = -1, .height = 432 }));
    try expectError(error.InvalidWindowSize, recovery_mod.display.resolve(.field, .{ .width = 16385, .height = 432 }));
}

test "an unsupported transient window keeps the last valid layout" {
    var policy: recovery_mod.display.Policy = .{};
    const first = policy.layout(.field, .{ .width = 1024, .height = 864 });
    try expectEqual(@as(i32, 2), first.scale);
    const kept = policy.layout(.field, .{ .width = 200, .height = 200 });
    try std.testing.expectEqualDeep(first, kept);
    try expectEqual(@as(u32, 1), policy.invalid_frames);
    try expect(policy.last_error != null);
    const recovered = policy.layout(.field, .{ .width = 1536, .height = 1296 });
    try expectEqual(@as(i32, 3), recovered.scale);
    try expect(policy.last_error == null);
}

test "fullscreen and vsync apply through the sink or roll back together" {
    var fake: FakeDisplay = .{};
    const current: recovery_mod.SettingsValue = .{};
    const next: recovery_mod.SettingsValue = .{ .fullscreen = true, .vsync = false };
    const ok = recovery_mod.display.applyPreferences(current, next, fake.sink());
    try expect(ok.changed);
    try expect(ok.value.fullscreen and !ok.value.vsync);
    try expect(fake.fullscreen and !fake.vsync);

    var failing: FakeDisplay = .{ .fail_vsync = true };
    const rejected = recovery_mod.display.applyPreferences(current, next, failing.sink());
    try expect(!rejected.changed);
    try std.testing.expectEqualDeep(current, rejected.value);
    try expect(rejected.diagnostic.?.code == .vsync_rejected);
    try expect(!failing.fullscreen);
    try expect(std.mem.indexOf(u8, rejected.diagnostic.?.message, "previous display state") != null);

    var failing_fullscreen: FakeDisplay = .{ .fail_fullscreen = true };
    const first = recovery_mod.display.applyPreferences(current, next, failing_fullscreen.sink());
    try expect(!first.changed);
    try std.testing.expectEqualDeep(current, first.value);
    try expect(first.diagnostic.?.code == .fullscreen_rejected);
}

test "an unchanged or invalid settings value makes no platform call" {
    var fake: FakeDisplay = .{};
    const current: recovery_mod.SettingsValue = .{};
    const same = recovery_mod.display.applyPreferences(current, current, fake.sink());
    try expect(!same.changed);
    try expectEqual(@as(u32, 0), fake.fullscreen_calls + fake.vsync_calls);

    const invalid: recovery_mod.SettingsValue = .{ .music = 11 };
    const rejected = recovery_mod.display.applyPreferences(current, invalid, fake.sink());
    try expect(!rejected.changed);
    try std.testing.expectEqualDeep(current, rejected.value);
    try expect(rejected.diagnostic.?.code == .unsupported_settings);
    try expectEqual(@as(u32, 0), fake.fullscreen_calls + fake.vsync_calls);
}

// ---------------------------------------------------------------------------
// Contract and diagnostics.
// ---------------------------------------------------------------------------

const CanvasContract = struct {
    id: []const u8,
    width: i32,
    height: i32,
    top: i32,
    min_width: i32,
    min_height: i32,
};

const Contract = struct {
    schema: []const u8,
    pack: []const u8,
    modes: []const []const u8,
    input: struct {
        ownership: []const u8,
        rearm: []const u8,
        suppressed_actions: []const []const u8,
    },
    audio: struct {
        unavailable: []const u8,
        pending_slots: u8,
        device_streams: u8,
        cue_values: []const u16,
    },
    display: struct {
        scale: []const u8,
        centering: []const u8,
        window_limit: i32,
        canvases: []const CanvasContract,
        opening_overlay: []const u8,
    },
    native: struct {
        visual_acceptance: bool,
        device_acceptance: bool,
        reason: []const u8,
    },
};

test "the platform contract matches the compiled recovery policy" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "game/assets/package_host/platform_contract.json", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Contract, std.testing.allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const contract = parsed.value;

    try expectEqualStrings("suikoden-platform-contract/1", contract.schema);
    try expectEqualStrings("platform_contract", contract.pack);

    const mode_fields = @typeInfo(recovery_mod.Mode).@"enum".field_names;
    try expectEqual(mode_fields.len, contract.modes.len);
    for (contract.modes, 0..) |name, index| {
        const value: recovery_mod.Mode = @fromBackingInt(@intCast(index));
        try expectEqualStrings(@tagName(value), name);
    }

    try expect(std.mem.indexOf(u8, contract.input.rearm, "neutral") != null);
    try expectEqual(@as(usize, 5), contract.input.suppressed_actions.len);
    try expectEqualStrings("waiver, not a mode stop", contract.audio.unavailable);
    try expectEqual(@as(u8, 1), contract.audio.pending_slots);
    try expectEqual(@as(u8, 1), contract.audio.device_streams);
    try expectEqual(@as(usize, 3), contract.audio.cue_values.len);
    try expectEqualStrings("integer", contract.display.scale);
    try expectEqualStrings("truncated", contract.display.centering);
    try expectEqual(recovery_mod.display.window_limit, contract.display.window_limit);
    try expect(!contract.native.visual_acceptance);
    try expect(!contract.native.device_acceptance);

    const canvases = [_]recovery_mod.Canvas{ .field, .journey, .battle, .replay_world, .replay_field };
    try expectEqual(canvases.len, contract.display.canvases.len);
    for (canvases, 0..) |canvas, index| {
        const spec = recovery_mod.display.spec(canvas);
        const row = contract.display.canvases[index];
        try expectEqualStrings(@tagName(canvas), row.id);
        try expectEqual(spec.width, row.width);
        try expectEqual(spec.height, row.height);
        try expectEqual(spec.top, row.top);
        try expectEqual(spec.min_width, row.min_width);
        try expectEqual(spec.min_height, row.min_height);
    }
}

test "ownership errors stay readable and change no state" {
    var r: recovery_mod.Recovery = .{};
    _ = r.begin(.field);
    try expectError(error.InputOwned, r.claim(.menu));
    try expectEqual(recovery_mod.Mode.field, r.input.lease.owner);
    try expect(std.mem.indexOf(u8, r.lastDiagnostic().?.message, "already owned") != null);
    try expectError(error.NotInputOwner, r.release(.battle));
    try expect(r.input.lease.held);
    try r.release(.field);
    try expect(!r.input.lease.held);
}

test "a full transition sequence reports no leaked confirm or device lease" {
    var fake: FakeAudio = .{};
    var r: recovery_mod.Recovery = .{};
    r.attachAudio(fake.backend());
    _ = r.begin(.title);
    armored(&r);
    _ = r.cue(0x81);
    r.setAudioReady(false);

    var leaks: u32 = 0;
    const sequence = [_]recovery_mod.Mode{ .opening, .field, .menu, .dialogue, .battle, .ending, .title, .field };
    for (sequence) |next| {
        _ = r.begin(next);
        leaks += confirmFrames(&r, 2);
        _ = r.frame(.{});
        r.focus(false);
        leaks += confirmFrames(&r, 1);
        r.focus(true);
        leaks += confirmFrames(&r, 1);
    }
    try expectEqual(@as(u32, 0), leaks);
    try expectEqual(@as(u32, 1), r.input.lease.acquisitions - r.input.lease.releases);
    try expectEqual(@as(usize, 0), r.report().audio_leases);
    try expect(r.report().audio_waived >= 1);
}

test "diagnostics map every typed failure to a readable message" {
    const codes = [_]recovery_mod.diagnostic.Code{
        .input_owned,
        .not_input_owner,
        .invalid_owner,
        .invalid_window_size,
        .unsupported_window_size,
        .fullscreen_rejected,
        .vsync_rejected,
        .unsupported_settings,
        .audio_device_unavailable,
        .audio_stream_unavailable,
    };
    for (codes) |code| {
        const value = recovery_mod.diagnostic.of(code);
        try expect(value.message.len >= 24);
        try expect(std.mem.endsWith(u8, value.message, "."));
    }
}
