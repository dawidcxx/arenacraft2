//! Spell casting pipeline. Client cast/attack commands arrive as map
//! inputs, get validated here and become ECS entities: a cast spawns a
//! SpellCast entity that SpellSystem ticks to completion, an auto attack
//! sets the Attacking component (ticked by MeleeSystem), and a spell hit
//! spawns Aura entities (ticked by AuraSystem).
//!
//! Validation lives at cast time only: range, target existence and
//! duplicate casts. Damage rolls, aura application and packet emission all
//! go through the same helpers so followup mechanics (misses, resists,
//! periodic ticks, charges) extend instead of replace them.

const std = @import("std");
const ecs = @import("ecs");
const domain = @import("domain");
const protocol = @import("protocol");

const component = @import("EcsComponent.zig");
const EcsInput = @import("EcsInput.zig");
const MapEcs = @import("MapEcs.zig").MapEcs;

const Entity = ecs.Entity;
const log = std.log.scoped(.spell_system);

/// Base run speed; slowed units scale this down per aura.
const base_run_speed: f32 = 7.0;

pub fn handleCast(map_ecs: *MapEcs, frame: MapEcs.Frame, cast: EcsInput.SpellCast) !void {
    const registry = &map_ecs.registry;

    const caster = map_ecs.findPlayer(cast.account_id) orelse {
        log.warn("spell cast from player not on this map (account_id={})", .{cast.account_id});
        return;
    };

    const def = domain.spells.findSpell(cast.packet.spell_id) orelse {
        return sendCastFailed(map_ecs, caster, cast.packet.cast_count, cast.packet.spell_id, .not_known);
    };

    // Dead casters cannot cast.
    if (registry.has(component.Health, caster) and
        registry.getConst(component.Health, caster).current == 0)
    {
        return sendCastFailed(map_ecs, caster, cast.packet.cast_count, def.entry, .caster_dead);
    }

    // Auto attack is driven by CMSG_ATTACKSWING, not the cast pipeline.
    if (def.is_melee) {
        log.debug("cast of melee spell '{s}' ignored; auto attack uses CMSG_ATTACKSWING", .{def.name});
        return;
    }

    const target_guid = cast.packet.target_guid orelse {
        return sendCastFailed(map_ecs, caster, cast.packet.cast_count, def.entry, .bad_implicit_targets);
    };
    const target = map_ecs.findByGuid(target_guid) orelse {
        return sendCastFailed(map_ecs, caster, cast.packet.cast_count, def.entry, .bad_implicit_targets);
    };

    // Enemy spells cannot target the caster.
    if (target == caster) {
        return sendCastFailed(map_ecs, caster, cast.packet.cast_count, def.entry, .bad_implicit_targets);
    }

    // Dead targets cannot be cast on.
    if (registry.has(component.Health, target) and
        registry.getConst(component.Health, target).current == 0)
    {
        return sendCastFailed(map_ecs, caster, cast.packet.cast_count, def.entry, .targets_dead);
    }

    // Only one cast at a time per caster.
    var existing_casts = registry.view(.{component.SpellCast}, .{});
    var casts_it = existing_casts.entityIterator();
    while (casts_it.next()) |cast_entity| {
        if (registry.getConst(component.SpellCast, cast_entity).caster == caster) {
            return sendCastFailed(map_ecs, caster, cast.packet.cast_count, def.entry, .spell_in_progress);
        }
    }

    if (distance(registry, caster, target) > @as(f32, @floatFromInt(def.range_yards))) {
        return sendCastFailed(map_ecs, caster, cast.packet.cast_count, def.entry, .out_of_range);
    }

    const cast_entity = registry.create();
    registry.add(cast_entity, component.SpellCast{
        .caster = caster,
        .target = target,
        .spell_entry = def.entry,
        .cast_count = cast.packet.cast_count,
        .finish_ms = frame.time_now + def.cast_time_ms,
    });

    try map_ecs.broadcast(.{ caster, .{ .ignore_sender = false } }, protocol.spell.SpellStartServer{
        .caster_guid = registry.getConst(component.Guid, caster).value,
        .cast_count = cast.packet.cast_count,
        .spell_id = def.entry,
        .delay_ms = @intCast(def.cast_time_ms),
        .target_guid = target_guid,
    });
}

