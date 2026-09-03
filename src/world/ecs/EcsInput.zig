const domain = @import("domain");
const ecs = @import("ecs");
const Arc = @import("stdx").Arc;

const protocol = @import("protocol");

/// Per-tick commands for a map's simulation. Pure game data: transport-level
/// concerns (signals, queues) never cross the MapInstance boundary.
pub const PlayerMove = struct {
    account_id: u64,
    packet: protocol.movement.AllMovementPackets,
};

pub const LocalChat = struct { account_id: u64, packet: protocol.chat.MessageChatClient };

pub const SpellCast = struct { account_id: u64, packet: protocol.spell.CastSpellClient };
pub const AttackSwing = struct { account_id: u64, packet: protocol.spell.AttackSwingClient };
pub const AttackStop = struct { account_id: u64 };
pub const CancelCast = struct { account_id: u64, packet: protocol.spell.CancelCastClient };

pub const Input = union(enum) {
    player_join: struct {
        player: *domain.Player,
    },
    player_leave: struct {
        account_id: u64,
    },
    player_move: PlayerMove,
    local_chat: LocalChat,
    spell_cast: SpellCast,
    attack_swing: AttackSwing,
    attack_stop: AttackStop,
    cancel_cast: CancelCast,
};

pub const EcsEventType = enum {
    player_joined,
    player_left,
};

pub const EcsEvent = union(EcsEventType) {
    player_joined: struct { player: ecs.Entity },
    player_left: struct { player: ecs.Entity, guid: domain.ObjectGuid },
};

pub const Output = union(enum) {
    sendTo: struct {
        opcode: u32,
        data: Arc([]const u8),
        recv: ecs.Entity,
    },
    broadcast: struct {
        opcode: u32,
        data: Arc([]const u8),
        sender: ecs.Entity,
        ignore_sender: bool,
    },
};
