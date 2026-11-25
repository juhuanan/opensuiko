//! Decoded scenery instances and 16px-footprint collision queries in 8px cells.
const std = @import("std");

// shortcut: capacity follows the extraction guard; increase if a source scene needs more.
pub const max_instances = 1024;
const staged_position = 2040;
pub const Object = struct {
    x: u16,
    y: u16,
    width_cells: u8,
    height_cells: u8,
    layer: u8,
    collides: bool,
    mask: []const u8,
};
pub const Instance = struct {
    object: u16,
    x: u16,
    y: u16,

    pub fn active(self: Instance) bool {
        return self.x != staged_position or self.y != staged_position;
    }
};
pub const Support = struct { layer: u8 = 0, instance: ?u16 = null };
pub const Query = struct {
    bits: u12 = 0,
    support: ?u16 = null,

    pub fn solid(self: Query, terrain: u4, layer: u8) u4 {
        const low: u4 = @truncate(self.bits);
        const upper: u4 = @truncate(self.bits >> 4);
        const coverage: u4 = @truncate(self.bits >> 8);
        if (layer == 0) {
            if (self.support != null and upper & ~low != 0) return low | (terrain & ~coverage);
            return (low & ~upper) | terrain;
        }
        return if (self.support != null) (low & coverage) | (terrain & ~coverage) else low | (terrain & ~coverage);
    }
};

pub const Model = struct {
    schema: []const u8,
    columns: u16,
    rows: u16,
    initial_count: u16,
    terrain: []const u8,
    objects: []const Object,

    pub fn validate(self: Model) !void {
        if (!std.mem.eql(u8, self.schema, "suikoden-field-scenery/1") or self.columns < 2 or self.rows < 2 or self.columns > 256 or self.rows > 256 or
            self.terrain.len != @as(usize, self.columns) * self.rows or self.initial_count > max_instances or
            self.initial_count > self.objects.len or self.objects.len > max_instances + 256) return error.InvalidFieldScenery;
        for (self.terrain) |cell| if (!((cell >= '0' and cell <= '9') or (cell >= 'a' and cell <= 'f'))) return error.InvalidFieldScenery;
        for (self.objects) |object| {
            if (!validPosition(object.x, object.y) or object.mask.len != @as(usize, object.width_cells) * object.height_cells) return error.InvalidFieldScenery;
            for (object.mask) |cell| if (cell < '0' or cell > '3') return error.InvalidFieldScenery;
        }
    }

    pub fn initial(self: Model, index: usize) Instance {
        const object = self.objects[index];
        return .{ .object = @intCast(index), .x = object.x, .y = object.y };
    }

    pub fn supportAfter(self: Model, state: ?*const State, current: Support, query_result: Query) Support {
        var next = current;
        if (query_result.support) |index| {
            if (query_result.bits & 0xf0 != 0) {
                // The support index is byte-sized; wrapping precedes the level lookup.
                const selected: u8 = @truncate(index);
                const instance = if (state) |value| value.instances[selected] else self.initial(selected);
                next = .{ .layer = self.objects[instance.object].layer, .instance = selected };
            }
        } else if (query_result.bits == 0) next.layer = 0;
        return next;
    }

    pub fn digest(self: Model) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(self.schema);
        var word: [2]u8 = undefined;
        for ([_]u16{ self.columns, self.rows, self.initial_count, @intCast(self.objects.len) }) |value| {
            std.mem.writeInt(u16, &word, value, .little);
            hash.update(&word);
        }
        hash.update(self.terrain);
        for (self.objects) |object| {
            for ([_]u16{ object.x, object.y }) |value| {
                std.mem.writeInt(u16, &word, value, .little);
                hash.update(&word);
            }
            hash.update(&.{ object.width_cells, object.height_cells, object.layer, @intFromBool(object.collides) });
            hash.update(object.mask);
        }
        return hash.finalResult();
    }

    pub fn query(self: Model, state: ?*const State, x: i32, y: i32, layer: u8) Query {
        var result: Query = .{};
        const count = if (state) |value| value.count else self.initial_count;
        for (0..count) |index| {
            const instance = if (state) |value| value.instances[index] else self.initial(index);
            if (!instance.active()) continue;
            const object = self.objects[instance.object];
            const ox: i32 = @divExact(instance.x, 8);
            const oy: i32 = @divExact(instance.y, 8);
            if (!object.collides or (@as(u16, object.layer) != layer and @as(u16, object.layer) != @as(u16, layer) + 1) or
                x < ox - 1 or x >= ox + object.width_cells or y < oy - 1 or y >= oy + object.height_cells or result.bits & 255 != 0) continue;
            result = .{};
            for (0..4) |bit| {
                const cx = x + @as(i32, @intCast(bit & 1)) - ox;
                const cy = y + @as(i32, @intCast(bit >> 1)) - oy;
                if (cx < 0 or cy < 0 or cx >= object.width_cells or cy >= object.height_cells) continue;
                const value = object.mask[@as(usize, @intCast(cy)) * object.width_cells + @as(usize, @intCast(cx))] - '0';
                result.bits |= (@as(u12, 1) << @intCast(8 + bit)) | (@as(u12, value & 1) << @intCast(bit)) | (@as(u12, value & 2) << @intCast(3 + bit));
            }
            if (result.bits & 15 == 0) result.support = @intCast(index);
        }
        return result;
    }

    pub fn canStand(self: Model, state: ?*const State, x: i32, y: i32, layer: u8) bool {
        if (x < 0 or y < 0 or @mod(x, 8) != 0 or @mod(y, 8) != 0) return false;
        const cx = @divExact(x, 8);
        const cy = @divExact(y, 8);
        if (cx >= self.columns - 1 or cy >= self.rows - 1) return false;
        const cell = self.terrain[@as(usize, @intCast(cy)) * self.columns + @as(usize, @intCast(cx))];
        const terrain: u4 = @intCast(if (cell <= '9') cell - '0' else cell - 'a' + 10);
        return self.query(state, cx, cy, layer).solid(terrain, layer) == 0;
    }
};

