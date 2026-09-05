//! Plain spell definition type. The entry lookup over the JSON rows lives
//! in the game_data module.

pub const SpellDef = struct {
    pub const Effect = enum(u8) {
        none = 0,
        damage = 1,
        heal = 2,
    };

    /// 3.3.5a spell school masks (SPELL_SCHOOL_MASK_*).
    pub const school_physical: u8 = 0x01;
    pub const school_holy: u8 = 0x02;
    pub const school_frost: u8 = 0x10;

    entry: u32,
    name: []const u8,
    /// SpellSchoolMask bitmask (see school_* constants).
    school: u8,
    /// 0 = instant. The client renders the cast bar from its own Spell.dbc;
    /// this drives the server-side cast delay.
    cast_time_ms: u32,
    /// Max cast distance in yards.
    range_yards: u32,
    /// What the spell does on impact; the min/max pair is the effect's
    /// magnitude (damage dealt or health restored).
    effect: Effect,
    min_effect: u32,
    max_effect: u32,
    /// Mana cost as percent of the caster's base mana pool (0 = free).
    mana_cost_pct_base: u32,
};
