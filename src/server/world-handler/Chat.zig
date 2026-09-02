const std = @import("std");
const domain = @import("domain");
const protocol = @import("protocol");
const world = @import("world");

pub fn handleMessageChat(
    io: std.Io,
    player: *domain.Player,
    payload: []const u8,
) !void {
    const packet = try protocol.chat.MessageChatClient.unmarshal(payload);
    log.debug("Received chat message (account_id={}, type=0x{x}, language={}, length={})", .{
        player.account_id,
        @intFromEnum(packet.chat_type),
        packet.language,
        packet.message.len,
    });

    if (packet.chat_type != .say and packet.chat_type != .yell) {
        log.warn("Chat message type is not implemented (account_id={}, type=0x{x})", .{
            player.account_id,
            @intFromEnum(packet.chat_type),
        });
        return;
    }

    const active_map_reference = player.active_map_reference orelse return;
    const map: *world.MapInstance = @ptrCast(@alignCast(active_map_reference));

    map.sendChatAsync(io, .{
        .account_id = player.account_id,
        .packet = packet,
    });
}

const log = std.log.scoped(.handler_chat);
