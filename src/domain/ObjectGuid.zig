//  WoW 3.3.5a 64-bit GUID layout:
//   [bits 63..48] = HighGuid — object-type discriminator
//   [bits 47..24] = Entry    — creature/GO template ID (if applicable)
//   [bits 23..0]  = Counter  — unique sequential ID ("low" part)
//
//  Player has HighGuid=0x0000 and no Entry, so the raw value IS the u32 counter.
//  This means player GUIDs pack to fewer bytes on the wire (variable-length encoding).
//
const std = @import("std");

pub const ObjectGuid = struct {
    raw: u64,

    pub const empty = ObjectGuid{ .raw = 0 };

    pub fn player(low: u32) ObjectGuid {
        return .{ .raw = low };
    }

    /// HighGuid discriminator for item objects (bits 63..48). Items carry
    /// no entry in the raw guid, just the instance counter.
    pub const item_high: u64 = 0x4000;

    pub fn item(low: u32) ObjectGuid {
        return .{ .raw = item_high << 48 | low };
    }

    pub fn fromRaw(raw: u64) ObjectGuid {
        return .{ .raw = raw };
    }

    pub fn valueOf(self: ObjectGuid) u64 {
        return self.raw;
    }

    pub fn playerLow(self: ObjectGuid) ?u32 {
        if (self.raw == 0) return null;
        if ((self.raw >> 48) != 0) return null; // ensure HighGuid == Player (0x0000)
        if (self.raw > std.math.maxInt(u32)) return null;
        return @intCast(self.raw);
    }

    pub fn toPacked(self: ObjectGuid) Packed {
        var encoded = Packed{
            .bytes = undefined,
            .len = 1,
        };
        encoded.bytes[0] = 0;

        var raw_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &raw_bytes, self.raw, .little);
        for (raw_bytes, 0..) |byte, i| {
            if (byte == 0) continue;
            encoded.bytes[0] |= @as(u8, 1) << @intCast(i);
            encoded.bytes[encoded.len] = byte;
            encoded.len += 1;
        }

        return encoded;
    }

    pub fn fromPacked(bytes: []const u8) error{TruncatedPackedGuid}!PackedRead {
        if (bytes.len == 0) return error.TruncatedPackedGuid;

        const mask = bytes[0];
        var raw: u64 = 0;
        var offset: usize = 1;
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            if ((mask & (@as(u8, 1) << @intCast(i))) == 0) continue;
            if (offset >= bytes.len) return error.TruncatedPackedGuid;
            raw |= @as(u64, bytes[offset]) << @intCast(i * 8);
            offset += 1;
        }

        return .{
            .guid = fromRaw(raw),
            .consumed = offset,
        };
    }
};

test "player object guids use the low counter as raw value" {
    const guid = ObjectGuid.player(42);
    try std.testing.expectEqual(@as(u64, 42), guid.valueOf());
    try std.testing.expectEqual(@as(u32, 42), guid.playerLow().?);
}

test "item guids carry the item HighGuid discriminator" {
    const guid = ObjectGuid.item(0x24);
    try std.testing.expectEqual(@as(u64, 0x4000_0000_0000_0024), guid.valueOf());
    // The low counter sits in the same bits as player guids.
    try std.testing.expectEqual(@as(u32, 0x24), @as(u32, @truncate(guid.valueOf())));
    try std.testing.expect(guid.playerLow() == null);
}

pub const Packed = struct {
    bytes: [9]u8,
    len: u8,

    pub fn slice(self: *const Packed) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const PackedRead = struct {
    guid: ObjectGuid,
    consumed: usize,
};

test "object guids convert to and from packed form" {
    const guid = ObjectGuid.fromRaw(0x0000_0000_0000_1234);
    const encoded = guid.toPacked();
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x34, 0x12 }, encoded.slice());

    const decoded = try ObjectGuid.fromPacked(encoded.slice());
    try std.testing.expectEqual(guid.valueOf(), decoded.guid.valueOf());
    try std.testing.expectEqual(@as(usize, 3), decoded.consumed);
}

test "packed object guid rejects truncated input" {
    try std.testing.expectError(error.TruncatedPackedGuid, ObjectGuid.fromPacked(&.{}));
    try std.testing.expectError(error.TruncatedPackedGuid, ObjectGuid.fromPacked(&.{ 0x03, 0x34 }));
}
