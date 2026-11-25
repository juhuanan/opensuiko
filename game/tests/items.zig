const std = @import("std");
const field = @import("field");
const saves = @import("save_file");
const pause = @import("pause_menu");
const allocator = std.testing.allocator;
fn hero() field.game_state.Member {
    return .{ .id = "hero", .name = "Hero", .hp = 35, .max_hp = 100, .status = .poisoned, .rune_charges = .{ 1, 0, 0, 0 }, .max_rune_charges = .{ 3, 0, 0, 0 } };
}

test "all source appraisal goods preserve names prices hidden state and inventory identity" {
    const parsed = try std.json.parseFromSlice(field.items.Rules, allocator, field.items.json, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    for (parsed.value.goods) |good| try std.testing.expectEqualStrings(good.id.name(), good.name);
    try parsed.value.validate();
    const Proof = struct { appraisal_items: []const struct { id: field.items.Id, unidentified_name: []const u8 } };
    const proof = try std.json.parseFromSlice(Proof, allocator, @embedFile("fixtures/appraisal_names.json"), .{ .ignore_unknown_fields = true });
    defer proof.deinit();
    try std.testing.expectEqual(@as(usize, 22), parsed.value.appraisals.len);
    try std.testing.expectEqual(parsed.value.appraisals.len, proof.value.appraisal_items.len);
    for (parsed.value.appraisals, proof.value.appraisal_items) |entry, witness| {
        const id = entry.id;
        const price = entry.price;
        try std.testing.expectEqual(witness.id, id);
        try std.testing.expectEqual(price, parsed.value.good(id).?.price);
        try std.testing.expect(!parsed.value.stocked(id));
        var member = hero();
        try std.testing.expect(try member.inventory.receive(id));
        var party = [_]field.game_state.Member{member};
        var progress = field.game_state.Progress{ .party = &party, .money = 500 };
        try progress.validate();
        const encoded = try std.json.Stringify.valueAlloc(allocator, member.inventory, .{});
        defer allocator.free(encoded);
        const restored = try std.json.parseFromSlice(field.items.Inventory, allocator, encoded, .{});
        defer restored.deinit();
        try std.testing.expectEqual(id, restored.value.slots[0].?.id);
        try std.testing.expect(!restored.value.slots[0].?.identified);
        try std.testing.expectEqualStrings(witness.unidentified_name, restored.value.slots[0].?.name());
        try std.testing.expectError(error.CannotSell, progress.sellItem(parsed.value, 0, 0));
        try progress.appraise(parsed.value, 0, 0);
        try std.testing.expect(party[0].inventory.slots[0].?.identified and progress.money == 0);
        try progress.sellItem(parsed.value, 0, 0);
        try std.testing.expect(progress.money == price / 2 and party[0].inventory.count() == 0);
    }
}

test "legacy stored counts default newly represented rune pieces to zero" {
    const Storage = field.game_state.storage.Storage;
    const parsed = try std.json.parseFromSlice(Storage, allocator, "{\"counts\":{\"medicine\":2}}", .{});
    defer parsed.deinit();
    try parsed.value.validate();
    try std.testing.expectEqual(@as(u16, 2), parsed.value.quantity(.medicine));
    for ([_]field.items.Id{ .fire_rune_piece, .wind_rune_piece, .thunder_rune_piece }) |id| {
        try std.testing.expectEqual(@as(u16, 0), parsed.value.quantity(id));
    }
}

test "healing and cure items agree with independent native vectors" {
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    const Vector = struct { id: field.items.Id, hp_before: u16, max_hp: u16, status_before: field.game_state.Status, balloons_before: u8, uses_before: u16, hp_after: u16, status_after: field.game_state.Status, balloons_after: u8, uses_after: u16, changed: bool };
    const vectors = try std.json.parseFromSlice([]Vector, allocator, @embedFile("fixtures/consumables.json"), .{});
    defer vectors.deinit();
    try std.testing.expectEqual(@as(usize, 128), vectors.value.len);
    for (vectors.value) |row| {
        var members = [_]field.game_state.Member{hero()};
        members[0].hp = row.hp_before;
        members[0].max_hp = row.max_hp;
        members[0].status = row.status_before;
        members[0].balloons = row.balloons_before;
        members[0].inventory.slots[0] = .{ .id = row.id, .uses = row.uses_before };
        members[0].inventory.slots[1] = .{ .id = .bandanna, .uses = 0 };
        var progress = field.game_state.Progress{ .money = 350, .party = &members };
        if (row.changed) try progress.useItem(rules.value, 0, 0, 0) else {
            try std.testing.expectError(if (rules.value.consumable(row.id).?.heal_hp > 0) error.FullHealth else error.NoEffect, progress.useItem(rules.value, 0, 0, 0));
        }
        try std.testing.expectEqual(row.hp_after, members[0].hp);
        try std.testing.expectEqual(row.status_after, members[0].status);
        try std.testing.expectEqual(row.balloons_after, members[0].balloons);
        if (row.uses_after == 0) {
            try std.testing.expectEqual(.bandanna, members[0].inventory.slots[0].?.id);
            try std.testing.expectEqual(@as(usize, 1), members[0].inventory.count());
        } else try std.testing.expectEqual(row.uses_after, members[0].inventory.slots[0].?.uses);
    }
}

test "catalog validation, legacy rules and purchase boundaries preserve inventory and money" {
    const parsed = try field.items.load(allocator, field.items.json);
    defer parsed.deinit();
    const rules = parsed.value;
    var invalid = rules;
    invalid.consumables = rules.consumables[0..3];
    try std.testing.expectError(error.InvalidItems, invalid.validate());
    invalid = rules;
    invalid.stock = &.{ .medicine, .medicine };
    try std.testing.expectError(error.InvalidItems, invalid.validate());
    invalid.stock = &.{.water_rune_piece};
    try std.testing.expectError(error.InvalidItems, invalid.validate());
    var catalog: [4]field.items.Consumable = undefined;
    @memcpy(&catalog, rules.consumables);
    invalid = rules;
    invalid.consumables = &catalog;
    catalog[0].uses = 0;
    try std.testing.expectError(error.InvalidItems, invalid.validate());
    catalog[0] = rules.consumables[0];
    catalog[0].cure = .poison;
    try std.testing.expectError(error.InvalidItems, invalid.validate());
    catalog[0] = rules.consumables[0];
    catalog[1] = catalog[0];
    try std.testing.expectError(error.InvalidItems, invalid.validate());
    var legacy = rules;
    legacy.schema = "suikoden-items/1";
    legacy.consumables = &.{};
    legacy.battle_reusables = &.{};
    legacy.automatic_revival = null;
    legacy.stock = &.{.medicine};
    try legacy.validate();
    try std.testing.expectEqual(@as(u16, 100), legacy.consumable(.medicine).?.heal_hp);
    try std.testing.expect(legacy.consumable(.needle) == null);
    for (rules.stock) |id| {
        const item = rules.good(id).?;
        var members = [_]field.game_state.Member{hero()};
        var progress = field.game_state.Progress{ .money = item.price - 1, .party = &members };
        try std.testing.expectError(error.InsufficientFunds, progress.buyItem(rules, id, 0));
        try std.testing.expectEqual(@as(usize, 0), members[0].inventory.count());
        try std.testing.expectEqual(item.price - 1, progress.money);
        progress.money = item.price;
        try progress.buyItem(rules, id, 0);
        try std.testing.expectEqual(@as(u32, 0), progress.money);
        try std.testing.expectEqualDeep(field.items.Stack{ .id = id, .uses = item.uses }, members[0].inventory.slots[0].?);
        members[0].inventory.slots = @splat(.{ .id = id, .uses = item.uses });
        progress.money = item.price;
        try std.testing.expectError(error.InventoryFull, progress.buyItem(rules, id, 0));
        try std.testing.expectEqual(item.price, progress.money);
        members[0].status = .unconscious;
        members[0].hp = 0;
        try std.testing.expectError(if (rules.consumable(id) != null) error.InvalidTarget else error.InvalidItem, progress.useItem(rules, 0, 0, 0));
        try std.testing.expectEqual(item.uses, members[0].inventory.slots[0].?.uses);
        members[0].balloons = 4;
        try std.testing.expectError(error.InvalidMember, progress.validate());
    }
}

test "selling supported supplies pays the native bundle price and rejects unsafe transactions atomically" {
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    for (rules.value.consumables) |item| {
        for ([_]u16{ 1, item.uses }) |uses| {
            var members = [_]field.game_state.Member{hero()};
            members[0].inventory.slots[0] = .{ .id = item.id, .uses = uses };
            members[0].inventory.slots[1] = .{ .id = .bandanna, .uses = 0 };
            var progress = field.game_state.Progress{ .money = 123, .party = &members };
            if (uses != item.uses) {
                const before = members;
                try std.testing.expectError(error.CannotSell, progress.sellItem(rules.value, 0, 0));
                try std.testing.expectEqualDeep(before, members);
                try std.testing.expectEqual(@as(u32, 123), progress.money);
                continue;
            }
            try std.testing.expectEqual(item.price / 2, try progress.salePrice(rules.value, 0, 0));
            progress.money = std.math.maxInt(u32);
            const before = members;
            try std.testing.expectError(error.MoneyLimit, progress.sellItem(rules.value, 0, 0));
            try std.testing.expectEqualDeep(before, members);
            try std.testing.expectEqual(std.math.maxInt(u32), progress.money);
            progress.money = field.game_state.max_money - item.price / 2 + 1;
            try std.testing.expectError(error.MoneyLimit, progress.sellItem(rules.value, 0, 0));
            try std.testing.expectEqualDeep(before, members);
            progress.money = 123;
            try progress.sellItem(rules.value, 0, 0);
            try std.testing.expectEqual(123 + item.price / 2, progress.money);
            try std.testing.expectEqual(.bandanna, members[0].inventory.slots[0].?.id);
            try std.testing.expectError(error.CannotSell, progress.sellItem(rules.value, 0, 0));
            try std.testing.expectEqual(123 + item.price / 2, progress.money);
            try std.testing.expectEqual(@as(usize, 1), members[0].inventory.count());
            try std.testing.expectError(error.InvalidItem, progress.sellItem(rules.value, 0, 1));
        }
    }
}

test "Medicine agrees with original effect and consumption instructions" {
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    const Vector = struct { hp_before: u16, max_hp: u16, uses_before: u16, hp_after: u16, uses_after: u16, slots_after: usize };
    const vectors = try std.json.parseFromSlice([]Vector, allocator, @embedFile("fixtures/medicine.json"), .{});
    defer vectors.deinit();
    try std.testing.expectEqual(@as(usize, 24), vectors.value.len);
    for (vectors.value) |row| {
        var members = [_]field.game_state.Member{hero()};
        members[0].hp = row.hp_before;
        members[0].max_hp = row.max_hp;
        members[0].inventory.slots[0] = .{ .id = .medicine, .uses = row.uses_before };
        var progress = field.game_state.Progress{ .money = 350, .party = &members };
        if (row.hp_before == row.max_hp) {
            try std.testing.expectError(error.FullHealth, progress.useMedicine(rules.value, 0, 0, 0));
        } else try progress.useMedicine(rules.value, 0, 0, 0);
        try std.testing.expectEqual(row.hp_after, members[0].hp);
        try std.testing.expectEqual(row.slots_after, members[0].inventory.count());
        try std.testing.expectEqual(row.uses_after, if (members[0].inventory.slots[0]) |item| item.uses else 0);
        try std.testing.expectEqual(.poisoned, members[0].status);
    }
}

test "purchase is atomic for funds and capacity and item removal compacts slots" {
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members = [_]field.game_state.Member{ hero(), hero() };
    members[1].id = "friend";
    var progress = field.game_state.Progress{ .money = 99, .party = &members };
    try std.testing.expectError(error.InsufficientFunds, progress.buyMedicine(rules.value, 0));
    try std.testing.expectEqual(@as(usize, 0), members[0].inventory.count());
    try std.testing.expectEqual(@as(u32, 99), progress.money);
    progress.money = 1000;
    for (0..9) |_| try progress.buyMedicine(rules.value, 0);
    try std.testing.expectEqual(@as(u32, 100), progress.money);
    try std.testing.expectError(error.InventoryFull, progress.buyMedicine(rules.value, 0));
    try std.testing.expectEqual(@as(u32, 100), progress.money);
    try progress.buyMedicine(rules.value, 1);
    try std.testing.expectEqual(@as(u32, 0), progress.money);
    members[0].inventory.slots[0].?.uses = 1;
    try progress.useMedicine(rules.value, 0, 0, 1);
    try std.testing.expectEqual(@as(u16, 100), members[1].hp);
    try std.testing.expectEqual(@as(usize, 8), members[0].inventory.count());
    try std.testing.expectEqual(@as(u16, 6), members[0].inventory.slots[0].?.uses);
    try std.testing.expectError(error.FullHealth, progress.useMedicine(rules.value, 0, 0, 1));
    try std.testing.expectEqual(@as(u16, 6), members[0].inventory.slots[0].?.uses);
    members[1].status = .unconscious;
    try std.testing.expectError(error.InvalidTarget, progress.useMedicine(rules.value, 0, 0, 1));
    try std.testing.expectError(error.InvalidItem, progress.useMedicine(rules.value, 0, 8, 0));
}

test "item menu and shop confirm, cancel, freeze and consume once" {
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    const parsed = try field.load(allocator, @embedFile("fixtures/room.json"));
    defer parsed.deinit();
    var members = [_]field.game_state.Member{hero()};
    var game_progress: field.game_state.Progress = .{ .money = 350, .party = &members };
    var game = field.State.init(parsed.value, &game_progress);
    game.item_rules = rules.value;
    var menu = pause.State{ .phase = .shop };
    const action = pause.Input{ .field = .{ .action = true } };
    const cancel = pause.Input{ .field = .{ .cancel = true } };
    _ = menu.tick(parsed.value, &game, action);
    try std.testing.expectEqual(.buy_member, menu.phase);
    _ = menu.tick(parsed.value, &game, action);
    try std.testing.expectEqual(.confirm_buy, menu.phase);
    _ = menu.tick(parsed.value, &game, action);
    try std.testing.expectEqual(.buy_member, menu.phase);
    try std.testing.expectEqual(@as(u32, 350), game.progress.money);
    _ = menu.tick(parsed.value, &game, action);
    _ = menu.tick(parsed.value, &game, .{ .left = true });
    _ = menu.tick(parsed.value, &game, action);
    try std.testing.expectEqual(.shop_notice, menu.phase);
    try std.testing.expectEqual(@as(u32, 250), game.progress.money);
    for (0..20) |_| _ = menu.tick(parsed.value, &game, .{ .field = .{ .direction = .down } });
    try std.testing.expectEqual(@as(i32, 16), game.y);
    _ = menu.tick(parsed.value, &game, action);
    _ = menu.tick(parsed.value, &game, cancel);
    try std.testing.expectEqual(.closed, menu.phase);
    menu = .{ .phase = .root, .selected = .item };
    _ = menu.tick(parsed.value, &game, action);
    try std.testing.expectEqual(.items, menu.phase);
    _ = menu.tick(parsed.value, &game, action);
    try std.testing.expectEqual(.item_target, menu.phase);
    _ = menu.tick(parsed.value, &game, cancel);
    try std.testing.expectEqual(@as(u16, 6), members[0].inventory.slots[0].?.uses);
    _ = menu.tick(parsed.value, &game, action);
    _ = menu.tick(parsed.value, &game, action);
    try std.testing.expectEqual(.item_notice, menu.phase);
    try std.testing.expectEqual(@as(u16, 5), members[0].inventory.slots[0].?.uses);
    _ = menu.tick(parsed.value, &game, action);
    try std.testing.expectEqual(.items, menu.phase);
    _ = menu.tick(parsed.value, &game, action);
    _ = menu.tick(parsed.value, &game, action);
    try std.testing.expectEqualStrings("HP is full. No item was consumed.", menu.message);
    try std.testing.expectEqual(@as(u16, 5), members[0].inventory.slots[0].?.uses);
}

test "inventory save validates uses, gaps, version and restores independently" {
    const parsed = try field.load(allocator, @embedFile("fixtures/room.json"));
    defer parsed.deinit();
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    var members = [_]field.game_state.Member{hero()};
    var game_progress: field.game_state.Progress = .{ .money = 350, .party = &members };
    var game = field.State.init(parsed.value, &game_progress);
    game.item_rules = rules.value;
    try game.progress.buyMedicine(rules.value, 0);
    try game.progress.useMedicine(rules.value, 0, 0, 0);
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try saves.write(allocator, std.testing.io, dir.dir, parsed.value, game);
    members[0] = hero();
    const loaded = try saves.restore(allocator, std.testing.io, dir.dir, parsed.value, &game);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u32, 250), game.progress.money);
    try std.testing.expectEqual(@as(u16, 100), game.progress.party[0].hp);
    try std.testing.expectEqual(@as(u16, 5), game.progress.party[0].inventory.slots[0].?.uses);
    try std.testing.expect(game.item_rules != null);
    game.progress.party[0].inventory.slots[0].?.uses = 7;
    try std.testing.expectError(error.InvalidInventory, saves.Snapshot.capture(game, parsed.value));
    game.progress.party[0].inventory.slots[0].?.uses = 0;
    try std.testing.expectError(error.InvalidInventory, saves.Snapshot.capture(game, parsed.value));
    game.progress.party[0].inventory.slots[0] = null;
    game.progress.party[0].inventory.slots[1] = .{ .id = .medicine, .uses = 1 };
    try std.testing.expectError(error.InvalidInventory, saves.Snapshot.capture(game, parsed.value));
    try std.testing.expectError(error.MissingInventory, saves.decode(allocator,
        \\{"schema":"suikoden-save/3","room":"inn","x":16,"y":16,"facing":"down","money":350,"story":{"village_south_exit_reached":false},"party":[{"id":"hero"}]}
    , parsed.value));
}

