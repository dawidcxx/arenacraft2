//! Parses the generated `game_data_db` rows into lookups that conform to
//! domain types. Plain data types themselves live in `domain`; this module
//! is where JSON rows become queryable game state inputs.

pub const character_create = @import("character_create.zig");
pub const items = @import("items.zig");
pub const spells = @import("spells.zig");
pub const initial_spells = @import("initial_spells.zig");
pub const equipment = @import("equipment.zig");
pub const races = @import("races.zig");

test {
    _ = @import("character_create.zig");
    _ = @import("items.zig");
    _ = @import("spells.zig");
    _ = @import("initial_spells.zig");
    _ = @import("equipment.zig");
    _ = @import("races.zig");
}
