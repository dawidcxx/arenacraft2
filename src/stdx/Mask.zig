//! Restriction bitmask over an id enum: one bit per variant, a zero
//! wildcard, and a `specified` union of every variant. For data rows that
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
        pub const specified: Self = blk: {
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
        /// `specified` are data bugs; asserts fire as compile errors when
        /// the conversion happens at comptime.
        pub fn fromJson(json_value: i64) Self {
            const value: u32 = @intCast(json_value);
            std.debug.assert(value & ~specified.value == 0);
            return .{ .value = value };
        }

        /// True when this mask is the wildcard or covers `id`.
        pub fn covers(self: Self, id: Id) bool {
            return self.value == 0 or self.has(id);
        }

        /// True only when the mask's bit for `id` is set; the wildcard
        /// does not match.
        pub fn has(self: Self, id: Id) bool {
            return self.value & of(id).value != 0;
        }

        /// Bitwise AND: true when `self` shares at least one bit with
        /// `other` — a single mask or a slice of masks ORed together.
        /// The wildcard carries no bits and never matches, like `has`.
        pub fn matchAnd(self: Self, other: anytype) bool {
            return self.value & flatten(other).value != 0;
        }

        /// Bitwise OR: `self` with every bit of `other` set — a single
        /// mask or a slice of masks.
        pub fn matchOr(self: Self, other: anytype) Self {
            return .{ .value = self.value | flatten(other).value };
        }

        /// Bitwise AND-NOT: `self` minus every bit of `other` — a single
        /// mask or a slice of masks.
        pub fn without(self: Self, other: anytype) Self {
            return .{ .value = self.value & ~flatten(other).value };
        }

        /// Collapses a mask, a slice of masks, or a tuple literal of masks
        /// (`&.{ a, b }`) into one mask so the set ops above stay plain bit
        /// algebra. Comptime type dispatch only; the fold is a plain loop.
        fn flatten(other: anytype) Self {
            const T = @TypeOf(other);
            const expected = "expected " ++ @typeName(Self) ++ " or a slice of it, got " ++ @typeName(T);
            switch (@typeInfo(T)) {
                .pointer => |ptr| switch (ptr.size) {
                    .slice => {
                        comptime if (ptr.child != Self) @compileError(expected);
                        var acc: u32 = 0;
                        for (other) |mask| acc |= mask.value;
                        return .{ .value = acc };
                    },
                    .one => switch (@typeInfo(ptr.child)) {
                        .array => |arr| {
                            comptime if (arr.child != Self) @compileError(expected);
                            var acc: u32 = 0;
                            for (other) |mask| acc |= mask.value;
                            return .{ .value = acc };
                        },
                        .@"struct" => |st| {
                            comptime if (!st.is_tuple) @compileError(expected);
                            inline for (st.fields) |field| {
                                comptime if (field.type != Self) @compileError(expected);
                            }
                            var acc: u32 = 0;
                            inline for (other) |mask| acc |= mask.value;
                            return .{ .value = acc };
                        },
                        else => @compileError(expected),
                    },
                    else => @compileError(expected),
                },
                else => {
                    comptime if (T != Self) @compileError(expected);
                    return other;
                },
            }
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
    try t.expectEqual(@as(u32, 0xB), FruitMask.specified.value);
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

test "has ignores the wildcard" {
    const t = std.testing;

    const Fruit = enum(u8) { apple = 1, banana = 2 };
    const FruitMask = Mask(Fruit);

    try t.expect(!FruitMask.all.has(.banana));
    try t.expect(FruitMask.of(.apple).has(.apple));
    try t.expect(!FruitMask.of(.apple).has(.banana));
    try t.expect(FruitMask.fromJson(FruitMask.of(.apple).value | FruitMask.of(.banana).value).has(.banana));
}

test "fromJson keeps known bits" {
    const t = std.testing;

    const Fruit = enum(u8) { apple = 1 };
    const FruitMask = Mask(Fruit);

    try t.expectEqual(@as(u32, 1), FruitMask.fromJson(1).value);
    try t.expectEqual(@as(u32, 0), FruitMask.fromJson(0).value);
}

test "set ops accept masks and slices" {
    const t = std.testing;

    const Fruit = enum(u8) { apple = 1, banana = 2, cherry = 4 };
    const FruitMask = Mask(Fruit);

    const apple_banana = FruitMask.of(.apple).matchOr(FruitMask.of(.banana));
    try t.expectEqual(@as(u32, 3), apple_banana.value);
    try t.expectEqual(@as(u32, 3), FruitMask.of(.apple).matchOr(&.{ FruitMask.of(.apple), FruitMask.of(.banana) }).value);

    try t.expect(apple_banana.matchAnd(FruitMask.of(.banana)));
    try t.expect(!apple_banana.matchAnd(FruitMask.of(.cherry)));
    try t.expect(apple_banana.matchAnd(&.{ FruitMask.of(.cherry), FruitMask.of(.apple) }));

    const apple_only = apple_banana.without(&.{ FruitMask.of(.banana), FruitMask.of(.cherry) });
    try t.expectEqual(@as(u32, 1), apple_only.value);
}