fn validPosition(x: u16, y: u16) bool {
    return x <= 2040 and y <= 2040 and x % 8 == 0 and y % 8 == 0;
}

pub const Stored = struct {
    model_sha256: [32]u8,
    instances: []const Instance,

    pub fn restore(self: Stored) !State {
        if (self.instances.len > max_instances) return error.InvalidFieldSceneryState;
        var result: State = .{ .model_sha256 = self.model_sha256, .count = @intCast(self.instances.len) };
        for (self.instances) |instance| if (!validPosition(instance.x, instance.y)) return error.InvalidFieldSceneryState;
        @memcpy(result.instances[0..result.count], self.instances);
        return result;
    }
};

pub const State = struct {
    model_sha256: [32]u8,
    count: u16 = 0,
    instances: [max_instances]Instance = @splat(.{ .object = 0, .x = 0, .y = 0 }),

    pub fn init(model: Model) !State {
        try model.validate();
        var result: State = .{ .model_sha256 = model.digest(), .count = model.initial_count };
        for (0..result.count) |index| result.instances[index] = model.initial(index);
        return result;
    }

    pub fn append(self: *State, model: Model, object: u16) !u16 {
        try model.validate();
        if (!std.meta.eql(self.model_sha256, model.digest())) return error.FieldSceneryContentMismatch;
        if (object < model.initial_count or object >= model.objects.len) return error.UnknownFieldSceneryTemplate;
        if (self.count >= max_instances) return error.FieldSceneryCapacity;
        const index = self.count;
        self.instances[index] = model.initial(object);
        self.count += 1;
        return index;
    }

    pub fn stage(self: *State, index: u16) !void {
        if (index >= self.count) return error.UnknownFieldSceneryInstance;
        self.instances[index].x = staged_position;
        self.instances[index].y = staged_position;
    }

    pub fn restore(self: *State, model: Model, index: u16) !void {
        try self.validate(model);
        if (index >= self.count) return error.UnknownFieldSceneryInstance;
        self.instances[index] = model.initial(self.instances[index].object);
    }

    pub fn validate(self: *const State, model: Model) !void {
        try model.validate();
        if (!std.meta.eql(self.model_sha256, model.digest())) return error.FieldSceneryContentMismatch;
        if (self.count < model.initial_count or self.count > max_instances) return error.InvalidFieldSceneryState;
        for (self.instances[0..self.count], 0..) |instance, index| {
            if (instance.object >= model.objects.len or
                (index < model.initial_count and instance.object != index) or
                (index >= model.initial_count and instance.object < model.initial_count)) return error.InvalidFieldSceneryState;
            const object = model.objects[instance.object];
            if ((instance.x != object.x or instance.y != object.y) and instance.active()) return error.InvalidFieldSceneryState;
        }
    }

    pub fn stored(self: *const State) Stored {
        return .{ .model_sha256 = self.model_sha256, .instances = self.instances[0..self.count] };
    }
    pub fn jsonStringify(self: *const State, writer: anytype) !void {
        try writer.write(self.stored());
    }
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !State {
        return (try std.json.innerParse(Stored, allocator, source, options)).restore() catch return error.UnexpectedToken;
    }
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !State {
        return (try std.json.innerParseFromValue(Stored, allocator, source, options)).restore() catch return error.UnexpectedToken;
    }
};
