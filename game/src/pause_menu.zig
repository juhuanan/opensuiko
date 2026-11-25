//! Field pause menu state machine, root navigation, and facility dispatch.
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
const SoundTheme = field.game_state.event_runtime.SoundTheme;
const audio_route = @import("audio_route");

const nav = @import("menu/navigation.zig");
const inventory = @import("menu/inventory.zig");
const equipment = @import("menu/equipment.zig");
const formation = @import("menu/formation.zig");
const runes = @import("menu/runes.zig");
const save_load = @import("menu/save_load.zig");
const menu_settings = @import("menu/settings.zig");
const service_dispatch = @import("menu/services/dispatch.zig");
const shop = @import("menu/services/shop.zig");
const blacksmith = @import("menu/services/blacksmith.zig");
const appraisal = @import("menu/services/appraisal.zig");
const storage = @import("menu/services/storage.zig");
const rune_master = @import("menu/services/rune_master.zig");
const facilities = @import("menu/services/facilities.zig");

pub const Command = enum { item, strength, rune, formation, equipment, setup, storage, appraisal, save, load, new_game, back };
pub const labels = [_][]const u8{ "Item", "Strength", "Rune", "Formation", "Equipment", "Setup", "Storage", "Appraisal", "Save", "Load", "New Game", "Return" };
pub const Phase = enum { appraisal, confirm_appraisal, appraisal_notice, storage, storage_items, confirm_storage, storage_notice, closed, root, save_slots, load_slots, name_save, setup, strength, confirm_save, confirm_load, confirm_new_game, notice, items, item_action, item_transfer, confirm_discard, item_target, confirm_weapon_piece, item_notice, shop, blacksmith, confirm_blacksmith, rune_service, rune_attach, confirm_rune_attach, confirm_rune_remove, buy_member, confirm_buy, sell_items, confirm_sell, shop_notice, formation, formation_target, equipment, equipment_items, rune, rune_target, character_notice, shared_items, bathhouse, bath, tablet, library, library_reading, window_style, window_color, sound_theme, jukebox };
pub const TickResult = struct {
    effect: Effect = .none,
    movement: field.Update = .{},
    closed_dialogue: ?field.Dialogue = null,
};

pub const Effect = enum { none, save, load, inspect_saves, settings_changed, party_give, party_discard, party_equip, weapon_piece, blinking_mirror, new_game };
pub const Input = struct { field: field.Input = .{}, menu: bool = false, left: bool = false, right: bool = false, text: []const u8 = "", erase: bool = false, party_transactions: bool = false, weapon_pieces: bool = false, has_shared_items: bool = false, travel_tools: bool = false };

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
        return self.tickWithArrivalAndGround(package, game, input, arrival, null).effect;
    }

    pub fn tickWithArrivalAndGround(self: *State, package: field.Package, game: *field.State, input: Input, arrival: field.StepArrival, ground: ?field.Ground) TickResult {
        const dialogue = game.dialogue;
        var result = self.advanceFrame(package, game, input, arrival, ground);
        if (game.dialogue == null) result.closed_dialogue = dialogue;
        return result;
    }

    fn advanceFrame(self: *State, package: field.Package, game: *field.State, input: Input, arrival: field.StepArrival, ground: ?field.Ground) TickResult {
        if (self.phase != .closed) return .{ .effect = self.tickMenu(game, input) };
        if (service_dispatch.openPendingOrDialogue(self, package, game, input)) |effect| return .{ .effect = effect };
        if (input.menu and game.dialogue == null and game.rest_ticks == 0) self.pending = true;
        if (!self.pending) return .{ .movement = game.tickWithArrival(package, input.field, ground, arrival) };
        var update: field.Update = .{};
        if (game.remaining > 0) {
            update = game.tickWithArrival(package, .{}, ground, arrival);
            if (arrival == .deferred and game.remaining == 0) return .{ .movement = update };
        }
        self.finishPending(game);
        return .{ .movement = update };
    }

    fn tickMenu(self: *State, game: *field.State, input: Input) Effect {
        if (input.field.cancel) {
            nav.handleCancel(self);
            return .none;
        }
        if (input.menu) {
            nav.closeAll(self);
            return .none;
        }
        switch (self.phase) {
            .closed => unreachable,
            .root => return self.handleRoot(game, input),
            .setup => return menu_settings.handle(self, input),
            .save_slots, .load_slots, .name_save, .confirm_save, .confirm_load, .confirm_new_game, .notice => return save_load.handle(self, input),
            .items, .shared_items, .item_action, .item_transfer, .confirm_discard, .item_target, .confirm_weapon_piece, .item_notice => return inventory.handle(self, game, input),
            .equipment, .equipment_items, .strength, .character_notice => return equipment.handle(self, game, input),
            .formation, .formation_target => formation.handle(self, game, input),
            .rune, .rune_target => runes.handle(self, game, input),
            .shop, .buy_member, .confirm_buy, .sell_items, .confirm_sell, .shop_notice => shop.handle(self, game, input),
            .blacksmith, .confirm_blacksmith => blacksmith.handle(self, game, input),
            .appraisal, .confirm_appraisal, .appraisal_notice => appraisal.handle(self, game, input),
            .storage, .storage_items, .confirm_storage, .storage_notice => storage.handle(self, game, input),
            .rune_service, .rune_attach, .confirm_rune_attach, .confirm_rune_remove => rune_master.handle(self, game, input),
            .bathhouse, .bath, .tablet, .library, .library_reading, .window_style, .window_color, .sound_theme, .jukebox => facilities.handle(self, game, input),
        }
        return .none;
    }

    fn handleRoot(self: *State, game: *field.State, input: Input) Effect {
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
            if (self.phase == .rune) runes.selectFieldSpell(self);
            if (self.phase == .storage) self.service_action = 0;
            if (self.phase == .save_slots or self.phase == .load_slots) return .inspect_saves;
        }
        return .none;
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
