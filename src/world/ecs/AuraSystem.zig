//! Aura lifecycle skeleton: spell effects that outlive their cast become
//! entity roots. Wire facts in docs/auras.md; full design report delivered
//! in chat (components, algorithms, policies). Components pending
//! reintroduction — stubs only for now.

const std = @import("std");
const ecs = @import("ecs");
const domain = @import("domain");
const proto = @import("protocol");
const c = @import("./EcsComponent.zig");

const MapEcs = @import("MapEcs.zig").MapEcs;

const log = std.log.scoped(.aura_system);

pub fn run(map_ecs: *MapEcs, frame: MapEcs.Frame) !void {
    const alloc = frame.arena_allocator;
    const registry = &map_ecs.registry;
    _ = registry; // autofix

    var invalidaded_auras_per_target = std.ArrayList(ecs.Entity).initCapacity(alloc, 2) catch unreachable;
    defer invalidaded_auras_per_target.deinit(alloc);

    for (map_ecs.events.get(.aura_applied).items) |event| {
        const aura_ent = event.aura_applied.aura;
        invalidaded_auras_per_target.append(alloc, aura_ent) catch unreachable;
        // const packet = proto.spell.AuraUpdateServer{
        //     .spell_id = aura.spell_id,
        //     .caster_guid = registry.getConst(c.Guid, aura.caster).value,
        //     .target_guid = registry.getConst(c.Guid, aura.owner).value,
        //     .slot = 0,
        //     .caster_level = registry.getConst(c.Level, aura.caster).value,
        //     .remaining_ms = elapsed,
        //     .max_duration_ms = max_duration,
        // };
        // map_ecs.broadcast(.{ aura.owner, .{ .ignore_sender = false } }, packet);
    }
}
