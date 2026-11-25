//! Journey room and battle share the caller-owned progress backing.
const battle = @import("battle");
const field = @import("field");
const roster = @import("journey_roster");
const journey = @import("../journey.zig");

pub fn current(state: *const journey.State) *const field.game_state.Progress {
    return &state.combat.progress;
}

pub fn stageField(state: *const journey.State, scratch: *field.game_state.Progress, members: *[6]battle.Member) field.State {
    const staged = state.field_state.stageProgress(scratch);
    const party = members[0..scratch.party.len];
    @memcpy(party, scratch.party);
    scratch.party = party;
    return staged;
}

pub fn commitFieldTransaction(state: *journey.State, next_field: field.State) void {
    const party = state.combat.progress.party;
    // Field transactions edit members in place. Roster changes own their backing.
    @memcpy(party, next_field.progress.party);
    next_field.progress.party = party;
    state.field_state.commitProgress(next_field);
}

pub fn setScenarioStory(state: *journey.State, story: field.game_state.event_runtime.StoryState) void {
    state.combat.progress.story.scenario = story;
}

pub fn completeStoryFlag(state: *journey.State, flag: field.game_state.StoryFlag) void {
    state.combat.progress.story.complete(flag);
}

pub fn recordPahnDuel(state: *journey.State, outcome: u8) void {
    if (state.combat.progress.story.scenario) |*story| roster.recordPahnDuel(story, outcome);
}

pub fn replacePartySlice(state: *journey.State, members: []battle.Member) void {
    state.combat.progress.party = members;
}
