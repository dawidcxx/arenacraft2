//! Comptime metadata for id enums: variant count and min/max tag values,
//! plus a contiguity check that fails the build when values have holes,
//! duplicates, or are declared out of order. Id enums mirror DBC row ids,
//! so holes are always data bugs, not something to work around.

const std = @import("std");

pub fn EnumMeta(comptime E: type) type {
    comptime {
        if (@typeInfo(E) != .@"enum") {
            @compileError("Meta requires an enum type, got " ++ @typeName(E));
        }

        const fields = @typeInfo(E).@"enum".fields;
        if (fields.len == 0) {
            @compileError("Meta requires a non-empty enum, got " ++ @typeName(E));
        }

        @setEvalBranchQuota(fields.len * 10 + 100);
        for (1..fields.len) |i| {
            if (fields[i].value != fields[i - 1].value + 1) {
                @compileError(std.fmt.comptimePrint(
                    "enum " ++ @typeName(E) ++ " values must be contiguous: '{s}' = {d} follows '{s}' = {d}",
                    .{ fields[i].name, fields[i].value, fields[i - 1].name, fields[i - 1].value },
                ));
            }
        }
    }

    return struct {
        /// The enum this metadata describes.
        pub const Enum = E;

        /// Number of variants.
        pub const count = @typeInfo(E).@"enum".fields.len;

        /// Lowest tag value (= first declared field, by contiguity).
        pub const min_value = @typeInfo(E).@"enum".fields[0].value;

        /// Highest tag value (= last declared field, by contiguity).
        pub const max_value = @typeInfo(E).@"enum".fields[count - 1].value;
    };
}

const testing = std.testing;

const Fruit = enum(u8) { apple = 1, banana = 2, cherry = 3 };

test "metadata over a contiguous enum" {
    const M = EnumMeta(Fruit);
    try testing.expectEqual(Fruit, M.Enum);
    try testing.expectEqual(@as(usize, 3), M.count);
    try testing.expectEqual(@as(u8, 1), M.min_value);
    try testing.expectEqual(@as(u8, 3), M.max_value);
}

test "zero-based enums are supported" {
    const Zeroed = enum(i16) { a = 0, b = 1, c = 2 };
    const M = EnumMeta(Zeroed);
    try testing.expectEqual(@as(usize, 3), M.count);
    try testing.expectEqual(@as(i16, 0), M.min_value);
    try testing.expectEqual(@as(i16, 2), M.max_value);
}