test "version-three missing inventory slots cannot silently discard items" {
    const package = try field.load(allocator, @embedFile("fixtures/room.json"));
    defer package.deinit();
    try std.testing.expectError(error.MissingInventory, saves.decode(allocator,
        \\{"schema":"suikoden-save/3","room":"inn","x":8,"y":16,"facing":"up","money":173,"story":{"village_south_exit_reached":true},"party":[{"id":"hero","name":"Hero","hp":35,"max_hp":100,"status":"poisoned","rune_charges":[1,0,0,0],"max_rune_charges":[3,0,0,0],"inventory":{}}]}
    , package.value));
}

test "version-two saves load empty inventories and upgrade without losing story" {
    const package = try field.load(allocator, @embedFile("fixtures/room.json"));
    defer package.deinit();
    var members = [_]field.game_state.Member{hero()};
    const bytes =
        \\{"schema":"suikoden-save/2","room":"inn","x":8,"y":16,"facing":"up","money":173,"story":{"village_south_exit_reached":true},"party":[{"id":"hero","name":"Hero","hp":35,"max_hp":100,"status":"poisoned","rune_charges":[1,0,0,0],"max_rune_charges":[3,0,0,0]}]}
    ;
    const decoded = try saves.decode(allocator, bytes, package.value);
    defer decoded.deinit();
    var game_progress: field.game_state.Progress = .{ .money = 350, .party = &members };
    var game = field.State.init(package.value, &game_progress);
    try decoded.value.apply(package.value, &game);
    try std.testing.expectEqual(@as(usize, 0), game.progress.party[0].inventory.count());
    try std.testing.expectEqual(@as(u32, 173), game.progress.money);
    try std.testing.expect(game.progress.story.village_south_exit_reached);
    const upgraded = try saves.Snapshot.capture(game, package.value);
    try std.testing.expectEqualStrings("suikoden-save/3", upgraded.schema);
}

