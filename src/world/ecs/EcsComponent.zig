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

/// Mirrors domain.Character.visible_items.
pub const VisibleItems = struct { entries: [19]u32 };
pub const Level = struct { value: u8 };

/// Transient outbound packet awaiting delivery. The entity is destroyed by
/// OutboundPacketSystem once every recipient got the body.
pub const Packet = struct { data: Arc([]const u8), opcode: u32 };
pub const Broadcast = struct { sender: Index, ignore_sender: bool };
pub const SendTo = struct { to: Entity };

pub const ObjectUpdateBlock = struct {} ;