pub fn handleSwing(map_ecs: *MapEcs, frame: MapEcs.Frame, swing: EcsInput.AttackSwing) !void {
    const registry = &map_ecs.registry;

    const attacker = map_ecs.findPlayer(swing.account_id) orelse {
        log.warn("attack swing from player not on this map (account_id={})", .{swing.account_id});
        return;
    };

    const target = map_ecs.findByGuid(swing.packet.target_guid) orelse {
        return try map_ecs.broadcast(.{ attacker, .{ .ignore_sender = false } }, protocol.spell.AttackStopServer{
            .attacker_guid = registry.getConst(component.Guid, attacker).value,
            .victim_guid = null,
        });
    };

    // Self and dead targets reject the swing with an attack stop so the
    // client drops its swing state.
    const target_dead = registry.has(component.Health, target) and
        registry.getConst(component.Health, target).current == 0;
    if (target == attacker or target_dead or !registry.has(component.Health, target)) {
        return try map_ecs.broadcast(.{ attacker, .{ .ignore_sender = false } }, protocol.spell.AttackStopServer{
            .attacker_guid = registry.getConst(component.Guid, attacker).value,
            .victim_guid = null,
        });
    }

    // Re-attacking (possibly a different target) replaces the state; the
    // registry would corrupt its storage on a blind double-add.
    registry.addOrReplace(attacker, component.Attacking{
        .target = target,
        // First swing on the next tick for immediate feedback.
        .next_swing_ms = frame.time_now,
    });

    try map_ecs.broadcast(.{ attacker, .{ .ignore_sender = false } }, protocol.spell.AttackStartServer{
        .attacker_guid = registry.getConst(component.Guid, attacker).value,
        .victim_guid = swing.packet.target_guid,
    });
}

pub fn handleStop(map_ecs: *MapEcs, frame: MapEcs.Frame, stop: EcsInput.AttackStop) !void {
    _ = frame;
    const registry = &map_ecs.registry;

    const attacker = map_ecs.findPlayer(stop.account_id) orelse return;
    if (!registry.has(component.Attacking, attacker)) return;

    const target = registry.getConst(component.Attacking, attacker).target;
    const victim_guid: ?domain.ObjectGuid = if (registry.valid(target) and registry.has(component.Guid, target))
        registry.getConst(component.Guid, target).value
    else
        null;

    registry.removeIfExists(component.Attacking, attacker);

    try map_ecs.broadcast(.{ attacker, .{ .ignore_sender = false } }, protocol.spell.AttackStopServer{
        .attacker_guid = registry.getConst(component.Guid, attacker).value,
        .victim_guid = victim_guid,
    });
}

/// Destroys the caster's live cast, if any, and clears the casting
/// animation on every client: the interrupted packets are what stop the
/// cast animation on other clients (a stationary interrupted caster emits
/// no movement packets that could do it). The client that cancelled
/// already dropped its own cast bar, but replays the animation reset
/// harmlessly.
pub fn interruptCast(map_ecs: *MapEcs, caster: Entity, spell_filter: ?u32) !void {
    const registry = &map_ecs.registry;

    var casts = registry.view(.{component.SpellCast}, .{});
    var it = casts.entityIterator();
    while (it.next()) |cast_entity| {
        const cast = registry.getConst(component.SpellCast, cast_entity);
        if (cast.caster != caster) continue;
        if (spell_filter) |spell_id| {
            if (cast.spell_entry != spell_id) continue;
        }

        const caster_guid = if (registry.has(component.Guid, caster))
            registry.getConst(component.Guid, caster).value
        else
            domain.ObjectGuid.empty;

        registry.destroy(cast_entity);

        try map_ecs.broadcast(.{ caster, .{ .ignore_sender = false } }, protocol.spell.SpellFailureServer{
            .caster_guid = caster_guid,
            .cast_count = cast.cast_count,
            .spell_id = cast.spell_entry,
            .result = .interrupted,
        });
        try map_ecs.broadcast(.{ caster, .{ .ignore_sender = false } }, protocol.spell.SpellFailedOtherServer{
            .caster_guid = caster_guid,
            .cast_count = cast.cast_count,
            .spell_id = cast.spell_entry,
            .result = .interrupted,
        });
        return;
    }
}

