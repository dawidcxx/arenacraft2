//! WoW 3.3.5a playable races (ChrRaces.dbc), plus the race restriction
//! bitmask (see Mask). Goblin (9) is not playable in this build.

const std = @import("std");
const stdx = @import("stdx");

pub const Race = enum(u8) {
    human = 1,
    orc = 2,
    dwarf = 3,
    night_elf = 4,
    undead = 5,
    tauren = 6,
    gnome = 7,
    troll = 8,
    blood_elf = 10,
    draenei = 11,

    /// Race restriction bitmask: one bit per race, 0 = all. Race-scopes
    /// data rows (login spell grants today; start locations, racial
    /// traits later).
    pub const Mask = stdx.Mask(@This());
};

// Generic mask behavior (wildcard, covers, fromJson) is covered by the
// stdx.Mask tests; these pin the race-domain facts.

test "race bits follow the CREATURE_TYPE_PERM id layout" {
    const t = std.testing;

    try t.expectEqual(@as(u32, 0x1), Race.Mask.of(.human).value);
    try t.expectEqual(@as(u32, 0x200), Race.Mask.of(.blood_elf).value);
    try t.expectEqual(@as(u32, 0x400), Race.Mask.of(.draenei).value);
}

test "playable unions every playable race" {
    const t = std.testing;

    // Human..Troll (0xFF) + BloodElf (0x200) + Draenei (0x400); no Goblin
    // (0x100) in 3.3.5a.
    try t.expectEqual(@as(u32, 0x0000_06FF), Race.Mask.playable.value);
}
