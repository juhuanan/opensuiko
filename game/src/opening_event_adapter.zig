const std = @import("std");
const runtime = @import("event_runtime");
const audience = @import("opening_audience");

pub const Update = struct {
    status: runtime.Status,
    batch_id: ?u64 = null,
    cue: ?u16 = null,
    completed: bool = false,
};

fn runSource(stage: *audience.State, script: audience.Content, index: usize, input: audience.Input) !audience.Emission {
    var view = script;
    view.commands = script.commands[index .. index + 1];
    stage.active = true;
    stage.cursor = 0;
    return stage.tick(view, input);
}

fn labelIndex(script: audience.Content) !usize {
    for (script.commands, 0..) |command, index| if (command.kind == .label) return index;
    return error.MissingOpeningIdleCommand;
}

fn inputFor(content: runtime.Content, instance: runtime.Instance, stage: *audience.State, choice_confirmed: bool, ids: *[16][]const u8) !runtime.Input {
    var count: usize = 0;
    if (stage.alignment == null) {
        ids[count] = "alignment";
        count += 1;
    }
    if (stage.delay == 0) {
        ids[count] = "delay";
        count += 1;
    }
    if (stage.pan == null) {
        ids[count] = "pan";
        count += 1;
    }
    if (!stage.tracksBusy()) {
        ids[count] = "tracks";
        count += 1;
    }
    var boxes_clear = true;
    for (stage.boxes, 0..) |box, index| {
        if (box.phase == .closed) {
            ids[count] = if (index == 0) "box_0" else "box_1";
            count += 1;
        }
        if (box.phase == .opening or box.phase == .closing) boxes_clear = false;
        if (box.prefix_done) {
            ids[count] = if (index == 0) "box_0" else "box_1";
            count += 1;
        }
    }
    if (boxes_clear) {
        ids[count] = "dialogue_flags";
        count += 1;
    }
    if (instance.execution.wait) |pending| {
        if (pending.kind == .text and !stage.textBusy()) {
            ids[count] = pending.id;
            count += 1;
        }
    }
    if (instance.pending == null and instance.execution.active) {
        const program = content.program(instance.program_id).?;
        const command = program.commands[instance.execution.pc];
        if (command.requires) |required| if (required.kind == .variant) {
            const actor = try stage.avatar(required.id);
            if (!actor.sprite.active) {
                ids[count] = required.id;
                count += 1;
            }
        };
    }
    return .{ .completions = ids[0..count], .choice = stage.choice, .choice_confirmed = choice_confirmed };
}

pub const Adapter = struct {
    instance: runtime.Instance,
    stage: audience.State,
    last_applied_batch: ?u64 = null,
    idle_command: usize,

    pub fn start(content: runtime.Content, script: audience.Content, stage: audience.State, story: *const runtime.StoryState) !Adapter {
        if (!std.mem.eql(u8, content.id, "vaa_audience_choice")) return error.UnsupportedOpeningEventContent;
        return .{
            .instance = try runtime.start(content, story, "vaa_room2_audience"),
            .stage = stage,
            .idle_command = try labelIndex(script),
        };
    }

    pub fn tick(self: *Adapter, content: runtime.Content, script: audience.Content, story: *runtime.StoryState, input: audience.Input) !Update {
        if (!self.instance.execution.active and self.instance.pending == null) return .{ .status = .completed };
        var host_ticked = false;
        var output: Update = .{ .status = .running };
        if (self.instance.execution.wait) |pending| {
            if (pending.kind == .choice) {
                const emission = try runSource(&self.stage, script, pending.command_index, input);
                self.stage.cursor = pending.command_index + self.stage.cursor;
                output.cue = emission.cue;
                output.completed = emission.completed;
                host_ticked = true;
            }
        }
        const choice_confirmed = host_ticked and input.confirm and !input.up and !input.down;
        var completion_ids: [16][]const u8 = undefined;
        var core_input = try inputFor(content, self.instance, &self.stage, choice_confirmed, &completion_ids);
        core_input.confirm = input.confirm;
        const result = try runtime.step(content, &self.instance, story, core_input);
        output.status = result.status;
        if (result.batch) |batch| {
            output.batch_id = batch.id;
            for (batch.slice()) |effect| {
                const emission = try runSource(&self.stage, script, effect.origin, input);
                self.stage.cursor = effect.origin + self.stage.cursor;
                if (emission.cue != null) output.cue = emission.cue;
                output.completed = output.completed or emission.completed;
                host_ticked = true;
            }
            self.last_applied_batch = batch.id;
            try runtime.acknowledge(content, &self.instance, story, batch.id);
            output.status = if (self.instance.execution.active) .running else .completed;
        }
        if (!host_ticked and self.stage.active) {
            const emission = try runSource(&self.stage, script, self.idle_command, input);
            self.stage.cursor = if (self.instance.execution.wait != null and self.instance.execution.wait.?.kind == .speaker_prefix)
                self.instance.execution.pc - 1
            else
                self.instance.execution.pc;
            output.cue = emission.cue;
            output.completed = emission.completed;
        }
        return output;
    }
};

pub const Initialization = struct {
    cues: [2]?u16 = @splat(null),
    count: u8 = 0,
};

pub fn initializeRoom(content: runtime.Content, stage: *audience.State, story: *runtime.StoryState) !Initialization {
    if (!std.mem.eql(u8, content.id, "vaa_audience_choice")) return error.UnsupportedOpeningEventContent;
    var result: Initialization = .{};
    for (content.programs) |program| {
        if (program.entry != .initialization or !story.matches(program.conditions)) continue;
        var instance = try runtime.start(content, story, program.id);
        const stepped = try runtime.step(content, &instance, story, .{});
        if (stepped.batch) |batch| {
            for (batch.slice()) |effect| switch (effect.kind) {
                .cue => {
                    if (stage.cached_cue != effect.cue) result.cues[result.count] = effect.cue;
                    stage.cue = effect.cue.?;
                    if (effect.cue.? >= 0x201 and effect.cue.? <= 0x445) stage.cached_cue = effect.cue;
                },
                .release_actor => {
                    const actor = try stage.avatar(effect.actor.?);
                    if (actor.attached and !actor.released) {
                        actor.motion.speed = 0;
                        actor.released = true;
                        actor.variant = 254;
                        actor.sprite.active = false;
                    }
                },
                else => return error.UnsupportedOpeningInitializationEffect,
            };
            try runtime.acknowledge(content, &instance, story, batch.id);
        }
        result.count += 1;
    }
    return result;
}
