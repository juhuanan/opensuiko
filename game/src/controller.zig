const std = @import("std");
const field = @import("field");
pub const Raw = struct { connected: bool = false, x: f32 = 0, y: f32 = 0, dpad: ?field.Direction = null, physical_up: bool = false, confirm: bool = false, cancel: bool = false, menu: bool = false };
pub const Output = struct {
    direction: ?field.Direction = null,
    navigation: ?field.Direction = null,
    confirm: bool = false,
    cancel: bool = false,
    menu: bool = false,
    physical_up: bool = false,

    pub fn jsonStringify(self: Output, writer: anytype) !void {
        try writer.beginObject();
        inline for (comptime std.meta.fieldNames(Output)) |name| {
            if (comptime std.mem.eql(u8, name, "physical_up")) {
                if (self.physical_up) {
                    try writer.objectField(name);
                    try writer.write(true);
                }
            } else {
                const value = @field(self, name);
                const emit = if (comptime @typeInfo(@TypeOf(value)) == .optional)
                    writer.options.emit_null_optional_fields or value != null
                else
                    true;
                if (emit) {
                    try writer.objectField(name);
                    try writer.write(value);
                }
            }
        }
        try writer.endObject();
    }
};
pub const State = struct {
    ready: bool = false,
    previous: Raw = .{},
    held: ?field.Direction = null,
    repeat: f32 = 0,
    pub fn update(self: *State, raw: Raw, seconds: f32) Output {
        if (!raw.connected) {
            self.* = .{};
            return .{};
        }
        var result = Output{};
        const x = if (std.math.isFinite(raw.x)) std.math.clamp(raw.x, -1, 1) else 0;
        const y = if (std.math.isFinite(raw.y)) std.math.clamp(raw.y, -1, 1) else 0;
        const direction: ?field.Direction = raw.dpad orelse if (@max(@abs(x), @abs(y)) < 0.3) null else if (@abs(y) >= @abs(x)) (if (y < 0) .up else .down) else (if (x < 0) .left else .right);
        // A newly connected or refocused controller must be released before it can act.
        if (!self.ready) {
            self.ready = direction == null and !raw.physical_up and !raw.confirm and !raw.cancel and !raw.menu;
            self.previous = raw;
            return result;
        }
        result.direction = direction;
        result.physical_up = raw.physical_up or raw.dpad == .up;
        result.confirm = raw.confirm and !self.previous.confirm;
        result.cancel = raw.cancel and !self.previous.cancel;
        result.menu = raw.menu and !self.previous.menu;
        if (direction != self.held) {
            result.navigation = direction;
            self.repeat = 0.35;
        } else if (direction != null) {
            self.repeat -= if (std.math.isFinite(seconds)) std.math.clamp(seconds, 0, 0.1) else 0;
            if (self.repeat <= 0) {
                result.navigation = direction;
                self.repeat = 0.09;
            }
        }
        self.held = direction;
        self.previous = raw;
        return result;
    }
};
