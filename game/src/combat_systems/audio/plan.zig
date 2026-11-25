//! Projected audio planner layout plus the pinned runtime interface record.
//!
//! The asset is generated from the audio request contract and the existing
//! runtime audio files.  The module validates every pin the producer checked,
//! so a drifted asset is refused before a host exists.

const std = @import("std");

pub const schema = "suikoden-combat-audio-integration/1";
pub const base_snapshot = "6777466c31bce45577c18a3e4e960926875ed4a3";
pub const contract_commit = "21aab22d723ec6c9b37b0739cc47413d1251b82e";
pub const contract_schema = "suikoden-audio-request-contracts/1";
pub const contract_asset_sha256 = "a633828f5f5fb08969c857eadf91af2d178ca7b6846c137b355372abaaf7bff4";
pub const contract_asset_canonical_sha256 = "a96a3b839890fab21787a6b910a314843afa4f28b39fbaa763c195a3055b86c2";
pub const contract_source_sha256 = "315bb6599e6fc97189f456cd94d5526298c1a21cb36b3e8c48e801ce185c1d05";
pub const chunk_bytes = 120832;

pub const Family = struct {
    family: u8,
    name: []const u8,
    planner: []const u8,
    blocker: ?[]const u8 = null,
};

pub const CueCommand = struct {
    command: u16,
    label: []const u8,
    track: ?[]const u8 = null,
    role: []const u8,
};

pub const Interface = struct {
    path: []const u8,
    role: []const u8,
    sha256: []const u8,
    anchors: []const []const u8,
};

pub const ContractFile = struct {
    path: []const u8,
    file_sha256: []const u8,
    canonical_sha256: ?[]const u8 = null,
};

pub const ContractFiles = struct {
    asset: ContractFile,
    source: ContractFile,
    report: ContractFile,
    registry: ContractFile,
};

pub const Contract = struct {
    commit: []const u8,
    status: []const u8,
    schema: []const u8,
    files: ContractFiles,
};

pub const Queue = struct {
    capacity: u8,
    sentinel_index: u8,
    action_min: u8,
    action_max: u8,
    dedupe_first: u8,
    dedupe_last: u8,
    append_first: u8,
    append_last: u8,
    dequeue_copies: u8,
};

pub const BankPhase = struct {
    id: []const u8,
    await: ?[]const u8 = null,
    next: ?[]const u8 = null,
    service_effect: ?[]const u8 = null,
    on_token: ?[]const u8 = null,
};

pub const SafePhase = struct {
    id: []const u8,
    await: ?[]const u8 = null,
    next: ?[]const u8 = null,
    service_effect: ?[]const u8 = null,
};

pub const TrackOpen = struct {
    index: u8,
    offset: u32,
    slot: u8,
};

pub const SequenceOpen = struct {
    action: u8,
    chunk_count: u32,
    resource_path: []const u8,
    resource_bytes: u32,
    default_bank_path: []const u8,
    default_bank_bytes: u32,
    tracks: []const TrackOpen,
};

pub const Score = struct {
    cue: u8,
    command: u16,
    track: u8,
    slot: u8,
    level: u16,
    sequence_offset: u32,
};

pub const Bank = struct {
    request: u8,
    bank: []const u8,
    slot: u8,
    header_bytes: u32,
    body_bytes: u32,
    request_bytes: u32,
    chunk_count: u32,
};

pub const Projection = struct {
    queue: Queue,
    chunk_bytes: u32,
    gate_order: []const []const u8,
    bank_phases: []const BankPhase,
    sequence_phases: []const SafePhase,
    sequence_open: SequenceOpen,
    scores: []const Score,
    banks: []const Bank,
    cue_operands: []const u16,
    families: []const Family,
    modeled_actions: []const u8,
    unmodeled_actions: []const u8,
};

pub const Runtime = struct {
    cue_commands: []const CueCommand,
    interfaces: []const Interface,
};

pub const Policy = struct {
    playback: []const u8,
    no_device: []const u8,
    missing_completion: []const u8,
    duplicate_request: []const u8,
    replace_order: []const []const u8,
    cleanup_order: []const []const u8,
    configured_volume: u16,
    receipt_key: []const u8,
};

pub const Step = struct {
    op: []const u8,
    port: []const u8 = "",
    planner: []const u8 = "",
    batch: u64 = 0,
    command: u16 = 0,
    origin: u16 = 0,
    kind: []const u8 = "",
    request: u8 = 0,
    generation: u32 = 0,
    chunk: u32 = 0,
};

pub const Scenario = struct {
    name: []const u8,
    note: []const u8,
    steps: []const Step,
    expected: []const []const u8,
    trace_sha256: []const u8,
};

