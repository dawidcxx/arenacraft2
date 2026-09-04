pub const ObjectGuid = @import("ObjectGuid.zig").ObjectGuid;
pub const ItemDef = @import("ItemDef.zig").ItemDef;
pub const SpellDef = @import("SpellDef.zig").SpellDef;
pub const SkillDef = @import("SkillDef.zig").SkillDef;
pub const SkillGrant = @import("SkillDef.zig").SkillGrant;
pub const equipment = @import("Equipment.zig");
pub const character_stats = @import("CharacterStats.zig");
pub const Class = @import("Class.zig").Class;
pub const Race = @import("Race.zig").Race;
pub const PowerTypeId = @import("PowerTypeId.zig").PowerTypeId;
pub const Realm = @import("./Realm.zig").Realm;
pub const MapId = @import("./MapId.zig").MapId;
pub const Session = @import("./Session.zig").Session;
pub const TimeSyncState = @import("./TimeSyncState.zig").TimeSyncState;
pub const Movement = @import("./Movement.zig").Movement;
pub const Character = @import("./Character.zig").Character;
pub const Player = @import("./Player.zig").Player;

test {
    _ = @import("ObjectGuid.zig");
    _ = @import("ItemDef.zig");
    _ = @import("SpellDef.zig");
    _ = @import("SkillDef.zig");
    _ = @import("Equipment.zig");
    _ = @import("CharacterStats.zig");
    _ = @import("Class.zig");
    _ = @import("Race.zig");
    _ = @import("PowerTypeId.zig");
    _ = @import("Realm.zig");
    _ = @import("MapId.zig");
    _ = @import("Session.zig");
    _ = @import("TimeSyncState.zig");
    _ = @import("Movement.zig");
    _ = @import("Character.zig");
    _ = @import("Player.zig");
}
