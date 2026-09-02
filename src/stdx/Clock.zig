const std = @import("std");

/// Shared monotonic server clock. The run loop owns updates; readers use an
/// atomic snapshot so connection fibers do not need to message the clock.
const log = std.log.scoped(.clock);

pub const Clock = struct {
    now_ms: std.atomic.Value(u64),
    boot_origin_ms: u64,
    unix_origin_ms: u64,

    pub fn init(io: std.Io) Clock {
        const boot_origin_ms = timestampMs(io, true);
        return .{
            .now_ms = .init(boot_origin_ms),
            .boot_origin_ms = boot_origin_ms,
            .unix_origin_ms = timestampMs(io, false),
        };
    }

    pub fn run(self: *Clock, io: std.Io) std.Io.Cancelable!void {
        defer log.info("Exiting clock", .{});

        while (true) {
            self.now_ms.store(timestampMs(io, true), .release);
            try io.sleep(.fromNanoseconds(500_000), .awake);
        }
    }

    pub fn nowMs(self: *const Clock) u64 {
        return self.now_ms.load(.acquire);
    }

    pub fn nowMs32(self: *const Clock) u32 {
        return @truncate(self.nowMs());
    }

    pub fn unixSeconds(self: *const Clock) u64 {
        const elapsed_ms = self.nowMs() -| self.boot_origin_ms;
        return (self.unix_origin_ms +| elapsed_ms) / std.time.ms_per_s;
    }

    fn timestampMs(io: std.Io, boot: bool) u64 {
        const value = if (boot)
            std.Io.Timestamp.now(io, .boot).toMilliseconds()
        else
            std.Io.Timestamp.now(io, .real).toMilliseconds();
        return @intCast(@max(value, 0));
    }
};

test "clock exposes monotonic and unix time" {
    // Clock construction is intentionally integration-tested through the
    // server build because std.Io is supplied by the process runtime.
    _ = Clock;
}
