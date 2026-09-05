//! Compile-time sorted lookup table over a fixed row source.
//!
//! Maps each row of a comptime-known slice (e.g. a generated game_data_db
//! `rows` value) to an entry, sorts the entries by a key field, rejects
//! duplicate keys with a compile error, and serves binary-search lookups.
//! The whole table is built at comptime; runtime use is just `find`.

const std = @import("std");

/// Builds a lookup type from:
///   - `source`: label used in duplicate-key compile errors
///   - `rows`:   comptime-known slice (or array) of row values
///   - `map`:    `fn (comptime Row) Entry`; may `@compileError` on invalid
///               rows. The param must be comptime so tag names and error
///               strings stay comptime-known, and the `@compileError`
///               must sit in a `comptime` block: at fn-body level the
///               check compiles to a runtime branch, whose bodies are
///               analyzed unconditionally, firing the error even when
///               the condition is false.
///   - `key`:    field of `Entry` used for ordering and lookup, passed as
///               `.field_name` (a std.meta.FieldEnum variant, so a
///               misspelled field is a compile error)
pub fn SortedTable(
    comptime source: []const u8,
    comptime rows: anytype,
    comptime map: anytype,
    comptime key: std.meta.FieldEnum(@TypeOf(map(rows[0]))),
) type {
    const Entry = @TypeOf(map(rows[0]));
    const key_name = @tagName(key);
    const KeyType = @FieldType(Entry, key_name);

    switch (@typeInfo(KeyType)) {
        .int => {},
        else => @compileError("key field '" ++ key_name ++ "' of " ++ @typeName(Entry) ++ " must be an int"),
    }

    return struct {
        /// Rows mapped to entries, sorted ascending by the key field.
        pub const entries: [rows.len]Entry = blk: {
            @setEvalBranchQuota(rows.len * 1000 + 100_000);

            var arr: [rows.len]Entry = undefined;
            for (rows, 0..) |row, i| {
                arr[i] = map(row);
            }

            std.mem.sort(Entry, &arr, {}, struct {
                fn lessThan(_: void, a: Entry, b: Entry) bool {
                    return @field(a, key_name) < @field(b, key_name);
                }
            }.lessThan);

            // The binary search only yields unambiguous results on strictly
            // increasing keys; duplicates are a data-authoring bug.
            for (1..arr.len) |i| {
                if (@field(arr[i], key_name) == @field(arr[i - 1], key_name)) {
                    @compileError(std.fmt.comptimePrint("duplicate {s} key in {s}: {d}", .{ key_name, source, @field(arr[i], key_name) }));
                }
            }

            break :blk arr;
        };

        /// Returns the entry whose key equals `k`, or null.
        pub fn find(k: KeyType) ?Entry {
            const idx = std.sort.binarySearch(Entry, &entries, k, struct {
                fn compare(ctx: KeyType, item: Entry) std.math.Order {
                    return std.math.order(ctx, @field(item, key_name));
                }
            }.compare) orelse return null;
            return entries[idx];
        }
    };
}

const testing = std.testing;

const TestRow = struct { id: i64, label: []const u8 };
const TestEntry = struct { id: u32, label: []const u8 };

fn mapTestRow(comptime row: TestRow) TestEntry {
    return .{ .id = @intCast(row.id), .label = row.label };
}

const test_rows = [_]TestRow{
    .{ .id = 3, .label = "c" },
    .{ .id = 1, .label = "a" },
    .{ .id = 2, .label = "b" },
};

const test_table = SortedTable("test rows", &test_rows, mapTestRow, .id);

test "SortedTable maps, sorts and finds" {
    try testing.expectEqual(@as(u32, 1), test_table.entries[0].id);
    try testing.expectEqual(@as(u32, 3), test_table.entries[2].id);

    const hit = test_table.find(2) orelse return error.MissingEntry;
    try testing.expectEqualStrings("b", hit.label);

    try testing.expect(test_table.find(4) == null);
}
