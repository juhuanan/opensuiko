const std = @import("std");
const field = @import("field");
const runtime = @import("event_runtime");
const records = @import("opening_records");
const ted_party_add = records.ted_party_add;
const field_records = records.field_records;
const room2_descriptor = @import("descriptor_release");
const room2_movement = @import("movement_batch");
const room2_text_host = @import("room2_text").host;
const fade = @import("fade");
const population = @import("scene_population");
const dispatch = @import("scene_dispatch");
const motion = @import("opening_audience");
const hero_descriptor = @import("hero_descriptor");
const data = @import("field_events_data");
const ordinary = @import("field_actors");
const village = @import("village_initializer.zig");
const fe = @import("field_events.zig");
const Room2Descriptor = fe.Room2Descriptor;
const TextState = fe.TextState;
const TextSpeed = fe.TextSpeed;
const Binding = fe.Binding;
const DialogueData = fe.DialogueData;
const QueueData = fe.QueueData;
const GraphicsData = fe.GraphicsData;

pub const HeroAnimations = struct { animations: []const motion.Animation };
pub const DispatchBundle = struct {
    id: []const u8,
    content_sha256: []const u8,
    source: population.Source,
    population: dispatch.Identity,
    contents: []const struct { content: ?runtime.Content = null },
};
pub const FieldPredicates = struct {
    schema: []const u8,
    id: []const u8,
    population_sha256: []const u8,
    content_sha256: []const u8,
    records: []const struct {
        entity: u8,
        terms: []const struct { kind: enum { x_range, y_range, up_input }, source_kind: []const u8, min_pixel: ?i32 = null, max_pixel: ?i32 = null },
    },
    pub fn validate(self: FieldPredicates, packet: population.Packet) !void {
        const trusted = std.json.parseFromSlice(FieldPredicates, std.heap.page_allocator, data.vb6_predicates, .{}) catch return error.InvalidFieldPredicates;
        defer trusted.deinit();
        if (!semanticEqual(self, trusted.value)) return error.InvalidFieldPredicates;
        if (!std.mem.eql(u8, self.schema, "suikoden-field-predicates/1") or !std.mem.eql(u8, self.id, "vb6_room6_predicates") or !std.mem.eql(u8, self.population_sha256, packet.content_sha256) or self.content_sha256.len != 64 or self.records.len != 5) return error.InvalidFieldPredicates;
        for (self.records, 0..) |record, i| {
            if (record.entity != i or i >= packet.entities.len) return error.InvalidFieldPredicates;
            const terms = packet.entities[i].event_selection.terms;
            if (record.terms.len != terms.len) return error.InvalidFieldPredicates;
            for (record.terms, terms) |term, source| {
                const expected = switch (term.kind) {
                    .x_range => "event_predicate_0b",
                    .y_range => "event_predicate_0c",
                    .up_input => "event_predicate_04",
                };
                if (source.kind != .unsupported or source.semantics == null or !std.mem.eql(u8, term.source_kind, expected) or !std.mem.eql(u8, source.semantics.?, expected)) return error.InvalidFieldPredicates;
                if (term.kind == .up_input) {
                    if (term.min_pixel != null or term.max_pixel != null) return error.InvalidFieldPredicates;
                } else {
                    const low = term.min_pixel orelse return error.InvalidFieldPredicates;
                    const high = term.max_pixel orelse return error.InvalidFieldPredicates;
                    if (low < 0 or high < low or high > 2040 or @mod(low, 8) != 0 or @mod(high, 8) != 0) return error.InvalidFieldPredicates;
                }
            }
        }
    }
};
pub fn semanticEqual(a: anytype, b: @TypeOf(a)) bool {
    return switch (@typeInfo(@TypeOf(a))) {
        .@"struct" => |info| blk: {
            inline for (info.field_names) |name| if (!semanticEqual(@field(a, name), @field(b, name))) break :blk false;
            break :blk true;
        },
        .optional => if (a) |value| (if (b) |other| semanticEqual(value, other) else false) else b == null,
        .array => blk: {
            for (a, b) |value, other| if (!semanticEqual(value, other)) break :blk false;
            break :blk true;
        },
        .pointer => |info| if (info.size == .slice) blk: {
            if (a.len != b.len) break :blk false;
            for (a, b) |value, other| if (!semanticEqual(value, other)) break :blk false;
            break :blk true;
        } else a == b,
        else => std.meta.eql(a, b),
    };
}
pub const Context = struct {
    schema: []const u8,
    room: []const u8,
    event_id: []const u8,
    event_sha256: []const u8,
    population_id: []const u8,
    population_sha256: []const u8,
    dialogue_sha256: []const u8,
    dialogue_counts: [5]u16,
    party_queue: bool,
    ordinary_sha256: ?[]const u8 = null,
    content_sha256: []const u8,
};
pub const Sources = struct { context: []const u8, events: []const u8, population: []const u8, dialogue: []const u8 };
pub const vb6_sources: Sources = .{ .context = data.context, .events = data.events, .population = data.population, .dialogue = data.dialogue };
pub const vaa_sources: Sources = .{ .context = data.vaa_context, .events = data.vaa_events, .population = data.vaa_population, .dialogue = data.vaa_dialogue };

