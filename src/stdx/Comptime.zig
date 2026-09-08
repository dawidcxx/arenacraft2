//! Comptime collection helpers over comptime-known item arrays (game_data
//! rows, static tables): `filter` keeps matching items, `groupBy` buckets
//! items per variant of an id enum. All params are comptime, so every call
//! is evaluated at comptime and the results are frozen constants; runtime
//! use is plain slice reads.

const std = @import("std");

const EnumMeta = @import("EnumMeta.zig").EnumMeta;

/// Returns the items for which `pred(item)` is true, source order
/// preserved, as a frozen slice. The call must be comptime.
pub fn filter(
    comptime items: anytype,
    comptime pred: anytype,
) []const @TypeOf(items[0]) {
    const Item = @TypeOf(items[0]);

    // Comptime block: even with all-comptime params the body is
    // runtime-analyzed, where comptime_int mutables would be rejected.
    const out = comptime blk: {
        var count = 0;
        for (items) |item| {
            if (pred(item)) count += 1;
        }

        var buf: [count]Item = undefined;
        var i = 0;
        for (items) |item| {
            if (pred(item)) {
                buf[i] = item;
                i += 1;
            }
        }

        break :blk buf;
    };

    const frozen = out;
    return &frozen;
}

/// Buckets `items` per variant of the id enum `Key`: an item lands in
/// every group whose key it matches, so the relation is many-to-many
/// (mask-scoped rows land in several groups; keyOf-style rows in one).
/// Returns a plain slice indexed directly by id value, so groups are
/// reachable as `groups[some_key]`; ids not numbering from 0 waste their
/// leading slots. Group order follows the source. `Key` must satisfy the
/// EnumMeta contiguity check.
pub fn groupBy(
    comptime Key: type,
    comptime items: anytype,
    comptime matches: anytype,
) []const []const @TypeOf(items[0]) {
    const Item = @TypeOf(items[0]);
    const meta = EnumMeta(Key);

    const groups = comptime blk: {
        @setEvalBranchQuota(items.len * meta.count * 1000 + 100_000);

        var out_groups: [meta.max_value + 1][]const Item = undefined;
        for (meta.min_value..meta.max_value + 1) |id| {
            const key: Key = @enumFromInt(id);

            var count = 0;
            for (items) |item| {
                if (matches(item, key)) count += 1;
            }

            var slot: [count]Item = undefined;
            var remaining = count;
            var j = items.len;
            while (j > 0) {
                j -= 1;
                const item = items[j];
                if (matches(item, key)) {
                    remaining -= 1;
                    slot[remaining] = item;
                }
            }

            const frozen = slot;
            out_groups[id] = &frozen;
        }

        break :blk out_groups;
    };

    return &groups;
}

const testing = std.testing;

const Fruit = enum(u8) { apple = 1, banana = 2, cherry = 3, date = 4 };
const FruitMask = @import("Mask.zig").Mask(Fruit);

const Row = struct { label: []const u8, fruits: FruitMask };

fn fruitMatch(row: Row, fruit: Fruit) bool {
    return row.fruits.has(fruit);
}

fn isApple(row: Row) bool {
    return row.fruits.has(.apple);
}

const test_rows = [_]Row{
    .{ .label = "a", .fruits = FruitMask.of(.apple) },
    .{ .label = "b", .fruits = .{ .value = FruitMask.of(.apple).value | FruitMask.of(.cherry).value } },
    .{ .label = "c", .fruits = FruitMask.of(.banana) },
};

test "groupBy buckets items per key, many-to-many, order kept" {
    const by_fruit = groupBy(Fruit, &test_rows, fruitMatch);

    try testing.expectEqual(@as(usize, 5), by_fruit.len);

    try testing.expectEqual(@as(usize, 2), by_fruit[@intFromEnum(Fruit.apple)].len);
    try testing.expectEqualStrings("a", by_fruit[@intFromEnum(Fruit.apple)][0].label);
    try testing.expectEqualStrings("b", by_fruit[@intFromEnum(Fruit.apple)][1].label);

    // "b" matches two keys; each group keeps source order.
    try testing.expectEqual(@as(usize, 1), by_fruit[@intFromEnum(Fruit.cherry)].len);
    try testing.expectEqualStrings("b", by_fruit[@intFromEnum(Fruit.cherry)][0].label);

    // A variant no row matches yields an empty group.
    try testing.expectEqual(@as(usize, 0), by_fruit[@intFromEnum(Fruit.date)].len);
}

test "filter keeps matching items in order" {
    const apples = filter(&test_rows, isApple);

    try testing.expectEqual(@as(usize, 2), apples.len);
    try testing.expectEqualStrings("a", apples[0].label);
    try testing.expectEqualStrings("b", apples[1].label);

    const none = filter(test_rows, struct {
        fn pred(_: Row) bool {
            return false;
        }
    }.pred);
    try testing.expectEqual(@as(usize, 0), none.len);
}
