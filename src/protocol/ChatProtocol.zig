const std = @import("std");
const ProtocolError = @import("./ProtocolError.zig").ProtocolErrorSet;
const utils = @import("./ProtocolUtils.zig");
const ObjectGuid = @import("domain").ObjectGuid;

pub const ChatType = enum(u32) {
    say = 0x01,
    yell = 0x06,
    _,
};

pub const MessageChatClient = struct {
    chat_type: ChatType,
    language: u32,
    message: MessageText,

    pub fn unmarshal(bytes: []const u8) ProtocolError!MessageChatClient {
        if (bytes.len < 8) return ProtocolError.InvalidMessage;

        const chat_type = utils.readU32LE(bytes, 0) catch return ProtocolError.InvalidMessage;
        const message = utils.readCString(bytes, 8) catch return ProtocolError.InvalidMessage;
        if (message.len == 0 or message.len > MessageText.max_len) return ProtocolError.InvalidMessage;

        return .{
            .chat_type = @as(ChatType, @enumFromInt(chat_type)),
            .language = utils.readU32LE(bytes, 4) catch return ProtocolError.InvalidMessage,
            .message = MessageText.fromSlice(message) catch return ProtocolError.InvalidMessage,
        };
    }
};

pub const MessageText = struct {
    pub const max_len: usize = 255;

    bytes: [max_len]u8 = undefined,
    len: u8 = 0,

    pub fn fromSlice(value: []const u8) !MessageText {
        if (value.len > max_len) return error.MessageTooLong;
        var result = MessageText{};
        result.len = @intCast(value.len);
        @memcpy(result.bytes[0..value.len], value);
        return result;
    }

    pub fn slice(self: *const MessageText) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const MessageChatServer = struct {
    pub const opcode: @import("./WorldProtocol.zig").Opcode = .smsg_messagechat;

    chat_type: ChatType,
    language: u32,
    sender_guid: ObjectGuid,
    receiver_guid: ObjectGuid,
    message: MessageText,

    pub fn marshal(self: MessageChatServer, allocator: std.mem.Allocator) ![]u8 {
        const total_len: usize = 1 + 4 + 8 + 4 + 8 + 4 + @as(usize, self.message.len) + 1 + 1;
        const buf = try allocator.alloc(u8, total_len);
        var offset: usize = 0;
        buf[offset] = @intCast(@intFromEnum(self.chat_type));
        offset += 1;
        utils.writeU32LE(buf, offset, @bitCast(self.language));
        offset += 4;
        utils.writeU64LE(buf, offset, self.sender_guid.valueOf());
        offset += 8;
        utils.writeU32LE(buf, offset, 0);
        offset += 4;
        utils.writeU64LE(buf, offset, self.receiver_guid.valueOf());
        offset += 8;
        utils.writeU32LE(buf, offset, @as(u32, self.message.len) + 1);
        offset += 4;
        @memcpy(buf[offset..][0..self.message.len], self.message.slice());
        offset += self.message.len;
        buf[offset] = 0;
        buf[offset + 1] = 0;
        return buf;
    }
};

test "message chat client parses local chat" {
    const packet = try MessageChatClient.unmarshal(&.{
        0x01, 0,   0, 0,
        0,    0,   0, 0,
        'h',  'i', 0,
    });

    try std.testing.expectEqual(ChatType.say, packet.chat_type);
    try std.testing.expectEqualStrings("hi", packet.message.slice());
}

test "message chat server marshals the client wire shape" {
    const body = try (MessageChatServer{
        .chat_type = .say,
        .language = 0,
        .sender_guid = ObjectGuid.player(0x1234),
        .receiver_guid = ObjectGuid.player(0x1234),
        .message = try MessageText.fromSlice("hi"),
    }).marshal(std.testing.allocator);
    defer std.testing.allocator.free(body);

    try std.testing.expectEqualSlices(u8, &.{
        0x01,
        0,
        0,
        0,
        0,
        0x34,
        0x12,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0x34,
        0x12,
        0,
        0,
        0,
        0,
        0,
        0,
        3,
        0,
        0,
        0,
        'h',
        'i',
        0,
        0,
    }, body);
}
