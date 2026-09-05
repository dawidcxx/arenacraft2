//! Cast lifecycle. Requests arrive as unvalidated CastRequest entities
//! transliterated from the wire; each is validated here and either
//! upgraded in place into a Cast (the effect fires once finish_ms passes)
//! or destroyed with a cast_failed event. Interrupts — client cancel and
//! displacing movement — tear down the running cast; mana is deducted when
//! the cast starts and is not refunded. All packet emission lives in
//! SpellPacketsSystem.

const std = @import("std");
const ecs = @import("ecs");
const domain = @import("domain");
const game_data = @import("game_data");
const protocol = @import("protocol");

const component = @import("EcsComponent.zig");
const MapEcs = @import("MapEcs.zig").MapEcs;

const log = std.log.scoped(.cast_system);

pub const InterruptKind = struct {
    /// CMSG_CANCEL_CAST: the caster additionally gets SMSG_CAST_FAILED;
    /// movement interrupts only broadcast the animation-clearing pair.
    by_client: bool,
};

/// Upper bound on requests/casts handled per tick; the input queue is
/// bounded so this cannot be exceeded through the wire.
const max_per_tick: usize = 256;

pub fn run(map_ecs: *MapEcs, frame: MapEcs.Frame) !void {
    try upgradeRequests(map_ecs, frame);
    try tickCasts(map_ecs, frame);
}

/// Validates every pending CastRequest and upgrades the passing ones into
/// Casts. Entities are collected before mutation so destroying a failed
/// request cannot invalidate the view iterator.
fn upgradeRequests(map_ecs: *MapEcs, frame: MapEcs.Frame) !void {
    const registry = &map_ecs.registry;

    var request_entities: [max_per_tick]ecs.Entity = undefined;
    var request_count: usize = 0;
    {
        var requests = registry.view(.{component.CastRequest}, .{});
        var it = requests.entityIterator();
        while (it.next()) |entity| {
            request_entities[request_count] = entity;
            request_count += 1;
            if (request_count == max_per_tick) {
                log.warn("request backlog above {d}; deferring the rest", .{request_count});
                break;
            }
        }
    }

    for (request_entities[0..request_count]) |request_entity| {
        if (!registry.valid(request_entity)) continue;
        const request = registry.getConst(component.CastRequest, request_entity);

        switch (check(map_ecs, request)) {
            .fail => |reason| {
                registry.destroy(request_entity);
                try map_ecs.addEvent(.{ .cast_failed = .{
                    .caster = request.caster,
                    .spell_id = request.spell_id,
                    .cast_count = request.cast_count,
                    .reason = reason,
                } });
            },
            .ok => |verdict| {
                const cost = manaCost(verdict.def);
                registry.get(component.Power, request.caster).*.current -= cost;

                // The request entity itself becomes the Cast: it matures
                // in place, keeping a stable identity across the upgrade.
                registry.removeIfExists(component.CastRequest, request_entity);
                registry.add(request_entity, component.Cast{
                    .caster = request.caster,
                    .target = verdict.target,
                    .spell_id = request.spell_id,
                    .cast_count = request.cast_count,
                    .finish_ms = frame.time_now + verdict.def.cast_time_ms,
                });

                try map_ecs.addEvent(.{ .cast_started = .{
                    .caster = request.caster,
                    .target = verdict.target,
                    .spell_id = request.spell_id,
                    .cast_count = request.cast_count,
                    .delay_ms = @intCast(verdict.def.cast_time_ms),
                } });
            },
        }
    }
}

const Verdict = union(enum) {
    ok: struct { def: domain.SpellDef, target: ecs.Entity },
    fail: protocol.spell.CastFailedCode,
};

/// The validation checklist, cheapest check first.
fn check(map_ecs: *MapEcs, request: component.CastRequest) Verdict {
    const registry = &map_ecs.registry;

    // The caster may have left between request spawn and validation.
    if (!registry.valid(request.caster)) return .{ .fail = .caster_dead };

    const def = game_data.spells.findSpell(request.spell_id) orelse
        return .{ .fail = .not_known };
    // Effects without a magnitude (languages, professions) are not
    // castable in v1.
    if (def.effect == .none) return .{ .fail = .not_known };

    const caster_health = registry.tryGetConst(component.Health, request.caster);
    if (caster_health != null and caster_health.?.current == 0)
        return .{ .fail = .caster_dead };

    // One cast at a time per caster.
    var casts = registry.view(.{component.Cast}, .{});
    var casts_it = casts.entityIterator();
    while (casts_it.next()) |cast_entity| {
        if (registry.getConst(component.Cast, cast_entity).caster == request.caster)
            return .{ .fail = .spell_in_progress };
    }

    const target = if (request.target_guid) |guid|
        map_ecs.findByGuid(guid) orelse return .{ .fail = .bad_implicit_targets }
    else
        return .{ .fail = .bad_implicit_targets };

    const target_health = registry.tryGetConst(component.Health, target);
    if (target_health != null and target_health.?.current == 0)
        return .{ .fail = .targets_dead };

    if (distance(registry, request.caster, target) > @as(f32, @floatFromInt(def.range_yards)))
        return .{ .fail = .out_of_range };

    if (manaCost(def) > registry.getConst(component.Power, request.caster).current)
        return .{ .fail = .no_power };

    return .{ .ok = .{ .def = def, .target = target } };
}

