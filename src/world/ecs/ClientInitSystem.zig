const domain = @import("domain");
const ecs = @import("ecs");
const protocol = @import("protocol");

const EcsEventType = @import("EcsInput.zig").EcsEventType;
const component = @import("EcsComponent.zig");
const MapEcs = @import("MapEcs.zig").MapEcs;

const placeholder_map = domain.MapId.eastern_kingdoms;
const initial_zone_id: u32 = 12;

/// Sends client initialization after the player's self create update.
pub fn run(map_ecs: *MapEcs, frame: MapEcs.Frame) !void {
    const joined = map_ecs.events.get(EcsEventType.player_joined);
    for (joined.items) |event| try sendClientInit(map_ecs, frame, event.player_joined.player);
}

fn sendClientInit(map_ecs: *MapEcs, frame: MapEcs.Frame, entity: ecs.Entity) !void {
    const registry = &map_ecs.registry;
    const position = registry.getConst(component.Position, entity);
    const appearance = registry.getConst(component.Appearance, entity);
    const session = registry.getConst(component.Player, entity).session;

    try map_ecs.sendTo(entity, protocol.world.BindPointUpdateServer{
        .x = position.x,
        .y = position.y,
        .z = position.z,
        .map_id = placeholder_map.valueOf(),
        .area_id = initial_zone_id,
    });
    try map_ecs.sendTo(entity, protocol.world.TalentsInfoServer{});

    const language_spell_ids = domain.races.languageSpellIds(appearance.race_id);
    try map_ecs.sendTo(entity, protocol.world.InitialSpellsServer{ .spells = language_spell_ids });
    for (language_spell_ids) |spell_id| {
        try map_ecs.sendTo(entity, protocol.world.LearnedSpellServer{ .spell_id = spell_id });
    }
    try map_ecs.sendTo(entity, protocol.world.ActionButtonsServer{});
    try map_ecs.sendTo(entity, protocol.world.InitializeFactionsServer{});
    try map_ecs.sendTo(entity, protocol.world.LoginSetTimeSpeedServer{
        .packed_time = protocol.world.packGameTime(frame.clock.unixSeconds()),
        .speed = 1.0 / 60.0,
    });
    try map_ecs.sendTo(entity, protocol.world.InitWorldStatesServer{
        .map_id = placeholder_map.valueOf(),
        .zone_id = initial_zone_id,
        .area_id = initial_zone_id,
    });

    const time_sync_counter = session.time_sync.begin(frame.clock.nowMs32());
    try map_ecs.sendTo(entity, protocol.world.TimeSyncRequestServer{ .counter = time_sync_counter });
    try map_ecs.sendTo(entity, protocol.world.MotdServer{
        .lines = &.{"Welcome to Arenacraft!"},
    });
}
