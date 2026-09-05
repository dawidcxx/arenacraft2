//! Spell entry lookup over the game_data_db/spells.zon rows, conforming
//! to domain.SpellDef. Duplicate entries fail the build.

const std = @import("std");
const stdx = @import("stdx");
const db = @import("game_data_db");
const domain = @import("domain");

const SpellDef = domain.SpellDef;

pub const spells_db = struct {
    pub fn findSpellById(spell_id: u32) ?SpellDef {
        return table.find(spell_id);
    }
};

fn mapSpellRow(comptime row: db.spells.Row) SpellDef {
    return .{
        .spell_id = @intCast(row.spell_id),
        .name = row.name,
        .school = stdx.mapEnum(SpellDef.School, row.school),
        .cast_time_ms = @intCast(row.cast_time_ms),
        .range_yards = @intCast(row.range_yards),
        .min_damage = @intCast(row.min_damage),
        .max_damage = @intCast(row.max_damage),
        .movement_slow_pct = @intCast(row.movement_slow_pct),
        .aura_duration_ms = @intCast(row.aura_duration_ms),
        .is_melee = row.is_melee,
    };
}

const table = stdx.SortedTable(
    "game_data/db/spells.zon",
    db.spells.rows,
    mapSpellRow,
    .spell_id,
);

test "spells_db finds entries as expected" {
    const t = std.testing;

    const auto_attack = spells_db.findSpellById(6603) orelse return error.MissingSpell;
    try t.expectEqual(domain.SpellDef.School.normal, auto_attack.school);
    try t.expectEqual(@as(u32, 0), auto_attack.cast_time_ms);
    try t.expectEqual(@as(u32, 5), auto_attack.range_yards);
    try t.expect(auto_attack.is_melee);

    try t.expect(spells_db.findSpellById(0) == null);
}
