//! Consumes every queued map input in arrival order: joins split players
//! into components, moves apply tracked transforms and rebroadcast, leaves
//! despawn. Packet emission is deferred to OutboundPacketSystem.

const std = @import("std");
const domain = @import("domain");
const ecs = @import("ecs");
const protocol = @import("protocol");
const stdx = @import("stdx");

const component = @import("EcsComponent.zig");
const EcsInput = @import("EcsInput.zig");
const MapEcs = @import("MapEcs.zig").MapEcs;
const LocalChatSystem = @import("LocalChatSystem.zig");
const CastSystem = @import("CastSystem.zig");

const Arc = stdx.Arc;
const ArcRuntime = stdx.ArcRuntime;

const log = std.log.scoped(.input_system);

pub fn run(map_ecs: *MapEcs, frame: MapEcs.Frame) !void {
    _ = frame;
    for (map_ecs.input_buffer.items) |input| {
        switch (input) {
            .player_join => |join| try handleJoin(map_ecs, join.player),
            .player_move => |move| try handleMove(map_ecs, move),
            .player_leave => |leave| try handleLeave(map_ecs, leave.account_id),
            .local_chat => |chat| try LocalChatSystem.run(map_ecs, chat),
            .cast_spell => |cast| try handleCastSpell(map_ecs, cast),
            .cancel_cast => |cancel| try handleCancelCast(map_ecs, cancel),
        }
    }
}

fn handleLeave(
    map_ecs: *MapEcs,
    account_id: u64,
) !void {
    var registry = &map_ecs.registry;

    const player_entity = map_ecs.findPlayer(account_id) orelse return;
    const guid = registry.getConst(component.Guid, player_entity).value;
    registry.destroy(player_entity);

    try map_ecs.addEvent(.{ .player_left = .{ .player = player_entity, .guid = guid } });
}

fn handleJoin(map_ecs: *MapEcs, joining_player: *domain.Player) !void {
    const reg = &map_ecs.registry;
    if (map_ecs.findPlayer(joining_player.account_id)) |existing| {
        log.warn("duplicate player_join (account_id={}); replacing stale entity", .{joining_player.account_id});
        reg.destroy(existing);
    }
    const entity = createPlayerEntity(reg, joining_player);
    try map_ecs.addEvent(.{ .player_joined = .{ .player = entity } });
}

fn createPlayerEntity(reg: *ecs.Registry, player: *domain.Player) ecs.Entity {
    const entity = reg.create();
    const session = player.session.?;
    const character = player.character;

    reg.add(entity, component.Player{ .session = session });
    reg.add(entity, component.AccountId{ .id = player.account_id });
    reg.add(entity, component.Guid{ .value = character.guid });
    reg.add(entity, component.Position{
        .x = character.movement.position.x,
        .y = character.movement.position.y,
        .z = character.movement.position.z,
    });
    reg.add(entity, component.Orientation{ .value = character.movement.orientation });
    reg.add(entity, component.Appearance{
        .race_id = character.race_id,
        .class_id = character.class_id,
        .gender = character.gender,
        .skin = character.skin,
        .face = character.face,
        .hair_style = character.hair_style,
        .hair_color = character.hair_color,
        .facial_hair = character.facial_hair,
    });
    reg.add(entity, component.VisibleItems{ .entries = character.visible_items, .guids = character.item_guids });
    reg.add(entity, component.Level{ .value = character.level });
    reg.add(entity, component.Stats{ .derived = character.derived });
    reg.add(entity, component.Health{ .current = character.derived.max_health });
    reg.add(entity, component.Power{ .current = character.derived.max_power });

    return entity;
}

fn handleMove(
    map_ecs: *MapEcs,
    move: EcsInput.PlayerMove,
) !void {
    const packet = move.packet;
    const info = packet.getInfo();

    const registry = &map_ecs.registry;
    const mover = map_ecs.findPlayer(move.account_id) orelse {
        log.warn("movement input for account not on this map (account_id={})", .{move.account_id});
        return;
    };

    registry.get(component.Position, mover).* = .{
        .x = info.x,
        .y = info.y,
        .z = info.z,
    };
    registry.get(component.Orientation, mover).*.value = info.orientation;

    switch (packet) {
        inline else => |active| try map_ecs.broadcast(
            .{ mover, .{ .ignore_sender = true } },
            active,
        ),
    }

    // Displacing movement breaks a running cast; CastSystem owns the
    // teardown and the animation-clearing packets.
    if (packet.interruptsCast()) {
        try CastSystem.interruptCast(map_ecs, mover, null, .{ .by_client = false });
    }
}

/// Transliterates the parsed CMSG_CAST_SPELL into a CastRequest entity.
/// No validation happens here; CastSystem decides everything.
fn handleCastSpell(map_ecs: *MapEcs, cast: EcsInput.CastSpell) !void {
    const caster = map_ecs.findPlayer(cast.account_id) orelse {
        log.warn("cast spell from account not on this map (account_id={})", .{cast.account_id});
        return;
    };

    const registry = &map_ecs.registry;
    const request_entity = registry.create();
    registry.add(request_entity, component.CastRequest{
        .caster = caster,
        .spell_id = cast.packet.spell_id,
        .target_guid = cast.packet.target_guid,
        .cast_count = cast.packet.cast_count,
    });
}

fn handleCancelCast(
    map_ecs: *MapEcs,
    cancel: EcsInput.CancelCast,
) !void {
    const caster = map_ecs.findPlayer(cancel.account_id) orelse return;
    try CastSystem.interruptCast(map_ecs, caster, cancel.packet.spell_id, .{ .by_client = true });
}
