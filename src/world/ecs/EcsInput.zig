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
pub const PlayerCastSpell = struct {
    account_id: u64,
    packet: protocol.spell.CastSpellClient,
};

pub const LocalChat = struct { account_id: u64, packet: protocol.chat.MessageChatClient };

pub const Input = union(enum) {
    player_join: struct {
        player: *domain.Player,
    },
    player_leave: struct {
        account_id: u64,
    },
    player_move: PlayerMove,
    player_spell_cast: PlayerCastSpell,
    local_chat: LocalChat,
};

pub const EcsEventType = enum {
    player_joined,
    player_left,
    spell_cast_fired,
    aura_apply_request,
};

pub const EcsEvent = union(EcsEventType) {
    player_joined: struct { player: ecs.Entity },
    player_left: struct { player: ecs.Entity, guid: domain.ObjectGuid },
    spell_cast_fired: struct { spell_cast: ecs.Entity },
    aura_apply_request: struct { aura: ecs.Entity },
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
