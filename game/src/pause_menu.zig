pub const title = @import("title.zig");
pub const content_path = @import("content_path.zig");
const field = @import("field");
const battle = @import("battle");
pub const tablet = @import("hq").tablet;

pub const controller = @import("controller.zig");
/// The controller module is shared with the platform recovery layer;
/// these aliases let that module name the existing types without owning a
/// second copy of the file.
pub const Output = controller.Output;
pub const save_slots = @import("save_slots.zig");
pub const settings = @import("settings.zig");
pub const Value = settings.Value;
const WindowAppearance = field.game_state.event_runtime.WindowAppearance;
const SoundTheme = field.game_state.event_runtime.SoundTheme;
const audio_route = @import("audio_route");

pub const Command = enum { item, strength, rune, formation, equipment, setup, storage, appraisal, save, load, new_game, back };
pub const labels = [_][]const u8{ "Item", "Strength", "Rune", "Formation", "Equipment", "Setup", "Storage", "Appraisal", "Save", "Load", "New Game", "Return" };
pub const Phase = enum { appraisal, confirm_appraisal, appraisal_notice, storage, storage_items, confirm_storage, storage_notice, closed, root, save_slots, load_slots, name_save, setup, strength, confirm_save, confirm_load, confirm_new_game, notice, items, item_action, item_transfer, confirm_discard, item_target, confirm_weapon_piece, item_notice, shop, blacksmith, confirm_blacksmith, rune_service, rune_attach, confirm_rune_attach, confirm_rune_remove, buy_member, confirm_buy, sell_items, confirm_sell, shop_notice, formation, formation_target, equipment, equipment_items, rune, rune_target, character_notice, shared_items, bathhouse, bath, tablet, library, library_reading, window_style, window_color, sound_theme, jukebox };
pub const Effect = enum { none, save, load, inspect_saves, settings_changed, party_give, party_discard, party_equip, weapon_piece, blinking_mirror, new_game };
pub const Input = struct { field: field.Input = .{}, menu: bool = false, left: bool = false, right: bool = false, text: []const u8 = "", erase: bool = false, party_transactions: bool = false, weapon_pieces: bool = false, has_shared_items: bool = false, travel_tools: bool = false };

fn themeSelectionStep(input: Input) u8 {
    if (input.left or input.field.menu_direction == .up or input.field.menu_direction == .left) return 4;
    if (input.right or input.field.menu_direction == .down or input.field.menu_direction == .right) return 1;
    return 0;
}

pub fn enabled(command: Command) bool {
    return switch (command) {
        .item, .strength, .setup, .save, .load, .new_game, .back => true,
        else => false,
    };
}

