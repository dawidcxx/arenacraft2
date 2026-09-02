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

test "domain module" {
    _ = character_create;
    _ = ObjectGuid;
    _ = items;
    _ = equipment;
    _ = races;
    _ = ClassId;
    _ = PowerTypeId;
    _ = Realm;
    _ = MapId;
    _ = Session;
    _ = TimeSyncState;
    _ = Movement;
    _ = Character;
    _ = Player;
}
