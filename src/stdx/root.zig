const std = @import("std");
pub const crypto = @import("./crypto/root.zig");
pub const srp6_session = @import("./crypto/Srp6Session.zig");
pub const StringList = @import("StringList.zig").StringList;
pub const Arc = @import("Arc.zig").Arc;
pub const ArcRuntime = @import("Arc.zig").ArcRuntime;
pub const Clock = @import("Clock.zig").Clock;
pub const ShutdownSignal = @import("ShutdownSignal.zig").ShutdownSignal;

pub const name = "stdx";

// ─── HEX DUMP HELPERS ────────────────────────────────────────────────────────

pub const hex_max_bytes = 128;

pub fn formatHex(buf: []u8, bytes: []const u8) []const u8 {
    const len = @min(bytes.len, hex_max_bytes);
    var off: usize = 0;
    for (bytes[0..len]) |b| {
        if (off > 0) {
            if (off >= buf.len - 1) break;
            buf[off] = ' ';
            off += 1;
        }
        if (off + 2 > buf.len) break;
        _ = std.fmt.bufPrint(buf[off..], "{X:0>2}", .{b}) catch break;
        off += 2;
    }
    if (bytes.len > hex_max_bytes) {
        const suffix = "...";
        if (off + suffix.len <= buf.len) {
            @memcpy(buf[off..][0..suffix.len], suffix);
            off += suffix.len;
        }
    }
    return buf[0..off];
}

// ─── HEX FORMATTER FOR {f} SPECIFIER ─────────────────────────────────────────

pub const HexFmt = struct {
    bytes: []const u8,
    max: usize = 8,

    pub fn format(self: HexFmt, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const n = @min(self.bytes.len, self.max);
        for (self.bytes[0..n], 0..) |b, i| {
            if (i > 0) try w.writeAll(" ");
            try w.print("{X:0>2}", .{b});
        }
        if (self.bytes.len > self.max) {
            try w.print("..+{d}", .{self.bytes.len - self.max});
        }
    }
};

// ─── IMMUTABLE FIELD UPDATE ──────────────────────────────────────────────────

/// The struct type behind a `with` receiver: method calls on a mutable
/// (`var`) receiver auto-reference to a pointer, so unwrap it.
fn WithSelfType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| ptr.child,
        else => T,
    };
}

/// Returns a copy of `self` with one field replaced. The field is a
/// comptime FieldEnum variant, so a misspelled field name or a wrong value
/// type is a compile error.
pub fn with(
    self: anytype,
    comptime field: std.meta.FieldEnum(WithSelfType(@TypeOf(self))),
    value: std.meta.fieldInfo(WithSelfType(@TypeOf(self)), field).type,
) WithSelfType(@TypeOf(self)) {
    var copy = switch (@typeInfo(@TypeOf(self))) {
        .pointer => self.*,
        else => self,
    };
    @field(copy, @tagName(field)) = value;
    return copy;
}

// ─── TEST ────────────────────────────────────────────────────────────────────

test "with returns a modified copy" {
    const Point = struct { x: f32, y: f32 = 0 };
    const p = Point{ .x = 1 };
    const q = with(p, .y, 5);
    try std.testing.expectEqual(@as(f32, 1), p.x);
    try std.testing.expectEqual(@as(f32, 0), p.y);
    try std.testing.expectEqual(@as(f32, 5), q.y);
    const r = with(p, .x, 9);
    try std.testing.expectEqual(@as(f32, 9), r.x);
}

test "with handles var receivers (auto-referenced to a pointer)" {
    const with_fn = with;
    const Point = struct {
        x: f32,
        y: f32 = 0,
        pub const with = with_fn;
    };
    var p = Point{ .x = 1 };
    const q = p.with(.y, 7);
    try std.testing.expectEqual(@as(f32, 0), p.y);
    try std.testing.expectEqual(@as(f32, 7), q.y);
}

test "formatHex basic" {
    var buf: [256]u8 = undefined;
    const got = formatHex(&buf, &.{ 0x00, 0x08, 0xAB, 0xFF });
    try std.testing.expectEqualStrings("00 08 AB FF", got);
}

test "formatHex empty" {
    var buf: [256]u8 = undefined;
    const got = formatHex(&buf, &.{});
    try std.testing.expectEqualStrings("", got);
}

test "formatHex truncation" {
    var buf: [1024]u8 = undefined;
    var big: [256]u8 = [_]u8{0xAA} ** 256;
    const got = formatHex(&buf, &big);
    try std.testing.expect(got.len < buf.len);
    try std.testing.expect(std.mem.startsWith(u8, got, "AA AA AA "));
    try std.testing.expect(std.mem.endsWith(u8, got, "..."));
}

test "srp6 module loads" {
    _ = crypto.srp6;
    _ = srp6_session.SrpSession;
}
