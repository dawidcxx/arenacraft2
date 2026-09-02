const std = @import("std");
const protocol = @import("protocol");
const domain = @import("domain");
const ServerState = @import("../ServerState.zig").ServerState;
const stdx = @import("stdx");
const build_cfg = @import("build_config");

const Realm = domain.Realm;
const AuthCrypt = protocol.world_auth.AuthCrypt;

pub const log = std.log.scoped(.world_server_connection);

fn opcodeName(opcode: protocol.world.Opcode) []const u8 {
    return std.enums.tagName(protocol.world.Opcode, opcode) orelse "unknown";
}

pub const WorldServerConnection = struct {
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    crypt: ?AuthCrypt = null,
    addon_info: ?[]const protocol.world.AddonInfo = null,
    account_name: ?[]const u8 = null,
    selected_realm: ?Realm = null,

    pub const CreateWorldServerConnectionError = std.mem.Allocator.Error;
    pub fn create(
        alloc: std.mem.Allocator,
        options: WorldServerConnection,
    ) CreateWorldServerConnectionError!*WorldServerConnection {
        const instance = try alloc.create(WorldServerConnection);
        errdefer alloc.destroy(instance);
        instance.* = options;
        return instance;
    }

    pub fn destroy(self: *WorldServerConnection, alloc: std.mem.Allocator) void {
        if (self.addon_info) |addon_info| alloc.free(addon_info);
        if (self.account_name) |account_name| alloc.free(account_name);

        alloc.destroy(self);
    }

    pub const ReadFrameError = std.Io.Reader.Error || protocol.ProtocolErrorSet;
    pub fn readFrame(
        self: *WorldServerConnection,
        buffer: *[protocol.world.Frame.client_max_payload_size]u8,
    ) ReadFrameError!protocol.world.Frame.Header {
        var header_buf: [protocol.world.Frame.client_header_size]u8 = undefined;
        try self.reader.readSliceAll(&header_buf);

        if (self.crypt) |*crypt| {
            crypt.client_decrypt.update(header_buf[0..header_buf.len]);
        }

        const parsed_header = try protocol.world.Frame.Header.fromClientBuf(&header_buf);
        try self.reader.readSliceAll(buffer[0..parsed_header.payload_len]);

        if (build_cfg.@"enable-verbose-packet-log") {
            const account = self.account_name orelse "unauthenticated";
            log.debug("PACKET.RECEIVED packet(acc={s}): opcode=[{s} (0x{x})] body=[{x}]", .{
                account,
                opcodeName(parsed_header.opcode),
                @intFromEnum(parsed_header.opcode),
                buffer[0..parsed_header.payload_len],
            });
        }

        return parsed_header;
    }

    pub const SendMessageError = std.Io.Writer.Error;
    pub fn sendMessage(
        self: *WorldServerConnection,
        alloc: std.mem.Allocator,
        message: anytype,
    ) SendMessageError!void {
        const opcode = @TypeOf(message).opcode;

        const body: []u8 = message.marshal(alloc) catch |e| {
            log.err("Failed to serialize message opcode='{}' error='{}'", .{ opcode, e });
            unreachable;
        };
        defer alloc.free(body);
        return try self.sendRawMessage(opcode.value(), body);
    }

    pub fn sendRawMessage(
        self: *WorldServerConnection,
        opcode: u32,
        body: []const u8,
    ) SendMessageError!void {
        const header = protocol.world.Frame.Header{
            .opcode = @enumFromInt(opcode),
            .payload_len = body.len,
        };

        if (build_cfg.@"enable-verbose-packet-log") {
            const account = self.account_name orelse "unauthenticated";
            log.debug("PACKET.SENT packet(acc={s}): opcode=[{s} (0x{x})] body=[{x}]", .{
                account,
                opcodeName(header.opcode),
                opcode,
                body,
            });
        }

        const packed_header = header.encodeServer() catch {
            // NOTE: error here would mean
            // some program error on our backend
            unreachable;
        };

        if (self.crypt) |*crypt| {
            const scrambled_header = packed_header.scrambled(&crypt.server_encrypt);
            try self.writer.writeAll(scrambled_header.slice());
        } else {
            try self.writer.writeAll(packed_header.slice());
        }

        try self.writer.writeAll(body);
        try self.writer.flush();
    }

    pub const AuthenticateError =
        std.Io.Cancelable ||
        SendMessageError ||
        ReadFrameError ||
        protocol.ProtocolErrorSet ||
        std.mem.Allocator.Error ||
        error{AuthenticationFailure};

    pub fn authenticate(
        self: *WorldServerConnection,
        alloc: std.mem.Allocator,
        io: std.Io,
        server_state: *ServerState,
        clock: *stdx.Clock,
    ) AuthenticateError!void {
        var server_seed: [4]u8 = undefined;
        var challenge_seeds: [32]u8 = undefined;
        var response_scratch_buf: [protocol.world.Frame.client_max_payload_size]u8 = undefined;

        io.randomSecure(&server_seed) catch |e| switch (e) {
            error.Canceled => return AuthenticateError.Canceled,
            else => unreachable,
        };
        io.randomSecure(&challenge_seeds) catch |e| switch (e) {
            error.Canceled => return AuthenticateError.Canceled,
            else => unreachable,
        };

        try self.sendMessage(alloc, protocol.world.AuthChallengeServer{ .seed = server_seed, .seeds = challenge_seeds });

        const header = try self.readFrame(&response_scratch_buf);
        if (header.opcode != .cmsg_auth_session) return AuthenticateError.IllegalClientState;

        const auth_session = try protocol.world.AuthSessionClient.unmarshal(&response_scratch_buf);

        const ticket_copy = server_state.auth_tickets.getByAccount(io, auth_session.account) orelse {
            try self.sendMessage(alloc, protocol.world.AuthResponseServer.unknownAccount());
            return AuthenticateError.IllegalClientState;
        };

        // Check if auth_ticket is expired
        const now_ms = @as(i64, @intCast(clock.nowMs()));
        if (ticket_copy.isExpired(now_ms)) {
            // Remove it also to free memory
            if (!server_state.auth_tickets.removeByAccount(io, auth_session.account)) {
                log.warn("Failed to remove auth_ticket", .{});
            }

            try self.sendMessage(alloc, protocol.world.AuthResponseServer.authFailed());
            return AuthenticateError.AuthenticationFailure;
        }

        // Check if user is who they claim they are
        const expected_digest = protocol.world_auth.computeWorldAuthDigest(
            auth_session.account,
            auth_session.local_challenge,
            server_seed,
            ticket_copy.k,
        );
        if (!std.crypto.timing_safe.eql([20]u8, expected_digest, auth_session.digest)) {
            try self.sendMessage(alloc, protocol.world.AuthResponseServer.authFailed());
            return AuthenticateError.AuthenticationFailure;
        }

        // Check if realm is legit
        const realm_id = std.math.cast(u8, auth_session.realm_id) orelse {
            // WoW protocol is incosistent, sometimes realm_id is u8, sometimes u32
            log.warn("Fishy relam_id detected: '{}'", .{auth_session.realm_id});
            try self.sendMessage(alloc, protocol.world.AuthResponseServer.authFailed());
            return AuthenticateError.AuthenticationFailure;
        };
        if (server_state.realms.findById(realm_id)) |realm| {
            self.selected_realm = realm;
        } else {
            try self.sendMessage(alloc, protocol.world.AuthResponseServer.authFailed());
            return AuthenticateError.AuthenticationFailure;
        }

        // Authentication Successful
        // Invalidate ticket & free memory
        if (!server_state.auth_tickets.removeByAccount(io, auth_session.account)) {
            log.warn("Failed to remove auth_ticket", .{});
            // Some concurrent connection tried to use a stale ticket?
            try self.sendMessage(alloc, protocol.world.AuthResponseServer.authFailed());
            return AuthenticateError.AuthenticationFailure;
        }

        const addon_info = auth_session.getParsedAddonInfo(alloc) catch |e| {
            log.warn("Client tried to send corrupted addon info: '{}'", .{e});
            return AuthenticateError.InvalidMessage;
        };
        self.addon_info = addon_info;
        self.account_name = try alloc.dupe(u8, auth_session.account);
        errdefer self.account_name.?;

        // Upgrade connection to a authenticated one
        self.crypt = AuthCrypt.init(ticket_copy.k);
    }
};
