const std = @import("std");
const hq_host = @import("../host.zig");
const stage_mod = @import("../stage.zig");
const windows_mod = @import("../windows.zig");

const Host = hq_host.Host;

/// The HQ recruitment window facts for the current canonical state.  Every fact comes
/// from a real owner; a fact the port cannot express (item identity) is
/// left empty so a window that needs it blocks instead of defaulting true.
pub fn recruitFacts(self: *Host, interaction: bool) windows_mod.Facts {
    @memset(&self.party_bitmap, 0);
    const identities = self.partyIdentities();
    var party_count: u8 = 0;
    for (identities) |id| if (id != 0) {
        self.party_bitmap[id] = 1;
        party_count += 1;
    };
    const by_identity = self.levels();
    @memcpy(&self.level_buffer, by_identity[0..hq_host.identity_slots]);
    return .{
        .entity_available = true,
        .interaction = interaction,
        .scenario = if (self.field_state.progress.story.scenario) |*scenario| &scenario.scenario else null,
        .recruit = &self.recruit,
        .party = &self.party_bitmap,
        .money = self.field_state.progress.money,
        .levels = &self.level_buffer,
        .tier = self.stageByte(),
        .eligible = self.counts().present,
        .party_count = party_count,
        .hero_x = @intCast(@divTrunc(self.field_state.x, 8)),
        .hero_y = @intCast(@divTrunc(self.field_state.y, 8)),
        .input_mask = 0x41,
        .mode_word = 0,
        .random = 0,
    };
}

pub fn evaluateWindow(self: *Host, window: *const windows_mod.Window, interaction: bool) windows_mod.Outcome {
    return windows_mod.evaluate(window, recruitFacts(self, interaction));
}

pub fn openRecruit(self: *Host, interaction: hq_host.Interaction) !void {
    const window = windows_mod.windowById(self.windows.asset(), interaction.window orelse return error.UnknownWindow) orelse return error.UnknownWindow;
    const outcome = evaluateWindow(self, window, true);
    switch (outcome.route) {
        .admitted => {
            self.screen = .recruit;
            self.message = window.id;
        },
        else => {
            self.blocker = .{
                .code = @tagName(outcome.blocker.?.code),
                .detail = outcome.blocker.?.detail,
                .interaction = interaction.id,
            };
            return error.RecruitWindowClosed;
        },
    }
}

pub fn stepRecruit(self: *Host, intent: hq_host.Intent) !void {
    switch (intent) {
        .cancel => {
            self.screen = .field;
            self.message = "recruit_declined";
            try self.rebuild();
        },
        .confirm => {
            const interaction = self.currentInteraction() orelse return error.NoInteraction;
            const window = windows_mod.windowById(self.windows.asset(), interaction.window orelse return error.UnknownWindow) orelse return error.UnknownWindow;
            // A window without a source menu grants on its admitted entry
            // conjunction; only a real menu goes through `choose`, which
            // keeps an unproved second arm on the typed second route.
            const outcome = if (window.choice == null)
                windows_mod.evaluate(window, recruitFacts(self, true))
            else
                windows_mod.choose(window, 0, recruitFacts(self, true));
            if (outcome.route != .admitted) {
                self.blocker = .{ .code = @tagName(outcome.blocker.?.code), .detail = outcome.blocker.?.detail, .interaction = interaction.id };
                return error.RecruitRefused;
            }
            const plan = outcome.plan orelse return error.MissingRecruitPlan;
            // Only the reviewed roster recruitment invocation is applied.
            if (!std.mem.eql(u8, plan.op_id, windows_mod.grant_op_id) or plan.op_code != windows_mod.grant_op_code) return error.UnsupportedRecruitPlan;
            try commitRecruit(self, plan.cid, window.id);
        },
        .up, .down, .left, .right => {},
    }
}

/// Apply one admitted source grant: roster mutation, recruit byte, the
/// Recount/promote pair, then a fresh population rebuild.
fn commitRecruit(self: *Host, cid: u8, source_text: []const u8) !void {
    if (cid >= hq_host.flag_slots) return error.InvalidRecruitSlot;
    if (self.recruit[cid] & 1 != 0) return error.AlreadyRecruited;
    const identity = self.identityForRecord(cid) catch |err| {
        self.blocker = .{ .code = @errorName(err), .detail = "no roster identity for this source record id" };
        return err;
    };
    self.roster.setRecruit(self.roster_packet.value, identity, true, source_text) catch |err| {
        // A combatant with no member record cannot be given fabricated
        // stats; the missing character seed is a typed blocker.
        if (err == error.RecordUnavailable) {
            self.blocker = .{ .code = "combat_member_seed_unresolved", .detail = "the roster carries no member record for this combatant" };
        }
        return err;
    };
    self.recruit[cid] |= 1;
    try promoteAfterRecount(self);
    self.screen = .field;
    self.message = "recruited";
    try self.rebuild();
}

/// Re-run the source recount/promotion on the current facts (the
/// save/load and recruit-flag path).  Exactly one step is applied.
pub fn recountStage(self: *Host) !stage_mod.Plan {
    const current = try self.stage();
    const plan = try stage_mod.afterRecount(current, self.counts(), self.storyCastleFlag());
    self.field_state.progress.story.recruitment_tier = plan.stage.byte();
    try self.rebuild();
    return plan;
}

/// The one source promotion step.  The stage byte is the produced value; it is
/// never hand-set.
fn promoteAfterRecount(self: *Host) !void {
    const current = try self.stage();
    const plan = try stage_mod.afterRecount(current, self.counts(), self.storyCastleFlag());
    self.field_state.progress.story.recruitment_tier = plan.stage.byte();
}
