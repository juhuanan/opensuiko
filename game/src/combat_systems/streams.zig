//! The three proven STR stream mode lifecycles, headless.
//!
//! The packet in the embedded campaign asset is produced by
//! the extraction pipeline from the disc's own bytes and from static
//! instruction/data words in `SLUS_002.92`.  This module is the runtime seam:
//! it validates the packet, then runs the recovered frontend movie mode as a
//! deterministic, bounded request scheduler.
//!
//! Source shape encoded here (all sites are in the packet and the report):
//!
//!   * the frontend movie mode is initialised at `0x8001785C` (it installs
//!     handler `0x800178D0`) and runs a five-state handler: 0 setup, 1 wait,
//!     2 play, 3 fade, 99 exit;
//!   * state 2 calls the per-frame decode/present entry `0x8001971C` and then
//!     polls the frontend input word `0x800AFE3C` with mask `0x841` once per
//!     frame (`0x800179F4`); a hit sets the fade countdown `0x800A4ED0` to 75
//!     (`0x80017A18`) and state 3;
//!   * state 3 subtracts 5 per frame (`0x80017A34`/`0x80017A3C`), so the fade
//!     lasts 15 frames, and ends with a final frame call whose second argument
//!     is 1 (`0x80017A78`);
//!   * the common tail then polls bit `0x800` of the same word
//!     (`0x80017AAC`) and, when set, clears the mode and returns -1 at once
//!     (`0x80017AB0`/`0x80017AC4`) -- cancel bypasses the fade;
//!   * teardown `0x80019998` resets MDEC, issues CD pause command 9 and frees
//!     the streaming ring.
//!
//! What this module does *not* do: it decodes no pixels, opens no window,
//! device or media file, and plays nothing.  A frame request names the disc
//! block range of one frame; an audio request names one XA block.  The caller
//! identity is a port seam: each caller carries a non-zero token that the
//! session returns unchanged with the finish reason.  The original scene ->
//! stream mapping and the original return targets are blocked rows in the
//! packet, not claims of this module.
//!
//! Scheduling: the disc's block grid is the clock.  The three streams carry
//! 10 blocks per frame on average (16898/1688, 16519/1647, 1432/143), i.e. 150
//! blocks per second (CD 2x sector cadence) and 66666.67 us per block.  A frame
//! request is due on its first video block, an audio request on its XA block,
//! so the request order is the disc's own order.  `usForBlock` is the single
//! integer rule; no floating point is involved.

const std = @import("std");
const validation = @import("validation");

pub const schema = "suikoden-combat-streams/1";
pub const max_events = 32;
pub const max_tick_blocks = 4096;
/// One disc block is 1/150 s = 6666.67 us; keep the exact ratio as integers.
pub const block_us_num: u64 = 20000;
pub const block_us_den: u64 = 3;

pub const Clock = struct {
    block_us: u32,
    blocks_per_second: u16,
    frame_us: u32,
    video_fps: u8,
    derivation: []const u8,
};

pub const Anchor = struct {
    addr: []const u8,
    word: []const u8,
    note: []const u8,
};

pub const StateRow = struct {
    state: u16,
    role: []const u8,
};

pub const StateEntry = struct {
    site: []const u8,
    word: []const u8,
    states: []const StateRow,
};

pub const SiteWord = struct {
    site: []const u8,
    word: []const u8,
};

pub const Skip = struct {
    poll_site: []const u8,
    poll_word: []const u8,
    input_word: []const u8,
    input_site: []const u8,
    mask: []const u8,
    countdown_site: []const u8,
    countdown: u8,
    decrement_site: []const u8,
    decrement: u8,
    fade_frames: u8,
    poll_state: u8,
    final_frame_site: []const u8,
    final_frame_flag: u8,
};

pub const Cancel = struct {
    site: []const u8,
    poll_word: []const u8,
    mask: []const u8,
    action: []const u8,
    precedence: []const u8,
};

