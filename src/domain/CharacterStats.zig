//! Derives character stats from the equipped items. Called once at login;
//! equipment is immutable during a session for now, so the result rides on
//! the character until the next login.
//!
//! Formula (v1): max_health = base_health + stamina * health_per_stamina,
//! max_power = base_mana + intellect * mana_per_intellect for mana classes.
//! Non-mana classes do not benefit from intellect; their power stays at the
//! base until the stats that will drive rage/energy/runic power exist.

const std = @import("std");
const PowerTypeId = @import("PowerTypeId.zig").PowerTypeId;
const items = @import("Items.zig");

pub const base_health: u32 = 1000;
pub const base_mana: u32 = 1000;
pub const health_per_stamina: u32 = 10;
pub const mana_per_intellect: u32 = 15;

/// Indices into the client's UNIT_FIELD_STAT0..4 layout.
pub const StatIndex = enum(u8) {
    strength = 0,
    agility = 1,
    stamina = 2,
    intellect = 3,
    spirit = 4,

    pub const count: usize = 5;
};

/// Derived character stats. `base_stats` are the raw character attributes
/// (all zero in v1), `item_stats` the contribution from equipped gear; the
/// client's character pane displays their sum.
pub const DerivedStats = struct {
    max_health: u32 = base_health,
    max_power: u32 = base_mana,
    base_stats: [StatIndex.count]u32 = .{0} ** StatIndex.count,
    item_stats: [StatIndex.count]u32 = .{0} ** StatIndex.count,
    armor: u32 = 0,
};

/// Sums stat contributions across equipped items and derives the power
/// pools. `equipped` is indexed by equipment slot; unresolvable entries
/// (missing from game data) are `null` and contribute nothing.
pub fn derive(power_type: PowerTypeId, equipped: []const ?items.ItemDef) DerivedStats {
    var stats = DerivedStats{};

    for (equipped) |maybe_def| {
        const def = maybe_def orelse continue;
        stats.item_stats[@intFromEnum(StatIndex.stamina)] += def.stamina;
        stats.item_stats[@intFromEnum(StatIndex.intellect)] += def.intellect;
        stats.armor += def.armor;
    }

    stats.max_health = base_health +
        stats.item_stats[@intFromEnum(StatIndex.stamina)] * health_per_stamina;

    stats.max_power = switch (power_type) {
        .mana => base_mana +
            stats.item_stats[@intFromEnum(StatIndex.intellect)] * mana_per_intellect,
        // Rage/energy/runic power will be driven by stats that do not exist
        // yet; each power type gets its own formula here once they do.
        else => base_mana,
    };

    return stats;
}

test "empty equipment keeps base health mana and armor" {
    const t = std.testing;

    const equipped = [_]?items.ItemDef{null} ** 19;
    const stats = derive(.mana, &equipped);

    try t.expectEqual(base_health, stats.max_health);
    try t.expectEqual(base_mana, stats.max_power);
    try t.expectEqual(@as(u32, 0), stats.armor);
    try t.expectEqual([_]u32{0} ** StatIndex.count, stats.item_stats);
}

test "equipped items contribute stamina intellect and armor" {
    const t = std.testing;
    const equipment = @import("Equipment.zig");

    var equipped: [19]?items.ItemDef = .{null} ** 19;
    for (equipment.default_suit) |starter| {
        equipped[@intFromEnum(starter.slot)] = items.findItem(starter.item_entry);
    }

    const stats = derive(.mana, &equipped);

    // tuxedo: 12 + 10 + 8 stamina.
    try t.expectEqual(@as(u32, 30), stats.item_stats[@intFromEnum(StatIndex.stamina)]);
    // 1000 + 30 * 10.
    try t.expectEqual(@as(u32, 1300), stats.max_health);
    // tuxedo: 8 + 6 + 4 intellect.
    try t.expectEqual(@as(u32, 18), stats.item_stats[@intFromEnum(StatIndex.intellect)]);
    // 1000 + 18 * 15.
    try t.expectEqual(@as(u32, 1270), stats.max_power);
    // 150 + 120 + 90.
    try t.expectEqual(@as(u32, 360), stats.armor);
}

test "non-mana classes do not benefit from intellect" {
    const t = std.testing;
    const equipment = @import("Equipment.zig");

    var equipped: [19]?items.ItemDef = .{null} ** 19;
    for (equipment.default_suit) |starter| {
        equipped[@intFromEnum(starter.slot)] = items.findItem(starter.item_entry);
    }

    const stats = derive(.rage, &equipped);

    try t.expectEqual(base_health + 30 * health_per_stamina, stats.max_health);
    try t.expectEqual(base_mana, stats.max_power);
}
