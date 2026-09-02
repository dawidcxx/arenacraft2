//! Raw WoW 3.3.5a movement wire structures.
//!
//! This module intentionally does not decide whether a movement sample is
//! legal for a player. It only decodes and encodes packet-level data.

const std = @import("std");
const domain = @import("domain");
const ProtocolError = @import("./ProtocolError.zig").ProtocolErrorSet;

const ObjectGuid = domain.ObjectGuid;

pub const AllMovementPackets = union(MovementOpCode) {
    msg_move_start_forward: ClientMovement(.msg_move_start_forward),
    msg_move_start_backward: ClientMovement(.msg_move_start_backward),
    msg_move_stop: ClientMovement(.msg_move_stop),
    msg_move_start_strafe_left: ClientMovement(.msg_move_start_strafe_left),
    msg_move_start_strafe_right: ClientMovement(.msg_move_start_strafe_right),
    msg_move_stop_strafe: ClientMovement(.msg_move_stop_strafe),
    msg_move_jump: ClientMovement(.msg_move_jump),
    msg_move_start_turn_left: ClientMovement(.msg_move_start_turn_left),
    msg_move_start_turn_right: ClientMovement(.msg_move_start_turn_right),
    msg_move_stop_turn: ClientMovement(.msg_move_stop_turn),
    msg_move_start_pitch_up: ClientMovement(.msg_move_start_pitch_up),
    msg_move_start_pitch_down: ClientMovement(.msg_move_start_pitch_down),
    msg_move_stop_pitch: ClientMovement(.msg_move_stop_pitch),
    msg_move_set_run_mode: ClientMovement(.msg_move_set_run_mode),
    msg_move_set_walk_mode: ClientMovement(.msg_move_set_walk_mode),
    msg_move_fall_land: ClientMovement(.msg_move_fall_land),
    msg_move_start_swim: ClientMovement(.msg_move_start_swim),
    msg_move_stop_swim: ClientMovement(.msg_move_stop_swim),
    msg_move_set_facing: ClientMovement(.msg_move_set_facing),
    msg_move_set_pitch: ClientMovement(.msg_move_set_pitch),
    msg_move_heartbeat: ClientMovement(.msg_move_heartbeat),

    pub fn getInfo(self: AllMovementPackets) MovementInfo {
        return switch (self) {
            inline else => |pkt| pkt.info,
        };
    }

    pub fn fromOpcodeAndBody(
        opcode: MovementOpCode,
        body: []const u8,
    ) ProtocolError!AllMovementPackets {
        inline for (@typeInfo(AllMovementPackets).@"union".fields) |field| {
            if (opcode == @field(MovementOpCode, field.name)) {
                const PacketType = field.type;
                return @unionInit(
                    AllMovementPackets,
                    field.name,
                    try PacketType.unmarshal(body),
                );
            }
        }
        unreachable;
    }
};

/// MSG_MOVE_WORLDPORT_ACK has no payload; it only acknowledges a transfer.
pub const WorldportAck = struct {
    pub const opcode = MovementOpCode.msg_move_worldport_ack;

    pub fn unmarshal(bytes: []const u8) ProtocolError!WorldportAck {
        if (bytes.len != 0) return error.InvalidMessage;
        return .{};
    }
};

pub fn ClientMovement(comptime opcode_type: MovementOpCode) type {
    return struct {
        pub const opcode = opcode_type;
        const Self = @This();

        mover: ObjectGuid,
        info: MovementInfo,

        pub fn unmarshal(bytes: []const u8) ProtocolError!Self {
            const guid_read = ObjectGuid.fromPacked(bytes) catch return error.InvalidMessage;
            return .{
                .mover = guid_read.guid,
                .info = try MovementInfo.unmarshal(bytes[guid_read.consumed..]),
            };
        }

        /// Serializes the client movement payload without the world frame header.
        pub fn marshal(self: Self, allocator: std.mem.Allocator) ![]u8 {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            const packed_guid = self.mover.toPacked();
            try out.appendSlice(allocator, packed_guid.slice());
            try appendMovementInfo(&out, allocator, self.info);
            return out.toOwnedSlice(allocator);
        }

        pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.print("Movement.ClientMovement{{ mover=0x{X}, info={} }}", .{ self.mover.valueOf(), self.info });
        }
    };
}