pub const Teardown = struct {
    stop_entry: []const u8,
    mdec_reset_site: []const u8,
    pause_site: []const u8,
    ring_free_site: []const u8,
};

pub const Player = struct {
    file: []const u8,
    lba: u32,
    size: u32,
    image_base: []const u8,
    sha256: []const u8,
    state_entry: StateEntry,
    frame_entry: SiteWord,
    stop_entry: SiteWord,
    skip: Skip,
    cancel: Cancel,
    teardown: Teardown,
    anchors: []const Anchor,
};

pub const Caller = struct {
    id: []const u8,
    declared_role: []const u8,
    stream_id: []const u8,
    source_caller: []const u8,
    return_kind: []const u8,
    evidence: []const u8,
};

pub const Blocked = struct {
    id: []const u8,
    reason: []const u8,
};

pub const Stream = struct {
    id: []const u8,
    source_path: []const u8,
    storage: []const u8,
    iso_lba: u32,
    iso_size: u32,
    unit: []const u8,
    block_size: u16,
    payload_offset: u16,
    payload_bytes: u16,
    block_count: u32,
    video_blocks: u32,
    audio_blocks: u32,
    empty_blocks: u32,
    offset_kind: []const u8,
    frames: u16,
    first_frame: u16,
    last_frame: u16,
    width: u16,
    height: u16,
    video_fps: u8,
    first_video_offset: u32,
    last_video_offset: u32,
    frame_start_block: []const u16,
    frame_last_block: []const u16,
    frame_video_blocks: []const u8,
    frame_first_offset: []const u32,
    audio_block: []const u16,
    audio_offset: []const u32,
    empty_block: []const u16,
    trailing_audio_blocks: u32,
    content_sha256: []const u8,
    decode_note: []const u8,
    link_bytes: ?u16 = null,
    source_sectors: ?u32 = null,
};

pub const Asset = struct {
    schema: []const u8,
    target: []const u8,
    base_snapshot: []const u8,
    producer: []const u8,
    clock: Clock,
    player: Player,
    callers: []const Caller,
    streams: []const Stream,
    blocked: []const Blocked,
    disclosures: []const []const u8,
};

pub const Opened = struct {
    parsed: std.json.Parsed(Asset),

    pub fn deinit(self: *Opened) void {
        self.parsed.deinit();
    }

    pub fn asset(self: *const Opened) *const Asset {
        return &self.parsed.value;
    }
};

/// Parse and validate one packet.  A packet that has lost its blocked rows,
/// its disclosures, a stream array or the skip/cancel contract is refused
/// rather than trusted.
pub fn open(allocator: std.mem.Allocator, json: []const u8) !Opened {
    const parsed = try std.json.parseFromSlice(Asset, allocator, json, .{
        .ignore_unknown_fields = true,
    });
    var opened = Opened{ .parsed = parsed };
    errdefer opened.deinit();
    try validate(opened.asset());
    return opened;
}

pub fn streamById(asset: *const Asset, id: []const u8) ?*const Stream {
    for (asset.streams) |*stream| if (std.mem.eql(u8, stream.id, id)) return stream;
    return null;
}

pub fn callerById(asset: *const Asset, id: []const u8) ?*const Caller {
    for (asset.callers) |*caller| if (std.mem.eql(u8, caller.id, id)) return caller;
    return null;
}

fn validId(id: []const u8) bool {
    return validation.isAsciiId(id, 63, "_-");
}

fn validHash(hash: []const u8) bool {
    return validation.isHex64(hash);
}

fn hasBlocked(asset: *const Asset, id: []const u8) bool {
    for (asset.blocked) |row| if (std.mem.eql(u8, row.id, id)) return true;
    return false;
}

fn ascending(blocks: []const u16) bool {
    var previous: u16 = 0;
    var first = true;
    for (blocks) |block| {
        if (!first and block <= previous) return false;
        previous = block;
        first = false;
    }
    return true;
}

fn ascendingU32(values: []const u32) bool {
    var previous: u32 = 0;
    var first = true;
    for (values) |value| {
        if (!first and value <= previous) return false;
        previous = value;
        first = false;
    }
    return true;
}

