const std = @import("std");
const domain = @import("domain");
const MapInstance = @import("MapInstance.zig").MapInstance;
const Player = domain.Player;
const stdx = @import("stdx");

pub const WorldSimulation = struct {
    gpa: std.mem.Allocator,
    clock: *stdx.Clock,

    maps: MapInstanceContainer = .{},
    players: PlayerContainer = .{},

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator, clock: *stdx.Clock) Self {
        return .{
            .gpa = gpa,
            .clock = clock,
        };
    }

    pub fn deinit(self: *Self) void {
        self.maps.deinit(self.gpa);
        self.players.deinit(self.gpa);
    }

    pub fn run(self: *Self, io: std.Io) void {
        var group: std.Io.Group = .init;
        defer group.cancel(io);

        log.info("Runnig WorldSimulation", .{});
        defer log.info("Exiting WorldSimulation", .{});

        self.runInner(io, &group) catch |e| switch (e) {
            error.Canceled => return,
            else => {
                log.err("Premature exit of WorldSimulation, reason='{}'", .{e});
                return;
            },
        };
    }

    pub fn runInner(
        self: *Self,
        io: std.Io,
        group: *std.Io.Group,
    ) !void {
        const gpa = self.gpa;
        var ek_map_instance = try MapInstance.init(gpa, domain.MapId.eastern_kingdoms, self.clock);

        group.concurrent(io, MapInstance.run, .{ &ek_map_instance, io }) catch unreachable;

        try self.maps.addStatic(gpa, io, &ek_map_instance);

        // Park while the map fibers do the work; cancellation wakes us.
        // In the future we can handle root level World commands here
        // Map spawning etc
        while (true) {
            try io.sleep(.fromSeconds(3600), .awake);
        }
    }

    pub fn connectPlayer(
        self: *Self,
        io: std.Io,
        request: struct { player: Player },
    ) !void {
        if (self.players.get(io, request.player.account_id)) |player| {
            if (player.session) |old_session| {
                // terminate the prior session
                // waits for it to complete
                old_session.kick(io);
            }
            try self.players.updateCharacter(self.gpa, io, request.player);
        } else {
            try self.players.put(self.gpa, io, request.player);
        }
    }

    pub fn disconnectPlayer(
        self: *Self,
        io: std.Io,
        request: struct {
            account_id: u64,
        },
    ) void {
        if (self.players.get(io, request.account_id)) |player| {
            const map_ref: ?*MapInstance = @ptrCast(@alignCast(player.active_map_reference));
            if (map_ref) |map| map.leavePlayer(io, .{ .account_id = player.account_id });
            player.session = null;
            player.active_map_reference = null;
        }
    }

    pub fn joinMap(
        self: *Self,
        io: std.Io,
        request: struct {
            account_id: u64,
            map_id: domain.MapId,
        },
    ) std.Io.Cancelable!*Player {
        const map = self.maps.get(io, request.map_id) orelse {
            // NOTE: map/instance spawning system is missing
            // only static maps for now
            std.debug.panic("Unknown map requested, map_id='{}'", .{request.map_id});
        };
        const player = self.players.get(io, request.account_id) orelse {
            std.debug.panic("Tried to joinMap on a player that is not loadded: '{}'", .{request.account_id});
        };

        map.joinPlayer(io, .{
            .player = player,
        });

        player.active_map_reference = map;

        return player;
    }
};

pub const MapInstanceContainer = struct {
    lock: std.Io.RwLock = .init,
    storage: std.AutoHashMapUnmanaged(domain.MapId, union(enum) {
        static: *MapInstance,
        const Inner = @This();
        pub fn get(self: *const Inner) *MapInstance {
            return self.static;
        }
    }) = .empty,

    const Self = @This();

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        var storage_it = self.storage.valueIterator();
        while (storage_it.next()) |map_entry| map_entry.get().deinit();
        self.storage.deinit(alloc);
    }

    pub fn get(
        self: *Self,
        io: std.Io,
        map_id: domain.MapId,
    ) ?*MapInstance {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        if (self.storage.get(map_id)) |map|
            return map.get();
        return null;
    }

    pub fn addStatic(
        self: *Self,
        alloc: std.mem.Allocator,
        io: std.Io,
        map_ref: *MapInstance,
    ) !void {
        try self.lock.lock(io);
        defer self.lock.unlock(io);
        try self.storage.put(alloc, map_ref.map_id, .{ .static = map_ref });
    }
};

pub const PlayerContainer = struct {
    lock: std.Io.RwLock = .init,
    storage: std.AutoHashMapUnmanaged(u64, *Player) = .empty,
    by_active_char_guid: std.AutoHashMapUnmanaged(u64, *Player) = .empty,

    const Self = @This();

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        var it = self.storage.valueIterator();
        while (it.next()) |item| alloc.destroy(item.*);
        self.storage.deinit(alloc);
        self.by_active_char_guid.deinit(alloc);
    }

    pub fn get(self: *Self, io: std.Io, account_id: u64) ?*Player {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        return self.storage.get(account_id);
    }

    pub fn getByGuid(self: *Self, io: std.Io, guid: domain.ObjectGuid) ?*Player {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        return self.by_active_char_guid.get(guid.valueOf());
    }

    pub fn updateCharacter(
        self: *Self,
        alloc: std.mem.Allocator,
        io: std.Io,
        player: Player,
    ) !void {
        try self.lock.lock(io);
        defer self.lock.unlock(io);
        const gop = try self.storage.getOrPut(alloc, player.account_id);
        if (gop.found_existing) {
            const old_guid = gop.value_ptr.*.character.guid.valueOf();
            if (old_guid != player.character.guid.valueOf()) {
                if (self.by_active_char_guid.get(old_guid)) |old_player| {
                    if (old_player == gop.value_ptr.*)
                        _ = self.by_active_char_guid.remove(old_guid);
                }
            }
            gop.value_ptr.*.character.update(player.character);
            try self.by_active_char_guid.put(alloc, player.character.guid.valueOf(), gop.value_ptr.*);
        } else {
            const player_entry = try alloc.create(Player);
            errdefer alloc.destroy(player_entry);
            player_entry.* = player;
            gop.value_ptr.* = player_entry;
            try self.by_active_char_guid.put(alloc, player.character.guid.valueOf(), player_entry);
        }
    }

    pub fn put(self: *Self, alloc: std.mem.Allocator, io: std.Io, player: Player) !void {
        try self.lock.lock(io);
        defer self.lock.unlock(io);
        const heap_allocated_player = try alloc.create(Player);
        errdefer alloc.destroy(heap_allocated_player);
        heap_allocated_player.* = player;
        try self.storage.put(alloc, player.account_id, heap_allocated_player);
        try self.by_active_char_guid.put(alloc, player.character.guid.valueOf(), heap_allocated_player);
    }
};

const log = std.log.scoped(.world_simulation);
