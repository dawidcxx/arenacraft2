const std = @import("std");
const ProtocolError = @import("./ProtocolError.zig").ProtocolErrorSet;
const utils = @import("./ProtocolUtils.zig");

pub const Opcode = enum(u8) {
    logon_challenge = 0x00,
    logon_proof = 0x01,
    realm_list = 0x10,
    _,

    pub fn value(self: Opcode) u8 {
        return @intFromEnum(self);
    }
};

pub const Frame = struct {
    pub const ClientMessage = union(enum) {
        logon_challenge: AuthLogonClientChallenge,
        logon_proof: AuthLogonClientProof,
        realm_list: AuthRealmListClientRequest,
    };

    const LengthStyle = enum { fixed, challenge };

    const PacketMeta = struct {
        opcode: Opcode,
        style: LengthStyle,
        already_read: usize,
        total_len: usize,
    };

    const client_packets = [_]PacketMeta{
        .{ .opcode = .logon_challenge, .style = .challenge, .already_read = 4, .total_len = 0 },
        .{ .opcode = .logon_proof, .style = .fixed, .already_read = 1, .total_len = AuthLogonClientProof.fixed_size },
        .{ .opcode = .realm_list, .style = .fixed, .already_read = 1, .total_len = AuthRealmListClientRequest.total_size },
    };

    pub fn readClientMessage(reader: *std.Io.Reader, buf: []u8) !ClientMessage {
        try reader.readSliceAll(buf[0..1]);
        const opcode = buf[0];

        inline for (client_packets) |meta| {
            if (opcode == meta.opcode.value()) {
                const total_len = switch (meta.style) {
                    .fixed => meta.total_len,
                    .challenge => blk: {
                        try reader.readSliceAll(buf[1..4]);
                        const body_len = std.mem.readInt(u16, buf[2..4], .little);
                        if (body_len > buf.len - 4) return error.MessageTooLarge;
                        break :blk 4 + body_len;
                    },
                };

                if (total_len > buf.len) return error.MessageTooLarge;

                try reader.readSliceAll(buf[meta.already_read..total_len]);

                const packet = buf[0..total_len];
                return switch (meta.opcode) {
                    .logon_challenge => .{ .logon_challenge = try AuthLogonClientChallenge.unmarshal(packet) },
                    .logon_proof => .{ .logon_proof = try AuthLogonClientProof.unmarshal(packet) },
                    .realm_list => .{ .realm_list = try AuthRealmListClientRequest.unmarshal(packet) },
                    else => unreachable,
                };
            }
        }

        return error.UnknownOpcode;
    }
};

// ─── AUTH_LOGON_CHALLENGE (cmd 0x00) ─────────────────────────────────────────