/// The single integer rule turning a disc block index into microseconds.
/// 20000/3 us per block is 150 blocks per second; frames fall on the first
/// video block of the frame, so no second clock is invented.
pub fn usForBlock(block: u32) u64 {
    return (@as(u64, block) * block_us_num) / block_us_den;
}

pub fn validate(asset: *const Asset) !void {
    if (!std.mem.eql(u8, asset.schema, schema)) return error.UnsupportedSchema;
    if (asset.base_snapshot.len != 40) return error.InvalidBaseSnapshot;
    if (asset.streams.len != 3) return error.WrongStreamCount;
    if (asset.callers.len != 3) return error.WrongCallerCount;
    if (asset.blocked.len < 5) return error.BlockedRowsDropped;
    if (asset.disclosures.len < 5) return error.DisclosuresDropped;
    if (asset.player.anchors.len < 30) return error.AnchorsDropped;

    // Clock: the packet must not be able to change the cadence under the
    // scheduler's feet.
    if (asset.clock.blocks_per_second != 150) return error.InvalidClock;
    if (asset.clock.video_fps != 15) return error.InvalidClock;
    if (asset.clock.frame_us != 66667) return error.InvalidClock;

    // The lifecycle contract is the behavioural claim; a packet that drops a
    // mask or the fade count is refused.
    if (!std.mem.eql(u8, asset.player.skip.mask, "0x841")) return error.SkipContractMissing;
    if (!std.mem.eql(u8, asset.player.cancel.mask, "0x800")) return error.CancelContractMissing;
    if (asset.player.skip.countdown != 75) return error.SkipContractMissing;
    if (asset.player.skip.decrement != 5) return error.SkipContractMissing;
    if (asset.player.skip.fade_frames != 15) return error.SkipContractMissing;
    if (asset.player.skip.final_frame_flag != 1) return error.SkipContractMissing;
    if (asset.player.skip.poll_state != 2) return error.SkipContractMissing;
    if (!std.mem.eql(u8, asset.player.teardown.stop_entry, "0x80019998")) {
        return error.TeardownContractMissing;
    }

    for (asset.streams) |*stream| {
        if (!validId(stream.id)) return error.InvalidStreamId;
        if (!std.mem.eql(u8, stream.unit, "cd_sector") and
            !std.mem.eql(u8, stream.unit, "file_block"))
        {
            return error.InvalidUnit;
        }
        if (!std.mem.eql(u8, stream.offset_kind, "lba") and
            !std.mem.eql(u8, stream.offset_kind, "file_byte_offset"))
        {
            return error.InvalidOffsetKind;
        }
        if (stream.block_size != 2352 and stream.block_size != 2336) return error.InvalidBlockSize;
        if (stream.payload_bytes != 2328) return error.InvalidPayload;
        if (stream.width != 320 or stream.height != 240) return error.InvalidGeometry;
        if (stream.video_fps != 15) return error.InvalidFrameRate;
        if (!validHash(stream.content_sha256)) return error.InvalidContentHash;
        if (stream.frames == 0) return error.EmptyStream;
        if (stream.first_frame != 1 or stream.last_frame != stream.frames) {
            return error.InvalidFrameRange;
        }
        if (stream.block_count != stream.video_blocks + stream.audio_blocks + stream.empty_blocks) {
            return error.BlockCountMismatch;
        }
        if (stream.frame_start_block.len != stream.frames) return error.FrameArrayMismatch;
        if (stream.frame_last_block.len != stream.frames) return error.FrameArrayMismatch;
        if (stream.frame_video_blocks.len != stream.frames) return error.FrameArrayMismatch;
        if (stream.frame_first_offset.len != stream.frames) return error.FrameArrayMismatch;
        if (stream.audio_block.len != stream.audio_blocks) return error.AudioArrayMismatch;
        if (stream.audio_offset.len != stream.audio_blocks) return error.AudioArrayMismatch;
        if (stream.empty_block.len != stream.empty_blocks) return error.EmptyArrayMismatch;
        if (!ascending(stream.frame_start_block)) return error.FrameOrderInvalid;
        if (!ascending(stream.audio_block)) return error.AudioOrderInvalid;
        if (!ascending(stream.empty_block)) return error.EmptyOrderInvalid;
        if (!ascendingU32(stream.audio_offset)) return error.AudioOffsetInvalid;

        var video_sum: u32 = 0;
        var max_block: u16 = 0;
        for (stream.frame_start_block, 0..) |start, index| {
            const last = stream.frame_last_block[index];
            const count = stream.frame_video_blocks[index];
            if (last < start) return error.FrameSpanInvalid;
            if (count == 0 or count > stream.block_count) return error.FrameCountInvalid;
            if (start >= stream.block_count or last >= stream.block_count) return error.FrameBlockInvalid;
            video_sum += count;
            max_block = @max(max_block, last);
        }
        if (video_sum != stream.video_blocks) return error.VideoSumMismatch;
        var trailing: u32 = 0;
        for (stream.audio_block) |block| {
            if (block > max_block) trailing += 1;
        }
        if (trailing != stream.trailing_audio_blocks) return error.TrailingAudioMismatch;
        if (stream.first_video_offset != stream.frame_first_offset[0]) {
            return error.VideoOffsetMismatch;
        }
        if (std.mem.eql(u8, stream.storage, "file_stream")) {
            if (stream.block_size != 2336) return error.InvalidBlockSize;
            if (stream.link_bytes != 8) return error.InvalidBlockSize;
            if (stream.first_video_offset != stream.payload_offset + stream.block_size *
                stream.frame_start_block[0])
            {
                return error.VideoOffsetMismatch;
            }
        } else {
            if (stream.block_size != 2352) return error.InvalidBlockSize;
            if (stream.payload_offset != 24) return error.InvalidPayload;
        }
    }
    inline for ([_][]const u8{
        "stream_caller_mapping",
        "original_return_targets",
        "mdec_pixel_decode",
        "xa_audio_playback",
        "engine_scripted_scenes",
    }) |row| {
        if (!hasBlocked(asset, row)) return error.BlockedRowMissing;
    }
    for (asset.callers) |caller| {
        if (!validId(caller.id)) return error.InvalidCallerId;
        if (!std.mem.eql(u8, caller.return_kind, "caller_token")) return error.AdmissionInvalid;
        if (!std.mem.eql(u8, caller.source_caller, "unresolved")) return error.AdmissionInvalid;
        if (streamById(asset, caller.stream_id) == null) return error.UnknownCallerStream;
    }
    // Streams are unique.
    for (asset.streams, 0..) |a, i| {
        for (asset.streams[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.id, b.id)) return error.DuplicateStream;
        }
    }
    // Callers are unique and cover every stream exactly once.
    for (asset.callers, 0..) |a, i| {
        for (asset.callers[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.id, b.id)) return error.DuplicateCaller;
        }
    }
    var covered: u8 = 0;
    for (asset.streams) |stream| {
        for (asset.callers) |caller| {
            if (std.mem.eql(u8, stream.id, caller.stream_id)) covered += 1;
        }
    }
    if (covered != asset.streams.len) return error.CallerCoverage;
}

