const std = @import("std");
const Realm = @import("domain").Realm;
const pg = @import("pg");
const db = @import("db");
const stdx = @import("stdx");

pub const ServerState = struct {
    auth_tickets: AuthTickets,
    realms: Realms,

    pub fn init(allocator: std.mem.Allocator) ServerState {
        return .{
            .auth_tickets = AuthTickets.init(allocator),
            .realms = Realms.init(allocator),
        };
    }

    pub const PopulateError = error{ QueryError, OutOfMemory };
    pub fn populate(self: *ServerState, pool: *pg.Pool) PopulateError!void {
        var realms = db.auth.fetchAllRealms(pool) catch {
            return PopulateError.QueryError;
        };
        defer realms.deinit();

        while (realms.next() catch
            return error.QueryError) |realm|
        {
            try self.realms.put(Realm{
                .id = realm.id(),
                .name = realm.realmname(),
            });
        }
    }

    pub fn deinit(self: *ServerState) void {
        self.realms.deinit();
        self.auth_tickets.deinit();
    }
};

pub const Realms = struct {
    arena: std.heap.ArenaAllocator,
    list: std.atomic.Value(?*std.ArrayList(Realm)) = .init(null),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
        self.list = .init(null);
    }

    pub fn load(self: *const Self) []const Realm {
        const l = self.list.load(.acquire) orelse return &.{};
        return l.items;
    }

    pub fn len(self: *const Self) usize {
        return self.load().len;
    }

    pub fn put(
        self: *Self,
        realm: Realm,
    ) std.mem.Allocator.Error!void {
        const aa = self.arena.allocator();
        const new_list = try aa.create(std.ArrayList(Realm));
        new_list.* = .empty;

        if (self.list.load(.acquire)) |old| {
            try new_list.appendSlice(aa, old.items);
        }
        try new_list.append(aa, .{
            .id = realm.id,
            .name = try aa.dupe(u8, realm.name),
        });

        _ = self.list.swap(new_list, .acq_rel);
    }

    pub fn findById(
        self: *const Self,
        id: u8,
    ) ?Realm {
        for (self.load()) |realm| {
            if (realm.id == id) return realm;
        }
        return null;
    }

    pub fn findByName(
        self: *const Self,
        name: []const u8,
    ) ?Realm {
        for (self.load()) |realm| {
            if (std.mem.eql(u8, realm.name, name)) return realm;
        }
        return null;
    }

    pub fn remove(
        self: *Self,
        id: u8,
    ) std.mem.Allocator.Error!bool {
        const old_list = self.list.load(.acquire) orelse return false;
        var found = false;

        const aa = self.arena.allocator();
        const new_list = try aa.create(std.ArrayList(Realm));
        new_list.* = .empty;

        for (old_list.items) |realm| {
            if (realm.id == id) {
                found = true;
                continue;
            }
            try new_list.append(aa, realm);
        }

        if (!found) return false;
        _ = self.list.swap(new_list, .acq_rel);
        return true;
    }
};

pub const AuthTickets = struct {
    allocator: std.mem.Allocator,
    lock: std.Io.RwLock = .init,
    tickets: std.StringHashMap(AuthTicket),

    pub fn init(allocator: std.mem.Allocator) AuthTickets {
        return .{
            .allocator = allocator,
            .tickets = std.StringHashMap(AuthTicket).init(allocator),
        };
    }

    pub fn deinit(self: *AuthTickets) void {
        var it = self.tickets.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.tickets.deinit();
    }

    pub fn put(self: *AuthTickets, io: std.Io, account: []const u8, ticket: AuthTicket) !void {
        const key = try self.allocator.dupe(u8, account);
        errdefer self.allocator.free(key);

        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        if (try self.tickets.fetchPut(key, ticket)) |old| {
            self.allocator.free(old.key);
            var old_ticket = old.value;
            old_ticket.deinit();
        }
    }

    pub fn take(self: *AuthTickets, io: std.Io, account: []const u8) ?AuthTicket {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        const removed = self.tickets.fetchRemove(account) orelse return null;
        self.allocator.free(removed.key);
        return removed.value;
    }

    pub fn getByAccount(self: *AuthTickets, io: std.Io, account: []const u8) ?AuthTicket {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);

        return self.tickets.get(account);
    }

    pub fn removeByAccount(self: *AuthTickets, io: std.Io, account: []const u8) bool {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        const removed = self.tickets.fetchRemove(account) orelse return false;
        self.allocator.free(removed.key);
        var ticket = removed.value;
        ticket.deinit();
        return true;
    }

    pub fn contains(self: *AuthTickets, io: std.Io, account: []const u8) bool {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        return self.tickets.contains(account);
    }
};

pub const AuthTicket = struct {
    k: [40]u8,
    expires_at_ms: i64,

    pub fn isExpired(self: AuthTicket, now_ms: i64) bool {
        return now_ms >= self.expires_at_ms;
    }

    pub fn deinit(self: *AuthTicket) void {
        @memset(&self.k, 0);
    }
};