pub const AuthLogonClientChallenge = struct {
    pub const opcode: Opcode = .logon_challenge;
    pub const cmd_byte: u8 = opcode.value();
    pub const header_size: usize = 4;
    pub const fixed_body_size: usize = 30;
    pub const max_username_len: usize = 16;

    protocol_ver: u8,
    gamename: [4]u8,
    version_major: u8,
    version_minor: u8,
    version_patch: u8,
    build: u16,
    platform: [4]u8,
    os: [4]u8,
    country: [4]u8,
    timezone_bias: u32,
    ip: u32,
    username: []const u8,

    const Self = @This();

    pub fn unmarshal(bytes: []const u8) ProtocolError!Self {
        if (bytes.len < header_size + fixed_body_size) {
            std.log.debug("[AuthLogonClientChallenge] buffer too small: {d} < {d}\n", .{ bytes.len, header_size + fixed_body_size });
            return ProtocolError.InvalidMessage;
        }
        std.debug.assert(bytes[0] == cmd_byte);
        const proto_ver = bytes[1];
        if (proto_ver != 0x00 and proto_ver != 0x08) {
            std.log.debug("[AuthLogonClientChallenge] unsupported protocol version: 0x{X:0>2}\n", .{proto_ver});
            return ProtocolError.InvalidMessage;
        }
        const size = utils.readU16LE(bytes, 2) catch {
            std.log.debug("[AuthLogonClientChallenge] failed to read size field\n", .{});
            return ProtocolError.InvalidMessage;
        };
        if (size < fixed_body_size) {
            std.log.debug("[AuthLogonClientChallenge] size field too small: {d} < {d}\n", .{ size, fixed_body_size });
            return ProtocolError.InvalidMessage;
        }
        const i_len: u8 = bytes[33];
        if (size - fixed_body_size != i_len) {
            std.log.debug("[AuthLogonClientChallenge] size/I_len mismatch: size={d}, I_len={d}\n", .{ size, i_len });
            return ProtocolError.InvalidMessage;
        }
        if (i_len > max_username_len) {
            std.log.debug("[AuthLogonClientChallenge] username too long: {d} > {d}\n", .{ i_len, max_username_len });
            return ProtocolError.InvalidMessage;
        }
        const total = header_size + fixed_body_size + @as(usize, i_len);
        if (bytes.len < total) {
            std.log.debug("[AuthLogonClientChallenge] buffer too small for username: {d} < {d}\n", .{ bytes.len, total });
            return ProtocolError.InvalidMessage;
        }
        const gamename = utils.recv4(bytes, 4) catch unreachable;
        const build = utils.readU16LE(bytes, 11) catch unreachable;
        const platform = utils.recv4(bytes, 13) catch unreachable;
        const os = utils.recv4(bytes, 17) catch unreachable;
        const country = utils.recv4(bytes, 21) catch unreachable;
        const timezone_bias = utils.readU32LE(bytes, 25) catch unreachable;
        const ip = utils.readU32BE(bytes, 29) catch unreachable;
        return Self{
            .protocol_ver = proto_ver,
            .gamename = gamename,
            .version_major = bytes[8],
            .version_minor = bytes[9],
            .version_patch = bytes[10],
            .build = build,
            .platform = platform,
            .os = os,
            .country = country,
            .timezone_bias = timezone_bias,
            .ip = ip,
            .username = bytes[34 .. 34 + @as(usize, i_len)],
        };
    }

    pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const ip = self.ip;
        try w.print("AuthLogonClientChallenge{{ ver=0x{X:0>2}, user=\"{s}\", build={d}, v={d}.{d}.{d}, game=\"{s}\", platform=\"{s}\", os=\"{s}\", locale=\"{s}\", tz={d}, ip={d}.{d}.{d}.{d} }}", .{
            self.protocol_ver,
            self.username,
            self.build,
            self.version_major,
            self.version_minor,
            self.version_patch,
            self.gamename[1..4],
            self.platform[1..4],
            self.os[1..4],
            &self.country,
            self.timezone_bias,
            (ip >> 24) & 0xff,
            (ip >> 16) & 0xff,
            (ip >> 8) & 0xff,
            ip & 0xff,
        });
    }
};

pub const AuthLogonServerChallengeSuccess = struct {
    pub const opcode: Opcode = .logon_challenge;
    pub const cmd_byte: u8 = opcode.value();
    pub const total_size: usize = 119;
    pub const version_challenge = [_]u8{
        0xBA, 0xA3, 0x1E, 0x99, 0xA0, 0x0B, 0x21, 0x57,
        0xFC, 0x37, 0x3F, 0xB3, 0x69, 0xCD, 0xD2, 0xF1,
    };

    B: [32]u8,
    g: u8,
    N: [32]u8,
    s: [32]u8,
    security_flags: u8,

    const Self = @This();
    pub fn marshal(self: Self, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, total_size);
        errdefer allocator.free(buf);
        buf[0] = cmd_byte;
        buf[1] = 0;
        buf[2] = 0; // WOW_SUCCESS
        @memcpy(buf[3..35], &self.B);
        buf[35] = 1; // g_len
        buf[36] = self.g;
        buf[37] = 32; // N_len
        @memcpy(buf[38..70], &self.N);
        @memcpy(buf[70..102], &self.s);
        @memcpy(buf[102..118], &version_challenge);
        buf[118] = self.security_flags;
        return buf;
    }

    pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("AuthLogonServerChallengeSuccess{{ B[0]=0x{X:0>2}, g={d}, N[0]=0x{X:0>2}, s[0]=0x{X:0>2}, sec=0x{X:0>2} }}", .{
            self.B[0], self.g, self.N[0], self.s[0], self.security_flags,
        });
    }
};

