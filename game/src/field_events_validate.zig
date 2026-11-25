const std = @import("std");
const field = @import("field");
const ordinary = @import("field_actors");
const population = @import("scene_population");
const room2_descriptor = @import("descriptor_release");
const events = @import("field_events.zig");
const runtime = @import("event_runtime");
const motion = @import("opening_audience");
const dispatch = @import("scene_dispatch");
const records = @import("opening_records");
const ted_party_add = records.ted_party_add;
const field_records = records.field_records;
const room2_movement = @import("movement_batch");
const room2_text_host = @import("room2_text").host;
const fade = @import("fade");
const CompletedEvent = events.CompletedEvent;
const SourceCueRequest = events.SourceCueRequest;
const RoomTransitionProposal = events.RoomTransitionProposal;
const TransitionCommit = events.TransitionCommit;
const retainedE27Program = events.retainedE27Program;
const semanticEqual = events.semanticEqual;
const Initialization = events.Initialization;
const Result = events.Result;
const graphicVariant = events.graphicVariant;
const validateConstructedGround = events.validateConstructedGround;
const pureInitializationProgram = events.pureInitializationProgram;
const pureInitializationPump = events.pureInitializationPump;
const Session = events.Session;
const Binding = events.Binding;
const Room2Descriptor = events.Room2Descriptor;
const begin_mod = @import("field_events_begin.zig");
const room2DescriptorBinding = begin_mod.room2DescriptorBinding;
const room2ActorPosition = begin_mod.room2ActorPosition;
const checks = @import("field_events_validate_checks.zig");
const initializedPosition = checks.initializedPosition;
const descriptorInitializerPositions = checks.descriptorInitializerPositions;
const openingSchema = checks.openingSchema;
const validateHeaderContext = checks.validateHeaderContext;
const validateHeroSpriteState = checks.validateHeroSpriteState;
const validateInitializations = checks.validateInitializations;
const validateActorsState = checks.validateActorsState;
const validateRuntimeQueuesAndActors = checks.validateRuntimeQueuesAndActors;
const validateInstanceState = checks.validateInstanceState;
const validateAudioState = checks.validateAudioState;
const validateLegacy = checks.validateLegacy;
pub const descriptorInitializerPositions_pub = descriptorInitializerPositions;

