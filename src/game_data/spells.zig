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
        .cast_time_ms = if (row.cast_time_ms) |ms| @intCast(ms) else null,
        .needs_target = row.needs_target orelse false,
        .range_yards = if (row.range_yards) |y| @intCast(y) else null,
        .effects = mapEffects(row),
        .projectile_speed = if (row.projectile_speed) |ps| @intCast(ps) else null,
    };
}

/// Discriminates the generic zon effect shape into domain.SpellDef.Effect,
/// enforcing each variant's required fields at comptime.
fn mapEffects(comptime row: db.spells.Row) []const SpellDef.Effect {
    const out = blk: {
        var built: [row.effects.len]SpellDef.Effect = undefined;
        inline for (row.effects, 0..) |e, i| {
            built[i] = switch (e.type) {
                .damage => .{ .damage = .{
                    .min = req(e.min, u32, "damage.min"),
                    .max = req(e.max, u32, "damage.max"),
                } },
                .movement_slow => .{ .movement_slow = .{
                    .duration = req(e.duration, u24, "movement_slow.duration"),
                    .pct = req(e.pct, u8, "movement_slow.pct"),
                } },
                .direct_melee_damage => .{ .direct_melee_damage = .{
                    .min = req(e.min, u32, "direct_melee_damage.min"),
                    .max = req(e.max, u32, "direct_melee_damage.max"),
                } },
            };
        }
        break :blk built;
    };
    return &out;
}

/// Unwraps a required effect field; a missing or `null` value is a data
/// authoring bug and fails the build with the field's path.
fn req(comptime value: ?i64, comptime T: type, comptime what: []const u8) T {
    return @intCast(value orelse @compileError("spells.zon effect requires `" ++ what ++ "`"));
}

const table = stdx.SortedTable(
    "game_data/db/spells.zon",
    db.spells.rows,
    mapSpellRow,
    .spell_id,
);

test "spells_db finds entries as expected" {
    const t = std.testing;

    const frostbolt = spells_db.findSpellById(116) orelse return error.MissingSpell;
    try t.expectEqual(domain.SpellDef.School.frost, frostbolt.school);
    try t.expectEqual(@as(u32, 1500), frostbolt.cast_time_ms.?);
    try t.expect(frostbolt.needs_target);
    try t.expectEqual(@as(u32, 30), frostbolt.range_yards.?);
    try t.expectEqual(2, frostbolt.effects.len);
    try t.expectEqual(@as(u32, 18), frostbolt.effects[0].damage.min);
    try t.expectEqual(@as(u32, 20), frostbolt.effects[0].damage.max);
    try t.expectEqual(@as(u24, 5000), frostbolt.effects[1].movement_slow.duration);
    try t.expectEqual(@as(u8, 40), frostbolt.effects[1].movement_slow.pct);

    const auto_attack = spells_db.findSpellById(6603) orelse return error.MissingSpell;
    try t.expect(auto_attack.cast_time_ms == null);
    try t.expect(!auto_attack.needs_target);
    try t.expectEqual(1, auto_attack.effects.len);
    try t.expectEqual(@as(u32, 3), auto_attack.effects[0].direct_melee_damage.min);
    try t.expectEqual(@as(u32, 4), auto_attack.effects[0].direct_melee_damage.max);

    const language_common = spells_db.findSpellById(668) orelse return error.MissingSpell;
    try t.expect(language_common.cast_time_ms == null);
    try t.expect(language_common.range_yards == null);
    try t.expectEqual(0, language_common.effects.len);

    try t.expect(spells_db.findSpellById(0) == null);
}
