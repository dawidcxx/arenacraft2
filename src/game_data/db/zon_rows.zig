//! Shared reflection helper for the generated `game_data_db` module.
//!
//! `build.zig` pastes each `src/game_data/db/*.zon` file verbatim into a
//! generated `.zig` file as `const raw = <zon text>;`. ZON is a subset of
//! Zig expression syntax, so the Zig compiler itself parses and type-checks
//! the table. `Row` maps the raw comptime columns onto runtime types:
//! comptime_int -> i64, comptime_float -> f64, bool -> bool, string
//! literals -> []const u8, and enum literal columns (`.faction = .horde`)
//! -> an anonymous `enum` derived from the distinct literal names used.
//! A field that is `null` or omitted in any row makes its whole column
//! optional; a column whose values are lists (`.{ .{...}, ... }`) becomes
//! `[]const Elem` with the element struct inferred recursively; a column
//! whose concrete value kind varies across rows (int vs string vs enum
//! literal vs list, ...) is a compile error.

const std = @import("std");

/// Runtime row type for a pasted ZON table. An empty table yields an empty
/// struct. Rows must share the same column set; a field may be omitted or
/// `null` in any row, which makes the whole column optional (`?i64` etc.).
/// A column may not mix concrete value kinds (write `1.0` for float
/// columns; enum literal columns must be enum literals in every row that
/// has the column). A column whose values are lists of structs derives the
/// element struct from the union of all elements across all rows, the same
/// way, recursively.
pub fn Row(comptime raw: anytype) type {
    const rows = @typeInfo(@TypeOf(raw)).@"struct".fields;
    if (rows.len == 0) return struct {};

    comptime var names: []const []const u8 = &.{};
    inline for (rows) |rf| {
        inline for (std.meta.fields(@TypeOf(@field(raw, rf.name)))) |cf| {
            if (!containsName(names, cf.name)) names = names ++ &[_][]const u8{cf.name};
        }
    }
    comptime var types: [names.len]type = undefined;
    inline for (names, 0..) |name, j| {
        types[j] = columnType(raw, name);
    }
    return @Struct(
        .auto,
        null,
        names,
        &types,
        &@splat(std.builtin.Type.StructField.Attributes{}),
    );
}

fn containsName(comptime names: []const []const u8, comptime name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn columnType(comptime raw: anytype, comptime col: []const u8) type {
    const rows = @typeInfo(@TypeOf(raw)).@"struct".fields;
    comptime var base: type = @TypeOf(null);
    comptime var nested = false;
    comptime var nullable = false;
    inline for (rows) |rf| {
        const RowRaw = @TypeOf(@field(raw, rf.name));
        if (@hasField(RowRaw, col)) {
            const ft = rowFieldType(RowRaw, col);
            if (@typeInfo(ft) == .null) {
                nullable = true;
            } else if (isTupleType(ft)) {
                if (base != @TypeOf(null)) {
                    @compileError("zon column `" ++ col ++ "` mixes value kinds (row " ++ rf.name ++ ")");
                }
                nested = true;
            } else {
                if (nested) {
                    @compileError("zon column `" ++ col ++ "` mixes value kinds (row " ++ rf.name ++ ")");
                }
                if (base == @TypeOf(null)) {
                    base = ft;
                } else if (columnKind(base) != columnKind(ft)) {
                    @compileError("zon column `" ++ col ++ "` mixes value kinds (row " ++ rf.name ++ ")");
                }
            }
        } else {
            nullable = true;
        }
    }
    if (nested) {
        const Elem = nestedRowType(raw, col);
        return if (nullable) ?[]const Elem else []const Elem;
    }
    const ty = if (isEnumLiteral(base)) enumLiteralType(raw, col) else scalarType(base);
    return if (nullable) ?ty else ty;
}

fn isTupleType(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple;
}

/// Derives the element row type of a nested list column (e.g. an `effects`
/// list in every spell row) by flattening every element across all rows
/// into one flat tuple and running `Row` on it. The recursion makes
/// arbitrarily deep nesting work for free.
fn nestedRowType(comptime raw: anytype, comptime col: []const u8) type {
    const rows = @typeInfo(@TypeOf(raw)).@"struct".fields;

    comptime var count: usize = 0;
    inline for (rows) |rf| {
        const RowRaw = @TypeOf(@field(raw, rf.name));
        if (@hasField(RowRaw, col)) {
            const ft = rowFieldType(RowRaw, col);
            if (@typeInfo(ft) != .null) count += @typeInfo(ft).@"struct".fields.len;
        }
    }

    comptime var names: [count][]const u8 = undefined;
    comptime var types: [count]type = undefined;
    comptime var idx: usize = 0;
    inline for (rows) |rf| {
        const RowRaw = @TypeOf(@field(raw, rf.name));
        if (@hasField(RowRaw, col)) {
            const ft = rowFieldType(RowRaw, col);
            if (@typeInfo(ft) != .null) {
                inline for (@typeInfo(ft).@"struct".fields) |ef| {
                    names[idx] = ef.name;
                    types[idx] = ef.type;
                    idx += 1;
                }
            }
        }
    }

    const Flat = std.meta.Tuple(&types);
    const flat: Flat = blk: {
        var out: Flat = undefined;
        idx = 0;
        inline for (rows) |rf| {
            const RowRaw = @TypeOf(@field(raw, rf.name));
            if (@hasField(RowRaw, col)) {
                const ft = rowFieldType(RowRaw, col);
                if (@typeInfo(ft) != .null) {
                    const list = @field(@field(raw, rf.name), col);
                    inline for (@typeInfo(ft).@"struct".fields) |ef| {
                        @field(out, std.fmt.comptimePrint("{d}", .{idx})) = @field(list, ef.name);
                        idx += 1;
                    }
                }
            }
        }
        break :blk out;
    };
    return Row(flat);
}

/// Normalizes a concrete value type for cross-row kind comparison. String
/// literals of different lengths are distinct types but the same kind;
/// enum literals already share one type.
fn columnKind(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| blk: {
            const is_string = p.size == .one and
                @typeInfo(p.child) == .array and
                @typeInfo(p.child).array.child == u8;
            break :blk if (is_string) []const u8 else T;
        },
        else => T,
    };
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
        const RowRaw = @TypeOf(@field(raw, rf.name));
        if (@hasField(RowRaw, col) and @typeInfo(rowFieldType(RowRaw, col)) != .null) {
            const name = @tagName(@field(@field(raw, rf.name), col));
            if (!containsName(names[0..count], name)) {
                names[count] = name;
                count += 1;
            }
        }
    }
    return @Enum(u32, .exhaustive, names[0..count], &std.simd.iota(u32, count));
}

