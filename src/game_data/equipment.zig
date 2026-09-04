//! Starter outfit lookup over the game_data_db/starter_suit.json rows.
//! An invalid slot number or duplicate slot entry fails the build.

const db = @import("game_data_db");
const domain = @import("domain");

/// Starter outfit given to every new character, built at comptime.
pub const default_suit: [db.starter_suit.rows.len]domain.equipment.StarterItem = blk: {
    @setEvalBranchQuota(10_000);
    var suit: [db.starter_suit.rows.len]domain.equipment.StarterItem = undefined;
    for (db.starter_suit.rows, 0..) |row, i| {
        suit[i] = .{
            .slot = @enumFromInt(@as(u8, @intCast(row.slot))),
            .item_entry = @intCast(row.item_entry),
        };
    }
    break :blk suit;
};

test "default suit resolves to known items in unique slots" {
    const std = @import("std");
    const items = @import("items.zig");

    var seen = [_]bool{false} ** domain.equipment.EquipmentSlot.count;
    for (default_suit) |starter| {
        try std.testing.expect(!seen[@intFromEnum(starter.slot)]);
        seen[@intFromEnum(starter.slot)] = true;
        _ = items.findItem(starter.item_entry) orelse return error.UnknownSuitItem;
    }
}