pub const Content = struct {
    schema: []const u8,
    package: []const u8,
    version: []const u8,
    base_snapshot: []const u8,
    runtime: Runtime,
    contract: Contract,
    plan: Projection,
    policy: Policy,
    scenarios: []const Scenario,

    pub fn cueCommand(self: *const Content, command: u16) ?*const CueCommand {
        for (self.runtime.cue_commands) |*row| if (row.command == command) return row;
        return null;
    }

    pub fn family(self: *const Content, family_index: u8) ?*const Family {
        for (self.plan.families) |*row| if (row.family == family_index) return row;
        return null;
    }

    pub fn bankRecord(self: *const Content, request: u8) ?*const Bank {
        for (self.plan.banks) |*row| if (row.request == request) return row;
        return null;
    }

    pub fn scoreRecord(self: *const Content, cue: u8) ?*const Score {
        for (self.plan.scores) |*row| if (row.cue == cue) return row;
        return null;
    }

    pub fn isCueOperand(self: *const Content, operand: u16) bool {
        for (self.plan.cue_operands) |value| if (value == operand) return true;
        return false;
    }
};

pub const Asset = struct {
    parsed: std.json.Parsed(Content),

    pub fn content(self: *const Asset) *const Content {
        return &self.parsed.value;
    }

    pub fn deinit(self: *Asset) void {
        self.parsed.deinit();
    }
};

