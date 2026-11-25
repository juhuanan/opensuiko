const std = @import("std");
const rl = @import("raylib");
const ui = @import("ui");
const war = @import("war");
const view = @import("war_view");

fn dialogue(text: []const u8, x: i32, y: i32) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var row: i32 = 0;
    while (lines.next()) |line| : (row += 12) ui.text(line, x, y + row, 10, .ray_white);
}

pub const Platform = struct {
    texture: rl.Texture2D,
    frame: view.Frame,

    pub fn init() !Platform {
        var frame: view.Frame = undefined;
        @memset(&frame.pixels, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
        const image: rl.Image = .{
            .data = &frame.pixels,
            .width = view.width,
            .height = view.height,
            .mipmaps = 1,
            .format = .uncompressed_r8g8b8a8,
        };
        return .{ .texture = try rl.loadTextureFromImage(image), .frame = frame };
    }

    pub fn deinit(self: *Platform) void {
        rl.unloadTexture(self.texture);
        self.* = undefined;
    }

    pub fn draw(self: *Platform, model: *const view.View, engine: *const war.Engine, command_index: u8, result_hint: []const u8) !void {
        try model.render(engine, &self.frame);
        rl.updateTexture(self.texture, &self.frame.pixels);
        rl.drawTexture(self.texture, 0, 0, .white);
        ui.panel(0, 0, view.width, 23);
        ui.numberText("Liberation Army  {d}", .{engine.sides[0].remaining}, 8, 5, 12, .ray_white);
        ui.numberText("Imperial Army  {d}", .{engine.sides[1].remaining}, 168, 5, 12, .ray_white);
        if (engine.script) |script| {
            const rows = model.scenario.script;
            if ((engine.scenario.selector == 2 or engine.scenario.selector == 4) and rows.len >= 3) {
                const row = rows[rows.len - 3 + @min(script.confirmations, 2)];
                if (row.text) |text| dialogue(text, 78, 180);
            } else if (engine.phase == .result) {
                for (rows) |row| if (row.text) |text| {
                    if (std.mem.indexOf(u8, text, "Congratulations") != null) {
                        dialogue(text, 78, 180);
                        break;
                    }
                };
            }
            if (engine.phase == .scripted and script.phase == engine.scenario.lifecycle.wait_phase) {
                ui.text("Confirm", 78, 216, 12, .gold);
            }
        } else {
            ui.numberText("Troops {d}", .{engine.troops[0]}, 78, 180, 12, .light_gray);
            if (engine.scouted_attack) |attack| ui.numberText("Scout: {s}", .{engine.scenario.attacks[attack].name}, 166, 180, 10, .gold);
            if (engine.selected_index < model.scenario.roster.len) if (model.scenario.roster[engine.selected_index].name) |name| ui.text(name, 78, 194, 10, .light_gray);
            const names = [_][]const u8{ "Charge", "Bow", "Magic", "Special" };
            const commands = [_]war.Command{ .charge, .bow, .magic, .special };
            for (names, 0..) |name, index| {
                const selected = index == command_index;
                const available = view.commandAvailable(engine, commands[index]);
                ui.text(name, 78 + @as(i32, @intCast(index)) * 60, 216, 10, if (selected) .gold else if (available) .light_gray else .dark_gray);
            }
        }
        if (engine.phase == .result) {
            const result = engine.result.?;
            ui.panel(64, 68, 192, 92);
            ui.text(switch (result.outcome) {
                .side0_victory, .forced_victory => "Victory",
                .side1_victory, .forced_defeat => "Defeat",
                .scripted_completion => "Battle complete",
            }, 82, 79, 18, .gold);
            ui.numberText("Losses {d} / {d}", .{ result.casualties[0], result.casualties[1] }, 82, 110, 12, .light_gray);
            ui.text(result_hint, 82, 134, 10, .ray_white);
        }
    }
};
