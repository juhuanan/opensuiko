const std = @import("std");
const rl = @import("raylib");
const field = @import("field");
const pause = @import("pause_menu");
const ui = @import("ui");
const layout = @import("menu_layout");
const text = ui.text;
const numberText = ui.numberText;
fn frame(context: *const ui.Context, rect: layout.Rect) void {
    context.window(rect.x, rect.y, rect.w, rect.h);
}

const library_pages = [_]struct { title: []const u8, lines: [3][]const u8 }{
    .{ .title = "Travel", .lines = .{ "An inn restores health and rune charges.", "Rest before leaving a town for a long trip.", "Use a floating orb to record your progress." } },
    .{ .title = "Formation", .lines = .{ "Short weapons need a place in the front row.", "Long weapons can attack from the back row.", "Check each weapon's range before moving a fighter." } },
    .{ .title = "Runes", .lines = .{ "A Rune Master can attach or remove many runes.", "Spell charges belong to individual spell levels.", "Check which charges remain before a long fight." } },
    .{ .title = "Equipment", .lines = .{ "A blacksmith can sharpen the weapon you carry.", "Each shop has a limit on how far it can sharpen.", "Use the equipment menu to wear purchased gear." } },
    .{ .title = "Supplies", .lines = .{ "Deposit spare supplies in the castle's storage.", "Withdraw them before setting out again.", "An appraiser can identify an unfamiliar urn." } },
    .{ .title = "Dueling", .lines = .{ "Attack beats Defend.", "Defend counters a Wild Attack.", "Wild Attack beats Attack." } },
    .{ .title = "Headquarters", .lines = .{ "The castle tablet records the people you recruit.", "Open a listed entry to inspect it.", "Visit again after finding new allies." } },
    .{ .title = "Returning", .lines = .{ "Use the Blinking Mirror outdoors on the world map.", "It brings the party back to headquarters.", "Talk to Viki to set out for another destination." } },
};

