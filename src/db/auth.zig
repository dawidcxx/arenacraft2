const std = @import("std");
const pg = @import("pg");

pub const AccountRecord = struct {
    row: pg.QueryRow,

    pub fn deinit(self: *AccountRecord) void {
        self.row.deinit() catch |err| {
            std.log.warn("db: account row deinit failed: {}", .{err});
        };
    }

    pub fn username(self: *const AccountRecord) []const u8 {
        return self.row.get([]const u8, 0) catch unreachable;
    }

    pub fn salt(self: *const AccountRecord) []const u8 {
        return self.row.get([]const u8, 1) catch unreachable;
    }

    pub fn verifier(self: *const AccountRecord) []const u8 {
        return self.row.get([]const u8, 2) catch unreachable;
    }
};

pub fn findByUsername(pool: *pg.Pool, username_: []const u8) !?AccountRecord {
    const row = try pool.row(
        \\select username, salt, verifier
        \\from accounts
        \\where username = $1
        \\limit 1
    , .{username_});
    if (row) |r| {
        return .{ .row = r };
    }
    return null;
}

pub const AccountIdentityRecord = struct {
    row: pg.QueryRow,

    pub fn deinit(self: *AccountIdentityRecord) void {
        self.row.deinit() catch |err| {
            std.log.warn("db: account identity row deinit failed: {}", .{err});
        };
    }

    pub fn id(self: *const AccountIdentityRecord) u64 {
        return @intCast(self.row.get(i64, 0) catch unreachable);
    }

    pub fn username(self: *const AccountIdentityRecord) []const u8 {
        return self.row.get([]const u8, 1) catch unreachable;
    }
};

pub fn findIdentityByUsername(pool: *pg.Pool, username: []const u8) !?AccountIdentityRecord {
    const row = try pool.row(
        \\select id, username
        \\from accounts
        \\where username = $1
        \\limit 1
    , .{username});
    if (row) |r| {
        return .{ .row = r };
    }
    return null;
}

pub const RealmRow = struct {
    row: pg.Row,

    pub fn id(self: *const RealmRow) u8 {
        return @intCast(self.row.get(i16, 0) catch unreachable);
    }

    pub fn realmname(self: *const RealmRow) []const u8 {
        return self.row.get([]const u8, 1) catch unreachable;
    }
};

pub const RealmIterator = struct {
    result: *pg.Result,

    pub fn deinit(self: *RealmIterator) void {
        self.result.deinit();
    }

    pub fn next(self: *RealmIterator) !?RealmRow {
        const row = try self.result.next() orelse return null;
        return RealmRow{ .row = row };
    }
};

pub fn fetchAllRealms(pool: *pg.Pool) !RealmIterator {
    const result = try pool.query(
        \\SELECT id, realmname
        \\FROM realms
        \\ORDER BY realmname
    , .{});
    return RealmIterator{ .result = result };
}

pub const RealmRecord = struct {
    row: pg.QueryRow,

    pub fn deinit(self: *RealmRecord) void {
        self.row.deinit() catch |err| {
            std.log.warn("db: realm row deinit failed: {}", .{err});
        };
    }

    pub fn id(self: *const RealmRecord) u8 {
        return @intCast(self.row.get(i16, 0) catch unreachable);
    }

    pub fn realmname(self: *const RealmRecord) []const u8 {
        return self.row.get([]const u8, 1) catch unreachable;
    }
};

pub fn findRealmByWireId(pool: *pg.Pool, wire_realm_id: u8) !?RealmRecord {
    if (wire_realm_id == 0) return null;

    const row = try pool.row(
        \\SELECT id, realmname
        \\FROM realms
        \\WHERE id = $1
    , .{@as(i16, wire_realm_id)});
    if (row) |r| {
        return .{ .row = r };
    }
    return null;
}
