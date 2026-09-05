const std = @import("std");
const stdx = @import("stdx");
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
    const entry = table.find(@intFromEnum(race_id)) orelse return null;
    return entry.info;
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

fn mapRaceRow(comptime row: db.races.Row) RaceEntry {
    return .{
        .race_id = @intCast(row.race_id),
        .info = .{
            .faction_template = @intCast(row.faction_template),
            .male_display_id = @intCast(row.male_display_id),
            .female_display_id = @intCast(row.female_display_id),
        },
    };
}

const RaceEntry = struct {
    race_id: u8,
    info: RaceInfo,
};

const table = stdx.SortedTable(
    "game_data/db/races.zon",
    db.races.rows,
    mapRaceRow,
    .race_id,
);

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
