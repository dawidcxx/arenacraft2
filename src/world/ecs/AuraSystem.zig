//! Aura lifecycle: apply requests admit auras into client-visible slots
//! (immunity may veto, re-applies refresh), durations retire them, and
//! periodic effects tick on independent timers. Folded stats are never
//! touched here — aura changes mark StatsDirty and DerivedStatSystem folds.

const std = @import("std");
const ecs = @import("ecs");
const domain = @import("domain");
const proto = @import("protocol");

const component = @import("./EcsComponent.zig");
const AuraQuery = @import("./AuraQuery.zig");
const MapEcs = @import("./MapEcs.zig").MapEcs;

const CategoryMask = domain.SpellDef.Category.Mask;

const log = std.log.scoped(.aura_system);

pub fn run(map_ecs: *MapEcs, frame: MapEcs.Frame) !void {
    cleanupDepartedOwners(map_ecs);
    applyRequests(map_ecs);
    expireAuras(map_ecs, frame);
    tickPeriodics(map_ecs, frame);
}

/// A departing unit's auras die with it — no wire, the unit despawns.
fn cleanupDepartedOwners(map_ecs: *MapEcs) void {
    var registry = &map_ecs.registry;

    for (map_ecs.events.get(.player_left).items) |event| {
        const owner = event.player_left.player;
        for (map_ecs.state.aura_slots.items(owner)) |slot| if (slot) |aura_ent| {
            registry.destroy(aura_ent);
        };
        map_ecs.state.aura_slots.removeTarget(owner);
    }
}

fn applyRequests(map_ecs: *MapEcs) void {
    var registry = &map_ecs.registry;

    for (map_ecs.events.get(.aura_apply_request).items) |event| {
        const aura_ent = event.aura_apply_request.aura;
        if (!registry.valid(aura_ent)) continue;
        const aura = registry.getConst(component.Aura, aura_ent);
        const owner = aura.owner;

        // Immunity veto: hostile applications against an immune owner drop.
        if (aura.caster != owner and AuraQuery.isImmuneTo(map_ecs, owner, aura.school)) {
            // TODO: immune feedback packet for the caster
            registry.destroy(aura_ent);
            continue;
        }

        // Re-applying a live spell refreshes its duration instead of
        // stacking a second aura into a new slot.
        if (findBySpell(map_ecs, owner, aura.spell_id)) |existing| {
            if (existing == aura_ent) continue; // already admitted
            refreshAura(map_ecs, existing, aura_ent);
            continue;
        }

        _ = map_ecs.state.aura_slots.addAuraForTarget(owner, aura_ent) orelse {
            log.info("aura slot cap reached, dropping aura (spell_id={d})", .{aura.spell_id});
            registry.destroy(aura_ent);
            continue;
        };
        broadcastApply(map_ecs, aura_ent);
        markStatsDirty(map_ecs, owner, aura.effects);
    }
}

fn refreshAura(map_ecs: *MapEcs, existing: ecs.Entity, fresh: ecs.Entity) void {
    var registry = &map_ecs.registry;

    // Same spell, so both sides carry the same duration shape; permanent
    // auras simply have nothing to reset.
    if (registry.tryGetConst(component.AuraDuration, fresh)) |fresh_duration| {
        if (registry.tryGet(component.AuraDuration, existing)) |duration| {
            duration.* = fresh_duration;
        }
    }
    if (registry.tryGet(component.AuraPeriodic, existing)) |periodic| {
        periodic.timer = periodic.interval_ms;
    }

    broadcastApply(map_ecs, existing);
    registry.destroy(fresh);
}

fn findBySpell(map_ecs: *MapEcs, owner: ecs.Entity, spell_id: u32) ?ecs.Entity {
    var registry = &map_ecs.registry;
    for (map_ecs.state.aura_slots.items(owner)) |slot| if (slot) |aura_ent| {
        if (registry.getConst(component.Aura, aura_ent).spell_id == spell_id) return aura_ent;
    };
    return null;
}

