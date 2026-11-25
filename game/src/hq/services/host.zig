//! Caller host: admission, ownership-preserving transaction routing and
//! return flow for the source service conversations.
//!
//! This is deliberately not a service planner.  The pure service-entry rules and
//! catalogue belong to the service contract; this host supplies the caller half
//! -- whether *this* source NPC/story conversation is open, what stock/limit it
//! carries, and where the screen returns.  Every transaction is delegated to the
//! current engines through `Engine`; a refused or failed transaction leaves the
//! phase at the caller menu and never publishes a receipt.
const std = @import("std");
const contract = @import("contract.zig");

pub const Phase = enum { menu, returned, closed };

pub const Access = struct {
    area: ?[]const u8 = null,
    npc_present: ?bool = null,
    service_available: ?bool = null,
    story_gate: ?bool = null,
    rune_permitted: ?bool = null,
};

pub const BlockReason = enum {
    unknown_caller,
    non_canonical_caller,
    non_canonical_overlay,
    missing_condition,
    service_locked,
    wrong_area,
    invalid_revision,
    stale_receipt,
    wrong_service,
    wrong_phase,
    not_in_stock,
    unsupported_item,
    unsupported_engine,
    insufficient_funds,
    inventory_full,
    warehouse_full,
    not_stored,
    not_appraisable,
    already_identified,
    level_limit_invalid,
    level_limit_reached,
    condition_denied,
    rune_locked,
    engine_error,
};

pub const Blocked = struct {
    reason: BlockReason,
    requirement: ?[]const u8 = null,
    caller: ?[]const u8 = null,
};

pub const Receipt = struct {
    caller_id: []const u8,
    service: contract.ServiceId,
    revision: u64,
    serial: u32,
};

pub const Outcome = union(enum) {
    ok: Receipt,
    failed: Blocked,
};

pub const Engine = struct {
    ctx: *anyopaque,
    buy: ?*const fn (*anyopaque, usize, u16) anyerror!void = null,
    sell: ?*const fn (*anyopaque, usize, usize) anyerror!void = null,
    deposit: ?*const fn (*anyopaque, usize, usize) anyerror!void = null,
    withdraw: ?*const fn (*anyopaque, usize, u16) anyerror!void = null,
    appraise: ?*const fn (*anyopaque, usize, usize) anyerror!void = null,
    sharpen: ?*const fn (*anyopaque, usize, u8) anyerror!void = null,
    attach: ?*const fn (*anyopaque, usize, u8, usize) anyerror!void = null,
    detach: ?*const fn (*anyopaque, usize) anyerror!void = null,
};