pub const State = struct {
    phase: Phase = .closed,
    opening_context: bool = false,
    travel_context: bool = false,
    live_world_context: bool = false,
    preferences: settings.Value = .{},
    setup_row: usize = 0,
    save_slot: usize = 0,
    save_label: save_slots.Label = save_slots.defaultLabel(0),
    summaries: [save_slots.count]save_slots.Summary = save_slots.emptySummaries(),
    combat: ?*battle.State = null,
    pending: bool = false,
    selected: Command = .strength,
    member: usize = 0,
    yes: bool = false,
    slot: usize = 0,
    target: usize = 0,
    shop_choice: usize = 0,
    service_limit: u8 = 16,
    service_action: usize = 0,
    rune_from_menu: bool = false,
    storage_withdraw: bool = false,
    storage_id: ?field.items.Id = null,
    strength_details: bool = false,
    stock_slot: usize = 0,
    shop_stock_buf: [8]field.items.Id = undefined,
    shop_stock_len: u8 = 0,
    shop_allow_equipment: bool = false,
    appraisal_from_service: bool = false,
    field_facility: ?field.game_state.event_runtime.FieldService = null,
    tablet_view: ?tablet.View = null,
    sound_theme_cursor: SoundTheme = .standard,
    pending_sound: ?u16 = null,
    region_bgm: ?audio_route.RegionBgmContent = null,
    jukebox_playing: ?usize = null,
    jukebox_failed: bool = false,
    item_action: usize = 0,
    weapon_piece_replace: bool = false,
    character_page: Phase = .equipment,
    equipment_slot: battle.systems.EquipmentSlot = .head,
    message: []const u8 = "",

    pub fn isEnabled(self: State, command: Command) bool {
        if (self.travel_context and (command == .storage or command == .appraisal or command == .back)) return false;
        if (self.travel_context and !self.live_world_context and (command == .save or command == .load)) return false;
        if (self.opening_context) return command == .strength or command == .setup or command == .save or command == .load or command == .new_game or command == .back;
        return enabled(command) or (self.combat != null and (command == .rune or command == .formation or command == .equipment or command == .storage or command == .appraisal));
    }

    pub fn shopStock(self: *const State, rules: field.items.Rules) []const field.items.Id {
        return if (self.shop_stock_len > 0) self.shop_stock_buf[0..self.shop_stock_len] else rules.stock;
    }

    pub fn jukeboxTrack(self: *const State) ?[]const u8 {
        if (self.phase != .jukebox) return null;
        const selected = self.jukebox_playing orelse return null;
        return self.region_bgm.?.jukebox[selected];
    }

    pub fn notify(self: *State, message: []const u8) void {
        self.phase = .notice;
        self.message = message;
    }

    fn leaveFacility(self: *State) Phase {
        const result: Phase = if (self.field_facility != null) .closed else .root;
        self.field_facility = null;
        self.tablet_view = null;
        self.jukebox_playing = null;
        return result;
    }

    pub fn tick(self: *State, package: field.Package, game: *field.State, input: Input) Effect {
        return self.tickWithArrival(package, game, input, .immediate);
    }

    pub fn finishPending(self: *State, game: *field.State) void {
        if (!self.pending) return;
        if (game.dialogue != null) {
            self.pending = false;
        } else if (game.remaining == 0) {
            self.pending = false;
            self.phase = .root;
            game.walking = false;
            game.animation_ticks = 0;
            game.action_pending = false;
        }
    }

    pub fn tickWithArrival(self: *State, package: field.Package, game: *field.State, input: Input, arrival: field.StepArrival) Effect {
        return self.tickWithArrivalAndGround(package, game, input, arrival, null);
    }

    pub fn tickWithArrivalAndGround(self: *State, package: field.Package, game: *field.State, input: Input, arrival: field.StepArrival, ground: ?field.Ground) Effect {
        if (self.phase == .closed) {
            if (game.pending_service) |service| {
                game.pending_service = null;
                self.shop_stock_len = 0;
                self.shop_allow_equipment = false;
                self.appraisal_from_service = false;
                self.field_facility = null;
                self.pending = false;
                game.walking = false;
                game.animation_ticks = 0;
                game.action_pending = false;
                switch (service.kind) {
                    .shop => {
                        if (game.item_rules == null) {
                            self.notify("This shop is unavailable in this build.");
                            return .none;
                        }
                        if (service.shop_items) |names| {
                            self.shop_allow_equipment = true;
                            for (names) |name| {
                                const id = @import("std").meta.stringToEnum(field.items.Id, name) orelse continue;
                                if (self.shop_stock_len < self.shop_stock_buf.len and game.item_rules.?.offerGood(id) != null) {
                                    self.shop_stock_buf[self.shop_stock_len] = id;
                                    self.shop_stock_len += 1;
                                }
                            }
                        }
                        self.phase = .shop;
                        self.member = 0;
                        self.shop_choice = 0;
                        self.stock_slot = 0;
                        return .none;
                    },
                    .blacksmith => {
                        if (self.combat == null) {
                            self.notify("This service is unavailable in this build.");
                            return .none;
                        }
                        self.service_limit = service.id;
                        self.phase = .blacksmith;
                        self.service_action = 0;
                        self.member = 0;
                        return .none;
                    },
                    .rune_master => {
                        if (self.combat == null) {
                            self.notify("This service is unavailable in this build.");
                            return .none;
                        }
                        self.rune_from_menu = false;
                        self.phase = .rune_service;
                        self.service_action = 0;
                        self.member = 0;
                        return .none;
                    },
                    .appraisal => {
                        if (game.item_rules == null) {
                            self.notify("This service is unavailable in this build.");
                            return .none;
                        }
                        self.appraisal_from_service = true;
                        self.phase = .appraisal;
                        self.member = 0;
                        self.slot = 0;
                        return .none;
                    },
                    .save_point => {
                        self.field_facility = .save_point;
                        self.phase = .save_slots;
                        self.yes = false;
                        return .inspect_saves;
                    },
                    .storage => {
                        if (self.combat == null) {
                            self.notify("This service is unavailable in this build.");
                            return .none;
                        }
                        self.field_facility = .storage;
                        self.phase = .storage;
                        self.service_action = 0;
                        self.member = 0;
                        self.slot = 0;
                        return .none;
                    },
                    .bathhouse => {
                        self.field_facility = .bathhouse;
                        self.phase = .bathhouse;
                        self.yes = false;
                        return .none;
                    },
                    .tablet => {
                        if (game.progress.story.scenario) |*story| {
                            self.tablet_view = tablet.loadView(story.recruit_flags);
                            self.field_facility = .tablet;
                            self.phase = .tablet;
                        } else self.notify("The roster is unavailable.");
                        return .none;
                    },
                    .library => {
                        const books = if (game.progress.story.scenario) |story| story.library_books else 0;
                        self.slot = if (books == 0) 0 else @ctz(books);
                        self.field_facility = .library;
                        self.phase = .library;
                        return .none;
                    },
                    .window_styles => {
                        self.field_facility = .window_styles;
                        self.phase = .window_style;
                        return .none;
                    },
                    .sound_themes => {
                        self.sound_theme_cursor = if (game.progress.story.scenario) |story| story.sound_theme else .standard;
                        self.field_facility = .sound_themes;
                        self.phase = .sound_theme;
                        return .none;
                    },
                    .music_player => {
                        if (self.region_bgm == null or self.region_bgm.?.jukebox.len == 0) {
                            self.notify("No songs are available.");
                            return .none;
                        }
                        self.slot = 0;
                        self.jukebox_failed = false;
                        self.jukebox_playing = null;
                        self.field_facility = .music_player;
                        self.phase = .jukebox;
                        return .none;
                    },
                    .cup_game, .card_game, .teleport => self.notify("This service is unavailable here."),
                }
            }
            if (game.dialogue != null and game.dialogue.?.phase == .service) {
                if (self.combat == null) {
                    game.dialogue = null;
                    self.notify("This service is unavailable in this build.");
                    return .none;
                }
                const npc = package.rooms[game.room].npcs[game.dialogue.?.source.npc];
                self.service_limit = npc.weapon_limit;
                self.rune_from_menu = false;
                game.dialogue = null;
                if (input.field.cancel) return .none;
                self.phase = if (npc.service.? == .blacksmith) .blacksmith else .rune_service;
                self.service_action = 0;
                self.member = 0;
                return .none;
            }
            if (game.dialogue != null and game.dialogue.?.phase == .shop) {
                game.dialogue = null;
                if (input.field.cancel) return .none;
                self.shop_stock_len = 0;
                self.shop_allow_equipment = false;
                self.appraisal_from_service = false;
                self.phase = .shop;
                self.member = 0;
                self.shop_choice = 0;
                self.stock_slot = 0;
                return .none;
            }
            if (input.menu and game.dialogue == null and game.rest_ticks == 0) self.pending = true;
            if (self.pending) {
                if (game.remaining > 0) {
                    game.tickWithArrival(package, .{}, ground, arrival);
                    if (arrival == .deferred and game.remaining == 0) return .none;
                }
                self.finishPending(game);
            } else game.tickWithArrival(package, input.field, ground, arrival);
            return .none;
        }
        if (input.field.cancel) {
            if (self.phase == .rune_attach) self.member = self.target;
            if (self.phase == .sound_theme) self.pending_sound = 0x503;
            self.phase = switch (self.phase) {
                .root, .shop, .blacksmith => .closed,
                .rune_service => if (self.rune_from_menu) .rune else .closed,
                .rune_attach, .confirm_rune_remove => .rune_service,
                .name_save => .save_slots,
                .confirm_new_game => .root,
                .save_slots, .storage, .notice, .bathhouse, .bath, .tablet, .library, .window_style, .window_color, .sound_theme, .jukebox => self.leaveFacility(),
                .library_reading => .library,
                .confirm_save => if (self.field_facility == .save_point) .save_slots else .root,
                .load_slots => .root,
                .appraisal => if (self.appraisal_from_service) .closed else .root,
                .confirm_appraisal, .appraisal_notice => .appraisal,
                .storage_items => .storage,
                .confirm_storage, .storage_notice => .storage_items,
                .confirm_rune_attach => .rune_attach,
                .confirm_blacksmith => .blacksmith,
                .buy_member, .sell_items, .shop_notice => .shop,
                .confirm_buy => .buy_member,
                .confirm_sell => .sell_items,
                .item_action, .item_notice => .items,
                .item_transfer, .confirm_discard => .item_action,
                .item_target => if (self.combat != null) .item_action else .items,
                .confirm_weapon_piece => .item_target,
                .formation_target => .formation,
                .rune_target => .rune,
                .equipment_items => .equipment,
                .character_notice => self.character_page,
                else => .root,
            };
            if (self.phase == .closed) {
                self.shop_stock_len = 0;
                self.shop_allow_equipment = false;
                self.appraisal_from_service = false;
            }
            if (self.phase == .rune) self.selectFieldSpell();
            return .none;
        }
        if (input.menu) {
            self.phase = .closed;
            self.field_facility = null;
            self.tablet_view = null;
            self.jukebox_playing = null;
            self.shop_stock_len = 0;
            self.shop_allow_equipment = false;
            self.appraisal_from_service = false;
            if (self.phase == .rune) self.selectFieldSpell();
            return .none;
        }
        switch (self.phase) {
            .closed => unreachable,
            .root => {
                if (input.field.menu_direction == .up) self.move(labels.len - 1);
                if (input.field.menu_direction == .down) self.move(1);
                if (input.field.action) {
                    if (!self.isEnabled(self.selected)) return .none;
                    self.yes = false;
                    self.member = @min(self.member, game.progress.party.len - 1);
                    self.slot = 0;
                    self.phase = switch (self.selected) {
                        .item => .items,
                        .strength => .strength,
                        .formation => .formation,
                        .equipment => .equipment,
                        .rune => .rune,
                        .setup => .setup,
                        .storage => .storage,
                        .appraisal => .appraisal,
                        .save => if (self.combat != null or self.opening_context) .save_slots else .confirm_save,
                        .load => if (self.combat != null or self.opening_context) .load_slots else .confirm_load,
                        .new_game => .confirm_new_game,
                        .back => .closed,
                    };
                    if (self.phase == .rune) self.selectFieldSpell();
                    if (self.phase == .storage) self.service_action = 0;
                    if (self.phase == .save_slots or self.phase == .load_slots) return .inspect_saves;
                }
            },
            .appraisal => {
                if (input.left) self.member = (self.member + game.progress.party.len - 1) % game.progress.party.len;
                if (input.right) self.member = (self.member + 1) % game.progress.party.len;
                const inventory = game.progress.party[self.member].inventory;
                const count = inventory.count();
                if (count == 0) self.slot = 0 else {
                    self.slot = @min(self.slot, count - 1);
                    if (input.field.menu_direction == .up) self.slot = (self.slot + count - 1) % count;
                    if (input.field.menu_direction == .down) self.slot = (self.slot + 1) % count;
                    if (input.field.action) {
                        const item = inventory.slots[self.slot].?;
                        if (item.identified) {
                            self.message = "This item does not need appraisal.";
                            self.phase = .appraisal_notice;
                        } else {
                            self.phase = .confirm_appraisal;
                            self.yes = false;
                        }
                    }
                }
            },
            .confirm_appraisal => {
                if (input.field.menu_direction != null or input.left or input.right) self.yes = !self.yes;
                if (input.field.action) {
                    if (!self.yes) self.phase = .appraisal else {
                        if (game.progress.appraise(game.item_rules.?, self.member, self.slot)) |_| {
                            self.message = game.progress.party[self.member].inventory.slots[self.slot].?.name();
                        } else |err| self.message = if (err == error.InsufficientFunds) "Not enough bits for appraisal." else "This item cannot be appraised here.";
                        self.phase = .appraisal_notice;
                    }
                }
            },
            .appraisal_notice => if (input.field.action) {
                self.phase = .appraisal;
            },
            .storage => {
                if (input.field.menu_direction == .up) self.service_action = (self.service_action + 2) % 3;
                if (input.field.menu_direction == .down) self.service_action = (self.service_action + 1) % 3;
                if (input.field.action) {
                    if (self.service_action == 2) {
                        self.phase = self.leaveFacility();
                    } else {
                        self.storage_withdraw = self.service_action == 1;
                        self.phase = .storage_items;
                        self.member = 0;
                        self.slot = 0;
                    }
                }
            },
            .bathhouse => {
                if (input.left != input.right) self.yes = input.left;
                if (input.field.menu_direction == .up or input.field.menu_direction == .down) self.yes = !self.yes;
                if (input.field.action) self.phase = if (self.yes) .bath else self.leaveFacility();
            },
            .bath => if (input.field.action) {
                self.phase = self.leaveFacility();
            },
            .tablet => if (self.tablet_view) |*view| {
                const intent: tablet.Intent = if (input.field.action) .confirm else if (input.left) .left else if (input.right) .right else switch (input.field.menu_direction orelse return .none) {
                    .up => .up,
                    .down => .down,
                    else => return .none,
                };
                _ = view.apply(intent);
            },
            .library => {
                const books = if (game.progress.story.scenario) |story| story.library_books else 0;
                if (books == 0) return .none;
                const step: usize = switch (input.field.menu_direction orelse .left) {
                    .up => 7,
                    .down => 1,
                    else => 0,
                };
                if (step != 0) {
                    self.slot = (self.slot + step) % 8;
                    while (books & (@as(u8, 1) << @as(u3, @intCast(self.slot))) == 0) self.slot = (self.slot + step) % 8;
                }
                if (input.field.action) self.phase = .library_reading;
            },
            .library_reading => if (input.field.action) {
                self.phase = .library;
            },
            .window_style => if (game.progress.story.scenario) |*story| {
                const step = themeSelectionStep(input);
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
                if (input.field.action) self.phase = .window_color;
            },
            .window_color => if (game.progress.story.scenario) |*story| {
                const step: u8 = if (input.left or input.field.menu_direction == .left)
                    7
                else if (input.right or input.field.menu_direction == .right)
                    1
                else if (input.field.menu_direction == .up or input.field.menu_direction == .down) 4 else 0;
                const index: u8 = @backingInt(story.window_appearance.color);
                story.window_appearance.color = @fromBackingInt(@intCast((index + step) % 8));
                if (input.field.action) self.phase = self.leaveFacility();
            },
            .sound_theme => if (game.progress.story.scenario) |*story| {
                if (input.field.action and self.sound_theme_cursor != story.sound_theme) {
                    story.sound_theme = self.sound_theme_cursor;
                    self.pending_sound = 0x504;
                    return .none;
                }
                const step = themeSelectionStep(input);
                if (step != 0) {
                    var index: u8 = @backingInt(self.sound_theme_cursor);
                    while (true) {
                        index = (index + step) % 5;
                        const theme: SoundTheme = @fromBackingInt(@intCast(index));
                        if (!story.hasSoundTheme(theme)) continue;
                        self.sound_theme_cursor = theme;
                        self.pending_sound = 0x502;
                        break;
                    }
                }
            },
            .jukebox => {
                const count = self.region_bgm.?.jukebox.len;
                const step: usize = if (input.left or input.right or input.field.menu_direction == .left or input.field.menu_direction == .right)
                    count / 2
                else if (input.field.menu_direction == .up) count - 1 else if (input.field.menu_direction == .down) 1 else 0;
                self.slot = (self.slot + step) % count;
                if (input.field.action) {
                    self.jukebox_failed = false;
                    self.jukebox_playing = if (self.jukebox_playing == self.slot) null else self.slot;
                }
            },
            .storage_items => {
                if (input.left) self.member = (self.member + game.progress.party.len - 1) % game.progress.party.len;
                if (input.right) self.member = (self.member + 1) % game.progress.party.len;
                const count = if (self.storage_withdraw) game.progress.storage.count() else game.progress.party[self.member].inventory.count();
                if (count == 0) {
                    self.slot = 0;
                } else {
                    self.slot = @min(self.slot, count - 1);
                    if (input.field.menu_direction == .up) self.slot = (self.slot + count - 1) % count;
                    if (input.field.menu_direction == .down) self.slot = (self.slot + 1) % count;
                    if (input.field.action) {
                        self.storage_id = if (self.storage_withdraw) game.progress.storage.itemAt(self.slot) else game.progress.party[self.member].inventory.slots[self.slot].?.id;
                        self.phase = .confirm_storage;
                        self.yes = false;
                    }
                }
            },
            .confirm_storage => {
                if (input.field.menu_direction != null or input.left or input.right) self.yes = !self.yes;
                if (input.field.action) {
                    if (!self.yes) {
                        self.phase = .storage_items;
                    } else {
                        const result = if (self.storage_withdraw)
                            game.progress.storage.withdraw(&game.progress.party[self.member].inventory, self.storage_id.?)
                        else
                            self.combat.?.depositToStorage(&game.progress.storage, self.member, self.slot);
                        if (result) |_| {
                            self.message = if (self.storage_withdraw) "Item withdrawn." else "Item deposited.";
                        } else |err| self.message = switch (err) {
                            error.StorageFull => "Already storing 254 of this item.",
                            error.InventoryFull => "This member's inventory is full.",
                            error.EquippedItem => "Remove worn equipment before storing it.",
                            error.AppraisalRequired => "Appraise the urn before storing it.",
                            else => "The transfer could not be completed.",
                        };
                        self.phase = .storage_notice;
                    }
                }
            },
            .storage_notice => if (input.field.action) {
                self.phase = .storage_items;
            },
            .formation, .formation_target => {
                const count = game.progress.party.len;
                const choice = if (self.phase == .formation) &self.member else &self.target;
                if (input.field.menu_direction == .up or input.left) choice.* = (choice.* + count - 1) % count;
                if (input.field.menu_direction == .down or input.right) choice.* = (choice.* + 1) % count;
                if (input.field.action) {
                    if (self.phase == .formation) {
                        self.target = self.member;
                        self.phase = .formation_target;
                    } else {
                        const combat = self.combat.?;
                        combat.swapFormation(self.member, self.target) catch unreachable;
                        self.phase = .formation;
                    }
                }
            },
            .equipment => {
                const count = game.progress.party.len;
                if (input.left) self.member = (self.member + count - 1) % count;
                if (input.right) self.member = (self.member + 1) % count;
                var slot_index: usize = @backingInt(self.equipment_slot);
                if (input.field.menu_direction == .up) slot_index = (slot_index + 4) % 5;
                if (input.field.menu_direction == .down) slot_index = (slot_index + 1) % 5;
                self.equipment_slot = @fromBackingInt(@intCast(slot_index));
                if (input.field.action) {
                    self.phase = .equipment_items;
                    self.slot = 0;
                }
            },
            .equipment_items => {
                const combat = self.combat.?;
                const choices = game.progress.party[self.member].inventory.count() + 1;
                if (input.field.menu_direction == .up) self.slot = (self.slot + choices - 1) % choices;
                if (input.field.menu_direction == .down) self.slot = (self.slot + 1) % choices;
                if (input.field.action) {
                    const item = if (self.slot == 0) null else combat.gearIndex(game.progress.party[self.member].inventory.slots[self.slot - 1].?.id) orelse {
                        self.message = "This is not wearable equipment.";
                        self.character_page = .equipment_items;
                        self.phase = .character_notice;
                        return .none;
                    };
                    self.message = "Equipment changed.";
                    if (input.party_transactions) {
                        self.character_page = .equipment;
                        self.phase = .character_notice;
                        return .party_equip;
                    }
                    combat.equipSlotOwned(self.member, self.equipment_slot, item) catch |err| {
                        self.message = if (err == error.ItemUnavailable) "You do not own a spare of this item." else "This member cannot equip that item here.";
                    };
                    self.character_page = .equipment;
                    self.phase = .character_notice;
                }
            },
            .rune => {
                const combat = self.combat.?;
                const count = game.progress.party.len;
                if (input.left) self.member = (self.member + count - 1) % count;
                if (input.right) self.member = (self.member + 1) % count;
                if (input.left or input.right) self.selectFieldSpell();
                const slots: usize = if (self.travel_context) 4 else 5;
                if (input.field.menu_direction == .up) self.slot = (self.slot + slots - 1) % slots;
                if (input.field.menu_direction == .down) self.slot = (self.slot + 1) % slots;
                if (input.field.action) {
                    if (self.slot == 4) {
                        if (self.travel_context) return .none;
                        self.rune_from_menu = true;
                        self.service_action = 0;
                        self.phase = .rune_service;
                        return .none;
                    }
                    const rune = combat.rune(self.member) orelse return .none;
                    const spell = rune.spells[self.slot] orelse return .none;
                    if ((!combat.content.systems.?.spells[spell].allies or !combat.content.systems.?.spells[spell].field_use) or !combat.canCast(self.member, spell)) return .none;
                    self.target = self.member;
                    self.phase = .rune_target;
                }
            },
            .rune_target => {
                const combat = self.combat.?;
                const count = game.progress.party.len;
                if (input.field.menu_direction == .up) self.target = (self.target + count - 1) % count;
                if (input.field.menu_direction == .down) self.target = (self.target + 1) % count;
                if (input.field.action) {
                    const spell = combat.rune(self.member).?.spells[self.slot].?;
                    self.message = "Rune used. One charge consumed.";
                    combat.castFieldSpell(self.member, spell, self.target) catch {
                        self.message = "No valid target. No rune charge consumed.";
                    };
                    self.character_page = .rune;
                    self.phase = .character_notice;
                }
            },
            .character_notice => if (input.field.action) {
                self.phase = self.character_page;
            },
            .strength => {
                if (input.field.menu_direction != null) self.strength_details = !self.strength_details;
                const count = game.progress.party.len;
                if (count > 0) {
                    if (input.left) self.member = (self.member + count - 1) % count;
                    if (input.right) self.member = (self.member + 1) % count;
                }
                if (input.field.action) self.phase = .root;
            },
            .items => {
                const count = game.progress.party.len;
                if (input.has_shared_items and input.left != input.right and
                    ((input.left and self.member == 0) or (input.right and self.member + 1 == count)))
                {
                    self.phase = .shared_items;
                    return .none;
                }
                if (input.left) self.member = (self.member + count - 1) % count;
                if (input.right) self.member = (self.member + 1) % count;
                const slots = game.progress.party[self.member].inventory.count();
                if (slots == 0) {
                    self.slot = 0;
                } else {
                    self.slot = @min(self.slot, slots - 1);
                    if (input.field.menu_direction == .up) self.slot = (self.slot + slots - 1) % slots;
                    if (input.field.menu_direction == .down) self.slot = (self.slot + 1) % slots;
                    if (input.field.action and game.item_rules != null) {
                        self.target = self.member;
                        const selected = game.progress.party[self.member].inventory.slots[self.slot].?.id;
                        if (selected == .sacrificial_buddha and self.combat == null) {
                            self.message = "Revives its bearer automatically in battle.";
                            self.phase = .item_notice;
                            return .none;
                        }
                        if (game.item_rules.?.consumable(selected)) |definition| if (!definition.field_usable) {
                            self.message = "This item can only be used in battle.";
                            self.phase = .item_notice;
                            return .none;
                        };
                        self.phase = if (self.combat != null) .item_action else .item_target;
                        self.item_action = 0;
                    }
                }
            },
            .shared_items => if (input.left != input.right) {
                self.member = if (input.left) game.progress.party.len - 1 else 0;
                self.slot = 0;
                self.phase = .items;
            },
            .item_action => {
                if (input.field.menu_direction == .up) self.item_action = (self.item_action + 2) % 3;
                if (input.field.menu_direction == .down) self.item_action = (self.item_action + 1) % 3;
                if (input.field.action) {
                    const item = game.progress.party[self.member].inventory.slots[self.slot].?;
                    self.target = self.member;
                    if (self.item_action == 0) {
                        if (item.id == .blinking_mirror and input.travel_tools) return .blinking_mirror;
                        if (input.weapon_pieces and item.id.weaponPiece()) {
                            self.phase = .item_target;
                        } else if (game.item_rules.?.consumable(item.id)) |definition| {
                            if (definition.field_usable) self.phase = .item_target else {
                                self.message = "This item can only be used in battle.";
                                self.phase = .item_notice;
                            }
                        } else {
                            self.message = if (item.id == .sacrificial_buddha) "Revives its bearer automatically in battle." else "This item's use is not available\nin this episode.";
                            self.phase = .item_notice;
                        }
                    } else if (self.combat.?.itemEquipped(self.member, self.slot)) {
                        self.message = "Remove this item in Equipment first.";
                        self.phase = .item_notice;
                    } else {
                        self.yes = false;
                        self.phase = if (self.item_action == 1) .item_transfer else .confirm_discard;
                    }
                }
            },
            .item_transfer => {
                const count = game.progress.party.len;
                if (input.field.menu_direction == .up) self.target = (self.target + count - 1) % count;
                if (input.field.menu_direction == .down) self.target = (self.target + 1) % count;
                if (input.field.action) {
                    self.message = "Item given to the selected member.";
                    if (input.party_transactions) {
                        self.phase = .item_notice;
                        return .party_give;
                    }
                    game.progress.transfer(self.member, self.slot, self.target) catch |err| {
                        self.message = if (err == error.InventoryFull) "That member's inventory is full." else "Choose a different member.";
                    };
                    self.phase = .item_notice;
                    self.slot = @min(self.slot, game.progress.party[self.member].inventory.count() -| 1);
                }
            },
            .confirm_discard => {
                if (input.field.menu_direction != null or input.left or input.right) self.yes = !self.yes;
                if (input.field.action) {
                    if (!self.yes) self.phase = .item_action else {
                        if (input.party_transactions) {
                            self.message = "Item discarded.";
                            self.phase = .item_notice;
                            return .party_discard;
                        }
                        game.progress.discard(self.member, self.slot) catch unreachable;
                        self.message = "Item discarded.";
                        self.phase = .item_notice;
                        self.slot = @min(self.slot, game.progress.party[self.member].inventory.count() -| 1);
                    }
                }
            },
            .item_target => {
                const count = game.progress.party.len;
                if (input.field.menu_direction == .up) self.target = (self.target + count - 1) % count;
                if (input.field.menu_direction == .down) self.target = (self.target + 1) % count;
                if (input.field.action) {
                    if (input.weapon_pieces and game.progress.party[self.member].inventory.slots[self.slot].?.id.weaponPiece()) {
                        self.weapon_piece_replace = false;
                        self.phase = .item_notice;
                        return .weapon_piece;
                    }
                    const item = game.item_rules.?.consumable(game.progress.party[self.member].inventory.slots[self.slot].?.id);
                    self.message = if (item != null and item.?.cure != null) "Condition cured. One use consumed." else "Recovered HP. One use consumed.";
                    game.progress.useItem(game.item_rules.?, self.member, self.slot, self.target) catch |err| {
                        self.message = switch (err) {
                            error.BattleOnlyItem => "This item can only be used in battle.",
                            error.FullHealth => "HP is full. No item was consumed.",
                            error.InvalidTarget => "This item cannot revive a member.",
                            error.NoEffect => "No condition to cure. No item consumed.",
                            else => "This item could not be used.",
                        };
                    };
                    self.phase = .item_notice;
                    self.slot = @min(self.slot, game.progress.party[self.member].inventory.count() -| 1);
                }
            },
            .confirm_weapon_piece => {
                if (input.field.menu_direction != null or input.left or input.right) self.yes = !self.yes;
                if (input.field.action) {
                    if (!self.yes) {
                        self.phase = .item_target;
                    } else {
                        self.weapon_piece_replace = true;
                        self.phase = .item_notice;
                        return .weapon_piece;
                    }
                }
            },
            .shop => {
                if (input.field.menu_direction == .up) self.shop_choice = (self.shop_choice + 2) % 3;
                if (input.field.menu_direction == .down) self.shop_choice = (self.shop_choice + 1) % 3;
                if (input.field.action) {
                    self.phase = switch (self.shop_choice) {
                        0 => .buy_member,
                        1 => .sell_items,
                        else => .closed,
                    };
                    if (self.phase == .closed) {
                        self.shop_stock_len = 0;
                        self.shop_allow_equipment = false;
                    }
                    self.slot = 0;
                    self.yes = false;
                }
            },
            .sell_items => {
                const count = game.progress.party.len;
                if (input.left) self.member = (self.member + count - 1) % count;
                if (input.right) self.member = (self.member + 1) % count;
                const slots = game.progress.party[self.member].inventory.count();
                self.slot = @min(self.slot, slots -| 1);
                if (slots > 0) {
                    if (input.field.menu_direction == .up) self.slot = (self.slot + slots - 1) % slots;
                    if (input.field.menu_direction == .down) self.slot = (self.slot + 1) % slots;
                    if (input.field.action) {
                        if (self.combat != null and self.combat.?.itemEquipped(self.member, self.slot)) {
                            self.message = "Remove this item in Equipment first.";
                            self.phase = .shop_notice;
                            return .none;
                        }
                        _ = (if (self.shop_allow_equipment) game.progress.shopSalePrice(game.item_rules.?, self.member, self.slot) else game.progress.salePrice(game.item_rules.?, self.member, self.slot)) catch {
                            self.message = "The merchant cannot buy this item.";
                            self.phase = .shop_notice;
                            return .none;
                        };
                        self.yes = false;
                        self.phase = .confirm_sell;
                    }
                }
            },
            .confirm_sell => {
                if (input.field.menu_direction != null or input.left or input.right) self.yes = !self.yes;
                if (input.field.action) {
                    if (!self.yes) self.phase = .sell_items else {
                        self.message = "Sold the selected item bundle.";
                        (if (self.shop_allow_equipment) game.progress.sellShopItem(game.item_rules.?, self.member, self.slot) else game.progress.sellItem(game.item_rules.?, self.member, self.slot)) catch {
                            self.message = "The sale could not be completed.";
                        };
                        self.phase = .shop_notice;
                        self.slot = @min(self.slot, game.progress.party[self.member].inventory.count() -| 1);
                    }
                }
            },
            .rune_service => {
                const count = game.progress.party.len;
                if (input.left) self.member = (self.member + count - 1) % count;
                if (input.right) self.member = (self.member + 1) % count;
                if (input.field.menu_direction == .up) self.service_action = (self.service_action + 2) % 3;
                if (input.field.menu_direction == .down) self.service_action = (self.service_action + 1) % 3;
                if (input.field.action) {
                    self.target = self.member;
                    self.yes = false;
                    self.slot = 0;
                    self.phase = switch (self.service_action) {
                        0 => .rune_attach,
                        1 => .confirm_rune_remove,
                        else => if (self.rune_from_menu) .rune else .closed,
                    };
                    if (self.phase == .rune) self.selectFieldSpell();
                }
            },
            .rune_attach => {
                const count = game.progress.party.len;
                if (input.left) self.member = (self.member + count - 1) % count;
                if (input.right) self.member = (self.member + 1) % count;
                const slots = game.progress.party[self.member].inventory.count();
                self.slot = @min(self.slot, slots -| 1);
                if (slots > 0) {
                    if (input.field.menu_direction == .up) self.slot = (self.slot + slots - 1) % slots;
                    if (input.field.menu_direction == .down) self.slot = (self.slot + 1) % slots;
                    if (input.field.action) {
                        self.yes = false;
                        self.phase = .confirm_rune_attach;
                    }
                }
            },
            .confirm_rune_attach, .confirm_rune_remove => {
                if (input.field.menu_direction != null or input.left or input.right) self.yes = !self.yes;
                if (input.field.action) {
                    if (!self.yes) self.phase = if (self.phase == .confirm_rune_attach) .rune_attach else .rune_service else {
                        self.message = "Rune changed. Spell charges preserved.";
                        const result = if (self.phase == .confirm_rune_attach) self.combat.?.attachRune(self.target, self.member, self.slot) else self.combat.?.detachRune(self.target);
                        result catch |err| {
                            self.message = switch (err) {
                                error.RuneLocked => "This rune cannot be removed or replaced.",
                                error.RuneOccupied => "Remove the current rune first.",
                                error.IncompatibleRune => "This character cannot use that rune.",
                                error.InventoryFull => "Make room in this member's bag first.",
                                else => "No usable rune or crystal was selected.",
                            };
                        };
                        self.member = self.target;
                        self.character_page = .rune_service;
                        self.phase = .character_notice;
                    }
                }
            },
            .blacksmith => {
                const count = game.progress.party.len;
                if (input.left or input.field.menu_direction == .up) self.member = (self.member + count - 1) % count;
                if (input.right or input.field.menu_direction == .down) self.member = (self.member + 1) % count;
                if (input.field.action) {
                    _ = self.combat.?.sharpenPrice(self.member, self.service_limit) catch {
                        self.message = "I cannot sharpen this weapon further.";
                        self.character_page = .blacksmith;
                        self.phase = .character_notice;
                        return .none;
                    };
                    self.yes = false;
                    self.phase = .confirm_blacksmith;
                }
            },
            .confirm_blacksmith => {
                if (input.field.menu_direction != null or input.left or input.right) self.yes = !self.yes;
                if (input.field.action) {
                    if (!self.yes) self.phase = .blacksmith else {
                        self.message = "Weapon sharpened.";
                        self.combat.?.sharpen(self.member, self.service_limit, &game.progress.money) catch |err| {
                            self.message = if (err == error.InsufficientFunds) "You do not have enough bits." else "I cannot sharpen this weapon further.";
                        };
                        self.character_page = .blacksmith;
                        self.phase = .character_notice;
                    }
                }
            },
            .buy_member => {
                const count = game.progress.party.len;
                if (input.left) self.member = (self.member + count - 1) % count;
                if (input.right) self.member = (self.member + 1) % count;
                const stock = self.shopStock(game.item_rules.?);
                const stock_count = stock.len;
                if (stock_count > 0) {
                    if (input.field.menu_direction == .up) self.stock_slot = (self.stock_slot + stock_count - 1) % stock_count;
                    if (input.field.menu_direction == .down) self.stock_slot = (self.stock_slot + 1) % stock_count;
                    if (input.field.action) {
                        self.yes = false;
                        self.phase = .confirm_buy;
                    }
                }
            },
            .confirm_buy => {
                if (input.field.menu_direction != null or input.left or input.right) self.yes = !self.yes;
                if (input.field.action) {
                    if (!self.yes) {
                        self.phase = .buy_member;
                    } else {
                        self.message = "Bought item for the selected member.";
                        const stock = self.shopStock(game.item_rules.?);
                        (if (self.shop_allow_equipment) game.progress.buyShopGood(game.item_rules.?, stock, stock[self.stock_slot], self.member) else game.progress.buyItem(game.item_rules.?, stock[self.stock_slot], self.member)) catch |err| {
                            self.message = switch (err) {
                                error.InsufficientFunds => "You do not have enough bits.",
                                error.InventoryFull => "That member carries nine items.",
                                else => "The purchase could not be completed.",
                            };
                        };
                        self.phase = .shop_notice;
                    }
                }
            },
            .item_notice, .shop_notice => if (input.field.action) {
                self.phase = if (self.phase == .item_notice) .items else .shop;
            },
            .save_slots, .load_slots => {
                if (input.field.menu_direction == .up) self.save_slot = (self.save_slot + save_slots.count - 1) % save_slots.count;
                if (input.field.menu_direction == .down) self.save_slot = (self.save_slot + 1) % save_slots.count;
                if (input.field.action) {
                    const entry = self.summaries[self.save_slot];
                    self.yes = false;
                    if (entry.status == .future) {
                        self.notify("This slot requires a newer build. Choose another slot.");
                    } else if (self.phase == .save_slots) {
                        self.save_label = entry.name;
                        self.phase = .name_save;
                    } else if (entry.status == .ready or entry.status == .backup) {
                        self.phase = .confirm_load;
                    } else self.notify(if (entry.status == .empty) "This slot is empty." else "This slot has no valid save or backup.");
                }
            },
            .name_save => {
                if (input.erase) self.save_label.erase();
                self.save_label.append(input.text);
                if (input.field.action) {
                    self.save_label.validate() catch {
                        self.save_label = save_slots.defaultLabel(self.save_slot);
                    };
                    self.yes = false;
                    self.phase = .confirm_save;
                }
            },
            .setup => {
                if (input.field.cancel or input.menu) {
                    self.phase = .root;
                    return .none;
                }
                if (input.field.menu_direction == .up) self.setup_row = (self.setup_row + 3) % 4;
                if (input.field.menu_direction == .down) self.setup_row = (self.setup_row + 1) % 4;
                if (input.left or input.right or input.field.action) {
                    self.preferences.adjust(self.setup_row, !input.left);
                    return .settings_changed;
                }
            },
            .confirm_save, .confirm_load => {
                if (input.field.menu_direction != null or input.left or input.right) self.yes = !self.yes;
                if (input.field.action) {
                    if (!self.yes) {
                        self.phase = self.leaveFacility();
                    } else {
                        const effect: Effect = if (self.phase == .confirm_save) .save else .load;
                        self.notify(if (effect == .save) "Saving..." else "Loading...");
                        return effect;
                    }
                }
            },
            .confirm_new_game => {
                if (input.field.menu_direction != null or input.left or input.right) self.yes = !self.yes;
                if (input.field.action) {
                    if (!self.yes) {
                        self.phase = .root;
                    } else {
                        self.phase = .closed;
                        return .new_game;
                    }
                }
            },
            .notice => if (input.field.action) {
                self.phase = self.leaveFacility();
            },
        }
        return .none;
    }

    fn selectFieldSpell(self: *State) void {
        const combat = self.combat.?;
        self.slot = if (self.travel_context) 0 else 4;
        const rune = combat.rune(self.member) orelse return;
        for (rune.spells, 0..) |slot, tier| if (slot) |spell| {
            if (combat.content.systems.?.spells[spell].allies and combat.content.systems.?.spells[spell].field_use and combat.canCast(self.member, spell)) {
                self.slot = tier;
                return;
            }
        };
    }

    fn move(self: *State, step: usize) void {
        var index: usize = @backingInt(self.selected);
        for (0..labels.len) |_| {
            index = (index + step) % labels.len;
            const command: Command = @fromBackingInt(@as(u4, @intCast(index)));
            if (self.isEnabled(command)) {
                self.selected = command;
                return;
            }
        }
    }
};
