//! Skill catalog over the game_data_db/skills.zon rows, conforming to
//! domain.SkillDef. Every skill pairs with the spell that represents it on
//! the wire; a skill whose spell is unknown is a data bug and fails the
//! build. Duplicate entries fail the build.

const std = @import("std");
const stdx = @import("stdx");
const db = @import("game_data_db");
const domain = @import("domain");
const spells_db = @import("spells.zig").spells_db;

const SkillDef = domain.SkillDef;

fn mapSkillRow(comptime row: db.skills.Row) SkillDef {
    comptime {
        if (spells_db.findSpellById(@intCast(row.spell_id)) == null) {
            @compileError(std.fmt.comptimePrint("skills.zon references unknown spell entry: {d}", .{row.spell_id}));
        }
    }

    return .{
        .skill_id = @intCast(row.skill_id),
        .spell_id = @intCast(row.spell_id),
    };
}

const table = stdx.SortedTable(
    "game_data/db/skills.zon",
    db.skills.rows,
    mapSkillRow,
    .skill_id,
);

pub fn findSkill(skill_id: u16) ?SkillDef {
    return table.find(skill_id);
}

test "generated skill defs resolve known ids" {
    const t = std.testing;

    const language_common = findSkill(98) orelse return error.MissingSkill;
    try t.expectEqual(@as(u32, 668), language_common.spell_id);

    try t.expect(findSkill(0) == null);
}
