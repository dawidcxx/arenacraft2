const std = @import("std");
const game_data = @import("game_data");

/// 3.3.5a ItemModType ids for the stats our game data carries; the item
/// query response lists stat bonuses with these type ids.
pub const stamina_stat_id: u32 = 7;
pub const intellect_stat_id: u32 = 5;

pub const ItemDef = struct {
    entry: u32,
    display_id: u32,
    inventory_type: u8,
    name: []const u8,
    /// ItemClass.dbc id (armor, weapon, ...).
    item_class: u8,
    /// ItemSubClass.dbc id within the class (cloth, leather, ...).
    item_subclass: u8,
    /// Quality tier the client uses for the name color (0 poor .. 5 orange).
    quality: u8,
    stamina: u32,
    intellect: u32,
    armor: u32,
};

pub fn findItem(entry: u32) ?ItemDef {
    const idx = std.sort.binarySearch(
        ItemDef,
        &sorted_items,
        LookupCtx{ .key = entry },
        compareEntry,
    ) orelse return null;

    return sorted_items[idx];
}

fn compareEntry(ctx: LookupCtx, item: ItemDef) std.math.Order {
    return std.math.order(ctx.key, item.entry);
}

const sorted_items: [game_data.items.rows.len]ItemDef = blk: {
    @setEvalBranchQuota(20_000);

    var arr: [game_data.items.rows.len]ItemDef = undefined;
    for (game_data.items.rows, 0..) |row, i| {
        arr[i] = .{
            .entry = @intCast(row.entry),
            .display_id = @intCast(row.display_id),
            .inventory_type = @intCast(row.inventory_type),
            .name = row.name,
            .item_class = @intCast(row.item_class),
            .item_subclass = @intCast(row.item_subclass),
            .quality = @intCast(row.quality),
            .stamina = @intCast(row.stamina),
            .intellect = @intCast(row.intellect),
            .armor = @intCast(row.armor),
        };
    }

    std.mem.sort(ItemDef, &arr, {}, struct {
        fn lessThan(_: void, a: ItemDef, b: ItemDef) bool {
            return a.entry < b.entry;
        }
    }.lessThan);

    // The binary search only yields unambiguous results on strictly
    // increasing entries; duplicates would be a game-data authoring bug.
    for (1..arr.len) |i| {
        if (arr[i].entry == arr[i - 1].entry)
            @compileError(std.fmt.comptimePrint("duplicate item entry in game_data/items.json: {d}", .{arr[i].entry}));
    }

    break :blk arr;
};

const LookupCtx = struct { key: u32 };

test "generated item defs resolve known entries" {
    const t = std.testing;

    const tuxedo = findItem(6834) orelse return error.MissingItem;
    try t.expectEqual(@as(u32, 13116), tuxedo.display_id);
    try t.expectEqual(@as(u8, 5), tuxedo.inventory_type);
    try t.expectEqual(@as(u8, 4), tuxedo.item_class);
    try t.expectEqual(@as(u8, 1), tuxedo.item_subclass);
    try t.expectEqual(@as(u8, 1), tuxedo.quality);
    try t.expectEqual(@as(u32, 12), tuxedo.stamina);
    try t.expectEqual(@as(u32, 8), tuxedo.intellect);
    try t.expectEqual(@as(u32, 150), tuxedo.armor);

    const pants = findItem(6835) orelse return error.MissingItem;
    try t.expectEqual(@as(u32, 13117), pants.display_id);
    try t.expectEqual(@as(u8, 7), pants.inventory_type);
    try t.expectEqual(@as(u32, 10), pants.stamina);
    try t.expectEqual(@as(u32, 6), pants.intellect);
    try t.expectEqual(@as(u32, 120), pants.armor);

    const shoes = findItem(6836) orelse return error.MissingItem;
    try t.expectEqual(@as(u32, 16368), shoes.display_id);
    try t.expectEqual(@as(u8, 8), shoes.inventory_type);
    try t.expectEqual(@as(u32, 8), shoes.stamina);
    try t.expectEqual(@as(u32, 4), shoes.intellect);
    try t.expectEqual(@as(u32, 90), shoes.armor);

    try t.expect(findItem(0) == null);
}
