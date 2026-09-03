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
const SpellSystem = @import("SpellSystem.zig");

const Arc = stdx.Arc;
const ArcRuntime = stdx.ArcRuntime;

const log = std.log.scoped(.input_system);

pub fn run(map_ecs: *MapEcs, frame: MapEcs.Frame) !void {
    for (map_ecs.input_buffer.items) |input| {
        switch (input) {
            .player_join => |join| try handleJoin(map_ecs, join.player),
            .player_move => |move| try handleMove(map_ecs, move),
            .player_leave => |leave| try handleLeave(map_ecs, leave.account_id),
            .local_chat => |chat| try LocalChatSystem.run(map_ecs, chat),
            .spell_cast => |cast| try SpellSystem.handleCast(map_ecs, frame, cast),
            .attack_swing => |swing| try SpellSystem.handleSwing(map_ecs, frame, swing),
            .attack_stop => |stop| try SpellSystem.handleStop(map_ecs, frame, stop),
            .cancel_cast => |cancel| try SpellSystem.handleCancelCast(map_ecs, cancel),
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

    // Displacing movement interrupts a running cast; the client already
    // dropped its cast bar when it started moving.
    if (packet.interruptsCast()) try SpellSystem.interruptCast(map_ecs, mover, null);

    switch (packet) {
        inline else => |active| try map_ecs.broadcast(
            .{ mover, .{ .ignore_sender = true } },
            active,
        ),
    }
}