pub noinline fn validate(self: *const Session, binding: Binding) !void {
    if (self.camera_push) |push| {
        if (!binding.content.hasCameraPush() or !binding.scripted_motion or !self.selected_program or binding.room_package == null or self.alignment != null or self.activeTracks() != 0)
            return error.InvalidCameraPushState;
        const instance = self.instance orelse return error.InvalidCameraPushState;
        const program = binding.content.program(instance.program_id) orelse return error.InvalidCameraPushState;
        if (program.entry != .ordinary or push.command >= program.commands.len or instance.pending != null or
            instance.execution.pc != @as(usize, push.command) + 1 or instance.execution.wait == null or instance.execution.wait.?.kind != .camera_push)
            return error.InvalidCameraPushState;
        const command = program.commands[push.command];
        if (command.kind != .camera_push or command.push == null or !std.meta.eql(command.push.?, push.model.request)) return error.InvalidCameraPushState;
        try push.model.validate();
        for ([_]i32{ push.start.x, push.start.y }) |coordinate| if (coordinate < 0 or coordinate > 2040 or @mod(coordinate, 8) != 0) return error.InvalidCameraPushState;
        const request = push.model.request;
        const applied: i32 = if (push.model.active()) request.repeats - push.model.repeats_left + 1 else request.repeats;
        // A repeated record is installed before the boundary frame settles it once.
        const settlements: i16 = if (push.model.elapsed == 0) 0 else if (!push.model.active()) request.updates else request.updates - push.model.updates_left + @as(i16, @intFromBool(push.model.elapsed >= request.updates));
        const offset_x = if (request.dx < 0) @max(0, -request.dx - 2 * settlements) else -@as(i16, @max(0, request.dx - 2 * settlements));
        const offset_y = if (request.dy < 0) @max(0, -request.dy - 2 * settlements) else -@as(i16, @max(0, request.dy - 2 * settlements));
        if (self.hero.x != @mod(push.start.x + applied * request.dx, 2048) or self.hero.y != @mod(push.start.y + applied * request.dy, 2048) or
            self.hero.offset_x != offset_x or self.hero.offset_y != offset_y or self.hero.speed != 2) return error.InvalidCameraPushState;
        if (push.model.elapsed != 0) {
            const sprite = self.hero_sprite orelse return error.InvalidCameraPushState;
            if (sprite.emitted_x != self.hero.x + self.hero.offset_x or sprite.emitted_y != self.hero.y + self.hero.offset_y) return error.InvalidCameraPushState;
        }
    } else if (self.instance) |instance| {
        if (instance.execution.wait) |wait| if (wait.kind == .camera_push) return error.InvalidCameraPushState;
    }
    if (self.field_effect) |effect| {
        if (!binding.content.hasFieldEffects() or !binding.scripted_motion or binding.room_package == null or
            !std.mem.eql(u8, effect.schema, "suikoden-field-effect-state/1")) return error.InvalidAreaEffectState;
        const instance = self.instance orelse return error.InvalidAreaEffectState;
        const program = binding.content.program(instance.program_id) orelse return error.InvalidAreaEffectState;
        // shortcut: forward scene streams; add branch-aware ownership for an admitted loop crossing an effect.
        if (program.entry != .ordinary or instance.execution.pc > program.commands.len or
            effect.command >= program.commands.len or effect.command >= instance.execution.pc)
            return error.InvalidAreaEffectState;
        const command = program.commands[effect.command];
        if (command.kind != .field_effect or command.x != effect.position.x or command.y != effect.position.y)
            return error.InvalidAreaEffectState;
        var history: runtime.CommandHistory = .{ .commands = program.commands, .execution = instance.execution };
        var reached = false;
        while (history.next()) |executed| {
            if (executed.index == effect.command) reached = true else if (reached and executed.command.kind == .field_effect) return error.InvalidAreaEffectState;
        }
        if (!reached) return error.InvalidAreaEffectState;
        try effect.model.validate(command.effect.?);
        if (!instance.execution.active and effect.model.clock.callback != null) return error.InvalidAreaEffectState;
    }
    if (self.pending_battle) |queued| {
        const owner = if (self.instance) |*value| value else return error.InvalidFieldBattleReceipt;
        const id = owner.pendingBattle() orelse return error.InvalidFieldBattleReceipt;
        if (!std.mem.eql(u8, queued, id)) return error.InvalidFieldBattleReceipt;
    }
    // Field-event schemas 11-18 keep the accepted constructor/ground/receipt validation
    // byte for byte; only the Opening route schemas use the extended owner.
    if (!openingSchema(self.schema)) return validateLegacy(self, binding);
    if (self.hero_descriptor_state) |retained| {
        _ = binding.hero_descriptor orelse return error.MissingHeroDescriptorContext;
        try retained.auxiliary.validateState(binding.hero_animation);
        try retained.entry.validate();
        // These capabilities admit only the recovered constructor/reset,
        // paired-tick and ground-plane draw writers, not arbitrary objects.
        const child0c = retained.auxiliary.child_0c;
        const child10 = retained.auxiliary.child_10;
        if (!((child10.attr_18 == 0x80 and child10.attr_19 == 0) or
            (child10.attr_18 == 0x22 and child10.attr_19 == 1))) return error.InvalidHeroDescriptorState;
        if (retained.entry.phase == .pending or binding.hero_descriptor.?.room_byte7 != 1) {
            if (child0c.attr_18 != 0x80 or child0c.attr_19 != 0) return error.InvalidHeroDescriptorState;
        } else if (child0c.attr_19 != 2 or child0c.attr_18 != (if (retained.tint_word == 0) @as(u8, 0) else @as(u8, @truncate(retained.tint_word +% 0x20)))) return error.InvalidHeroDescriptorState;
        if (retained.entry.title_hold != binding.hero_descriptor.?.entry_title_hold or
            (retained.entry.phase == .pending and retained.tint_word != 0) or retained.tint_word > 0x80) return error.InvalidHeroDescriptorState;
    }
    try self.fade_state.validate();
    if (self.fade_state.step != fade.default_step) return error.InvalidFieldEventState;
    if (self.fade_state.enabled) {
        const owner = self.instance orelse return error.InvalidFieldEventState;
        const program = binding.content.program(owner.program_id) orelse return error.InvalidFieldEventState;
        if (owner.execution.pc > program.commands.len) return error.InvalidFieldEventState;
        var requested: ?@FieldType(runtime.Command, "kind") = null;
        var history: runtime.CommandHistory = .{ .commands = program.commands, .execution = owner.execution };
        while (history.next()) |executed| if (executed.command.kind == .fade_out or executed.command.kind == .fade_in) {
            requested = executed.command.kind;
        };
        if (self.fade_state.direction == .from_black) {
            if (!binding.content.hasFadeIn() or requested != .fade_in or self.fade_state.level % 8 != 7 or (self.fade_state.active and (owner.execution.wait == null or owner.execution.wait.?.kind != .fade))) return error.InvalidFieldEventState;
        } else {
            if (requested != .fade_out) return error.InvalidFieldEventState;
            if (self.fade_state.active and (owner.execution.wait == null or owner.execution.wait.?.kind != .fade or self.fade_state.level % 8 != 0)) return error.InvalidFieldEventState;
        }
    }
    try validateHeaderContext(self, binding);
    const requires_construction = binding.ordinary != null and !self.selected_program;
    if (!requires_construction) return error.UnsupportedFieldGroundConstruction;
    try binding.validateContext();
    const access = binding.ground orelse return error.UnsupportedFieldGroundConstruction;
    const actors_constructed = self.ordinary_actors orelse return error.UnsupportedFieldGroundConstruction;
    if (self.selected_program or actors_constructed.count > actors_constructed.slots.len or access.identity.len == 0 or !std.mem.eql(u8, self.construction_ground_identity, access.identity)) return error.UnsupportedFieldGroundConstruction;
    try validateConstructedGround(&binding, &actors_constructed, access, true);
    const retained_schema = std.mem.eql(u8, self.schema, "suikoden-field-event/21") or std.mem.eql(u8, self.schema, "suikoden-field-event/22");
    if (retained_schema != (self.retained_selection != null)) return error.InvalidFieldEventState;
    if (self.retained_selection) |selected| {
        if (std.mem.eql(u8, self.schema, "suikoden-field-event/22")) {
            if (selected != 2 or self.selected_program or !self.initialization_done or
                !std.mem.eql(u8, binding.content.id, "va1_room2_field_events") or
                !std.mem.eql(u8, binding.room, "va1_room_2") or binding.population.source.room != 2) return error.InvalidFieldEventState;
            const owner = self.instance orelse return error.InvalidFieldEventState;
            const program = binding.content.program("va1_r02_e02_ordinary") orelse return error.InvalidFieldEventState;
            const actors = self.ordinary_actors orelse return error.MissingFieldActorConstruction;
            if (program.entity != 2 or program.entry != .ordinary or !std.mem.eql(u8, owner.program_id, program.id) or
                actors.construction_story.scenario[0] != 0x40 or !std.mem.allEqual(u8, actors.construction_story.scenario[1..], 0)) return error.InvalidFieldEventState;
            const descriptor = self.room2_descriptor orelse return error.InvalidDescriptorInitialization;
            _ = try room2DescriptorBinding(binding);
            // The supported history ends before the first native text open.
            // Refuse a fabricated early text owner until the later event
            // history and the other source flag owners are integrated.
            if (descriptor.history_len > 2 or owner.execution.pc > 3) return error.UnsupportedRoom2EventReceipt;
            const expected_sequence: u64 = if (descriptor.movement != null) 3 else descriptor.history_len;
            if (owner.effect_sequence != expected_sequence or owner.pending != null or owner.execution.wait != null or
                owner.execution.reloop or owner.execution.choice != 0) return error.InvalidFieldEventReceipt;
            if (descriptor.movement) |saved_movement| {
                if (descriptor.history_len != 2 or owner.execution.pc != 3 or descriptor.movement_frames > 28) return error.UnsupportedRoom2EventReceipt;
                var replay: room2_movement.Owner = .{};
                try replay.commit(try replay.proposeRequest(0x3d17c, 1));
                for (0..descriptor.movement_frames) |frame| try replay.commit(try replay.proposeTick(@intCast(frame + 2)));
                if (!std.meta.eql(replay.state, saved_movement) or self.receipt == null or self.receipt.?.batch != 3) return error.InvalidFieldEventReceipt;
            } else if (owner.execution.pc != descriptor.history_len or descriptor.movement_frames != 0) return error.UnsupportedRoom2EventReceipt;
            if ((descriptor.history_len == 0) != (descriptor.descriptor_16_result == null) or
                (descriptor.descriptor_16_result != null and descriptor.descriptor_16_result != 0xe0)) return error.InvalidDescriptorInitialization;
            for (descriptor.batches, 0..) |batch, i| {
                if (i < descriptor.history_len) {
                    if (batch != i + 1) return error.InvalidFieldEventReceipt;
                } else if (batch != 0) return error.InvalidFieldEventReceipt;
            }
            if (descriptor.history_len != 0) {
                const receipt = self.receipt orelse return error.InvalidFieldEventReceipt;
                if (receipt.instance != self.serial or receipt.batch != (if (descriptor.movement != null) @as(u64, 3) else descriptor.batches[descriptor.history_len - 1])) return error.InvalidFieldEventReceipt;
            }
        } else {
            if (selected != 27 or self.selected_program or !self.initialization_done or
                !std.mem.eql(u8, binding.content.id, "va1_room0_field_events") or
                !std.mem.eql(u8, binding.room, "va1_room_0") or binding.population.source.room != 0) return error.InvalidFieldEventState;
            const source_entity = for (binding.population.entities) |candidate| {
                if (candidate.source_order == selected) break candidate;
            } else return error.InvalidFieldEventState;
            if (source_entity.record_role != .character or !source_entity.population_candidate or
                source_entity.classification.pointer_state == .null or source_entity.event_selection.pointer_state == .null or
                source_entity.trigger != .interaction or source_entity.event.status != .resolved or
                source_entity.event.program_id == null or source_entity.resource_id == null or
                !std.mem.eql(u8, source_entity.event.program_id.?, "va1_r00_e27_ordinary")) return error.InvalidFieldEventState;
            const program = binding.content.program("va1_r00_e27_ordinary") orelse return error.InvalidFieldEventState;
            const owner = self.instance orelse return error.InvalidFieldEventState;
            const actors = self.ordinary_actors orelse return error.MissingFieldActorConstruction;
            if (actors.construction_story.scenario[0] != 0x40 or
                !std.mem.allEqual(u8, actors.construction_story.scenario[1..], 0) or
                !std.mem.eql(u8, owner.program_id, program.id) or !retainedE27Program(program) or
                !actors.construction_story.matches(program.conditions)) return error.InvalidFieldEventState;
            var eligible_storage: [population.max_entities]population.Entity = undefined;
            const eligible = try population.select(binding.population, .{ .story = &actors.construction_story, .active_party_count = self.active_party_count }, &eligible_storage);
            const source_eligible = for (eligible.entities) |candidate| {
                if (candidate.source_order == selected) break true;
            } else false;
            if (!source_eligible) return error.InvalidFieldEventState;
            var interaction_term = false;
            for (source_entity.event_selection.terms) |term| switch (term.kind) {
                .interaction => interaction_term = true,
                .story_mask_set, .story_mask_clear => {
                    const condition: runtime.Condition = .{ .kind = if (term.kind == .story_mask_set) .story_mask_set else .story_mask_clear, .flag = term.flag.? };
                    if (!actors.construction_story.matches(&.{condition})) return error.InvalidFieldEventState;
                },
                .coordinate_range, .unsupported => return error.UnsupportedFieldEventPredicate,
                else => return error.UnsupportedFieldEventPredicate,
            };
            if (!interaction_term) return error.InvalidFieldEventState;
            const actor_index = for (binding.ordinary.?.actors, 0..) |definition, index| {
                if (definition.entity == selected) break index;
            } else return error.MissingFieldActorConstruction;
            if (actor_index >= actors.count or actors.slots[actor_index] == null or
                actors.slots[actor_index].?.phase != .active or actors.slots[actor_index].?.avatar == null) return error.InvalidFieldActorState;
            const definition = binding.ordinary.?.actors[actor_index];
            const avatar = actors.slots[actor_index].?.avatar.?;
            if (definition.entity != source_entity.source_order or
                !std.mem.eql(u8, definition.resource, source_entity.resource_id.?) or
                definition.x != source_entity.position.x or definition.y != source_entity.position.y or
                avatar.motion.x != 808 or avatar.motion.y != 488 or avatar.motion.moving() or avatar.support != null) return error.InvalidFieldActorState;
            if (owner.execution.active or owner.pending != null) {
                if (self.hero.x != 808 or self.hero.y != 472 or self.hero.moving() or
                    self.hero.offset_x != 0 or self.hero.offset_y != 0 or self.facing != .down) return error.InvalidFieldEventState;
            } else {
                const interaction_receipt = self.receipt orelse return error.InvalidFieldEventReceipt;
                if (owner.execution.reloop or owner.execution.choice != 0 or owner.execution.wait != null or
                    owner.execution.pc != program.commands.len or owner.effect_sequence == 0 or
                    interaction_receipt.batch != owner.effect_sequence or interaction_receipt.instance != self.serial or
                    !std.mem.eql(u8, interaction_receipt.content_sha256, binding.content.content_sha256) or
                    !std.mem.eql(u8, interaction_receipt.program, program.id)) return error.InvalidFieldEventReceipt;
            }
        }
    }
    if (!std.mem.eql(u8, self.schema, "suikoden-field-event/22") and self.room2_descriptor != null) return error.InvalidDescriptorInitialization;
    if (self.completed_event != null or self.reconstruction != null) return error.InvalidFieldEventReceipt;
    if (self.position_history != null) return error.InvalidFieldActorPositionHistory;
    const jobs = self.tracks();
    const ownership: ?ordinary.PositionOwnership = null;
    const initialized_position = try initializedPosition(self, binding);
    if (self.ordinary_actors) |actors| {
        var storage: [3]ordinary.Position = undefined;
        const descriptor_positions = try descriptorInitializerPositions(self, binding, &storage);
        var scripted_storage: [64]ordinary.Position = undefined;
        const scripted_positions = try checks.scriptedActorPositions(self, binding, &scripted_storage);
        if (self.room2_descriptor) |descriptor| {
            if (descriptor_positions.len != 0 or initialized_position != null) return error.InvalidDescriptorInitialization;
            const position = [_]ordinary.Position{room2ActorPosition(descriptor)};
            try actors.validateTracksAtMany(binding.ordinary.?, binding.animations, binding.content, &jobs, ownership, &position);
        } else if (scripted_positions.len != 0) {
            if (descriptor_positions.len != 0 or initialized_position != null) return error.InvalidFieldActorPositionHistory;
            try actors.validateTracksAtMany(binding.ordinary.?, binding.animations, binding.content, &jobs, null, scripted_positions);
        } else if (descriptor_positions.len != 0) {
            if (initialized_position != null) return error.InvalidDescriptorInitialization;
            try actors.validateTracksAtMany(binding.ordinary.?, binding.animations, binding.content, &jobs, ownership, descriptor_positions);
        } else try actors.validateTracksAt(binding.ordinary orelse return error.InvalidFieldActorState, binding.animations, binding.content, &jobs, ownership, initialized_position);
    }
    const multiple = for (self.other_tracks) |job| {
        if (job != null) break true;
    } else false;
    if (self.ordinary_track != null or multiple or self.movement_identity.len != 0 or self.movement_camera != null) return error.InvalidFieldActorState;
    if (self.selected_program and binding.ordinary != null and self.ordinary_actors == null) return error.MissingFieldActorConstruction;
    if (!std.mem.eql(u8, self.content_sha256, binding.content.content_sha256) or !std.mem.eql(u8, self.population_sha256, binding.population.content_sha256) or !std.mem.eql(u8, self.queue_sha256, binding.queues.content_sha256) or !std.mem.eql(u8, self.dialogue_sha256, binding.dialogue.content_sha256) or !std.mem.eql(u8, self.graphics_sha256, if (binding.queues.graphics) |graphics| graphics.content_sha256 else "") or !std.mem.eql(u8, self.hero_sha256, binding.hero_sha256)) return error.FieldEventIdentityMismatch;
    try validateHeroSpriteState(self, binding, true);
    try validateInitializations(self, binding, true);
    try validateRuntimeQueuesAndActors(self, binding);
    try validateInstanceState(self, binding, true);
    try validateAudioState(self, binding, false);
}
