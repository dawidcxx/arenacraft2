pub const character_create = @import("CharacterCreate.zig");
pub const ObjectGuid = @import("ObjectGuid.zig").ObjectGuid;
pub const items = @import("Items.zig");
pub const equipment = @import("Equipment.zig");
pub const races = @import("Races.zig");
pub const ClassId = @import("ClassId.zig").ClassId;
pub const PowerTypeId = @import("PowerTypeId.zig").PowerTypeId;
pub const Realm = @import("./Realm.zig").Realm;
pub const MapId = @import("./MapId.zig").MapId;
pub const Session = @import("./Session.zig").Session;
pub const TimeSyncState = @import("./TimeSyncState.zig").TimeSyncState;
pub const Movement = @import("./Movement.zig").Movement;
pub const Character = @import("./Character.zig").Character;
pub const Player = @import("./Player.zig").Player;

test {
    _ = @import("CharacterCreate.zig");
    _ = @import("ObjectGuid.zig");
    _ = @import("Items.zig");
    _ = @import("Equipment.zig");
    _ = @import("Races.zig");
    _ = @import("ClassId.zig");
    _ = @import("PowerTypeId.zig");
    _ = @import("Realm.zig");
    _ = @import("MapId.zig");
    _ = @import("Session.zig");
    _ = @import("TimeSyncState.zig");
    _ = @import("Movement.zig");
    _ = @import("Character.zig");
    _ = @import("Player.zig");
}