pub const AuthLogonServerChallengeFailure = struct {
    pub const opcode: Opcode = .logon_challenge;
    pub const cmd_byte: u8 = opcode.value();
    pub const total_size: usize = 3;

    result: u8,

    const Self = @This();
    pub fn marshal(self: Self, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, total_size);
        errdefer allocator.free(buf);
        buf[0] = cmd_byte;
        buf[1] = 0;
        buf[2] = self.result;
        return buf;
    }
};

// ─── AUTH_LOGON_PROOF (cmd 0x01) ─────────────────────────────────────────────

pub const AuthLogonClientProof = struct {
    pub const opcode: Opcode = .logon_proof;
    pub const cmd_byte: u8 = opcode.value();
    pub const fixed_size: usize = 75; // cmd + A[32] + clientM[20] + crc_hash[20] + num_keys + sec_flags

    A: [32]u8,
    clientM: [20]u8,
    crc_hash: [20]u8,
    number_of_keys: u8,
    security_flags: u8,
    extra: []const u8, // trailing token bytes (if any)

    const Self = @This();

    pub fn unmarshal(bytes: []const u8) ProtocolError!Self {
        if (bytes.len < fixed_size) {
            std.log.debug("[AuthLogonClientProof] buffer too small: {d} < {d}\n", .{ bytes.len, fixed_size });
            return ProtocolError.InvalidMessage;
        }
        std.debug.assert(bytes[0] == cmd_byte);

        var A: [32]u8 = undefined;
        @memcpy(&A, bytes[1..33]);
        var clientM: [20]u8 = undefined;
        @memcpy(&clientM, bytes[33..53]);
        var crc_hash: [20]u8 = undefined;
        @memcpy(&crc_hash, bytes[53..73]);

        return Self{
            .A = A,
            .clientM = clientM,
            .crc_hash = crc_hash,
            .number_of_keys = bytes[73],
            .security_flags = bytes[74],
            .extra = if (bytes.len > fixed_size) bytes[fixed_size..] else &[_]u8{},
        };
    }

    pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("AuthLogonClientProof{{ A[0]=0x{X:0>2}, M1[0]=0x{X:0>2}, crc[0]=0x{X:0>2}, keys={d}, sec=0x{X:0>2}, extra={d}B }}", .{
            self.A[0],
            self.clientM[0],
            self.crc_hash[0],
            self.number_of_keys,
            self.security_flags,
            self.extra.len,
        });
    }
};

pub const AuthLogonServerProofSuccess = struct {
    pub const opcode: Opcode = .logon_proof;
    pub const cmd_byte: u8 = opcode.value();
    pub const total_size: usize = 32; // cmd + error + M2[20] + AccountFlags + SurveyId + LoginFlags

    M2: [20]u8,
    account_flags: u32,
    survey_id: u32,
    login_flags: u16,

    const Self = @This();
    pub fn marshal(self: Self, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, total_size);
        errdefer allocator.free(buf);
        buf[0] = cmd_byte;
        buf[1] = 0; // error = WOW_SUCCESS
        @memcpy(buf[2..22], &self.M2);
        utils.writeU32LE(buf, 22, self.account_flags);
        utils.writeU32LE(buf, 26, self.survey_id);
        utils.writeU16LE(buf, 30, self.login_flags);
        return buf;
    }

    pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("AuthLogonServerProofSuccess{{ M2[0]=0x{X:0>2}, flags=0x{X:0>8}, survey={d}, login=0x{X:0>4} }}", .{
            self.M2[0], self.account_flags, self.survey_id, self.login_flags,
        });
    }
};

