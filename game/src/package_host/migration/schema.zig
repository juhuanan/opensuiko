//! The full-campaign snapshot schema (`suikoden-campaign-save/1`).
//!
//! Five durable sections share one envelope so that a campaign is committed or
//! not committed as a whole:
//!
//!   roster  - 108-record presence map, party/reserve order, member progression
//!   quest   - 240-byte source scenario, money, block and settled quest entries
//!   world   - map/room position, camera, facing and travel/battle receipts
//!   hq      - stage, recruit bytes, tablet cursor, unlocked rooms/services
//!   mode    - the mode the player is in and that mode's typed resume facts
//!
//! `pending` is a mode result that has been produced but not yet committed.
//! It is part of the snapshot on purpose: a failed or interrupted write leaves
//! the player's campaign and this pending ownership exactly as they were, so the
//! result is retryable instead of lost or applied twice.
//!
//! Every value is fixed-size, so capture is a copy and a rejected transaction
//! cannot leave a half-mutated campaign behind.

const std = @import("std");
const ids = @import("ids.zig");
const content = @import("content.zig");

pub const schema_id = "suikoden-campaign-save/1";
pub const max_member_inventory = 9;
pub const max_money: u32 = 999_999;
pub const max_recruit_records = 108;

pub const Snapshot = struct {
    schema: []const u8 = schema_id,
    content: content.Ref = .{},
    revision: u64 = 0,
    last_receipt: u64 = 0,
    saved_ticks: u64 = 0,
    roster: Roster = .{},
    quest: Quest = .{},
    world: World = .{},
    hq: Hq = .{},
    mode: Mode = .{},
    pending: ?Pending = null,

    pub fn validate(self: *const Snapshot, content_ref: *const content.Content) !void {
        if (!std.mem.eql(u8, self.schema, schema_id)) return error.UnsupportedCampaignSchema;
        try self.content.validate();
        _ = try content_ref.rebind(self.content);
        if (self.last_receipt > self.revision) return error.InvalidCampaignRevision;
        if (self.roster.identities.bytes[13] & 0xF0 != 0) return error.InvalidRecruitMap;
        try self.roster.validate(content_ref);
        try self.quest.validate(content_ref);
        try self.world.validate(content_ref);
        try self.hq.validate(content_ref);
        try self.mode.validate(content_ref, self);
        if (self.pending) |pending| try pending.validate(self, content_ref);
    }

    /// Apply the pending result to a copy of `self`.  The caller persists the
    /// copy and only then adopts it; a write failure therefore leaves both the
    /// campaign and the pending ownership untouched.
    pub fn applyPending(self: Snapshot, content_ref: *const content.Content) ApplyError!Snapshot {
        const pending = self.pending orelse return error.PendingEffectsEmpty;
        if (pending.receipt <= self.last_receipt) return error.StalePendingReceipt;
        if (pending.effects.len == 0) return error.PendingEffectsEmpty;
        if (pending.content_revision > content_ref.revision()) return error.InvalidContentRevision;
        var next = self;
        for (pending.effects.slice()) |effect| try applyEffect(&next, content_ref, effect, pending.receipt);
        next.last_receipt = pending.receipt;
        next.revision += 1;
        next.pending = null;
        return next;
    }
};

pub const Status = enum { healthy, poisoned, unconscious };

pub const InventorySlot = struct {
    id: ids.Id(32) = .{},
    uses: u16 = 0,

    pub fn isSet(self: InventorySlot) bool {
        return self.id.isSet();
    }
};

