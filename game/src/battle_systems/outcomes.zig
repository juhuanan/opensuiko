//! Source scripted and boss battle outcomes.
//!
//! The packet in the embedded campaign asset is produced by
//! the extraction pipeline from static source facts.  This module is the
//! runtime seam: it validates the decoded battle-entry and result contracts,
//! classifies a battle against the source's two result flags, and commits the
//! consequence **once** at the host.
//!
//! What it does *not* do: it never mutates story state, never awards anything and
//! never turns an unproven continuation into a victory.  A consequence is data:
//! the host applies it.  That is the source shape -- battle code writes
//! `scene+0x34` / `scene+0x38`, the parent gate installs (or skips) the reward
//! initializer, and the teardown routes to the field or to the game-over module.
//!
//! Source rules encoded here:
//!
//!   * rewards iff `scene+0x34 == 0` and `scene+0x38 == 0` (`0x800DE150..0x800DE184`);
//!   * `scene+0x34 != 0` is a battle-over-with-no-rewards end, and it returns to
//!     the field; its nonzero writers are bribe success (`0x800F6D60`) and the
//!     round driver's battle-over arm (`0x800F6D7C`);
//!   * `scene+0x38 == 1` is defeat and routes to mode 99 selector `0x0A`, whose
//!     module table entry `0x8016448C` is `GAMEOVER.BIN`;
//!   * an enemy whose feature word has `0x4000` never decrements the live count
//!     (`0x801160B0`), so a boss battle cannot complete through the live count.
//!     If a host reports zero live enemies for such a battle the signal is
//!     inconsistent and refused; the battle stays pending until the source's
//!     `scene+0x34` end request arrives.
//!
//! Nothing here is an original instruction or a PS1 memory model in gameplay
//! terms: the addresses live in the packet and the Python producer, and the port
//! sees only named signals.

const std = @import("std");
const validation = @import("validation");

pub const schema = "suikoden-battle-scripted-outcomes/1";
pub const defeat_selector: u8 = 0x0A;
pub const max_id = 63;

pub const Form = struct {
    selector: []const u8,
    mode: u8,
    operand_bytes: u8,
    rule: []const u8,
};

pub const RoomChain = struct {
    root: []const u8,
    section_table: []const u8,
    room_table: []const u8,
    room_stride: u8,
    room_section_byte: u8,
    header_base_field: []const u8,
    header_table_field: []const u8,
    probe_entries: u8,
};

pub const EncounterContract = struct {
    flags_offset: []const u8,
    escape_bit: []const u8,
    archive_bit: []const u8,
    escape_rule: []const u8,
    standard_archive: []const u8,
    boss_archive: []const u8,
};

pub const EntryContract = struct {
    opcode: []const u8,
    handler: []const u8,
    forms: []const Form,
    room_chain: RoomChain,
    encounter: EncounterContract,
};

pub const RewardGate = struct {
    addr: []const u8,
    rule: []const u8,
    reward_initializer: []const u8,
    no_reward_initializer: []const u8,
    child_result_gate: []const u8,
};

pub const DefeatRoute = struct {
    mode: u8,
    selector: []const u8,
    module: []const u8,
    descriptor: []const u8,
    table: []const u8,
};

pub const Teardown = struct {
    addr: []const u8,
    result_source: []const u8,
    defeat_route: DefeatRoute,
    ordinary_route: []const u8,
};

pub const BranchRule = struct {
    id: []const u8,
    when: []const u8,
    rewards: bool,
    action: []const u8,
};

pub const ResultContract = struct {
    scene: []const u8,
    live_enemies: []const u8,
    end_flag: []const u8,
    defeat_flag: []const u8,
    victory_addr: []const u8,
    end_flag_addr: []const u8,
    defeat_addr: []const u8,
    reward_gate: RewardGate,
    teardown: Teardown,
    branches: []const BranchRule,
};

pub const FeatureBit = struct {
    bit: []const u8,
    name: []const u8,
    addr: []const u8,
    rule: []const u8,
};

pub const BossContract = struct {
    feature_word: []const u8,
    special_death_mask: []const u8,
    special_death_addr: []const u8,
    special_death_rule: []const u8,
    feature_bits: []const FeatureBit,
    end_trigger_evidence: []const u8,
};

pub const Continuation = struct {
    story_continuation_after_defeat: []const u8,
    script_observes_result: []const u8,
    permitted_defeat: []const u8,
    reason: []const u8,
};

