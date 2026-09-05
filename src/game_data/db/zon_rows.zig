//! Shared reflection helper for the generated `game_data_db` module.
//!
//! `build.zig` pastes each `src/game_data/db/*.zon` file verbatim into a
//! generated `.zig` file as `const raw = <zon text>;`. ZON is a subset of
//! Zig expression syntax, so the Zig compiler itself parses and type-checks
//! the table. `Row` maps the raw comptime columns onto runtime types:
//! comptime_int -> i64, comptime_float -> f64, bool -> bool, string
//! literals -> []const u8, and enum literal columns (`.faction = .horde`)
//! -> an anonymous `enum` derived from the distinct literal names used.

const std = @import("std");

/// Runtime row type for a pasted ZON table. An empty table yields an empty
/// struct. Rows must be homogeneous: every row needs the same fields, and a
/// column may not mix kinds (write `1.0` for float columns; enum literal
/// columns must be enum literals in every row).
pub fn Row(comptime raw: anytype) type {
    const rows = @typeInfo(@TypeOf(raw)).@"struct".fields;
    if (rows.len == 0) return struct {};

    const columns = std.meta.fields(@TypeOf(@field(raw, rows[0].name)));
    comptime var names: [columns.len][]const u8 = undefined;
    comptime var types: [columns.len]type = undefined;
    inline for (columns, 0..) |f, j| {
        names[j] = f.name;
        types[j] = columnType(raw, f.name);
    }
    return @Struct(
        .auto,
        null,
        &names,
        &types,
        &@splat(std.builtin.Type.StructField.Attributes{}),
    );
}

fn columnType(comptime raw: anytype, comptime col: []const u8) type {
    const rows = @typeInfo(@TypeOf(raw)).@"struct".fields;
    const first = rowFieldType(@TypeOf(@field(raw, rows[0].name)), col);
    const enum_col = isEnumLiteral(first);
    inline for (rows[1..]) |rf| {
        const ft = rowFieldType(@TypeOf(@field(raw, rf.name)), col);
        if (enum_col != isEnumLiteral(ft)) {
            @compileError("zon column `" ++ col ++ "` mixes enum literals with other values (row " ++ rf.name ++ ")");
        }
    }
    if (enum_col) return enumLiteralType(raw, col);
    return scalarType(first);
}

fn isEnumLiteral(comptime T: type) bool {
    return @typeInfo(T) == .enum_literal;
}

/// Resolves a column's field type in a row struct, erroring if the row does
/// not have the column.
fn rowFieldType(comptime RowRaw: type, comptime col: []const u8) type {
    inline for (std.meta.fields(RowRaw)) |f| {
        if (std.mem.eql(u8, f.name, col)) return f.type;
    }
    @compileError("zon table row is missing column `" ++ col ++ "`");
}

fn scalarType(comptime T: type) type {
    return switch (T) {
        comptime_int => i64,
        comptime_float => f64,
        bool => bool,
        else => switch (@typeInfo(T)) {
            .pointer => |p| blk: {
                const is_string = p.size == .one and
                    @typeInfo(p.child) == .array and
                    @typeInfo(p.child).array.child == u8;
                if (!is_string) {
                    @compileError("unsupported zon column type `" ++ @typeName(T) ++
                        "` (supported: int, float, bool, string, enum literal)");
                }
                break :blk []const u8;
            },
            else => @compileError("unsupported zon column type `" ++ @typeName(T) ++
                "` (supported: int, float, bool, string, enum literal)"),
        },
    };
}

/// Synthesizes an anonymous enum from the distinct enum literal names used
/// in a column across all rows.
fn enumLiteralType(comptime raw: anytype, comptime col: []const u8) type {
    const rows = @typeInfo(@TypeOf(raw)).@"struct".fields;
    comptime var names: [rows.len][]const u8 = undefined;
    comptime var count: usize = 0;
    inline for (rows) |rf| {
        const name = @tagName(@field(@field(raw, rf.name), col));
        var seen = false;
        for (names[0..count]) |n| {
            if (std.mem.eql(u8, n, name)) seen = true;
        }
        if (!seen) {
            names[count] = name;
            count += 1;
        }
    }
    return @Enum(u32, .exhaustive, names[0..count], &std.simd.iota(u32, count));
}

/// Materializes a pasted ZON table as a comptime-known `[]const Row`.
pub fn materialize(comptime RowT: type, comptime raw: anytype) []const RowT {
    const raw_fields = @typeInfo(@TypeOf(raw)).@"struct".fields;
    const arr = blk: {
        var out: [raw_fields.len]RowT = undefined;
        inline for (raw_fields, 0..) |f, i| {
            const r = @field(raw, f.name);
            inline for (std.meta.fields(RowT)) |rf| {
                @field(out[i], rf.name) = @field(r, rf.name);
            }
        }
        break :blk out;
    };
    return &arr;
}

const testing = std.testing;

test "scalar columns map to runtime types" {
    const raw = .{
        .{ .id = 1, .name = "a", .ok = true, .ratio = 1.5 },
        .{ .id = 2, .name = "bb", .ok = false, .ratio = 2.5 },
    };
    const T = Row(raw);
    const rows = materialize(T, raw);
    try testing.expectEqual(2, rows.len);
    try testing.expectEqual(i64, @TypeOf(rows[0].id));
    try testing.expectEqual(f64, @TypeOf(rows[0].ratio));
    try testing.expectEqual([]const u8, @TypeOf(rows[0].name));
    try testing.expectEqualStrings("bb", rows[1].name);
    try testing.expectEqual(@as(f64, 2.5), rows[1].ratio);
}

test "enum literal columns derive a runtime enum" {
    const raw = .{
        .{ .id = 1, .faction = .horde },
        .{ .id = 2, .faction = .alliance },
        .{ .id = 3, .faction = .horde },
    };
    const T = Row(raw);
    const rows = materialize(T, raw);
    const Faction = @TypeOf(rows[0].faction);
    try testing.expectEqual(2, @typeInfo(Faction).@"enum".fields.len);
    try testing.expectEqualStrings("horde", @tagName(rows[0].faction));
    try testing.expectEqualStrings("alliance", @tagName(rows[1].faction));
    try testing.expectEqual(rows[0].faction, rows[2].faction);
    const n: u32 = switch (rows[0].faction) {
        .horde => 1,
        .alliance => 2,
    };
    try testing.expectEqual(@as(u32, 1), n);
}

test "enum and scalar columns coexist" {
    const raw = .{
        .{ .kind = .sword, .dmg = 10, .label = "short" },
        .{ .kind = .axe, .dmg = 12, .label = "hand" },
    };
    const T = Row(raw);
    const rows = materialize(T, raw);
    try testing.expectEqualStrings("axe", @tagName(rows[1].kind));
    try testing.expectEqual(@as(i64, 12), rows[1].dmg);
    try testing.expectEqualStrings("short", rows[0].label);
}

test "empty table yields empty row struct" {
    const raw = .{};
    const T = Row(raw);
    const rows = materialize(T, raw);
    try testing.expectEqual(0, rows.len);
}
