//! The host between a committed source audio request and the
//! platform service.
//!
//! The host owns the request ledger, the receipt ledger, the stream/sequence/
//! bank/score owners, the device-operation order and the cleanup order.  It
//! plays nothing: `Port` is a logical device contract, and the only committed
//! implementations are the headless recorder and the no-device waiter.
//!
//! The planner is a comptime type implementing the documented protocol
//! (`requestBank`, `requestScore`, `requestVolume`, `requestCue`,
//! `requestSequenceOpen`, `service`, `pending`, `pendingSequence`, `complete`,
//! `completeSequence`, `stopCueContext`, `voiceActive`, `activeVoices`,
//! `activeSequenceVoices`, `generationValue`, `snapshot`, `restore`).  the host binds
//! the accepted audio-planner engine through an adapter over that protocol; until then
//! `Unbound` refuses every modeled request and the host keeps it pending.
//!
//! Non-negotiables encoded here:
//!
//!   * one committed source event -> one logical request; a repeated delivery is
//!     `DuplicateRequest` and a non-changing cue is `NoStateChange`, with no
//!     second planner call, device operation or receipt;
//!   * replacement is stop-then-start, and a stop with no stream is not a
//!     request;
//!   * a modeled request without its completion token stays pending: no receipt,
//!     no scene acknowledgement, no owner;
//!   * a wrong token is refused before the planner mutates state;
//!   * no device is a waiver: acknowledge the scene once, record
//!     `playback=unavailable`, install no owner, keep gameplay running;
//!   * cleanup is stop -> volume restore -> loop disable -> bank close (only with
//!     no pending transfer) -> score/sequence retention.

const std = @import("std");
const events = @import("events.zig");
const plan = @import("plan.zig");
const trace_mod = @import("trace.zig");

pub const Request = struct {
    batch: u64,
    command: u16,
    origin: u16,
};

pub const Disposition = enum {
    accepted_stream,
    pending,
    gated,
    applied,
    candidate,
    waived_no_device,
    refused_unmodeled,
    refused_unmapped,
};

pub const Service = enum { accepted, pending, waived };
pub const Playback = enum { not_attempted, unavailable, refused };

pub const Receipt = struct {
    service: Service,
    playback: Playback,
    disposition: Disposition,
};

pub const SceneSink = struct {
    context: *anyopaque,
    acknowledge_fn: *const fn (context: *anyopaque, batch: u64, origin: u16) anyerror!void,

    pub fn acknowledge(self: SceneSink, batch: u64, origin: u16) !void {
        return self.acknowledge_fn(self.context, batch, origin);
    }
};

/// Logical device contract.  The production adapter (module) forwards these to
/// `opening_audio_platform.Player`; this campaign commits only a headless
/// recorder (`available = true`) and a no-device waiter (`available = false`).
pub const Port = struct {
    available: bool,

    pub fn start(self: Port, track: []const u8) !void {
        _ = track;
        if (!self.available) return error.AudioDeviceUnavailable;
    }

    pub fn stop(self: Port, track: []const u8) !void {
        _ = track;
        if (!self.available) return error.AudioDeviceUnavailable;
    }

    pub fn volume(self: Port, value: u16) !void {
        _ = value;
        if (!self.available) return error.AudioDeviceUnavailable;
    }

    pub fn loop(self: Port, enabled: bool) !void {
        _ = enabled;
        if (!self.available) return error.AudioDeviceUnavailable;
    }
};

pub const BankOwner = struct {
    request: u8,
    slot: u8,
    generation: u32,
};

pub const Owners = struct {
    stream: ?[]const u8 = null,
    sequence: ?u32 = null,
    bank: ?BankOwner = null,
    score: ?u8 = null,
    voices: usize = 0,
};

const ledger_capacity = 16;

const RequestKey = struct {
    batch: u64,
    origin: u16,
    command: u16,
};

