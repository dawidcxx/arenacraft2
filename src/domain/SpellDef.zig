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

    /// Reduces the target's movement speed by `pct` percent for `duration` ms.
    pub const MovementSlow = struct { duration: u24, pct: u8 };

    pub const Effect = union(enum) {
        damage: struct { min: u32, max: u32 },
        movement_slow: MovementSlow,
        direct_melee_damage: struct { min: u32, max: u32 },
    };

    spell_id: u32,
    name: []const u8,
    school: School,

    cast_time_ms: ?u32, //       null = instant
    projectile_speed: ?u32, //   null = no travel phase, connects on cast
    needs_target: bool, //       default = false
    range_yards: ?u32, //        null = infinite range
    power_cost: u32, //          0 = free
    effects: []const Effect,
};