pub const Member = struct {
    id: ids.Id(32) = .{},
    level: u8 = 1,
    experience: u32 = 0,
    hp: u16 = 1,
    max_hp: u16 = 1,
    weapon_level: u8 = 1,
    status: Status = .healthy,
    rune_charges: [4]u16 = @splat(0),
    max_rune_charges: [4]u16 = @splat(0),
    inventory: ids.List(max_member_inventory, InventorySlot) = .{},
    equipment: ids.List(5, ?ids.Id(32)) = .{},
    rune: ?ids.Id(32) = null,

    pub fn validate(self: Member, content_ref: *const content.Content) !void {
        if (!content_ref.hasRoster(self.id)) return error.UnknownRosterId;
        if (self.level == 0 or self.level > 99) return error.InvalidMemberLevel;
        if (self.max_hp == 0 or self.max_hp > 9_999) return error.InvalidMemberHp;
        if (self.hp > self.max_hp) return error.InvalidMemberHp;
        if (self.weapon_level == 0 or self.weapon_level > 16) return error.InvalidWeaponLevel;
        for (self.rune_charges, self.max_rune_charges) |charges, maximum| {
            if (maximum > 999 or charges > maximum) return error.InvalidRuneCharges;
        }
        for (self.inventory.slice(), 0..) |slot, index| {
            if (!slot.isSet()) return error.InvalidInventory;
            if (!content_ref.hasItem(slot.id)) return error.UnknownItemId;
            if (slot.uses > 999) return error.InvalidInventory;
            for (self.inventory.slice()[0..index]) |earlier| if (std.meta.eql(earlier.id, slot.id)) return error.DuplicateItemId;
        }
        for (self.equipment.slice(), 0..) |maybe, index| {
            const id = maybe orelse continue;
            if (!content_ref.hasEquipment(id)) return error.UnknownEquipmentId;
            for (self.equipment.slice()[0..index]) |earlier| if (earlier) |other| {
                if (std.meta.eql(other, id)) return error.DuplicateEquipmentId;
            };
        }
        if (self.rune) |rune| if (!content_ref.hasRune(rune)) return error.UnknownRuneId;
    }
};

pub const Roster = struct {
    /// 108 source recruit records, two bits each; unused high bits must be 0.
    identities: ids.HexBytes(14) = .{},
    party: ids.List(6, ids.Id(32)) = .{},
    reserves: ids.List(72, ids.Id(32)) = .{},
    members: ids.List(78, Member) = .{},

    pub fn validate(self: Roster, content_ref: *const content.Content) !void {
        for (self.party.slice(), 0..) |id, index| {
            if (!content_ref.hasRoster(id)) return error.UnknownRosterId;
            for (self.party.slice()[0..index]) |earlier| if (std.meta.eql(earlier, id)) return error.DuplicateRosterId;
        }
        for (self.reserves.slice(), 0..) |id, index| {
            if (!content_ref.hasRoster(id)) return error.UnknownRosterId;
            if (self.party.contains(id)) return error.DuplicateRosterId;
            for (self.reserves.slice()[0..index]) |earlier| if (std.meta.eql(earlier, id)) return error.DuplicateRosterId;
        }
        for (self.members.slice(), 0..) |member, index| {
            try member.validate(content_ref);
            for (self.members.slice()[0..index]) |earlier| if (std.meta.eql(earlier.id, member.id)) return error.DuplicateRosterId;
        }
        for (self.party.slice()) |id| if (!self.hasMember(id)) return error.PartyMemberMissing;
        for (self.reserves.slice()) |id| if (!self.hasMember(id)) return error.PartyMemberMissing;
    }

    pub fn hasMember(self: Roster, id: ids.Id(32)) bool {
        for (self.members.slice()) |member| if (std.meta.eql(member.id, id)) return true;
        return false;
    }
};

pub const QuestState = enum { pending, settled, failed };

pub const QuestEntry = struct {
    id: ids.Id(32) = .{},
    state: QuestState = .pending,
    receipt: u64 = 0,
};

