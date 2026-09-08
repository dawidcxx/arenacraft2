//! Consumes `spell_cast_fired` events raised by InputSystem. Placeholder:
//! spells only log for now; real cast progression/impact lands here later.

const std = @import("std");
const ecs = @import("ecs");

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
    var targeted_spells_view = registry.view(.{ component.SpellReady, component.SpellTarget, component.SpellCast }, .{});
    var targeted_spells_it = targeted_spells_view.entityIterator();
    while (targeted_spells_it.next()) |spell_cast_ent| {
        const spell_cast = registry.getConst(component.SpellCast, spell_cast_ent);
        _ = spell_cast; // autofix
        const target = registry.getConst(component.SpellTarget, spell_cast_ent);
        _ = target; // autofix

    }
}