pub const Kind = enum { frame, audio };

pub const FinishReason = enum {
    natural_end,
    skip,
    cancelled,

    pub fn label(self: FinishReason) []const u8 {
        return switch (self) {
            .natural_end => "natural_end",
            .skip => "skip",
            .cancelled => "cancelled",
        };
    }
};

pub const Event = struct {
    kind: Kind,
    /// 1-based frame number for a frame event, 0 for an audio event.
    frame: u16,
    /// Disc block index inside the stream.
    block: u16,
    /// LBA for a CD-XA stream, file byte offset for the file stream.
    offset: u32,
    /// Video blocks in the frame (0 for an audio event).
    video_blocks: u8,
    time_us: u64,
};

pub const Finish = struct {
    caller: []const u8,
    token: u32,
    reason: FinishReason,
    frames_presented: u16,
    audio_requests: u16,
    fade_frames: u8,
    skipped_before_start: bool,
    end_block: u16,
};

pub const Outcome = union(enum) {
    frame: Event,
    audio: Event,
    finished: Finish,
};

pub const SessionError = error{
    SessionClosed,
    SessionFinished,
    UnknownCaller,
    UnknownStream,
    MissingCallerToken,
    CallerStreamMismatch,
    SkipAlreadyRequested,
    DuplicateFinish,
    TickOverflow,
    QueueFull,
};