const RequestLedger = struct {
    items: [ledger_capacity]RequestKey = undefined,
    len: usize = 0,

    fn contains(self: *const RequestLedger, key: RequestKey) bool {
        for (self.items[0..self.len]) |item| {
            if (item.batch == key.batch and item.origin == key.origin and item.command == key.command) return true;
        }
        return false;
    }

    fn add(self: *RequestLedger, key: RequestKey) !void {
        if (self.len == ledger_capacity) return error.LedgerFull;
        self.items[self.len] = key;
        self.len += 1;
    }
};

const ReceiptEntry = struct {
    batch: u64,
    origin: u16,
    service: Service,
};

const ReceiptLedger = struct {
    items: [ledger_capacity]ReceiptEntry = undefined,
    len: usize = 0,

    fn set(self: *ReceiptLedger, entry: ReceiptEntry) !void {
        for (self.items[0..self.len]) |*item| {
            if (item.batch == entry.batch and item.origin == entry.origin) {
                item.service = entry.service;
                return;
            }
        }
        if (self.len == ledger_capacity) return error.LedgerFull;
        self.items[self.len] = entry;
        self.len += 1;
    }
};

const PendingKind = enum { bank, score };

const PendingReceipt = struct {
    batch: u64,
    origin: u16,
    kind: PendingKind,
    key: u16,
};

const PendingLedger = struct {
    items: [ledger_capacity]PendingReceipt = undefined,
    len: usize = 0,

    fn add(self: *PendingLedger, entry: PendingReceipt) !void {
        if (self.len == ledger_capacity) return error.LedgerFull;
        self.items[self.len] = entry;
        self.len += 1;
    }

    fn take(self: *PendingLedger, kind: PendingKind, key: u16) ?PendingReceipt {
        var index: usize = 0;
        while (index < self.len) : (index += 1) {
            const item = self.items[index];
            if (item.kind == kind and item.key == key) {
                var shift = index;
                while (shift + 1 < self.len) : (shift += 1) self.items[shift] = self.items[shift + 1];
                self.len -= 1;
                return item;
            }
        }
        return null;
    }
};

pub const Class = enum { stream, bank, score, volume, cue_candidate, unmodeled, unmapped };

pub const Classification = struct {
    class: Class,
    family: u8,
    blocker: ?[]const u8 = null,
};

const DeviceOp = enum { score_start, score_stop };

fn planName(class: Class) []const u8 {
    return switch (class) {
        .stream => "stream",
        .bank => "bank",
        .score => "score",
        .volume => "volume",
        .cue_candidate => "cue_candidate",
        .unmodeled => "unmodeled",
        .unmapped => "unmapped",
    };
}

fn reasonText(err: anyerror) []const u8 {
    return switch (err) {
        error.PlannerUnbound => "unbound",
        error.WrongTransferOwner => "wrong_transfer_owner",
        error.WrongTransferChunk => "wrong_transfer_chunk",
        error.WrongTransferKind => "wrong_transfer_kind",
        error.NoPendingTransfer => "no_pending_transfer",
        error.UnknownResource => "unknown_resource",
        error.UnknownScore => "unknown_score",
        error.UnknownRequest => "unknown_request",
        error.UnknownAction => "unknown_action",
        error.QueueFull => "queue_full",
        error.LoaderBusy => "loader_busy",
        error.NoDesiredScore => "no_desired_score",
        error.ScoreNotAdmissible => "score_not_admissible",
        error.BankNotResident => "bank_not_resident",
        error.UnmodeledAction => "unmodeled_action",
        error.UnmodeledFamily => "unmodeled_family",
        error.UnadmittedCueOperand => "unadmitted_cue_operand",
        error.InvalidVoiceCount => "invalid_voice_count",
        error.AudioDeviceUnavailable => "audio_device_unavailable",
        else => @errorName(err),
    };
}

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn ownersEql(a: ?Owners, b: ?Owners) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    const left = a.?;
    const right = b.?;
    if (!optionalEql(left.stream, right.stream)) return false;
    if (left.sequence != right.sequence) return false;
    if (left.score != right.score) return false;
    if (left.voices != right.voices) return false;
    if (left.bank == null and right.bank == null) return true;
    if (left.bank == null or right.bank == null) return false;
    return left.bank.?.request == right.bank.?.request and
        left.bank.?.slot == right.bank.?.slot and
        left.bank.?.generation == right.bank.?.generation;
}

