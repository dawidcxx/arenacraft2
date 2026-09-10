//! Drives the spell cast pipeline: instant casts arm on the fired event,
//! timed casts mature through their cast/projectile timers, and ready
//! targeted spells apply their effects with wire feedback via MapEcs.

const std = @import("std");
const ecs = @import("ecs");
const domain = @import("domain");
const protocol = @import("protocol");

const component = @import("EcsComponent.zig");
const MapEcs = @import("MapEcs.zig").MapEcs;

const log = std.log.scoped(.spell_system);

pub fn run(map_ecs: *MapEcs, frame: MapEcs.Frame) !void {
    var registry = &map_ecs.registry;
    const alloc = frame.arena_allocator;

    for (map_ecs.events.getPtr(.spell_cast_fired).items) |event| {
        const spell_cast = event.spell_cast_fired.spell_cast;
        if (registry.has(component.CastTime, spell_cast)) continue;
        if (registry.has(component.CastProjectileTime, spell_cast)) continue;

        registry.add(spell_cast, component.SpellReady{});
    }

    // await cast times
    var casted_spells_view = registry.view(.{component.CastTime}, .{});
    var casted_spells_it = casted_spells_view.entityIterator();
    while (casted_spells_it.next()) |cast| {
        var cast_time = registry.get(component.CastTime, cast);
        cast_time.elapsed -%= frame.dt;
        if (cast_time.elapsed == 0) {
            registry.remove(component.CastTime, cast);
            map_ecs.queueEvent(.{ .spell_cast_fired = .{ .spell_cast = cast } });
        }
    }

    // await flight times
    var spells_in_flight_view = registry.view(.{component.CastProjectileTime}, .{});
    var spells_in_flight_it = spells_in_flight_view.entityIterator();
    while (spells_in_flight_it.next()) |cast| {
        var cast_time = registry.get(component.CastProjectileTime, cast);
        cast_time.elapsed -%= frame.dt;
        if (cast_time.elapsed == 0) {
            registry.remove(component.CastProjectileTime, cast);
            map_ecs.queueEvent(.{ .spell_cast_fired = .{ .spell_cast = cast } });
        }
    }

    var executed_spells_list = std.ArrayList(ecs.Entity).initCapacity(alloc, 16) catch unreachable;
    defer executed_spells_list.deinit(alloc);

    // Execute targeted spells
    var targeted_spells_view = registry.view(.{
        component.SpellReady,
        component.SpellTarget,
        component.SpellCast,
    }, .{});

    var targeted_spells_it = targeted_spells_view.entityIterator();

    while (targeted_spells_it.next()) |spell_cast_ent| {
        executeTargetedSpell(map_ecs, frame, spell_cast_ent);
        executed_spells_list.append(alloc, spell_cast_ent) catch unreachable;
    }

    for (executed_spells_list.items) |spell_cast_entity| registry.destroy(spell_cast_entity);
}

fn executeTargetedSpell(map_ecs: *MapEcs, frame: MapEcs.Frame, spell_cast_ent: ecs.Entity) void {
    var registry = &map_ecs.registry;

    const spell_cast = registry.getConst(component.SpellCast, spell_cast_ent);
    const target = registry.getConst(component.SpellTarget, spell_cast_ent).target;
    const caster = spell_cast.caster;

    const caster_guid = registry.getConst(component.Guid, caster);
    const target_guid = registry.getConst(component.Guid, target);

    const spell_go_packet = protocol.spell.SpellGoServer{
        .spell_id = spell_cast.spell_id,
        .cast_count = spell_cast.cast_count,
        .caster_guid = caster_guid.value,
        .target_guid = target_guid.value,
        .hit_guids = &.{target_guid.value},
        .timestamp_ms = frame.time_now,
    };

    map_ecs.broadcast(.{ caster, .{ .ignore_sender = false } }, spell_go_packet);

    for (spell_cast.effects) |spell_effect| {
        switch (spell_effect) {
            .direct_melee_damage => |d| {
                const melee_hit_packet = protocol.spell.AttackerStateUpdateServer{
                    .attacker_guid = caster_guid.value,
                    .victim_guid = target_guid.value,
                    .damage = d.max,
                    .school_mask = @intFromEnum(spell_cast.school),
                };
                map_ecs.broadcast(.{ caster, .{ .ignore_sender = false } }, melee_hit_packet);
            },
            .damage => |d| {
                const damage_packet = protocol.spell.SpellNonMeleeDamageServer{
                    .attacker_guid = caster_guid.value,
                    .victim_guid = target_guid.value,
                    .spell_id = spell_cast.spell_id,
                    .damage = d.max,
                    .school_mask = @intFromEnum(spell_cast.school),
                };
                map_ecs.broadcast(.{ caster, .{ .ignore_sender = false } }, damage_packet);
            },
            .movement_slow => {
                // TODO: spawn a aura here once the aura system is reintroduced.
            },
        }
    }
}
