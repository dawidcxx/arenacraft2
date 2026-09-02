const std = @import("std");
const game_data = @import("game_data");

/// Static ChrRaces.dbc-derived data for playable races, sourced from
/// `src/game_data/races.json`. Faction template ids come from
/// FactionTemplate.dbc, display ids from ChrRaces.dbc.
pub const RaceInfo = struct {
    faction_template: u32,
    male_display_id: u32,
    female_display_id: u32,
};

/// Keyed by ChrRaces id (1..8, 10, 11).
pub fn raceInfo(race_id: u8) ?RaceInfo {
    const idx = std.sort.binarySearch(
        RaceEntry,
        &sorted_races,
        LookupCtx{ .key = race_id },
        compareRaceId,
    ) orelse return null;

    return sorted_races[idx].info;
}

pub fn displayId(race_id: u8, gender: u8) u32 {
    const info = raceInfo(race_id) orelse {
        std.debug.panic("Missing display_id of race_id={}", .{race_id});
    };
    return if (gender == 0) info.male_display_id else info.female_display_id;
}

pub fn factionTemplate(race_id: u8) u32 {
    const info = raceInfo(race_id) orelse {
        std.debug.panic("Missing faction_template of race_id={}", .{race_id});
    };
    return info.faction_template;
}

pub fn languageSpellIds(race_id: u8) []const u32 {
    return switch (race_id) {
        1 => &.{668},
        2 => &.{669},
        3 => &.{ 668, 672 },
        4 => &.{ 668, 671 },
        5 => &.{ 669, 17737 },
        6 => &.{ 669, 670 },
        7 => &.{ 668, 7340 },
        8 => &.{ 669, 7341 },
        10 => &.{ 669, 813 },
        11 => &.{ 668, 29932 },
        else => std.debug.panic("Missing language spells of race_id={}", .{race_id}),
    };
}

pub fn languageSkillIds(race_id: u8) []const u16 {
    return switch (race_id) {
        1 => &.{98},
        2 => &.{109},
        3 => &.{ 98, 111 },
        4 => &.{ 98, 113 },
        5 => &.{ 109, 673 },
        6 => &.{ 109, 115 },
        7 => &.{ 98, 313 },
        8 => &.{ 109, 315 },
        10 => &.{ 109, 137 },
        11 => &.{ 98, 759 },
        else => std.debug.panic("Missing language skills of race_id={}", .{race_id}),
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
    for ([_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 10, 11 }) |race_id| {
        try std.testing.expect(raceInfo(race_id) != null);
        try std.testing.expect(languageSpellIds(race_id).len > 0);
        try std.testing.expect(languageSkillIds(race_id).len > 0);
    }

    try std.testing.expectEqual(@as(u32, 1), factionTemplate(1));
    try std.testing.expectEqual(@as(u32, 1629), factionTemplate(11));
    try std.testing.expectEqual(@as(u32, 49), displayId(1, 0));
    try std.testing.expectEqual(@as(u32, 15475), displayId(10, 1));
    try std.testing.expectEqualSlices(u32, &.{668}, languageSpellIds(1));
    try std.testing.expectEqualSlices(u16, &.{98}, languageSkillIds(1));
    try std.testing.expectEqual(@as(u32, 7), default_language_id);
    try std.testing.expectEqualSlices(u32, &.{ 668, 672 }, languageSpellIds(3));
    try std.testing.expectEqualSlices(u16, &.{ 98, 111 }, languageSkillIds(3));
    try std.testing.expectEqualSlices(u32, &.{ 669, 670 }, languageSpellIds(6));
    try std.testing.expectEqualSlices(u16, &.{ 109, 115 }, languageSkillIds(6));
    try std.testing.expect(raceInfo(9) == null);
}