test "battle item tracks reject missing oversized and non-finite geometry" {
    const parsed = try field.items.load(allocator, field.items.json);
    defer parsed.deinit();
    var invalid = parsed.value;
    var definitions: [4]field.items.Consumable = undefined;
    @memcpy(&definitions, invalid.consumables);
    invalid.consumables = &definitions;
    definitions[0].battle = null;
    try std.testing.expectError(error.InvalidItems, invalid.validate());
    definitions[0] = parsed.value.consumables[0];
    var too_many: [9][3]f32 = @splat(.{ 0, 0, 0 });
    var frames = [_][]const [3]f32{&too_many};
    definitions[0].battle.?.particles = &frames;
    try std.testing.expectError(error.InvalidItems, invalid.validate());
    frames[0] = too_many[0..1];
    too_many[0][0] = std.math.nan(f32);
    try std.testing.expectError(error.InvalidItems, invalid.validate());
}

test "Incense is a reusable battle-only tool with validated party effect data" {
    const parsed = try field.items.load(allocator, field.items.json);
    defer parsed.deinit();
    const rules = parsed.value;
    const item = rules.consumable(.dragon_seal_incense).?;
    try std.testing.expect(item.partyWide());
    try std.testing.expectEqual(@as(u16, 0), item.uses);
    var members = [_]field.game_state.Member{hero()};
    members[0].hp = 1;
    members[0].inventory.slots[0] = .{ .id = .dragon_seal_incense, .uses = 0 };
    var progress = field.game_state.Progress{ .money = 123, .party = &members };
    const before = members;
    try progress.validate();
    try std.testing.expectError(error.BattleOnlyItem, progress.useItem(rules, 0, 0, 0));
    try std.testing.expectEqualDeep(before, members);
    try std.testing.expectError(error.CannotSell, progress.salePrice(rules, 0, 0));
    var invalid = rules;
    var reusable = [_]field.items.Consumable{item};
    invalid.battle_reusables = &reusable;
    reusable[0].uses = 1;
    try std.testing.expectError(error.InvalidItems, invalid.validate());
    reusable[0] = item;
    reusable[0].field_usable = true;
    try std.testing.expectError(error.InvalidItems, invalid.validate());
    reusable[0] = item;
    reusable[0].battle.?.targeting = .single;
    try std.testing.expectError(error.InvalidItems, invalid.validate());
    reusable[0] = item;
    reusable[0].battle.?.release_delay = 64;
    try std.testing.expectError(error.InvalidItems, invalid.validate());
    reusable[0] = item;
    invalid.schema = "suikoden-items/5";
    try std.testing.expectError(error.InvalidItems, invalid.validate());
    invalid.battle_reusables = &.{};
    invalid.automatic_revival = null;
    try invalid.validate();
}

