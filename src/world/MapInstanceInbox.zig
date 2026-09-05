const std = @import("std");

const domain = @import("domain");
const protocol = @import("protocol");

pub const PlayerMove = struct {
    packet: protocol.movement.AllMovementPackets,
    account_id: u64,
};

pub const Chat = struct {
    account_id: u64,
    packet: protocol.chat.MessageChatClient,
};

pub const CastSpell = struct {
    account_id: u64,
    packet: protocol.spell.CastSpellClient,
};

pub const CancelCast = struct {
    account_id: u64,
    packet: protocol.spell.CancelCastClient,
};

pub const InboxMsg = union(enum) {
    player_join: struct {
        signal: *std.Io.Semaphore,
        player: *domain.Player,
    },
    player_leave: struct {
        signal: *std.Io.Semaphore,
        account_id: u64,
    },
    player_move: PlayerMove,
    chat: Chat,
    cast_spell: CastSpell,
    cancel_cast: CancelCast,
};
