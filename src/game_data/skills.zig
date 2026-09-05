//! Skill catalog over the game_data_db/skills.zon rows, conforming to
//! domain.SkillDef. Every skill pairs with the spell that represents it on
//! the wire; a skill whose spell is unknown is a data bug and fails the
//! build. Duplicate entries fail the build.

const std = @import("std");
const db = @import("game_data_db");
const domain = @import("domain");
const spells = @import("spells.zig");

const SkillDef = domain.SkillDef;

pub fn findSkill(skill_id: u16) ?SkillDef {
    const idx = std.sort.binarySearch(
        SkillDef,
        &sorted_skills,
        LookupCtx{ .key = skill_id },
        compareSkillId,
    ) orelse return null;

    return sorted_skills[idx];
}

fn compareSkillId(ctx: LookupCtx, skill: SkillDef) std.math.Order {
    return std.math.order(ctx.key, skill.skill_id);
}

const sorted_skills: [db.skills.rows.len]SkillDef = blk: {
    @setEvalBranchQuota(20_000);

    var arr: [db.skills.rows.len]SkillDef = undefined;
    for (db.skills.rows, 0..) |row, i| {
        if (spells.findSpell(@intCast(row.spell_id)) == null) {
            @compileError(std.fmt.comptimePrint("skills.zon references unknown spell entry: {d}", .{row.spell_id}));
        }

        arr[i] = .{
            .skill_id = @intCast(row.skill_id),
            .spell_id = @intCast(row.spell_id),
        };
    }

    std.mem.sort(SkillDef, &arr, {}, struct {
        fn lessThan(_: void, a: SkillDef, b: SkillDef) bool {
            return a.skill_id < b.skill_id;
        }
    }.lessThan);

    for (1..arr.len) |i| {
        if (arr[i].skill_id == arr[i - 1].skill_id)
            @compileError(std.fmt.comptimePrint("duplicate skill id in game_data/db/skills.zon: {d}", .{arr[i].skill_id}));
    }

    break :blk arr;
};

const LookupCtx = struct { key: u16 };

test "generated skill defs resolve known ids" {
    const t = std.testing;

    const language_common = findSkill(98) orelse return error.MissingSkill;
    try t.expectEqual(@as(u32, 668), language_common.spell_id);

    try t.expect(findSkill(0) == null);
}
