const std = @import("std");
const net = std.Io.net;
const pg = @import("pg");
const db = @import("db");
const domain = @import("domain");
const protocol = @import("protocol");
const ServerState = @import("./ServerState.zig").ServerState;
const world_handler = @import("./world-handler/root.zig");
const world = @import("world");
const stdx = @import("stdx");

const WorldServerConnection = world_handler.WorldServerConnection;
const Session = domain.Session;
const character_commands = world_handler.character;
const login_handler = world_handler.login;
const item_handler = world_handler.item;

pub const log = std.log.scoped(.world_server);

pub const WorldServer = struct {
    const Self = @This();

    io: std.Io,
    allocator: std.mem.Allocator,
    pool: *pg.Pool,
    state: *ServerState,
    world_simulation: *world.WorldSimulation,
    clock: *stdx.Clock,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        pool: *pg.Pool,
        state: *ServerState,
        world_simulation: *world.WorldSimulation,
        clock: *stdx.Clock,
    ) Self {
        return .{
            .io = io,
            .allocator = allocator,
            .pool = pool,
            .state = state,
            .world_simulation = world_simulation,
            .clock = clock,
        };
    }

    pub fn run(self: *Self) void {
        const addr = net.IpAddress.parseIp4("0.0.0.0", 8085) catch unreachable;
        var server = addr.listen(self.io, .{ .reuse_address = true }) catch |e| {
            std.debug.panic("WorldServer failed to bind to network iface, reason={}", .{e});
        };
        defer server.deinit(self.io);

        var connections: std.Io.Group = .init;
        defer connections.cancel(self.io);

        log.info("Running WorldServer", .{});
        defer log.info("Exiting WorldServer", .{});

        while (true) {
            const stream = server.accept(self.io) catch |e| {
                if (e == error.Canceled) break;
                log.err("Failed to accept incoming connection: '{}'", .{e});
                continue;
            };

            connections.concurrent(
                self.io,
                Self.connectionFiber,
                .{ self, stream },
            ) catch unreachable;
        }
    }

    pub fn connectionFiber(self: *Self, stream: net.Stream) void {
        defer stream.close(self.io);

        var rx_buf: [4096]u8 = undefined;
        var reader = stream.reader(self.io, rx_buf[0..]);

        var tx_buf: [4096]u8 = undefined;
        var writer = stream.writer(self.io, tx_buf[0..]);

        self.connectionFiberInner(&reader.interface, &writer.interface) catch |err| {
            switch (err) {
                error.Canceled => {
                    log.debug("Canceled in connection fiber", .{});
                },
                WorldServerConnection.AuthenticateError.IllegalClientState => {
                    log.warn("Client Illegal state packet receiceved", .{});
                },
                error.EndOfStream => {
                    // Client connection interrupted abruptly
                    // TODO: consider adding some debug assertions here
                },
                else => {
                    log.err("Unexpected error in connection fiber: '{}'", .{err});
                },
            }
        };

        stream.shutdown(self.io, .both) catch |e| {
            log.debug("Error occured during stream shutdown, ignoring '{}'", .{e});
        };
    }

    fn connectionFiberInner(self: *Self, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const alloc = arena.allocator();

        var worldserver_connection = try WorldServerConnection.create(alloc, .{
            .reader = reader,
            .writer = writer,
        });
        defer worldserver_connection.destroy(alloc);

        try worldserver_connection.authenticate(alloc, self.io, self.state, self.clock);
        try sendWorldPreludePackets(alloc, worldserver_connection);

        var inbox_queue: [32]Session.InboxMsg = undefined;
        var session = try initSessionForAccount(
            alloc,
            self.pool,
            worldserver_connection.account_name.?,
            worldserver_connection.selected_realm.?,
            &inbox_queue,
        );
        defer {
            self.world_simulation.disconnectPlayer(self.io, .{
                .account_id = session.account_id,
            });
            session.deinit(alloc, self.io);
        }

        var player: ?*domain.Player = null;
        var payload_scratch_buf: [protocol.world.Frame.client_max_payload_size]u8 = undefined;

        var select_buf: [2]SelectEvent = undefined;
        var select = std.Io.Select(SelectEvent).init(self.io, &select_buf);
        defer select.cancelDiscard();

        select.concurrent(.packet, SelectEvent.getPacket, .{ worldserver_connection, &payload_scratch_buf }) catch unreachable;
        select.concurrent(.inbox_msg, SelectEvent.getInboxMessage, .{ self.io, &session }) catch unreachable;

        while (true) {
            switch (try select.await()) {
                .packet => |maybe_packet| {
                    const packet = try maybe_packet;

                    try dispatchPacket(
                        alloc,
                        self.io,
                        self.pool,
                        packet,
                        payload_scratch_buf[0..packet.payload_len],
                        worldserver_connection,
                        &session,
                        &player,
                        self.world_simulation,
                        self.clock,
                    );

                    select.concurrent(.packet, SelectEvent.getPacket, .{ worldserver_connection, &payload_scratch_buf }) catch unreachable;
                },
                .inbox_msg => |maybe_inbox_msg| {
                    const inbox_msg = try maybe_inbox_msg;

                    try dispatchInboxMessage(self.io, worldserver_connection, inbox_msg);

                    select.concurrent(.inbox_msg, SelectEvent.getInboxMessage, .{ self.io, &session }) catch unreachable;
                },
            }
        }
    }
};

