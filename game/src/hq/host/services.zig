const hq_host = @import("../host.zig");
const services_mod = @import("../services/root.zig");
const tablet_mod = @import("../tablet/root.zig");

const Host = hq_host.Host;

pub fn openService(self: *Host, interaction: hq_host.Interaction) !void {
    const caller = self.services.value.findCaller(interaction.id) orelse return error.UnknownServiceCaller;
    // The three runtime facts are supplied by the interaction owner.  The
    // per-caller story gate is not decoded in the packet, so the host
    // records that as a blocker instead of pretending it was checked.
    const supplied = self.service_access orelse return error.MissingServiceAccess;
    const access: services_mod.Access = .{
        .area = self.area,
        .npc_present = supplied.npc_present,
        .service_available = supplied.service_available,
        .story_gate = if (caller.access.requires_story_gate) supplied.story_gate else null,
        .rune_permitted = supplied.rune_permitted,
    };
    switch (services_mod.open(&self.services.value, caller.id, access, self.revision)) {
        .blocked => |blocked| {
            self.blocker = .{ .code = @tagName(blocked.reason), .detail = blocked.requirement orelse "", .interaction = caller.id };
            return error.ServiceBlocked;
        },
        .opened => |service| {
            self.service = service;
            self.service_op_count = 0;
            for (caller.services) |id| {
                if (self.service_op_count == hq_host.max_service_ops) break;
                self.service_ops[self.service_op_count] = id;
                self.service_op_count += 1;
            }
            self.service_cursor = 0;
            self.screen = .service;
            self.message = caller.id;
        },
    }
}

pub fn stepService(self: *Host, intent: hq_host.Intent) !void {
    switch (intent) {
        .up => if (self.service_cursor > 0) {
            self.service_cursor -= 1;
        },
        .down => if (self.service_cursor + 1 < self.service_op_count) {
            self.service_cursor += 1;
        },
        .cancel => {
            if (self.service) |*service| _ = service.cancel();
            self.service = null;
            self.screen = .field;
            self.message = "service_cancelled";
            try self.rebuild();
        },
        .confirm => try executeService(self),
        .left, .right => {},
    }
}

fn executeService(self: *Host) !void {
    if (self.service == null) return error.NoService;
    const service = &self.service.?;
    const id = self.service_ops[self.service_cursor];
    const engine = self.service_adapter.engine();
    const outcome = switch (id) {
        .shop_buy => blk: {
            const caller = service.caller orelse return error.UnknownServiceCaller;
            if (caller.stock.len == 0) break :blk services_mod.Outcome{ .failed = .{ .reason = .not_in_stock, .caller = caller.id } };
            break :blk service.buy(&engine, 0, caller.stock[0].native_id);
        },
        .shop_sell => service.sell(&engine, 0, 0),
        .warehouse_deposit => blk: {
            // The interactive AZUKARI caller is unresolved: the overlay entry
            // stays locked in production.
            break :blk services_mod.Outcome{ .failed = .{ .reason = .non_canonical_overlay, .caller = "azukari_entry" } };
        },
        .warehouse_withdraw => services_mod.Outcome{ .failed = .{ .reason = .non_canonical_overlay, .caller = "azukari_entry" } },
        .appraisal_appraise => service.appraise(&engine, 0, 0),
        .blacksmith_sharpen => blk: {
            const caller = service.caller orelse return error.UnknownServiceCaller;
            const limit = caller.level_limit orelse
                break :blk services_mod.Outcome{ .failed = .{ .reason = .level_limit_invalid, .requirement = "blacksmith_level_limit_unresolved", .caller = caller.id } };
            break :blk service.sharpen(&engine, 0, limit);
        },
        .rune_attach => service.attach(&engine, 0, 0, 0),
        .rune_detach => service.detach(&engine, 0),
    };
    switch (outcome) {
        .ok => |receipt| {
            self.revision += 1;
            self.message = "service_ok";
            _ = receipt;
        },
        .failed => |blocked| {
            self.blocker = .{ .code = @tagName(blocked.reason), .detail = blocked.requirement orelse "", .interaction = blocked.caller };
            return error.ServiceRefused;
        },
    }
}

/// Journey owns the field callers. The standalone host opens declared entries.
pub fn openTablet(self: *Host, entry: hq_host.Entry) !void {
    if (self.screen != .field) return error.WrongScreen;
    if (entry == .canonical) return error.TabletEntryUnbound;
    self.tablet = tablet_mod.View.init(self.recruit);
    self.screen = .tablet;
    self.message = "tablet_declared_entry";
}

pub fn stepTablet(self: *Host, intent: hq_host.Intent) !void {
    var view = &(self.tablet orelse return error.NoTablet);
    const result = view.apply(switch (intent) {
        .up => .up,
        .down => .down,
        .left => .left,
        .right => .right,
        .confirm => .confirm,
        .cancel => .cancel,
    });
    switch (result) {
        .closed => {
            self.tablet = null;
            self.screen = .field;
            self.message = "tablet_closed";
            try self.rebuild();
        },
        .revealed => |reveal| self.message = reveal.name,
        .blocked => |reason| {
            self.blocker = .{ .code = @tagName(reason), .detail = "tablet entry is not listed/active", .interaction = "stars_of_destiny_tablet" };
            return error.TabletEntryBlocked;
        },
        .moved => {},
    }
}