pub fn open(allocator: std.mem.Allocator, bytes: []const u8) !Asset {
    if (bytes.len > 512 * 1024) return error.InvalidIntegrationAsset;
    const parsed = try std.json.parseFromSlice(Content, allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
    var asset = Asset{ .parsed = parsed };
    errdefer asset.deinit();
    try validate(asset.content());
    return asset;
}

fn expectHex64(value: []const u8) !void {
    if (value.len != 64) return error.InvalidIntegrationAsset;
    for (value) |byte| {
        const hex = (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f');
        if (!hex) return error.InvalidIntegrationAsset;
    }
}

pub fn validate(content: *const Content) !void {
    if (!std.mem.eql(u8, content.schema, schema)) return error.UnsupportedIntegrationAsset;
    if (!std.mem.eql(u8, content.package, "combat_audio")) return error.InvalidIntegrationAsset;
    if (!std.mem.eql(u8, content.version, "combat-audio-integration.1")) return error.InvalidIntegrationAsset;
    if (!std.mem.eql(u8, content.base_snapshot, base_snapshot)) return error.InvalidIntegrationAsset;

    if (!std.mem.eql(u8, content.contract.commit, contract_commit)) return error.InvalidIntegrationAsset;
    if (!std.mem.eql(u8, content.contract.status, "candidate_only")) return error.InvalidIntegrationAsset;
    if (!std.mem.eql(u8, content.contract.schema, contract_schema)) return error.InvalidIntegrationAsset;
    if (!std.mem.eql(u8, content.contract.files.asset.file_sha256, contract_asset_sha256)) return error.InvalidIntegrationAsset;
    if (!std.mem.eql(u8, content.contract.files.asset.canonical_sha256.?, contract_asset_canonical_sha256)) return error.InvalidIntegrationAsset;
    if (!std.mem.eql(u8, content.contract.files.source.file_sha256, contract_source_sha256)) return error.InvalidIntegrationAsset;
    try expectHex64(content.contract.files.asset.file_sha256);
    try expectHex64(content.contract.files.source.file_sha256);
    try expectHex64(content.contract.files.report.file_sha256);
    try expectHex64(content.contract.files.registry.file_sha256);

    // runtime cue table: exactly the three commands the existing State maps.
    if (content.runtime.cue_commands.len != 3) return error.InvalidIntegrationAsset;
    const cues = content.runtime.cue_commands;
    if (cues[0].command != 0x81 or !std.mem.eql(u8, cues[0].track.?, "palace")) return error.InvalidIntegrationAsset;
    if (cues[1].command != 0x422 or !std.mem.eql(u8, cues[1].track.?, "audience")) return error.InvalidIntegrationAsset;
    if (cues[2].command != 0x15 or cues[2].track != null) return error.InvalidIntegrationAsset;
    if (content.runtime.interfaces.len < 5) return error.InvalidIntegrationAsset;
    for (content.runtime.interfaces) |interface| {
        try expectHex64(interface.sha256);
        if (interface.anchors.len == 0) return error.InvalidIntegrationAsset;
    }

    // projected plan shape.
    const plan = &content.plan;
    if (plan.families.len != 33) return error.InvalidIntegrationAsset;
    if (plan.banks.len != 47) return error.InvalidIntegrationAsset;
    if (plan.scores.len != 4) return error.InvalidIntegrationAsset;
    if (plan.cue_operands.len != 10) return error.InvalidIntegrationAsset;
    if (plan.sequence_open.tracks.len != 4) return error.InvalidIntegrationAsset;
    if (plan.chunk_bytes != chunk_bytes) return error.InvalidIntegrationAsset;
    if (plan.queue.capacity != 31 or plan.queue.sentinel_index != 31) return error.InvalidIntegrationAsset;
    if (!std.mem.eql(u8, plan.sequence_open.resource_path, "DATA/00_INIT/SEQ.BIN")) return error.InvalidIntegrationAsset;
    if (plan.sequence_open.resource_bytes != 71162) return error.InvalidIntegrationAsset;
    if (!std.mem.eql(u8, plan.sequence_open.default_bank_path, "DATA/00_INIT/STAY.VA")) return error.InvalidIntegrationAsset;
    for (plan.sequence_open.tracks, 0..) |track, index| {
        if (track.index != index) return error.InvalidIntegrationAsset;
        if (track.slot != 1 and track.slot != 2) return error.InvalidIntegrationAsset;
    }
    // the four classification rows the host routes on.
    const control = content.family(0) orelse return error.InvalidIntegrationAsset;
    if (!std.mem.eql(u8, control.planner, "bank_and_volume")) return error.InvalidIntegrationAsset;
    const score = content.family(2) orelse return error.InvalidIntegrationAsset;
    if (!std.mem.eql(u8, score.planner, "score")) return error.InvalidIntegrationAsset;
    const stream = content.family(4) orelse return error.InvalidIntegrationAsset;
    if (!std.mem.eql(u8, stream.planner, "unmodeled")) return error.InvalidIntegrationAsset;
    if (!std.mem.eql(u8, stream.blocker.?, "family_effects_unmodeled")) return error.InvalidIntegrationAsset;
    const cue = content.family(5) orelse return error.InvalidIntegrationAsset;
    if (!std.mem.eql(u8, cue.planner, "cue_request")) return error.InvalidIntegrationAsset;

    // every bank record is bounded and its chunk count follows the loader.
    for (plan.banks) |bank| {
        if (bank.request < 0x21 or bank.request > 0x4F) return error.InvalidIntegrationAsset;
        if (bank.slot > 2) return error.InvalidIntegrationAsset;
        if (bank.request_bytes == 0 or bank.chunk_count == 0) return error.InvalidIntegrationAsset;
        const expected = @max(@as(u32, 1), (bank.request_bytes + plan.chunk_bytes - 1) / plan.chunk_bytes);
        if (bank.chunk_count != expected) return error.InvalidIntegrationAsset;
    }
    for (plan.scores) |row| {
        if (row.command != 0x200 + @as(u16, row.cue)) return error.InvalidIntegrationAsset;
        if (row.slot != 1 and row.slot != 2) return error.InvalidIntegrationAsset;
        if (row.cue < 1 or row.cue > 4) return error.InvalidIntegrationAsset;
    }
    if (content.policy.configured_volume != 100) return error.InvalidIntegrationAsset;
    if (!std.mem.eql(u8, content.policy.playback, "not_performed_in_campaign")) return error.InvalidIntegrationAsset;
    if (!std.mem.eql(u8, content.policy.no_device, "waive_and_acknowledge")) return error.InvalidIntegrationAsset;
    if (!std.mem.eql(u8, content.policy.missing_completion, "pending_without_receipt")) return error.InvalidIntegrationAsset;
    if (!std.mem.eql(u8, content.policy.receipt_key, "scene_instance_batch_origin")) return error.InvalidIntegrationAsset;

    if (content.scenarios.len != 5) return error.InvalidIntegrationAsset;
    for (content.scenarios) |scenario| {
        if (scenario.steps.len < 2) return error.InvalidIntegrationAsset;
        if (!std.mem.eql(u8, scenario.steps[0].op, "init")) return error.InvalidIntegrationAsset;
        if (!std.mem.eql(u8, scenario.steps[0].port, "recording") and !std.mem.eql(u8, scenario.steps[0].port, "no_device")) return error.InvalidIntegrationAsset;
        if (!std.mem.eql(u8, scenario.steps[0].planner, "unbound") and !std.mem.eql(u8, scenario.steps[0].planner, "double")) return error.InvalidIntegrationAsset;
        if (scenario.expected.len == 0) return error.InvalidIntegrationAsset;
        try expectHex64(scenario.trace_sha256);
        for (scenario.steps[1..]) |step| {
            if (!knownOp(step.op)) return error.InvalidIntegrationAsset;
        }
        for (scenario.expected) |row| {
            if (row.len < 4 or row[3] != '|') return error.InvalidIntegrationAsset;
        }
    }
}

fn knownOp(op: []const u8) bool {
    for ([_][]const u8{
        "commit",
        "open_sequence",
        "service",
        "complete",
        "complete_sequence",
        "cleanup",
        "snapshot",
        "restore",
    }) |name| {
        if (std.mem.eql(u8, op, name)) return true;
    }
    return false;
}
