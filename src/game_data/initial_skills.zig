const std = @import("std");
const db = @import("game_data_db");
const domain = @import("domain");
const skills = @import("skills.zig");
const initial_spells = @import("initial_spells.zig");

const Class = domain.Class;
const Race = domain.Race;

/// Login skill grants, from the game_data_db/initial_skills.json rows.
/// Rows say which skill (skill pane row + its paired spell) a character of
/// a given class/race receives at login; the catalog lives in the skills
/// lookup. Restriction masks follow Class.Mask/Race.Mask (0 = wildcard).

const GrantRow = struct {
    skill_id: u16,
    class_mask: Class.Mask,
    race_mask: Race.Mask,
    value: u16,
    max: u16,
};

fn matches(row: GrantRow, class_id: Class, race_id: Race) bool {
    return row.class_mask.covers(class_id) and row.race_mask.covers(race_id);
}

/// Worst-case grant list length over every class/race pair; sizes GrantList.
pub const max_granted: usize = blk: {
    @setEvalBranchQuota(100_000);

    var worst: usize = 0;
    for (@typeInfo(Class).@"enum".fields) |class_field| {
        for (@typeInfo(Race).@"enum".fields) |race_field| {
            var count: usize = 0;
            for (grant_rows) |row| {
                if (matches(row, @enumFromInt(class_field.value), @enumFromInt(race_field.value))) count += 1;
            }
            worst = @max(worst, count);
        }
    }
    break :blk worst;
};

/// Skill grants at login to one character, ascending, deduped.
pub const GrantList = struct {
    rows: [max_granted]domain.SkillGrant = undefined,
    len: usize = 0,

    pub fn slice(self: *const GrantList) []const domain.SkillGrant {
        return self.rows[0..self.len];
    }
};

/// The login skill list for a character of `class_id`/`race_id`.
pub fn grantsFor(class_id: Class, race_id: Race) GrantList {
    var list = GrantList{};
    for (grant_rows) |row| {
        if (!matches(row, class_id, race_id)) continue;
        const grant = domain.SkillGrant{ .skill_id = row.skill_id, .value = row.value, .max = row.max };

        // Overlapping rows can grant the same skill twice; the client
        // would render duplicate skill pane entries.
        var already = false;
        for (list.rows[0..list.len]) |g| {
            if (g.skill_id == grant.skill_id) already = true;
        }
        if (already) continue;

        list.rows[list.len] = grant;
        list.len += 1;
    }
    return list;
}

/// Spell ids implied by the skill grants for one character, ascending.
/// These join the initial spell list so the client knows the paired spell.
pub const SpellIdList = struct {
    ids: [max_granted]u32 = undefined,
    len: usize = 0,

    pub fn slice(self: *const SpellIdList) []const u32 {
        return self.ids[0..self.len];
    }
};

pub fn spellIdsFor(class_id: Class, race_id: Race) SpellIdList {
    var list = SpellIdList{};
    for (grantsFor(class_id, race_id).slice()) |grant| {
        list.ids[list.len] = skills.findSkill(grant.skill_id).?.spell_id;
        list.len += 1;
    }
    return list;
}

/// JSON rows converted to domain types, sorted by skill id so grant lists
/// come out ascending. Unknown skill ids, mask bits outside the playable
/// classes/races (asserted by the mask fromJson), inverted value/max and
/// duplicate (skill, class, race) triples are data bugs and fail the
/// build. A skill whose paired spell is also granted by initial_spells
/// would reach the client twice and fails the build too.
const grant_rows: [db.initial_skills.rows.len]GrantRow = blk: {
    @setEvalBranchQuota(20_000);

    var sorted: [db.initial_skills.rows.len]db.initial_skills.Row = undefined;
    @memcpy(&sorted, db.initial_skills.rows);

    std.mem.sort(db.initial_skills.Row, &sorted, {}, struct {
        fn lessThan(_: void, a: db.initial_skills.Row, b: db.initial_skills.Row) bool {
            return a.skill_id < b.skill_id;
        }
    }.lessThan);

    var converted: [sorted.len]GrantRow = undefined;
    for (sorted, 0..) |row, i| {
        const skill = skills.findSkill(@intCast(row.skill_id)) orelse {
            @compileError(std.fmt.comptimePrint("initial_skills.json references unknown skill id: {d}", .{row.skill_id}));
        };

        if (initial_spells.grantsSpellId(skill.spell_id)) {
            @compileError(std.fmt.comptimePrint("spell {d} is granted by both initial_spells.json and skills.json {d}", .{ skill.spell_id, skill.skill_id }));
        }

        const value: u16 = @intCast(row.value);
        const max: u16 = @intCast(row.max);
        if (value > max) {
            @compileError(std.fmt.comptimePrint("initial_skills.json skill {d} has value {d} above max {d}", .{ row.skill_id, value, max }));
        }

        converted[i] = .{
            .skill_id = @intCast(row.skill_id),
            .class_mask = Class.Mask.fromJson(row.class_mask),
            .race_mask = Race.Mask.fromJson(row.race_mask),
            .value = value,
            .max = max,
        };
    }

    for (1..converted.len) |i| {
        const a = converted[i - 1];
        const b = converted[i];
        if (a.skill_id == b.skill_id and a.class_mask.value == b.class_mask.value and a.race_mask.value == b.race_mask.value) {
            @compileError(std.fmt.comptimePrint("duplicate initial skill grant in game_data/db/initial_skills.json: skill {d}", .{b.skill_id}));
        }
    }

    break :blk converted;
};

test "wildcard rows grant to every class and race" {
    const t = std.testing;

    inline for (@typeInfo(Class).@"enum".fields) |class_field| {
        inline for (@typeInfo(Race).@"enum".fields) |race_field| {
            const grants = grantsFor(@enumFromInt(class_field.value), @enumFromInt(race_field.value));
            try t.expectEqualSlices(domain.SkillGrant, &.{.{ .skill_id = 98, .value = 300, .max = 300 }}, grants.slice());
        }
    }
}

test "skill grants imply their paired spell ids" {
    const t = std.testing;

    const ids = spellIdsFor(.mage, .human);
    try t.expectEqual(@as(usize, 1), ids.slice().len);
    try t.expectEqual(@as(u32, 668), ids.slice()[0]);
}
