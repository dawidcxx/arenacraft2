pub const SpellDef = struct {
    pub const School = enum(u8) {
        normal = 0,
        holy = 1,
        fire = 2,
        nature = 3,
        frost = 4,
        shadow = 5,
        arcane = 6,
    };

    entry: u32,
    name: []const u8,

    school: School,

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