pub const AuthLogonServerProofFailure = struct {
    pub const opcode: Opcode = .logon_proof;
    pub const cmd_byte: u8 = opcode.value();
    pub const total_size: usize = 4; // cmd + error + login_flags(u16)

    result: u8,
    login_flags: u16,

    const Self = @This();
    pub fn marshal(self: Self, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, total_size);
        errdefer allocator.free(buf);
        buf[0] = cmd_byte;
        buf[1] = self.result;
        utils.writeU16LE(buf, 2, self.login_flags);
        return buf;
    }
};

// ─── REALM_LIST (cmd 0x10) ───────────────────────────────────────────────────

pub const AuthRealmListClientRequest = struct {
    pub const opcode: Opcode = .realm_list;
    pub const cmd_byte: u8 = opcode.value();
    pub const total_size: usize = 5; // cmd + u32 padding

    const Self = @This();
    pub fn unmarshal(bytes: []const u8) ProtocolError!Self {
        if (bytes.len != total_size) return ProtocolError.InvalidMessage;
        std.debug.assert(bytes[0] == cmd_byte);
        return Self{};
    }

    pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = self;
        try w.writeAll("AuthRealmListClientRequest{}");
    }
};

pub const AuthRealmListServerResponse = struct {
    pub const opcode: Opcode = .realm_list;
    pub const cmd_byte: u8 = opcode.value();

    pub const RealmEntry = struct {
        realm_type: u8,
        locked: u8,
        flags: u8,
        name: []const u8,
        address: []const u8,
        population: f32,
        num_chars: u8,
        timezone: u8,
        realm_id: u8,
        build_major: u8,
        build_minor: u8,
        build_patch: u8,
        build: u16,
        has_build_info: bool,
    };

    realms: []const RealmEntry,

    const Self = @This();

    fn calcSize(realms: []const RealmEntry) usize {
        var total: usize = 1 + 2; // cmd + payload_size(u16)
        // size header: u32(zero) + u16(realmlist_size)
        total += 6;
        for (realms) |r| {
            total += 1 + 1 + 1; // realm_type, locked, flags
            total += r.name.len + 1; // name + null
            total += r.address.len + 1; // address + null
            total += 4; // population f32
            total += 1; // num_chars
            total += 1; // timezone
            total += 1; // realm_id
            if (r.has_build_info) {
                total += 3 + 2; // major, minor, patch + build
            }
        }
        total += 2; // trailing 0x0010 for post-BC
        return total;
    }

    pub fn marshal(self: Self, allocator: std.mem.Allocator) ![]u8 {
        const total = calcSize(self.realms);
        const buf = try allocator.alloc(u8, total);
        errdefer allocator.free(buf);

        buf[0] = cmd_byte;
        const payload_start: usize = 1 + 2; // skip cmd + payload_size for now
        var off: usize = payload_start;

        // realm list size header
        utils.writeU32LE(buf, off, 0);
        off += 4;
        utils.writeU16LE(buf, off, @intCast(self.realms.len));
        off += 2;

        for (self.realms) |r| {
            buf[off] = r.realm_type;
            off += 1;
            buf[off] = r.locked;
            off += 1;
            buf[off] = r.flags;
            off += 1;
            @memcpy(buf[off..][0..r.name.len], r.name);
            off += r.name.len;
            buf[off] = 0;
            off += 1;
            @memcpy(buf[off..][0..r.address.len], r.address);
            off += r.address.len;
            buf[off] = 0;
            off += 1;
            @memcpy(buf[off..][0..4], std.mem.asBytes(&r.population));
            off += 4;
            buf[off] = r.num_chars;
            off += 1;
            buf[off] = r.timezone;
            off += 1;
            buf[off] = r.realm_id;
            off += 1;
            if (r.has_build_info) {
                buf[off] = r.build_major;
                off += 1;
                buf[off] = r.build_minor;
                off += 1;
                buf[off] = r.build_patch;
                off += 1;
                utils.writeU16LE(buf, off, r.build);
                off += 2;
            }
        }

        // trailing marker
        buf[off] = 0x10;
        off += 1;
        buf[off] = 0x00;
        off += 1;

        // fill payload_size
        const payload_size: u16 = @intCast(off - payload_start);
        utils.writeU16LE(buf, 1, payload_size);

        return buf;
    }

    pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("AuthRealmListServerResponse{{ {d} realms: [", .{self.realms.len});
        for (self.realms, 0..) |r, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("{s}({s})", .{ r.name, r.address });
        }
        try w.writeAll("] }");
    }
};

