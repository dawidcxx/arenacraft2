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

const HealResult = struct { applied: u32 = 0, overheal: u32 = 0 };

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

/// Applies `amount` to the target's health pool, clamped to max. Broadcasts
/// a UNIT_FIELD_HEALTH values update so clients see the bar move. Returns
/// the wire tuple: applied gain + overheal (the clamped-away remainder).
fn applyHeal(map_ecs: *MapEcs, frame: MapEcs.Frame, target: ecs.Entity, amount: u32) HealResult {
    const registry = &map_ecs.registry;

    const health = registry.tryGet(component.Health, target) orelse {
        log.warn("heal effect on entity without Health component", .{});
        return .{};
    };

    const applied = @min(amount, health.max - health.current);
    health.current += applied;

    if (applied > 0) {
        var fields = protocol.object.Fields{};
        fields.set(protocol.object.UnitField.health, health.current);
        var update_packet = protocol.object.UpdateObject.init(frame.arena_allocator) catch unreachable;
        defer update_packet.deinit(frame.arena_allocator);
        update_packet.add(frame.arena_allocator, .{ .values = .{
            .guid = registry.getConst(component.Guid, target).value,
            .fields = fields,
        } }) catch unreachable;

        map_ecs.broadcast(.{ target, .{ .ignore_sender = false } }, update_packet);
    }

    return .{ .applied = applied, .overheal = amount - applied };
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
            .heal => |h| {
                const result = applyHeal(map_ecs, frame, target, h.max);

                // heal = actual gain, overheal = clamped-away remainder;
                // the client renders the overheal text from that pair.
                const heal_packet = protocol.spell.SpellHealLogServer{
                    .victim_guid = target_guid.value,
                    .caster_guid = caster_guid.value,
                    .spell_id = spell_cast.spell_id,
                    .heal = result.applied,
                    .overheal = result.overheal,
                };
                map_ecs.broadcast(.{ caster, .{ .ignore_sender = false } }, heal_packet);
            },
            .movement_slow => |ms| {
                // TODO: aura spawn attempt (slow effect on target) — aura
                // ECS was torn down for a redesign; rebuild here once the
                // new lifecycle exists. `ms.pct`/`ms.duration` carry the
                // effect payload.
                _ = ms;
            },
        }
    }
}
