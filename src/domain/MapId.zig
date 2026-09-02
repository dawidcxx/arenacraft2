const std = @import("std");

pub const MapId = enum(u32) {
    eastern_kingdoms = 0,
    kalimdor = 1,
    outland = 530,
    acherus = 609,

    none_assigned = std.math.maxInt(u32),

    pub fn valueOf(self: MapId) u32 {
        return @intFromEnum(self);
    }
};