pub fn draw(menu: pause.State, game: field.State, room: field.Room, shared_items: []const ?[]const u8, context: *const ui.Context) void {
    rl.clearBackground(.{ .r = 3, .g = 8, .b = 34, .a = 255 });
    if (menu.phase == .jukebox) {
        const catalogue = menu.region_bgm.?;
        context.window(24, 26, 464, 370);
        ui.text("Kasios's music player", 48, 48, 22, .gold);
        for (catalogue.jukebox, 0..) |id, index| {
            const x: i32 = 48 + 220 * @as(i32, @intCast(index / 8));
            const y: i32 = 99 + 25 * @as(i32, @intCast(index % 8));
            const color: rl.Color = if (menu.jukebox_playing == index) .gold else .ray_white;
            if (menu.slot == index) ui.selection(x - 4, y - 3, 206, 24);
            if (catalogue.trackById(id).?.title) |title| ui.text(title, x, y, 15, color) else ui.numberText("Track {d}", .{index + 1}, x, y, 15, color);
        }
        if (menu.jukebox_failed) ui.text("This track could not be played.", 48, 310, 15, .gold);
        ui.text("Arrows: browse   Confirm: play or stop   Cancel: return", 48, 350, 14, .light_gray);
        return;
    }
    if (menu.phase == .sound_theme) {
        const Theme = field.game_state.event_runtime.SoundTheme;
        const story = game.progress.story.scenario orelse return;
        const names = [_][]const u8{ "Standard", "Chime", "Reed", "Pulse", "Pluck" };
        context.window(40, 32, 432, 352);
        ui.text("Sound themes", 66, 58, 22, .gold);
        var y: i32 = 112;
        for (names, 0..) |name, index| {
            const theme: Theme = @fromBackingInt(@intCast(index));
            if (!story.hasSoundTheme(theme)) continue;
            if (menu.sound_theme_cursor == theme) ui.selection(62, y - 3, 386, 28);
            ui.text(name, 76, y, 17, .ray_white);
            if (story.sound_theme == theme) ui.text("Selected", 330, y, 16, .gold);
            y += 34;
        }
        if (y == 146) ui.text("Bring a Sound Set to unlock another theme.", 66, 182, 14, .light_gray);
        ui.text("Arrows: browse   Confirm: apply and hear", 66, 306, 14, .light_gray);
        ui.text("Cancel: return", 66, 334, 14, .light_gray);
        return;
    }
    if (menu.phase == .window_style or menu.phase == .window_color) {
        const names = [_][]const u8{ "Classic", "Rounded", "Double", "Corners", "Inset" };
        const colors = [_][]const u8{ "Blue", "Slate", "Forest", "Teal", "Plum", "Burgundy", "Bronze", "Graphite" };
        const appearance = context.appearance;
        context.window(24, 24, 464, 376);
        ui.text("Window appearance", 48, 48, 22, .gold);
        context.window(70, 114, 372, 142);
        ui.numberText("Style    {s}", .{names[@backingInt(appearance.style)]}, 94, 150, 17, if (menu.phase == .window_style) .gold else .ray_white);
        ui.numberText("Color    {s}", .{colors[@backingInt(appearance.color)]}, 94, 196, 17, if (menu.phase == .window_color) .gold else .ray_white);
        ui.text(if (menu.phase == .window_style) "Arrows: change style   Confirm: choose color" else "Arrows: change color   Confirm: finish", 48, 323, 14, .light_gray);
        ui.text("Cancel: return", 48, 351, 14, .light_gray);
        return;
    }
    if (menu.phase == .library or menu.phase == .library_reading) {
        context.window(24, 22, 464, 378);
        if (menu.phase == .library_reading) {
            const page = library_pages[menu.slot];
            ui.numberText("Old Book Vol. {d}  /  {s}", .{ menu.slot + 1, page.title }, 48, 50, 22, .gold);
            for (page.lines, 0..) |line, index| ui.text(line, 48, 134 + 38 * @as(i32, @intCast(index)), 16, .ray_white);
            ui.text("Confirm or Cancel to close the book", 48, 351, 14, .light_gray);
        } else {
            ui.text("Library", 48, 50, 22, .gold);
            const books = if (game.progress.story.scenario) |story| story.library_books else 0;
            if (books == 0) {
                ui.text("There are no books on the shelf yet.", 48, 124, 16, .ray_white);
                ui.text("Cancel to return", 48, 351, 14, .light_gray);
            } else {
                for (0..library_pages.len) |index| {
                    if (books & (@as(u8, 1) << @as(u3, @intCast(index))) == 0) continue;
                    const y = 100 + 27 * @as(i32, @intCast(index));
                    if (menu.slot == index) ui.selection(44, y - 2, 414, 23);
                    ui.numberText("Old Book Vol. {d}  /  {s}", .{ index + 1, library_pages[index].title }, 48, y, 16, .ray_white);
                }
                ui.text("Up/Down: choose   Confirm: read   Cancel: return", 48, 351, 14, .light_gray);
            }
        }
        return;
    }
    if (menu.tablet_view) |*view| {
        const page = pause.tablet.source.page(view.cursor).?;
        const hero_name = for (game.progress.party) |member| {
            if (std.mem.eql(u8, member.id, "hero")) break member.name;
        } else "Hero";
        context.window(12, 12, 488, 408);
        ui.text("Stars of Destiny", 28, 28, 22, .gold);
        ui.numberText("{d} listed   Page {d}/{d}", .{ view.listedCount(), page.index + 1, pause.tablet.data.page_count }, 28, 57, 15, .ray_white);
        for (page.start..page.end + 1) |i| {
            const entry: u8 = @intCast(i);
            const x: i32 = 28 + 232 * @as(i32, entry % 2);
            const y: i32 = 94 + 26 * @as(i32, (entry - page.start) / 2);
            const listed = view.listed(entry);
            const record = pause.tablet.source.entry(entry).?;
            const name = if (!listed) "-" else if (pause.tablet.source.nameKind(record) == .player_named) hero_name else record.name;
            if (view.cursor == entry) ui.selection(x - 4, y - 3, 222, 23);
            ui.text(name, x, y, 16, if (listed) .ray_white else .gray);
        }
        if (view.lastReveal()) |reveal| {
            const record = pause.tablet.source.entry(reveal.entry).?;
            ui.text(if (pause.tablet.source.nameKind(record) == .player_named) hero_name else reveal.name, 28, 330, 18, .gold);
        }
        ui.text("Arrows: browse   Confirm: reveal   Cancel: return", 28, 381, 14, .light_gray);
        return;
    }
    frame(context, layout.top);
    ui.text("Suikoden", 22, 17, 18, .ray_white);
    ui.numberText("{d} bits", .{game.progress.money}, 366, 18, 16, .ray_white);
    frame(context, layout.commands);
    var visible_row: i32 = 0;
    for (pause.labels, 0..) |label, index| {
        const command: pause.Command = @fromBackingInt(@as(u4, @intCast(index)));
        if (menu.travel_context and !menu.isEnabled(command)) continue;
        if (menu.opening_context and (command == .storage or command == .appraisal)) continue;
        const y: i32 = 60 + visible_row * 26;
        visible_row += 1;
        if (command == menu.selected) ui.selection(14, y - 2, 130, 22);
        if (command == menu.selected) ui.selectedText(">", 18, y, 17, .ray_white);
        if (command == menu.selected) ui.selectedText(label, 38, y, 17, .ray_white) else ui.text(label, 38, y, 17, if (menu.isEnabled(command)) .ray_white else .{ .r = 110, .g = 125, .b = 160, .a = 255 });
    }
    for (0..6) |index| {
        const x: i32 = 158 + @as(i32, @intCast(index % 2)) * 174;
        const y: i32 = 48 + @as(i32, @intCast(index / 2)) * 104;
        frame(context, layout.party(index));
        if (index >= game.progress.party.len) continue;
        const member = game.progress.party[index];
        rl.beginScissorMode(x + 4, y + 4, 162, 90);
        ui.text(member.name, x + 10, y + 11, 17, .ray_white);
        ui.numberText("HP {d}/{d}", .{ member.hp, member.max_hp }, x + 10, y + 37, 15, .ray_white);
        rl.drawRectangle(x + 10, y + 61, 148, 5, .{ .r = 4, .g = 8, .b = 34, .a = 255 });
        rl.drawRectangle(x + 10, y + 61, @intCast(@as(u32, member.hp) * 148 / member.max_hp), 5, .green);
        if (member.balloons > 0) ui.numberText("{s} B{d}", .{ @tagName(member.status), member.balloons }, x + 10, y + 75, 12, .gold) else ui.text(@tagName(member.status), x + 10, y + 75, 12, if (member.status == .healthy) .light_gray else .gold);
        rl.endScissorMode();
    }
    frame(context, layout.room);
    ui.text(room.title, 170, 366, 14, .ray_white);
    ui.text("Up/Down: choose    Z/Enter: select    X/Esc: back", 16, 407, 12, .light_gray);
    switch (menu.phase) {
        .closed, .root, .tablet, .library, .library_reading, .window_style, .window_color, .sound_theme, .jukebox => {},
        .bathhouse, .bath => {
            frame(context, layout.detail);
            ui.text("Bathhouse", 174, 65, 22, .gold);
            if (menu.phase == .bathhouse) {
                ui.text("Take a bath?", 174, 135, 19, .ray_white);
                ui.text(if (menu.yes) "> Yes     No" else "  Yes   > No", 174, 185, 19, .gold);
            } else {
                ui.text("Steam rises from the warm water.", 174, 135, 17, .ray_white);
                ui.text("Confirm to leave", 174, 185, 16, .gold);
            }
        },
        .appraisal, .confirm_appraisal, .appraisal_notice => {
            frame(context, layout.detail);
            ui.text("Appraisal", 174, 65, 22, .gold);
            const inventory = game.progress.party[menu.member].inventory;
            ui.numberText("< {s} >", .{game.progress.party[menu.member].name}, 174, 100, 18, .sky_blue);
            for (inventory.slots, 0..) |slot, i| if (slot) |item| {
                ui.numberText("{s}{s}", .{ if (i == menu.slot) "> " else "  ", item.name() }, 168, 142 + @as(i32, @intCast(i)) * 23, 15, if (item.identified) .gray else .ray_white);
            };
            if (menu.phase == .confirm_appraisal) {
                const item = inventory.slots[menu.slot].?;
                var fee: u32 = 0;
                for (game.item_rules.?.appraisals) |record| if (record.id == item.id) {
                    fee = record.fee;
                };
                frame(context, layout.dialog);
                ui.numberText("Appraise this urn for {d} bits?", .{fee}, 80, 174, 18, .ray_white);
                ui.text(if (menu.yes) "> Yes    No" else "  Yes  > No", 100, 230, 20, .gold);
            } else if (menu.phase == .appraisal_notice) {
                frame(context, layout.notice);
                ui.text(menu.message, 48, 191, 17, .gold);
            }
        },
        .storage => {
            frame(context, layout.detail);
            ui.text("Storage", 174, 65, 22, .gold);
            for ([_][]const u8{ "Deposit", "Withdraw", "End" }, 0..) |label, i| ui.numberText("{s}{s}", .{ if (menu.service_action == i) "> " else "  ", label }, 174, 130 + @as(i32, @intCast(i)) * 48, 20, .ray_white);
            ui.text("254 bundles per item type.", 174, 304, 15, .sky_blue);
            ui.text("Supplies withdraw at full uses.", 174, 330, 15, .light_gray);
        },
        .storage_items, .confirm_storage, .storage_notice => {
            frame(context, layout.detail);
            ui.text(if (menu.storage_withdraw) "Withdraw" else "Deposit", 174, 65, 22, .gold);
            ui.numberText("< {s} >", .{game.progress.party[menu.member].name}, 174, 103, 18, .sky_blue);
            const count = if (menu.storage_withdraw) game.progress.storage.count() else game.progress.party[menu.member].inventory.count();
            const start = menu.slot -| 7;
            if (count == 0) ui.text("No items.", 174, 153, 18, .light_gray);
            for (start..@min(count, start + 9)) |i| {
                const item = if (menu.storage_withdraw) game.progress.storage.itemAt(i).? else game.progress.party[menu.member].inventory.slots[i].?.id;
                ui.numberText("{s}{s}  x{d}", .{ if (i == menu.slot) "> " else "  ", if (menu.storage_withdraw) item.name() else game.progress.party[menu.member].inventory.slots[i].?.name(), game.progress.storage.quantity(item) }, 168, 142 + @as(i32, @intCast(i - start)) * 23, 14, .ray_white);
            }
            if (menu.phase == .confirm_storage) {
                frame(context, layout.dialog);
                ui.numberText("{s} {s}?", .{ if (menu.storage_withdraw) "Withdraw" else "Deposit", menu.storage_id.?.name() }, 80, 172, 17, .ray_white);
                ui.text(if (menu.yes) "> Yes    No" else "  Yes  > No", 100, 230, 20, .gold);
            } else if (menu.phase == .storage_notice) {
                ui.window(24, 166, 464, 116);
                ui.text(menu.message, 38, 191, 16, .gold);
            }
        },
        .save_slots, .load_slots => {
            frame(context, layout.detail);
            ui.text(if (menu.phase == .save_slots) "Save slot" else "Load slot", 174, 64, 21, .gold);
            for (menu.summaries, 0..) |entry, i| {
                const y: i32 = 102 + @as(i32, @intCast(i)) * 82;
                ui.numberText("{s}{d}: {s}", .{ if (menu.save_slot == i) "> " else "  ", i + 1, entry.name.text() }, 170, y, 15, if (entry.status == .future) .gray else .ray_white);
                if (entry.status == .ready or entry.status == .backup) {
                    ui.text(entry.scene, 190, y + 21, 13, .sky_blue);
                    ui.numberText("{s} Lv{d}  {d}:{d:0>2}", .{ entry.leader, entry.level, @min(9999, entry.seconds / 3600), entry.seconds / 60 % 60 }, 190, y + 39, 12, .ray_white);
                    if (entry.status == .backup) ui.text("Recovery copy", 190, y + 55, 11, .gold);
                } else ui.text(switch (entry.status) {
                    .empty => "Empty",
                    .damaged => "Damaged",
                    .future => "Newer save format",
                    else => unreachable,
                }, 190, y + 25, 13, .light_gray);
            }
            ui.text("Choose a slot. X/Esc: return", 174, 361, 14, .light_gray);
        },
        .name_save => {
            ui.window(64, 112, 384, 190);
            ui.text("Name this save", 82, 130, 22, .gold);
            ui.text(menu.save_label.text(), 82, 174, 17, .ray_white);
            ui.text("Type / Backspace, or keep the name.", 82, 215, 14, .sky_blue);
            ui.text("Enter/Confirm: continue   Esc/Cancel: return", 82, 258, 14, .light_gray);
        },
        .setup => {
            frame(context, layout.detail);
            ui.text("Setup", 174, 65, 22, .gold);
            const names = [_][]const u8{ "Music", "Sound effects", "Display", "VSync" };
            for (names, 0..) |label, i| {
                const y: i32 = 116 + @as(i32, @intCast(i)) * 46;
                ui.numberText("{s}{s}", .{ if (menu.setup_row == i) "> " else "  ", label }, 174, y, 18, .ray_white);
                if (i < 2) ui.numberText("{d}%", .{@as(u16, if (i == 0) menu.preferences.music else menu.preferences.effects) * 10}, 388, y, 18, .sky_blue) else ui.text(if (i == 2) (if (menu.preferences.fullscreen) "Full screen" else "Windowed") else (if (menu.preferences.vsync) "On" else "Off"), 366, y, 16, .sky_blue);
            }
            ui.text("Left / right: change", 174, 324, 16, .ray_white);
            ui.text("Changes save separately from your journey.", 174, 350, 12, .light_gray);
        },
        .formation, .formation_target => {
            const combat = menu.combat.?;
            frame(context, layout.list);
            ui.text("Formation", 174, 64, 22, .gold);
            ui.text(if (menu.phase == .formation) "Choose a position to swap." else "Choose its new position.", 174, 98, 15, .ray_white);
            for (0..game.progress.party.len) |slot| {
                const member = combat.formation[slot];
                ui.numberText("{s}{d} {s}  {s}", .{ if ((if (menu.phase == .formation) menu.member else menu.target) == slot) "> " else "  ", slot + 1, if (slot < 3) "Front" else "Back", combat.name(member) }, 174, 134 + @as(i32, @intCast(slot)) * 27, 18, if (menu.phase == .formation_target and slot == menu.member) .sky_blue else .ray_white);
            }
            ui.text("Up/Down: position   Enter: select", 174, 318, 14, .light_gray);
        },
        .equipment, .equipment_items => {
            const combat = menu.combat.?;
            const rules = combat.content.systems.?;
            frame(context, layout.detail_344);
            ui.numberText("Equipment: {s}", .{combat.name(menu.member)}, 174, 64, 20, .gold);
            const names = [_][]const u8{ "Head", "Body", "Shield", "Accessory 1", "Accessory 2" };
            if (menu.phase == .equipment) {
                for (std.enums.values(@TypeOf(menu.equipment_slot)), 0..) |slot, i| {
                    const current = combat.loadouts[menu.member].get(slot);
                    ui.numberText("{s}{s}: {s}", .{ if (slot == menu.equipment_slot) "> " else "  ", names[i], if (current) |id| rules.equipment[id].name else "None" }, 174, 110 + @as(i32, @intCast(i)) * 31, 16, .ray_white);
                }
                ui.text("Left/Right: member   Up/Down: slot", 174, 303, 14, .light_gray);
                ui.text("Z: select slot   X: back", 174, 331, 14, .light_gray);
            } else {
                ui.numberText("{s} - choose carried item", .{names[@backingInt(menu.equipment_slot)]}, 174, 99, 16, .gold);
                const inventory = game.progress.party[menu.member].inventory;
                const start = menu.slot -| 5;
                for (start..@min(start + 6, inventory.count() + 1)) |index| {
                    const gear = if (index == 0) null else combat.gearIndex(inventory.slots[index - 1].?.id);
                    const enabled = if (index == 0) true else if (gear != null) available: {
                        combat.checkEquipment(menu.member, menu.equipment_slot, gear) catch break :available false;
                        break :available true;
                    } else false;
                    ui.numberText("{s}{s}", .{ if (index == menu.slot) "> " else "  ", if (index == 0) "Remove" else inventory.slots[index - 1].?.name() }, 174, 133 + @as(i32, @intCast(index - start)) * 23, 16, if (enabled) .ray_white else .gray);
                }
                const selected = if (menu.slot == 0) null else combat.gearIndex(inventory.slots[menu.slot - 1].?.id);
                var preview = combat.*;
                const available = if (menu.slot == 0 or selected != null) checked: {
                    combat.checkEquipment(menu.member, menu.equipment_slot, selected) catch break :checked false;
                    break :checked true;
                } else false;
                if (available) preview.loadouts[menu.member].set(menu.equipment_slot, selected);
                const current = combat.stats(menu.member);
                const next = preview.stats(menu.member);
                ui.numberText("ATK {d} -> {d}   DEF {d} -> {d}", .{ current.attack, next.attack, current.defense, next.defense }, 174, 290, 15, .sky_blue);
                ui.numberText("MGC {d} -> {d}   SPD {d} -> {d}", .{ current.magic, next.magic, current.speed, next.speed }, 174, 315, 15, .sky_blue);
                ui.text("Z: equip/remove   X: back", 174, 350, 14, .light_gray);
            }
        },
        .rune, .rune_target => {
            const combat = menu.combat.?;
            frame(context, layout.detail_344);
            ui.numberText("Rune: {s}", .{combat.name(menu.member)}, 174, 64, 20, .gold);
            if (combat.rune(menu.member)) |rune| {
                ui.numberText("{s}  MGC {d}", .{ rune.name, combat.stats(menu.member).magic }, 174, 99, 17, .sky_blue);
                for (rune.spell_names, rune.spells, 0..) |name, spell, i| {
                    const usable = spell != null and combat.content.systems.?.spells[spell.?].allies and combat.content.systems.?.spells[spell.?].field_use and combat.canCast(menu.member, spell.?);
                    ui.numberText("{s}{s}", .{ if (menu.slot == i) "> " else "  ", name }, 174, 140 + @as(i32, @intCast(i)) * 35, 16, if (usable) .ray_white else .gray);
                    ui.numberText("{d}/{d}", .{ game.progress.party[menu.member].rune_charges[i], game.progress.party[menu.member].max_rune_charges[i] }, 427, 140 + @as(i32, @intCast(i)) * 35, 14, .sky_blue);
                }
                ui.text("Dimmed: battle-only/unavailable spells.", 174, 310, 12, .light_gray);
                ui.text(combat.runeHint(menu.member), 174, 329, 12, .sky_blue);
            } else ui.text("No rune equipped.", 174, 128, 18, .ray_white);
            if (!menu.travel_context) ui.numberText("{s}Manage: attach / remove", .{if (menu.slot == 4) "> " else "  "}, 174, 282, 16, .gold);
            ui.text("Left/Right: member   Enter: use", 174, 353, 14, .light_gray);
            if (menu.phase == .rune_target) {
                ui.window(158, 92, 344, 254);
                const spell = combat.content.systems.?.spells[combat.rune(menu.member).?.spells[menu.slot].?];
                ui.text(if (spell.group) "All allies" else "Rune target", 174, 108, 20, .gold);
                for (game.progress.party, 0..) |member, i| ui.numberText("{s}{s}  HP {d}/{d}", .{ if (spell.group or menu.target == i) "> " else "  ", member.name, member.hp, member.max_hp }, 174, 144 + @as(i32, @intCast(i)) * 29, 16, .ray_white);
            }
        },
        .strength => {
            const member = game.progress.party[@min(menu.member, game.progress.party.len - 1)];
            frame(context, layout.item_panel);
            ui.text("Strength", 178, 64, 18, .ray_white);
            ui.text(member.name, 178, 100, 22, .gold);
            ui.numberText("HP  {d} / {d}", .{ member.hp, member.max_hp }, 178, 138, 18, .ray_white);
            ui.text(@tagName(member.status), 178, 167, 16, .ray_white);
            if (menu.combat) |combat| {
                if (menu.strength_details) {
                    const labels = [_][]const u8{ "Head", "Body", "Shield", "Accessory 1", "Accessory 2" };
                    for (std.enums.values(@TypeOf(menu.equipment_slot)), 0..) |slot, i| {
                        const item = combat.loadouts[menu.member].get(slot);
                        ui.numberText("{s}: {s}", .{ labels[i], if (item) |id| combat.content.systems.?.equipment[id].name else "None" }, 178, 195 + @as(i32, @intCast(i)) * 22, 15, .ray_white);
                    }
                    ui.numberText("Rune: {s}", .{if (combat.rune(menu.member)) |rune| rune.name else "None"}, 178, 309, 15, .sky_blue);
                } else {
                    const stats = combat.stats(menu.member);
                    ui.numberText("Level {d}    EXP {d}/1000", .{ combat.levels[menu.member], combat.experience[menu.member] }, 178, 195, 16, .sky_blue);
                    ui.numberText("ATK {d}  DEF {d}  SKL {d}", .{ stats.attack, stats.defense, stats.skill }, 178, 222, 16, .ray_white);
                    ui.numberText("SPD {d}  MGC {d}  LUK {d}", .{ stats.speed, stats.magic, stats.luck }, 178, 248, 16, .ray_white);
                    ui.numberText("{s} row  /  {s} reach", .{ combat.partyRow(menu.member).label(), combat.weaponRange(menu.member).label() }, 178, 276, 15, .ray_white);
                    ui.numberText("{s} LV {d}", .{ combat.weaponName(menu.member), combat.weapon_levels[menu.member] }, 178, 303, 15, .gold);
                    if (combat.levels[menu.member] == 99) ui.text("Maximum level", 178, 329, 14, .light_gray) else ui.numberText("Next level: {d} EXP", .{1000 - combat.experience[menu.member]}, 178, 329, 14, .sky_blue);
                }
            } else {
                ui.text("Rune charges", 178, 204, 16, .ray_white);
                for (member.rune_charges, member.max_rune_charges, 0..) |current, maximum, index| ui.numberText("{d}: {d}/{d}", .{ index + 1, current, maximum }, 178 + @as(i32, @intCast(index % 2)) * 148, 234 + @as(i32, @intCast(index / 2)) * 27, 16, .ray_white);
                if (!menu.opening_context) ui.text(if (game.progress.story.village_south_exit_reached) "Village south exit: reached" else "Village south exit: not reached", 178, 294, 12, .ray_white);
            }
            ui.text(if (menu.combat != null) "Up/Down: details  Left/Right: member" else "Left/Right: member    X: back", 178, 355, 12, .light_gray);
        },
        .rune_service, .rune_attach, .confirm_rune_attach, .confirm_rune_remove => {
            const combat = menu.combat.?;
            frame(context, layout.wide);
            ui.text(if (menu.rune_from_menu) "Rune management" else "Rune master", 48, 72, 22, .gold);
            if (menu.phase == .rune_service) {
                ui.numberText("{s}: {s}", .{ combat.name(menu.member), if (combat.rune(menu.member)) |rune| rune.name else "No rune" }, 48, 121, 18, .ray_white);
                if (combat.partyProfile(menu.member).rune_locked) ui.text("Fixed rune", 48, 150, 15, .gold);
                for ([_][]const u8{ "Attach crystal", "Remove rune", "End" }, 0..) |label, index| ui.numberText("{s}{s}", .{ if (menu.service_action == index) "> " else "  ", label }, 48, 190 + @as(i32, @intCast(index)) * 32, 18, .ray_white);
                ui.text("Prototype service: no fee.", 48, 304, 14, .sky_blue);
                ui.text("Left/Right: member   Z: choose   X: leave", 48, 334, 14, .light_gray);
            } else if (menu.phase == .rune_attach) {
                ui.numberText("Attach to {s}", .{combat.name(menu.target)}, 48, 113, 19, .gold);
                const inventory = game.progress.party[menu.member].inventory;
                ui.numberText("Crystals carried by {s}", .{combat.name(menu.member)}, 48, 144, 16, .ray_white);
                const start = menu.slot -| 5;
                if (inventory.count() == 0) ui.text("No items", 48, 185, 17, .light_gray);
                for (start..@min(start + 6, inventory.count())) |index| {
                    const usable = valid: {
                        _ = combat.checkRuneAttachment(menu.target, menu.member, index) catch break :valid false;
                        break :valid true;
                    };
                    ui.numberText("{s}{s}", .{ if (menu.slot == index) "> " else "  ", inventory.slots[index].?.name() }, 48, 180 + @as(i32, @intCast(index - start)) * 22, 16, if (usable) .ray_white else .gray);
                }
                ui.text("Left/Right: bag   Up/Down: item   Z: select", 48, 334, 14, .light_gray);
            } else {
                ui.numberText("{s} {s}'s rune?", .{ if (menu.phase == .confirm_rune_remove) "Remove" else "Change", combat.name(menu.target) }, 48, 131, 19, .ray_white);
                if (menu.phase == .confirm_rune_attach) ui.text(game.progress.party[menu.member].inventory.slots[menu.slot].?.name(), 48, 180, 18, .gold);
                ui.text("No service fee.", 48, 228, 16, .light_gray);
                ui.text(if (menu.yes) "> Yes     No" else "  Yes   > No", 48, 288, 20, .ray_white);
            }
        },
        .blacksmith, .confirm_blacksmith => {
            const combat = menu.combat.?;
            const level = combat.weapon_levels[menu.member];
            frame(context, layout.wide);
            ui.numberText("Blacksmith - up to level {d}", .{menu.service_limit}, 48, 72, 21, .gold);
            ui.numberText("{s}: {s}", .{ combat.name(menu.member), combat.weaponName(menu.member) }, 48, 120, 20, .ray_white);
            ui.numberText("Weapon level {d}   ATK {d}", .{ level, combat.stats(menu.member).attack }, 48, 163, 18, .ray_white);
            if (combat.sharpenPrice(menu.member, menu.service_limit)) |price| {
                var preview = combat.*;
                preview.weapon_levels[menu.member] += 1;
                const next = preview.stats(menu.member).attack;
                ui.numberText("Level {d} -> {d}   ATK {d} -> {d}", .{ level, level + 1, combat.stats(menu.member).attack, next }, 48, 211, 18, .sky_blue);
                ui.numberText("Price: {d} bits", .{price}, 48, 245, 18, .ray_white);
                if (menu.phase == .confirm_blacksmith) ui.text(if (menu.yes) "> Yes     No" else "  Yes   > No", 48, 294, 20, .ray_white);
            } else |_| ui.text("I cannot sharpen this weapon further.", 48, 211, 17, .light_gray);
            if (menu.phase == .blacksmith) ui.text("Left/Right: member   Z: sharpen   X: leave", 48, 330, 14, .light_gray);
        },
        .shop, .buy_member, .confirm_buy => {
            frame(context, layout.full);
            ui.text("Item Shop", 24, 64, 22, .gold);
            if (menu.phase == .shop) {
                for ([_][]const u8{ "Buy", "Sell", "End" }, 0..) |label, index| ui.numberText("{s}{s}", .{ if (menu.shop_choice == index) "> " else "  ", label }, 28, 112 + @as(i32, @intCast(index)) * 36, 20, .ray_white);
                ui.text("Supplies and rune crystals available.", 28, 246, 17, .ray_white);
                ui.text("Nine inventory slots per member.", 28, 276, 15, .light_gray);
                ui.text("Z: choose    X: back", 28, 344, 14, .light_gray);
            } else {
                const member = game.progress.party[menu.member];
                const rules = game.item_rules.?;
                const stock = menu.shopStock(rules);
                const stock_start = menu.stock_slot -| 2;
                for (stock_start..@min(stock_start + 3, stock.len)) |index| {
                    const id = stock[index];
                    const item = rules.offerGood(id).?;
                    if (item.uses > 0) ui.numberText("{s}{s}  {d} bits / {d} uses", .{ if (index == menu.stock_slot) "> " else "  ", item.name, item.price, item.uses }, 28, 110 + @as(i32, @intCast(index - stock_start)) * 27, 17, .ray_white) else ui.numberText("{s}{s}  {d} bits", .{ if (index == menu.stock_slot) "> " else "  ", item.name, item.price }, 28, 110 + @as(i32, @intCast(index - stock_start)) * 27, 17, .ray_white);
                }
                ui.text(member.name, 28, 204, 20, .gold);
                ui.numberText("Inventory {d}/9", .{member.inventory.count()}, 28, 234, 17, .ray_white);
                if (menu.phase == .confirm_buy) {
                    ui.numberText("Buy {s} for this member?", .{stock[menu.stock_slot].name()}, 28, 269, 17, .ray_white);
                    ui.text(if (menu.yes) "> Yes     No" else "  Yes   > No", 40, 311, 20, .ray_white);
                } else ui.text("Up/Down: item   Left/Right: member   Z: buy", 28, 307, 14, .light_gray);
            }
        },
        .shared_items => {
            frame(context, layout.detail_344);
            ui.text("Shared items", 174, 64, 18, .gold);
            for (shared_items, 0..) |slot, index| {
                const name = slot orelse break;
                ui.text(name, 190, 102 + @as(i32, @intCast(index)) * 25, 15, .ray_white);
            }
            ui.text("Left/Right  Switch inventory", 174, 351, 14, .light_gray);
        },
        .items, .item_action, .item_target, .item_transfer, .confirm_discard, .confirm_weapon_piece, .sell_items, .confirm_sell => {
            frame(context, layout.detail_344);
            const member = game.progress.party[menu.member];
            ui.numberText("{s}    {d}/9", .{ member.name, member.inventory.count() }, 174, 64, 18, .gold);
            if (member.inventory.count() == 0) ui.text("No items", 180, 110, 18, .light_gray);
            for (member.inventory.slots, 0..) |slot, index| {
                const item = slot orelse break;
                const y = 102 + @as(i32, @intCast(index)) * 25;
                if (index == menu.slot) ui.text(">", 170, y, 17, .ray_white);
                if (item.uses > 0) ui.numberText("{s}  {d} uses", .{ item.name(), item.uses }, 190, y, 15, .ray_white) else ui.text(item.name(), 190, y, 15, .ray_white);
            }
            ui.text(if (menu.phase == .items and shared_items.len != 0 and shared_items[0] != null)
                "Left/Right  Member or shared items"
            else if (menu.phase == .sell_items or menu.phase == .confirm_sell)
                "Left/Right: member    Z: sell"
            else if (menu.combat == null)
                "Left/Right: member    Z: use"
            else
                "Left/Right: member    Z: item actions", 174, 351, 14, .light_gray);
            if (menu.phase == .sell_items and member.inventory.count() > 0) {
                const price = (if (menu.shop_allow_equipment) game.progress.shopSalePrice(game.item_rules.?, menu.member, menu.slot) else game.progress.salePrice(game.item_rules.?, menu.member, menu.slot)) catch 0;
                if (price > 0) ui.numberText("Offer: {d} bits for this bundle", .{price}, 174, 323, 15, .gold) else ui.text("This item cannot be sold here.", 174, 323, 15, .light_gray);
            }
            if (menu.phase == .confirm_sell) {
                ui.window(158, 122, 344, 180);
                ui.text("Sell this item bundle?", 174, 140, 19, .gold);
                ui.text(member.inventory.slots[menu.slot].?.name(), 174, 178, 17, .ray_white);
                const price = (if (menu.shop_allow_equipment) game.progress.shopSalePrice(game.item_rules.?, menu.member, menu.slot) else game.progress.salePrice(game.item_rules.?, menu.member, menu.slot)) catch 0;
                ui.numberText("{d} bits   {s}", .{ price, if (menu.yes) "> Yes     No" else "  Yes   > No" }, 174, 237, 18, .ray_white);
            }
            if (menu.phase == .item_action) {
                ui.window(158, 92, 344, 254);
                ui.text(member.inventory.slots[menu.slot].?.name(), 174, 108, 20, .gold);
                for ([_][]const u8{ "Use", "Give", "Discard" }, 0..) |label, index| ui.numberText("{s}{s}", .{ if (menu.item_action == index) "> " else "  ", label }, 174, 156 + @as(i32, @intCast(index)) * 34, 18, .ray_white);
            }
            if (menu.phase == .confirm_discard) {
                ui.window(158, 122, 344, 180);
                ui.text("Discard this item?", 174, 140, 19, .gold);
                ui.text(member.inventory.slots[menu.slot].?.name(), 174, 178, 17, .ray_white);
                ui.text(if (menu.yes) "> Yes     No" else "  Yes   > No", 174, 237, 20, .ray_white);
            }
            if (menu.phase == .confirm_weapon_piece) {
                ui.window(158, 122, 344, 180);
                ui.text("Replace this weapon's rune?", 174, 140, 19, .gold);
                ui.text("Existing pieces will be lost.", 174, 178, 17, .ray_white);
                ui.text(if (menu.yes) "> Yes     No" else "  Yes   > No", 174, 237, 20, .ray_white);
            }
            if (menu.phase == .item_target or menu.phase == .item_transfer) {
                ui.window(158, 92, 344, 254);
                if (menu.phase == .item_transfer) ui.text("Give item to:", 174, 108, 19, .gold) else ui.numberText("Use {s} on:", .{member.inventory.slots[menu.slot].?.name()}, 174, 108, 19, .gold);
                for (game.progress.party, 0..) |target, index| {
                    const y = 144 + @as(i32, @intCast(index)) * 29;
                    if (index == menu.target) ui.text(">", 170, y, 17, .ray_white);
                    ui.numberText("{s}  HP {d}/{d}", .{ target.name, target.hp, target.max_hp }, 190, y, 16, .ray_white);
                }
            }
        },
        .confirm_new_game => {
            frame(context, layout.new_game);
            ui.text("Start a New Game?", 96, 146, 18, .gold);
            ui.text("Route, story, roster, inventory and money reset.", 96, 178, 14, .light_gray);
            ui.text("Save slots are kept.", 96, 199, 14, .light_gray);
            ui.text(if (menu.yes) "> Yes" else "  Yes", 110, 241, 18, .ray_white);
            ui.text(if (!menu.yes) "> No" else "  No", 110, 271, 18, .ray_white);
        },
        .confirm_save, .confirm_load => {
            frame(context, layout.confirm);
            ui.numberText("{s} progress {s} Slot {d}?", .{ if (menu.phase == .confirm_save) "Save" else "Load", if (menu.phase == .confirm_save) "to" else "from", if (menu.combat != null or menu.opening_context) menu.save_slot + 1 else 1 }, 96, 154, 17, .ray_white);
            ui.text(if (menu.phase == .confirm_save) "The existing save will be replaced." else "Unsaved progress will be replaced.", 96, 187, 14, .light_gray);
            ui.text(if (menu.yes) "> Yes" else "  Yes", 110, 231, 18, .ray_white);
            ui.text(if (!menu.yes) "> No" else "  No", 110, 261, 18, .ray_white);
        },
        .notice, .item_notice, .shop_notice, .character_notice => {
            ui.window(56, 150, 400, 130);
            ui.text(menu.message, 74, 174, 17, .ray_white);
            ui.text("Z/Enter: continue", 74, 249, 12, .light_gray);
        },
    }
}
