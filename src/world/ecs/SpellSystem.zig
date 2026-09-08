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

    // Execute Ready targeted spells
    // Destroying the entity the view just yielded is safe: the view's
    // reverse iterator and the sparse set's swap-and-pop removal keep the
    // unread portion of the iteration intact.
    var targeted_spells_view = registry.view(.{
        component.SpellReady,
        component.SpellTarget,
        component.SpellCast,
    }, .{});
    var targeted_spells_it = targeted_spells_view.entityIterator();
    while (targeted_spells_it.next()) |spell_cast_ent| {
        broadcastSpellEffects(map_ecs, frame, spell_cast_ent);
        registry.destroy(spell_cast_ent);
    }
}

/// Run speed the slow effect scales from; mirrors UpdateObject.base_speeds.
const base_run_speed: f32 = 7.0;

/// Broadcasts the spell's impact packets. Pure reads plus MapEcs output;
/// the caller owns destroying the spell entity (skipped effects on a
/// vanished caster/target fizzle).
fn broadcastSpellEffects(map_ecs: *MapEcs, frame: MapEcs.Frame, spell_cast_ent: ecs.Entity) void {
    const registry = &map_ecs.registry;

    const spell_cast = registry.getConst(component.SpellCast, spell_cast_ent);
    const target = registry.getConst(component.SpellTarget, spell_cast_ent).target;

    // Caster or target may have left while the cast was running.
    const caster_guid = guidOf(registry, spell_cast.caster) orelse return;
    const target_guid = guidOf(registry, target) orelse return;

    map_ecs.broadcast(.{ spell_cast.caster, .{ .ignore_sender = false } }, protocol.spell.SpellGoServer{
        .caster_guid = caster_guid,
        .cast_count = spell_cast.cast_count,
        .spell_id = spell_cast.spell_id,
        .timestamp_ms = @truncate(frame.time_now),
        .hit_guids = &.{target_guid},
        .target_guid = target_guid,
    });

    for (spell_cast.effects) |effect| {
        switch (effect) {
            .damage => |d| broadcastDamage(map_ecs, spell_cast, rollMagnitude(frame.io, d.min, d.max), caster_guid, target_guid),
            .direct_melee_damage => |d| broadcastDamage(map_ecs, spell_cast, rollMagnitude(frame.io, d.min, d.max), caster_guid, target_guid),
            .movement_slow => |slow| broadcastSlow(map_ecs, spell_cast, slow, caster_guid, target_guid),
        }
    }

    registry.destroy(spell_cast_ent);
}

fn broadcastDamage(
    map_ecs: *MapEcs,
    spell_cast: component.SpellCast,
    damage: u32,
    caster_guid: domain.ObjectGuid,
    target_guid: domain.ObjectGuid,
) void {
    map_ecs.broadcast(.{ spell_cast.caster, .{ .ignore_sender = false } }, protocol.spell.SpellNonMeleeDamageServer{
        .victim_guid = target_guid,
        .attacker_guid = caster_guid,
        .spell_id = spell_cast.spell_id,
        .damage = damage,
        .school_mask = schoolMask(spell_cast.school),
    });
}

fn broadcastSlow(
    map_ecs: *MapEcs,
    spell_cast: component.SpellCast,
    slow: anytype,
    caster_guid: domain.ObjectGuid,
    target_guid: domain.ObjectGuid,
) void {
    map_ecs.broadcast(.{ spell_cast.caster, .{ .ignore_sender = false } }, protocol.spell.AuraUpdateServer{
        .target_guid = target_guid,
        .slot = 0,
        .spell_id = spell_cast.spell_id,
        .caster_guid = caster_guid,
        .max_duration_ms = slow.duration,
        .remaining_ms = slow.duration,
    });
    map_ecs.broadcast(.{ spell_cast.caster, .{ .ignore_sender = false } }, protocol.spell.ForceRunSpeedChangeServer{
        .guid = target_guid,
        .speed = base_run_speed * (1.0 - @as(f32, @floatFromInt(slow.pct)) / 100.0),
    });
}

fn rollMagnitude(io: std.Io, min: u32, max: u32) u32 {
    if (max <= min) return min;
    const span = max - min + 1;
    var buf: [4]u8 = undefined;
    io.random(&buf);
    return min + std.mem.readInt(u32, &buf, .little) % span;
}

/// SpellSchoolMask: physical = 0x01, holy = 0x02, ... = 1 << school.
fn schoolMask(school: domain.SpellDef.School) u8 {
    return @as(u8, 1) << @intCast(@intFromEnum(school));
}

fn guidOf(registry: *ecs.Registry, entity: ecs.Entity) ?domain.ObjectGuid {
    if (registry.tryGetConst(component.Guid, entity)) |guid| return guid.value;
    return null;
}
