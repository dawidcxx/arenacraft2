//! Drives the spell cast pipeline: instant casts arm on the fired event,
//! timed casts mature through their cast/projectile timers, and ready
//! targeted spells apply their effects with wire feedback via MapEcs.

const std = @import("std");
const ecs = @import("ecs");
const domain = @import("domain");
const protocol = @import("protocol");

const component = @import("EcsComponent.zig");
const AuraQuery = @import("./AuraQuery.zig");
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

    const school_mask: u8 = @as(u8, 1) << @intCast(@intFromEnum(spell_cast.school));

    const spell_go_packet = protocol.spell.SpellGoServer{
        .spell_id = spell_cast.spell_id,
        .cast_count = spell_cast.cast_count,
        .caster_guid = caster_guid.value,
        .target_guid = target_guid.value,
        .hit_guids = &.{target_guid.value},
        .timestamp_ms = frame.time_now,
    };

    map_ecs.broadcast(.{ caster, .{ .ignore_sender = false } }, spell_go_packet);

    // A hostile spell into an immune target lands on nothing.
    if (caster != target and AuraQuery.isImmuneTo(map_ecs, target, spell_cast.school)) {
        // TODO: immune feedback packet for the caster
        return;
    }

    for (spell_cast.effects) |spell_effect| {
        switch (spell_effect) {
            .direct_melee_damage => |d| {
                const melee_hit_packet = protocol.spell.AttackerStateUpdateServer{
                    .attacker_guid = caster_guid.value,
                    .victim_guid = target_guid.value,
                    .damage = d.max,
                    .school_mask = school_mask,
                };
                map_ecs.broadcast(.{ caster, .{ .ignore_sender = false } }, melee_hit_packet);
            },
            .damage => |d| {
                const damage_packet = protocol.spell.SpellNonMeleeDamageServer{
                    .attacker_guid = caster_guid.value,
                    .victim_guid = target_guid.value,
                    .spell_id = spell_cast.spell_id,
                    .damage = d.max,
                    .school_mask = school_mask,
                };
                map_ecs.broadcast(.{ caster, .{ .ignore_sender = false } }, damage_packet);
            },
            .apply_aura => |apply| {
                const aura = registry.create();
                registry.add(aura, component.Aura{
                    .owner = target,
                    .caster = caster,
                    .spell_id = spell_cast.spell_id,
                    .school = spell_cast.school,
                    .effects = apply.effects,
                });
                if (apply.duration_ms > 0) {
                    registry.add(aura, component.AuraDuration{ .remaining = apply.duration_ms, .max = apply.duration_ms });
                }
                if (AuraQuery.firstPeriodic(apply.effects)) |tick| {
                    registry.add(aura, component.AuraPeriodic{ .interval_ms = tick.interval_ms, .timer = tick.interval_ms });
                }
                map_ecs.addEvent(.{ .aura_apply_request = .{ .aura = aura } });
            },
        }
    }
}

// --- tests -------------------------------------------------------------------------

const t = std.testing;

const Rig = @import("EcsTestRig.zig").Rig;

const frostbolt_effects = [_]domain.SpellDef.Effect{
    .{ .damage = .{ .min = 18, .max = 20 } },
    .{ .apply_aura = .{ .duration_ms = 5000, .effects = &[_]domain.SpellDef.AuraEffect{
        .{ .movement_speed_mod = .{ .pct = -40 } },
    } } },
};
const immune_all = [_]domain.SpellDef.AuraEffect{.{ .immune = .{ .school_mask = 0x7F } }};

fn readyCast(rig: *Rig, caster: ecs.Entity, target: ecs.Entity, spell_id: u32) ecs.Entity {
    const registry = &rig.map_ecs.registry;
    const cast = registry.create();
    registry.add(cast, component.SpellCast{
        .spell_id = spell_id,
        .school = .frost,
        .cast_count = 1,
        .caster = caster,
        .effects = &frostbolt_effects,
    });
    registry.add(cast, component.SpellTarget{ .target = target });
    registry.add(cast, component.SpellReady{});
    return cast;
}

test "apply_aura impact spawns a full aura and queues admission" {
    var rig = try Rig.init();
    defer rig.deinit();

    _ = readyCast(&rig, rig.caster, rig.owner, 116);
    try run(&rig.map_ecs, rig.frame(50));

    const requests = rig.map_ecs.events.get(.aura_apply_request);
    try t.expectEqual(@as(usize, 1), requests.items.len);

    const aura_ent = requests.items[0].aura_apply_request.aura;
    const aura = rig.map_ecs.registry.getConst(component.Aura, aura_ent);
    try t.expectEqual(rig.owner, aura.owner);
    try t.expectEqual(rig.caster, aura.caster);
    try t.expectEqual(@as(u32, 116), aura.spell_id);
    try t.expectEqual(@as(usize, 1), aura.effects.len);

    const duration = rig.map_ecs.registry.getConst(component.AuraDuration, aura_ent);
    try t.expectEqual(@as(u32, 5000), duration.remaining);
    try t.expectEqual(@as(u32, 5000), duration.max);
}

test "hostile spell into an immune target lands on nothing" {
    var rig = try Rig.init();
    defer rig.deinit();

    const spell_go_op: u32 = @intFromEnum(protocol.spell.SpellGoServer.opcode);

    _ = rig.requestAura(rig.owner, rig.owner, 45438, .frost, &immune_all, 4000);
    try @import("./AuraSystem.zig").run(&rig.map_ecs, rig.frame(50));
    rig.drainEvents();

    _ = readyCast(&rig, rig.caster, rig.owner, 116);
    try run(&rig.map_ecs, rig.frame(50));

    // The cast itself still lands on the wire; the effects do not.
    try t.expectEqual(@as(usize, 1), rig.broadcastCount(spell_go_op));
    try t.expectEqual(@as(usize, 0), rig.map_ecs.events.get(.aura_apply_request).items.len);
    try t.expectEqual(@as(usize, 1), rig.occupiedAuras(rig.owner)); // only the immunity aura
}