/// The shared wire-level MovementInfo block used by client movement packets
/// and movement sections inside object updates.
pub const MovementInfo = struct {
    flags: u32,
    flags2: u16,
    time_ms: u32,
    x: f32,
    y: f32,
    z: f32,
    orientation: f32,
    transport: ?Transport = null,
    pitch: ?f32 = null,
    fall_time_ms: u32,
    jump: ?Jump = null,
    spline_elevation: ?f32 = null,

    pub fn unmarshal(bytes: []const u8) ProtocolError!MovementInfo {
        var cursor = BufferCursor{ .bytes = bytes };
        const flags = cursor.readU32() orelse return error.InvalidMessage;
        const flags2 = cursor.readU16() orelse return error.InvalidMessage;
        const time_ms = cursor.readU32() orelse return error.InvalidMessage;
        const x = cursor.readF32() orelse return error.InvalidMessage;
        const y = cursor.readF32() orelse return error.InvalidMessage;
        const z = cursor.readF32() orelse return error.InvalidMessage;
        const orientation = cursor.readF32() orelse return error.InvalidMessage;

        const transport = if ((flags & movement_flag_on_transport) != 0)
            try readTransport(&cursor, flags2)
        else
            null;

        const pitch = if (hasPitch(flags, flags2))
            cursor.readF32() orelse return error.InvalidMessage
        else
            null;

        const fall_time_ms = cursor.readU32() orelse return error.InvalidMessage;

        const jump: ?Jump = if ((flags & movement_flag_falling) != 0)
            Jump{
                .z_speed = cursor.readF32() orelse return error.InvalidMessage,
                .sin_angle = cursor.readF32() orelse return error.InvalidMessage,
                .cos_angle = cursor.readF32() orelse return error.InvalidMessage,
                .xy_speed = cursor.readF32() orelse return error.InvalidMessage,
            }
        else
            null;

        const spline_elevation = if ((flags & movement_flag_spline_elevation) != 0)
            cursor.readF32() orelse return error.InvalidMessage
        else
            null;

        if (!cursor.atEnd()) return error.InvalidMessage;

        return .{
            .flags = flags,
            .flags2 = flags2,
            .time_ms = time_ms,
            .x = x,
            .y = y,
            .z = z,
            .orientation = orientation,
            .transport = transport,
            .pitch = pitch,
            .fall_time_ms = fall_time_ms,
            .jump = jump,
            .spline_elevation = spline_elevation,
        };
    }

    pub fn format(self: MovementInfo, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("MovementInfo{{ flags=0x{X}, flags2=0x{X}, time={d}, x={d}, y={d}, z={d}, o={d}, fall={d} }}", .{
            self.flags,
            self.flags2,
            self.time_ms,
            self.x,
            self.y,
            self.z,
            self.orientation,
            self.fall_time_ms,
        });
    }
};

const movement_flag_on_transport: u32 = 0x00000200;
const movement_flag_falling: u32 = 0x00001000;
const movement_flag_swimming: u32 = 0x00200000;
const movement_flag_flying: u32 = 0x02000000;
const movement_flag_spline_elevation: u32 = 0x04000000;

const movement_flag2_always_allow_pitching: u16 = 0x0020;
const movement_flag2_interpolated_movement: u16 = 0x0400;

/// Raw transport-relative movement data following MovementInfo's base fields.
pub const Transport = struct {
    guid: ObjectGuid,
    x: f32,
    y: f32,
    z: f32,
    orientation: f32,
    time_ms: u32,
    seat: u8,
    interpolated_time_ms: ?u32 = null,

    pub fn format(self: Transport, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("Movement.Transport{{ guid=0x{X}, x={d}, y={d}, z={d}, o={d}, time={d}, seat={d} }}", .{
            self.guid.valueOf(),
            self.x,
            self.y,
            self.z,
            self.orientation,
            self.time_ms,
            self.seat,
        });
    }
};

/// Raw jump/fall data present when MovementInfo has the FALLING flag.
pub const Jump = struct {
    z_speed: f32,
    sin_angle: f32,
    cos_angle: f32,
    xy_speed: f32,

    pub fn format(self: Jump, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("Movement.Jump{{ z_speed={d}, sin={d}, cos={d}, xy_speed={d} }}", .{
            self.z_speed,
            self.sin_angle,
            self.cos_angle,
            self.xy_speed,
        });
    }
};