fn dispatchInboxMessage(
    io: std.Io,
    conn: *WorldServerConnection,
    inbox_msg: Session.InboxMsg,
) !void {
    _ = io;

    switch (inbox_msg) {
        .tick => @panic("todo"),
        .kick => @panic("todo"),
        .send => |send_req| {
            var body = send_req.body;
            defer body.release();
            try conn.sendRawMessage(send_req.opcode, body.get());
        },
    }
}

fn dispatchPacket(
    alloc: std.mem.Allocator,
    io: std.Io,
    pool: *pg.Pool,
    header: protocol.world.Frame.Header,
    payload_scratch_buf: []u8,
    conn: *WorldServerConnection,
    session: *Session,
    player_ref: *?*domain.Player,
    sim: *world.WorldSimulation,
    clock: *stdx.Clock,
) !void {
    switch (header.opcode) {
        .cmsg_ping => {
            const ping_client = try protocol.world.PingClient.unmarshal(payload_scratch_buf);
            return try conn.sendMessage(alloc, protocol.world.PongServer{ .ping = ping_client.ping });
        },
        .cmsg_keep_alive => {
            // no-op
        },
        .cmsg_name_query => {
            const query = try protocol.world.NameQueryClient.unmarshal(payload_scratch_buf);
            if (sim.players.getByGuid(io, query.guid)) |player| {
                return try conn.sendMessage(alloc, protocol.world.NameQueryResponseServer{
                    .guid = query.guid,
                    .name = player.character.nameSlice(),
                    .race = player.character.race_id,
                    .gender = player.character.gender,
                    .class_id = @intFromEnum(player.character.class_id),
                });
            }
            return try conn.sendMessage(alloc, protocol.world.NameQueryResponseServer{
                .guid = query.guid,
                .name_unknown = true,
                .name = "",
                .race = 0,
                .gender = 0,
                .class_id = 0,
            });
        },
        .cmsg_messagechat => {
            const player = player_ref.*.?;
            return try world_handler.chat.handleMessageChat(io, player, payload_scratch_buf);
        },
        .cmsg_ready_for_account_data_times => {
            return try conn.sendMessage(alloc, protocol.world.AccountDataTimesServer{
                .unix_time = @intCast(clock.unixSeconds()),
            });
        },
        .cmsg_realm_split => {
            const realmsplit = try protocol.world.RealmSplitClient.unmarshal(payload_scratch_buf);
            return try conn.sendMessage(alloc, protocol.world.RealmSplitServer{ .value = realmsplit.value });
        },
        .cmsg_request_account_data => {
            // Account data is client-local for now. Do not send an empty
            // server blob that could overwrite the client's local settings.
            _ = try protocol.world.RequestAccountDataClient.unmarshal(payload_scratch_buf);
            return;
        },
        .cmsg_update_account_data => {
            const upd = try protocol.world.UpdateAccountDataClient.unmarshal(payload_scratch_buf);
            return try conn.sendMessage(alloc, protocol.world.UpdateAccountDataCompleteServer{ .typ = upd.typ });
        },
        .cmsg_time_sync_resp => {
            const response = try protocol.world.TimeSyncResponseClient.unmarshal(payload_scratch_buf);
            _ = session.time_sync.complete(
                clock.nowMs32(),
                response.counter,
                response.client_time_ms,
            );
        },
        .msg_move_start_forward,
        .msg_move_start_backward,
        .msg_move_stop,
        .msg_move_start_strafe_left,
        .msg_move_start_strafe_right,
        .msg_move_stop_strafe,
        .msg_move_jump,
        .msg_move_start_turn_left,
        .msg_move_start_turn_right,
        .msg_move_stop_turn,
        .msg_move_start_pitch_up,
        .msg_move_start_pitch_down,
        .msg_move_stop_pitch,
        .msg_move_set_run_mode,
        .msg_move_set_walk_mode,
        .msg_move_fall_land,
        .msg_move_start_swim,
        .msg_move_stop_swim,
        .msg_move_set_facing,
        .msg_move_set_pitch,
        .msg_move_heartbeat,
        => {
            const player = player_ref.*.?;
            const opcode = protocol.movement.MovementOpCode.fromOpcode(header.opcode);
            return try world_handler.movement.handleMovement(io, player, payload_scratch_buf, opcode);
        },
        .msg_move_worldport_ack => {
            // Client acked a teleporation, no-op for now
            // maybe can use it later
            return;
        },
        .cmsg_char_enum => {
            return try character_commands.handleEnum(alloc, pool, session, conn);
        },
        .cmsg_char_create => {
            return try character_commands.handleCreate(alloc, pool, session, conn, payload_scratch_buf);
        },
        .cmsg_char_delete => {
            return try character_commands.handleDelete(alloc, pool, session, conn, payload_scratch_buf);
        },
        .cmsg_player_login => {
            const signedin_player_ref = try login_handler.handlePlayerLogin(alloc, io, pool, session, conn, payload_scratch_buf, sim, clock);
            player_ref.* = signedin_player_ref;
            return;
        },
        .cmsg_item_query_single => {
            return try item_handler.handleItemQuerySingle(alloc, conn, payload_scratch_buf);
        },
        else => {
            return log.warn("Unhandled opcode in #dispatchPacket (opcode=0x{X}, account={s})", .{ header.opcode, session.account });
        },
    }
}

