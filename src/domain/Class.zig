//! WoW 3.3.5a playable classes (ChrClasses.dbc), plus the class
//! restriction bitmask (see Mask).

const std = @import("std");
const stdx = @import("stdx");
const PowerTypeId = @import("PowerTypeId.zig").PowerTypeId;

pub const Class = enum(u8) {
    warrior = 1,
    paladin = 2,
    hunter = 3,
    rogue = 4,
    priest = 5,
    death_knight = 6,
    shaman = 7,
    mage = 8,
    warlock = 9,
    druid = 11,

    pub fn powerTypeId(self: Class) PowerTypeId {
        return switch (self) {
            .warrior => .rage,
            .rogue => .energy,
            .death_knight => .runic_power,
            else => .mana,
        };
    }

    /// Class restriction bitmask: one bit per class, 0 = all. Class-scopes
    /// data rows (login spell grants today; talent/feature gates later).
    pub const Mask = stdx.Mask(@This());
};

// Generic mask behavior (wildcard, covers, fromJson) is covered by the
// stdx.Mask tests; these pin the class-domain facts.

test "class bits follow the ChrClasses id layout" {
    const t = std.testing;

    try t.expectEqual(@as(u32, 0x1), Class.Mask.of(.warrior).value);
    try t.expectEqual(@as(u32, 0x80), Class.Mask.of(.mage).value);
    try t.expectEqual(@as(u32, 0x400), Class.Mask.of(.druid).value);
}

test "playable unions every playable class" {
    const t = std.testing;

    // Warrior..Warlock (0x1FF) + Druid (0x400); no Monk (0x200) in 3.3.5a.
    try t.expectEqual(@as(u32, 0x0000_05FF), Class.Mask.playable.value);
}
