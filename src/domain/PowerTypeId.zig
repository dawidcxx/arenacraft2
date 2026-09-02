/// WoW 3.3.5a power types (Powers.dbc):
/// 0=mana 1=rage 2=focus 3=energy 4=happiness 5=runes 6=runic power.
pub const PowerTypeId = enum(u8) {
    mana = 0,
    rage = 1,
    focus = 2,
    energy = 3,
    happiness = 4,
    runes = 5,
    runic_power = 6,

    pub fn valueOf(self: PowerTypeId) u8 {
        return @intFromEnum(self);
    }
};
