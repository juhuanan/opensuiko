const std = @import("std");
const builtin = @import("builtin");
const field = @import("field");

pub const filename = "slot1.json";
pub const max_bytes = 64 * 1024;
pub const Snapshot = struct {
    schema: []const u8,
    room: []const u8,
    x: i32,
    y: i32,
    facing: field.Direction,
    money: u32,
    party: []field.game_state.Member,
    story: ?field.game_state.Story = null,

    const Wire = struct {
        schema: []const u8,
        room: []const u8,
        x: i32,
        y: i32,
        facing: field.Direction,
        money: u32,
        party: []const field.game_state.CharacterRecord,
        story: ?field.game_state.Story = null,
    };

    pub fn jsonStringify(self: Snapshot, writer: *std.json.Stringify) !void {
        var party: [6]field.game_state.CharacterRecord = undefined;
        if (self.party.len > party.len) return error.WriteFailed;
        for (self.party, 0..) |member, i| party[i] = member.record();
        try writer.write(Wire{
            .schema = self.schema,
            .room = self.room,
            .x = self.x,
            .y = self.y,
            .facing = self.facing,
            .money = self.money,
            .party = party[0..self.party.len],
            .story = self.story,
        });
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Snapshot {
        const wire = try std.json.innerParse(Wire, allocator, source, options);
        const party = try allocator.alloc(field.game_state.Member, wire.party.len);
        for (party, wire.party) |*member, record| member.* = record.character();
        return .{
            .schema = wire.schema,
            .room = wire.room,
            .x = wire.x,
            .y = wire.y,
            .facing = wire.facing,
            .money = wire.money,
            .party = party,
            .story = wire.story,
        };
    }

    pub fn validate(self: Snapshot, package: field.Package) !void {
        if (std.mem.eql(u8, self.schema, "suikoden-save/1")) {
            if (self.story != null) return error.InvalidLegacySave;
        } else if (std.mem.eql(u8, self.schema, "suikoden-save/2") or std.mem.eql(u8, self.schema, "suikoden-save/3")) {
            if (self.story == null) return error.MissingStoryState;
        } else return error.UnsupportedSaveVersion;
        if (!std.mem.eql(u8, self.schema, "suikoden-save/3")) {
            for (self.party) |member| if (member.inventory.count() != 0) return error.InvalidLegacySave;
        }
        const room = package.roomIndex(self.room) orelse return error.UnknownSaveRoom;
        if (!package.rooms[room].canStand(self.x, self.y)) return error.InvalidSavePosition;
        try (field.game_state.Progress{ .money = self.money, .party = self.party }).validate();
    }

    pub fn capture(state: field.State, package: field.Package) !Snapshot {
        if (state.remaining != 0 or state.dialogue != null or state.rest_ticks != 0) return error.GameBusy;
        const result = Snapshot{ .schema = "suikoden-save/3", .room = package.rooms[state.room].id, .x = state.x, .y = state.y, .facing = state.facing, .money = state.progress.money, .party = state.progress.party, .story = state.progress.story };
        try result.validate(package);
        return result;
    }

    pub fn apply(self: Snapshot, package: field.Package, state: *field.State) !void {
        try self.validate(package);
        var restored_progress: field.game_state.Progress = .{ .money = self.money, .party = self.party, .story = self.story orelse .initial };
        var restored = field.State.init(package, &restored_progress);
        restored.room = package.roomIndex(self.room).?;
        restored.x = self.x;
        restored.y = self.y;
        restored.destination = .{ .x = self.x, .y = self.y };
        restored.facing = self.facing;
        restored.inn_rules = state.inn_rules;
        restored.item_rules = state.item_rules;
        state.commitProgress(restored);
    }
};

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, package: field.Package) !std.json.Parsed(Snapshot) {
    if (bytes.len > max_bytes) return error.SaveTooLarge;
    const document = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer document.deinit();
    if (document.value != .object) return error.InvalidSave;
    if (document.value.object.get("schema")) |schema| {
        if (schema == .string and std.mem.eql(u8, schema.string, "suikoden-save/3")) {
            const party = document.value.object.get("party") orelse return error.InvalidParty;
            if (party != .array) return error.InvalidParty;
            for (party.array.items) |member| {
                if (member != .object) return error.InvalidMember;
                const inventory = member.object.get("inventory") orelse return error.MissingInventory;
                if (inventory != .object or !inventory.object.contains("slots")) return error.MissingInventory;
            }
        }
    }
    const parsed = try std.json.parseFromSlice(Snapshot, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate(package);
    return parsed;
}

pub fn write(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, package: field.Package, state: field.State) !void {
    const snapshot = try Snapshot.capture(state, package);
    const bytes = try std.json.Stringify.valueAlloc(allocator, snapshot, .{ .whitespace = .indent_2 });
    defer allocator.free(bytes);
    try atomicWrite(io, directory, filename, bytes);
}

pub fn atomicWrite(io: std.Io, directory: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    var atomic = try directory.createFileAtomic(io, name, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

pub fn read(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, package: field.Package) !std.json.Parsed(Snapshot) {
    const bytes = try directory.readFileAlloc(io, filename, allocator, .limited(max_bytes));
    defer allocator.free(bytes);
    return decode(allocator, bytes, package);
}

pub fn restore(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, package: field.Package, state: *field.State) !std.json.Parsed(Snapshot) {
    const parsed = try read(allocator, io, directory, package);
    errdefer parsed.deinit();
    try parsed.value.apply(package, state);
    return parsed;
}

pub fn defaultDirectory(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map) ![]u8 {
    const name = "Suikoden Zig";
    if (builtin.os.tag == .windows) {
        const base = environment.get("LOCALAPPDATA") orelse return error.SaveDirectoryUnavailable;
        if (!std.fs.path.isAbsolute(base)) return error.SaveDirectoryUnavailable;
        return std.fs.path.join(allocator, &.{ base, name });
    }
    if (builtin.os.tag != .macos) {
        if (environment.get("XDG_DATA_HOME")) |base| {
            if (std.fs.path.isAbsolute(base)) return std.fs.path.join(allocator, &.{ base, name });
        }
    }
    const home = environment.get("HOME") orelse return error.SaveDirectoryUnavailable;
    if (!std.fs.path.isAbsolute(home)) return error.SaveDirectoryUnavailable;
    if (builtin.os.tag == .macos) return std.fs.path.join(allocator, &.{ home, "Library", "Application Support", name });
    return std.fs.path.join(allocator, &.{ home, ".local", "share", name });
}