const WorldPreludeError = WorldServerConnection.ReadFrameError || WorldServerConnection.SendMessageError || std.mem.Allocator.Error || error{IllegalClientState};
fn sendWorldPreludePackets(
    alloc: std.mem.Allocator,
    conn: *WorldServerConnection,
) WorldPreludeError!void {
    try conn.sendMessage(alloc, protocol.world.AuthResponseServer.success(.wotlk));
    try conn.sendMessage(alloc, protocol.world.AddonInfoServer{
        .addons = conn.addon_info orelse &.{},
    });
    try conn.sendMessage(alloc, protocol.world.ClientCacheVersionServer{ .version = 0 });
    try conn.sendMessage(alloc, protocol.world.TutorialFlagsServer.allCompleted());
}

const SelectEvent = union(enum) {
    packet: GetPacketError!protocol.world.Frame.Header,
    inbox_msg: GetInboxMessageError!Session.InboxMsg,

    pub const GetPacketError = WorldServerConnection.ReadFrameError;

    pub fn getPacket(
        conn: *WorldServerConnection,
        buffer: *[protocol.world.Frame.client_max_payload_size]u8,
    ) GetPacketError!protocol.world.Frame.Header {
        return conn.readFrame(buffer);
    }

    pub const GetInboxMessageError = std.Io.Cancelable;

    pub fn getInboxMessage(
        io: std.Io,
        session: *Session,
    ) GetInboxMessageError!Session.InboxMsg {
        const msg = session.inbox.getOne(io) catch |e| {
            switch (e) {
                error.Closed => return GetInboxMessageError.Canceled,
                error.Canceled => return GetInboxMessageError.Canceled,
            }
        };
        return msg;
    }
};

fn initSessionForAccount(
    alloc: std.mem.Allocator,
    pool: *pg.Pool,
    account_name: []const u8,
    selected_realm: domain.Realm,
    inbox_buf: []Session.InboxMsg,
) !Session {
    var identity = try db.auth.findIdentityByUsername(pool, account_name) orelse {
        return error.AccountNotFound;
    };
    defer identity.deinit();

    const inbox_queue: std.Io.Queue(Session.InboxMsg) = .init(inbox_buf);

    return .{
        .account = try alloc.dupe(u8, identity.username()),
        .account_id = identity.id(),
        .active_realm = selected_realm,
        .inbox = inbox_queue,
    };
}