/// Applies the effect of every cast whose time has come. Cast entities are
/// collected before mutation; destroying one mid-loop would invalidate
/// the view iterator.
fn tickCasts(map_ecs: *MapEcs, frame: MapEcs.Frame) !void {
    const registry = &map_ecs.registry;

    var cast_entities: [max_per_tick]ecs.Entity = undefined;
    var cast_count: usize = 0;
    {
        var casts = registry.view(.{component.Cast}, .{});
        var it = casts.entityIterator();
        while (it.next()) |entity| {
            cast_entities[cast_count] = entity;
            cast_count += 1;
            if (cast_count == max_per_tick) {
                log.warn("cast backlog above {d}; deferring the rest", .{cast_count});
                break;
            }
        }
    }

    for (cast_entities[0..cast_count]) |cast_entity| {
        if (!registry.valid(cast_entity)) continue;
        const cast = registry.getConst(component.Cast, cast_entity);
        if (frame.time_now < cast.finish_ms) continue;

        // Caster or target may have left mid-cast.
        if (registry.valid(cast.caster) and registry.valid(cast.target)) {
            if (game_data.spells.findSpell(cast.spell_id)) |def| {
                switch (def.effect) {
                    .heal => try applyHeal(map_ecs, frame, cast, def),
                    else => log.debug("spell {d} completed without a v1 effect path", .{cast.spell_id}),
                }
            }
        }

        registry.destroy(cast_entity);
    }
}

/// Rolls the heal magnitude and applies it clamped to the target's max
/// health; the raw roll rides the event (the heal log reports it even
/// when overheal drops part of it).
fn applyHeal(map_ecs: *MapEcs, frame: MapEcs.Frame, cast: component.Cast, def: domain.SpellDef) !void {
    const registry = &map_ecs.registry;

    const roll = rollMagnitude(frame.io, def);
    const health = registry.get(component.Health, cast.target);
    const max_health = registry.getConst(component.Stats, cast.target).derived.max_health;
    health.*.current = @min(health.current + roll, max_health);

    try map_ecs.addEvent(.{ .spell_healed = .{
        .caster = cast.caster,
        .target = cast.target,
        .spell_id = cast.spell_id,
        .cast_count = cast.cast_count,
        .amount = roll,
    } });
}

fn rollMagnitude(io: std.Io, def: domain.SpellDef) u32 {
    const span = def.max_effect - def.min_effect + 1;
    if (span <= 1) return def.min_effect;
    var buf: [4]u8 = undefined;
    io.random(&buf);
    return def.min_effect + std.mem.readInt(u32, &buf, .little) % span;
}

/// "18% of base mana" etc.; base mana is the class-agnostic constant.
fn manaCost(def: domain.SpellDef) u32 {
    return domain.character_stats.base_mana * def.mana_cost_pct_base / 100;
}

fn distance(registry: *ecs.Registry, a: ecs.Entity, b: ecs.Entity) f32 {
    const pa = registry.getConst(component.Position, a);
    const pb = registry.getConst(component.Position, b);
    const dx = pa.x - pb.x;
    const dy = pa.y - pb.y;
    const dz = pa.z - pb.z;
    return @sqrt(dx * dx + dy * dy + dz * dz);
}

/// Destroys the caster's live cast, if any, and queues the interruption
/// event. No-op when the caster has no running cast matching
/// `spell_filter` (null matches any).
pub fn interruptCast(
    map_ecs: *MapEcs,
    caster: ecs.Entity,
    spell_filter: ?u32,
    kind: InterruptKind,
) !void {
    const registry = &map_ecs.registry;

    var casts = registry.view(.{component.Cast}, .{});
    var it = casts.entityIterator();
    while (it.next()) |cast_entity| {
        const cast = registry.getConst(component.Cast, cast_entity);
        if (cast.caster != caster) continue;
        if (spell_filter) |spell_id| {
            if (cast.spell_id != spell_id) continue;
        }

        registry.destroy(cast_entity);
        try map_ecs.addEvent(.{ .cast_interrupted = .{
            .caster = caster,
            .spell_id = cast.spell_id,
            .cast_count = cast.cast_count,
            .by_client = kind.by_client,
        } });
        return;
    }
}