// The base supplies the shared Hero and queue resources; this binding owns the village data.
pub const VillageDialogue = struct {
    content: std.json.Parsed(runtime.Content),
    exit_content: std.json.Parsed(runtime.Content),
    exit_context: std.json.Parsed(Context),
    exit_dialogue: std.json.Parsed(DialogueData),
    context: std.json.Parsed(Context),
    dialogue: std.json.Parsed(DialogueData),
    actors: std.json.Parsed(ordinary.Packet),
    animations: std.json.Parsed(HeroAnimations),
    population: std.json.Parsed(population.Packet),

    pub fn load(allocator: std.mem.Allocator) !VillageDialogue {
        const content = try std.json.parseFromSlice(runtime.Content, allocator, data.village_dialogue_events, .{ .allocate = .alloc_always });
        errdefer content.deinit();
        const exit_content = try std.json.parseFromSlice(runtime.Content, allocator, data.village_exit_events, .{ .allocate = .alloc_always });
        errdefer exit_content.deinit();
        const exit_context = try std.json.parseFromSlice(Context, allocator, data.village_exit_context, .{ .allocate = .alloc_always });
        errdefer exit_context.deinit();
        const exit_dialogue = try std.json.parseFromSlice(DialogueData, allocator, data.village_exit_dialogue, .{ .allocate = .alloc_always });
        errdefer exit_dialogue.deinit();
        const context = try std.json.parseFromSlice(Context, allocator, data.village_dialogue_context, .{ .allocate = .alloc_always });
        errdefer context.deinit();
        const dialogue = try std.json.parseFromSlice(DialogueData, allocator, data.village_dialogue, .{ .allocate = .alloc_always });
        errdefer dialogue.deinit();
        const actors = try std.json.parseFromSlice(ordinary.Packet, allocator, data.village_dialogue_actors, .{ .allocate = .alloc_always });
        errdefer actors.deinit();
        const animations = try std.json.parseFromSlice(HeroAnimations, allocator, data.village_animations, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
        errdefer animations.deinit();
        const scene = try population.load(allocator, data.village_population);
        errdefer scene.deinit();
        try content.value.validate();
        try exit_content.value.validate();
        try exit_dialogue.value.validate(exit_content.value);
        try dialogue.value.validate(content.value);
        try actors.value.validate(animations.value.animations);
        return .{ .content = content, .exit_content = exit_content, .exit_context = exit_context, .exit_dialogue = exit_dialogue, .context = context, .dialogue = dialogue, .actors = actors, .animations = animations, .population = scene };
    }
    pub fn binding(self: *const VillageDialogue, base: *const Owned) Binding {
        var result = base.binding();
        result.content = self.content.value;
        result.context = self.context.value;
        result.room = self.context.value.room;
        result.dialogue = self.dialogue.value;
        result.population = self.population.value;
        result.ordinary = self.actors.value;
        result.animations = self.animations.value.animations;
        result.dispatch = null;
        result.queues.graphics = null;
        return result;
    }
    pub fn exitBinding(self: *const VillageDialogue, base: *const Owned) Binding {
        var result = self.binding(base);
        result.content = self.exit_content.value;
        result.context = self.exit_context.value;
        result.dialogue = self.exit_dialogue.value;
        result.ordinary = null;
        return result;
    }
    pub fn deinit(self: VillageDialogue) void {
        self.exit_dialogue.deinit();
        self.exit_context.deinit();
        self.exit_content.deinit();
        self.population.deinit();
        self.animations.deinit();
        self.actors.deinit();
        self.dialogue.deinit();
        self.context.deinit();
        self.content.deinit();
    }
};

pub const Owned = struct {
    context: std.json.Parsed(Context),
    events: std.json.Parsed(runtime.Content),
    population: std.json.Parsed(population.Packet),
    queues: std.json.Parsed(QueueData),
    dialogue: std.json.Parsed(DialogueData),
    graphics: std.json.Parsed(GraphicsData),
    hero: std.json.Parsed(HeroAnimations),
    ordinary_actors: ?std.json.Parsed(ordinary.Packet) = null,
    dispatch_packet: ?std.json.Parsed(dispatch.Packet) = null,
    dispatch_bundle: ?std.json.Parsed(DispatchBundle) = null,
    dispatch_predicates: ?std.json.Parsed(FieldPredicates) = null,
    dispatch_contents: [8]runtime.Content = undefined,
    dispatch_count: usize = 0,
    hero_sha256: [64]u8,
    party: [6]u8,
    count: u8,

    pub fn load(allocator: std.mem.Allocator, members: []const field.game_state.Member) !Owned {
        return loadSources(allocator, members, vb6_sources);
    }
    pub fn loadSources(allocator: std.mem.Allocator, members: []const field.game_state.Member, files: Sources) !Owned {
        if (members.len == 0 or members.len > 6) return error.InvalidParty;
        const identities = try std.json.parseFromSlice(struct { schema: []const u8, records: []const struct { id: []const u8, source_character: u8 } }, allocator, data.party, .{ .ignore_unknown_fields = true });
        defer identities.deinit();
        if (!std.mem.eql(u8, identities.value.schema, "suikoden-field-event-party/1") or identities.value.records.len > 78) return error.InvalidFieldEventBinding;
        for (identities.value.records, 0..) |record, index| {
            if (record.source_character == 255) return error.InvalidFieldEventBinding;
            for (identities.value.records[0..index]) |prior| if (std.mem.eql(u8, prior.id, record.id) or prior.source_character == record.source_character) return error.InvalidFieldEventBinding;
        }
        var party: [6]u8 = @splat(255);
        for (members, 0..) |member, index| {
            party[index] = for (identities.value.records) |record| {
                if (std.mem.eql(u8, record.id, member.id)) break record.source_character;
            } else return error.MissingSourcePartyIdentity;
        }
        const context = try std.json.parseFromSlice(Context, allocator, files.context, .{ .allocate = .alloc_always });
        errdefer context.deinit();
        const events = try std.json.parseFromSlice(runtime.Content, allocator, files.events, .{ .allocate = .alloc_always });
        errdefer events.deinit();
        try events.value.validate();
        const graphics = try std.json.parseFromSlice(GraphicsData, allocator, data.graphics, .{ .allocate = .alloc_always });
        errdefer graphics.deinit();
        try graphics.value.validate();
        var queues = try std.json.parseFromSlice(QueueData, allocator, data.queues, .{ .allocate = .alloc_always });
        errdefer queues.deinit();
        queues.value.graphics = if (context.value.party_queue) graphics.value else null;
        try queues.value.validate();
        const dialogue = try std.json.parseFromSlice(DialogueData, allocator, files.dialogue, .{ .allocate = .alloc_always });
        errdefer dialogue.deinit();
        try dialogue.value.validate(events.value);
        const hero = try std.json.parseFromSlice(HeroAnimations, allocator, motion.json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
        errdefer hero.deinit();
        var selected: ?motion.Animation = null;
        if (hero.value.animations.len > 64) return error.InvalidFieldHeroAnimation;
        for (hero.value.animations) |animation| if (std.mem.eql(u8, animation.graphic, "hero")) {
            if (selected != null) return error.InvalidFieldHeroAnimation;
            selected = animation;
        };
        const bytes = try std.json.Stringify.valueAlloc(allocator, selected orelse return error.InvalidFieldHeroAnimation, .{});
        defer allocator.free(bytes);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const actors = if (context.value.ordinary_sha256 != null) try std.json.parseFromSlice(ordinary.Packet, allocator, data.ordinary, .{ .allocate = .alloc_always }) else null;
        errdefer if (actors) |value| value.deinit();
        if (actors) |value| try value.value.validate(hero.value.animations);
        const policy = if (std.mem.eql(u8, context.value.population_id, "vb6_room6")) try dispatch.load(allocator, data.dispatch) else null;
        errdefer if (policy) |value| value.deinit();
        const bundle = if (policy != null) try std.json.parseFromSlice(DispatchBundle, allocator, data.vb6_bundle, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) else null;
        errdefer if (bundle) |value| value.deinit();
        const predicates = if (policy != null) try std.json.parseFromSlice(FieldPredicates, allocator, data.vb6_predicates, .{ .allocate = .alloc_always }) else null;
        errdefer if (predicates) |value| value.deinit();
        var result: Owned = .{ .context = context, .ordinary_actors = actors, .dispatch_packet = policy, .dispatch_bundle = bundle, .dispatch_predicates = predicates, .events = events, .population = try population.load(allocator, files.population), .queues = queues, .dialogue = dialogue, .graphics = graphics, .hero = hero, .hero_sha256 = std.fmt.bytesToHex(digest, .lower), .party = party, .count = @intCast(members.len) };
        errdefer result.population.deinit();
        if (bundle) |value| {
            for (value.value.contents) |entry| if (entry.content) |content| {
                if (result.dispatch_count == result.dispatch_contents.len - 1) return error.InvalidDispatchContent;
                try content.validate();
                result.dispatch_contents[result.dispatch_count] = content;
                result.dispatch_count += 1;
            };
            result.dispatch_contents[result.dispatch_count] = events.value;
            result.dispatch_count += 1;
        }
        try result.binding().validateContext();
        return result;
    }
    pub fn binding(self: *const Owned) Binding {
        const hero = for (self.hero.value.animations) |animation| {
            if (std.mem.eql(u8, animation.graphic, "hero")) break animation;
        } else unreachable;
        return .{ .ordinary = if (self.ordinary_actors) |value| value.value else null, .dispatch = if (self.dispatch_packet) |value| .{ .packet = value.value, .bundle = self.dispatch_bundle.?.value, .predicates = self.dispatch_predicates.?.value, .contents = self.dispatch_contents[0..self.dispatch_count] } else null, .animations = self.hero.value.animations, .room = self.context.value.room, .context = self.context.value, .content = self.events.value, .population = self.population.value, .queues = self.queues.value, .dialogue = self.dialogue.value, .hero_animation = hero, .hero_sha256 = &self.hero_sha256, .party = self.party[0..self.count] };
    }
    pub fn deinit(self: Owned) void {
        if (self.ordinary_actors) |value| value.deinit();
        if (self.dispatch_bundle) |value| value.deinit();
        if (self.dispatch_predicates) |value| value.deinit();
        if (self.dispatch_packet) |value| value.deinit();
        self.context.deinit();
        self.population.deinit();
        self.events.deinit();
        self.queues.deinit();
        self.dialogue.deinit();
        self.graphics.deinit();
        self.hero.deinit();
    }
};

pub fn candidateJson(comptime T: type, init: std.process.Init, path: []const u8, ignore_unknown: bool) !std.json.Parsed(T) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(1024 * 1024));
    defer init.gpa.free(bytes);
    return std.json.parseFromSlice(T, init.gpa, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = ignore_unknown });
}

