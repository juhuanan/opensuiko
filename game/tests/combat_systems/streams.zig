//! Stream lifecycle focused checks: the three proven STR stream mode lifecycles.
//!
//! The cases verify the acceptance facts, not a walkthrough:
//!   * the asset validates, keeps its blocked rows and its disclosures, and
//!     names the derived block/frame/audio counts of all three streams;
//!   * frame requests fall on the first video block of each frame and audio
//!     requests on each XA block, in disc order and on one integer clock;
//!   * a skip before the first frame latches until the state-2 poll, then fades
//!     for 15 frames; a skip during play fades from the next frame boundary;
//!   * a cancel ends the mode immediately, without the fade;
//!   * a torn input (schema, clock, frame count, blocked row, truncation) is
//!     refused instead of trusted;
//!   * the caller identity owns the return: the finish carries the caller id and
//!     its non-zero token unchanged, and unknown callers/zero tokens are refused;
//!   * teardown is bounded: close() drops queued work once, later work is
//!     refused and close()/deinit are idempotent.
//!
//! No original instruction is executed, no window is opened, no device or media
//! file is touched and no pixels are decoded.

const std = @import("std");
const streams_mod = @import("combat_systems").streams;
const data = @import("combat_systems_data").streams;

fn openPacket() !streams_mod.Opened {
    return streams_mod.open(std.testing.allocator, data.json);
}

fn streamOf(asset: *const streams_mod.Asset, id: []const u8) *const streams_mod.Stream {
    return streams_mod.streamById(asset, id) orelse unreachable;
}

const Drained = struct {
    frames: usize = 0,
    audio: usize = 0,
    finish: ?streams_mod.Finish = null,
    last_time: u64 = 0,
    monotonic: bool = true,
};

/// Tick and drain until a finish is delivered (or the guard trips).  The guard
/// is a test-side bound: a scheduler that never finishes fails the case.
fn runToFinish(session: *streams_mod.Session, dt_us: u64, guard: usize) !Drained {
    var out = Drained{};
    var rounds: usize = 0;
    while (rounds < guard) : (rounds += 1) {
        try session.tick(dt_us);
        while (session.next()) |outcome| {
            switch (outcome) {
                .frame => |event| {
                    out.frames += 1;
                    if (event.time_us < out.last_time) out.monotonic = false;
                    out.last_time = event.time_us;
                },
                .audio => |event| {
                    out.audio += 1;
                    if (event.time_us < out.last_time) out.monotonic = false;
                    out.last_time = event.time_us;
                },
                .finished => |finish| out.finish = finish,
            }
        }
        if (out.finish != null) return out;
        if (dt_us == 0) return error.NoProgress;
    }
    return error.GuardTripped;
}

fn replaced(allocator: std.mem.Allocator, json: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, json, needle) orelse return error.NeedleMissing;
    const out = try allocator.alloc(u8, json.len - needle.len + replacement.len);
    @memcpy(out[0..at], json[0..at]);
    @memcpy(out[at .. at + replacement.len], replacement);
    @memcpy(out[at + replacement.len ..], json[at + needle.len ..]);
    return out;
}