// ─── TESTS ───────────────────────────────────────────────────────────────────

test AuthLogonClientChallenge {
    const t = std.testing;
    const expected_bytes = [_]u8{
        0x00, 0x08, 0x23, 0x00,
        0x57, 0x6F, 0x57, 0x00,
        0x03, 0x03, 0x05, 0x34,
        0x30, 0x36, 0x38, 0x78,
        0x00, 0x6E, 0x69, 0x57,
        0x00, 0x53, 0x55, 0x6E,
        0x65, 0x3C, 0x00, 0x00,
        0x00, 0x7F, 0x00, 0x00,
        0x01, 0x05, 0x41, 0x44,
        0x4D, 0x49, 0x4E,
    };
    const parsed = try AuthLogonClientChallenge.unmarshal(&expected_bytes);
    try t.expectEqual(@as(u8, 0x08), parsed.protocol_ver);
    try t.expectEqualStrings("WoW", parsed.gamename[1..4]);
    try t.expectEqual(@as(u8, 3), parsed.version_major);
    try t.expectEqual(@as(u8, 3), parsed.version_minor);
    try t.expectEqual(@as(u8, 5), parsed.version_patch);
    try t.expectEqual(@as(u16, 12340), parsed.build);
    try t.expectEqualStrings("x86", parsed.platform[1..4]);
    try t.expectEqualStrings("Win", parsed.os[1..4]);
    try t.expectEqualStrings("enUS", parsed.country[0..4]);
    try t.expectEqual(@as(u32, 60), parsed.timezone_bias);
    try t.expectEqual(@as(u32, 0x7F000001), parsed.ip);
    try t.expectEqualStrings("ADMIN", parsed.username);
    try t.expectError(ProtocolError.InvalidMessage, AuthLogonClientChallenge.unmarshal(expected_bytes[0..5]));

    var bytes_00 = expected_bytes;
    bytes_00[1] = 0x00;
    _ = try AuthLogonClientChallenge.unmarshal(&bytes_00);

    var bytes_bad = expected_bytes;
    bytes_bad[1] = 0xFF;
    try t.expectError(ProtocolError.InvalidMessage, AuthLogonClientChallenge.unmarshal(&bytes_bad));
}

test AuthLogonServerChallengeSuccess {
    const t = std.testing;
    const pkt = AuthLogonServerChallengeSuccess{
        .B = [_]u8{0xBB} ** 32,
        .g = 7,
        .N = [_]u8{0xDD} ** 32,
        .s = [_]u8{0x55} ** 32,
        .security_flags = 0,
    };
    const wire = try pkt.marshal(t.allocator);
    defer t.allocator.free(wire);
    try t.expectEqual(AuthLogonServerChallengeSuccess.total_size, wire.len);
    try t.expectEqual(@as(u8, 0x00), wire[0]);
    try t.expectEqual(@as(u8, 0xBB), wire[3]);
    try t.expectEqual(@as(u8, 0xBB), wire[34]);
    try t.expectEqual(@as(u8, 1), wire[35]);
    try t.expectEqual(@as(u8, 7), wire[36]);
    try t.expectEqual(@as(u8, 32), wire[37]);
    try t.expectEqual(@as(u8, 0xBA), wire[102]);
    try t.expectEqual(@as(u8, 0xF1), wire[117]);
    try t.expectEqual(@as(u8, 0), wire[118]);
}

