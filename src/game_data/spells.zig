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
        .power_cost = if (row.power_cost) |pc| @intCast(pc) else 0,
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
                .direct_melee_damage => .{ .direct_melee_damage = .{
                    .min = req(e.min, u32, "direct_melee_damage.min"),
                    .max = req(e.max, u32, "direct_melee_damage.max"),
                } },
                .apply_aura => .{ .apply_aura = .{
                    .duration_ms = req(e.duration, u24, "apply_aura.duration"),
                    .effects = mapAuraEffects(e.effects orelse @compileError("apply_aura effect requires an `effects` list (empty for a marker aura)")),
                } },
            };
        }
        break :blk built;
    };
    return &out;
}

fn mapAuraEffects(comptime effects: anytype) []const SpellDef.AuraEffect {
    const out = blk: {
        var built: [effects.len]SpellDef.AuraEffect = undefined;
        inline for (effects, 0..) |e, i| {
            built[i] = switch (e.type) {
                .movement_speed_mod => .{ .movement_speed_mod = .{
                    .pct = req(e.pct, i16, "movement_speed_mod.pct"),
                } },
                .periodic_damage => .{ .periodic_damage = .{
                    .interval_ms = req(e.interval_ms, u24, "periodic_damage.interval_ms"),
                    .min = req(e.min, u32, "periodic_damage.min"),
                    .max = req(e.max, u32, "periodic_damage.max"),
                } },
                .max_health_mod => .{ .max_health_mod = .{
                    .amount = req(e.amount, i32, "max_health_mod.amount"),
                } },
                .immune => .{ .immune = .{
                    .school_mask = req(e.school_mask, u8, "immune.school_mask"),
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
    try t.expectEqual(@as(u24, 5000), frostbolt.effects[1].apply_aura.duration_ms);
    try t.expectEqual(@as(i16, -40), frostbolt.effects[1].apply_aura.effects[0].movement_speed_mod.pct);

    const agony = spells_db.findSpellById(980) orelse return error.MissingSpell;
    try t.expectEqual(@as(u24, 3000), agony.effects[0].apply_aura.effects[0].periodic_damage.interval_ms);

    const ice_block = spells_db.findSpellById(45438) orelse return error.MissingSpell;
    try t.expectEqual(@as(u8, 127), ice_block.effects[0].apply_aura.effects[0].immune.school_mask);

    const fortitude = spells_db.findSpellById(21562) orelse return error.MissingSpell;
    try t.expectEqual(@as(i32, 50), fortitude.effects[0].apply_aura.effects[0].max_health_mod.amount);

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
