const std = @import("std");

// --- Big-endian readers/writers (authserver packets, port 3724) ---

pub fn recv4(bytes: []const u8, offset: usize) ![4]u8 {
    if (offset + 4 > bytes.len) return error.OutOfRange;
    var out: [4]u8 = undefined;
    @memcpy(&out, bytes[offset..][0..4]);
    std.mem.reverse(u8, &out);
    return out;
}

pub fn readU16BE(bytes: []const u8, offset: usize) !u16 {
    if (offset + 2 > bytes.len) return error.OutOfRange;
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}

pub fn readU32BE(bytes: []const u8, offset: usize) !u32 {
    if (offset + 4 > bytes.len) return error.OutOfRange;
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

// --- Little-endian readers/writers (world packets, port 8085) ---

pub fn readU16LE(bytes: []const u8, offset: usize) !u16 {
    if (offset + 2 > bytes.len) return error.OutOfRange;
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

pub fn readU32LE(bytes: []const u8, offset: usize) !u32 {
    if (offset + 4 > bytes.len) return error.OutOfRange;
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

pub fn readU64LE(bytes: []const u8, offset: usize) !u64 {
    if (offset + 8 > bytes.len) return error.OutOfRange;
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

pub fn writeU16LE(buf: []u8, offset: usize, val: u16) void {
    std.mem.writeInt(u16, buf[offset..][0..2], val, .little);
}

pub fn writeU32LE(buf: []u8, offset: usize, val: u32) void {
    std.mem.writeInt(u32, buf[offset..][0..4], val, .little);
}

pub fn writeU64LE(buf: []u8, offset: usize, val: u64) void {
    std.mem.writeInt(u64, buf[offset..][0..8], val, .little);
}

// --- Strings ---

pub fn readCString(bytes: []const u8, offset: usize) ![]const u8 {
    const end = std.mem.indexOfScalar(u8, bytes[offset..], 0) orelse return error.OutOfRange;
    return bytes[offset .. offset + end];
}

pub fn readU32LECursor(bytes: []const u8, off: *usize) !u32 {
    if (off.* + 4 > bytes.len) return error.OutOfRange;
    const value = std.mem.readInt(u32, bytes[off.*..][0..4], .little);
    off.* += 4;
    return value;
}

pub fn readCStringCursor(bytes: []const u8, off: *usize) ![]const u8 {
    const rel_end = std.mem.indexOfScalar(u8, bytes[off.*..], 0) orelse return error.OutOfRange;
    const start = off.*;
    off.* += rel_end + 1;
    return bytes[start .. start + rel_end];
}
