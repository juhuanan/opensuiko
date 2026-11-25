//! Opcode12 owns a name-prefix wait and optional synchronous image selection.
//! It requires an allocated text object, independently of body-box visibility.
const std = @import("std");
const source_data = @import("opening_assets").native_slots;

pub const SlotId = enum(u1) { first, second };
pub const CommandKey = struct { instance: u64, batch: u64, origin: u16 };
pub const Request = struct { slot: SlotId, code: u8, command: CommandKey };
pub const Name = struct { code: u8, text: []const u8, glyph_ends: []const u8 };
pub const Resource = struct {
    code: u8,
    id: u32,
    /// Original image pointer is nonnull. This never means media is accepted,
    /// decoded, uploaded or renderable; presentation blocks independently.
    available: bool = true,
};
pub const Context = struct {
    /// Changed whenever caller-owned names, section resources or loaded order change.
    generation: u64,
    names: []const Name,
    custom_images: []const Resource,
    loaded_characters: []const Resource,
};
pub const Room = struct { room: u8, section: u8, custom_images: []const Resource };
pub const Asset = struct {
    schema: []const u8,
    content_sha256: []const u8,
    names: []const Name,
    rooms: []const Room,
    initial_glyph_countdowns: [3]u8,
    pub fn context(self: Asset, room_number: u8, generation: u64, loaded: []const Resource) !Context {
        for (self.rooms) |room| if (room.room == room_number) return .{ .generation = generation, .names = self.names, .custom_images = room.custom_images, .loaded_characters = loaded };
        return error.NativeRoomResourcesRequired;
    }
};
pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Asset) {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual, source_data.slots_sha256)) return error.StaleNativeSlotAsset;
    const parsed = try std.json.parseFromSlice(Asset, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    const asset = parsed.value;
    if (!std.mem.eql(u8, asset.schema, "suikoden-opening-native-slots/1") or asset.content_sha256.len != 64 or
        asset.names.len != 124 or asset.rooms.len != 2 or !std.mem.eql(u8, &asset.initial_glyph_countdowns, &.{ 2, 4, 11 }))
        return error.InvalidNativeSlotAsset;
    for (asset.rooms) |room| try validateContext(try asset.context(room.room, 0, &.{}));
    return parsed;
}
pub const Image = struct { id: u32, origin: enum { custom, loaded_character } };
pub const Flow = enum { wait, advance };
pub const Proposal = struct {
    request: Request,
    revision: u64,
    context_generation: u64,
    /// Fingerprints include source order and values, not caller-owned pointers.
    state_digest: u64,
    context_digest: u64,
    flow: Flow,
    starts: bool,
    image: ?Image,
    prefix: ?Name,
};
/// Shared TextState consumes the exported glyph tokens followed by a newline.
pub const Prefix = struct { glyph_count: u8, consumed: u8 = 0, done: bool = false, generation: u64 };
pub const Slot = struct {
    allocated: bool = false,
    waiting: ?Request = null,
    prefix: ?Prefix = null,
    image: ?Image = null,
};
pub const GlyphReceipt = struct {
    request: Request,
    generation: u64,
    /// Shared TextState cursor, including the appended03 newline token.
    consumed: u8,
    done: bool,
};

