const std = @import("std");

const domain = @import("domain");
const stdx = @import("stdx");
const MapEcs = @import("ecs/MapEcs.zig").MapEcs;
const MapInstanceInbox = @import("MapInstanceInbox.zig");
const InboxMsg = MapInstanceInbox.InboxMsg;

pub const MapInstance = struct {
    gpa: std.mem.Allocator,

    map_id: domain.MapId,
    clock: *stdx.Clock,
    last_tick_ms: u64,

    map_ecs: MapEcs,

    inbox_buf: [256]InboxMsg,
    inbox: std.Io.Queue(InboxMsg),

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator, map_id: domain.MapId, clock: *stdx.Clock) !Self {
        var instance = Self{
            .gpa = gpa,
            .map_id = map_id,
            .clock = clock,
            .last_tick_ms = clock.nowMs(),
            .map_ecs = try MapEcs.init(gpa),
            .inbox_buf = undefined,
            .inbox = undefined,
        };
        instance.inbox = .init(&instance.inbox_buf);
        return instance;
    }

    pub fn deinit(self: *Self) void {
        self.map_ecs.deinit();
    }

    pub fn pushMovementCommandAsync(self: *Self, io: std.Io, request: MapInstanceInbox.PlayerMove) void {
        self.inbox.putOne(io, .{ .player_move = request }) catch |e| {
            log.info("Dropping .pushMovementCommandAsync, reason='{}'", .{e});
        };
    }

    pub fn sendChatAsync(self: *Self, io: std.Io, request: MapInstanceInbox.Chat) void {
        self.inbox.putOne(io, .{ .chat = request }) catch |e| {
            log.info("Dropping .sendChatAsync, reason='{}'", .{e});
        };
    }

    pub fn pushCastSpellAsync(self: *Self, io: std.Io, request: MapInstanceInbox.CastSpell) void {
        self.inbox.putOne(io, .{ .cast_spell = request }) catch |e| {
            log.info("Dropping .pushCastSpellAsync, reason='{}'", .{e});
        };
    }

    pub fn pushCancelCastAsync(self: *Self, io: std.Io, request: MapInstanceInbox.CancelCast) void {
        self.inbox.putOne(io, .{ .cancel_cast = request }) catch |e| {
            log.info("Dropping .pushCancelCastAsync, reason='{}'", .{e});
        };
    }

    pub fn joinPlayer(
        self: *Self,
        io: std.Io,
        req: struct {
            player: *domain.Player,
        },
    ) void {
        var signal: std.Io.Semaphore = .{};
        self.inbox.putOneUncancelable(io, .{
            .player_join = .{
                .signal = &signal,
                .player = req.player,
            },
        }) catch unreachable;
        signal.waitUncancelable(io);
    }

    pub fn leavePlayer(self: *Self, io: std.Io, req: struct {
        account_id: u64,
    }) void {
        var signal: std.Io.Semaphore = .{};
        self.inbox.putOneUncancelable(io, .{ .player_leave = .{ .signal = &signal, .account_id = req.account_id } }) catch unreachable;
        signal.waitUncancelable(io);
    }

    pub fn run(self: *Self, io: std.Io) std.Io.Cancelable!void {
        self.runInner(io) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            else => {
                log.err("MapInstance exited with a error: {}", .{e});
            },
        };
    }

    fn runInner(self: *Self, io: std.Io) !void {
        var select_buf: [128]MapInstanceSelect = undefined;

        var select: std.Io.Select(MapInstanceSelect) = .init(io, &select_buf);
        defer select.cancelDiscard();
        select.concurrent(.inbox_message, MapInstanceSelect.getInboxMsg, .{ io, &self.inbox }) catch unreachable;
        select.concurrent(.tick, MapInstanceSelect.getTick, .{io}) catch unreachable;

        log.info("Running MapInstance ({})", .{self.map_id});
        defer log.info("Exiting MapInstance  ({})", .{self.map_id});

        var tick_counter: u16 = 0;

        while (true) {
            switch (try select.await()) {
                .inbox_message => |maybe_msg| {
                    const msg = try maybe_msg;
                    switch (msg) {
                        .player_join => |j| {
                            self.map_ecs.addInput(.{ .player_join = .{ .player = j.player } });
                            j.signal.post(io);
                        },
                        .player_leave => |l| {
                            self.map_ecs.addInput(.{ .player_leave = .{ .account_id = l.account_id } });
                            l.signal.post(io);
                        },
                        .player_move => |m| {
                            self.map_ecs.addInput(.{ .player_move = .{ .account_id = m.account_id, .packet = m.packet } });
                            // movement is async only, no ack
                        },
                        .chat => |chat| {
                            self.map_ecs.addInput(.{ .local_chat = .{ .account_id = chat.account_id, .packet = chat.packet } });
                            // chat is async only, no ack
                        },
                        .cast_spell => |c| {
                            self.map_ecs.addInput(.{ .cast_spell = .{ .account_id = c.account_id, .packet = c.packet } });
                            // cast is async only, no ack
                        },
                        .cancel_cast => |c| {
                            self.map_ecs.addInput(.{ .cancel_cast = .{ .account_id = c.account_id, .packet = c.packet } });
                            // cancel is async only, no ack
                        },
                    }

                    select.concurrent(.inbox_message, MapInstanceSelect.getInboxMsg, .{ io, &self.inbox }) catch unreachable;
                },
                .tick => {
                    tick_counter +%= 1;

                    // A single timestamp per tick keeps all systems consistent.
                    const now_ms = self.clock.nowMs();
                    try self.map_ecs.run(.{
                        .io = io,
                        .dt = now_ms - self.last_tick_ms,
                        .time_now = now_ms,
                        .clock = self.clock,
                        // TODO: provide actual arena here
                        .arena_allocator = self.gpa,
                    });
                    self.last_tick_ms = now_ms;

                    if (tick_counter % 1024 == 0) {
                        log.debug("1024 ticks has passed on the world simulation map instance (map_id='{}')", .{self.map_id});
                    }

                    select.concurrent(.tick, MapInstanceSelect.getTick, .{io}) catch unreachable;
                },
            }
        }
    }
};

const log = std.log.scoped(.map_instance);

const MapInstanceSelect = union(enum) {
    inbox_message: std.Io.Cancelable!InboxMsg,
    tick: std.Io.Cancelable!void,

    fn getTick(io: std.Io) std.Io.Cancelable!void {
        try io.sleep(.fromMilliseconds(8), .awake);
    }

    fn getInboxMsg(io: std.Io, queue: *std.Io.Queue(InboxMsg)) std.Io.Cancelable!InboxMsg {
        return queue.getOne(io) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            error.Closed => return error.Canceled,
        };
    }
};
