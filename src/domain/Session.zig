const std = @import("std");
const Arc = @import("stdx").Arc;

const Realm = @import("./Realm.zig").Realm;
const ObjectGuid = @import("./ObjectGuid.zig").ObjectGuid;
const MapId = @import("./MapId.zig").MapId;
const TimeSyncState = @import("./TimeSyncState.zig").TimeSyncState;

pub const Session = struct {
    account: []const u8,
    account_id: u64,
    active_realm: Realm,
    time_sync: TimeSyncState = .{},

    inbox: std.Io.Queue(InboxMsg),

    pub const InboxMsg = union(enum) {
        tick: void,
        kick: struct {
            callback: *std.Io.Semaphore,
        },
        send: SendPacket,
    };

    pub const SendPacket = struct { opcode: u32, body: Arc([]const u8) };

    const Self = @This();

    pub fn kick(self: *Self, io: std.Io) void {
        var callback: std.Io.Semaphore = .{};
        self.inbox.putOneUncancelable(io, .{ .kick = .{ .callback = &callback } }) catch unreachable;
        callback.waitUncancelable(io);
    }

    pub fn sendAsync(
        self: *Self,
        io: std.Io,
        opcode: u32,
        packet_body: Arc([]const u8),
    ) void {
        defer packet_body.release();
        self.inbox.putOne(io, .{
            .send = .{ .opcode = opcode, .body = packet_body.retain() },
        }) catch unreachable;
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator, io: std.Io) void {
        self.inbox.close(io); // todo: investigate this, queue probably to be closed by a owner.. ?
        alloc.free(self.account);
    }
};