pub const CommitContract = struct {
    once_per_battle: bool,
    ownership: []const u8,
    story_mutation: []const u8,
    restart_rule: []const u8,
};

pub const Boss = struct {
    id: []const u8,
    name: []const u8,
    level: u16,
    hp: u16,
    stats: []const u16,
    feature_mask: u16,
    feature_bits: []const u16,
    actor_script: ?[]const u8,
    callback: ?[]const u8,
    callback_kind: []const u8,
    record_va: []const u8,
    mechanics: []const u8,
};

pub const Enemy = struct {
    id: []const u8,
    name: []const u8,
    level: u16,
    hp: u16,
    stats: []const u16,
    feature_mask: u16,
    feature_bits: []const u16,
    actor_script: ?[]const u8,
    callback: ?[]const u8,
    callback_kind: []const u8,
    record_va: []const u8,
};

pub const Encounter = struct {
    active: u8,
    enemy_ids: []const []const u8,
    roster_slots: []const u8,
    encounter_va: []const u8,
    flags: u32,
};

pub const Battle = struct {
    id: []const u8,
    source: []const u8,
    source_sha256: []const u8,
    section: u8,
    entry: u16,
    base_index: u8,
    directory_va: []const u8,
    room_reachable: bool,
    rooms: []const u16,
    flags: u32,
    escape_allowed: bool,
    archive: []const u8,
    archive_resource: []const u8,
    family: []const u8,
    encounters: []const Encounter,
    boss_present: bool,
    end_trigger: []const u8,
    boss_ids: []const []const u8,
};

pub const Caller = struct {
    file: []const u8,
    offset: []const u8,
    bytes: []const u8,
    opcode: []const u8,
    selector: []const u8,
    form: []const u8,
    operand_bytes: u8,
    mode: u8,
    note: []const u8,
    room_link: []const u8,
};

pub const Blocked = struct {
    id: []const u8,
    reason: []const u8,
};