pub const Quest = struct {
    scenario: ids.HexBytes(240) = .{},
    money: u32 = 0,
    block: ids.Id(32) = .{},
    quests: ids.List(64, QuestEntry) = .{},

    pub fn validate(self: Quest, content_ref: *const content.Content) !void {
        if (self.money > max_money) return error.InvalidMoney;
        if (!content_ref.hasBlock(self.block)) return error.UnknownBlock;
        for (self.quests.slice(), 0..) |entry, index| {
            if (!content_ref.hasQuest(entry.id)) return error.UnknownQuestId;
            for (self.quests.slice()[0..index]) |earlier| if (std.meta.eql(earlier.id, entry.id)) return error.DuplicateQuestId;
        }
    }
};

pub const World = struct {
    block: ids.Id(32) = .{},
    map: ids.Id(32) = .{},
    room: ids.Id(32) = .{},
    x: i32 = 0,
    y: i32 = 0,
    camera_x: i32 = 0,
    camera_y: i32 = 0,
    facing: u8 = 0,
    travel_receipt: u64 = 0,
    battle_receipt: u64 = 0,

    pub fn validate(self: World, content_ref: *const content.Content) !void {
        if (!content_ref.hasBlock(self.block)) return error.UnknownBlock;
        // The world map is required in world mode and optional in a field save:
        // the canonical opening room has no world-map place of its own.
        if (self.map.isSet()) {
            const map = content_ref.place(self.map) orelse return error.UnknownWorldMap;
            if (map.kind != .map or !std.meta.eql(map.block, self.block)) return error.WorldBlockMismatch;
        }
        if (self.room.isSet()) {
            const room = content_ref.place(self.room) orelse return error.UnknownRoom;
            if (room.kind != .room or !std.meta.eql(room.block, self.block)) return error.WorldBlockMismatch;
            if (self.x < 0 or self.y < 0 or self.x > 2040 or self.y > 2040) return error.InvalidWorldPosition;
            if (@mod(self.x, 8) != 0 or @mod(self.y, 8) != 0) return error.InvalidWorldPosition;
        } else if (self.x != 0 or self.y != 0) return error.InvalidWorldPosition;
        if (self.camera_x < -1024 or self.camera_x > 4096 or self.camera_y < -1024 or self.camera_y > 4096) return error.InvalidWorldCamera;
        if (self.facing > 3) return error.InvalidWorldFacing;
    }
};

pub const HqScreen = enum { field, tablet, service };

pub const Hq = struct {
    stage: u8 = 0,
    recruit: ids.HexBytes(108) = .{},
    tablet_cursor: u8 = 0,
    screen: HqScreen = .field,
    room: ids.Id(32) = .{},
    rooms: ids.List(64, ids.Id(32)) = .{},
    services: ids.List(16, ids.Id(32)) = .{},
    revision: u64 = 0,

    pub fn validate(self: Hq, content_ref: *const content.Content) !void {
        if (!content_ref.hasHqStage(self.stage)) return error.UnknownHqStage;
        if (self.tablet_cursor > 107) return error.InvalidTabletCursor;
        if (self.room.isSet() and !content_ref.hasHqRoom(self.room)) return error.UnknownHqRoom;
        for (self.rooms.slice(), 0..) |id, index| {
            if (!content_ref.hasHqRoom(id)) return error.UnknownHqRoom;
            for (self.rooms.slice()[0..index]) |earlier| if (std.meta.eql(earlier, id)) return error.DuplicateHqRoom;
        }
        for (self.services.slice(), 0..) |id, index| {
            if (!content_ref.hasService(id)) return error.UnknownService;
            for (self.services.slice()[0..index]) |earlier| if (std.meta.eql(earlier, id)) return error.DuplicateService;
        }
        for (self.recruit.bytes) |byte| if (byte & 0xFC != 0) return error.InvalidRecruitByte;
    }
};

pub const ModeKind = enum { world, field, battle, duel, minigame, war, hq, ending, credits };

pub const BattleResume = struct {
    round: u16 = 1,
    receipt: u64 = 0,
    active_party: u8 = 1,
};