pub const MovementOpCode = enum(u32) {
    msg_move_start_forward = 0x0B5,
    msg_move_start_backward = 0x0B6,
    msg_move_stop = 0x0B7,
    msg_move_start_strafe_left = 0x0B8,
    msg_move_start_strafe_right = 0x0B9,
    msg_move_stop_strafe = 0x0BA,
    msg_move_jump = 0x0BB,
    msg_move_start_turn_left = 0x0BC,
    msg_move_start_turn_right = 0x0BD,
    msg_move_stop_turn = 0x0BE,
    msg_move_start_pitch_up = 0x0BF,
    msg_move_start_pitch_down = 0x0C0,
    msg_move_stop_pitch = 0x0C1,
    msg_move_set_run_mode = 0x0C2,
    msg_move_set_walk_mode = 0x0C3,
    msg_move_fall_land = 0x0C9,
    msg_move_start_swim = 0x0CA,
    msg_move_stop_swim = 0x0CB,
    msg_move_set_facing = 0x0DA,
    msg_move_set_pitch = 0x0DB,
    msg_move_heartbeat = 0x0EE,

    const Self = @This();

    pub fn fromOpcode(opcode: @import("./WorldProtocol.zig").Opcode) Self {
        switch (opcode) {
            .msg_move_start_forward => return Self.msg_move_start_forward,
            .msg_move_start_backward => return Self.msg_move_start_backward,
            .msg_move_stop => return Self.msg_move_stop,
            .msg_move_start_strafe_left => return Self.msg_move_start_strafe_left,
            .msg_move_start_strafe_right => return Self.msg_move_start_strafe_right,
            .msg_move_stop_strafe => return Self.msg_move_stop_strafe,
            .msg_move_jump => return Self.msg_move_jump,
            .msg_move_start_turn_left => return Self.msg_move_start_turn_left,
            .msg_move_start_turn_right => return Self.msg_move_start_turn_right,
            .msg_move_stop_turn => return Self.msg_move_stop_turn,
            .msg_move_start_pitch_up => return Self.msg_move_start_pitch_up,
            .msg_move_start_pitch_down => return Self.msg_move_start_pitch_down,
            .msg_move_stop_pitch => return Self.msg_move_stop_pitch,
            .msg_move_set_run_mode => return Self.msg_move_set_run_mode,
            .msg_move_set_walk_mode => return Self.msg_move_set_walk_mode,
            .msg_move_fall_land => return Self.msg_move_fall_land,
            .msg_move_start_swim => return Self.msg_move_start_swim,
            .msg_move_stop_swim => return Self.msg_move_stop_swim,
            .msg_move_set_facing => return Self.msg_move_set_facing,
            .msg_move_set_pitch => return Self.msg_move_set_pitch,
            .msg_move_heartbeat => return Self.msg_move_heartbeat,
            else => std.debug.panic("Illegal opcode mapping ({})", .{opcode}),
        }
    }
};

fn hasPitch(flags: u32, flags2: u16) bool {
    return (flags & (movement_flag_swimming | movement_flag_flying)) != 0 or
        (flags2 & movement_flag2_always_allow_pitching) != 0;
}

fn readTransport(cursor: *BufferCursor, flags2: u16) ProtocolError!Transport {
    const guid_read = ObjectGuid.fromPacked(cursor.remaining()) catch return error.InvalidMessage;
    cursor.offset += guid_read.consumed;
    return .{
        .guid = guid_read.guid,
        .x = cursor.readF32() orelse return error.InvalidMessage,
        .y = cursor.readF32() orelse return error.InvalidMessage,
        .z = cursor.readF32() orelse return error.InvalidMessage,
        .orientation = cursor.readF32() orelse return error.InvalidMessage,
        .time_ms = cursor.readU32() orelse return error.InvalidMessage,
        .seat = cursor.readU8() orelse return error.InvalidMessage,
        .interpolated_time_ms = if ((flags2 & movement_flag2_interpolated_movement) != 0)
            cursor.readU32() orelse return error.InvalidMessage
        else
            null,
    };
}

/// Appends the flag-selected conditional MovementInfo layout into `out`.
pub fn appendMovementInfo(out: *std.ArrayList(u8), allocator: std.mem.Allocator, info: MovementInfo) !void {
    try appendU32(out, allocator, info.flags);
    try appendU16(out, allocator, info.flags2);
    try appendU32(out, allocator, info.time_ms);
    try appendF32(out, allocator, info.x);
    try appendF32(out, allocator, info.y);
    try appendF32(out, allocator, info.z);
    try appendF32(out, allocator, info.orientation);

    if ((info.flags & movement_flag_on_transport) != 0) {
        const transport = info.transport orelse return error.InvalidMessage;
        const packed_guid = transport.guid.toPacked();
        try out.appendSlice(allocator, packed_guid.slice());
        try appendF32(out, allocator, transport.x);
        try appendF32(out, allocator, transport.y);
        try appendF32(out, allocator, transport.z);
        try appendF32(out, allocator, transport.orientation);
        try appendU32(out, allocator, transport.time_ms);
        try out.append(allocator, transport.seat);
        if ((info.flags2 & movement_flag2_interpolated_movement) != 0)
            try appendU32(out, allocator, transport.interpolated_time_ms orelse return error.InvalidMessage);
    }

    if (hasPitch(info.flags, info.flags2))
        try appendF32(out, allocator, info.pitch orelse return error.InvalidMessage);

    try appendU32(out, allocator, info.fall_time_ms);

    if ((info.flags & movement_flag_falling) != 0) {
        const jump = info.jump orelse return error.InvalidMessage;
        try appendF32(out, allocator, jump.z_speed);
        try appendF32(out, allocator, jump.sin_angle);
        try appendF32(out, allocator, jump.cos_angle);
        try appendF32(out, allocator, jump.xy_speed);
    }

    if ((info.flags & movement_flag_spline_elevation) != 0)
        try appendF32(out, allocator, info.spline_elevation orelse return error.InvalidMessage);
}

