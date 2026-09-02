const Session = @import("./Session.zig").Session;
const Character = @import("./Character.zig").Character;

pub const Player = struct {
    account_id: Id,
    character: Character, // currently active character

    session: ?*Session,
    active_map_reference: ?*anyopaque,

    pub const Id = u64;

    const Self = @This();
};