pub fn handleCancelCast(map_ecs: *MapEcs, cancel: EcsInput.CancelCast) !void {    const caster = map_ecs.findPlayer(cancel.account_id) orelse return;

    // Client-initiated cancel (ESC): retail also acknowledges with
    // SMSG_CAST_FAILED(interrupted) to the caster, then broadcasts the
    // interrupted pair (Spell::cancel, PREPARING state).
    const registry = &map_ecs.registry;
    var cast_count: ?u8 = null;
    var casts = registry.view(.{component.SpellCast}, .{});
    var it = casts.entityIterator();
    while (it.next()) |cast_entity| {
        const cast = registry.getConst(component.SpellCast, cast_entity);
        if (cast.caster == caster and cast.spell_entry == cancel.packet.spell_id) {
            cast_count = cast.cast_count;
            break;
        }
    }
    if (cast_count) |cc| {
        try map_ecs.sendTo(caster, protocol.spell.CastFailedServer{
            .cast_count = cc,
            .spell_id = cancel.packet.spell_id,
            .result = .interrupted,
        });
    }

    return interruptCast(map_ecs, caster, cancel.packet.spell_id);
}

/// CMSG_SET_SHEATHED: stores the client-driven weapon pose and propagates
/// it through a bytes_2 values update so other clients see the draw.
pub fn handleSheath(map_ecs: *MapEcs, frame: MapEcs.Frame, sheathed: EcsInput.SetSheathed) !void {
    const registry = &map_ecs.registry;

    const player = map_ecs.findPlayer(sheathed.account_id) orelse return;
    registry.get(component.Sheath, player).*.state = sheathed.packet.sheath_state;

    var fields = protocol.object.Fields{};
    fields.set(protocol.object.UnitField.bytes_2, protocol.object.bytes2FieldValue(sheathed.packet.sheath_state));
    var pkt = try protocol.object.UpdateObject.init(frame.arena_allocator);
    defer pkt.deinit(frame.arena_allocator);
    try pkt.add(frame.arena_allocator, .{ .values = .{
        .guid = registry.getConst(component.Guid, player).value,
        .fields = fields,
    } });
    try map_ecs.broadcast(.{ player, .{ .ignore_sender = false } }, pkt);
}

