const std = @import("std");

const domain = @import("domain");
const ecs = @import("ecs");
const protocol = @import("protocol");

const EcsEventType = @import("./EcsInput.zig").EcsEventType;
const component = @import("EcsComponent.zig");
const MapEcs = @import("MapEcs.zig").MapEcs;

// Placeholders carried over from the pre-ECS login path.
const placeholder_health: u32 = 100;
const placeholder_power: u32 = 100;

pub fn run(map_ecs: *MapEcs, frame: MapEcs.Frame) !void {
    var registry = map_ecs.registry;

    // a Player joined, time to introduce them to the world
    // and vice versa
    const player_joined_events = map_ecs.events.get(EcsEventType.player_joined);
    for (player_joined_events.items) |event| {
        const joining_player = event.player_joined.player;
        // Have the joining player obtain a initial visibility
        try syncPlayerVisibilities(map_ecs, frame, joining_player);

        // Update everyone elses view
        var introduce_player_packet = try protocol.object.UpdateObject.init(frame.arena_allocator);
        defer introduce_player_packet.deinit(frame.arena_allocator);
        try introduce_player_packet.add(frame.arena_allocator, .{
            .create_object2 = .{
                .player_create = playerEntityToPlayerCreate(&registry, joining_player, @truncate(frame.time_now)),
            },
        });
        try map_ecs.broadcast(.{ joining_player, .{ .ignore_sender = true } }, introduce_player_packet);
    }

    const player_leave_events = map_ecs.events.get(EcsEventType.player_left);
    for (player_leave_events.items) |event| {
        const player = event.player_left.player;
        const despawn_packet = protocol.world.DestroyObjectServer{ .guid = event.player_left.guid };
        try map_ecs.broadcast(.{ player, .{ .ignore_sender = true } }, despawn_packet);
    }
}

const log = std.log.scoped(.player_visibility_system);

fn syncPlayerVisibilities(
    map_ecs: *MapEcs,
    frame: MapEcs.Frame,
    player_to_sync: ecs.Entity,
) !void {
    const aa = frame.arena_allocator;
    var registry = &map_ecs.registry;

    var all_players_in_map_view = registry.view(.{
        component.Guid,
        component.Level,
        component.Appearance,
    }, .{});

    var all_players_in_map_view_it = all_players_in_map_view.entityIterator();

    // Sync joining player with all current players in map
    var update_obj_packet_for_joining_player = try protocol.object.UpdateObject.init(aa);
    defer update_obj_packet_for_joining_player.deinit(aa);

    while (all_players_in_map_view_it.next()) |player| {
        const is_self_update = player == player_to_sync;
        const player_to_introduce = playerEntityToPlayerCreate(registry, player, @truncate(frame.time_now));
        try update_obj_packet_for_joining_player.add(aa, .{
            .create_object2 = .{ .player_create = player_to_introduce.with(.self_update, is_self_update) },
        });
    }

    try map_ecs.sendTo(player_to_sync, update_obj_packet_for_joining_player);
}

fn playerEntityToPlayerCreate(reg: *ecs.Registry, player: ecs.Entity, time_ms: u32) protocol.object.PlayerCreate {
    const guid = reg.getConst(component.Guid, player);
    const level = reg.getConst(component.Level, player);
    const appearance = reg.getConst(component.Appearance, player);
    const position = reg.getConst(component.Position, player);
    const orientation = reg.getConst(component.Orientation, player);

    return .{
        .guid = guid.value,
        .x = position.x,
        .y = position.y,
        .z = position.z,
        .orientation = orientation.value,
        .race = appearance.race_id,
        .class = @intFromEnum(appearance.class_id),
        .gender = appearance.gender,
        .skin = appearance.skin,
        .face = appearance.face,
        .hair_style = appearance.hair_style,
        .hair_color = appearance.hair_color,
        .facial_hair = appearance.facial_hair,
        .level = level.value,
        .health = placeholder_health,
        .power_type = appearance.class_id.powerTypeId().valueOf(),
        .power = placeholder_power,
        .faction_template = domain.races.factionTemplate(appearance.race_id),
        .display_id = domain.races.displayId(appearance.race_id, appearance.gender),
        .visible_items = reg.getConst(component.VisibleItems, player).entries,
        .language_skill_ids = domain.races.languageSkillIds(appearance.race_id),
        .time_ms = time_ms,
        .self_update = false,
    };
}