pub const Host = struct {
    packet: *const contract.Packet,
    caller: ?*const contract.Caller,
    overlay: ?*const contract.OverlayEntry,
    access: Access,
    revision: u64,
    serial: u32 = 0,
    phase: Phase = .menu,
    receipt: Receipt,
    message: []const u8 = "",

    pub fn open(packet: *const contract.Packet, caller_id: []const u8, access: Access, revision: u64) OpenResult {
        if (revision == 0) return .{ .blocked = .{ .reason = .invalid_revision } };
        const caller = packet.findCaller(caller_id) orelse {
            if (packet.findOverlay(caller_id) != null) return .{ .blocked = .{ .reason = .non_canonical_caller, .caller = caller_id } };
            return .{ .blocked = .{ .reason = .unknown_caller, .caller = caller_id } };
        };
        if (!caller.canonical) return .{ .blocked = .{ .reason = .non_canonical_caller, .caller = caller_id } };
        if (access.service_available == null) return .{ .blocked = .{ .reason = .missing_condition, .requirement = "service_available", .caller = caller_id } };
        if (!access.service_available.?) return .{ .blocked = .{ .reason = .service_locked, .requirement = "service_available", .caller = caller_id } };
        if (access.npc_present == null) return .{ .blocked = .{ .reason = .missing_condition, .requirement = "npc_present", .caller = caller_id } };
        if (!access.npc_present.?) return .{ .blocked = .{ .reason = .service_locked, .requirement = "npc_present", .caller = caller_id } };
        if (access.area == null) return .{ .blocked = .{ .reason = .missing_condition, .requirement = "area", .caller = caller_id } };
        if (!std.mem.eql(u8, access.area.?, caller.area)) return .{ .blocked = .{ .reason = .wrong_area, .requirement = "area", .caller = caller_id } };
        if (caller.access.requires_story_gate) {
            if (access.story_gate == null) return .{ .blocked = .{ .reason = .missing_condition, .requirement = "story_gate", .caller = caller_id } };
            if (!access.story_gate.?) return .{ .blocked = .{ .reason = .service_locked, .requirement = "story_gate", .caller = caller_id } };
        }
        return .{ .opened = .{
            .packet = packet,
            .caller = caller,
            .overlay = null,
            .access = access,
            .revision = revision,
            .receipt = .{ .caller_id = caller.id, .service = caller.services[0], .revision = revision, .serial = 0 },
        } };
    }

    pub fn openOverlay(packet: *const contract.Packet, entry_id: []const u8, access: Access, revision: u64) OpenResult {
        if (revision == 0) return .{ .blocked = .{ .reason = .invalid_revision } };
        const entry = packet.findOverlay(entry_id) orelse return .{ .blocked = .{ .reason = .unknown_caller, .caller = entry_id } };
        if (entry.canonical) return .{ .blocked = .{ .reason = .non_canonical_overlay, .caller = entry_id } };
        if (access.service_available == null) return .{ .blocked = .{ .reason = .missing_condition, .requirement = "service_available", .caller = entry_id } };
        if (!access.service_available.?) return .{ .blocked = .{ .reason = .service_locked, .requirement = "service_available", .caller = entry_id } };
        if (access.npc_present == null) return .{ .blocked = .{ .reason = .missing_condition, .requirement = "npc_present", .caller = entry_id } };
        if (!access.npc_present.?) return .{ .blocked = .{ .reason = .service_locked, .requirement = "npc_present", .caller = entry_id } };
        return .{ .opened = .{
            .packet = packet,
            .caller = null,
            .overlay = entry,
            .access = access,
            .revision = revision,
            .receipt = .{ .caller_id = entry.id, .service = .warehouse_deposit, .revision = revision, .serial = 0 },
        } };
    }

    pub fn replay(packet: *const contract.Packet, caller_id: []const u8, access: Access, revision: u64, receipt: Receipt) OpenResult {
        const result = open(packet, caller_id, access, revision);
        const host = switch (result) {
            .blocked => return result,
            .opened => |host| host,
        };
        if (receipt.revision != revision or !std.mem.eql(u8, receipt.caller_id, caller_id) or !host.serviceAllowed(receipt.service)) {
            return .{ .blocked = .{ .reason = .stale_receipt, .caller = caller_id } };
        }
        var replayed = host;
        replayed.receipt = receipt;
        return .{ .opened = replayed };
    }

    pub fn identity(self: *const Host) []const u8 {
        return if (self.caller) |caller| caller.id else self.overlay.?.id;
    }

    pub fn family(self: *const Host) contract.ServiceFamily {
        return if (self.caller) |caller| caller.service else self.overlay.?.service;
    }

    pub fn returnTarget(self: *const Host) []const u8 {
        return self.identity();
    }

    pub fn cancel(self: *Host) Outcome {
        self.phase = .returned;
        self.message = "service_cancelled";
        return .{ .ok = self.receipt };
    }

    pub fn close(self: *Host) void {
        self.phase = .closed;
    }

    fn serviceAllowed(self: *const Host, id: contract.ServiceId) bool {
        if (self.overlay) |_| return id == .warehouse_deposit or id == .warehouse_withdraw;
        for (self.caller.?.services) |service| if (service == id) return true;
        return false;
    }

    fn stocked(self: *const Host, native_id: u16) bool {
        if (self.overlay) |_| return true;
        const caller = self.caller.?;
        if (std.mem.eql(u8, caller.stock_source, "party_inventory_filtered")) return true;
        if (std.mem.eql(u8, caller.stock_source, "static_entry_list")) {
            for (caller.stock) |item| if (item.native_id == native_id) return true;
            return false;
        }
        return true;
    }

    fn begin(self: *const Host, id: contract.ServiceId) ?Blocked {
        if (self.phase != .menu) return .{ .reason = .wrong_phase, .caller = self.identity() };
        if (!self.serviceAllowed(id)) return .{ .reason = .wrong_service, .caller = self.identity() };
        return null;
    }

    fn fail(self: *Host, blocked: Blocked) Outcome {
        // A refused transaction returns to the caller's menu, never to a
        // different screen and never with a published receipt.
        self.phase = .menu;
        self.message = "service_refused";
        return .{ .failed = blocked };
    }

    fn succeed(self: *Host, id: contract.ServiceId) Outcome {
        self.serial += 1;
        self.receipt = .{ .caller_id = self.identity(), .service = id, .revision = self.revision, .serial = self.serial };
        self.phase = .menu;
        self.message = "service_ok";
        return .{ .ok = self.receipt };
    }

    pub fn buy(self: *Host, engine: *const Engine, member: usize, native_id: u16) Outcome {
        if (self.begin(.shop_buy)) |blocked| return self.fail(blocked);
        if (!self.stocked(native_id)) return self.fail(.{ .reason = .not_in_stock, .caller = self.identity() });
        const call = engine.buy orelse return self.fail(.{ .reason = .unsupported_engine, .caller = self.identity() });
        call(engine.ctx, member, native_id) catch |err| return self.fail(.{ .reason = failureOf(err), .caller = self.identity() });
        return self.succeed(.shop_buy);
    }

    pub fn sell(self: *Host, engine: *const Engine, member: usize, slot: usize) Outcome {
        if (self.begin(.shop_sell)) |blocked| return self.fail(blocked);
        const call = engine.sell orelse return self.fail(.{ .reason = .unsupported_engine, .caller = self.identity() });
        call(engine.ctx, member, slot) catch |err| return self.fail(.{ .reason = failureOf(err), .caller = self.identity() });
        return self.succeed(.shop_sell);
    }

    pub fn deposit(self: *Host, engine: *const Engine, member: usize, slot: usize) Outcome {
        if (self.begin(.warehouse_deposit)) |blocked| return self.fail(blocked);
        const call = engine.deposit orelse return self.fail(.{ .reason = .unsupported_engine, .caller = self.identity() });
        call(engine.ctx, member, slot) catch |err| return self.fail(.{ .reason = failureOf(err), .caller = self.identity() });
        return self.succeed(.warehouse_deposit);
    }

    pub fn withdraw(self: *Host, engine: *const Engine, member: usize, native_id: u16) Outcome {
        if (self.begin(.warehouse_withdraw)) |blocked| return self.fail(blocked);
        const call = engine.withdraw orelse return self.fail(.{ .reason = .unsupported_engine, .caller = self.identity() });
        call(engine.ctx, member, native_id) catch |err| return self.fail(.{ .reason = failureOf(err), .caller = self.identity() });
        return self.succeed(.warehouse_withdraw);
    }

    pub fn appraise(self: *Host, engine: *const Engine, member: usize, slot: usize) Outcome {
        if (self.begin(.appraisal_appraise)) |blocked| return self.fail(blocked);
        const call = engine.appraise orelse return self.fail(.{ .reason = .unsupported_engine, .caller = self.identity() });
        call(engine.ctx, member, slot) catch |err| return self.fail(.{ .reason = failureOf(err), .caller = self.identity() });
        return self.succeed(.appraisal_appraise);
    }

    pub fn sharpen(self: *Host, engine: *const Engine, member: usize, limit: u8) Outcome {
        if (self.begin(.blacksmith_sharpen)) |blocked| return self.fail(blocked);
        if (limit < 1 or limit > self.packet.limits.weapon_level_max) {
            return self.fail(.{ .reason = .level_limit_invalid, .caller = self.identity() });
        }
        const call = engine.sharpen orelse return self.fail(.{ .reason = .unsupported_engine, .caller = self.identity() });
        call(engine.ctx, member, limit) catch |err| return self.fail(.{ .reason = failureOf(err), .caller = self.identity() });
        return self.succeed(.blacksmith_sharpen);
    }

    pub fn attach(self: *Host, engine: *const Engine, target: usize, rune_index: u8, crystal_slot: usize) Outcome {
        if (self.begin(.rune_attach)) |blocked| return self.fail(blocked);
        if (self.access.rune_permitted == null) return self.fail(.{ .reason = .missing_condition, .requirement = "rune_permitted", .caller = self.identity() });
        if (!self.access.rune_permitted.?) return self.fail(.{ .reason = .condition_denied, .requirement = "rune_permitted", .caller = self.identity() });
        const call = engine.attach orelse return self.fail(.{ .reason = .unsupported_engine, .caller = self.identity() });
        call(engine.ctx, target, rune_index, crystal_slot) catch |err| return self.fail(.{ .reason = failureOf(err), .caller = self.identity() });
        return self.succeed(.rune_attach);
    }

    pub fn detach(self: *Host, engine: *const Engine, member: usize) Outcome {
        if (self.begin(.rune_detach)) |blocked| return self.fail(blocked);
        const call = engine.detach orelse return self.fail(.{ .reason = .unsupported_engine, .caller = self.identity() });
        call(engine.ctx, member) catch |err| return self.fail(.{ .reason = failureOf(err), .caller = self.identity() });
        return self.succeed(.rune_detach);
    }
};

pub const OpenResult = union(enum) {
    opened: Host,
    blocked: Blocked,
};

fn failureOf(err: anyerror) BlockReason {
    return switch (err) {
        error.InsufficientFunds => .insufficient_funds,
        error.InventoryFull => .inventory_full,
        error.StorageFull => .warehouse_full,
        error.ItemNotStored => .not_stored,
        error.AlreadyIdentified => .already_identified,
        error.AppraisalUnavailable => .not_appraisable,
        error.InvalidItem => .not_in_stock,
        error.UnsupportedItem => .unsupported_item,
        error.EngineUnavailable => .unsupported_engine,
        error.RuneLocked => .rune_locked,
        error.LevelLimitReached => .level_limit_reached,
        else => .engine_error,
    };
}
