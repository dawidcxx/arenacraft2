const std = @import("std");
const game_data = @import("game_data");
const Race = @import("Race.zig").Race;

/// Static ChrRaces.dbc-derived data for playable races, sourced from
/// `src/game_data/races.json`. Faction template ids come from
/// FactionTemplate.dbc, display ids from ChrRaces.dbc.
pub const RaceInfo = struct {
    faction_template: u32,
    male_display_id: u32,
    female_display_id: u32,
};

/// Keyed by ChrRaces id (1..8, 10, 11).
pub fn raceInfo(race_id: Race) ?RaceInfo {
    const idx = std.sort.binarySearch(
        RaceEntry,
        &sorted_races,
        LookupCtx{ .key = @intFromEnum(race_id) },
        compareRaceId,
    ) orelse return null;

    return sorted_races[idx].info;
}

pub fn displayId(race_id: Race, gender: u8) u32 {
    const info = raceInfo(race_id) orelse {
        std.debug.panic("Missing display_id of race_id={}", .{@intFromEnum(race_id)});
    };
    return if (gender == 0) info.male_display_id else info.female_display_id;
}

pub fn factionTemplate(race_id: Race) u32 {
    const info = raceInfo(race_id) orelse {
        std.debug.panic("Missing faction_template of race_id={}", .{@intFromEnum(race_id)});
    };
    return info.faction_template;
}

pub fn languageSpellIds(race_id: Race) []const u32 {
    return switch (race_id) {
        .human => &.{668},
        .orc => &.{669},
        .dwarf => &.{ 668, 672 },
        .night_elf => &.{ 668, 671 },
        .undead => &.{ 669, 17737 },
        .tauren => &.{ 669, 670 },
        .gnome => &.{ 668, 7340 },
        .troll => &.{ 669, 7341 },
        .blood_elf => &.{ 669, 813 },
        .draenei => &.{ 668, 29932 },
    };
}

pub fn languageSkillIds(race_id: Race) []const u16 {
    return switch (race_id) {
        .human => &.{98},
        .orc => &.{109},
        .dwarf => &.{ 98, 111 },
        .night_elf => &.{ 98, 113 },
        .undead => &.{ 109, 673 },
        .tauren => &.{ 109, 115 },
        .gnome => &.{ 98, 313 },
        .troll => &.{ 109, 315 },
        .blood_elf => &.{ 109, 137 },
        .draenei => &.{ 98, 759 },
    };
}

/// Chat language used for /say and /yell. PvP is faction-agnostic, so every
/// player speaks Common regardless of race.
pub const default_language_id: u32 = 7;

pub fn compareRaceId(ctx: LookupCtx, entry: RaceEntry) std.math.Order {
    return std.math.order(ctx.key, entry.race_id);
}

const RaceEntry = struct {
    race_id: u8,
    info: RaceInfo,
};

const sorted_races: [game_data.races.rows.len]RaceEntry = blk: {
    var arr: [game_data.races.rows.len]RaceEntry = undefined;
    for (game_data.races.rows, 0..) |row, i| {
        arr[i] = .{
            .race_id = @intCast(row.race_id),
            .info = .{
                .faction_template = @intCast(row.faction_template),
                .male_display_id = @intCast(row.male_display_id),
                .female_display_id = @intCast(row.female_display_id),
            },
        };
    }

    std.mem.sort(RaceEntry, &arr, {}, struct {
        fn lessThan(_: void, a: RaceEntry, b: RaceEntry) bool {
            return a.race_id < b.race_id;
        }
    }.lessThan);

    break :blk arr;
};

const LookupCtx = struct { key: u8 };

test "race data covers playable race ids" {
    inline for (@typeInfo(Race).@"enum".fields) |field| {
        const race_id: Race = @enumFromInt(field.value);
        try std.testing.expect(raceInfo(race_id) != null);
        try std.testing.expect(languageSpellIds(race_id).len > 0);
        try std.testing.expect(languageSkillIds(race_id).len > 0);
    }

    try std.testing.expectEqual(@as(u32, 1), factionTemplate(.human));
    try std.testing.expectEqual(@as(u32, 1629), factionTemplate(.draenei));
    try std.testing.expectEqual(@as(u32, 49), displayId(.human, 0));
    try std.testing.expectEqual(@as(u32, 15475), displayId(.blood_elf, 1));
    try std.testing.expectEqualSlices(u32, &.{668}, languageSpellIds(.human));
    try std.testing.expectEqualSlices(u16, &.{98}, languageSkillIds(.human));
    try std.testing.expectEqual(@as(u32, 7), default_language_id);
    try std.testing.expectEqualSlices(u32, &.{ 668, 672 }, languageSpellIds(.dwarf));
    try std.testing.expectEqualSlices(u16, &.{ 98, 111 }, languageSkillIds(.dwarf));
    try std.testing.expectEqualSlices(u32, &.{ 669, 670 }, languageSpellIds(.tauren));
    try std.testing.expectEqualSlices(u16, &.{ 109, 115 }, languageSkillIds(.tauren));
}
