const PowerTypeId = @import("PowerTypeId.zig").PowerTypeId;

/// WoW 3.3.5a playable class IDs (ChrClasses.dbc).
pub const ClassId = enum(u8) {
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

    pub fn powerTypeId(self: ClassId) PowerTypeId {
        return switch (self) {
            .warrior => .rage,
            .rogue => .energy,
            .death_knight => .runic_power,
            else => .mana,
        };
    }
};
