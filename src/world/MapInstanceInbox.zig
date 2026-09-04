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

pub const SpellCast = struct {
    account_id: u64,
    packet: protocol.spell.CastSpellClient,
};

pub const AttackSwing = struct {
    account_id: u64,
    packet: protocol.spell.AttackSwingClient,
};

pub const AttackStop = struct {
    account_id: u64,
};

pub const CancelCast = struct {
    account_id: u64,
    packet: protocol.spell.CancelCastClient,
};

pub const SetSheathed = struct {
    account_id: u64,
    packet: protocol.spell.SetSheathedClient,
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
    spell_cast: SpellCast,
    attack_swing: AttackSwing,
    attack_stop: AttackStop,
    cancel_cast: CancelCast,
    set_sheathed: SetSheathed,
};