fn expireAuras(map_ecs: *MapEcs, frame: MapEcs.Frame) void {
    var registry = &map_ecs.registry;
    const alloc = frame.arena_allocator;

    var expired = std.ArrayList(ecs.Entity).initCapacity(alloc, 8) catch unreachable;
    defer expired.deinit(alloc);

    var duration_view = registry.view(.{component.AuraDuration}, .{});
    var duration_it = duration_view.entityIterator();
    while (duration_it.next()) |aura_ent| {
        const duration = registry.get(component.AuraDuration, aura_ent);
        duration.remaining -|= frame.dt;
        if (duration.remaining == 0) expired.append(alloc, aura_ent) catch unreachable;
    }

    var compact_candidates = std.ArrayList(ecs.Entity).initCapacity(alloc, 4) catch unreachable;
    defer compact_candidates.deinit(alloc);

    for (expired.items) |aura_ent| {
        const aura = registry.getConst(component.Aura, aura_ent);
        const owner = aura.owner;

        if (map_ecs.state.aura_slots.removeAuraForTarget(owner, aura_ent)) |slot| {
            map_ecs.broadcast(
                .{ owner, .{ .ignore_sender = false } },
                proto.spell.AuraUpdateServer.remove(registry.getConst(component.Guid, owner).value, slot),
            );
        }
        markStatsDirty(map_ecs, owner, aura.effects);
        registry.destroy(aura_ent);

        if (std.mem.indexOfScalar(ecs.Entity, compact_candidates.items, owner) == null) {
            compact_candidates.append(alloc, owner) catch unreachable;
        }
    }

    // Tombstone-heavy windows compact (slots renumber) and observers get a
    // full resync — incremental patching is deliberately not attempted.
    for (compact_candidates.items) |owner| {
        if (!map_ecs.state.aura_slots.needsCompaction(owner)) continue;
        map_ecs.state.aura_slots.compactForTarget(owner);
        broadcastResync(map_ecs, owner);
    }
}

fn tickPeriodics(map_ecs: *MapEcs, frame: MapEcs.Frame) void {
    var registry = &map_ecs.registry;

    var periodic_view = registry.view(.{component.AuraPeriodic}, .{});
    var periodic_it = periodic_view.entityIterator();
    while (periodic_it.next()) |aura_ent| {
        const periodic = registry.get(component.AuraPeriodic, aura_ent);
        if (periodic.timer > frame.dt) {
            periodic.timer -= frame.dt;
            continue;
        }
        periodic.timer = periodic.interval_ms;

        const aura = registry.getConst(component.Aura, aura_ent);
        const tick = AuraQuery.firstPeriodic(aura.effects) orelse continue;
        // TODO: roll [min, max] and route through a damage/health system
        // once combat exists
        map_ecs.broadcast(
            .{ aura.owner, .{ .ignore_sender = false } },
            proto.spell.SpellNonMeleeDamageServer{
                .victim_guid = registry.getConst(component.Guid, aura.owner).value,
                .attacker_guid = casterGuid(registry, aura.caster),
                .spell_id = aura.spell_id,
                .damage = tick.max,
                .school_mask = @as(u8, 1) << @intCast(@intFromEnum(aura.school)),
            },
        );
    }
}

fn broadcastApply(map_ecs: *MapEcs, aura_ent: ecs.Entity) void {
    var registry = &map_ecs.registry;

    const aura = registry.getConst(component.Aura, aura_ent);
    const slot = map_ecs.state.aura_slots.slotOf(aura.owner, aura_ent) orelse unreachable;

    var packet = proto.spell.AuraUpdateServer{
        .target_guid = registry.getConst(component.Guid, aura.owner).value,
        .slot = slot,
        .spell_id = aura.spell_id,
        .caster_level = casterLevel(registry, aura.caster),
        .caster_guid = casterGuid(registry, aura.caster),
    };
    if (registry.tryGetConst(component.AuraDuration, aura_ent)) |duration| {
        packet.remaining_ms = duration.remaining;
        packet.max_duration_ms = duration.max;
    } else {
        // Permanent auras carry no duration pair on the wire.
        packet.flags &= ~proto.spell.aura_flag_duration;
    }
    map_ecs.broadcast(.{ aura.owner, .{ .ignore_sender = false } }, packet);
}

