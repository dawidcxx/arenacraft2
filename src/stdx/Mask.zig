//! Restriction bitmask over an id enum: one bit per variant, a zero
//! wildcard, and a `playable` union of every variant. For data rows that
//! spec which ids a row applies to (login spell grants per class/race, ...).

const std = @import("std");

/// Builds a mask type for the enum `Id`. Bit layout is `1 << (id - 1)`,
/// so id variants must number from 1.
pub fn Mask(comptime Id: type) type {
    comptime {
        if (@typeInfo(Id) != .@"enum") {
            @compileError("Mask requires an enum id type, got " ++ @typeName(Id));
        }
    }

    return struct {
        const Self = @This();

        value: u32,

        /// Wildcard: applies to every id. Data files have no nullable
        /// columns (missing values become 0), so the wildcard rides on the
        /// zero default; a "no id" grant is meaningless, keeping the read
        /// unambiguous.
        pub const all: Self = .{ .value = 0 };

        /// Every id of `Id`, ORed together.
        pub const playable: Self = blk: {
            var union_mask: u32 = 0;
            for (@typeInfo(Id).@"enum".fields) |field| {
                union_mask |= of(@enumFromInt(field.value)).value;
            }
            break :blk .{ .value = union_mask };
        };

        /// The single-id mask for `id`.
        pub fn of(id: Id) Self {
            return .{ .value = @as(u32, 1) << @intCast(@intFromEnum(id) - 1) };
        }

        /// i64 data column -> mask. Negative values and bits outside
        /// `playable` are data bugs; asserts fire as compile errors when
        /// the conversion happens at comptime.
        pub fn fromJson(json_value: i64) Self {
            const value: u32 = @intCast(json_value);
            std.debug.assert(value & ~playable.value == 0);
            return .{ .value = value };
        }

        /// True when this mask is the wildcard or covers `id`.
        pub fn covers(self: Self, id: Id) bool {
            return self.value == 0 or self.value & of(id).value != 0;
        }
    };
}

test "mask bits follow id values, not declaration order" {
    const t = std.testing;

    const Fruit = enum(u8) { apple = 1, banana = 2, cherry = 4 };
    const FruitMask = Mask(Fruit);

    try t.expectEqual(@as(u32, 1), FruitMask.of(.apple).value);
    try t.expectEqual(@as(u32, 2), FruitMask.of(.banana).value);
    try t.expectEqual(@as(u32, 8), FruitMask.of(.cherry).value);
    try t.expectEqual(@as(u32, 0xB), FruitMask.playable.value);
}

test "mask covers honors the wildcard" {
    const t = std.testing;

    const Fruit = enum(u8) { apple = 1, banana = 2 };
    const FruitMask = Mask(Fruit);

    try t.expect(FruitMask.all.covers(.banana));
    try t.expect(FruitMask.of(.apple).covers(.apple));
    try t.expect(!FruitMask.of(.apple).covers(.banana));
    try t.expect(FruitMask.fromJson(FruitMask.of(.apple).value | FruitMask.of(.banana).value).covers(.banana));
}

test "fromJson keeps known bits" {
    const t = std.testing;

    const Fruit = enum(u8) { apple = 1 };
    const FruitMask = Mask(Fruit);

    try t.expectEqual(@as(u32, 1), FruitMask.fromJson(1).value);
    try t.expectEqual(@as(u32, 0), FruitMask.fromJson(0).value);
}