/// Materializes a pasted ZON table as a comptime-known `[]const Row`.
/// Fields a row omits get `null` (such columns are optional by inference);
/// nested list columns materialize recursively into `[]const Elem` slices.
pub fn materialize(comptime RowT: type, comptime raw: anytype) []const RowT {
    const raw_fields = @typeInfo(@TypeOf(raw)).@"struct".fields;
    const arr = blk: {
        var out: [raw_fields.len]RowT = undefined;
        inline for (raw_fields, 0..) |f, i| {
            const r = @field(raw, f.name);
            inline for (std.meta.fields(RowT)) |rf| {
                if (@hasField(@TypeOf(r), rf.name)) {
                    const val = @field(r, rf.name);
                    if (comptime isTupleType(@TypeOf(val))) {
                        @field(out[i], rf.name) = materialize(elemRowType(rf.type), val);
                    } else {
                        @field(out[i], rf.name) = val;
                    }
                } else {
                    @field(out[i], rf.name) = null;
                }
            }
        }
        break :blk out;
    };
    return &arr;
}

/// Unwraps a nested column's `?[]const Elem` (either part may be absent)
/// down to the element row type for recursive materialization.
fn elemRowType(comptime FT: type) type {
    return switch (@typeInfo(FT)) {
        .optional => |o| elemRowType(o.child),
        .pointer => |p| p.child,
        else => @compileError("zon nested column must be a list of structs"),
    };
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

test "null and omitted fields make columns optional" {
    const raw = .{
        .{ .id = 1, .n = 10, .label = "x" },
        .{ .id = 2, .n = null },
        .{ .id = 3 },
    };
    const T = Row(raw);
    const rows = materialize(T, raw);
    try testing.expectEqual(?i64, @TypeOf(rows[0].n));
    try testing.expectEqual(@as(i64, 10), rows[0].n.?);
    try testing.expect(rows[1].n == null);
    try testing.expect(rows[2].n == null);
    try testing.expectEqual(?[]const u8, @TypeOf(rows[0].label));
    try testing.expectEqualStrings("x", rows[0].label.?);
    try testing.expect(rows[1].label == null);
    try testing.expect(rows[2].label == null);
    try testing.expectEqual(@as(i64, 3), rows[2].id);
}

test "enum columns support null and omitted fields" {
    const raw = .{
        .{ .id = 1, .faction = .horde },
        .{ .id = 2, .faction = null },
        .{ .id = 3 },
    };
    const T = Row(raw);
    const rows = materialize(T, raw);
    try testing.expectEqualStrings("horde", @tagName(rows[0].faction.?));
    try testing.expect(rows[1].faction == null);
    try testing.expect(rows[2].faction == null);
}

test "nested list columns derive element structs" {
    const raw = .{
        .{ .id = 1, .effects = .{
            .{ .kind = .damage, .min = 3, .max = 4 },
            .{ .kind = .slow, .pct = 40 },
        } },
        .{ .id = 2, .effects = .{} },
    };
    const T = Row(raw);
    const rows = materialize(T, raw);
    const Elem = @typeInfo(@FieldType(T, "effects")).pointer.child;

    try testing.expectEqual([]const Elem, @FieldType(T, "effects"));
    try testing.expectEqual(2, rows[0].effects.len);
    try testing.expectEqual(@as(i64, 3), rows[0].effects[0].min.?);
    try testing.expectEqual(@as(i64, 4), rows[0].effects[0].max.?);
    try testing.expectEqualStrings("damage", @tagName(rows[0].effects[0].kind));
    try testing.expect(rows[0].effects[1].min == null);
    try testing.expectEqual(@as(i64, 40), rows[0].effects[1].pct.?);
    try testing.expectEqual(0, rows[1].effects.len);
}

test "omitted list columns are optional" {
    const raw = .{
        .{ .id = 1, .effects = .{ .{ .kind = .damage, .min = 1 } } },
        .{ .id = 2 },
    };
    const T = Row(raw);
    const rows = materialize(T, raw);
    const Elem = @TypeOf(rows[0].effects.?[0]);

    try testing.expectEqual(?[]const Elem, @FieldType(T, "effects"));
    try testing.expectEqual(@as(i64, 1), rows[0].effects.?[0].min.?);
    try testing.expect(rows[1].effects == null);
}

test "empty table yields empty row struct" {
    const raw = .{};
    const T = Row(raw);
    const rows = materialize(T, raw);
    try testing.expectEqual(0, rows.len);
}
