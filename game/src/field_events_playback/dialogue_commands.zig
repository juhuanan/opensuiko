const std = @import("std");
const events = @import("../field_events.zig");
const runtime = @import("event_runtime");
const motion = @import("opening_audience");
const audio_route = @import("audio_route");

const Session = events.Session;
const Binding = events.Binding;

pub fn applyOpenFixedBox(self: *Session, binding: Binding, command: runtime.Command) !bool {
    if (!binding.content.hasFixedBoxes()) return false;
    const box = &self.boxes[command.box.?];
    if (box.phase != .closed) return error.FieldDialogueBusy;
    box.* = .{ .phase = .opening, .transition = 20, .fixed = .{ .x = command.x.?, .y = command.y.?, .w = command.width.?, .h = command.height.? } };
    self.sound_effect = audio_route.SoundContent.window_open;
    return true;
}

pub fn applyOpenBox(self: *Session, binding: Binding, command: runtime.Command) !bool {
    const definition = for (binding.dialogue.anchors) |anchor| {
        if (anchor.command == command.origin and std.mem.eql(u8, anchor.program, self.instance.?.program_id)) break anchor;
    } else return false;
    if (self.boxes[definition.box].phase != .closed) return error.FieldDialogueBusy;
    if (definition.interaction_actor != null) {
        const program = binding.content.program(self.instance.?.program_id) orelse return false;
        const actors = if (self.ordinary_actors) |*value| value else return false;
        const point = binding.interactionPosition(program.entity, actors) orelse return error.IneligibleFieldInteraction;
        self.boxes[definition.box] = .{ .phase = .opening, .transition = 20, .anchor = .{ .x = point.x + 8, .y = point.y - 24 } };
        if (binding.content.hasFixedBoxes()) self.sound_effect = audio_route.SoundContent.window_open;
        return true;
    }
    if (definition.point) |point| {
        self.boxes[definition.box] = .{ .phase = .opening, .transition = 20, .anchor = .{ .x = point.x + 8, .y = point.y - 24 } };
        if (binding.content.hasFixedBoxes()) self.sound_effect = audio_route.SoundContent.window_open;
        return true;
    }
    const actor = if (definition.actor) |id| blk: {
        if (std.mem.eql(u8, id, "hero") and command.actor != null) break :blk self.hero;
        const packet = binding.ordinary orelse return false;
        const actors = if (self.ordinary_actors) |*value| value else return false;
        if (command.actor == null) {
            const layout = command.layout orelse return false;
            const avatar = actors.actorAtLayout(packet, layout, id) catch return false;
            break :blk avatar.motion;
        }
        const avatar = actors.actor(packet, id) catch return false;
        break :blk avatar.motion;
    } else blk: {
        const queue = self.party_queue orelse return error.MissingFieldPartyQueue;
        if (definition.follower.? >= queue.count or queue.active() != 0) return error.InvalidFieldDialogue;
        break :blk queue.followers[definition.follower.?].?.position;
    };
    self.boxes[definition.box] = .{ .phase = .opening, .transition = 20, .anchor = .{ .x = actor.x + 8, .y = actor.y - 24 } };
    if (binding.content.hasFixedBoxes()) self.sound_effect = audio_route.SoundContent.window_open;
    return true;
}

pub fn applyCloseBox(self: *Session, command: runtime.Command) !bool {
    const box = &self.boxes[command.box.?];
    if (box.phase != .open) return error.FieldDialogueBusy;
    box.phase = .closing;
    box.transition = 20;
    box.image = null;
    if (self.text_job != null and self.text_job.?.box == command.box.?) self.text_job = null;
    return true;
}

pub fn applyDialoguePrefix(self: *Session, binding: Binding, command: runtime.Command) !bool {
    const prefix = binding.dialogue.prefixFor(self.instance.?.program_id, command.origin) orelse return false;
    const box = &self.boxes[prefix.box];
    if (box.phase == .closed or box.phase == .closing) return error.FieldDialogueBusy;
    if (prefix.text != null and self.text_job != null and !self.text_job.?.state.done) return error.FieldDialogueBusy;
    // The original image lookup leaves its descriptor unchanged when no custom/loaded character matches.
    if (prefix.absent_character) |character| if (std.mem.indexOfScalar(u8, self.source_party[0..self.active_party_count], character) != null) return false;
    if (prefix.image) |image| {
        const resource = binding.dialogue.images[image];
        const loaded = resource.domain != .active_party or std.mem.indexOfScalar(u8, self.source_party[0..self.active_party_count], resource.character) != null;
        if (!loaded and resource.atlas_rect == null) return false;
        if (resource.domain == .area_custom and resource.resource == null) return false;
        if (loaded) box.image = image;
    }
    if (prefix.text) |text| {
        box.speaker = text;
        self.text_job = .{ .box = prefix.box, .text = text, .state = motion.TextState.start(binding.dialogue.texts[text], 0) };
    }
    return true;
}

pub fn applyText(self: *Session, binding: Binding, command: runtime.Command) !bool {
    const index = for (binding.dialogue.texts, 0..) |text, i| {
        if (std.mem.eql(u8, text.id, command.text.?)) break i;
    } else return false;
    for (binding.dialogue.texts[index].tokens) |token| switch (token.kind) {
        .glyph, .newline, .countdown, .pace => {},
        .page => if (!binding.dialogue.allow_pages) return false,
        .player_name => if (!binding.dialogue.allow_substitution) return false,
    };
    if (self.text_job != null and !self.text_job.?.state.done) return error.FieldDialogueBusy;
    const pace = binding.dialogue.configuration[@backingInt(self.text_speed)].normal_pace;
    self.text_job = .{ .box = command.box.?, .text = @intCast(index), .state = motion.TextState.start(binding.dialogue.texts[index], pace), .kind = .body_staged, .current_pace = pace };
    return true;
}

pub fn applyChoice(self: *Session, command: runtime.Command) !bool {
    const slot = command.box.?;
    const job = if (self.text_job) |*job| job else return error.FieldDialogueBusy;
    if (self.boxes[slot].phase != .open) return error.FieldDialogueBusy;
    if (!job.hasChoiceRows(slot)) return error.InvalidFieldChoices;
    return true;
}
