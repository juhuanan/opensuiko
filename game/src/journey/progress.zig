//! Single authoritative owner for persistent `Progress` state inside `journey.State`.
//!
//! `state.combat.progress` holds the canonical persistent `Progress` value (party slice,
//! money, storage, and story state); `state.field_state.progress` is its synchronized
//! field-facing mirror. No subsystem outside this file should assign
//! `field_state.progress = combat.progress` or `combat.progress = field_state.progress`
//! directly—go through these explicit synchronization/transaction helpers instead.
const battle = @import("battle");
const field = @import("field");
const roster = @import("journey_roster");
const journey = @import("../journey.zig");

pub fn current(state: *const journey.State) *const field.game_state.Progress {
    return &state.combat.progress;
}

pub fn inSync(state: *const journey.State) bool {
    return state.combat.progress.equal(state.field_state.progress);
}

pub fn publishToField(state: *journey.State) void {
    state.field_state.progress = state.combat.progress;
}

pub fn commitFromField(state: *journey.State) void {
    state.combat.progress = state.field_state.progress;
}

pub fn commitProgress(state: *journey.State, next: field.game_state.Progress) void {
    state.combat.progress = next;
    state.field_state.progress = next;
}

pub fn stageField(state: *const journey.State) field.State {
    var staged = state.field_state;
    staged.progress = state.combat.progress;
    return staged;
}

pub fn commitFieldTransaction(state: *journey.State, next_field: field.State) void {
    state.field_state = next_field;
    state.combat.progress = next_field.progress;
}

pub fn setScenarioStory(state: *journey.State, story: field.game_state.event_runtime.StoryState) void {
    state.combat.progress.story.scenario = story;
    state.field_state.progress.story.scenario = story;
}

pub fn completeStoryFlag(state: *journey.State, flag: field.game_state.StoryFlag) void {
    state.combat.progress.story.complete(flag);
    publishToField(state);
}

pub fn commitStoryFromField(state: *journey.State) void {
    state.combat.progress.story = state.field_state.progress.story;
    publishToField(state);
}

pub fn recordPahnDuel(state: *journey.State, outcome: u8) void {
    if (state.combat.progress.story.scenario) |*story| {
        roster.recordPahnDuel(story, outcome);
        state.field_state.progress.story.scenario = story.*;
    } else if (state.field_state.progress.story.scenario) |*story| {
        roster.recordPahnDuel(story, outcome);
        state.combat.progress.story.scenario = story.*;
    }
}

pub fn replacePartySlice(state: *journey.State, members: []battle.Member) void {
    state.combat.progress.party = members;
    state.field_state.progress.party = members;
}

pub fn bindInitialParty(combat_progress: *field.game_state.Progress, field_progress: *field.game_state.Progress, members: []battle.Member) void {
    combat_progress.party = members;
    field_progress.* = combat_progress.*;
}
