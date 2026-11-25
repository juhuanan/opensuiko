//! Pending field service and NPC service/shop dialogue admission when the menu is closed.
const std = @import("std");
const field = @import("field");
const pause = @import("../../pause_menu.zig");
const nav = @import("../navigation.zig");

pub fn openPendingOrDialogue(state: *pause.State, package: field.Package, game: *field.State, input: pause.Input) ?pause.Effect {
    if (game.pending_service) |service| {
        game.pending_service = null;
        nav.resetTransientServiceFlags(state);
        state.field_facility = null;
        state.pending = false;
        game.walking = false;
        game.animation_ticks = 0;
        game.action_pending = false;
        switch (service.kind) {
            .shop => {
                if (game.item_rules == null) {
                    state.notify("This shop is unavailable in this build.");
                    return .none;
                }
                if (service.shop_items) |names| {
                    state.shop_allow_equipment = true;
                    for (names) |name| {
                        const id = std.meta.stringToEnum(field.items.Id, name) orelse continue;
                        if (state.shop_stock_len < state.shop_stock_buf.len and game.item_rules.?.offerGood(id) != null) {
                            state.shop_stock_buf[state.shop_stock_len] = id;
                            state.shop_stock_len += 1;
                        }
                    }
                }
                state.phase = .shop;
                state.member = 0;
                state.shop_choice = 0;
                state.stock_slot = 0;
                return .none;
            },
            .blacksmith => {
                if (state.combat == null) {
                    state.notify("This service is unavailable in this build.");
                    return .none;
                }
                state.service_limit = service.id;
                state.phase = .blacksmith;
                state.service_action = 0;
                state.member = 0;
                return .none;
            },
            .rune_master => {
                if (state.combat == null) {
                    state.notify("This service is unavailable in this build.");
                    return .none;
                }
                state.rune_from_menu = false;
                state.phase = .rune_service;
                state.service_action = 0;
                state.member = 0;
                return .none;
            },
            .appraisal => {
                if (game.item_rules == null) {
                    state.notify("This service is unavailable in this build.");
                    return .none;
                }
                state.appraisal_from_service = true;
                state.phase = .appraisal;
                state.member = 0;
                state.slot = 0;
                return .none;
            },
            .save_point => {
                state.field_facility = .save_point;
                state.phase = .save_slots;
                state.yes = false;
                return .inspect_saves;
            },
            .storage => {
                if (state.combat == null) {
                    state.notify("This service is unavailable in this build.");
                    return .none;
                }
                state.field_facility = .storage;
                state.phase = .storage;
                state.service_action = 0;
                state.member = 0;
                state.slot = 0;
                return .none;
            },
            .bathhouse => {
                state.field_facility = .bathhouse;
                state.phase = .bathhouse;
                state.yes = false;
                return .none;
            },
            .tablet => {
                if (game.progress.story.scenario) |*story| {
                    state.tablet_view = pause.tablet.loadView(story.recruit_flags);
                    state.field_facility = .tablet;
                    state.phase = .tablet;
                } else state.notify("The roster is unavailable.");
                return .none;
            },
            .library => {
                const books = if (game.progress.story.scenario) |story| story.library_books else 0;
                state.slot = if (books == 0) 0 else @ctz(books);
                state.field_facility = .library;
                state.phase = .library;
                return .none;
            },
            .window_styles => {
                state.field_facility = .window_styles;
                state.phase = .window_style;
                return .none;
            },
            .sound_themes => {
                state.sound_theme_cursor = if (game.progress.story.scenario) |story| story.sound_theme else .standard;
                state.field_facility = .sound_themes;
                state.phase = .sound_theme;
                return .none;
            },
            .music_player => {
                if (state.region_bgm == null or state.region_bgm.?.jukebox.len == 0) {
                    state.notify("No songs are available.");
                    return .none;
                }
                state.slot = 0;
                state.jukebox_failed = false;
                state.jukebox_playing = null;
                state.field_facility = .music_player;
                state.phase = .jukebox;
                return .none;
            },
            .cup_game, .card_game, .teleport => state.notify("This service is unavailable here."),
        }
    }
    if (game.dialogue != null and game.dialogue.?.phase == .service) {
        if (state.combat == null) {
            game.dialogue = null;
            state.notify("This service is unavailable in this build.");
            return .none;
        }
        const npc = package.rooms[game.room].npcs[game.dialogue.?.source.npc];
        state.service_limit = npc.weapon_limit;
        state.rune_from_menu = false;
        game.dialogue = null;
        if (input.field.cancel) return .none;
        state.phase = if (npc.service.? == .blacksmith) .blacksmith else .rune_service;
        state.service_action = 0;
        state.member = 0;
        return .none;
    }
    if (game.dialogue != null and game.dialogue.?.phase == .shop) {
        game.dialogue = null;
        if (input.field.cancel) return .none;
        nav.resetTransientServiceFlags(state);
        state.phase = .shop;
        state.member = 0;
        state.shop_choice = 0;
        state.stock_slot = 0;
        return .none;
    }
    return null;
}