test "packet validates and keeps the derived stream counts" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();

    try std.testing.expectEqualStrings(streams_mod.schema, asset.schema);
    try std.testing.expectEqual(@as(usize, 3), asset.streams.len);
    try std.testing.expectEqual(@as(usize, 3), asset.callers.len);
    try std.testing.expect(asset.blocked.len >= 5);
    try std.testing.expect(asset.disclosures.len >= 5);
    try std.testing.expect(asset.player.anchors.len >= 30);

    const logo = streamOf(asset, "demo_logo");
    try std.testing.expectEqual(@as(u16, 143), logo.frames);
    try std.testing.expectEqual(@as(u32, 1432), logo.block_count);
    try std.testing.expectEqual(@as(u32, 1253), logo.video_blocks);
    try std.testing.expectEqual(@as(u32, 141), logo.audio_blocks);
    try std.testing.expectEqual(@as(u32, 38), logo.empty_blocks);
    try std.testing.expectEqual(@as(u32, 24), logo.iso_lba);
    try std.testing.expectEqual(@as(u32, 24), logo.first_video_offset);
    try std.testing.expectEqual(@as(u32, 1454), logo.last_video_offset);

    const opening = streamOf(asset, "demo_opening");
    try std.testing.expectEqual(@as(u16, 1647), opening.frames);
    try std.testing.expectEqual(@as(u32, 16519), opening.block_count);
    try std.testing.expectEqual(@as(u32, 14428), opening.video_blocks);
    try std.testing.expectEqual(@as(u32, 2064), opening.audio_blocks);
    try std.testing.expectEqual(@as(u32, 27), opening.empty_blocks);

    const montage = streamOf(asset, "open15mx");
    try std.testing.expectEqual(@as(u16, 1688), montage.frames);
    try std.testing.expectEqual(@as(u32, 16898), montage.block_count);
    try std.testing.expectEqual(@as(u32, 14786), montage.video_blocks);
    try std.testing.expectEqual(@as(u32, 2112), montage.audio_blocks);
    try std.testing.expectEqual(@as(u16, 2336), montage.block_size);
    try std.testing.expectEqual(@as(u32, 8), montage.first_video_offset);
    try std.testing.expectEqualStrings("file_byte_offset", montage.offset_kind);
}

test "frame and audio requests follow the disc's block order" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();
    const logo = streamOf(asset, "demo_logo");

    var session = try streams_mod.Session.begin(asset, "demo_logo", "site_a", 0xA11CE);
    try session.tick(0);

    // First frame at block 0 / LBA 24 with the disc's own video-block count.
    const first = session.next() orelse return error.MissingFrame;
    const frame_one = switch (first) {
        .frame => |event| event,
        else => return error.WrongFirstOutcome,
    };
    try std.testing.expectEqual(@as(u16, 1), frame_one.frame);
    try std.testing.expectEqual(@as(u16, 0), frame_one.block);
    try std.testing.expectEqual(@as(u32, 24), frame_one.offset);
    try std.testing.expectEqual(logo.frame_video_blocks[0], frame_one.video_blocks);
    try std.testing.expectEqual(@as(u64, 0), frame_one.time_us);

    // The first audio block is block 7 (LBA 31) and is due on its own block
    // time, not on a frame boundary.
    try session.tick(streams_mod.usForBlock(7));
    const audio = session.next() orelse return error.MissingAudio;
    const audio_seven = switch (audio) {
        .audio => |event| event,
        else => return error.WrongAudioOutcome,
    };
    try std.testing.expectEqual(@as(u16, 7), audio_seven.block);
    try std.testing.expectEqual(@as(u32, 31), audio_seven.offset);
    try std.testing.expectEqual(streams_mod.usForBlock(7), audio_seven.time_us);
    try std.testing.expectEqual(@as(u16, 0), audio_seven.frame);

    // Frame 2 starts on block 10; with the exact block clock its time is
    // 66666 us, three microseconds short of the nominal 66667 us frame period.
    try session.tick(streams_mod.usForBlock(10) - streams_mod.usForBlock(7));
    const second = session.next() orelse return error.MissingFrameTwo;
    const frame_two = switch (second) {
        .frame => |event| event,
        else => return error.WrongSecondOutcome,
    };
    try std.testing.expectEqual(@as(u16, 2), frame_two.frame);
    try std.testing.expectEqual(@as(u16, 10), frame_two.block);
    try std.testing.expectEqual(streams_mod.usForBlock(10), frame_two.time_us);
    try std.testing.expect(frame_two.time_us > frame_one.time_us);
}

