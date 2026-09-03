const game_data = @import("game_data");
const items = @import("Items.zig");
const ObjectGuid = @import("ObjectGuid.zig").ObjectGuid;

pub const EquipmentSlot = enum(u8) {
    head = 0,
    neck = 1,
    shoulders = 2,
    body = 3,
    chest = 4,
    waist = 5,
    legs = 6,
    feet = 7,
    wrists = 8,
    hands = 9,
    finger1 = 10,
    finger2 = 11,
    trinket1 = 12,
    trinket2 = 13,
    back = 14,
    main_hand = 15,
    off_hand = 16,
    ranged = 17,
    tabard = 18,

    pub const count: usize = 19;
};

pub const StarterItem = struct {
    slot: EquipmentSlot,
    item_entry: u32,
};

/// Starter outfit given to every new character, built at comptime from
/// game_data/starter_suit.json. An invalid slot number or duplicate slot
/// entry fails the build.
pub const default_suit: [game_data.starter_suit.rows.len]StarterItem = blk: {
    @setEvalBranchQuota(10_000);
    var suit: [game_data.starter_suit.rows.len]StarterItem = undefined;
    for (game_data.starter_suit.rows, 0..) |row, i| {
        suit[i] = .{
            .slot = @enumFromInt(@as(u8, @intCast(row.slot))),
            .item_entry = @intCast(row.item_entry),
        };
    }
    break :blk suit;
};

/// Deterministic item instance guid for an equipped slot, derived from the
/// owning character and the slot index. INV_SLOT_HEAD is an owner-private
/// field, so the guid only has to be unique within one character and stay
/// stable across logins.
pub fn equippedInstanceGuid(character_guid: ObjectGuid, slot: u8) ObjectGuid {
    const character_low: u64 = character_guid.playerLow() orelse 0;
    const low: u32 = @truncate(character_low << 5 | slot);
    return ObjectGuid.item(low);
}

test "default suit resolves to known items in unique slots" {
    const std = @import("std");

    var seen = [_]bool{false} ** EquipmentSlot.count;
    for (default_suit) |starter| {
        try std.testing.expect(!seen[@intFromEnum(starter.slot)]);
        seen[@intFromEnum(starter.slot)] = true;
        _ = items.findItem(starter.item_entry) orelse return error.UnknownSuitItem;
    }
}

test "equipped instance guids are unique per slot and stable" {
    const std = @import("std");

    const character = ObjectGuid.player(1);
    var guid_a: u64 = 0;
    var guid_b: u64 = 0;
    var seen = std.AutoHashMap(u64, void).init(std.testing.allocator);
    defer seen.deinit();

    for (0..EquipmentSlot.count) |slot| {
        const guid = equippedInstanceGuid(character, @intCast(slot)).valueOf();
        try seen.put(guid, {});
        if (slot == 4) guid_a = guid;
        if (slot == 6) guid_b = guid;
    }
    try std.testing.expectEqual(seen.count(), EquipmentSlot.count);
    try std.testing.expect(guid_a != guid_b);
    // Same character + slot => same guid on the next login.
    try std.testing.expectEqual(guid_a, equippedInstanceGuid(character, 4).valueOf());
    // Distinct characters never collide on the same slot.
    try std.testing.expect(guid_a != equippedInstanceGuid(ObjectGuid.player(2), 4).valueOf());
}
