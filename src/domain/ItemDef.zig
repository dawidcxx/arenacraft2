//! Plain item definition type. The entry lookup over the JSON rows lives
//! in the game_data module.

pub const ItemDef = struct {
    /// 3.3.5a ItemModType ids for the stats our game data carries; the item
    /// query response lists stat bonuses with these type ids.
    pub const stamina_stat_id: u32 = 7;
    pub const intellect_stat_id: u32 = 5;

    entry: u32,
    display_id: u32,
    inventory_type: u8,
    name: []const u8,
    /// ItemClass.dbc id (armor, weapon, ...).
    item_class: u8,
    /// ItemSubClass.dbc id within the class (cloth, leather, ...).
    item_subclass: u8,
    /// Quality tier the client uses for the name color (0 poor .. 5 orange).
    quality: u8,
    stamina: u32,
    intellect: u32,
    armor: u32,
};