fn pendingEql(a: ?events.Pending, b: ?events.Pending) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    const left = a.?;
    const right = b.?;
    return left.kind == right.kind and
        left.request == right.request and
        left.generation == right.generation and
        left.chunk == right.chunk and
        std.mem.eql(u8, left.phase, right.phase);
}

pub fn Host(comptime Planner: type) type {
    return struct {
        const Self = @This();

        content: *const plan.Content,
        planner: Planner,
        port: Port,
        trace: *trace_mod.Trace,
        scene: SceneSink,
        owners: Owners = .{},
        requests: RequestLedger = .{},
        receipts: ReceiptLedger = .{},
        pending_receipts: PendingLedger = .{},
        sequence_voices: usize = 0,
        last_pending: ?events.Pending = null,
        last_owner: ?Owners = null,

        pub const Snapshot = struct {
            owners: Owners,
            requests: RequestLedger,
            receipts: ReceiptLedger,
            pending_receipts: PendingLedger,
            planner: Planner.Snapshot,
        };

        pub fn init(
            content: *const plan.Content,
            planner: Planner,
            port: Port,
            trace: *trace_mod.Trace,
            scene: SceneSink,
        ) Self {
            var self = Self{
                .content = content,
                .planner = planner,
                .port = port,
                .trace = trace,
                .scene = scene,
            };
            self.syncVoices();
            self.owners.voices = self.planner.activeVoices();
            self.sequence_voices = self.planner.activeSequenceVoices();
            self.last_owner = null;
            return self;
        }

        // -- tracing ------------------------------------------------------

        fn traceRequest(self: *Self, request: Request, family: u8, name: []const u8, disposition: Disposition, track: ?[]const u8) !void {
            try self.trace.append(
                "request batch={d} command=0x{X:0>4} origin={d} family={d} plan={s} disposition={s} track={s}",
                .{ request.batch, request.command, request.origin, family, name, @tagName(disposition), track orelse "-" },
            );
        }

        fn traceCall(self: *Self, op: []const u8, arg: ?[]const u8, outcome: []const u8) !void {
            try self.trace.append("call op={s} arg={s} outcome={s}", .{ op, arg orelse "-", outcome });
        }

        fn tracePending(self: *Self, pending: events.Pending) !void {
            try self.trace.append(
                "pending kind={s} request=0x{X:0>2} generation={d} chunk={d} phase={s}",
                .{ @tagName(pending.kind), pending.request, pending.generation, pending.chunk, pending.phase },
            );
        }

        fn traceDevice(self: *Self, op: []const u8, track: ?[]const u8, value: u16) !void {
            try self.trace.append("device op={s} track={s} value={d}", .{ op, track orelse "-", value });
        }

        fn traceOwner(self: *Self) !void {
            var buffer: [160]u8 = undefined;
            var cursor: usize = 0;
            const head = try std.fmt.bufPrint(buffer[cursor..], "owner stream={s} sequence=", .{self.owners.stream orelse "-"});
            cursor += head.len;
            if (self.owners.sequence) |generation| {
                const part = try std.fmt.bufPrint(buffer[cursor..], "{d}", .{generation});
                cursor += part.len;
            } else {
                buffer[cursor] = '-';
                cursor += 1;
            }
            const bank_head = try std.fmt.bufPrint(buffer[cursor..], " bank=", .{});
            cursor += bank_head.len;
            if (self.owners.bank) |bank| {
                const part = try std.fmt.bufPrint(buffer[cursor..], "0x{X:0>2}:{d}:{d}", .{ bank.request, bank.slot, bank.generation });
                cursor += part.len;
            } else {
                buffer[cursor] = '-';
                cursor += 1;
            }
            const score_head = try std.fmt.bufPrint(buffer[cursor..], " score=", .{});
            cursor += score_head.len;
            if (self.owners.score) |cue| {
                const part = try std.fmt.bufPrint(buffer[cursor..], "{d}", .{cue});
                cursor += part.len;
            } else {
                buffer[cursor] = '-';
                cursor += 1;
            }
            const tail = try std.fmt.bufPrint(buffer[cursor..], " voices={d}", .{self.owners.voices});
            cursor += tail.len;
            try self.trace.append("{s}", .{buffer[0..cursor]});
        }

        fn traceReceipt(self: *Self, request: Request, service_kind: Service, playback: Playback) !void {
            try self.trace.append(
                "receipt batch={d} origin={d} service={s} playback={s}",
                .{ request.batch, request.origin, @tagName(service_kind), @tagName(playback) },
            );
        }

        fn refuse(self: *Self, reason: []const u8) !void {
            try self.trace.append("refuse reason={s}", .{reason});
        }

        fn note(self: *Self, comptime fmt: []const u8, args: anytype) !void {
            var buffer: [96]u8 = undefined;
            const text = try std.fmt.bufPrint(&buffer, fmt, args);
            try self.trace.append("note {s}", .{text});
        }

        fn emitPending(self: *Self, force: bool) !void {
            const pending = self.currentPending();
            if (!force and pendingEql(pending, self.last_pending)) return;
            if (pending) |value| try self.tracePending(value);
            self.last_pending = pending;
        }

        fn emitOwner(self: *Self, force: bool) !void {
            if (!force and ownersEql(self.owners, self.last_owner)) return;
            try self.traceOwner();
            self.last_owner = self.owners;
        }

        fn currentPending(self: *const Self) ?events.Pending {
            if (self.planner.pending()) |pending| return pending;
            return self.planner.pendingSequence();
        }

        fn syncVoices(self: *Self) void {
            self.owners.voices = self.planner.activeVoices();
            self.sequence_voices = self.planner.activeSequenceVoices();
        }

        // -- receipts -----------------------------------------------------

        fn finish(self: *Self, request: Request, service_kind: Service, playback: Playback, disposition: Disposition) !Receipt {
            try self.traceReceipt(request, service_kind, playback);
            try self.receipts.set(.{ .batch = request.batch, .origin = request.origin, .service = service_kind });
            try self.trace.append("ack batch={d} origin={d}", .{ request.batch, request.origin });
            self.scene.acknowledge(request.batch, request.origin) catch |err| {
                try self.refuse("scene_receipt_rejected");
                return err;
            };
            return .{ .service = service_kind, .playback = playback, .disposition = disposition };
        }

        fn resolveReceipt(self: *Self, kind: PendingKind, key: u16) !void {
            const entry = self.pending_receipts.take(kind, key) orelse return;
            _ = try self.finish(
                .{ .batch = entry.batch, .command = 0, .origin = entry.origin },
                .accepted,
                .not_attempted,
                .pending,
            );
        }

        fn addPendingReceipt(self: *Self, request: Request, kind: PendingKind, key: u16) !void {
            try self.pending_receipts.add(.{
                .batch = request.batch,
                .origin = request.origin,
                .kind = kind,
                .key = key,
            });
            try self.receipts.set(.{ .batch = request.batch, .origin = request.origin, .service = .pending });
        }

        // -- classification ----------------------------------------------

        fn classify(self: *Self, command: u16) Classification {
            return classifyCommand(self.content, command);
        }

        // -- commit -------------------------------------------------------

        pub fn commit(self: *Self, request: Request) !Receipt {
            if (request.batch == 0 or request.origin == 0) {
                try self.refuse("invalid_request");
                return error.InvalidRequest;
            }
            const key = RequestKey{ .batch = request.batch, .origin = request.origin, .command = request.command };
            if (self.requests.contains(key)) {
                try self.refuse("duplicate_request");
                return error.DuplicateRequest;
            }
            const class = self.classify(request.command);
            if (class.class == .stream) return self.commitStream(request, class);
            try self.requests.add(key);
            switch (class.class) {
                .unmodeled, .unmapped => {
                    const disposition: Disposition = if (class.class == .unmodeled) .refused_unmodeled else .refused_unmapped;
                    try self.traceRequest(request, class.family, planName(class.class), disposition, null);
                    return self.finish(request, .waived, .refused, disposition);
                },
                else => {},
            }
            return self.commitPlanned(request, class);
        }

        fn commitStream(self: *Self, request: Request, class: Classification) !Receipt {
            const cue = self.content.cueCommand(request.command).?;
            const target = cue.track;
            if (optionalEql(target, self.owners.stream)) {
                try self.refuse("no_state_change");
                return error.NoStateChange;
            }
            try self.requests.add(.{ .batch = request.batch, .origin = request.origin, .command = request.command });
            if (!self.port.available) {
                try self.traceRequest(request, class.family, "stream", .waived_no_device, target);
                try self.refuse("audio_device_unavailable");
                return self.finish(request, .waived, .unavailable, .waived_no_device);
            }
            try self.traceRequest(request, class.family, "stream", .accepted_stream, target);
            if (self.owners.stream) |previous| {
                try self.port.stop(previous);
                try self.traceDevice("stop", previous, 0);
            }
            if (target) |next| {
                try self.port.start(next);
                try self.traceDevice("start", next, 0);
            }
            self.owners.stream = target;
            const receipt = try self.finish(request, .accepted, .not_attempted, .accepted_stream);
            try self.emitOwner(false);
            return receipt;
        }

        fn commitPlanned(self: *Self, request: Request, class: Classification) !Receipt {
            const key: u16 = switch (class.class) {
                .bank, .score, .volume => @as(u16, request.command & 0xFF),
                else => request.command,
            };
            switch (class.class) {
                .bank => {
                    var effects = events.PlanEffects{};
                    const outcome = self.planner.requestBank(@intCast(request.command & 0xFF), &effects) catch |err| {
                        return self.plannerRefusal(request, class, "request_bank", bankArg(request.command), err);
                    };
                    const disposition: Disposition = if (outcome == .gated) .gated else .pending;
                    try self.traceRequest(request, class.family, "bank", disposition, null);
                    try self.traceCall("request_bank", bankArg(request.command), if (outcome == .gated) "gated" else "accepted");
                    if (outcome == .gated) return self.finish(request, .waived, .refused, .gated);
                    try self.addPendingReceipt(request, .bank, key);
                    try self.drain(effects.slice());
                    try self.emitPending(false);
                    return .{ .service = .pending, .playback = .not_attempted, .disposition = .pending };
                },
                .score => {
                    var effects = events.PlanEffects{};
                    self.planner.requestScore(@intCast(request.command & 0xFF), &effects) catch |err| {
                        return self.plannerRefusal(request, class, "request_score", cueArg(request.command), err);
                    };
                    try self.traceRequest(request, class.family, "score", .pending, null);
                    try self.traceCall("request_score", cueArg(request.command), "queued");
                    try self.addPendingReceipt(request, .score, key);
                    try self.drain(effects.slice());
                    try self.emitPending(false);
                    return .{ .service = .pending, .playback = .not_attempted, .disposition = .pending };
                },
                .volume => {
                    var effects = events.PlanEffects{};
                    self.planner.requestVolume(request.command, 24, &effects) catch |err| {
                        return self.plannerRefusal(request, class, "request_volume", commandArg(request.command), err);
                    };
                    try self.traceRequest(request, class.family, "volume", .applied, null);
                    try self.traceCall("request_volume", commandArg(request.command), "applied");
                    try self.drain(effects.slice());
                    return self.finish(request, .accepted, .not_attempted, .applied);
                },
                .cue_candidate => {
                    var effects = events.PlanEffects{};
                    self.planner.requestCue(request.command, &effects) catch |err| {
                        return self.plannerRefusal(request, class, "request_cue", commandArg(request.command), err);
                    };
                    try self.traceRequest(request, class.family, "cue_candidate", .candidate, null);
                    try self.traceCall("request_cue", commandArg(request.command), "recorded");
                    try self.drain(effects.slice());
                    return self.finish(request, .accepted, .not_attempted, .candidate);
                },
                else => unreachable,
            }
        }

        fn plannerRefusal(self: *Self, request: Request, class: Classification, op: []const u8, arg: ?[]const u8, err: anyerror) !Receipt {
            if (err == error.PlannerUnbound) {
                try self.traceRequest(request, class.family, planName(class.class), .pending, null);
                try self.traceCall(op, arg, "unbound");
                switch (class.class) {
                    .bank => try self.addPendingReceipt(request, .bank, @intCast(request.command & 0xFF)),
                    .score => try self.addPendingReceipt(request, .score, @intCast(request.command & 0xFF)),
                    else => try self.receipts.set(.{
                        .batch = request.batch,
                        .origin = request.origin,
                        .service = .pending,
                    }),
                }
                return .{ .service = .pending, .playback = .not_attempted, .disposition = .pending };
            }
            try self.traceRequest(request, class.family, planName(class.class), .refused_unmapped, null);
            try self.traceCall(op, arg, reasonText(err));
            return self.finish(request, .waived, .refused, .refused_unmapped);
        }

        // -- frame service ------------------------------------------------

        pub fn service(self: *Self) !void {
            var effects = events.PlanEffects{};
            self.planner.service(&effects) catch |err| {
                try self.traceCall("service", null, reasonText(err));
                if (err == error.PlannerUnbound) return;
                return err;
            };
            try self.traceCall("service", null, "ok");
            try self.drain(effects.slice());
            try self.emitPending(false);
            try self.emitOwner(false);
        }

        pub fn openSequence(self: *Self) !void {
            var effects = events.PlanEffects{};
            self.planner.requestSequenceOpen(&effects) catch |err| {
                try self.traceCall("request_sequence_open", null, reasonText(err));
                if (err == error.PlannerUnbound) return;
                return err;
            };
            try self.traceCall("request_sequence_open", null, "accepted");
            try self.drain(effects.slice());
        }

        pub fn complete(self: *Self, token: events.Token) !void {
            var effects = events.PlanEffects{};
            self.planner.complete(token, &effects) catch |err| {
                try self.refuse(reasonText(err));
                return err;
            };
            try self.traceCall("complete", @tagName(token.kind), "ok");
            try self.drain(effects.slice());
            try self.emitPending(false);
            try self.emitOwner(false);
        }

        pub fn completeSequence(self: *Self, token: events.Token) !void {
            var effects = events.PlanEffects{};
            self.planner.completeSequence(token, &effects) catch |err| {
                try self.refuse(reasonText(err));
                return err;
            };
            try self.traceCall("complete_sequence", @tagName(token.kind), "ok");
            try self.drain(effects.slice());
            try self.emitPending(false);
            try self.emitOwner(false);
        }

        // -- effect drain -------------------------------------------------

        fn drain(self: *Self, list: []const events.Event) !void {
            var devices: [8]struct { op: DeviceOp, cue: u8 } = undefined;
            var device_len: usize = 0;
            var resolved: [4]struct { kind: PendingKind, key: u16 } = undefined;
            var resolved_len: usize = 0;
            var owner_changed = false;
            for (list) |event| {
                switch (event) {
                    .bank_close => |value| {
                        if (self.owners.bank) |bank| {
                            if (bank.slot == value.slot) {
                                self.owners.bank = null;
                                owner_changed = true;
                            }
                        }
                    },
                    .bank_open => |value| {
                        self.owners.bank = .{ .request = value.request, .slot = value.slot, .generation = value.generation };
                        owner_changed = true;
                    },
                    .bank_loaded => |value| {
                        self.owners.bank = .{ .request = value.request, .slot = value.slot, .generation = value.generation };
                        if (resolved_len < resolved.len) {
                            resolved[resolved_len] = .{ .kind = .bank, .key = value.request };
                            resolved_len += 1;
                        }
                        owner_changed = true;
                    },
                    .score_play => |value| {
                        self.owners.score = value.cue;
                        if (device_len < devices.len) {
                            devices[device_len] = .{ .op = .score_start, .cue = value.cue };
                            device_len += 1;
                        }
                        if (resolved_len < resolved.len) {
                            resolved[resolved_len] = .{ .kind = .score, .key = value.cue };
                            resolved_len += 1;
                        }
                        owner_changed = true;
                    },
                    .score_select => |value| {
                        self.owners.score = value.cue;
                        owner_changed = true;
                    },
                    .score_clear => {
                        if (self.owners.score) |cue| {
                            if (device_len < devices.len) {
                                devices[device_len] = .{ .op = .score_stop, .cue = cue };
                                device_len += 1;
                            }
                        }
                        self.owners.score = null;
                        owner_changed = true;
                    },
                    .voice_reset => owner_changed = true,
                    .sequences_open => {
                        self.owners.sequence = self.planner.generationValue();
                        owner_changed = true;
                    },
                    else => {},
                }
            }
            for (devices[0..device_len]) |device| {
                switch (device.op) {
                    .score_start => try self.traceDevice("score_start", null, device.cue),
                    .score_stop => try self.traceDevice("score_stop", null, device.cue),
                }
            }
            if (owner_changed) {
                self.syncVoices();
                try self.emitOwner(false);
            }
            for (resolved[0..resolved_len]) |entry| try self.resolveReceipt(entry.kind, entry.key);
        }

        // -- cleanup ------------------------------------------------------

        pub fn cleanup(self: *Self) !void {
            var effects = events.PlanEffects{};
            try self.planner.stopCueContext(&effects);
            try self.drain(effects.slice());
            if (self.owners.stream != null) {
                if (self.port.available) {
                    try self.port.stop(self.owners.stream.?);
                    try self.traceDevice("stop", self.owners.stream.?, 0);
                } else {
                    try self.refuse("audio_device_unavailable");
                }
                self.owners.stream = null;
            }
            if (self.port.available) {
                try self.port.volume(self.content.policy.configured_volume);
                try self.traceDevice("volume", null, self.content.policy.configured_volume);
                try self.port.loop(false);
                try self.traceDevice("loop", null, 0);
            } else {
                try self.refuse("audio_device_unavailable");
                try self.refuse("audio_device_unavailable");
            }
            if (self.owners.bank) |bank| {
                if (self.currentPending() != null) {
                    try self.refuse("pending_transfer_blocks_bank_close");
                } else {
                    try self.note("bank_closed request=0x{X:0>2}", .{bank.request});
                    self.owners.bank = null;
                }
            }
            if (self.owners.score != null) try self.refuse("score_stop_entry_point_missing");
            if (self.owners.sequence != null) try self.note("sequence_owner_retained", .{});
            self.syncVoices();
            if (self.sequence_voices > 0 and self.owners.score == null) {
                try self.refuse("voice_release_requires_score_stop");
            }
            try self.emitOwner(true);
        }

        pub fn pendingRequest(self: *const Self) ?events.Pending {
            return self.currentPending();
        }

        pub fn serviceFor(self: *const Self, batch: u64, origin: u16) ?Service {
            for (self.receipts.items[0..self.receipts.len]) |entry| {
                if (entry.batch == batch and entry.origin == origin) return entry.service;
            }
            return null;
        }

        // -- restart ------------------------------------------------------

        pub fn snapshot(self: *Self) Snapshot {
            return .{
                .owners = self.owners,
                .requests = self.requests,
                .receipts = self.receipts,
                .pending_receipts = self.pending_receipts,
                .planner = self.planner.snapshot(),
            };
        }

        pub fn restore(self: *Self, state: Snapshot) !void {
            if (state.requests.len > ledger_capacity or
                state.receipts.len > ledger_capacity or
                state.pending_receipts.len > ledger_capacity)
            {
                return error.CorruptSnapshot;
            }
            if (state.owners.bank) |bank| {
                if (self.content.bankRecord(bank.request) == null or bank.slot > 2) return error.CorruptSnapshot;
            }
            if (state.owners.score) |cue| {
                if (self.content.scoreRecord(cue) == null) return error.CorruptSnapshot;
            }
            self.owners = state.owners;
            self.requests = state.requests;
            self.receipts = state.receipts;
            self.pending_receipts = state.pending_receipts;
            try self.planner.restore(state.planner);
            self.last_pending = null;
            self.last_owner = null;
            self.syncVoices();
            try self.emitPending(true);
        }
    };
}