/// Full slot resync for one unit after compaction renumbered its slots.
fn broadcastResync(map_ecs: *MapEcs, owner: ecs.Entity) void {
    var registry = &map_ecs.registry;

    var entries: [56]proto.spell.AuraSlotUpdate = undefined;
    var len: usize = 0;
    for (map_ecs.state.aura_slots.items(owner), 0..) |slot, slot_id| if (slot) |aura_ent| {
        const aura = registry.getConst(component.Aura, aura_ent);
        var entry = proto.spell.AuraSlotUpdate{
            .slot = @intCast(slot_id),
            .spell_id = aura.spell_id,
            .caster_level = casterLevel(registry, aura.caster),
            .caster_guid = casterGuid(registry, aura.caster),
        };
        if (registry.tryGetConst(component.AuraDuration, aura_ent)) |duration| {
            entry.remaining_ms = duration.remaining;
            entry.max_duration_ms = duration.max;
        } else {
            entry.flags &= ~proto.spell.aura_flag_duration;
        }
        entries[len] = entry;
        len += 1;
    };

    map_ecs.broadcast(
        .{ owner, .{ .ignore_sender = false } },
        proto.spell.AuraUpdateAllServer{
            .target_guid = registry.getConst(component.Guid, owner).value,
            .entries = entries[0..len],
        },
    );
}

fn casterGuid(registry: *ecs.Registry, caster: ecs.Entity) domain.ObjectGuid {
    // Auras outlive their caster; a departed caster reads as anonymous.
    if (registry.valid(caster)) {
        if (registry.tryGetConst(component.Guid, caster)) |guid| return guid.value;
    }
    return domain.ObjectGuid.empty;
}

fn casterLevel(registry: *ecs.Registry, caster: ecs.Entity) u8 {
    if (registry.valid(caster)) {
        if (registry.tryGetConst(component.Level, caster)) |level| return level.value;
    }
    return 1;
}

/// ORs the categories of `effects` into the owner's StatsDirty mask,
/// installing the component on first touch.
fn markStatsDirty(map_ecs: *MapEcs, unit: ecs.Entity, effects: []const domain.SpellDef.AuraEffect) void {
    var mask = CategoryMask{ .value = 0 };
    for (effects) |effect| {
        if (effect.category()) |cat| mask = mask.matchOr(CategoryMask.of(cat));
    }
    if (mask.value == 0) return;

    if (map_ecs.registry.tryGet(component.StatsDirty, unit)) |dirty| {
        dirty.mask = dirty.mask.matchOr(mask);
    } else {
        map_ecs.registry.add(unit, component.StatsDirty{ .mask = mask });
    }
}

// --- tests -------------------------------------------------------------------------

const t = std.testing;
const stdx = @import("stdx");

const aura_update_op: u32 = @intFromEnum(proto.spell.AuraUpdateServer.opcode);

const Rig = @import("EcsTestRig.zig").Rig;

const slow_40 = [_]domain.SpellDef.AuraEffect{.{ .movement_speed_mod = .{ .pct = -40 } }};
const immune_all = [_]domain.SpellDef.AuraEffect{.{ .immune = .{ .school_mask = 0x7F } }};
const agony_tick = [_]domain.SpellDef.AuraEffect{.{ .periodic_damage = .{ .interval_ms = 3000, .min = 5, .max = 7 } }};

fn step(rig: *Rig, dt: u32) !void {
    try run(&rig.map_ecs, rig.frame(dt));
    rig.drainEvents();
}

test "apply assigns a slot, broadcasts the update and marks stats dirty" {
    var rig = try Rig.init();
    defer rig.deinit();

    const aura_ent = rig.requestAura(rig.owner, rig.caster, 116, .frost, &slow_40, 5000);
    try step(&rig, 50);

    try t.expect(rig.map_ecs.registry.valid(aura_ent));
    try t.expectEqual(@as(usize, 1), rig.occupiedAuras(rig.owner));
    try t.expectEqual(@as(u8, 0), rig.map_ecs.state.aura_slots.slotOf(rig.owner, aura_ent).?);
    try t.expectEqual(@as(usize, 1), rig.broadcastCount(aura_update_op));

    const dirty = rig.map_ecs.registry.getConst(component.StatsDirty, rig.owner);
    try t.expect(dirty.mask.has(.movement_speed));
    try t.expect(!dirty.mask.has(.max_health));
}

test "re-applying the same spell refreshes instead of stacking" {
    var rig = try Rig.init();
    defer rig.deinit();

    const first = rig.requestAura(rig.owner, rig.caster, 116, .frost, &slow_40, 5000);
    try step(&rig, 50);

    // Burn 2000ms so the refresh is observable.
    try step(&rig, 2000);

    const second = rig.requestAura(rig.owner, rig.caster, 116, .frost, &slow_40, 5000);
    try step(&rig, 50);

    try t.expect(rig.map_ecs.registry.valid(first));
    try t.expect(!rig.map_ecs.registry.valid(second));
    try t.expectEqual(@as(usize, 1), rig.occupiedAuras(rig.owner));
    try t.expectEqual(@as(u32, 5000 - 50), rig.map_ecs.registry.getConst(component.AuraDuration, first).remaining);
    // Apply + refresh both broadcast; the refresh is not a new stat change.
    try t.expectEqual(@as(usize, 2), rig.broadcastCount(aura_update_op));
}

