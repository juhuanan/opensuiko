//! Mode-result data model.
//!
//! A mode result is an immutable, self-contained proposal produced by one
//! ordinary mode owner (travel, battle or party).  It carries the before-facts
//! it was computed against, one ordered effect list, and the receipt it wants
//! to publish.  This file defines the value types and their semantic digests;
//! `host.zig` owns the transaction.  Everything here is a fixed-size value:
//! there is no borrowed content, allocator or pointer in the durable envelope.
const std = @import("std");

pub const schema = "suikoden-mode-result-host/1";
pub const result_schema = "suikoden-mode-result/1";

pub const max_id_len = 63;
pub const max_effects = 8;
pub const max_members = 6;
pub const max_inventory = 9;
pub const equipment_slots = 5;
pub const shared_slots = 7;
pub const story_bytes = 240;
pub const money_cap: u32 = 999999;
pub const max_warehouse_entries = 24;
pub const warehouse_capacity: u16 = 254;
pub const max_retries: u16 = 8;
/// The three owners of the original envelope.  Their receipts are part
/// of `storeDigest`, so every existing conformance digest stays valid.
pub const base_owner_count = 3;
/// One more slot for the optional-game (`arcade`) result family integrated
/// by HQ.  Its receipt is pinned by `modeDigest`, not by `storeDigest`.
pub const owner_count = base_owner_count + 1;
/// The `gs+0x230` status-flag page an optional-game result may publish.
pub const status_bytes = 16;
/// KARUTA per-round records (four rounds).
pub const record_rounds = 4;

