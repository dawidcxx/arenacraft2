const std = @import("std");
const db = @import("game_data_db");
const spells = @import("spells.zig");

const domain = @import("domain");

const Class = domain.Class;
const Race = domain.Race;

/// Login spell grants, from the game_data_db/initial_spells.zon rows.
/// Rows say which spell a character of a given class/race receives at
/// login; spell definitions themselves live in the spells lookup.
/// Restriction masks follow Class.Mask/Race.Mask (0 = wildcard).

const GrantRow = struct {
    spell_id: u32,
    class_mask: Class.Mask,
    race_mask: Race.Mask,
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

/// Spell ids granted at login to one character, ascending, deduped.
pub const GrantList = struct {
    ids: [max_granted]u32 = undefined,
    len: usize = 0,

    pub fn slice(self: *const GrantList) []const u32 {
        return self.ids[0..self.len];
    }
};

/// The login spell list for a character of `class_id`/`race_id`.
pub fn grantsFor(class_id: Class, race_id: Race) GrantList {
    var list = GrantList{};
    for (grant_rows) |row| {
        if (!matches(row, class_id, race_id)) continue;
        const spell_id = row.spell_id;

        // Overlapping rows can grant the same spell twice; the client
        // would render duplicate spellbook entries.
        var already = false;
        for (list.ids[0..list.len]) |id| {
            if (id == spell_id) already = true;
        }
        if (already) continue;

        list.ids[list.len] = spell_id;
        list.len += 1;
    }
    return list;
}

/// Whether any grant row references `spell_id`, regardless of masks.
/// Used to detect spells granted by both the spell and skill data files,
/// which would reach the client as duplicate spellbook entries.
pub fn grantsSpellId(spell_id: u32) bool {
    for (grant_rows) |row| {
        if (row.spell_id == spell_id) return true;
    }
    return false;
}

/// JSON rows converted to domain types, sorted by spell id so grant lists
/// come out ascending. Unknown spell ids, mask bits outside the playable
/// classes/races (asserted by the mask fromJson) and duplicate (spell,
/// class, race) triples are data bugs and fail the build.
const grant_rows: [db.initial_spells.rows.len]GrantRow = blk: {
    @setEvalBranchQuota(20_000);

    var sorted: [db.initial_spells.rows.len]db.initial_spells.Row = undefined;
    @memcpy(&sorted, db.initial_spells.rows);

    std.mem.sort(db.initial_spells.Row, &sorted, {}, struct {
        fn lessThan(_: void, a: db.initial_spells.Row, b: db.initial_spells.Row) bool {
            return a.spell_id < b.spell_id;
        }
    }.lessThan);

    var converted: [sorted.len]GrantRow = undefined;
    for (sorted, 0..) |row, i| {
        if (spells.findSpell(@intCast(row.spell_id)) == null) {
            @compileError(std.fmt.comptimePrint("initial_spells.zon references unknown spell entry: {d}", .{row.spell_id}));
        }

        converted[i] = .{
            .spell_id = @intCast(row.spell_id),
            .class_mask = Class.Mask.fromJson(row.class_mask),
            .race_mask = Race.Mask.fromJson(row.race_mask),
        };
    }

    for (1..converted.len) |i| {
        const a = converted[i - 1];
        const b = converted[i];
        if (a.spell_id == b.spell_id and a.class_mask.value == b.class_mask.value and a.race_mask.value == b.race_mask.value) {
            @compileError(std.fmt.comptimePrint("duplicate initial spell grant in game_data/db/initial_spells.zon: spell {d}", .{b.spell_id}));
        }
    }

    break :blk converted;
};

test "wildcard rows grant to every class and race" {
    const t = std.testing;

    inline for (@typeInfo(Class).@"enum".fields) |class_field| {
        inline for (@typeInfo(Race).@"enum".fields) |race_field| {
            const grants = grantsFor(@enumFromInt(class_field.value), @enumFromInt(race_field.value));
            try t.expectEqualSlices(u32, &.{ 116, 6603 }, grants.slice());
        }
    }
}

test "mask matching restricts by class and race" {
    const t = std.testing;

    const mage_row = GrantRow{ .spell_id = 116, .class_mask = Class.Mask.of(.mage), .race_mask = Race.Mask.all };
    const blood_elf_row = GrantRow{ .spell_id = 6603, .class_mask = Class.Mask.all, .race_mask = Race.Mask.of(.blood_elf) };

    try t.expect(matches(mage_row, .mage, .human));
    try t.expect(!matches(mage_row, .warrior, .human));
    try t.expect(matches(blood_elf_row, .mage, .blood_elf));
    try t.expect(!matches(blood_elf_row, .mage, .draenei));
}
