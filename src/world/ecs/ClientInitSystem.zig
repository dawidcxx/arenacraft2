const domain = @import("domain");
const game_data = @import("game_data");
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

fn sendClientInit(map_ecs: *MapEcs, frame: MapEcs.Frame, player_entity: ecs.Entity) !void {
    const alloc = frame.arena_allocator;
    const registry = &map_ecs.registry;
    const position = registry.getConst(component.Position, player_entity);
    const appearance = registry.getConst(component.Appearance, player_entity);
    const session = registry.getConst(component.Player, player_entity).session;

    map_ecs.sendTo(player_entity, protocol.world.BindPointUpdateServer{
        .x = position.x,
        .y = position.y,
        .z = position.z,
        .map_id = placeholder_map.valueOf(),
        .area_id = initial_zone_id,
    });
    map_ecs.sendTo(player_entity, protocol.world.TalentsInfoServer{});

    const initial_spells = try game_data.initial_spells_db.getAllFor(alloc, appearance.class_id, appearance.race_id);
    defer alloc.free(initial_spells);

    // map_ecs.sendTo(player_entity, protocol.world.InitialSpellsServer{ .spells = &.{} });
    for (initial_spells) |initial_spell| {
        map_ecs.sendTo(player_entity, protocol.world.LearnedSpellServer{ .spell_id = initial_spell.spell_id });
    }

    // Spellbook = explicit login grants + spells implied by skill grants
    // (skills.zon pairs, e.g. Language Common). Disjoint by comptime check.
    // var spell_ids: [game_data.initial_spells.max_granted + game_data.initial_skills.max_granted]u32 = undefined;
    // var spell_len: usize = 0;
    // for (game_data.initial_spells.grantsFor(appearance.class_id, appearance.race_id).slice()) |spell_id| {
    //     spell_ids[spell_len] = spell_id;
    //     spell_len += 1;
    // }
    // for (game_data.initial_skills.spellIdsFor(appearance.class_id, appearance.race_id).slice()) |spell_id| {
    //     spell_ids[spell_len] = spell_id;
    //     spell_len += 1;
    // }
    //
    // try map_ecs.sendTo(entity, protocol.world.InitialSpellsServer{ .spells = spell_ids[0..spell_len] });
    // for (spell_ids[0..spell_len]) |spell_id| {
    //     try map_ecs.sendTo(entity, protocol.world.LearnedSpellServer{ .spell_id = spell_id });
    // }

    map_ecs.sendTo(player_entity, protocol.world.ActionButtonsServer{});
    map_ecs.sendTo(player_entity, protocol.world.InitializeFactionsServer{});
    map_ecs.sendTo(player_entity, protocol.world.LoginSetTimeSpeedServer{
        .packed_time = protocol.world.packGameTime(frame.clock.unixSeconds()),
        .speed = 1.0 / 60.0,
    });
    map_ecs.sendTo(player_entity, protocol.world.InitWorldStatesServer{
        .map_id = placeholder_map.valueOf(),
        .zone_id = initial_zone_id,
        .area_id = initial_zone_id,
    });

    const time_sync_counter = session.time_sync.begin(frame.clock.nowMs32());
    map_ecs.sendTo(player_entity, protocol.world.TimeSyncRequestServer{ .counter = time_sync_counter });
    map_ecs.sendTo(player_entity, protocol.world.MotdServer{
        .lines = &.{"Welcome to Arenacraft!"},
    });
}
