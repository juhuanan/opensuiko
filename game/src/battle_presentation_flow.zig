//! Battle presentation composition: cast/attack begin, boundary advance, frame.
const combat_effects = @import("combat_systems").effects;
const State = @import("battle.zig").State;

pub fn attachEffects(state: *State, packet: *const combat_effects.Packet) void {
    state.effects = .{ .packet = packet };
}

pub fn beginCastPresentation(state: *State, spell_id: []const u8) void {
    state.presentation = null;
    state.presentation_refusal = "";
    const effects = state.effects orelse return;
    state.presentation = combat_effects.beginCast(effects.packet, spell_id, state.impactTick(), state.actionDuration()) catch |err| {
        state.presentation_refusal = @errorName(err);
        return;
    };
}

pub fn beginAttackPresentation(state: *State, actor: usize) void {
    state.presentation = null;
    state.presentation_refusal = "";
    const effects = state.effects orelse return;
    const ready = state.actionMotion(actor) != null;
    state.presentation = combat_effects.beginAttack(effects.packet, "physical_attack", state.memberImpact(actor), state.memberDuration(actor), ready) catch |err| {
        state.presentation_refusal = @errorName(err);
        return;
    };
}

pub fn advancePresentation(state: *State, boundary: u16) void {
    const composer = if (state.presentation) |*value| value else return;
    _ = composer.advanceTo(boundary) catch |err| {
        state.presentation_refusal = @errorName(err);
        state.presentation = null;
    };
}

pub fn effectFrame(state: *const State, boundary: u16) ?combat_effects.Frame {
    const composer = if (state.presentation) |*value| value else return null;
    return composer.frameAt(boundary);
}