test AuthLogonServerChallengeFailure {
    const t = std.testing;
    const pkt = AuthLogonServerChallengeFailure{ .result = 0x04 };
    const wire = try pkt.marshal(t.allocator);
    defer t.allocator.free(wire);
    try t.expectEqual(@as(usize, 3), wire.len);
    try t.expectEqual(@as(u8, 0x00), wire[0]);
    try t.expectEqual(@as(u8, 0x00), wire[1]);
    try t.expectEqual(@as(u8, 0x04), wire[2]);
}

test AuthLogonClientProof {
    const t = std.testing;
    const bytes = [_]u8{
        0x01, // cmd
    } ++ ([_]u8{0xAA} ** 32) ++ // A
        ([_]u8{0xBB} ** 20) ++ // clientM
        ([_]u8{0xCC} ** 20) ++ // crc_hash
        [_]u8{ 0x00, 0x00 }; // num_keys, sec_flags
    const parsed = try AuthLogonClientProof.unmarshal(&bytes);
    try t.expectEqual(@as(u8, 0xAA), parsed.A[0]);
    try t.expectEqual(@as(u8, 0xAA), parsed.A[31]);
    try t.expectEqual(@as(u8, 0xBB), parsed.clientM[0]);
    try t.expectEqual(@as(u8, 0xCC), parsed.crc_hash[0]);
    try t.expectEqual(@as(u8, 0), parsed.number_of_keys);
    try t.expectEqual(@as(u8, 0), parsed.security_flags);
    try t.expectEqual(@as(usize, 0), parsed.extra.len);
}

test AuthLogonServerProofSuccess {
    const t = std.testing;
    const pkt = AuthLogonServerProofSuccess{
        .M2 = [_]u8{0xEE} ** 20,
        .account_flags = 0x00800000,
        .survey_id = 0,
        .login_flags = 0,
    };
    const wire = try pkt.marshal(t.allocator);
    defer t.allocator.free(wire);
    try t.expectEqual(@as(usize, 32), wire.len);
    try t.expectEqual(@as(u8, 0x01), wire[0]);
    try t.expectEqual(@as(u8, 0x00), wire[1]); // error = success
    try t.expectEqual(@as(u8, 0xEE), wire[2]);
    try t.expectEqual(@as(u32, 0x00800000), std.mem.readInt(u32, wire[22..26], .little));
    try t.expectEqual(@as(u32, 0), std.mem.readInt(u32, wire[26..30], .little));
    try t.expectEqual(@as(u16, 0), std.mem.readInt(u16, wire[30..32], .little));
}

test AuthLogonServerProofFailure {
    const t = std.testing;
    const pkt = AuthLogonServerProofFailure{ .result = 0x04, .login_flags = 0 };
    const wire = try pkt.marshal(t.allocator);
    defer t.allocator.free(wire);
    try t.expectEqual(@as(usize, 4), wire.len);
    try t.expectEqual(@as(u8, 0x01), wire[0]);
    try t.expectEqual(@as(u8, 0x04), wire[1]);
    try t.expectEqual(@as(u16, 0), std.mem.readInt(u16, wire[2..4], .little));
}

test AuthRealmListClientRequest {
    const bytes = [_]u8{ 0x10, 0x00, 0x00, 0x00, 0x00 };
    _ = try AuthRealmListClientRequest.unmarshal(&bytes);
    try std.testing.expectError(ProtocolError.InvalidMessage, AuthRealmListClientRequest.unmarshal(bytes[0..4]));
}

test AuthRealmListServerResponse {
    const t = std.testing;
    const response = AuthRealmListServerResponse{
        .realms = &[_]AuthRealmListServerResponse.RealmEntry{
            .{
                .realm_type = 0x01,
                .locked = 0,
                .flags = 0,
                .name = "ArenaCraft",
                .address = "127.0.0.1:8085",
                .population = 0.5,
                .num_chars = 0,
                .timezone = 2,
                .realm_id = 1,
                .build_major = 3,
                .build_minor = 3,
                .build_patch = 5,
                .build = 12340,
                .has_build_info = true,
            },
        },
    };
    const wire = try response.marshal(t.allocator);
    defer t.allocator.free(wire);
    try t.expectEqual(@as(u8, 0x10), wire[0]);
}
