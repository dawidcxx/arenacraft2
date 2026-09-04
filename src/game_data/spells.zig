//! Spell entry lookup over the game_data_db/spells.json rows, conforming
//! to domain.SpellDef. Duplicate entries fail the build.

const std = @import("std");
const db = @import("game_data_db");
const domain = @import("domain");

const SpellDef = domain.SpellDef;

pub fn findSpell(entry: u32) ?SpellDef {
    const idx = std.sort.binarySearch(
        SpellDef,
        &sorted_spells,
        LookupCtx{ .key = entry },
        compareEntry,
    ) orelse return null;

    return sorted_spells[idx];
}

fn compareEntry(ctx: LookupCtx, spell: SpellDef) std.math.Order {
    return std.math.order(ctx.key, spell.entry);
}

const sorted_spells: [db.spells.rows.len]SpellDef = blk: {
    @setEvalBranchQuota(20_000);

    var arr: [db.spells.rows.len]SpellDef = undefined;
    for (db.spells.rows, 0..) |row, i| {
        arr[i] = .{
            .entry = @intCast(row.entry),
            .name = row.name,
            .school = @intCast(row.school),
            .cast_time_ms = @intCast(row.cast_time_ms),
            .range_yards = @intCast(row.range_yards),
            .min_damage = @intCast(row.min_damage),
            .max_damage = @intCast(row.max_damage),
            .movement_slow_pct = @intCast(row.movement_slow_pct),
            .aura_duration_ms = @intCast(row.aura_duration_ms),
            .is_melee = row.is_melee,
        };
    }

    std.mem.sort(SpellDef, &arr, {}, struct {
        fn lessThan(_: void, a: SpellDef, b: SpellDef) bool {
            return a.entry < b.entry;
        }
    }.lessThan);

    for (1..arr.len) |i| {
        if (arr[i].entry == arr[i - 1].entry)
            @compileError(std.fmt.comptimePrint("duplicate spell entry in game_data/db/spells.json: {d}", .{arr[i].entry}));
    }

    break :blk arr;
};

const LookupCtx = struct { key: u32 };

test "generated spell defs resolve known entries" {
    const t = std.testing;

    const frostbolt = findSpell(116) orelse return error.MissingSpell;
    try t.expectEqualStrings("Frostbolt", frostbolt.name);
    try t.expectEqual(domain.SpellDef.school_frost, frostbolt.school);
    try t.expectEqual(@as(u32, 1500), frostbolt.cast_time_ms);
    try t.expectEqual(@as(u32, 30), frostbolt.range_yards);
    try t.expectEqual(@as(u32, 18), frostbolt.min_damage);
    try t.expectEqual(@as(u32, 20), frostbolt.max_damage);
    try t.expectEqual(@as(u32, 40), frostbolt.movement_slow_pct);
    try t.expectEqual(@as(u32, 5000), frostbolt.aura_duration_ms);
    try t.expect(!frostbolt.is_melee);

    const auto_attack = findSpell(6603) orelse return error.MissingSpell;
    try t.expectEqual(domain.SpellDef.school_physical, auto_attack.school);
    try t.expectEqual(@as(u32, 0), auto_attack.cast_time_ms);
    try t.expectEqual(@as(u32, 5), auto_attack.range_yards);
    try t.expect(auto_attack.is_melee);

    try t.expect(findSpell(0) == null);
}