pub const Owner = struct {
    revision: u64 = 0,
    slots: [2]Slot = .{ .{}, .{} },

    fn nextRevision(self: Owner) !u64 {
        return std.math.add(u64, self.revision, 1) catch error.NativeSlotRevisionExhausted;
    }

    pub fn validate(self: Owner) !void {
        for (self.slots, 0..) |slot, index| {
            if (!slot.allocated and slot.prefix != null) return error.InvalidNativeSlot;
            if (slot.waiting) |request| {
                if (@backingInt(request.slot) != index) return error.InvalidNativeSlot;
                if (hasPrefix(request.code) and slot.allocated and slot.prefix == null) return error.InvalidNativeSlot;
            }
            if (slot.prefix) |prefix| {
                if (prefix.glyph_count > 32 or prefix.consumed > prefix.glyph_count + 1 or
                    prefix.done != (prefix.consumed == prefix.glyph_count + 1)) return error.InvalidNativePrefix;
            }
        }
    }

    /// Follow actual object construction; this does not open a body box.
    pub fn allocate(self: *Owner, id: SlotId) !void {
        try self.validate();
        const next_revision = try self.nextRevision();
        const slot = &self.slots[@backingInt(id)];
        if (slot.allocated) return error.NativeSlotAlreadyAllocated;
        slot.* = .{ .allocated = true };
        self.revision = next_revision;
    }

    /// 8013B0C8 resets opcode12's wait status when opening/reopening the object.
    pub fn opened(self: *Owner, id: SlotId) !void {
        try self.validate();
        const next_revision = try self.nextRevision();
        const slot = &self.slots[@backingInt(id)];
        if (!slot.allocated) return error.NativeTextObjectRequired;
        slot.waiting = null;
        self.revision = next_revision;
    }

    /// 8013B2F4 clears image presence when close starts, before object release.
    pub fn closing(self: *Owner, id: SlotId) !void {
        try self.validate();
        const next_revision = try self.nextRevision();
        const slot = &self.slots[@backingInt(id)];
        if (!slot.allocated) return error.NativeTextObjectRequired;
        slot.image = null;
        self.revision = next_revision;
    }

    /// Opcode01 starts closing without the image clear used by opcode0C.
    pub fn closingKeepImage(self: *Owner, id: SlotId) !void {
        try self.validate();
        const next_revision = try self.nextRevision();
        if (!self.slots[@backingInt(id)].allocated) return error.NativeTextObjectRequired;
        self.revision = next_revision;
    }

    /// 8013E3B4 destroys the glyph object; wait status is reset by the next open.
    pub fn released(self: *Owner, id: SlotId) !void {
        try self.validate();
        const next_revision = try self.nextRevision();
        const slot = &self.slots[@backingInt(id)];
        slot.allocated = false;
        slot.prefix = null;
        slot.image = null;
        self.revision = next_revision;
    }

    pub fn propose(self: Owner, request: Request, context: Context) !Proposal {
        try self.validate();
        try validateContext(context);
        _ = try self.nextRevision();
        const slot = self.slots[@backingInt(request.slot)];
        if (!slot.allocated) return error.NativeTextObjectRequired;
        var flow: Flow = .wait;
        const starts = slot.waiting == null;
        var image: ?Image = null;
        var prefix: ?Name = null;
        if (slot.waiting) |waiting| {
            if (!std.meta.eql(waiting, request)) return error.NativeSlotBusy;
            if (!hasPrefix(request.code)) {
                flow = .advance;
            } else {
                if (slot.prefix.?.done) flow = .advance;
            }
        } else {
            if (hasPrefix(request.code)) {
                prefix = try findName(context, request.code);
            }
            image = findImage(context, request.code);
        }
        return .{ .request = request, .revision = self.revision, .context_generation = context.generation, .state_digest = stateDigest(self), .context_digest = contextDigest(context), .flow = flow, .starts = starts, .image = image, .prefix = prefix };
    }

    /// Recompute before commit, so forged/stale receipts cannot mutate state.
    pub fn acknowledge(self: *Owner, proposal: Proposal, context: Context) !void {
        const expected = try self.propose(proposal.request, context);
        if (expected.revision != proposal.revision or expected.context_generation != proposal.context_generation or
            expected.state_digest != proposal.state_digest or expected.context_digest != proposal.context_digest or
            expected.flow != proposal.flow or expected.starts != proposal.starts or !std.meta.eql(expected.image, proposal.image) or
            !sameName(expected.prefix, proposal.prefix)) return error.StaleNativeSlotProposal;
        const next_revision = try self.nextRevision();
        var next = self.*;
        const slot = &next.slots[@backingInt(proposal.request.slot)];
        if (proposal.starts) {
            slot.waiting = proposal.request;
            if (hasPrefix(proposal.request.code)) {
                const name = expected.prefix.?;
                slot.prefix = .{ .glyph_count = @intCast(name.glyph_ends.len), .generation = next_revision };
            }
            // A missing resource leaves prior image presence intact in source.
            if (proposal.image) |image| slot.image = image;
        } else if (proposal.flow == .advance) slot.waiting = null;
        next.revision = next_revision;
        try next.validate();
        self.* = next;
    }

    /// Follow the real shared TextState glyph pass, before event dispatch.
    /// Opening, rendering or resource selection cannot manufacture completion.
    pub fn observeGlyphs(self: *Owner, receipt: GlyphReceipt) !void {
        try self.validate();
        const next_revision = try self.nextRevision();
        var next = self.*;
        const slot = &next.slots[@backingInt(receipt.request.slot)];
        if (!slot.allocated or slot.waiting == null or !std.meta.eql(slot.waiting.?, receipt.request) or slot.prefix == null)
            return error.StaleNativeGlyphReceipt;
        const prefix = &slot.prefix.?;
        if (prefix.generation != receipt.generation or receipt.consumed <= prefix.consumed or
            receipt.consumed > prefix.glyph_count + 1 or receipt.done != (receipt.consumed == prefix.glyph_count + 1))
            return error.StaleNativeGlyphReceipt;
        prefix.consumed = receipt.consumed;
        prefix.done = receipt.done;
        next.revision = next_revision;
        try next.validate();
        self.* = next;
    }
};

