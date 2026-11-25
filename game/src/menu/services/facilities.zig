//! Castle facilities: bathhouse, tablet, library, window styles/colors, sound themes, and jukebox.
const field = @import("field");
const pause = @import("../../pause_menu.zig");
const nav = @import("../navigation.zig");

const WindowAppearance = field.game_state.event_runtime.WindowAppearance;
const SoundTheme = field.game_state.event_runtime.SoundTheme;

pub fn handle(state: *pause.State, game: *field.State, input: pause.Input) void {
    switch (state.phase) {
        .bathhouse => {
            if (input.left != input.right) state.yes = input.left;
            if (input.field.menu_direction == .up or input.field.menu_direction == .down) state.yes = !state.yes;
            if (input.field.action) state.phase = if (state.yes) .bath else nav.leaveFacility(state);
        },
        .bath => if (input.field.action) {
            state.phase = nav.leaveFacility(state);
        },
        .tablet => if (state.tablet_view) |*view| {
            const intent: pause.tablet.Intent = if (input.field.action) .confirm else if (input.left) .left else if (input.right) .right else switch (input.field.menu_direction orelse return) {
                .up => .up,
                .down => .down,
                else => return,
            };
            _ = view.apply(intent);
        },
        .library => {
            const books = if (game.progress.story.scenario) |story| story.library_books else 0;
            if (books == 0) return;
            const step: usize = switch (input.field.menu_direction orelse .left) {
                .up => 7,
                .down => 1,
                else => 0,
            };
            if (step != 0) {
                state.slot = (state.slot + step) % 8;
                while (books & (@as(u8, 1) << @as(u3, @intCast(state.slot))) == 0) state.slot = (state.slot + step) % 8;
            }
            if (input.field.action) state.phase = .library_reading;
        },
        .library_reading => if (input.field.action) {
            state.phase = .library;
        },
        .window_style => if (game.progress.story.scenario) |*story| {
            const step = nav.themeSelectionStep(input);
            if (step != 0) {
                var index: u8 = @backingInt(story.window_appearance.style);
                while (true) {
                    index = (index + step) % 5;
                    const style: WindowAppearance.Style = @fromBackingInt(@intCast(index));
                    if (!story.hasWindowStyle(style)) continue;
                    story.window_appearance.style = style;
                    break;
                }
            }
            if (input.field.action) state.phase = .window_color;
        },
        .window_color => if (game.progress.story.scenario) |*story| {
            const step: u8 = if (input.left or input.field.menu_direction == .left)
                7
            else if (input.right or input.field.menu_direction == .right)
                1
            else if (input.field.menu_direction == .up or input.field.menu_direction == .down)
                4
            else
                0;
            const index: u8 = @backingInt(story.window_appearance.color);
            story.window_appearance.color = @fromBackingInt(@intCast((index + step) % 8));
            if (input.field.action) state.phase = nav.leaveFacility(state);
        },
        .sound_theme => if (game.progress.story.scenario) |*story| {
            if (input.field.action and state.sound_theme_cursor != story.sound_theme) {
                story.sound_theme = state.sound_theme_cursor;
                state.pending_sound = 0x504;
                return;
            }
            const step = nav.themeSelectionStep(input);
            if (step != 0) {
                var index: u8 = @backingInt(state.sound_theme_cursor);
                while (true) {
                    index = (index + step) % 5;
                    const theme: SoundTheme = @fromBackingInt(@intCast(index));
                    if (!story.hasSoundTheme(theme)) continue;
                    state.sound_theme_cursor = theme;
                    state.pending_sound = 0x502;
                    break;
                }
            }
        },
        .jukebox => {
            const count = state.region_bgm.?.jukebox.len;
            const step: usize = if (input.left or input.right or input.field.menu_direction == .left or input.field.menu_direction == .right)
                count / 2
            else if (input.field.menu_direction == .up)
                count - 1
            else if (input.field.menu_direction == .down)
                1
            else
                0;
            state.slot = (state.slot + step) % count;
            if (input.field.action) {
                state.jukebox_failed = false;
                state.jukebox_playing = if (state.jukebox_playing == state.slot) null else state.slot;
            }
        },
        else => unreachable,
    }
}
