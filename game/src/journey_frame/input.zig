//! Window/controller polling, text entry, and per-tick input accumulation.
const rl = @import("raylib");
const raylib_app = @import("raylib_app");
const controller_platform = @import("../controller_platform.zig");
const field = @import("field");
const battle = @import("battle");
const pause = @import("pause_menu");
const recovery_layer = @import("platform_recovery");
const journey = @import("journey");
const dice_view = @import("../dice_view.zig");

pub const FrameInput = struct {
    safe: recovery_layer.Sample,
    erase_key: bool,
    title_text: []const u8,
};

pub const InputState = struct {
    menu_input: pause.Input = .{},
    battle_input: battle.Input = .{},
    dice_sampler: journey.dice.Entry.Sampler = .{},
    dice_input: journey.dice.Entry.Controls = .{},
    party_sampler: journey.party_selection.selector.Sampler = .{},
    collision: bool = false,
    controller: controller_platform.State = .{},
    recovery: recovery_layer.Recovery = .{ .mode = .field },
    typed: [32]u8 = undefined,
    typed_len: usize = 0,

    pub fn pollFocused(self: *InputState, title_phase: @FieldType(pause.title.State, "phase"), state: *const journey.State) FrameInput {
        const pad = self.controller.poll();
        self.recovery.device(self.controller.device != null, self.controller.device);
        self.dice_input.merge(dice_view.poll(&self.dice_sampler, title_phase == .playing and state.dice_game != null, self.controller.device));
        const naming = state.menu.phase == .name_save or title_phase == .hero_name;
        while (true) {
            const character = rl.getCharPressed();
            if (character == 0) break;
            if (naming and character >= 32 and character <= 126 and self.typed_len < self.typed.len) {
                self.typed[self.typed_len] = @intCast(character);
                self.typed_len += 1;
            }
        }
        const erase_key = rl.isKeyPressed(.backspace) or rl.isKeyPressedRepeat(.backspace);
        self.menu_input.text = if (state.menu.phase == .name_save) self.typed[0..self.typed_len] else &.{};
        self.menu_input.erase = self.menu_input.erase or (state.menu.phase == .name_save and erase_key);
        if (rl.isKeyPressed(.f2)) self.collision = !self.collision;
        const nav: @TypeOf(pad.navigation) = if (title_phase == .hero_name)
            if (pad.navigation == .up or rl.isKeyPressed(.up)) .up else if (pad.navigation == .down or rl.isKeyPressed(.down)) .down else if (pad.navigation == .left or rl.isKeyPressed(.left)) .left else if (pad.navigation == .right or rl.isKeyPressed(.right)) .right else null
        else if (pad.navigation == .up or raylib_app.anyKeyPressed(.up, .w)) .up else if (pad.navigation == .down or raylib_app.anyKeyPressed(.down, .s)) .down else if (pad.navigation == .left or raylib_app.anyKeyPressed(.left, .a)) .left else if (pad.navigation == .right or raylib_app.anyKeyPressed(.right, .d)) .right else null;
        const raw = recovery_layer.Sample{
            .direction = raylib_app.heldDirection(field.Direction) orelse pad.direction,
            .navigation = nav,
            .confirm = pad.confirm or (if (naming) rl.isKeyPressed(.enter) else raylib_app.anyKeyPressed(.z, .enter) or (state.mode == .field and rl.isKeyPressed(.space))),
            .cancel = pad.cancel or (if (naming) rl.isKeyPressed(.escape) else raylib_app.anyKeyPressed(.x, .escape)),
            .menu = pad.menu or raylib_app.anyKeyPressed(.tab, .escape),
            .physical_up = pad.physical_up,
        };
        const safe = self.recovery.frame(raw);
        const title_text = if (title_phase == .hero_name) self.typed[0..self.typed_len] else &.{};
        return .{ .safe = safe, .erase_key = erase_key, .title_text = title_text };
    }

    pub fn accumulateGameplay(self: *InputState, safe: recovery_layer.Sample) void {
        const up = safe.navigation == .up;
        const down = safe.navigation == .down;
        const left = safe.navigation == .left;
        const right = safe.navigation == .right;
        self.menu_input.field.direction = safe.direction;
        self.menu_input.field.action = self.menu_input.field.action or safe.confirm;
        self.menu_input.field.cancel = self.menu_input.field.cancel or safe.cancel;
        if (up) self.menu_input.field.menu_direction = .up;
        if (down) self.menu_input.field.menu_direction = .down;
        self.menu_input.menu = self.menu_input.menu or safe.menu;
        self.menu_input.left = self.menu_input.left or left;
        self.menu_input.right = self.menu_input.right or right;
        self.battle_input.up = self.battle_input.up or up;
        self.battle_input.down = self.battle_input.down or down;
        self.battle_input.left = self.battle_input.left or left;
        self.battle_input.right = self.battle_input.right or right;
        self.battle_input.confirm = self.battle_input.confirm or safe.confirm;
        self.battle_input.cancel = self.battle_input.cancel or safe.cancel;
    }

    pub fn samplePartySelection(self: *InputState) journey.party_selection.selector.Sampler.Sample {
        const held = dice_view.pollHeld(self.controller.device);
        return self.party_sampler.sample(.{
            .up = held.up,
            .down = held.down,
            .left = held.left,
            .right = held.right,
            .confirm = held.confirm,
            .cancel = held.cancel,
        });
    }

    pub fn clearStepEdges(self: *InputState, direction: ?field.Direction) void {
        self.typed_len = 0;
        self.menu_input = .{ .field = .{ .direction = direction } };
        self.battle_input = .{};
    }

    pub fn clearUnfocused(self: *InputState) void {
        _ = self.dice_sampler.sample(.{}, false, null);
        self.dice_input = .{};
        self.controller = .{};
        self.typed_len = 0;
        self.menu_input = .{};
        self.battle_input = .{};
    }

    pub fn resetForGameplay(self: *InputState, clear_edges: bool) void {
        self.controller = .{};
        if (clear_edges) {
            self.recovery = .{ .mode = .field };
            self.menu_input = .{};
            self.battle_input = .{};
            self.typed_len = 0;
        } else {
            _ = self.recovery.begin(.field);
        }
    }
};
