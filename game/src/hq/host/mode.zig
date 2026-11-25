const hq_host = @import("../host.zig");
const results = @import("campaign_policies").mode_result;

const Host = hq_host.Host;
const arcade_status_story_index: usize = 160;

pub fn admitMode(self: *Host, caller_site: u32) !void {
    const driver = self.mode_driver orelse {
        self.blocker = .{ .code = "optional_game_seam_unbound", .detail = "the optional-game driver needs the accepted contracts" };
        return error.OptionalGameSeamUnbound;
    };
    if (self.screen != .field) return error.WrongScreen;
    try driver.admit(driver.ctx, caller_site);
    self.screen = .mode;
    self.message = "optional_game_admitted";
}

pub fn stepMode(self: *Host, intent: hq_host.Intent) !void {
    const driver = self.mode_driver orelse return error.OptionalGameSeamUnbound;
    switch (intent) {
        .confirm => try driver.play(driver.ctx, .confirm),
        .cancel => {
            driver.finish(driver.ctx) catch |err| {
                self.blocker = .{ .code = @errorName(err), .detail = "a pending settlement must be committed before the field resumes" };
                return err;
            };
            self.screen = .field;
            self.message = "optional_game_closed";
            try self.rebuild();
        },
        .up, .down, .left, .right => try driver.play(driver.ctx, switch (intent) {
            .up => .up,
            .down => .down,
            .left => .left,
            .right => .right,
            else => unreachable,
        }),
    }
}

/// Build the shared mode-result store for one optional-game transaction from the
/// canonical owners.  This is a projection, never a second stored host.
pub fn modeProjection(self: *Host) results.Store {
    var store: results.Store = .{};
    store.revision = self.mode_facts.revision;
    store.money = self.field_state.progress.money;
    store.net = self.mode_facts.net;
    store.status = self.mode_facts.status;
    if (self.field_state.progress.story.scenario) |story| {
        store.story = story.scenario;
        store.story_bound = true;
        @memcpy(&store.status, story.scenario[arcade_status_story_index..][0..store.status.len]);
    }
    store.retained = self.mode_facts.retained;
    store.best = self.mode_facts.best;
    store.draws_cursor = self.mode_facts.draws_cursor;
    store.draws_bios = self.mode_facts.draws_bios;
    store.receipts = self.mode_facts.receipts;
    store.camera = .{
        .x = self.field_state.x,
        .y = self.field_state.y,
        .facing = switch (self.field_state.facing) {
            .up => .north,
            .right => .east,
            .down => .south,
            .left => .west,
        },
        .place = .field,
    };
    // Party identity/HP/level facts only: an optional-game result cannot
    // publish an item, and the bags stay with the field owner.
    store.party.count = 0;
    for (self.roster.snapshot.members) |maybe| if (maybe) |member| {
        if (store.party.count == results.max_members) break;
        const member_state = self.roster.stateOf(member.member.id) orelse continue;
        if (member_state.presence != .active) continue;
        var slot = results.Member{};
        slot.id = results.Id.init(member.member.id) catch continue;
        slot.hp = member.member.hp;
        slot.max_hp = member.member.max_hp;
        slot.status = switch (member.member.status) {
            .healthy => .healthy,
            .poisoned => .poisoned,
            .unconscious => .unconscious,
        };
        slot.level = member.level;
        slot.experience = member.experience;
        slot.weapon_level = member.weapon_level;
        store.party.members[store.party.count] = slot;
        store.party.count += 1;
    };
    return store;
}

/// Publish one optional-game result through the shared transaction.  The
/// mode facts are written back only after the store is committed.
pub fn publishMode(self: *Host, result: results.Result) !results.Outcome {
    try self.result_host.begin(result);
    const outcome = try self.result_host.commit();
    const committed = self.result_host.store;
    self.field_state.progress.money = committed.money;
    if (committed.story_bound) {
        if (self.field_state.progress.story.scenario) |*story| {
            story.scenario = committed.story;
            @memcpy(story.scenario[arcade_status_story_index..][0..committed.status.len], &committed.status);
        }
    }
    self.mode_facts = .{
        .net = committed.net,
        .status = committed.status,
        .retained = committed.retained,
        .best = committed.best,
        .draws_cursor = committed.draws_cursor,
        .draws_bios = committed.draws_bios,
        .receipts = committed.receipts,
        .revision = committed.revision,
    };
    self.revision += 1;
    return outcome;
}
