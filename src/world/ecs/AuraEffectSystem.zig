//! Aura lifecycle skeleton: spell effects that outlive their cast become
//! entity roots. Wire facts in docs/auras.md; full design report delivered
//! in chat (components, algorithms, policies). Components pending
//! reintroduction — stubs only for now.

const std = @import("std");
const ecs = @import("ecs");
const proto = @import("protocol");
const c = @import("./EcsComponent.zig");
const MapEcs = @import("MapEcs.zig").MapEcs;

const log = std.log.scoped(.aura_effect_system);

pub fn run(map_ecs: *MapEcs, frame: MapEcs.Frame) !void {
    var registry = &map_ecs.registry;

    var auras_affected = std.ArrayListUnmanaged(ecs.Entity).initCapacity(frame.arena_allocator, 64) catch unreachable;
    defer auras_affected.deinit(frame.arena_allocator);

    for (map_ecs.events.get(.aura_applied).items) |event| {
        const aura_ent = event.aura_applied[0];
        auras_affected.append(frame.arena_allocator, aura_ent) catch unreachable;
    }

    var slow_effects_view = registry.view(.{c.AuraMovementSlow}, .{});
    var slow_effects_it = slow_effects_view.entityIterator();
    while (slow_effects_it.next()) |slow_effect_aura_ent| {
        const aura = registry.getConst(c.Aura, slow_effect_aura_ent);
        const slow_effect = registry.getConst(c.AuraMovementSlow, slow_effect_aura_ent);
        map_ecs.broadcast(.{ aura.owner, .{ .ignore_sender = false } }, proto.spell.ForceRunSpeedChangeServer{
            .guid = registry.getConst(c.Guid, aura.owner).value,
            .speed = c.BASE_RUN_SPEED * slow_effect.pct,
        });
    }
}
