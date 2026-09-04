//! Plain spell definition type. The entry lookup over the JSON rows lives
//! in the game_data module.

pub const SpellDef = struct {
    /// 3.3.5a spell school masks (SPELL_SCHOOL_MASK_*).
    pub const school_physical: u8 = 0x01;
    pub const school_frost: u8 = 0x10;

    entry: u32,
    name: []const u8,
    /// SpellSchoolMask bitmask (see school_* constants).
    school: u8,
    /// 0 = instant. The client renders the cast bar from its own Spell.dbc;
    /// this drives the server-side cast delay.
    cast_time_ms: u32,
    /// Max cast/attack distance in yards.
    range_yards: u32,
    min_damage: u32,
    max_damage: u32,
    /// Movement speed reduction on hit, percent (0 = no aura effect).
    movement_slow_pct: u32,
    /// How long the aura entity lives (0 = no aura).
    aura_duration_ms: u32,
    /// Auto attack spells are driven by CMSG_ATTACKSWING, not the cast pipeline.
    is_melee: bool,
};