// Private source candidate; the caller owns the original binding and all parsed packets.
pub const FollowonCandidate = struct {
    content: std.json.Parsed(runtime.Content),
    context: std.json.Parsed(Context),
    dialogue: ?std.json.Parsed(DialogueData),
    actors: std.json.Parsed(ordinary.Packet),
    animations: std.json.Parsed(HeroAnimations),
    policy: std.json.Parsed(dispatch.Packet),
    bundle: std.json.Parsed(DispatchBundle),
    contents: [8]runtime.Content = undefined,
    count: u8 = 0,

    pub fn load(init: std.process.Init, base: *const Owned, with_dialogue: bool) !FollowonCandidate {
        if (base.dispatch_packet == null or base.dispatch_bundle == null or base.dispatch_predicates == null) return error.MissingFieldDispatch;
        const content = try candidateJson(runtime.Content, init, "game/assets/events/vb6_room6_followons.json", false);
        errdefer content.deinit();
        const context = try candidateJson(Context, init, if (with_dialogue) "game/assets/vb6_field_context_dialogue.json" else "game/assets/vb6_field_context_followons.json", false);
        errdefer context.deinit();
        const dialogue = if (with_dialogue) try candidateJson(DialogueData, init, "game/assets/field_dialogue_vb6_e7.json", false) else null;
        errdefer if (dialogue) |value| value.deinit();
        const actors = try candidateJson(ordinary.Packet, init, "game/assets/field_ordinary_actors_vb6_followons.json", false);
        errdefer actors.deinit();
        const animations = try candidateJson(HeroAnimations, init, "game/assets/field_ordinary_animations_vb6.json", true);
        errdefer animations.deinit();
        const policy = try candidateJson(dispatch.Packet, init, "game/assets/scenes/dispatch/vb6_room6_followons.json", false);
        errdefer policy.deinit();
        try dispatch.validate(policy.value);
        const bundle = try candidateJson(DispatchBundle, init, "game/assets/scenes/events/vb6_room6_followons.json", true);
        errdefer bundle.deinit();
        var result: FollowonCandidate = .{ .content = content, .context = context, .dialogue = dialogue, .actors = actors, .animations = animations, .policy = policy, .bundle = bundle };
        for (bundle.value.contents) |entry| if (entry.content) |value| {
            if (result.count == result.contents.len - 1) return error.InvalidDispatchContent;
            result.contents[result.count] = value;
            result.count += 1;
        };
        result.contents[result.count] = base.events.value;
        result.count += 1;
        return result;
    }

    pub fn binding(self: *const FollowonCandidate, base: *const Owned) Binding {
        var result = base.binding();
        result.content = self.content.value;
        result.context = self.context.value;
        if (self.dialogue) |value| result.dialogue = value.value;
        result.ordinary = self.actors.value;
        result.animations = self.animations.value.animations;
        result.dispatch = .{ .packet = self.policy.value, .bundle = self.bundle.value, .predicates = result.dispatch.?.predicates, .contents = self.contents[0..self.count] };
        return result;
    }

    pub fn deinit(self: FollowonCandidate) void {
        self.content.deinit();
        self.context.deinit();
        if (self.dialogue) |value| value.deinit();
        self.actors.deinit();
        self.animations.deinit();
        self.policy.deinit();
        self.bundle.deinit();
    }
};