fn bankArg(command: u16) ?[]const u8 {
    const buffer = struct {
        var storage: [5]u8 = undefined;
    };
    const text = std.fmt.bufPrint(&buffer.storage, "0x{X:0>2}", .{@as(u8, @intCast(command & 0xFF))}) catch return null;
    return text;
}

fn cueArg(command: u16) ?[]const u8 {
    const buffer = struct {
        var storage: [4]u8 = undefined;
    };
    const text = std.fmt.bufPrint(&buffer.storage, "{d}", .{@as(u8, @intCast(command & 0xFF))}) catch return null;
    return text;
}

fn commandArg(command: u16) ?[]const u8 {
    const buffer = struct {
        var storage: [7]u8 = undefined;
    };
    const text = std.fmt.bufPrint(&buffer.storage, "0x{X:0>4}", .{command}) catch return null;
    return text;
}

/// Public classification used by the gate: the host routes on exactly this.
pub fn classifyCommand(content: *const plan.Content, command: u16) Classification {
    const family_index: u8 = @intCast(command >> 8);
    if (content.cueCommand(command) != null) {
        return .{ .class = .stream, .family = family_index };
    }
    const low: u8 = @intCast(command & 0xFF);
    const family = content.family(family_index) orelse
        return .{ .class = .unmapped, .family = family_index, .blocker = "family_slot_unmapped" };
    if (std.mem.eql(u8, family.planner, "bank_and_volume")) {
        if (low >= 0x21 and low <= 0x4F) return .{ .class = .bank, .family = family_index };
        if (low == 0xB0 or low == 0xB1) return .{ .class = .volume, .family = family_index };
        return .{ .class = .unmodeled, .family = family_index, .blocker = "control_subcommand_unmodeled" };
    }
    if (std.mem.eql(u8, family.planner, "score")) {
        if (content.scoreRecord(low) != null) return .{ .class = .score, .family = family_index };
        return .{ .class = .unmodeled, .family = family_index, .blocker = family.blocker };
    }
    if (std.mem.eql(u8, family.planner, "cue_request")) {
        if (content.isCueOperand(command)) return .{ .class = .cue_candidate, .family = family_index };
        return .{ .class = .unmodeled, .family = family_index, .blocker = "cue_operand_semantics_unmodeled" };
    }
    return .{ .class = .unmodeled, .family = family_index, .blocker = family.blocker };
}
