pub const TimeSyncState = struct {
    next_counter: u32 = 0,
    pending: ?Pending = null,
    /// Server clock minus client clock, in milliseconds.
    clock_delta_ms: i64 = 0,

    const Pending = struct {
        counter: u32,
        sent_ms: u32,
    };

    pub fn begin(self: *TimeSyncState, sent_ms: u32) u32 {
        const counter = self.next_counter;
        self.next_counter +%= 1;
        self.pending = .{
            .counter = counter,
            .sent_ms = sent_ms,
        };
        return counter;
    }

    pub fn complete(
        self: *TimeSyncState,
        now_ms: u32,
        counter: u32,
        client_time_ms: u32,
    ) ?i64 {
        const pending = self.pending orelse return null;
        if (pending.counter != counter) return null;

        self.pending = null;
        const round_trip_ms = now_ms -% pending.sent_ms;
        const server_time_at_client_response = @as(i64, pending.sent_ms) +
            @as(i64, round_trip_ms / 2);
        const clock_delta_ms = server_time_at_client_response - @as(i64, client_time_ms);
        self.clock_delta_ms = clock_delta_ms;
        return clock_delta_ms;
    }
};
