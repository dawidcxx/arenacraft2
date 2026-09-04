const std = @import("std");
const ObjectGuid = @import("./ObjectGuid.zig").ObjectGuid;
const Session = @import("./Session.zig").Session;
const Class = @import("./Class.zig").Class;
const Race = @import("./Race.zig").Race;
const MapId = @import("./MapId.zig").MapId;
const Movement = @import("./Movement.zig").Movement;
const DerivedStats = @import("./CharacterStats.zig").DerivedStats;

pub const Character = struct {
    pub const max_name_len = 12;

    guid: ObjectGuid,
    name: [max_name_len + 1]u8 = .{0} ** (max_name_len + 1),

    map_id: MapId,

    class_id: Class,
    race_id: Race,
    gender: u8,
    skin: u8,
    face: u8,
    hair_style: u8,
    hair_color: u8,
    facial_hair: u8,
    level: u8,
    visible_items: [19]u32 = .{0} ** 19,
    /// Synthetic item instance guids per equipped slot (see
    /// Equipment.equippedInstanceGuid); zero when the slot is empty.
    item_guids: [19]u64 = .{0} ** 19,
    /// Stats derived from equipped items at login; base values until
    /// derived. See CharacterStats.
    derived: DerivedStats = .{},

    movement: Movement.State,

    const Self = @This();

    pub fn nameSlice(self: *const Self) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }

    pub fn update(self: *Self, character: Character) void {
        self.* = character;
    }
};