/// Progresses every live cast; finished casts apply their effects and die.
pub fn run(map_ecs: *MapEcs, frame: MapEcs.Frame) !void {
    const registry = &map_ecs.registry;

    var casts = registry.view(.{component.SpellCast}, .{});
    var it = casts.entityIterator();
    while (it.next()) |cast_entity| {
        const cast = registry.getConst(component.SpellCast, cast_entity);
        if (frame.time_now < cast.finish_ms) continue;

        // Complete the cast. Destroy the entity first so re-entrant work
        // (spawning auras, sending packets) sees a consistent state.
        registry.destroy(cast_entity);

        const def = domain.spells.findSpell(cast.spell_entry) orelse continue;
        if (!registry.valid(cast.caster) or !registry.valid(cast.target)) continue;
        if (!registry.has(component.Health, cast.target)) continue;
        // Dead targets take no further effect from a cast finishing.
        if (registry.getConst(component.Health, cast.target).current == 0) continue;

        const caster_guid = registry.getConst(component.Guid, cast.caster).value;
        const target_guid = registry.getConst(component.Guid, cast.target).value;

        const damage = rollDamage(frame.io, def.min_damage, def.max_damage);
        const died = applyDamage(registry, cast.target, damage);

        try map_ecs.broadcast(.{ cast.caster, .{ .ignore_sender = false } }, protocol.spell.SpellGoServer{
            .caster_guid = caster_guid,
            .cast_count = cast.cast_count,
            .spell_id = def.entry,
            .timestamp_ms = @truncate(frame.time_now),
            .hit_guids = &.{target_guid},
            .target_guid = target_guid,
        });

        try map_ecs.broadcast(.{ cast.caster, .{ .ignore_sender = false } }, protocol.spell.SpellNonMeleeDamageServer{
            .victim_guid = target_guid,
            .attacker_guid = caster_guid,
            .spell_id = def.entry,
            .damage = damage,
            .school_mask = def.school,
        });

        try sendHealthUpdate(map_ecs, frame, cast.caster, cast.target);

        if (died) {
            try handleDeath(map_ecs, frame, cast.target);
        } else if (def.movement_slow_pct > 0 and def.aura_duration_ms > 0) {
            try applyAura(map_ecs, frame, .{
                .target = cast.target,
                .caster = cast.caster,
                .spell_entry = def.entry,
                .movement_slow_pct = def.movement_slow_pct,
                .duration_ms = def.aura_duration_ms,
            });
        }
    }
}

pub const AuraRequest = struct {
    target: Entity,
    caster: Entity,
    spell_entry: u32,
    movement_slow_pct: u32,
    duration_ms: u32,
};

/// Applies (or refreshes) an aura on the target and notifies clients.
pub fn applyAura(map_ecs: *MapEcs, frame: MapEcs.Frame, req: AuraRequest) !void {
    const registry = &map_ecs.registry;

    const caster_guid = if (registry.valid(req.caster) and registry.has(component.Guid, req.caster))
        registry.getConst(component.Guid, req.caster).value.valueOf()
    else
        0;
    const caster_level: u8 = if (registry.valid(req.caster) and registry.has(component.Level, req.caster))
        registry.getConst(component.Level, req.caster).value
    else
        1;

    // Same spell on the same target refreshes the existing aura instead of
    // stacking a second slow.
    var auras = registry.view(.{component.Aura}, .{});
    var it = auras.entityIterator();
    while (it.next()) |aura_entity| {
        const aura = registry.getConst(component.Aura, aura_entity);
        if (aura.target != req.target or aura.spell_entry != req.spell_entry) continue;

        registry.get(component.Aura, aura_entity).*.apply_ms = frame.time_now;
        registry.get(component.Aura, aura_entity).*.expire_ms = frame.time_now + req.duration_ms;

        try broadcastAura(map_ecs, aura_entity);
        try broadcastSpeed(map_ecs, req.target);
        return;
    }

    const aura_entity = registry.create();
    registry.add(aura_entity, component.Aura{
        .target = req.target,
        .caster = req.caster,
        .caster_guid = caster_guid,
        .caster_level = caster_level,
        .spell_entry = req.spell_entry,
        .slot = nextFreeAuraSlot(registry, req.target),
        .apply_ms = frame.time_now,
        .expire_ms = frame.time_now + req.duration_ms,
        .max_duration_ms = req.duration_ms,
        .movement_slow_pct = req.movement_slow_pct,
    });

    try broadcastAura(map_ecs, aura_entity);
    try broadcastSpeed(map_ecs, req.target);
}

/// Removes expired auras and cleans up auras whose target despawned.
pub fn tickAuras(map_ecs: *MapEcs, frame: MapEcs.Frame) !void {
    const registry = &map_ecs.registry;

    var auras = registry.view(.{component.Aura}, .{});
    var it = auras.entityIterator();
    while (it.next()) |aura_entity| {
        const aura = registry.getConst(component.Aura, aura_entity);
        if (!registry.valid(aura.target) or !registry.has(component.Guid, aura.target)) {
            registry.destroy(aura_entity);
            continue;
        }
        if (frame.time_now < aura.expire_ms) continue;

        const target_guid = registry.getConst(component.Guid, aura.target).value;
        registry.destroy(aura_entity);

        try map_ecs.broadcast(.{ aura.target, .{ .ignore_sender = false } }, protocol.spell.AuraUpdateServer.remove(target_guid, aura.slot));
        try broadcastSpeed(map_ecs, aura.target);
    }
}

