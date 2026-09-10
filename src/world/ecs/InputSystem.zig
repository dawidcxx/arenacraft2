//! Consumes every queued map input in arrival order: joins split players
//! into components, moves apply tracked transforms and rebroadcast, leaves
//! despawn. Packet emission is deferred to OutboundPacketSystem.

const std = @import("std");
const domain = @import("domain");
const ecs = @import("ecs");
const protocol = @import("protocol");
const stdx = @import("stdx");
const game_data = @import("game_data");

const component = @import("EcsComponent.zig");
const EcsInput = @import("EcsInput.zig");
const MapEcs = @import("MapEcs.zig").MapEcs;
const LocalChatSystem = @import("LocalChatSystem.zig");

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
            .local_chat => |chat| try LocalChatSystem.run(map_ecs, chat), // TODO: this is bad
            .player_spell_cast => |spell_cast_request| try handleCastRequest(map_ecs, spell_cast_request),
            .player_cancel_cast => |cancel_request| try handleCancelCast(map_ecs, cancel_request),
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

    map_ecs.addEvent(.{ .player_left = .{ .player = player_entity, .guid = guid } });
}

fn handleJoin(map_ecs: *MapEcs, joining_player: *domain.Player) !void {
    const reg = &map_ecs.registry;
    if (map_ecs.findPlayer(joining_player.account_id)) |existing| {
        log.warn("duplicate player_join (account_id={}); replacing stale entity", .{joining_player.account_id});
        reg.destroy(existing);
    }
    const entity = createPlayerEntity(reg, joining_player);
    map_ecs.addEvent(.{ .player_joined = .{ .player = entity } });
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
    reg.add(entity, component.Health{ .current = character.derived.max_health, .max = character.derived.max_health });
    reg.add(entity, component.MoveSpeed{ .run = component.BASE_RUN_SPEED });

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
        inline else => |active| map_ecs.broadcast(
            .{ mover, .{ .ignore_sender = true } },
            active,
        ),
    }
}

// 1. Validate the request
// 2. Tear apart the SpellDef into a ECS representation
fn handleCastRequest(
    map_ecs: *MapEcs,
    cast_request: EcsInput.PlayerCastSpell,
) !void {
    const spell_cast = handleCastRequestImpl(map_ecs, cast_request) catch |e| switch (e) {
        error.CastFailed => {
            log.debug("Failing spellcast (spell_id={})", .{cast_request.packet.spell_id});
            return;
        },
    };
    map_ecs.addEvent(.{ .spell_cast_fired = .{ .spell_cast = spell_cast } });
}

fn handleCancelCast(
    map_ecs: *MapEcs,
    cancel_request: EcsInput.PlayerCancelCast,
) !void {
    var registry = &map_ecs.registry;

    const player = map_ecs.findPlayer(cancel_request.account_id) orelse return;

    // Abort the in-flight cast (one per caster) matching the spell id.
    var casting_view = registry.view(.{ component.SpellCast, component.CastTime }, .{});
    var casting_it = casting_view.entityIterator();
    while (casting_it.next()) |spell_cast_ent| {
        const spell_cast = registry.getConst(component.SpellCast, spell_cast_ent);
        if (spell_cast.caster != player) continue;
        if (spell_cast.spell_id != cancel_request.spell_id) continue;

        registry.destroy(spell_cast_ent);

        map_ecs.broadcast(.{ player, .{ .ignore_sender = true } }, protocol.spell.SpellFailureServer{
            .caster_guid = registry.getConst(component.Guid, player).value,
            .cast_count = spell_cast.cast_count,
            .spell_id = spell_cast.spell_id,
            .result = .interrupted,
        });
        return;
    }
}

fn handleCastRequestImpl(
    map_ecs: *MapEcs,
    cast_request: EcsInput.PlayerCastSpell,
) error{CastFailed}!ecs.Entity {
    var registry = &map_ecs.registry;

    const spell_cast = registry.create();
    errdefer registry.destroy(spell_cast);

    const player = map_ecs.findPlayer(cast_request.account_id) orelse unreachable;
    const spell_def = game_data.spells.spells_db.findSpellById(cast_request.packet.spell_id) orelse {
        @branchHint(.unlikely);
        const packet = protocol.spell.CastFailedServer{
            .spell_id = cast_request.packet.spell_id,
            .result = .not_known,
            .cast_count = cast_request.packet.cast_count,
        };
        map_ecs.sendTo(player, packet);
        return error.CastFailed;
    };

    registry.add(spell_cast, component.SpellCast{
        .spell_id = spell_def.spell_id,
        .school = spell_def.school,
        .cast_count = cast_request.packet.cast_count,
        .caster = player,
        .effects = spell_def.effects,
    });
    registry.add(spell_cast, component.SpellName{ .name = spell_def.name });
    registry.add(spell_cast, component.PowerCost{ .cost = spell_def.power_cost });
    if (spell_def.cast_time_ms) |cast_time_ms| registry.add(spell_cast, component.CastTime{ .elapsed = cast_time_ms });
    if (spell_def.needs_target) {
        const target = map_ecs.findEntityByGuid(cast_request.packet.target_guid) orelse {
            const packet = protocol.spell.CastFailedServer{
                .spell_id = cast_request.packet.spell_id,
                .result = .not_known,
                .cast_count = cast_request.packet.cast_count,
            };
            map_ecs.sendTo(player, packet);
            return error.CastFailed;
        };
        registry.add(spell_cast, component.SpellTarget{ .target = target });

        const distance = distanceBetweenUnits(registry, player, target);

        if (spell_def.range_yards) |max_range| {
            if (distance > max_range) {
                const packet = protocol.spell.CastFailedServer{
                    .spell_id = cast_request.packet.spell_id,
                    .result = .out_of_range,
                    .cast_count = cast_request.packet.cast_count,
                };
                map_ecs.sendTo(player, packet);
                return error.CastFailed;
            }
        }

        if (spell_def.projectile_speed) |projectile_speed| {
            registry.add(spell_cast, component.CastProjectileTime{
                .elapsed = @intFromFloat(@as(f32, @floatFromInt(distance)) / @as(f32, @floatFromInt(projectile_speed))),
            });
        }
    }

    // SMSG_SPELL_START drives the client-side cast bar (delay_ms > 0) and
    // target visual anticipation for instants as well.
    const target_guid: ?domain.ObjectGuid = if (registry.tryGetConst(component.SpellTarget, spell_cast)) |t|
        registry.getConst(component.Guid, t.target).value
    else
        null;

    map_ecs.broadcast(.{ player, .{ .ignore_sender = false } }, protocol.spell.SpellStartServer{
        .caster_guid = registry.getConst(component.Guid, player).value,
        .cast_count = cast_request.packet.cast_count,
        .spell_id = spell_def.spell_id,
        .delay_ms = @intCast(spell_def.cast_time_ms orelse 0),
        .target_guid = target_guid,
    });

    return spell_cast;
}

// helpers
fn distanceBetweenUnits(reg: *ecs.Registry, unit1: ecs.Entity, unit2: ecs.Entity) u32 {
    const pos1 = reg.getConst(component.Position, unit1);
    const pos2 = reg.getConst(component.Position, unit2);

    const dx = pos1.x - pos2.x;
    const dy = pos1.y - pos2.y;
    const dz = pos1.z - pos2.z;

    const distance = @sqrt(dx * dx + dy * dy + dz * dz);

    return @intFromFloat(distance);
}
