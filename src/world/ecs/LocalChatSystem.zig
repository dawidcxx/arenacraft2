const std = @import("std");
const domain = @import("domain");
const protocol = @import("protocol");

const component = @import("EcsComponent.zig");
const EcsInput = @import("EcsInput.zig");
const MapEcs = @import("MapEcs.zig").MapEcs;

pub fn run(map_ecs: *MapEcs, chat: EcsInput.LocalChat) !void {
    const sender = map_ecs.findPlayer(chat.account_id) orelse {
        log.warn("Local chat from player not on this map (account_id={})", .{chat.account_id});
        return;
    };

    const guid = map_ecs.registry.getConst(component.Guid, sender).value;
    const language = switch (chat.packet.chat_type) {
        .say, .yell => domain.races.default_language_id,
        else => chat.packet.language,
    };

    try map_ecs.broadcast(
        .{ sender, .{ .ignore_sender = false } },
        protocol.chat.MessageChatServer{
            .chat_type = chat.packet.chat_type,
            .language = language,
            .sender_guid = guid,
            .receiver_guid = domain.ObjectGuid.empty,
            .message = chat.packet.message,
        },
    );
}

const log = std.log.scoped(.local_chat_system);