test "expiry frees the slot, broadcasts removal and re-marks stats" {
    var rig = try Rig.init();
    defer rig.deinit();

    const aura_ent = rig.requestAura(rig.owner, rig.caster, 116, .frost, &slow_40, 100);
    try step(&rig, 50);
    try t.expect(rig.map_ecs.registry.valid(aura_ent));

    try step(&rig, 50);
    try t.expect(!rig.map_ecs.registry.valid(aura_ent));
    try t.expectEqual(@as(usize, 0), rig.occupiedAuras(rig.owner));
    try t.expectEqual(@as(usize, 2), rig.broadcastCount(aura_update_op)); // apply + remove

    const dirty = rig.map_ecs.registry.getConst(component.StatsDirty, rig.owner);
    try t.expect(dirty.mask.has(.movement_speed));
}

test "hostile application against an immune target is vetoed" {
    var rig = try Rig.init();
    defer rig.deinit();

    _ = rig.requestAura(rig.owner, rig.owner, 45438, .frost, &immune_all, 4000);
    try step(&rig, 50);
    try t.expectEqual(@as(usize, 1), rig.occupiedAuras(rig.owner));

    const hostile = rig.requestAura(rig.owner, rig.caster, 116, .frost, &slow_40, 5000);
    try step(&rig, 50);

    try t.expect(!rig.map_ecs.registry.valid(hostile));
    try t.expectEqual(@as(usize, 1), rig.occupiedAuras(rig.owner));
}

test "periodic auras tick on their interval" {
    var rig = try Rig.init();
    defer rig.deinit();

    const damage_op: u32 = @intFromEnum(proto.spell.SpellNonMeleeDamageServer.opcode);
    _ = rig.requestAura(rig.owner, rig.caster, 980, .shadow, &agony_tick, 9000);
    try step(&rig, 50);

    // 58 more frames bring the timer to exactly one dt short of the tick.
    for (0..58) |_| try step(&rig, 50);
    try t.expectEqual(@as(usize, 0), rig.broadcastCount(damage_op));

    try step(&rig, 50);
    try t.expectEqual(@as(usize, 1), rig.broadcastCount(damage_op));
}

test "tombstone-heavy windows compact and resync" {
    var rig = try Rig.init();
    defer rig.deinit();

    const aura_update_all_op: u32 = @intFromEnum(proto.spell.AuraUpdateAllServer.opcode);
    const empty = [_]domain.SpellDef.AuraEffect{};

    const short_1 = rig.requestAura(rig.owner, rig.caster, 201, .frost, &empty, 100);
    _ = rig.requestAura(rig.owner, rig.caster, 202, .frost, &empty, 200);
    _ = rig.requestAura(rig.owner, rig.caster, 203, .frost, &empty, 300);
    const long_lived = rig.requestAura(rig.owner, rig.caster, 204, .frost, &empty, 60_000);
    try step(&rig, 100);

    // Three frames at dt=100 expire 201..203 in sequence.
    try step(&rig, 100);
    try step(&rig, 100);
    try t.expect(!rig.map_ecs.registry.valid(short_1));

    // Small windows re-cross the half-tombstone threshold on each expiry,
    // so several resyncs are expected; what matters is the final state.
    try t.expect(rig.broadcastCount(aura_update_all_op) >= 1);
    try t.expectEqual(@as(usize, 1), rig.occupiedAuras(rig.owner));
    try t.expectEqual(@as(u8, 0), rig.map_ecs.state.aura_slots.slotOf(rig.owner, long_lived).?);
}

test "a departed caster cannot crash the pipeline" {
    var rig = try Rig.init();
    defer rig.deinit();

    const departed = rig.player(3);
    rig.map_ecs.registry.destroy(departed);
    const aura_ent = rig.requestAura(rig.owner, departed, 116, .frost, &slow_40, 5000);
    try step(&rig, 50);

    try t.expect(rig.map_ecs.registry.valid(aura_ent));
    try t.expectEqual(@as(usize, 1), rig.broadcastCount(aura_update_op));
}
