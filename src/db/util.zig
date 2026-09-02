const std = @import("std");
const pg = @import("pg");
const domain = @import("domain");

const ObjectGuid = domain.ObjectGuid;

pub fn guidFromDb(raw: i64) ObjectGuid {
    if (raw <= 0 or raw > std.math.maxInt(u32)) {
        std.debug.panic("db: invalid persisted guid={d}", .{raw});
    }
    return ObjectGuid.player(@intCast(raw));
}

pub fn readU8(row: pg.Row, index: usize) u8 {
    const value = row.get(i32, index) catch unreachable;
    if (value < 0 or value > std.math.maxInt(u8)) {
        std.debug.panic("db: invalid u8 field index={d} value={d}", .{ index, value });
    }
    return @intCast(value);
}

pub fn readU32(row: pg.Row, index: usize) u32 {
    const value = row.get(i32, index) catch unreachable;
    if (value < 0) {
        std.debug.panic("db: invalid u32 field index={d} value={d}", .{ index, value });
    }
    return @intCast(value);
}

const log = std.log.scoped(.db_module);

pub fn logPgError(comptime context: []const u8, conn: *pg.Conn) void {
    const pg_err = conn.err orelse return;
    log.err(
        "{s}: postgres code={s} severity={s} message={s} detail={s} hint={s} constraint={s} table={s} column={s}",
        .{
            context,
            pg_err.code,
            pg_err.severity,
            pg_err.message,
            pg_err.detail orelse "",
            pg_err.hint orelse "",
            pg_err.constraint orelse "",
            pg_err.table orelse "",
            pg_err.column orelse "",
        },
    );
}