pub const DuelResume = struct {
    id: ids.Id(32) = .{},
    phase: u8 = 0,
    gauge: u16 = 0,
};

pub const MinigameResume = struct {
    id: ids.Id(32) = .{},
    seed: u64 = 0,
    step: u32 = 0,
};

pub const WarResume = struct {
    /// Campaign-side id of the called battle; the war internals stay external.
    id: ids.Id(32) = .{},
    /// Opaque accepted handoff id from the war owner.
    handoff: ids.Id(32) = .{},
};

pub const Mode = struct {
    kind: ModeKind = .world,
    battle: ?BattleResume = null,
    duel: ?DuelResume = null,
    minigame: ?MinigameResume = null,
    war: ?WarResume = null,

    pub fn validate(self: Mode, content_ref: *const content.Content, snapshot: *const Snapshot) !void {
        const resumes = @as(u8, @intFromBool(self.battle != null)) + @as(u8, @intFromBool(self.duel != null)) + @as(u8, @intFromBool(self.minigame != null)) + @as(u8, @intFromBool(self.war != null));
        switch (self.kind) {
            .world => if (resumes != 0 or snapshot.world.room.isSet() or !snapshot.world.map.isSet()) return error.InvalidModeState,
            .field => if (resumes != 0 or !snapshot.world.room.isSet()) return error.InvalidModeState,
            .battle => {
                const battle = self.battle orelse return error.MissingModeResume;
                if (resumes != 1) return error.InvalidModeState;
                if (battle.round == 0 or battle.round > 999 or battle.active_party == 0 or battle.active_party > 6) return error.InvalidBattleResume;
                if (battle.active_party > snapshot.roster.party.len) return error.InvalidBattleResume;
            },
            .duel => {
                const duel = self.duel orelse return error.MissingModeResume;
                if (resumes != 1 or !content_ref.hasDuel(duel.id)) return error.InvalidModeState;
                if (duel.phase > 3) return error.InvalidDuelResume;
            },
            .minigame => {
                const game = self.minigame orelse return error.MissingModeResume;
                if (resumes != 1 or !content_ref.hasMinigame(game.id)) return error.InvalidModeState;
            },
            .war => {
                const war = self.war orelse return error.MissingModeResume;
                if (resumes != 1 or !content_ref.hasWarBattle(war.id)) return error.InvalidModeState;
                try war.handoff.validate();
            },
            .hq => if (resumes != 0) return error.InvalidModeState,
            .ending, .credits => if (resumes != 0) return error.InvalidModeState,
        }
    }
};

pub const EffectKind = enum { money, recruit_record, party_add, party_remove, quest_state, hq_stage, service_unlock };

pub const Effect = struct {
    kind: EffectKind = .money,
    id: ids.Id(32) = .{},
    amount: i64 = 0,
    value: u8 = 0,
};

pub const Pending = struct {
    receipt: u64 = 0,
    owner: ModeKind = .world,
    content_revision: u32 = 0,
    effects: ids.List(32, Effect) = .{},

    pub fn validate(self: Pending, snapshot: *const Snapshot, content_ref: *const content.Content) !void {
        if (self.receipt <= snapshot.last_receipt) return error.StalePendingReceipt;
        if (self.effects.len == 0 or self.effects.len > 32) return error.PendingEffectsEmpty;
        if (self.content_revision > content_ref.revision()) return error.InvalidContentRevision;
        switch (self.owner) {
            .battle, .duel, .minigame, .war, .world, .field, .hq => {},
            .ending, .credits => return error.PendingEffectInvalid,
        }
        var probe = snapshot.*;
        for (self.effects.slice()) |effect| try applyEffect(&probe, content_ref, effect, self.receipt);
    }
};

pub const ApplyError = error{
    InvalidContentRevision,
    StalePendingReceipt,
    PendingEffectsEmpty,
    PendingEffectInvalid,
    MoneyOutOfRange,
    UnknownRosterId,
    PartyFull,
    PartyMemberAbsent,
    PartyMemberPresent,
    PartyMemberMissing,
    UnknownQuestId,
    UnknownHqStage,
    UnknownService,
    ServiceListFull,
    RecruitRecordOutOfRange,
    TooManyEntries,
};

