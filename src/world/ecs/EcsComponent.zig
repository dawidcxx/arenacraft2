const domain = @import("domain");
const ecs = @import("ecs");
const stdx = @import("stdx");

const Arc = stdx.Arc;
const Entity = ecs.Entity;
const Index = ecs.Entity.Index;
const Session = domain.Session;

pub const Guid = struct { value: domain.ObjectGuid };

pub const AccountId = struct { id: u64 };
pub const Position = struct { x: f32, y: f32, z: f32 };
pub const Orientation = struct { value: f32 };

pub const Appearance = struct {
    race_id: domain.Race,
    class_id: domain.Class,
    gender: u8,
    skin: u8,
    face: u8,
    hair_style: u8,
    hair_color: u8,
    facial_hair: u8,
};

/// Mirrors domain.Character.visible_items (+ per-slot instance guids).
pub const VisibleItems = struct { entries: [19]u32, guids: [19]u64 = .{0} ** 19 };
pub const Level = struct { value: u8 };
pub const Stats = struct { derived: domain.character_stats.DerivedStats };

// Spell related components
pub const SpellName = struct { name: []const u8 };
pub const CastTime = struct { elapsed: u32 };
pub const CastProjectileTime = struct { elapsed: u32 };
pub const PowerCost = struct { cost: u32 };
pub const SpellTarget = struct { target: Entity };
pub const SpellReady = struct {};

// @root
pub const Player = struct { session: *Session };
// @root
pub const SpellCast = struct { spell_id: u32, school: domain.SpellDef.School, caster: Entity, effects: []const domain.SpellDef.Effect };
