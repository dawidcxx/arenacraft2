//! Login skill grants, from the game_data_db/initial_skills.zon rows.
//! Rows say which skill (skill pane row + its paired spell) a character of
//! a given class/race receives at login; the catalog lives in the skills
//! lookup. Restriction masks follow Class.Mask/Race.Mask (0 = wildcard).

const std = @import("std");
const stdx = @import("stdx");
const db = @import("game_data_db");
const skills = @import("skills.zig");
const initial_spells = @import("initial_spells.zig");

const domain = @import("domain");

const Class = domain.Class;
const Race = domain.Race;

pub const InitialSkill = struct {
    skill_id: u16,
    class_mask: Class.Mask,
    race_mask: Race.Mask,
    max: u16,
};

pub const initial_skills_db = struct {
    const Self = @This();

    /// Grant rows whose race_mask covers `race` (wildcards included).
    /// Class scoping is left to the caller; see getAllFor. Skill ids
    /// ascending.
    pub fn getAllForRace(race: Race) []const InitialSkill {
        return rows_by_race[@intFromEnum(race)];
    }

    pub fn getAllForClass(class: Class) []const InitialSkill {
        return rows_by_class[@intFromEnum(class)];
    }

    /// All grant rows matching one character, ascending by skill id.
    /// Skill ids are unique across rows, so groups never overlap.
    pub fn getAllFor(gpa: std.mem.Allocator, class: Class, race: Race) ![]const InitialSkill {
        const racial_skills: []const InitialSkill = Self.getAllForRace(race);
        const class_skills: []const InitialSkill = Self.getAllForClass(class);
        const common_skills: []const InitialSkill = unscoped_rows;

        const total_len = racial_skills.len + class_skills.len + common_skills.len;

        var skill_list: std.ArrayList(InitialSkill) = try .initCapacity(gpa, total_len);
        errdefer skill_list.deinit(gpa);

        const skill_list_slice = skill_list.allocatedSlice();
        var offset: usize = 0;
        inline for (.{ racial_skills, class_skills, common_skills }) |src| {
            @memcpy(skill_list_slice[offset..][0..src.len], src);
            offset += src.len;
        }
        skill_list.items.len = total_len;

        return try skill_list.toOwnedSlice(gpa);
    }

    /// Spell ids implied by the skill grants for one character, ascending.
    /// These join the initial spell list so the client knows the paired spell.
    pub fn spellIdsFor(gpa: std.mem.Allocator, class: Class, race: Race) ![]const u32 {
        const all = try Self.getAllFor(gpa, class, race);
        defer gpa.free(all);

        const spell_ids = try gpa.alloc(u32, all.len);
        errdefer gpa.free(spell_ids);

        for (all, 0..) |row, i| {
            spell_ids[i] = skills.findSkill(row.skill_id).?.spell_id;
        }

        return spell_ids;
    }
};

const rows = stdx.SortedTable(
    "db/initial_skills.zon",
    db.initial_skills.rows,
    mapRow,
    .skill_id,
);

pub fn mapRow(comptime row: db.initial_skills.Row) InitialSkill {
    const skill = comptime skills.findSkill(@intCast(row.skill_id)) orelse {
        @compileError("initial_skills.zon references unknown skill id: " ++
            std.fmt.comptimePrint("{d}", .{row.skill_id}));
    };

    // A skill whose paired spell is also granted by initial_spells would
    // reach the client twice.
    if (comptime initial_spells.grantsSpellId(skill.spell_id)) {
        @compileError("spell " ++ std.fmt.comptimePrint("{d}", .{skill.spell_id}) ++
            " is granted by both initial_spells.zon and skills.zon " ++
            std.fmt.comptimePrint("{d}", .{skill.skill_id}));
    }

    const max: u16 = @intCast(row.max);

    return .{
        .skill_id = @intCast(row.skill_id),
        .class_mask = Class.Mask.fromJson(row.class_mask),
        .race_mask = Race.Mask.fromJson(row.race_mask),
        .max = max,
    };
}

/// One group per Race/Class variant; each slice keeps row order. Mask
/// scoping is many-to-many: one row lands in every group it matches.
const rows_by_race = stdx.groupBy(Race, rows.entries, selectByRace);
const rows_by_class = stdx.groupBy(Class, rows.entries, selectByClass);
const unscoped_rows = stdx.filter(rows.entries, selectUnmasked);

fn selectByRace(row: InitialSkill, race: Race) bool {
    return row.race_mask.has(race);
}

fn selectByClass(row: InitialSkill, klass: Class) bool {
    return row.class_mask.has(klass);
}

fn selectUnmasked(row: InitialSkill) bool {
    return row.class_mask.value == 0 and row.race_mask.value == 0;
}

test "wildcard rows grant to every class and race" {
    const t = std.testing;

    inline for (@typeInfo(Class).@"enum".fields) |class_field| {
        inline for (@typeInfo(Race).@"enum".fields) |race_field| {
            const grants = try initial_skills_db.getAllFor(t.allocator, @enumFromInt(class_field.value), @enumFromInt(race_field.value));
            defer t.allocator.free(grants);
            try t.expectEqualSlices(InitialSkill, &.{.{ .skill_id = 98, .class_mask = .{ .value = 0 }, .race_mask = .{ .value = 0 }, .max = 300 }}, grants);
        }
    }
}

test "skill grants imply their paired spell ids" {
    const t = std.testing;

    const ids = try initial_skills_db.spellIdsFor(t.allocator, .mage, .human);
    defer t.allocator.free(ids);
    try t.expectEqual(@as(usize, 1), ids.len);
    try t.expectEqual(@as(u32, 668), ids[0]);
}