/// Effective run speed of a unit: base speed scaled by every movement
/// slow aura currently applied (multiplicative stacking).
pub fn effectiveRunSpeed(registry: *ecs.Registry, target: Entity) f32 {
    var speed = base_run_speed;

    var auras = registry.view(.{component.Aura}, .{});
    var it = auras.entityIterator();
    while (it.next()) |aura_entity| {
        const aura = registry.getConst(component.Aura, aura_entity);
        if (aura.target != target) continue;
        speed *= 1.0 - @as(f32, @floatFromInt(aura.movement_slow_pct)) / 100.0;
    }

    return speed;
}

pub fn broadcastSpeed(map_ecs: *MapEcs, target: Entity) !void {
    const registry = &map_ecs.registry;
    try map_ecs.broadcast(.{ target, .{ .ignore_sender = false } }, protocol.spell.ForceRunSpeedChangeServer{
        .guid = registry.getConst(component.Guid, target).value,
        .speed = effectiveRunSpeed(registry, target),
    });
}

fn broadcastAura(map_ecs: *MapEcs, aura_entity: Entity) !void {
    const registry = &map_ecs.registry;
    const aura = registry.getConst(component.Aura, aura_entity);
    try map_ecs.broadcast(.{ aura.target, .{ .ignore_sender = false } }, protocol.spell.AuraUpdateServer{
        .target_guid = registry.getConst(component.Guid, aura.target).value,
        .slot = aura.slot,
        .spell_id = aura.spell_entry,
        .caster_level = aura.caster_level,
        .caster_guid = ObjectGuid.fromRaw(aura.caster_guid),
        .max_duration_ms = aura.max_duration_ms,
        .remaining_ms = @intCast(aura.expire_ms - aura.apply_ms),
        .flags = protocol.spell.aura_flag_eff_index_0 | protocol.spell.aura_flag_negative | protocol.spell.aura_flag_duration,
    });
}

fn nextFreeAuraSlot(registry: *ecs.Registry, target: Entity) u8 {
    var used = [_]bool{false} ** 256;

    var auras = registry.view(.{component.Aura}, .{});
    var it = auras.entityIterator();
    while (it.next()) |aura_entity| {
        const aura = registry.getConst(component.Aura, aura_entity);
        if (aura.target == target) used[aura.slot] = true;
    }

    for (used, 0..) |is_used, slot| {
        if (!is_used) return @intCast(slot);
    }
    return 0;
}

fn sendCastFailed(map_ecs: *MapEcs, caster: Entity, cast_count: u8, spell_id: u32, result: protocol.spell.CastFailedCode) !void {
    try map_ecs.sendTo(caster, protocol.spell.CastFailedServer{
        .cast_count = cast_count,
        .spell_id = spell_id,
        .result = result,
    });
}

/// Broadcasts the current health of `target` as a VALUES update block.
pub fn sendHealthUpdate(map_ecs: *MapEcs, frame: MapEcs.Frame, sender: Entity, target: Entity) !void {
    const registry = &map_ecs.registry;
    var pkt = try protocol.object.UpdateObject.init(frame.arena_allocator);
    defer pkt.deinit(frame.arena_allocator);

    var fields = protocol.object.Fields{};
    fields.set(protocol.object.UnitField.health, registry.getConst(component.Health, target).current);
    try pkt.add(frame.arena_allocator, .{ .values = .{ .guid = registry.getConst(component.Guid, target).value, .fields = fields } });

    try map_ecs.broadcast(.{ sender, .{ .ignore_sender = false } }, pkt);
}

