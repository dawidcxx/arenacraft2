const std = @import("std");
const game_data = @import("game_data");

/// 3.3.5a spell school masks (SPELL_SCHOOL_MASK_*).
pub const school_physical: u8 = 0x01;
pub const school_frost: u8 = 0x10;

pub const SpellDef = struct {
    entry: u32,
    name: []const u8,
    /// SpellSchoolMask bitmask (see school_* constants).
    school: u8,
    /// 0 = instant. The client renders the cast bar from its own Spell.dbc;
    /// this drives the server-side cast delay.
    cast_time_ms: u32,
    /// Max cast/attack distance in yards.
    range_yards: u32,
    min_damage: u32,
    max_damage: u32,
    /// Movement speed reduction on hit, percent (0 = no aura effect).
    movement_slow_pct: u32,
    /// How long the aura entity lives (0 = no aura).
    aura_duration_ms: u32,
    /// Auto attack spells are driven by CMSG_ATTACKSWING, not the cast pipeline.
    is_melee: bool,
    /// Granted to every character at login (InitialSpells).
    auto_learn: bool,
};

pub fn findSpell(entry: u32) ?SpellDef {
    const idx = std.sort.binarySearch(
        SpellDef,
        &sorted_spells,
        LookupCtx{ .key = entry },
        compareEntry,
    ) orelse return null;

    return sorted_spells[idx];
}

/// Spell ids every character gets at login, ascending.
pub const auto_learned_spell_ids: [auto_learned_spell_count]u32 = blk: {
    @setEvalBranchQuota(10_000);

    var ids: [auto_learned_spell_count]u32 = undefined;
    var i = 0;
    for (sorted_spells) |spell| {
        if (spell.auto_learn) {
            ids[i] = spell.entry;
            i += 1;
        }
    }

    break :blk ids;
};

const auto_learned_spell_count = blk: {
    @setEvalBranchQuota(10_000);

    var count = 0;
    for (sorted_spells) |spell| {
        if (spell.auto_learn) count += 1;
    }
    break :blk count;
};

fn compareEntry(ctx: LookupCtx, spell: SpellDef) std.math.Order {
    return std.math.order(ctx.key, spell.entry);
}

const sorted_spells: [game_data.spells.rows.len]SpellDef = blk: {
    @setEvalBranchQuota(20_000);

    var arr: [game_data.spells.rows.len]SpellDef = undefined;
    for (game_data.spells.rows, 0..) |row, i| {
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
            .auto_learn = row.auto_learn,
        };
    }

    std.mem.sort(SpellDef, &arr, {}, struct {
        fn lessThan(_: void, a: SpellDef, b: SpellDef) bool {
            return a.entry < b.entry;
        }
    }.lessThan);

    for (1..arr.len) |i| {
        if (arr[i].entry == arr[i - 1].entry)
            @compileError(std.fmt.comptimePrint("duplicate spell entry in game_data/spells.json: {d}", .{arr[i].entry}));
    }

    break :blk arr;
};

const LookupCtx = struct { key: u32 };

test "generated spell defs resolve known entries" {
    const t = std.testing;

    const frostbolt = findSpell(116) orelse return error.MissingSpell;
    try t.expectEqualStrings("Frostbolt", frostbolt.name);
    try t.expectEqual(school_frost, frostbolt.school);
    try t.expectEqual(@as(u32, 1500), frostbolt.cast_time_ms);
    try t.expectEqual(@as(u32, 30), frostbolt.range_yards);
    try t.expectEqual(@as(u32, 18), frostbolt.min_damage);
    try t.expectEqual(@as(u32, 20), frostbolt.max_damage);
    try t.expectEqual(@as(u32, 40), frostbolt.movement_slow_pct);
    try t.expectEqual(@as(u32, 5000), frostbolt.aura_duration_ms);
    try t.expect(!frostbolt.is_melee);

    const auto_attack = findSpell(6603) orelse return error.MissingSpell;
    try t.expectEqual(school_physical, auto_attack.school);
    try t.expectEqual(@as(u32, 0), auto_attack.cast_time_ms);
    try t.expectEqual(@as(u32, 5), auto_attack.range_yards);
    try t.expect(auto_attack.is_melee);

    try t.expect(findSpell(0) == null);
}

test "auto learned spells list is ascending" {
    const t = std.testing;

    try t.expectEqualSlices(u32, &.{ 116, 6603 }, &auto_learned_spell_ids);
}
