const std = @import("std");
const net = std.Io.net;
const protocol = @import("protocol");
const auth = protocol.auth;
const db = @import("db");
const stdx = @import("stdx");
const pg = @import("pg");
const build_config = @import("build_config");

const server_state = @import("./ServerState.zig");
const ServerState = server_state.ServerState;
const SrpSession = stdx.srp6_session.SrpSession;
const SrpInitOptions = stdx.srp6_session.InitOptions;

const auth_ticket_ttl_ms: i64 = 30_000;
const log = std.log.scoped(.auth_server);

// ═══ AuthServer ═══════════════════════════════════════════════════════════════
pub const AuthServer = struct {
    const Self = @This();

    io: std.Io,
    allocator: std.mem.Allocator,
    pool: *pg.Pool,
    state: *ServerState,
    clock: *stdx.Clock,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        pool: *pg.Pool,
        state: *ServerState,
        clock: *stdx.Clock,
    ) !Self {
        return .{
            .io = io,
            .allocator = allocator,
            .pool = pool,
            .state = state,
            .clock = clock,
        };
    }

    pub fn run(self: *Self) void {
        const addr = net.IpAddress.parseIp4("0.0.0.0", 3724) catch unreachable;
        var server = addr.listen(self.io, .{ .reuse_address = false }) catch |e| {
            std.debug.panic("AuthServer failed to bind to network iface, reason={}", .{e});
        };
        defer server.deinit(self.io);

        var connections: std.Io.Group = .init;
        defer connections.cancel(self.io);

        log.info("Running AuthServer", .{});
        defer log.info("Exiting AuthServer", .{});

        while (true) {
            const stream = server.accept(self.io) catch |e| {
                if (e == error.Canceled) break;
                std.log.err("Failed to accept incoming connection: {}", .{e});
                continue;
            };
            connections.concurrent(self.io, Self.connectionFiber, .{ self, stream }) catch |e| {
                std.log.err("Error in authserver fiber: {}", .{e});
                stream.close(self.io);
                continue;
            };
        }
    }

    pub fn connectionFiber(self: *Self, stream: net.Stream) void {
        defer stream.close(self.io);

        var rx_buf: [256]u8 = undefined;
        var reader = stream.reader(self.io, rx_buf[0..]);

        var tx_buf: [512]u8 = undefined;
        var writer = stream.writer(self.io, tx_buf[0..]);

        self.connectionFiberInner(&reader.interface, &writer.interface) catch |err| switch (err) {
            error.EndOfStream => {},
            error.ReadFailed => std.log.warn("auth read error, cause: {?}", .{reader.err}),
            else => std.log.warn("auth connection closed: {}", .{err}),
        };
    }

    fn connectionFiberInner(self: *Self, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
        var msg_buf: [512]u8 = undefined;

        var srp = SrpSession.empty();
        defer srp.deinit();

        var account_name_buf: [16]u8 = undefined;
        var account_name_len: usize = 0;

        var state: enum { wait_challenge, wait_proof, authenticated } = .wait_challenge;

        while (auth.Frame.readClientMessage(reader, msg_buf[0..])) |msg| {
            switch (msg) {
                .logon_challenge => |c| {
                    if (state != .wait_challenge) return error.IllegalState;

                    var account_row = db.auth.findByUsername(self.pool, c.username) catch |err| {
                        std.log.err("auth: account lookup failed: {}", .{err});
                        try sendPacket(writer, self.allocator, auth.AuthLogonServerChallengeFailure{ .result = 0x04 });
                        break;
                    } orelse {
                        std.log.warn("auth: unknown account {s}", .{c.username});
                        try sendPacket(writer, self.allocator, auth.AuthLogonServerChallengeFailure{ .result = 0x04 });
                        break;
                    };
                    defer account_row.deinit();

                    const srp_options = makeSrpInitOptions(&account_row);

                    srp = SrpSession.init(srp_options) catch {
                        try sendPacket(writer, self.allocator, auth.AuthLogonServerChallengeFailure{ .result = 0x04 });
                        break;
                    };

                    var b_priv: [32]u8 = undefined;
                    self.io.random(&b_priv);

                    const chal = srp.beginChallenge(b_priv, 0) catch {
                        try sendPacket(writer, self.allocator, auth.AuthLogonServerChallengeFailure{ .result = 0x04 });
                        break;
                    };

                    try sendPacket(writer, self.allocator, auth.AuthLogonServerChallengeSuccess{
                        .B = chal.b_pub_le,
                        .g = chal.g,
                        .N = chal.n_le,
                        .s = chal.salt,
                        .security_flags = chal.security_flags,
                    });

                    const account_name = account_row.username();
                    if (account_name.len > account_name_buf.len) {
                        try sendPacket(writer, self.allocator, auth.AuthLogonServerChallengeFailure{ .result = 0x04 });
                        break;
                    }
                    @memcpy(account_name_buf[0..account_name.len], account_name);
                    account_name_len = account_name.len;

                    state = .wait_proof;
                },
                .logon_proof => |p| {
                    if (state != .wait_proof) return error.IllegalState;

                    const result = srp.verifyProof(.{ .a_pub_le = p.A, .m1 = p.clientM }) catch {
                        try sendPacket(writer, self.allocator, auth.AuthLogonServerProofFailure{ .result = 0x04, .login_flags = 0 });
                        break;
                    };

                    const expires_at_ms = @as(i64, @intCast(self.clock.nowMs())) + auth_ticket_ttl_ms;
                    self.state.auth_tickets.put(self.io, account_name_buf[0..account_name_len], .{
                        .k = result.k,
                        .expires_at_ms = expires_at_ms,
                    }) catch {
                        try sendPacket(writer, self.allocator, auth.AuthLogonServerProofFailure{ .result = 0x04, .login_flags = 0 });
                        break;
                    };

                    try sendPacket(writer, self.allocator, auth.AuthLogonServerProofSuccess{
                        .M2 = result.m2,
                        .account_flags = 0x00800000,
                        .survey_id = 0,
                        .login_flags = 0,
                    });

                    state = .authenticated;
                },
                .realm_list => {
                    if (state != .authenticated) return error.IllegalState;

                    var arena = std.heap.ArenaAllocator.init(self.allocator);
                    defer arena.deinit();
                    const aa = arena.allocator();

                    const realms_slice = self.state.realms.load();
                    const entries = aa.alloc(auth.AuthRealmListServerResponse.RealmEntry, realms_slice.len) catch break;

                    for (realms_slice, 0..) |realm, i| {
                        const num_chars = db.char.countForRealmName(
                            self.pool,
                            account_name_buf[0..account_name_len],
                            realm.name,
                        ) catch |err| blk: {
                            std.log.warn("auth: failed to count characters for account={s} realm={s}: {}", .{
                                account_name_buf[0..account_name_len],
                                realm.name,
                                err,
                            });
                            break :blk 0;
                        };

                        entries[i] = .{
                            .realm_type = 0x01,
                            .locked = 0,
                            .flags = 0,
                            .name = realm.name,
                            .address = "127.0.0.1:8085",
                            .population = 0.5,
                            .num_chars = num_chars,
                            .timezone = 2,
                            .realm_id = realm.id,
                            .build_major = 3,
                            .build_minor = 3,
                            .build_patch = 5,
                            .build = 12340,
                            .has_build_info = false,
                        };
                    }

                    try sendPacket(writer, self.allocator, auth.AuthRealmListServerResponse{ .realms = entries });
                },
            }
        } else |err| return err;
    }
};

// ═══ Helpers ═══════════════════════════════════════════════════════════════════

fn sendPacket(writer: *std.Io.Writer, allocator: std.mem.Allocator, pkt: anytype) !void {
    const wire = try pkt.marshal(allocator);
    defer allocator.free(wire);

    std.debug.assert(wire.len > 0);
    std.debug.assert(wire[0] == @TypeOf(pkt).opcode.value());

    try writer.writeAll(wire);
    try writer.flush();
}

fn makeSrpInitOptions(record: *const db.auth.AccountRecord) SrpInitOptions {
    const username = record.username();
    const salt_bytes = record.salt();
    const verifier_bytes = record.verifier();
    if (salt_bytes.len != 32 or verifier_bytes.len != 32) {
        std.debug.panic(
            "auth: invalid persisted SRP material for account {s}: salt_len={d}, verifier_len={d}",
            .{ username, salt_bytes.len, verifier_bytes.len },
        );
    }

    return SrpInitOptions{
        .username = username,
        .salt = salt_bytes[0..32].*,
        .verifier_le = verifier_bytes[0..32].*,
    };
}