/// A deterministic, bounded run of one source stream mode.
///
/// The caller supplies the clock deltas (`tick`), drains `next`, and may call
/// `skip` or `cancel` at any point.  Work per call is bounded by
/// `max_tick_blocks` and `max_events`; a large delta simply leaves blocks due
/// for later ticks instead of emitting without bound.
pub const Session = struct {
    asset: *const Asset,
    stream: *const Stream,
    caller: *const Caller,
    token: u32,
    now_us: u64,
    next_block: u32,
    next_frame: u32,
    next_audio: u32,
    fade_remaining: u8,
    skip_pending: bool,
    skip_before_start: bool,
    fade_emitted: u8,
    frames_presented: u16,
    audio_requests: u16,
    finish: ?Finish,
    finish_delivered: bool,
    closed: bool,
    queue: [max_events]Outcome,
    q_head: u8,
    q_len: u8,

    /// Begin one stream mode for a declared caller.
    ///
    /// `token` is the caller's opaque, non-zero identity receipt: it is
    /// returned unchanged in the finish value.  An unknown caller, a zero
    /// token, or a caller whose declared stream is not `stream_id` is refused.
    pub fn begin(
        asset: *const Asset,
        stream_id: []const u8,
        caller_id: []const u8,
        token: u32,
    ) SessionError!Session {
        if (token == 0) return error.MissingCallerToken;
        const stream = streamById(asset, stream_id) orelse return error.UnknownStream;
        const caller = callerById(asset, caller_id) orelse return error.UnknownCaller;
        if (!std.mem.eql(u8, caller.stream_id, stream.id)) return error.CallerStreamMismatch;
        return .{
            .asset = asset,
            .stream = stream,
            .caller = caller,
            .token = token,
            .now_us = 0,
            .next_block = 0,
            .next_frame = 0,
            .next_audio = 0,
            .fade_remaining = 0,
            .skip_pending = false,
            .skip_before_start = false,
            .fade_emitted = 0,
            .frames_presented = 0,
            .audio_requests = 0,
            .finish = null,
            .finish_delivered = false,
            .closed = false,
            .queue = undefined,
            .q_head = 0,
            .q_len = 0,
        };
    }

    pub fn close(self: *Session) void {
        self.closed = true;
        self.q_len = 0;
        self.q_head = 0;
    }

    pub fn isClosed(self: *const Session) bool {
        return self.closed;
    }

    pub fn isFinished(self: *const Session) bool {
        return self.finish != null;
    }

    pub fn pending(self: *const Session) usize {
        return self.q_len;
    }

    /// Advance the mode clock and queue the requests that fall due.
    pub fn tick(self: *Session, dt_us: u64) SessionError!void {
        if (self.closed) return error.SessionClosed;
        if (self.finish != null) return error.SessionFinished;
        const sum = @addWithOverflow(self.now_us, dt_us);
        if (sum[1] != 0) return error.TickOverflow;
        self.now_us = sum[0];

        var steps: u32 = 0;
        while (steps < max_tick_blocks and self.q_len < max_events) : (steps += 1) {
            if (self.next_block >= self.stream.block_count) {
                self.setFinish(.natural_end, 0);
                return;
            }
            const due = usForBlock(self.next_block);
            if (due > self.now_us) return;

            // A frame is due on its first video block.
            if (self.next_frame < self.stream.frames and
                self.stream.frame_start_block[self.next_frame] == self.next_block)
            {
                if (self.skip_pending and self.fade_remaining == 0) {
                    self.fade_remaining = self.asset.player.skip.fade_frames;
                }
                const index = self.next_frame;
                const event = Event{
                    .kind = .frame,
                    .frame = @intCast(index + 1),
                    .block = self.stream.frame_start_block[index],
                    .offset = self.stream.frame_first_offset[index],
                    .video_blocks = self.stream.frame_video_blocks[index],
                    .time_us = due,
                };
                self.push(.{ .frame = event });
                self.next_frame += 1;
                self.frames_presented += 1;
                if (self.fade_remaining > 0) {
                    self.fade_remaining -= 1;
                    self.fade_emitted += 1;
                    if (self.fade_remaining == 0) {
                        self.next_block += 1;
                        self.setFinish(.skip, self.fade_emitted);
                        return;
                    }
                }
                self.next_block += 1;
                continue;
            }

            // An audio request is due on its XA block.
            if (self.next_audio < self.stream.audio_blocks and
                self.stream.audio_block[self.next_audio] == self.next_block)
            {
                const event = Event{
                    .kind = .audio,
                    .frame = 0,
                    .block = self.stream.audio_block[self.next_audio],
                    .offset = self.stream.audio_offset[self.next_audio],
                    .video_blocks = 0,
                    .time_us = due,
                };
                self.push(.{ .audio = event });
                self.next_audio += 1;
                self.audio_requests += 1;
                self.next_block += 1;
                continue;
            }

            // Empty filler and mid-frame video blocks carry no request.
            self.next_block += 1;
        }
    }

    /// Pop the next queued outcome.  A finish is delivered once, after the
    /// requests that preceded it; afterwards the session refuses further work.
    pub fn next(self: *Session) ?Outcome {
        if (self.q_len > 0) {
            const value = self.queue[self.q_head];
            self.q_head = (self.q_head + 1) % max_events;
            self.q_len -= 1;
            return value;
        }
        if (self.finish) |value| {
            if (!self.finish_delivered) {
                self.finish_delivered = true;
                return .{ .finished = value };
            }
        }
        return null;
    }

    /// Request the skip path.  Before the first frame this latches until the
    /// state-2 poll (the first frame), matching the source, which polls only in
    /// state 2; after play starts it takes effect at the next frame boundary.
    pub fn skip(self: *Session) SessionError!void {
        if (self.closed) return error.SessionClosed;
        if (self.finish != null) return error.SessionFinished;
        if (self.skip_pending) return error.SkipAlreadyRequested;
        self.skip_pending = true;
        self.skip_before_start = self.frames_presented == 0;
    }

    /// Request the immediate cancel path (input mask 0x800): the mode ends
    /// now, without the fade, and queued requests are dropped.
    pub fn cancel(self: *Session) SessionError!void {
        if (self.closed) return error.SessionClosed;
        if (self.finish != null) return error.SessionFinished;
        self.q_len = 0;
        self.q_head = 0;
        self.setFinish(.cancelled, 0);
    }

    fn push(self: *Session, outcome: Outcome) void {
        const tail = (self.q_head + self.q_len) % max_events;
        self.queue[tail] = outcome;
        self.q_len += 1;
    }

    fn setFinish(self: *Session, reason: FinishReason, fade: u8) void {
        self.finish = .{
            .caller = self.caller.id,
            .token = self.token,
            .reason = reason,
            .frames_presented = self.frames_presented,
            .audio_requests = self.audio_requests,
            .fade_frames = fade,
            .skipped_before_start = self.skip_before_start,
            .end_block = @intCast(@min(self.next_block, self.stream.block_count)),
        };
    }

    /// Counters for a receipt without draining the queue.
    pub fn counters(self: *const Session) struct { frames: u16, audio: u16, block: u32 } {
        return .{
            .frames = self.frames_presented,
            .audio = self.audio_requests,
            .block = self.next_block,
        };
    }
};