test "Buddha is an automatic whole-slot item with a checked source profile" {
    const parsed = try field.items.load(std.testing.allocator, field.items.json);
    defer parsed.deinit();
    const rules = parsed.value;
    try std.testing.expectEqualStrings("suikoden-items/7", rules.schema);
    const spec = rules.automatic_revival.?;
    try std.testing.expectEqual(field.items.Id.sacrificial_buddha, spec.id);
    try std.testing.expectEqual(@as(u16, 0), spec.id.maxUses());
    try std.testing.expect(rules.consumable(spec.id) == null);
    try std.testing.expectEqual(@as(u32, 5000), rules.good(spec.id).?.price);
    var invalid = rules;
    invalid.automatic_revival.?.release_delay = 122;
    try std.testing.expectError(error.InvalidItems, invalid.validate());
    invalid = rules;
    invalid.automatic_revival = null;
    try std.testing.expectError(error.InvalidItems, invalid.validate());
    invalid = rules;
    invalid.automatic_revival.?.particle_plane_z = 1;
    try std.testing.expectError(error.InvalidItems, invalid.validate());
    var positions: [59][4][2]f32 = undefined;
    @memcpy(&positions, spec.particles);
    positions[0][0][0] = std.math.nan(f32);
    invalid = rules;
    invalid.automatic_revival.?.particles = &positions;
    try std.testing.expectError(error.InvalidItems, invalid.validate());
    var members = [_]field.game_state.Member{hero()};
    members[0].inventory.slots[0] = .{ .id = .sacrificial_buddha, .uses = 0 };
    var progress = field.game_state.Progress{ .money = 0, .party = &members };
    try progress.validate();
    const before = members;
    try std.testing.expectError(error.InvalidItem, progress.useItem(rules, 0, 0, 0));
    try std.testing.expectEqualDeep(before, members);
}

