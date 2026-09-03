//! Melee auto attack swings. Entities carrying the Attacking component
//! swing at their target on a fixed cadence while it stays alive and in
//! range; the component is dropped when the target despawns.

const std = @import("std");
const ecs = @import("ecs");
const domain = @import("domain");
const protocol = @import("protocol");

const component = @import("EcsComponent.zig");
const MapEcs = @import("MapEcs.zig").MapEcs;
const SpellSystem = @import("SpellSystem.zig");

const log = std.log.scoped(.melee_system);

/// Bare-hand melee reach; matches the Auto Attack spell def range.
const melee_range_yards: f32 = 5.0;
/// Bare-hand swing cadence.
const swing_interval_ms: u64 = 2000;

pub fn run(map_ecs: *MapEcs, frame: MapEcs.Frame) !void {
    const registry = &map_ecs.registry;

    var attackers = registry.view(.{component.Attacking}, .{});
    var it = attackers.entityIterator();
    while (it.next()) |attacker| {
        const attacking = registry.getConst(component.Attacking, attacker);
        if (frame.time_now < attacking.next_swing_ms) continue;

        const target_still_there = registry.valid(attacking.target) and
            registry.has(component.Health, attacking.target) and
            registry.has(component.Guid, attacking.target);
        if (!target_still_there) {
            // Target despawned; stop attacking so the client drops its
            // swing state too.
            const attacker_guid = registry.getConst(component.Guid, attacker).value;
            registry.removeIfExists(component.Attacking, attacker);
            try map_ecs.broadcast(.{ attacker, .{ .ignore_sender = false } }, protocol.spell.AttackStopServer{
                .attacker_guid = attacker_guid,
                .victim_guid = null,
            });
            continue;
        }

        registry.get(component.Attacking, attacker).*.next_swing_ms = frame.time_now + swing_interval_ms;

        const position = registry.getConst(component.Position, attacker);
        const target_position = registry.getConst(component.Position, attacking.target);
        const dx = position.x - target_position.x;
        const dy = position.y - target_position.y;
        const dz = position.z - target_position.z;
        const dist = @sqrt(dx * dx + dy * dy + dz * dz);
        if (dist > melee_range_yards) continue;

        const def = domain.spells.findSpell(6603) orelse continue;
        const damage = SpellSystem.rollDamage(frame.io, def.min_damage, def.max_damage);
        SpellSystem.applyDamage(registry, attacking.target, damage);

        try map_ecs.broadcast(.{ attacker, .{ .ignore_sender = false } }, protocol.spell.AttackerStateUpdateServer{
            .school_mask = def.school,
            .attacker_guid = registry.getConst(component.Guid, attacker).value,
            .victim_guid = registry.getConst(component.Guid, attacking.target).value,
            .damage = damage,
        });

        try SpellSystem.sendHealthUpdate(map_ecs, frame, attacker, attacking.target);
    }
}