test "natural end emits every frame and audio request once, in order" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();
    const logo = streamOf(asset, "demo_logo");

    var session = try streams_mod.Session.begin(asset, "demo_logo", "site_a", 1);
    const run = try runToFinish(&session, 100_000, 400);
    const finish = run.finish orelse return error.NoFinish;

    try std.testing.expectEqual(streams_mod.FinishReason.natural_end, finish.reason);
    try std.testing.expectEqual(@as(u16, logo.frames), finish.frames_presented);
    try std.testing.expectEqual(@as(u32, finish.audio_requests), logo.audio_blocks);
    try std.testing.expectEqual(@as(usize, logo.frames), run.frames);
    try std.testing.expectEqual(@as(usize, logo.audio_blocks), run.audio);
    try std.testing.expect(run.monotonic);
    try std.testing.expectEqual(@as(u32, finish.end_block), logo.block_count);
    try std.testing.expectEqual(@as(u8, 0), finish.fade_frames);
    try std.testing.expect(!finish.skipped_before_start);

    // A finished session refuses more work.
    try std.testing.expectError(error.SessionFinished, session.tick(1));
    try std.testing.expectError(error.SessionFinished, session.skip());
    try std.testing.expectError(error.SessionFinished, session.cancel());
    try std.testing.expect(session.next() == null);
    session.close();
}

test "skip before start latches to the first frame and fades 15 frames" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();

    var session = try streams_mod.Session.begin(asset, "demo_logo", "site_a", 0xB0B);
    try session.skip();
    try std.testing.expectError(error.SkipAlreadyRequested, session.skip());

    const run = try runToFinish(&session, 10_000, 200);
    const finish = run.finish orelse return error.NoFinish;

    try std.testing.expectEqual(streams_mod.FinishReason.skip, finish.reason);
    try std.testing.expect(finish.skipped_before_start);
    try std.testing.expectEqual(@as(u8, 15), finish.fade_frames);
    try std.testing.expectEqual(@as(u16, 15), finish.frames_presented);
    try std.testing.expectEqual(@as(usize, 15), run.frames);
    // The fade ends inside the first 15 frames, so most audio is never requested.
    try std.testing.expect(finish.audio_requests < 30);
    try std.testing.expect(finish.end_block <= 160);
    try std.testing.expect(run.monotonic);
}

test "skip during play fades from the next frame boundary" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();

    var session = try streams_mod.Session.begin(asset, "demo_opening", "site_b", 0xC0FFEE);
    // Play a few frames first.
    try session.tick(200_000);
    var played: usize = 0;
    while (session.next()) |outcome| {
        if (outcome == .frame) played += 1;
    }
    try std.testing.expect(played > 0);
    try session.skip();

    const run = try runToFinish(&session, 10_000, 200);
    const finish = run.finish orelse return error.NoFinish;
    try std.testing.expectEqual(streams_mod.FinishReason.skip, finish.reason);
    try std.testing.expect(!finish.skipped_before_start);
    try std.testing.expectEqual(@as(u8, 15), finish.fade_frames);
    // played + faded = frames presented; nothing beyond the fade is presented.
    try std.testing.expectEqual(@as(usize, 15), run.frames);
    try std.testing.expectEqual(@as(u16, 15 + @as(u16, @intCast(played))), finish.frames_presented);
}

test "cancel ends immediately without the fade" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();

    var session = try streams_mod.Session.begin(asset, "open15mx", "site_c", 0x5EED);
    try session.tick(100_000);
    var before: usize = 0;
    while (session.next()) |outcome| {
        if (outcome == .frame) before += 1;
    }
    try session.cancel();

    const outcome = session.next() orelse return error.NoFinish;
    const finish = switch (outcome) {
        .finished => |value| value,
        else => return error.WrongCancelOutcome,
    };
    try std.testing.expectEqual(streams_mod.FinishReason.cancelled, finish.reason);
    try std.testing.expectEqual(@as(u8, 0), finish.fade_frames);
    try std.testing.expectEqual(@as(usize, before), finish.frames_presented);
    try std.testing.expectEqualStrings("site_c", finish.caller);
    try std.testing.expectEqual(@as(u32, 0x5EED), finish.token);
    try std.testing.expect(session.next() == null);
    try std.testing.expectError(error.SessionFinished, session.cancel());
}

