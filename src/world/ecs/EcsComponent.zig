const domain = @import("domain");
const ecs = @import("ecs");
const stdx = @import("stdx");

const Arc = stdx.Arc;
const Entity = ecs.Entity;
const Index = ecs.Entity.Index;
const Session = domain.Session;

pub const Player = struct { session: *Session };
pub const AccountId = struct { id: u64 };
pub const Guid = struct { value: domain.ObjectGuid };

pub const Position = struct { x: f32, y: f32, z: f32 };
pub const Orientation = struct { value: f32 };

pub const Appearance = struct {
    race_id: u8,
    class_id: domain.ClassId,
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
/// Mirrors domain.Character.derived: stats computed from equipped items.
pub const Stats = struct { derived: domain.character_stats.DerivedStats };

/// Current hit points. Damage subtracts here; the wire health field is
/// refreshed through a VALUES update block on every change.
pub const Health = struct { current: u32 };

/// Live spell cast (spell entity). Spawned when a cast starts, ticked by
/// SpellSystem until finish_ms, then destroyed after effects apply.
pub const SpellCast = struct {
    caster: Entity,
    target: Entity,
    spell_entry: u32,
    /// Echoed back in SpellStart/Go/Failed so the client matches packets
    /// to the cast it initiated.
    cast_count: u8,
    finish_ms: u64,
};

/// Melee auto attack state on the attacker entity. MeleeSystem fires a
/// swing whenever time passes next_swing_ms.
pub const Attacking = struct {
    target: Entity,
    next_swing_ms: u64,
};

/// Applied aura (spell entity). Spawned on spell hit; AuraSystem removes
/// it at expire_ms and restores the movement speed it modified.
pub const Aura = struct {
    target: Entity,
    /// Caster entity handle; may become invalid before the aura expires.
    caster: Entity,
    /// Original caster guid for the aura update wire packet.
    caster_guid: u64,
    caster_level: u8,
    spell_entry: u32,
    /// Aura slot on the target (u8 slot in SMSG_AURA_UPDATE).
    slot: u8,
    apply_ms: u64,
    expire_ms: u64,
    max_duration_ms: u32,
    /// Movement speed reduction in percent while active.
    movement_slow_pct: u32,
};

/// Transient outbound packet awaiting delivery. The entity is destroyed by
/// OutboundPacketSystem once every recipient got the body.
pub const Packet = struct { data: Arc([]const u8), opcode: u32 };
pub const Broadcast = struct { sender: Index, ignore_sender: bool };
pub const SendTo = struct { to: Entity };

pub const ObjectUpdateBlock = struct {} ;
