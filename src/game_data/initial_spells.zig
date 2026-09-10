const std = @import("std");
const stdx = @import("stdx");
const db = @import("game_data_db");
const spells_db = @import("spells.zig").spells_db;

const domain = @import("domain");

const Class = domain.Class;
const Race = domain.Race;

pub const InitialSpell = struct {
    spell_id: u32,
    class_mask: Class.Mask,
    race_mask: Race.Mask,
};

pub const initial_spells_db = struct {
    const Self = @This();

    /// Grant rows whose race_mask covers `race` (wildcards included).
    /// Class scoping is left to the caller; see getAllFor. Spell ids
    /// ascending.
    pub fn getAllForRace(race: Race) []const InitialSpell {
        return rows_by_race[@intFromEnum(race)];
    }

    pub fn getAllForClass(class: Class) []const InitialSpell {
        return rows_by_class[@intFromEnum(class)];
    }

    pub fn getAllFor(gpa: std.mem.Allocator, class: Class, race: Race) ![]const InitialSpell {
        const racial_spells: []const InitialSpell = Self.getAllForRace(race);
        const class_spells: []const InitialSpell = Self.getAllForClass(class);
        const common_spells: []const InitialSpell = unscoped_rows;

        const total_len = racial_spells.len + class_spells.len + common_spells.len;

        var spell_list: std.ArrayList(InitialSpell) = try .initCapacity(gpa, total_len);
        errdefer spell_list.deinit(gpa);

        const spell_list_slice = spell_list.allocatedSlice();
        var offset: usize = 0;
        inline for (.{ racial_spells, class_spells, common_spells }) |src| {
            @memcpy(spell_list_slice[offset..][0..src.len], src);
            offset += src.len;
        }
        spell_list.items.len = total_len;

        return try spell_list.toOwnedSlice(gpa);
    }
};

const rows = stdx.SortedTable(
    "db/initial_spells.zon",
    db.initial_spells.rows,
    mapRow,
    .spell_id,
);

pub fn mapRow(row: db.initial_spells.Row) InitialSpell {
    return .{
        .spell_id = @intCast(row.spell_id),
        .class_mask = Class.Mask.fromJson(row.class_mask),
        .race_mask = Race.Mask.fromJson(row.race_mask),
    };
}

/// True when `spell_id` is granted to anyone by initial_spells.zon; used
/// by initial_skills to reject double grants at comptime.
pub fn grantsSpellId(spell_id: u32) bool {
    return rows.find(spell_id) != null;
}

/// One group per Race/Class variant; each slice keeps row order. Mask
/// scoping is many-to-many: one row lands in every group it matches.
const rows_by_race = stdx.groupBy(Race, rows.entries, selectByRace);
const rows_by_class = stdx.groupBy(Class, rows.entries, selectByClass);
const unscoped_rows = stdx.filter(rows.entries, selectUnmasked);

fn selectByRace(row: InitialSpell, race: Race) bool {
    return row.race_mask.has(race);
}

fn selectByClass(row: InitialSpell, klass: Class) bool {
    return row.class_mask.has(klass);
}

fn selectUnmasked(row: InitialSpell) bool {
    return row.class_mask.value == 0 and row.race_mask.value == 0;
}
