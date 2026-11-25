const rl = @import("raylib");
const controller = @import("pause_menu").controller;
pub const State = struct {
    device: ?i32 = null,
    controls: controller.State = .{},
    pub fn poll(self: *State) controller.Output {
        if (self.device) |id| if (!rl.isGamepadAvailable(id)) {
            self.* = .{};
        };
        if (self.device == null) for (0..4) |index| {
            const id: i32 = @intCast(index);
            if (rl.isGamepadAvailable(id)) {
                self.device = id;
                break;
            }
        };
        const id = self.device orelse return self.controls.update(.{}, 0);
        return self.controls.update(.{
            .connected = true,
            .x = rl.getGamepadAxisMovement(id, .left_x),
            .y = rl.getGamepadAxisMovement(id, .left_y),
            .dpad = if (rl.isGamepadButtonDown(id, .left_face_up)) .up else if (rl.isGamepadButtonDown(id, .left_face_down)) .down else if (rl.isGamepadButtonDown(id, .left_face_left)) .left else if (rl.isGamepadButtonDown(id, .left_face_right)) .right else null,
            .physical_up = rl.isGamepadButtonDown(id, .left_face_up),
            .confirm = rl.isGamepadButtonDown(id, .right_face_down),
            .cancel = rl.isGamepadButtonDown(id, .right_face_right),
            .menu = rl.isGamepadButtonDown(id, .middle_right),
        }, rl.getFrameTime());
    }
};
