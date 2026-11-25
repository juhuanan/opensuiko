const std = @import("std");
const field = @import("field");
const events = @import("field_events.zig");
const runtime = @import("event_runtime");
const handoffs = @import("field_events_playback/handoffs.zig");
const world_commands = @import("field_events_playback/world_commands.zig");

const Session = events.Session;
const Binding = events.Binding;

pub const queuedBattle = handoffs.queuedBattle;
pub const takeBattle = handoffs.takeBattle;
pub const queuedFixedDice = handoffs.queuedFixedDice;
pub const queuedItemOverload = handoffs.queuedItemOverload;
pub const resumeItemOverload = handoffs.resumeItemOverload;
pub const queuedPartySelect = handoffs.queuedPartySelect;
pub const partySelectReservesSlot = handoffs.partySelectReservesSlot;
pub const resumePartySelect = handoffs.resumePartySelect;
pub const updateSelectorParty = handoffs.updateSelectorParty;
pub const pendingFieldMusic = handoffs.pendingFieldMusic;
pub const resumeFieldMusic = handoffs.resumeFieldMusic;
pub const resumeFixedDice = handoffs.resumeFixedDice;
pub const resumeBattleStory = handoffs.resumeBattleStory;
pub const acknowledgeAudio = handoffs.acknowledgeAudio;
pub const apply = world_commands.apply;

const ItemGrant = struct { member: usize, inventory: field.items.Inventory };

fn prepareChestItem(state: field.State, command: runtime.Command) !?ItemGrant {
    const name = command.item_name orelse return error.UnknownFieldEventItem;
    const item_id = std.meta.stringToEnum(field.items.Id, name) orelse return error.UnknownFieldEventItem;
    for (state.progress.party, 0..) |member, index| {
        var inventory = member.inventory;
        if (try inventory.receive(item_id)) return .{ .member = index, .inventory = inventory };
    }
    return null;
}

fn applyStoryEffect(
    effect: runtime.Command,
    staged_state: *field.State,
    staged_story: *runtime.StoryState,
    chest_failed_target: *?u16,
    item_grant: *?ItemGrant,
) !void {
    switch (effect.kind) {
        .soul_eater_advance => {
            if (staged_story.soul_eater_spell_slots < 1 or staged_story.soul_eater_spell_slots >= 4) return error.InvalidSoulEaterProgress;
            staged_story.soul_eater_spell_slots += 1;
        },
        .world_mode => {
            const code = effect.code.?;
            if (code == 2) {
                if (staged_story.castle_tier >= 4) return error.InvalidRecruitmentTier;
                staged_story.castle_tier += 1;
                staged_state.progress.story.recruitment_tier = staged_story.castle_tier;
            } else if (code >= 0x0B and code <= 0x0D) {
                staged_story.world_mode = code - 0x0B;
            } else if (code == 0x14) {
                staged_story.scenario[38] |= 8;
            } else if (code == 0x19) {
                staged_story.scenario[43] ^= 0x40;
            } else if (code == 0x1B) {
                staged_story.scenario[44] ^= 0x04;
            }
        },
        .recruit_toggle => {
            staged_story.toggleRecruit(effect.index.?, (effect.mask orelse 0) != 0);
            if (effect.mask == 2) staged_story.recruit_flags[effect.index.?] |= 2;
        },
        .recruit_mark_loaded => staged_story.markCharacterLoaded(effect.index.?),
        .sequence_input => try staged_story.advanceSequence(effect.flag.?, effect.parameter.?, effect.value.?),
        .chest_grant => {
            item_grant.* = try prepareChestItem(staged_state.*, effect);
            if (item_grant.* == null) {
                chest_failed_target.* = effect.failure_target;
            } else if (effect.flag) |f| {
                try staged_story.apply(f);
            }
        },
        else => {},
    }
}

pub noinline fn pump(self: *Session, binding: Binding, state: *field.State, story: *runtime.StoryState, input: runtime.Input) !bool {
    const before_pc = self.instance.?.execution.pc;
    var event_input = input;
    event_input.active_party = self.source_party[0..self.active_party_count];
    const stepped = try runtime.step(binding.content, &self.instance.?, story, event_input);
    var staged = self.*;
    const after_pc = if (self.instance.?.pending) |pending| pending.next.pc else self.instance.?.execution.pc;
    const program = binding.content.program(self.instance.?.program_id).?;
    if (after_pc >= before_pc) for (program.commands[before_pc..after_pc]) |command| {
        if (command.kind == .wait_text_queue_drain_and_release) {
            if (self.party_queue != null and self.party_queue.?.active() != 0) return error.FieldPartyQueueBusy;
            staged.party_queue = null;
        }
    };
    if (stepped.batch) |batch| {
        if (staged.instance.?.pendingBattle()) |id| {
            staged.pending_battle = id;
            self.* = staged;
            return true;
        }
        if (staged.instance.?.pendingFixedDice() or staged.instance.?.pendingPartySelect() or staged.instance.?.pendingItemOverload() or (pendingFieldMusic(&staged) != null and program.entry != .initialization)) {
            self.* = staged;
            return true;
        }
        var staged_state_progress: field.game_state.Progress = undefined;
        var staged_state = state.stageProgress(&staged_state_progress);
        var staged_story = story.*;
        var chest_failed_target: ?u16 = null;
        var item_grant: ?ItemGrant = null;
        for (batch.slice()) |effect| {
            if (!try apply(&staged, binding, effect, &staged_state)) {
                self.blocker = .{ .entity = binding.content.program(self.instance.?.program_id).?.entity, .command = effect.origin };
                return false;
            }
            try applyStoryEffect(effect, &staged_state, &staged_story, &chest_failed_target, &item_grant);
        }
        staged.receipt = .{ .content_sha256 = binding.content.content_sha256, .program = staged.instance.?.program_id, .instance = staged.serial, .batch = batch.id };
        try runtime.acknowledge(binding.content, &staged.instance.?, &staged_story, batch.id);
        if (staged_story.castle_tier != story.castle_tier)
            staged_state.progress.story.recruitment_tier = staged_story.castle_tier;
        if (batch.slice()[0].kind == .party_restore) try staged_state.progress.restoreParty(batch.slice()[0].hp_only);
        if (batch.slice()[0].kind == .inn_stay) {
            // The isolated batch is acknowledged before changing the shared party backing.
            staged.inn_payment_refused = false;
            staged_state.progress.stay(@intCast(batch.slice()[0].amount.?)) catch |err| switch (err) {
                error.InsufficientFunds => staged.inn_payment_refused = true,
                else => return err,
            };
            if (!staged.inn_payment_refused) staged_state.rest_ticks = 60;
        }
        if (chest_failed_target) |target| try staged.instance.?.redirect(binding.content, batch.slice()[0].origin, target);
        if (item_grant) |grant| staged_state.progress.party[grant.member].inventory = grant.inventory;
        self.* = staged;
        state.commitProgress(staged_state);
        story.* = staged_story;
    } else self.* = staged;
    return true;
}