pub fn hasPrefix(code: u8) bool {
    return code != 8 and code < 125;
}
fn validateName(name: Name) !void {
    if (name.text.len > 32 or name.glyph_ends.len > 32) return error.UnsupportedNativeName;
    var previous: usize = 0;
    for (name.glyph_ends) |end| {
        if (end <= previous or end > name.text.len) return error.InvalidNativeGlyphBoundaries;
        previous = end;
    }
    if (previous != name.text.len) return error.InvalidNativeGlyphBoundaries;
}
fn validateContext(context: Context) !void {
    for (context.names, 0..) |name, index| {
        if (!hasPrefix(name.code)) return error.InvalidNativeNameCode;
        try validateName(name);
        for (context.names[0..index]) |earlier| if (earlier.code == name.code) return error.DuplicateNativeName;
    }
}
fn findName(context: Context, code: u8) !Name {
    for (context.names) |name| if (name.code == code) return name;
    return error.NativeNameRequired;
}
fn findImage(context: Context, code: u8) ?Image {
    for (context.custom_images) |resource| {
        if (resource.code == code and resource.available) return .{ .id = resource.id, .origin = .custom };
    }
    for (context.loaded_characters) |resource| {
        if (resource.code == code and resource.available) return .{ .id = resource.id, .origin = .loaded_character };
    }
    return null;
}
/// Detect changes in ordered names and resource values; compare canonical values
/// as well when collision-free snapshot identity is required.
pub fn contextFingerprint(context: Context) !u64 {
    try validateContext(context);
    return contextDigest(context);
}

fn contextDigest(context: Context) u64 {
    var hash = std.hash.Wyhash.init(context.generation);
    for (context.names) |name| {
        hash.update(&.{name.code});
        hash.update(name.text);
        hash.update(&.{0});
        hash.update(name.glyph_ends);
        hash.update(&.{0});
    }
    for ([_][]const Resource{ context.custom_images, context.loaded_characters }) |resources| {
        hash.update(std.mem.asBytes(&resources.len));
        for (resources) |resource| {
            hash.update(&.{ resource.code, @intFromBool(resource.available) });
            hash.update(std.mem.asBytes(&resource.id));
        }
    }
    return hash.final();
}
fn stateDigest(owner: Owner) u64 {
    var hash = std.hash.Wyhash.init(owner.revision);
    for (owner.slots) |slot| {
        hash.update(&.{ @intFromBool(slot.allocated), @intFromBool(slot.waiting != null), @intFromBool(slot.prefix != null), @intFromBool(slot.image != null) });
        if (slot.waiting) |request| {
            hash.update(&.{ @backingInt(request.slot), request.code });
            hash.update(std.mem.asBytes(&request.command.instance));
            hash.update(std.mem.asBytes(&request.command.batch));
            hash.update(std.mem.asBytes(&request.command.origin));
        }
        if (slot.prefix) |prefix| {
            hash.update(&.{ prefix.glyph_count, prefix.consumed, @intFromBool(prefix.done) });
            hash.update(std.mem.asBytes(&prefix.generation));
        }
        if (slot.image) |image| {
            hash.update(std.mem.asBytes(&image.id));
            hash.update(&.{@backingInt(image.origin)});
        }
    }
    return hash.final();
}

fn sameName(a: ?Name, b: ?Name) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.code == b.?.code and std.mem.eql(u8, a.?.text, b.?.text) and std.mem.eql(u8, a.?.glyph_ends, b.?.glyph_ends);
}