test "Incense field menus show the battle-only notice without target selection or consumption" {
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    const room = try field.load(allocator, @embedFile("fixtures/room.json"));
    defer room.deinit();
    var members = [_]field.game_state.Member{hero()};
    members[0].inventory.slots[0] = .{ .id = .dragon_seal_incense, .uses = 0 };
    var game_progress: field.game_state.Progress = .{ .money = 0, .party = &members };
    var game = field.State.init(room.value, &game_progress);
    game.item_rules = rules.value;
    const before = members;
    for ([_]pause.Phase{ .items, .item_action }) |phase| {
        var menu = pause.State{ .phase = phase };
        _ = menu.tick(room.value, &game, .{ .field = .{ .action = true } });
        try std.testing.expectEqual(pause.Phase.item_notice, menu.phase);
        try std.testing.expect(std.mem.indexOf(u8, menu.message, "only be used in battle") != null);
        try std.testing.expectEqualDeep(before, members);
    }
}

test "Buddha menus explain automatic revival without queuing manual use" {
    const rules = try field.items.load(allocator, field.items.json);
    defer rules.deinit();
    const room = try field.load(allocator, @embedFile("fixtures/room.json"));
    defer room.deinit();
    var members = [_]field.game_state.Member{hero()};
    members[0].inventory.slots[0] = .{ .id = .sacrificial_buddha, .uses = 0 };
    var game_progress: field.game_state.Progress = .{ .money = 0, .party = &members };
    var game = field.State.init(room.value, &game_progress);
    game.item_rules = rules.value;
    const before = members;
    for ([_]pause.Phase{ .items, .item_action }) |phase| {
        var menu = pause.State{ .phase = phase };
        _ = menu.tick(room.value, &game, .{ .field = .{ .action = true } });
        try std.testing.expectEqual(pause.Phase.item_notice, menu.phase);
        try std.testing.expect(std.mem.indexOf(u8, menu.message, "automatically") != null);
        try std.testing.expectEqualDeep(before, members);
    }
}
