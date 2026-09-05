const std = @import("std");
const db = @import("game_data_db");
const domain = @import("domain");

const Race = domain.Race;

/// Static ChrRaces.dbc-derived data for playable races, sourced from
/// `src/game_data/races.zon`. Faction template ids come from
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

pub fn compareRaceId(ctx: LookupCtx, entry: RaceEntry) std.math.Order {
    return std.math.order(ctx.key, entry.race_id);
}

const RaceEntry = struct {
    race_id: u8,
    info: RaceInfo,
};

const sorted_races: [db.races.rows.len]RaceEntry = blk: {
    var arr: [db.races.rows.len]RaceEntry = undefined;
    for (db.races.rows, 0..) |row, i| {
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
    }

    try std.testing.expectEqual(@as(u32, 1), factionTemplate(.human));
    try std.testing.expectEqual(@as(u32, 1629), factionTemplate(.draenei));
    try std.testing.expectEqual(@as(u32, 49), displayId(.human, 0));
    try std.testing.expectEqual(@as(u32, 15475), displayId(.blood_elf, 1));
}