const BufferCursor = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn remaining(self: *const BufferCursor) []const u8 {
        return self.bytes[self.offset..];
    }

    fn atEnd(self: *const BufferCursor) bool {
        return self.offset == self.bytes.len;
    }

    fn take(self: *BufferCursor, comptime size: usize) ?[]const u8 {
        if (self.bytes.len -| self.offset < size) return null;
        const result = self.bytes[self.offset .. self.offset + size];
        self.offset += size;
        return result;
    }

    fn readU8(self: *BufferCursor) ?u8 {
        const bytes = self.take(1) orelse return null;
        return bytes[0];
    }

    fn readU16(self: *BufferCursor) ?u16 {
        const bytes = self.take(2) orelse return null;
        return @as(u16, bytes[0]) | @as(u16, bytes[1]) << 8;
    }

    fn readU32(self: *BufferCursor) ?u32 {
        const bytes = self.take(4) orelse return null;
        return @as(u32, bytes[0]) |
            @as(u32, bytes[1]) << 8 |
            @as(u32, bytes[2]) << 16 |
            @as(u32, bytes[3]) << 24;
    }

    fn readF32(self: *BufferCursor) ?f32 {
        return @bitCast(self.readU32() orelse return null);
    }
};

fn appendU16(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

fn appendU32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

fn appendF32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: f32) !void {
    try appendU32(out, allocator, @bitCast(value));
}

test "client movement reads packed guid and base movement info" {
    var payload: [33]u8 = .{0} ** 33;
    payload[0] = 0x03;
    payload[1] = 0x34;
    payload[2] = 0x12;
    std.mem.writeInt(u32, payload[13..17], @bitCast(@as(f32, 1.0)), .little);
    std.mem.writeInt(u32, payload[17..21], @bitCast(@as(f32, 2.0)), .little);
    std.mem.writeInt(u32, payload[21..25], @bitCast(@as(f32, 3.0)), .little);
    std.mem.writeInt(u32, payload[25..29], @bitCast(@as(f32, 4.0)), .little);
    const movement = try ClientMovement(.msg_move_start_forward).unmarshal(&payload);
    try std.testing.expectEqual(@as(u64, 0x1234), movement.mover.valueOf());
    try std.testing.expectEqual(@as(f32, 1.0), movement.info.x);
    try std.testing.expectEqual(@as(f32, 2.0), movement.info.y);
    try std.testing.expectEqual(@as(f32, 3.0), movement.info.z);
}

test "movement info reads conditional pitch and jump data" {
    var payload: [50]u8 = undefined;
    @memset(&payload, 0);
    std.mem.writeInt(u32, payload[0..4], movement_flag_swimming | movement_flag_falling, .little);
    std.mem.writeInt(u32, payload[10..14], @bitCast(@as(f32, 1.0)), .little);
    std.mem.writeInt(u32, payload[14..18], @bitCast(@as(f32, 2.0)), .little);
    std.mem.writeInt(u32, payload[18..22], @bitCast(@as(f32, 3.0)), .little);
    std.mem.writeInt(u32, payload[22..26], @bitCast(@as(f32, 4.0)), .little);
    std.mem.writeInt(u32, payload[26..30], @bitCast(@as(f32, 5.0)), .little);
    std.mem.writeInt(u32, payload[30..34], @bitCast(@as(f32, 6.0)), .little);
    std.mem.writeInt(u32, payload[34..38], @bitCast(@as(f32, 7.0)), .little);
    std.mem.writeInt(u32, payload[38..42], @bitCast(@as(f32, 8.0)), .little);
    std.mem.writeInt(u32, payload[42..46], @bitCast(@as(f32, 9.0)), .little);
    std.mem.writeInt(u32, payload[46..50], @bitCast(@as(f32, 10.0)), .little);

    const movement = try MovementInfo.unmarshal(&payload);
    try std.testing.expectEqual(@as(f32, 5.0), movement.pitch.?);
    try std.testing.expectEqual(@as(f32, 7.0), movement.jump.?.z_speed);
    try std.testing.expectEqual(@as(f32, 10.0), movement.jump.?.xy_speed);
}

test "movement info rejects missing conditional data" {
    var payload: [30]u8 = .{0} ** 30;
    std.mem.writeInt(u32, payload[0..4], movement_flag_falling, .little);
    try std.testing.expectError(error.InvalidMessage, MovementInfo.unmarshal(&payload));
}

test "movement info rejects trailing data" {
    var payload: [31]u8 = .{0} ** 31;
    try std.testing.expectError(error.InvalidMessage, MovementInfo.unmarshal(&payload));
}