pub const Asset = struct {
    schema: []const u8,
    target: []const u8,
    base_snapshot: []const u8,
    producer: []const u8,
    entry_contract: EntryContract,
    result_contract: ResultContract,
    boss_contract: BossContract,
    continuation: Continuation,
    commit_contract: CommitContract,
    bosses: []const Boss,
    battles: []const Battle,
    enemies: []const Enemy,
    callers: []const Caller,
    disclosures: []const []const u8,
    blocked: []const Blocked,
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

/// Parse and validate one packet.  A packet that has lost its disclosures, its
/// blocked rows or a branch rule is refused rather than trusted.
pub fn open(allocator: std.mem.Allocator, json: []const u8) !Opened {
    const parsed = try std.json.parseFromSlice(Asset, allocator, json, .{
        .ignore_unknown_fields = true,
    });
    var opened = Opened{ .parsed = parsed };
    errdefer opened.deinit();
    try validate(opened.asset());
    return opened;
}

pub fn battleById(asset: *const Asset, id: []const u8) ?*const Battle {
    for (asset.battles) |*battle| if (std.mem.eql(u8, battle.id, id)) return battle;
    return null;
}

pub fn bossById(asset: *const Asset, id: []const u8) ?*const Boss {
    for (asset.bosses) |*boss| if (std.mem.eql(u8, boss.id, id)) return boss;
    return null;
}

pub fn enemyById(asset: *const Asset, id: []const u8) ?*const Enemy {
    for (asset.enemies) |*enemy| if (std.mem.eql(u8, enemy.id, id)) return enemy;
    return null;
}

fn validId(id: []const u8) bool {
    return validation.isAsciiId(id, max_id, "_-");
}

fn validHash(hash: []const u8) bool {
    return validation.isHex64(hash);
}

fn hasRule(asset: *const Asset, id: []const u8) bool {
    for (asset.result_contract.branches) |rule| if (std.mem.eql(u8, rule.id, id)) return true;
    return false;
}

fn hasBlocked(asset: *const Asset, id: []const u8) bool {
    for (asset.blocked) |row| if (std.mem.eql(u8, row.id, id)) return true;
    return false;
}

fn hasFeature(contract: *const BossContract, mask: u16) bool {
    for (contract.feature_bits) |bit| {
        if (bit.bit.len < 3) continue;
        if (!std.mem.startsWith(u8, bit.bit, "0x")) continue;
        const parsed = std.fmt.parseInt(u16, bit.bit[2..], 16) catch continue;
        if (parsed == mask) return true;
    }
    return false;
}

pub fn validate(asset: *const Asset) !void {
    if (!std.mem.eql(u8, asset.schema, schema)) return error.UnsupportedSchema;
    if (asset.base_snapshot.len != 40) return error.InvalidBaseSnapshot;
    if (asset.battles.len == 0) return error.EmptyPacket;
    if (asset.callers.len == 0) return error.NoCallers;
    if (asset.disclosures.len < 5) return error.DisclosuresDropped;
    inline for ([_][]const u8{
        asset.continuation.story_continuation_after_defeat,
        asset.continuation.script_observes_result,
        asset.continuation.permitted_defeat,
    }) |state| {
        if (!std.mem.eql(u8, state, "blocked") and
            !std.mem.eql(u8, state, "unproven") and
            !std.mem.eql(u8, state, "proven"))
        {
            return error.ContinuationStateInvalid;
        }
    }
    if (std.mem.eql(u8, asset.continuation.story_continuation_after_defeat, "proven") and
        !hasRule(asset, "continuation"))
    {
        return error.ContinuationWithoutRule;
    }

    // The result contract is the whole behavioural claim; a packet that drops a
    // branch or the defeat module is refused.
    if (std.mem.indexOf(u8, asset.result_contract.reward_gate.rule, "iff") == null) {
        return error.RewardRuleMissing;
    }
    const route = asset.result_contract.teardown.defeat_route;
    if (route.mode != 99) return error.DefeatModeChanged;
    if (!std.mem.eql(u8, route.module, "DATA/05_BATLE/GAMEOVER.BIN")) return error.DefeatModuleChanged;
    if (route.selector.len < 3) return error.DefeatSelectorInvalid;
    const selected = std.fmt.parseInt(u8, route.selector[2..], 16) catch return error.DefeatSelectorInvalid;
    if (selected != defeat_selector) return error.DefeatSelectorChanged;
    for ([_][]const u8{ "victory", "no_reward_end", "defeat", "battle_open" }) |id| {
        if (!hasRule(asset, id)) return error.BranchRuleMissing;
    }
    for ([_][]const u8{
        "story_continues_after_defeat",
        "permitted_defeat",
        "script_branch_on_result",
        "boss_end_trigger",
        "gameover_screens",
    }) |id| if (!hasBlocked(asset, id)) return error.BlockedRowMissing;

    // The entry contract must still describe the three source forms.
    var forms = [_]bool{ false, false, false };
    for (asset.entry_contract.forms) |form| {
        if (std.mem.eql(u8, form.selector, "0xFF") and form.mode == 4 and form.operand_bytes == 2) forms[0] = true;
        if (std.mem.eql(u8, form.selector, "0xFE") and form.mode == 5 and form.operand_bytes == 1) forms[1] = true;
        if (std.mem.eql(u8, form.selector, "other") and form.mode == 3 and form.operand_bytes == 1) forms[2] = true;
    }
    for (forms) |seen| if (!seen) return error.EntryFormMissing;

    // Boss contract: the two mechanics bits are declared with consumers.
    if (!hasFeature(&asset.boss_contract, 0x4000)) return error.SpecialDeathUndocumented;
    if (!hasFeature(&asset.boss_contract, 0x8000)) return error.AccuracyBypassUndocumented;

    for (asset.bosses) |boss| {
        if (!validId(boss.id)) return error.InvalidBossId;
        if (boss.level == 0 or boss.hp == 0) return error.InvalidBossStats;
        if (boss.feature_mask & 0xC000 == 0) return error.BossWithoutMechanic;
        if (boss.feature_mask & 0x4000 != 0) {
            if (!std.mem.eql(u8, boss.mechanics, "scripted_death")) return error.MechanicsMismatch;
        } else if (!std.mem.eql(u8, boss.mechanics, "accuracy_bypass")) {
            return error.MechanicsMismatch;
        }
    }

    for (asset.enemies) |enemy| {
        if (!validId(enemy.id)) return error.InvalidEnemyId;
        if (enemy.level == 0 or enemy.hp == 0) return error.InvalidEnemyStats;
    }

    for (asset.battles) |*battle| {
        if (!validId(battle.id)) return error.InvalidBattleId;
        if (!validHash(battle.source_sha256)) return error.InvalidSourceHash;
        if (battle.section >= 64) return error.InvalidSection;
        if (battle.entry < battle.base_index) return error.InvalidEntry;
        if (battle.encounters.len == 0) return error.BattleWithoutEncounter;
        if (battle.rooms.len == 0) return error.BattleWithoutRoom;

        const archive_boss = battle.flags & 0x40000000 != 0;
        if ((battle.flags & 0x80000000) != 0 and battle.escape_allowed) return error.EscapeFlagMismatch;
        if ((battle.flags & 0x80000000) == 0 and !battle.escape_allowed) return error.EscapeFlagMismatch;
        if (archive_boss and !std.mem.eql(u8, battle.archive, "boss")) return error.ArchiveMismatch;
        if (!archive_boss and !std.mem.eql(u8, battle.archive, "standard")) return error.ArchiveMismatch;
        if (battle.boss_present != (battle.boss_ids.len != 0)) return error.BossPresenceMismatch;
        if (battle.boss_present and !std.mem.eql(u8, battle.end_trigger, "unproven")) {
            return error.BossEndTriggerNotBlocked;
        }
        if (!battle.boss_present and !std.mem.eql(u8, battle.end_trigger, "live_count")) {
            return error.EndTriggerMismatch;
        }
        for (battle.boss_ids) |id| {
            if (bossById(asset, id) == null) return error.UnknownBoss;
        }
        for (battle.encounters) |encounter| {
            if (encounter.active == 0 or encounter.active > 6) return error.InvalidActiveCount;
            if (encounter.enemy_ids.len != encounter.active) return error.EnemyIdCountMismatch;
            if (encounter.roster_slots.len != encounter.active) return error.RosterSlotCountMismatch;
            for (encounter.enemy_ids) |id| if (enemyById(asset, id) == null) return error.UnknownEnemy;
            for (encounter.roster_slots) |slot| if (slot == 0 or slot > 32) return error.InvalidRosterSlot;
        }
    }
}

// ---------------------------------------------------------------------------
// Result semantics
// ---------------------------------------------------------------------------

/// The three source signals a host reads from the battle scene.  They are named
/// for their role, not for the PS1 offsets: those live in the packet.
pub const Signal = struct {
    live_enemies: u32,
    end_flag: bool,
    defeat_flag: bool,
};

pub const Branch = enum {
    victory,
    no_reward_end,
    defeat,
    battle_open,
};

pub const Action = union(enum) {
    return_to_field,
    special_module: u8,
    none,
};

pub const Consequence = struct {
    branch: Branch,
    rewards: bool,
    action: Action,
    /// The source never hands the battle result to story code, so the port does
    /// not either: every consequence names this explicitly.
    story_mutation: enum { none } = .none,
    reason: []const u8,
};

/// `0x800F74A8` + `0x800DE150..0x800DE184` + `0x800DE2B8`, as one rule.
///
/// Order matters: the teardown reads `scene+0x38` for routing, so a defeat with
/// a stale end flag still routes to the game-over module, while the reward gate
/// refuses both.
pub fn classify(signal: Signal) Consequence {
    if (signal.defeat_flag) {
        return .{
            .branch = .defeat,
            .rewards = false,
            .action = .{ .special_module = defeat_selector },
            .reason = "scene+0x38 set: no rewards; teardown routes to the GAMEOVER module",
        };
    }
    if (signal.end_flag) {
        return .{
            .branch = .no_reward_end,
            .rewards = false,
            .action = .return_to_field,
            .reason = "scene+0x34 set: battle over without rewards; the field return is the source route",
        };
    }
    if (signal.live_enemies == 0) {
        return .{
            .branch = .victory,
            .rewards = true,
            .action = .return_to_field,
            .reason = "all enemy slots down and both result flags clear: the reward initializer is installed",
        };
    }
    return .{
        .branch = .battle_open,
        .rewards = false,
        .action = .none,
        .reason = "enemies remain and no end request: the source has no consequence yet",
    };
}

/// Classify a real packet battle.  A boss battle cannot report zero live enemies:
/// `0x4000` skips the live-count decrement, so such a signal is inconsistent and
/// is refused instead of being rounded up to a victory.
pub fn classifyBattle(battle: *const Battle, signal: Signal) !Consequence {
    if (battle.boss_present and signal.live_enemies == 0 and !signal.defeat_flag and !signal.end_flag) {
        return error.InconsistentLiveCount;
    }
    const result = classify(signal);
    if (battle.boss_present and result.branch == .victory) {
        return error.BossVictoryWithoutEndRequest;
    }
    return result;
}

// ---------------------------------------------------------------------------
// Host commit protocol
// ---------------------------------------------------------------------------

pub const Phase = enum { idle, active, pending, resolved, committed };

pub const Receipt = struct {
    battle: [max_id]u8 = undefined,
    battle_len: u8 = 0,
    branch: Branch = .battle_open,
    rewards: bool = false,
    action: Action = .none,
    sequence: u32 = 0,

    pub fn id(self: *const Receipt) []const u8 {
        return self.battle[0..self.battle_len];
    }
};

pub const Capture = struct {
    token: u64,
    phase: Phase,
    battle: [max_id]u8,
    battle_len: u8,
    pending: ?Consequence,
    committed: ?Receipt,
    commit_count: u32,
};

/// The host owns the transition.  `begin` takes a stable per-battle token; the
/// token is the ownership, so a snapshot restored after a restart cannot be
/// committed by a second owner and a commit cannot run twice.
///
/// A consequence borrows its `reason` from the packet, so the opened asset must
/// outlive the host (the normal arrangement: one packet, one session).
pub const Host = struct {
    token: u64 = 0,
    battle: [max_id]u8 = undefined,
    battle_len: u8 = 0,
    phase: Phase = .idle,
    pending: ?Consequence = null,
    committed: ?Receipt = null,
    commit_count: u32 = 0,

    pub fn id(self: *const Host) []const u8 {
        return self.battle[0..self.battle_len];
    }

    pub fn begin(self: *Host, battle: *const Battle, token: u64) !void {
        if (self.phase != .idle) return error.HostBusy;
        if (token == 0) return error.OwnershipMissing;
        if (battle.id.len == 0 or battle.id.len > max_id) return error.InvalidBattleId;
        @memcpy(self.battle[0..battle.id.len], battle.id);
        self.battle_len = @intCast(battle.id.len);
        self.token = token;
        self.phase = .active;
        self.pending = null;
        self.committed = null;
        self.commit_count = 0;
    }

    /// Resolve (or re-resolve) the current battle.  A still-open battle becomes
    /// `pending`; pending is a real state, not a quiet victory.
    pub fn resolve(self: *Host, battle: *const Battle, signal: Signal) !Consequence {
        if (self.phase != .active and self.phase != .pending) return error.HostNotActive;
        if (!std.mem.eql(u8, self.id(), battle.id)) return error.BattleMismatch;
        const result = try classifyBattle(battle, signal);
        self.pending = result;
        self.phase = if (result.branch == .battle_open) .pending else .resolved;
        return result;
    }

    /// Commit the resolved consequence exactly once.  Pending and already
    /// committed states are refused, so a restart between resolve and commit can
    /// only complete the same consequence with the same owner.
    pub fn commit(self: *Host) !Receipt {
        if (self.committed != null) return error.AlreadyCommitted;
        if (self.phase == .pending) return error.ResultPending;
        if (self.phase != .resolved) return error.NotResolved;
        if (self.pending == null) return error.NotResolved;
        const consequence = self.pending.?;
        var receipt = Receipt{
            .battle_len = self.battle_len,
            .branch = consequence.branch,
            .rewards = consequence.rewards,
            .action = consequence.action,
            .sequence = self.commit_count + 1,
        };
        @memcpy(receipt.battle[0..self.battle_len], self.battle[0..self.battle_len]);
        self.commit_count += 1;
        self.committed = receipt;
        self.phase = .committed;
        return receipt;
    }

    pub fn capture(self: *const Host) Capture {
        return .{
            .token = self.token,
            .phase = self.phase,
            .battle = self.battle,
            .battle_len = self.battle_len,
            .pending = self.pending,
            .committed = self.committed,
            .commit_count = self.commit_count,
        };
    }

    /// Restore into an idle host.  The snapshot carries the owner token, so a
    /// different owner cannot resume the transition.
    pub fn restore(self: *Host, snapshot: Capture) !void {
        if (self.phase != .idle) return error.HostBusy;
        if (snapshot.token == 0) return error.OwnershipMissing;
        if (snapshot.phase == .idle) return error.InvalidSnapshot;
        if (snapshot.battle_len == 0 or snapshot.battle_len > max_id) return error.InvalidSnapshot;
        if (snapshot.phase == .committed and snapshot.committed == null) return error.InvalidSnapshot;
        self.token = snapshot.token;
        self.battle = snapshot.battle;
        self.battle_len = snapshot.battle_len;
        self.phase = snapshot.phase;
        self.pending = snapshot.pending;
        self.committed = snapshot.committed;
        self.commit_count = snapshot.commit_count;
    }

    /// A second owner may not adopt a transition it did not begin.
    pub fn adopt(self: *Host, snapshot: Capture, token: u64) !void {
        if (snapshot.token != token) return error.OwnershipMismatch;
        try self.restore(snapshot);
    }
};
