//! Candidate overload view using the existing native menu skin.
const ui = @import("ui");
const rl = @import("raylib");
const journey = @import("journey");

pub fn draw(state: *const journey.State, context: *const ui.Context) !void {
    const active = state.item_overload orelse return;
    const labels = journey.overload.layout;
    rl.drawRectangle(0, 24, 512, 384, .{ .r = 0, .g = 0, .b = 0, .a = 160 });
    context.window(24, 64, 464, 300);
    switch (active.phase) {
        .overloaded, .offer => {
            context.text(labels.overloaded, 44, 84, 18, .ray_white);
            context.text(active.item.name(), 44, 120, 17, .ray_white);
            if (active.phase == .offer) {
                const rows = [_][]const u8{ labels.continue_selecting, labels.give_up };
                for (rows, 0..) |label, i| {
                    const y = 166 + @as(i32, @intCast(i)) * 28;
                    if (active.choice == i) context.selection(40, y - 3, 320, 24);
                    context.text(label, 48, y, 17, .ray_white);
                }
            }
        },
        .gave_up => {
            context.text(labels.gave_up, 44, 88, 18, .ray_white);
            context.text(active.item.name(), 44, 122, 17, .ray_white);
        },
        .equipped => {
            context.text(labels.equipped, 44, 88, 17, .ray_white);
            const rows = [_][]const u8{ labels.drop, labels.keep };
            for (rows, 0..) |label, i| {
                const y = 150 + @as(i32, @intCast(i)) * 28;
                if (active.choice == i) context.selection(40, y - 3, 320, 24);
                context.text(label, 48, y, 17, .ray_white);
            }
        },
        .members, .items, .commit, .settling => {
            context.text(labels.choose_item, 44, 82, 17, .ray_white);
            for (state.combat.progress.party.items(), 0..) |member, i| {
                const y = 124 + @as(i32, @intCast(i)) * 25;
                if (active.member == i) context.selection(40, y - 3, 150, 23);
                context.text(member.name, 48, y, 16, .ray_white);
            }
            const bag = if (active.phase == .settling) bag: {
                const selection = active.replacement.?;
                break :bag (try journey.overload.prepareReplacement(state, selection.member, selection.slot, active.item)).inventory;
            } else state.combat.progress.party.at(active.member).inventory;
            for (bag.slots[0..bag.count()], 0..) |item, i| {
                const y = 122 + @as(i32, @intCast(i)) * 24;
                if (active.phase == .items and active.slot == i) context.selection(202, y - 3, 264, 23);
                context.text(item.?.name(), 210, y, 15, .ray_white);
            }
        },
    }
}
