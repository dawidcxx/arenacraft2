pub const auth = @import("auth.zig");
pub const char = @import("char.zig");
pub const util = @import("util.zig");

pub const Error = error{
    Timeout,
    WriteFailed,
    ConcurrencyUnavailable,
    Canceled,
    EndOfStream,
    ReadFailed,
    Closed,
    UnexpectedDBMessage,
    PG,
    PoolExhausted,
    ConnectionBusy,
    InvalidDataRow,
    WrongNumberOfParameters,
    InvalidUUID,
};

test "db module" {
    _ = auth;
    _ = char;
    _ = util;
}