test "caller identity controls the returned receipt" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();

    const cases = [_]struct { caller: []const u8, stream: []const u8, token: u32 }{
        .{ .caller = "site_a", .stream = "demo_logo", .token = 0x1111 },
        .{ .caller = "site_b", .stream = "demo_opening", .token = 0x2222 },
        .{ .caller = "site_c", .stream = "open15mx", .token = 0x3333 },
    };
    for (cases) |case| {
        var session = try streams_mod.Session.begin(asset, case.stream, case.caller, case.token);
        try session.cancel();
        const outcome = session.next() orelse return error.NoFinish;
        const finish = switch (outcome) {
            .finished => |value| value,
            else => return error.WrongOutcome,
        };
        try std.testing.expectEqualStrings(case.caller, finish.caller);
        try std.testing.expectEqual(case.token, finish.token);
        try std.testing.expectEqual(streams_mod.FinishReason.cancelled, finish.reason);
        session.close();
    }

    try std.testing.expectError(
        error.UnknownCaller,
        streams_mod.Session.begin(asset, "demo_logo", "site_zz", 1),
    );
    try std.testing.expectError(
        error.MissingCallerToken,
        streams_mod.Session.begin(asset, "demo_logo", "site_a", 0),
    );
    try std.testing.expectError(
        error.CallerStreamMismatch,
        streams_mod.Session.begin(asset, "demo_opening", "site_a", 1),
    );
    try std.testing.expectError(
        error.UnknownStream,
        streams_mod.Session.begin(asset, "stream_fourth", "site_a", 1),
    );
}

test "a torn packet is refused instead of trusted" {
    const allocator = std.testing.allocator;

    {
        const json = try replaced(allocator, data.json, "suikoden-combat-streams/1", "bogus");
        defer allocator.free(json);
        try std.testing.expectError(error.UnsupportedSchema, streams_mod.open(allocator, json));
    }
    {
        const json = try replaced(allocator, data.json, "\"blocks_per_second\": 150", "\"blocks_per_second\": 120");
        defer allocator.free(json);
        try std.testing.expectError(error.InvalidClock, streams_mod.open(allocator, json));
    }
    {
        // The first stream's frame count is torn out of agreement with its arrays.
        const json = try replaced(allocator, data.json, "\"frames\": 143", "\"frames\": 142");
        defer allocator.free(json);
        try std.testing.expectError(error.InvalidFrameRange, streams_mod.open(allocator, json));
    }
    {
        // A blocked row is not optional evidence.
        const json = try replaced(allocator, data.json, "stream_caller_mapping", "stream_caller_mapping_x");
        defer allocator.free(json);
        try std.testing.expectError(error.BlockedRowMissing, streams_mod.open(allocator, json));
    }
    {
        // Truncation is a parse error, never a partial success.
        const json = data.json[0 .. data.json.len / 2];
        if (streams_mod.open(allocator, json)) |opened| {
            var value = opened;
            value.deinit();
            return error.TruncatedPacketAccepted;
        } else |_| {}
    }
}

test "teardown is bounded and idempotent" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();

    var session = try streams_mod.Session.begin(asset, "demo_logo", "site_a", 0xD00D);
    try session.tick(100_000);
    try std.testing.expect(session.pending() > 0);
    session.close();
    try std.testing.expect(session.isClosed());
    try std.testing.expectEqual(@as(usize, 0), session.pending());
    try std.testing.expect(session.next() == null);
    try std.testing.expectError(error.SessionClosed, session.tick(1));
    try std.testing.expectError(error.SessionClosed, session.skip());
    try std.testing.expectError(error.SessionClosed, session.cancel());
    session.close();
    session.close();
}

test "bounded work: a huge delta cannot emit without bound" {
    var opened = try openPacket();
    defer opened.deinit();
    const asset = opened.asset();

    var session = try streams_mod.Session.begin(asset, "open15mx", "site_c", 7);
    try session.tick(60_000_000); // ten minutes: every block is due
    try std.testing.expect(session.pending() <= streams_mod.max_events);
    try std.testing.expect(session.pending() > 0);

    // Drain and continue until the stream genuinely finishes.
    var finish: ?streams_mod.Finish = null;
    var rounds: usize = 0;
    while (rounds < 4096 and finish == null) : (rounds += 1) {
        while (session.next()) |outcome| {
            if (outcome == .finished) finish = outcome.finished;
        }
        if (finish == null) try session.tick(100_000);
    }
    try std.testing.expect(finish != null);
    try std.testing.expectEqual(streams_mod.FinishReason.natural_end, finish.?.reason);
    try std.testing.expectEqual(@as(u16, 1688), finish.?.frames_presented);
}
