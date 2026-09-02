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

pub const default_suit = [_]StarterItem{
    .{ .slot = .chest, .item_entry = 6834 },
    .{ .slot = .legs, .item_entry = 6835 },
    .{ .slot = .feet, .item_entry = 6836 },
};

test "default suit fits within equipment slots and resolves to known items" {
    const std = @import("std");
    const items = @import("Items.zig");

    for (default_suit) |starter| {
        try std.testing.expect(@intFromEnum(starter.slot) < EquipmentSlot.count);
        _ = items.findItem(starter.item_entry) orelse return error.UnknownSuitItem;
    }
}
