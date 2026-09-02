const std = @import("std");
const game_data = @import("game_data");

pub const ItemDef = struct {
    entry: u32,
    display_id: u32,
    inventory_type: u8,
    name: []const u8,
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
        };
    }

    std.mem.sort(ItemDef, &arr, {}, struct {
        fn lessThan(_: void, a: ItemDef, b: ItemDef) bool {
            return a.entry < b.entry;
        }
    }.lessThan);

    break :blk arr;
};

const LookupCtx = struct { key: u32 };

test "generated item defs resolve known entries" {
    const t = std.testing;

    const tuxedo = findItem(6834) orelse return error.MissingItem;
    try t.expectEqual(@as(u32, 13116), tuxedo.display_id);
    try t.expectEqual(@as(u8, 5), tuxedo.inventory_type);

    const pants = findItem(6835) orelse return error.MissingItem;
    try t.expectEqual(@as(u32, 13117), pants.display_id);
    try t.expectEqual(@as(u8, 7), pants.inventory_type);

    const shoes = findItem(6836) orelse return error.MissingItem;
    try t.expectEqual(@as(u32, 16368), shoes.display_id);
    try t.expectEqual(@as(u8, 8), shoes.inventory_type);

    try t.expect(findItem(0) == null);
}