/// Short ordinary identity (character, item, encounter, entry or menu id).
/// Printable ASCII only; the durable envelope stores it as a JSON string.
pub const Id = struct {
    len: u8 = 0,
    bytes: [max_id_len]u8 = @splat(0),

    /// An empty string is the explicit "unset" identity used by unused party,
    /// equipment and warehouse slots.  Required identities are checked by the
    /// model validators, never by silently fabricating a name.
    pub fn init(text: []const u8) !Id {
        if (text.len > max_id_len) return error.InvalidId;
        for (text) |char| if (char < 0x21 or char > 0x7e) return error.InvalidId;
        var id: Id = .{ .len = @intCast(text.len) };
        @memcpy(id.bytes[0..text.len], text);
        return id;
    }

    pub fn slice(self: *const Id) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(a: Id, b: Id) bool {
        return a.len == b.len and std.mem.eql(u8, a.bytes[0..a.len], b.bytes[0..b.len]);
    }

    pub fn isZero(self: Id) bool {
        return self.len == 0;
    }

    pub fn jsonStringify(self: Id, writer: anytype) !void {
        try writer.write(self.slice());
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Id {
        const text = try std.json.innerParse([]const u8, allocator, source, options);
        return init(text) catch return error.SyntaxError;
    }

    /// The world-session envelope parses nested values through
    /// `innerParseFromValue`, so the durable Id must also accept an
    /// already-parsed JSON string.
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Id {
        _ = allocator;
        _ = options;
        if (source != .string) return error.UnexpectedToken;
        return init(source.string) catch return error.UnexpectedToken;
    }
};

/// SHA-256, serialized as lowercase hex.  The transaction binds content by it.
pub const Sha = struct {
    bytes: [32]u8 = @splat(0),

    pub fn initHex(text: []const u8) !Sha {
        if (text.len != 64) return error.InvalidSha;
        var sha: Sha = .{};
        _ = std.fmt.hexToBytes(&sha.bytes, text) catch return error.InvalidSha;
        return sha;
    }

    pub fn hex(self: Sha) [64]u8 {
        return std.fmt.bytesToHex(self.bytes, .lower);
    }

    pub fn eql(a: Sha, b: Sha) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    pub fn isZero(self: Sha) bool {
        for (self.bytes) |byte| if (byte != 0) return false;
        return true;
    }

    pub fn jsonStringify(self: Sha, writer: anytype) !void {
        const text = self.hex();
        try writer.write(&text);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Sha {
        const text = try std.json.innerParse([]const u8, allocator, source, options);
        return initHex(text) catch return error.SyntaxError;
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Sha {
        _ = allocator;
        _ = options;
        if (source != .string) return error.UnexpectedToken;
        return initHex(source.string) catch return error.UnexpectedToken;
    }
};

pub const Owner = enum { travel, battle, party, arcade };
pub const ResultKind = enum { travel_route, travel_board, travel_teleport, travel_mirror, battle_result, party_item, optional_game };
pub const Facing = enum { north, east, south, west };
pub const Place = enum { world, field, battle };
pub const Status = enum { healthy, poisoned, unconscious };

pub fn ownerOf(kind: ResultKind) Owner {
    return switch (kind) {
        .travel_route, .travel_board, .travel_teleport, .travel_mirror => .travel,
        .battle_result => .battle,
        .party_item => .party,
        .optional_game => .arcade,
    };
}

pub fn ownerIndex(owner: Owner) usize {
    return @backingInt(owner);
}

pub const Camera = struct {
    x: i32 = 0,
    y: i32 = 0,
    facing: Facing = .south,
    place: Place = .world,
};

pub const Stack = struct {
    item: Id = .{},
    uses: u16 = 0,
    identified: bool = true,
};

pub const Member = struct {
    id: Id = .{},
    hp: u16 = 0,
    max_hp: u16 = 0,
    status: Status = .healthy,
    level: u8 = 0,
    experience: u32 = 0,
    weapon_level: u8 = 0,
    inventory: [max_inventory]?Stack = @splat(null),
    equipment: [equipment_slots]?Id = @splat(null),

    pub fn validate(self: Member) !void {
        if (self.id.isZero()) return error.InvalidMember;
        if (self.max_hp == 0 or self.hp > self.max_hp) return error.InvalidMember;
        if (self.level == 0 or self.level > 99 or self.weapon_level > 99) return error.InvalidMember;
        var empty = false;
        for (self.inventory) |maybe| {
            if (maybe) |stack| {
                if (empty or stack.item.isZero()) return error.InvalidMember;
            } else empty = true;
        }
        for (self.equipment, 0..) |maybe, index| {
            if (maybe) |item| {
                if (item.isZero()) return error.InvalidMember;
                for (self.equipment[0..index]) |previous| {
                    if (previous) |other| if (other.eql(item)) return error.InvalidMember;
                }
            }
        }
    }
};

pub const Party = struct {
    members: [max_members]Member = @splat(Member{}),
    count: u8 = 0,

    pub fn validate(self: Party) !void {
        if (self.count > max_members) return error.InvalidParty;
        for (self.members, 0..) |member, index| {
            if (index < self.count) {
                try member.validate();
                for (self.members[0..index]) |previous| {
                    if (previous.id.eql(member.id)) return error.InvalidParty;
                }
            } else if (!std.meta.eql(member, Member{})) return error.InvalidParty;
        }
    }
};

pub const WarehouseEntry = struct {
    item: Id = .{},
    quantity: u16 = 0,
};

pub const Store = struct {
    revision: u64 = 0,
    money: u32 = 0,
    price_quote: ?u32 = null,
    camera: Camera = .{},
    party: Party = .{},
    shared: [shared_slots]?Id = @splat(null),
    warehouse: [max_warehouse_entries]WarehouseEntry = @splat(WarehouseEntry{}),
    warehouse_count: u8 = 0,
    story: [story_bytes]u8 = @splat(0),
    story_bound: bool = false,
    draws_cursor: u64 = 0,
    draws_bios: ?u32 = null,
    /// Optional-game projection of `gs+0x230..0x23F` (the status-flag page).
    status: [status_bytes]u8 = @splat(0),
    /// COIN's signed running net.
    net: i32 = 0,
    /// Dice retained-winnings context.
    retained: u32 = 0,
    /// KARUTA best elapsed per round; 0 is unset.
    best: [record_rounds]u32 = @splat(0),
    receipts: [owner_count]u64 = @splat(0),

    pub fn validate(self: Store) !void {
        if (self.money > money_cap) return error.InvalidStore;
        if (self.net > 10_000_000 or self.net < -10_000_000) return error.InvalidStore;
        if (self.retained > money_cap) return error.InvalidStore;
        try self.party.validate();
        for (self.shared, 0..) |maybe, index| {
            if (maybe) |item| {
                if (item.isZero()) return error.InvalidStore;
                for (self.shared[0..index]) |previous| {
                    if (previous) |other| if (other.eql(item)) return error.InvalidStore;
                }
            }
        }
        if (self.warehouse_count > max_warehouse_entries) return error.InvalidStore;
        for (self.warehouse, 0..) |entry, index| {
            if (index < self.warehouse_count) {
                if (entry.item.isZero() or entry.quantity == 0 or entry.quantity > warehouse_capacity) return error.InvalidStore;
                for (self.warehouse[0..index]) |previous| {
                    if (previous.item.eql(entry.item)) return error.InvalidStore;
                }
            } else if (entry.item.len != 0 or entry.quantity != 0) return error.InvalidStore;
        }
    }

    pub fn warehouseQuantity(self: Store, item: Id) u16 {
        for (self.warehouse[0..self.warehouse_count]) |entry| {
            if (entry.item.eql(item)) return entry.quantity;
        }
        return 0;
    }

    pub fn setWarehouse(self: *Store, item: Id, quantity: u16) !void {
        if (item.isZero() or quantity > warehouse_capacity) return error.InvalidEffect;
        for (self.warehouse[0..self.warehouse_count], 0..) |entry, index| {
            if (!entry.item.eql(item)) continue;
            if (quantity == 0) {
                std.mem.copyForwards(WarehouseEntry, self.warehouse[index .. self.warehouse_count - 1], self.warehouse[index + 1 .. self.warehouse_count]);
                self.warehouse_count -= 1;
                self.warehouse[self.warehouse_count] = .{};
            } else {
                self.warehouse[index].quantity = quantity;
            }
            return;
        }
        if (quantity == 0) return;
        if (self.warehouse_count == self.warehouse.len) return error.WarehouseEntriesFull;
        self.warehouse[self.warehouse_count] = .{ .item = item, .quantity = quantity };
        self.warehouse_count += 1;
    }
};

// ---------------------------------------------------------------------------
// Ordered effects
// ---------------------------------------------------------------------------

pub const EffectKind = enum { money, price_quote, member, party, shared, warehouse, story, draws, camera, flag_publish, record, retained, net };

pub const EffectPayload = union(EffectKind) {
    money: u32,
    price_quote: ?u32,
    member: struct { index: u8 = 0, member: Member = .{} },
    party: Party,
    shared: struct { index: u8 = 0, item: ?Id = null },
    warehouse: struct { item: Id = .{}, quantity: u16 = 0 },
    story: struct { offset: u16 = 0, byte: u8 = 0 },
    draws: struct { cursor: u64 = 0, bios: ?u32 = null },
    camera: Camera,
    /// Set one mask bit in the `gs+0x230` status page (`offset` is relative).
    flag_publish: struct { offset: u8 = 0, mask: u8 = 0 },
    /// A KARUTA per-round best record; lower elapsed is better.
    record: struct { round: u8 = 0, elapsed: u32 = 0 },
    /// Dice retained winnings.
    retained: u32,
    /// COIN's signed running net.
    net: i32,
};

pub const Effect = struct {
    kind: EffectKind = .money,
    payload: EffectPayload = .{ .money = 0 },

    pub fn validate(self: Effect) !void {
        if (std.meta.activeTag(self.payload) != self.kind) return error.InvalidEffect;
        switch (self.payload) {
            .money => |amount| if (amount > money_cap) return error.InvalidEffect,
            .price_quote => |price| {
                if (price) |value| if (value > money_cap) return error.InvalidEffect;
            },
            .member => |change| {
                if (change.index >= max_members) return error.InvalidEffect;
                try change.member.validate();
            },
            .party => |party| {
                if (party.count == 0) return error.InvalidEffect;
                try party.validate();
            },
            .shared => |change| {
                if (change.index >= shared_slots) return error.InvalidEffect;
                if (change.item) |item| if (item.isZero()) return error.InvalidEffect;
            },
            .warehouse => |change| {
                if (change.item.isZero() or change.quantity > warehouse_capacity) return error.InvalidEffect;
            },
            .story => |change| {
                if (change.offset >= story_bytes) return error.InvalidEffect;
            },
            .draws => {},
            .camera => {},
            .flag_publish => |bit| {
                if (bit.offset >= status_bytes or bit.mask == 0) return error.InvalidEffect;
            },
            .record => |record| {
                if (record.round >= record_rounds or record.elapsed == 0) return error.InvalidEffect;
            },
            .retained => |value| if (value > money_cap) return error.InvalidEffect,
            .net => |value| if (value > 10_000_000 or value < -10_000_000) return error.InvalidEffect,
        }
    }

    pub fn apply(self: Effect, store: *Store) !void {
        switch (self.payload) {
            .money => |amount| store.money = amount,
            .price_quote => |price| store.price_quote = price,
            .member => |change| {
                if (change.index >= store.party.count) return error.InvalidEffect;
                store.party.members[change.index] = change.member;
            },
            .party => |party| store.party = party,
            .shared => |change| {
                if (change.index >= shared_slots) return error.InvalidEffect;
                store.shared[change.index] = change.item;
            },
            .warehouse => |change| try store.setWarehouse(change.item, change.quantity),
            .story => |change| {
                if (change.offset >= story_bytes) return error.InvalidEffect;
                if (!store.story_bound) return error.UnboundStory;
                store.story[change.offset] = change.byte;
            },
            .draws => |change| {
                store.draws_cursor = change.cursor;
                store.draws_bios = change.bios;
            },
            .camera => |camera| store.camera = camera,
            .flag_publish => |bit| {
                if (bit.offset >= status_bytes or bit.mask == 0) return error.InvalidEffect;
                store.status[bit.offset] |= bit.mask;
            },
            .record => |record| {
                if (record.round >= record_rounds or record.elapsed == 0) return error.InvalidEffect;
                if (store.best[record.round] == 0 or record.elapsed < store.best[record.round]) {
                    store.best[record.round] = record.elapsed;
                }
            },
            .retained => |value| store.retained = value,
            .net => |value| store.net = value,
        }
    }
};

// ---------------------------------------------------------------------------
// Result envelope
// ---------------------------------------------------------------------------

/// Before-facts the result was computed against.  The host revalidates every
/// one of them before the first mutation and again before publication.
pub const Expected = struct {
    content_sha256: Sha = .{},
    revision: u64 = 0,
    money: u32 = 0,
    price: ?u32 = null,
    roster: u64 = 0,
    ledger: u64 = 0,
    story: u64 = 0,
    camera: Camera = .{},
    pending_owner: ?Owner = null,
    receipt: u64 = 0,
    /// Digest of the optional-game facts (`net`, `status`, `retained`, `best`,
    /// draw cursor/tape) the result was computed against.  Required for
    /// `.optional_game` and verified by the host; 0 for every other family.
    mode: u64 = 0,
};

pub const Result = struct {
    schema: Id = .{},
    owner: Owner = .travel,
    kind: ResultKind = .travel_route,
    entry_id: Id = .{},
    receipt: u64 = 0,
    expected: Expected = .{},
    effect_count: u8 = 0,
    effects: [max_effects]Effect = @splat(Effect{}),

    pub fn validate(self: Result) !void {
        if (!std.mem.eql(u8, self.schema.slice(), result_schema)) return error.InvalidResult;
        if (ownerOf(self.kind) != self.owner) return error.InvalidResult;
        if (self.entry_id.isZero()) return error.InvalidResult;
        if (self.expected.content_sha256.isZero()) return error.InvalidResult;
        if (self.expected.revision == std.math.maxInt(u64)) return error.InvalidResult;
        if (self.expected.money > money_cap) return error.InvalidResult;
        if (self.expected.price) |price| if (price > money_cap) return error.InvalidResult;
        const expected_receipt = std.math.add(u64, self.expected.receipt, 1) catch return error.InvalidResult;
        if (self.receipt != expected_receipt) return error.InvalidResult;
        if (self.kind == .optional_game and self.expected.mode == 0) return error.InvalidResult;
        if (self.effect_count == 0 or self.effect_count > max_effects) return error.InvalidResult;
        for (self.effects[0..self.effect_count]) |effect| try effect.validate();
        for (self.effects[self.effect_count..]) |effect| if (!std.meta.eql(effect, Effect{})) return error.InvalidResult;
        try self.validateFamily();
    }

    fn validateFamily(self: Result) !void {
        var money = false;
        var party = false;
        var draws = false;
        var camera = false;
        var ledger = false;
        var price = false;
        var mode = false;
        for (self.effects[0..self.effect_count]) |effect| switch (effect.payload) {
            .money => money = true,
            .party => party = true,
            .draws => draws = true,
            .camera => camera = true,
            .shared, .warehouse => ledger = true,
            .member => party = true,
            .story => {},
            .price_quote => price = true,
            .flag_publish, .record, .retained, .net => mode = true,
        };
        switch (self.kind) {
            .travel_route, .travel_board, .travel_teleport, .travel_mirror => {
                // Every travel continuation publishes the committed place/camera.
                if (!camera) return error.InvalidResult;
                // RNG is owned by battle; a travel result may not publish draws.
                if (draws) return error.InvalidResult;
            },
            .battle_result => {
                // world_battle.tickTransactional publishes money, party and the
                // acknowledged draw tape, and returnPlan commits the world camera.
                if (!money or !party or !draws or !camera) return error.InvalidResult;
            },
            .party_item => {
                // Item/shared/warehouse operations publish an owner mutation and
                // never consume the caller's RNG.
                if (!party and !ledger) return error.InvalidResult;
                if (draws) return error.InvalidResult;
            },
            .optional_game => {
                // Money is mandatory; COIN also publishes its net and the caller
                // RNG cursor, KARUTA a record, dice the retained winnings.  No
                // party/ledger/camera effect may ride along. Dice may publish story flags.
                if (!money) return error.InvalidResult;
                if (party or ledger or camera) return error.InvalidResult;
            },
        }
        // A mode projection is an optional-game fact only.
        if (mode) switch (self.kind) {
            .optional_game => {},
            else => return error.InvalidResult,
        };
        // A quoted price is a priced-mode fact only (board/teleport/mirror).
        if (price) switch (self.kind) {
            .travel_board, .travel_teleport, .travel_mirror => {},
            else => return error.InvalidResult,
        };
    }

    pub fn requiredEffect(self: Result, kind: EffectKind) bool {
        for (self.effects[0..self.effect_count]) |effect| if (effect.kind == kind) return true;
        return false;
    }
};

// ---------------------------------------------------------------------------
// Canonical semantic digests
// ---------------------------------------------------------------------------

const Hasher = std.hash.Fnv1a_64;

fn putU8(hasher: *Hasher, value: u8) void {
    hasher.update(&[_]u8{value});
}

fn putBool(hasher: *Hasher, value: bool) void {
    putU8(hasher, if (value) 1 else 0);
}

fn putU16(hasher: *Hasher, value: u16) void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    hasher.update(&bytes);
}

fn putU32(hasher: *Hasher, value: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hasher.update(&bytes);
}

fn putU64(hasher: *Hasher, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hasher.update(&bytes);
}

fn putI32(hasher: *Hasher, value: i32) void {
    putU32(hasher, @bitCast(value));
}

fn putId(hasher: *Hasher, id: Id) void {
    putU8(hasher, id.len);
    hasher.update(id.slice());
}

fn putOptId(hasher: *Hasher, id: ?Id) void {
    if (id) |value| {
        putU8(hasher, 1);
        putId(hasher, value);
    } else putU8(hasher, 0);
}

fn putOptU32(hasher: *Hasher, value: ?u32) void {
    if (value) |number| {
        putU8(hasher, 1);
        putU32(hasher, number);
    } else putU8(hasher, 0);
}

fn putCamera(hasher: *Hasher, camera: Camera) void {
    putI32(hasher, camera.x);
    putI32(hasher, camera.y);
    putU8(hasher, @backingInt(camera.facing));
    putU8(hasher, @backingInt(camera.place));
}

fn putStack(hasher: *Hasher, stack: ?Stack) void {
    if (stack) |value| {
        putU8(hasher, 1);
        putId(hasher, value.item);
        putU16(hasher, value.uses);
        putBool(hasher, value.identified);
    } else putU8(hasher, 0);
}

fn putMember(hasher: *Hasher, member: Member) void {
    putId(hasher, member.id);
    putU16(hasher, member.hp);
    putU16(hasher, member.max_hp);
    putU8(hasher, @backingInt(member.status));
    putU8(hasher, member.level);
    putU32(hasher, member.experience);
    putU8(hasher, member.weapon_level);
    for (member.inventory) |stack| putStack(hasher, stack);
    for (member.equipment) |item| putOptId(hasher, item);
}

fn putParty(hasher: *Hasher, party: Party) void {
    putU8(hasher, party.count);
    for (party.members[0..party.count]) |member| putMember(hasher, member);
}

fn putEffect(hasher: *Hasher, effect: Effect) void {
    putU8(hasher, @backingInt(effect.kind));
    switch (effect.payload) {
        .money => |amount| putU32(hasher, amount),
        .price_quote => |price| putOptU32(hasher, price),
        .member => |change| {
            putU8(hasher, change.index);
            putMember(hasher, change.member);
        },
        .party => |party| putParty(hasher, party),
        .shared => |change| {
            putU8(hasher, change.index);
            putOptId(hasher, change.item);
        },
        .warehouse => |change| {
            putId(hasher, change.item);
            putU16(hasher, change.quantity);
        },
        .story => |change| {
            putU16(hasher, change.offset);
            putU8(hasher, change.byte);
        },
        .draws => |change| {
            putU64(hasher, change.cursor);
            putOptU32(hasher, change.bios);
        },
        .camera => |camera| putCamera(hasher, camera),
        .flag_publish => |bit| {
            putU8(hasher, bit.offset);
            putU8(hasher, bit.mask);
        },
        .record => |record| {
            putU8(hasher, record.round);
            putU32(hasher, record.elapsed);
        },
        .retained => |value| putU32(hasher, value),
        .net => |value| putI32(hasher, value),
    }
}

pub fn rosterDigest(store: Store) u64 {
    var hasher = Hasher.init();
    hasher.update("roster/1");
    putParty(&hasher, store.party);
    return hasher.final();
}

pub fn ledgerDigest(store: Store) u64 {
    var hasher = Hasher.init();
    hasher.update("ledger/1");
    for (store.shared) |item| putOptId(&hasher, item);
    putU8(&hasher, store.warehouse_count);
    for (store.warehouse[0..store.warehouse_count]) |entry| {
        putId(&hasher, entry.item);
        putU16(&hasher, entry.quantity);
    }
    return hasher.final();
}

pub fn storyDigest(store: Store) u64 {
    var hasher = Hasher.init();
    hasher.update("story/1");
    putBool(&hasher, store.story_bound);
    hasher.update(&store.story);
    return hasher.final();
}

/// Digest of the optional-game projection.  It covers exactly the facts an
/// optional-game result may publish, so a stale net/status/record/retained or a
/// different draw cursor is a typed refusal instead of a silent overwrite.
pub fn modeDigest(store: Store) u64 {
    var hasher = Hasher.init();
    hasher.update("mode/1");
    putI32(&hasher, store.net);
    hasher.update(&store.status);
    putU32(&hasher, store.retained);
    for (store.best) |record| putU32(&hasher, record);
    putU64(&hasher, store.draws_cursor);
    putOptU32(&hasher, store.draws_bios);
    putU64(&hasher, store.receipts[base_owner_count]);
    return hasher.final();
}

pub fn storeDigest(store: Store) u64 {
    var hasher = Hasher.init();
    hasher.update("store/1");
    putU64(&hasher, store.revision);
    putU32(&hasher, store.money);
    putOptU32(&hasher, store.price_quote);
    putU64(&hasher, rosterDigest(store));
    putU64(&hasher, ledgerDigest(store));
    putU64(&hasher, storyDigest(store));
    putCamera(&hasher, store.camera);
    // Only the three original owner receipts are part of the store identity;
    // the arcade receipt is pinned by `modeDigest` so the mode-result conformance
    // digests survive the additive slot.
    for (store.receipts[0..base_owner_count]) |receipt| putU64(&hasher, receipt);
    return hasher.final();
}

pub fn resultDigest(result: Result) u64 {
    var hasher = Hasher.init();
    hasher.update("result/1");
    putU8(&hasher, @backingInt(result.owner));
    putU8(&hasher, @backingInt(result.kind));
    putId(&hasher, result.entry_id);
    putU64(&hasher, result.receipt);
    hasher.update(&result.expected.content_sha256.bytes);
    putU64(&hasher, result.expected.revision);
    putU32(&hasher, result.expected.money);
    putOptU32(&hasher, result.expected.price);
    putU64(&hasher, result.expected.roster);
    putU64(&hasher, result.expected.ledger);
    putU64(&hasher, result.expected.story);
    putCamera(&hasher, result.expected.camera);
    if (result.expected.pending_owner) |owner| {
        putU8(&hasher, 1);
        putU8(&hasher, @backingInt(owner));
    } else putU8(&hasher, 0);
    putU64(&hasher, result.expected.receipt);
    putU8(&hasher, result.effect_count);
    for (result.effects[0..result.effect_count]) |effect| putEffect(&hasher, effect);
    return hasher.final();
}
