const stdx = @import("stdx");

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

    /// Persistent effect granted by an aura: it modifies its owner for as
    /// long as the aura lives. Effects are static spell data — auras share
    /// the granting spell's slice and never copy it.
    pub const AuraEffect = union(enum) {
        pub const MovementSpeedMod = struct { pct: i16 };
        pub const PeriodicDamage = struct { interval_ms: u24, min: u32, max: u32 };
        pub const MaxHealthMod = struct { amount: i32 };
        pub const Immune = struct { school_mask: u8 };

        /// Signed percentage: +30 = 30% faster, -40 = 40% slower.
        movement_speed_mod: MovementSpeedMod,
        /// Independent damage tick on the aura's owner; every aura ticks alone.
        periodic_damage: PeriodicDamage,
        /// Signed flat amount added to max health.
        max_health_mod: MaxHealthMod,
        /// Hostile spells of a matching school are rejected while active.
        /// Bit per School (1 << school), i.e. the wire SpellSchoolMask.
        immune: Immune,

        /// Foldable stat category this effect contributes to, or null for
        /// non-stat effects (periodic ticks, immunity flags).
        pub fn category(self: AuraEffect) ?Category {
            return switch (self) {
                .movement_speed_mod => .movement_speed,
                .max_health_mod => .max_health,
                .periodic_damage, .immune => null,
            };
        }
    };

    pub const Effect = union(enum) {
        damage: struct { min: u32, max: u32 },
        direct_melee_damage: struct { min: u32, max: u32 },
        /// Grants an aura compressing `effects` for `duration_ms`
        /// (0 = permanent).
        apply_aura: struct { duration_ms: u24, effects: []const AuraEffect },
    };

    /// Stat categories foldable from a unit's active aura effects. The
    /// stacking rule belongs to the category (world/ecs/AuraQuery.zig):
    /// greatest effect wins within a sign class for speed, plain sum for
    /// health. Ids number from 1 for stdx.Mask.
    pub const Category = enum(u8) {
        movement_speed = 1,
        max_health = 2,

        pub const Mask = stdx.Mask(@This());
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