/// v1 death: zero health is dead. The client renders the death pose from
/// the health field; a relogin resurrects (health recomputed from stats).
pub fn applyDamage(registry: *ecs.Registry, target: Entity, damage: u32) bool {
    const health = registry.get(component.Health, target);
    if (health.current == 0) return false;
    health.*.current = health.current -| damage;
    return health.current == 0;
}

/// Death cleanup mirroring the reference core's Unit::setDeathState +
/// Player::KillPlayer: zero health/power on the wire, stop the victim's
/// own attacks and cast, stop everyone attacking the victim, drop auras.
pub fn handleDeath(map_ecs: *MapEcs, frame: MapEcs.Frame, victim: Entity) !void {
    const registry = &map_ecs.registry;

    // Wire state: health 0 + power 0 (public fields; the client renders
    // the death pose from health).
    const victim_guid = registry.getConst(component.Guid, victim).value;
    const power_type: u8 = if (registry.has(component.Appearance, victim))
        @intFromEnum(registry.getConst(component.Appearance, victim).class_id.powerTypeId())
    else
        0;

    var pkt = try protocol.object.UpdateObject.init(frame.arena_allocator);
    defer pkt.deinit(frame.arena_allocator);
    var fields = protocol.object.Fields{};
    fields.set(protocol.object.UnitField.health, 0);
    if (power_type < 7) fields.set(protocol.object.UnitField.power(power_type), 0);
    try pkt.add(frame.arena_allocator, .{ .values = .{ .guid = victim_guid, .fields = fields } });
    try map_ecs.broadcast(.{ victim, .{ .ignore_sender = false } }, pkt);

    // The victim's own cast dies (retail: InterruptNonMeleeSpells).
    try interruptCast(map_ecs, victim, null);

    // The victim stops attacking.
    if (registry.has(component.Attacking, victim)) {
        registry.removeIfExists(component.Attacking, victim);
        try map_ecs.broadcast(.{ victim, .{ .ignore_sender = false } }, protocol.spell.AttackStopServer{
            .attacker_guid = victim_guid,
            .victim_guid = null,
        });
    }

    // Everyone attacking the victim stops.
    var attackers = registry.view(.{component.Attacking}, .{});
    var attacker_it = attackers.entityIterator();
    while (attacker_it.next()) |attacker| {
        if (registry.getConst(component.Attacking, attacker).target != victim) continue;
        registry.removeIfExists(component.Attacking, attacker);
        try map_ecs.broadcast(.{ attacker, .{ .ignore_sender = false } }, protocol.spell.AttackStopServer{
            .attacker_guid = registry.getConst(component.Guid, attacker).value,
            .victim_guid = victim_guid,
        });
    }

    // Auras drop on death (retail: RemoveAllAurasOnDeath).
    var auras = registry.view(.{component.Aura}, .{});
    var aura_it = auras.entityIterator();
    while (aura_it.next()) |aura_entity| {
        const aura = registry.getConst(component.Aura, aura_entity);
        if (aura.target != victim) continue;
        registry.destroy(aura_entity);
        try map_ecs.broadcast(.{ victim, .{ .ignore_sender = false } }, protocol.spell.AuraUpdateServer.remove(victim_guid, aura.slot));
    }
}

pub fn rollDamage(io: std.Io, min: u32, max: u32) u32 {
    if (max <= min) return min;
    const span = max - min + 1;
    var buf: [4]u8 = undefined;
    io.random(&buf);
    return min + std.mem.readInt(u32, &buf, .little) % span;
}

fn distance(registry: *ecs.Registry, a: Entity, b: Entity) f32 {
    const pa = registry.getConst(component.Position, a);
    const pb = registry.getConst(component.Position, b);
    const dx = pa.x - pb.x;
    const dy = pa.y - pb.y;
    const dz = pa.z - pb.z;
    return @sqrt(dx * dx + dy * dy + dz * dz);
}

const ObjectGuid = domain.ObjectGuid;