pub fn applyEffect(snapshot: *Snapshot, content_ref: *const content.Content, effect: Effect, receipt: u64) ApplyError!void {
    switch (effect.kind) {
        .money => {
            const next = @as(i64, snapshot.quest.money) + effect.amount;
            if (next < 0 or next > max_money) return error.MoneyOutOfRange;
            snapshot.quest.money = @intCast(next);
        },
        .recruit_record => {
            if (effect.amount < 0 or effect.amount >= max_recruit_records) return error.RecruitRecordOutOfRange;
            if (effect.id.isSet() and !content_ref.hasRoster(effect.id)) return error.UnknownRosterId;
            const index: usize = @intCast(effect.amount);
            const byte = index / 8;
            const shift: u3 = @intCast((index % 8) * 2);
            const mask: u8 = @as(u8, 0x3) << shift;
            if (effect.value != 0) {
                snapshot.roster.identities.bytes[byte] |= mask;
            } else {
                snapshot.roster.identities.bytes[byte] &= ~mask;
            }
        },
        .party_add => {
            if (!content_ref.hasRoster(effect.id)) return error.UnknownRosterId;
            if (snapshot.roster.party.contains(effect.id)) return error.PartyMemberPresent;
            if (snapshot.roster.party.len == snapshot.roster.party.items.len) return error.PartyFull;
            if (!snapshot.roster.hasMember(effect.id)) return error.PartyMemberMissing;
            try snapshot.roster.party.append(effect.id);
        },
        .party_remove => {
            const index = snapshot.roster.party.indexOf(effect.id) orelse return error.PartyMemberAbsent;
            snapshot.roster.party.removeAt(index);
        },
        .quest_state => {
            if (!content_ref.hasQuest(effect.id)) return error.UnknownQuestId;
            const state: QuestState = switch (effect.value) {
                0 => .pending,
                1 => .settled,
                2 => .failed,
                else => return error.PendingEffectInvalid,
            };
            for (snapshot.quest.quests.mutableSlice()) |*entry| {
                if (std.meta.eql(entry.id, effect.id)) {
                    entry.state = state;
                    entry.receipt = receipt;
                    return;
                }
            }
            try snapshot.quest.quests.append(.{ .id = effect.id, .state = state, .receipt = receipt });
        },
        .hq_stage => {
            if (effect.amount < 0 or effect.amount > 15) return error.UnknownHqStage;
            const stage: u8 = @intCast(effect.amount);
            if (!content_ref.hasHqStage(stage)) return error.UnknownHqStage;
            snapshot.hq.stage = stage;
            snapshot.hq.revision = receipt;
        },
        .service_unlock => {
            if (!content_ref.hasService(effect.id)) return error.UnknownService;
            if (snapshot.hq.services.contains(effect.id)) return;
            if (snapshot.hq.services.len == snapshot.hq.services.items.len) return error.ServiceListFull;
            try snapshot.hq.services.append(effect.id);
        },
    }
}

pub fn newGame(content_ref: *const content.Content, block: ids.Id(32), map: ids.Id(32)) !Snapshot {
    if (!content_ref.hasBlock(block)) return error.UnknownBlock;
    const place = content_ref.place(map) orelse return error.UnknownWorldMap;
    if (place.kind != .map) return error.UnknownWorldMap;
    var snapshot: Snapshot = .{
        .content = content_ref.ref(),
        .quest = .{ .money = 0, .block = block },
        .world = .{ .block = block, .map = map },
        .hq = .{ .stage = content_ref.doc.hq_stages[0] },
        .mode = .{ .kind = .world },
    };
    try snapshot.validate(content_ref);
    return snapshot;
}
