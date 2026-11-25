const std = @import("std");
const runtime = @import("event_runtime");

pub const max_records = 64;

pub const Effect = struct {
    kind: enum { move, advance, face, set_motion, clear_height, finish },
    selector: u8,
    flags: u8,
    direction: ?runtime.Direction = null,
    motion: ?u8 = null,
};

pub const Record = struct {
    selector: u8,
    glyph_bytes: []const u8,
    countdown: u8,
    flags: u8,
    cursor: u16 = 0,
    direction: runtime.Direction = .down,
    advancing: bool = false,
};

pub const Queue = struct {
    records: [max_records]?Record = @splat(null),
    count: u8 = 0,

    pub fn empty(self: *const Queue) bool {
        return self.count == 0;
    }

    pub fn validate(self: *const Queue) !void {
        if (self.count > self.records.len) return error.InvalidDrawRecordQueue;
        for (self.records, 0..) |entry, index| {
            if (index < self.count) {
                const record = entry orelse return error.InvalidDrawRecordQueue;
                if (!runtime.validDrawRecordBytes(record.glyph_bytes) or record.cursor > record.glyph_bytes.len)
                    return error.InvalidDrawRecord;
            } else if (entry != null) return error.InvalidDrawRecordQueue;
        }
    }

    pub fn enqueue(self: *Queue, command: runtime.Command) !void {
        try self.validate();
        if (command.kind != .queue_draw_record) return error.InvalidDrawRecordCommand;
        const bytes = command.glyph_bytes orelse return error.InvalidDrawRecordCommand;
        if (command.selector == null or command.countdown == null or command.flags == null or
            !runtime.validDrawRecordBytes(bytes)) return error.InvalidDrawRecordCommand;
        if (self.count == self.records.len) return error.DrawRecordQueueFull;
        self.records[self.count] = .{
            .selector = command.selector.?,
            .glyph_bytes = bytes,
            .countdown = command.countdown.?,
            .flags = command.flags.?,
        };
        self.count += 1;
    }

    fn effect(record: Record, kind: @FieldType(Effect, "kind")) Effect {
        return .{
            .kind = kind,
            .selector = record.selector,
            .flags = record.flags,
            .direction = if (kind == .set_motion or kind == .clear_height or kind == .finish) null else record.direction,
            .motion = if (kind == .set_motion) record.glyph_bytes[record.cursor - 1] else null,
        };
    }

    fn remove(self: *Queue, index: usize) void {
        std.debug.assert(index < self.count);
        var cursor = index;
        while (cursor + 1 < self.count) : (cursor += 1) self.records[cursor] = self.records[cursor + 1];
        self.count -= 1;
        self.records[self.count] = null;
    }

    pub fn consume(self: *Queue, index: usize, descriptor_moving: bool) !?Effect {
        try self.validate();
        if (index >= self.count) return error.InvalidDrawRecordIndex;
        if (descriptor_moving) return null;
        var record = &self.records[index].?;
        if (record.countdown != 0) {
            record.countdown -= 1;
            var result = effect(record.*, if (record.advancing) .advance else .move);
            if (record.advancing) result.direction = opposite(record.direction);
            return result;
        }
        const code = record.glyph_bytes[record.cursor];
        if (code == 5) {
            if (record.cursor + 1 != record.glyph_bytes.len) return error.InvalidDrawRecord;
            const result = effect(record.*, .finish);
            self.remove(index);
            return result;
        }
        if (record.cursor + 1 >= record.glyph_bytes.len) return error.InvalidDrawRecord;
        const value = record.glyph_bytes[record.cursor + 1];
        record.cursor += 2;
        switch (code) {
            0...3 => {
                record.direction = @fromBackingInt(@intCast(code));
                record.advancing = false;
                if (value != 0) record.countdown = value - 1;
                return effect(record.*, if (value == 0) .face else .move);
            },
            4 => {
                if (value == 255) return error.UnsupportedDrawRecordMotion;
                return effect(record.*, .set_motion);
            },
            6 => return effect(record.*, .clear_height),
            7 => {
                if (value == 0) return error.UnsupportedDrawRecordAdvance;
                record.advancing = true;
                record.countdown = value - 1;
                var result = effect(record.*, .advance);
                result.direction = opposite(record.direction);
                return result;
            },
            else => return error.UnsupportedDrawRecordCode,
        }
    }
};

fn opposite(direction: runtime.Direction) runtime.Direction {
    return switch (direction) {
        .up => .down,
        .right => .left,
        .down => .up,
        .left => .right,
    };
}
