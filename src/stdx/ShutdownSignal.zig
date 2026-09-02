const std = @import("std");
const posix = std.posix;

pub const ShutdownSignal = struct {
    requested: std.atomic.Value(bool) = .init(false),

    var active: ?*ShutdownSignal = null;

    pub fn installSignalHandlers(self: *ShutdownSignal) void {
        active = self;
        const action: posix.Sigaction = .{
            .handler = .{ .sigaction = handleSignal },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.SIGINFO | posix.SA.RESTART,
        };
        posix.sigaction(.INT, &action, null);
        posix.sigaction(.TERM, &action, null);
    }

    pub fn isShutdown(self: *const ShutdownSignal) bool {
        return self.requested.load(.acquire);
    }

    fn handleSignal(_: posix.SIG, _: *const posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
        if (active) |signal| {
            signal.requested.store(true, .release);
        }
    }
};
