//! Shared Ivy/Mad Ivy vine clock. Rendering consumes thirteen world samples.
const std = @import("std");
const camera = @import("battle_camera");

pub const Art = struct { strip: u16, leaves: [2]u16, leaf_extents: [2][2]u16 };
pub const Quad = struct { vertices: [4][2]i32, depth: i32 };

pub fn rootQ12(value: u31) u32 {
    if (value == 0) return 0;
    const zeros: i32 = @intCast(@clz(@as(u32, value)) & ~@as(u6, 1));
    const exponent = @divFloor(19 - zeros, 2);
    const normalized = if (zeros >= 24) @as(u32, value) << @as(u5, @intCast(zeros - 24)) else @as(u32, value) >> @as(u5, @intCast(24 - zeros));
    const calibrated: u32 = std.math.sqrt(normalized << 18);
    return if (exponent >= 0) calibrated << @as(u5, @intCast(exponent)) else calibrated >> @as(u5, @intCast(-exponent));
}

pub fn segmentBasis(delta: [2]i32) ?[4]i32 {
    const squared = (delta[0] *% delta[0] +% delta[1] *% delta[1]) *% 4096;
    if (squared <= 0) return null;
    const length: i32 = @intCast(rootQ12(@intCast(squared)));
    const x: i32 = @as(i16, @truncate(@divTrunc(delta[0] *% 16777216, length)));
    const y: i32 = @as(i16, @truncate(@divTrunc(delta[1] *% 16777216, length)));
    const negative_y: i32 = @as(i16, @truncate(@divTrunc((0 -% delta[1]) *% 16777216, length)));
    return .{ x, negative_y, y, x };
}

pub fn quad(points: [13][3]i32, block: camera.Block, index: usize, anchor: [2]i16, extent: [2]u16) ?Quad {
    if (index >= 18 or block.translation[2] <= 0) return null;
    const bias = @divTrunc(block.scale[0] *% 16384, block.translation[2] *% 4096);
    var result: Quad = undefined;
    if (index < 12) {
        const basis = segmentBasis(.{ points[index + 1][0] - points[index][0], points[index + 1][1] - points[index][1] }) orelse return null;
        var matrix = [9]i32{ basis[0], basis[1], 0, basis[2], basis[3], 0, 0, 0, 4096 };
        for (&matrix, 0..) |*value, component| value.* = @as(i16, @truncate((value.* *% block.scale[component % 3]) >> 12));
        result.depth = (points[index][2] >> 2) * 4;
        for (&result.vertices, 0..) |*vertex, corner| {
            const local = camera.rawProjectMatrix(matrix, block.translation, .{ if (corner & 1 != 0) 16 else 0, if (corner >= 2) 8 else 0, 0 });
            vertex.* = .{ @as(i16, @truncate(points[index][0] + local[0] + bias)), @as(i16, @truncate(points[index][1] + local[1])) };
        }
    } else {
        const group = (index - 12) / 3;
        const sample = 10 - group - 2 * ((index - 12) % 3);
        const scale = [2]i32{ @divTrunc(block.scale[0] *% 1024, block.translation[2]), @divTrunc(block.scale[1] *% 1024, block.translation[2]) };
        result.depth = 0;
        for (&result.vertices, 0..) |*vertex, corner| {
            const x = -@as(i32, anchor[0]) + (if (corner & 1 != 0) extent[0] else @as(i32, 0));
            const y = -@as(i32, anchor[1]) + (if (corner >= 2) extent[1] else @as(i32, 0));
            vertex.* = .{ @as(i16, @truncate(points[sample][0] + bias + @divTrunc(x *% scale[0], 4096))), @as(i16, @truncate(points[sample][1] + @divTrunc(y *% scale[1], 4096))) };
        }
    }
    return result;
}

pub const State = struct {
    points: [3][3]i32 = @splat(@splat(0)),
    velocity: [3]i32 = @splat(0),
    remaining: u8 = 10,
    initialized: bool = false,
    visible: bool = false,

    pub const Result = enum { active, finished };

    pub fn advance(self: *State, stage: *i16, start: [3]i32, target_home: [3]i32) !Result {
        self.visible = false;
        switch (stage.*) {
            0 => {
                if (!self.initialized) {
                    self.* = .{ .initialized = true };
                    self.points[0] = start;
                    for (0..3) |axis| {
                        const middle = start[axis] +% @divTrunc(target_home[axis] -% start[axis], 2);
                        self.points[1][axis] = middle;
                        self.points[2][axis] = middle;
                        self.velocity[axis] = @divTrunc(target_home[axis] -% middle, 10);
                    }
                    self.points[2][2] -%= 60 * 4096;
                    stage.* = 1;
                    return .active;
                }
            },
            99 => {
                stage.* = 100;
                return .active;
            },
            100 => return .finished,
            else => {},
        }
        if (!self.initialized) return error.MissingActorMotion;
        if (stage.* == 1) {
            if (self.remaining > 0) {
                self.remaining -= 1;
                for (0..3) |axis| self.points[2][axis] +%= self.velocity[axis];
            } else stage.* = 2;
        } else if (stage.* == 2) {
            self.points[2][0] -%= 4 * 4096;
            if (self.points[2][2] >= 0) self.points[2][2] = 0;
        }
        self.visible = true;
        return .active;
    }

    pub fn samples(self: State) [13][3]i32 {
        var result: [13][3]i32 = undefined;
        for (&result, 0..) |*point, index| {
            const k: i32 = @intCast(index);
            for (0..3) |axis| {
                const start = self.points[0][axis];
                const control = self.points[1][axis];
                const end = self.points[2][axis];
                const curve = @divTrunc((start -% (control *% 2) +% end) *% k *% k, 144);
                const linear = @divTrunc((control -% start) *% (2 * k), 12);
                point[axis] = start +% curve +% linear;
            }
        }
        return result;
    }
};
