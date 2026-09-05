//! Wire emission for the cast pipeline. Drains the cast events into the
//! spell packets plus the health/power VALUES patches that keep client
//! bars in sync: SpellStart on cast start, CastFailed on rejection, the
//! SpellFailure/SpellFailedOther pair (plus CastFailed for client
//! cancels) on interruption, and SpellGo + SpellHealLog on a completed
//! heal. Reading current component state at drain time keeps the events
//! free of duplicated values.

const std = @import("std");
const ecs = @import("ecs");
const domain = @import("domain");
const protocol = @import("protocol");

const component = @import("EcsComponent.zig");
const EcsEventType = @import("EcsInput.zig").EcsEventType;
const MapEcs = @import("MapEcs.zig").MapEcs;

const log = std.log.scoped(.spell_packets_system);

pub fn run(map_ecs: *MapEcs, frame: MapEcs.Frame) !void {
    for (map_ecs.events.get(EcsEventType.cast_started).items) |event| {
        try sendCastStarted(map_ecs, frame, event.cast_started);
    }

    for (map_ecs.events.get(EcsEventType.cast_failed).items) |event| {
        const failed = event.cast_failed;
        try map_ecs.sendTo(failed.caster, protocol.spell.CastFailedServer{
            .cast_count = failed.cast_count,
            .spell_id = failed.spell_id,
            .result = failed.reason,
        });
    }

    for (map_ecs.events.get(EcsEventType.cast_interrupted).items) |event| {
        try sendCastInterrupted(map_ecs, event.cast_interrupted);
    }

    for (map_ecs.events.get(EcsEventType.spell_healed).items) |event| {
        try sendHealed(map_ecs, frame, event.spell_healed);
    }
}

fn sendCastStarted(map_ecs: *MapEcs, frame: MapEcs.Frame, started: anytype) !void {
    const registry = &map_ecs.registry;

    try map_ecs.broadcast(.{ started.caster, .{ .ignore_sender = false } }, protocol.spell.SpellStartServer{
        .caster_guid = guidOf(registry, started.caster),
        .cast_count = started.cast_count,
        .spell_id = started.spell_id,
        .delay_ms = started.delay_ms,
        .target_guid = guidOf(registry, started.target),
    });

    // Mana was spent when the cast started; sync the caster's power bar.
    try sendPowerPatch(map_ecs, frame, started.caster);
}

fn sendCastInterrupted(map_ecs: *MapEcs, interrupted: anytype) !void {
    const registry = &map_ecs.registry;
    const caster_guid = guidOf(registry, interrupted.caster);

    // The pair clears the cast animation on every client; without it a
    // stationary interrupted caster stays mid-cast forever (it emits no
    // movement packets that could reset the animation).
    try map_ecs.broadcast(.{ interrupted.caster, .{ .ignore_sender = false } }, protocol.spell.SpellFailureServer{
        .caster_guid = caster_guid,
        .cast_count = interrupted.cast_count,
        .spell_id = interrupted.spell_id,
        .result = .interrupted,
    });
    try map_ecs.broadcast(.{ interrupted.caster, .{ .ignore_sender = false } }, protocol.spell.SpellFailedOtherServer{
        .caster_guid = caster_guid,
        .cast_count = interrupted.cast_count,
        .spell_id = interrupted.spell_id,
        .result = .interrupted,
    });

    // The client that cancelled already dropped its own cast bar; the
    // failure packet mirrors the reference core's cancel path.
    if (interrupted.by_client) {
        try map_ecs.sendTo(interrupted.caster, protocol.spell.CastFailedServer{
            .cast_count = interrupted.cast_count,
            .spell_id = interrupted.spell_id,
            .result = .interrupted,
        });
    }
}

fn sendHealed(map_ecs: *MapEcs, frame: MapEcs.Frame, healed: anytype) !void {
    const registry = &map_ecs.registry;
    const aa = frame.arena_allocator;

    const target_guid = guidOf(registry, healed.target);
    const target_guids = [_]domain.ObjectGuid{target_guid};

    try map_ecs.broadcast(.{ healed.caster, .{ .ignore_sender = false } }, protocol.spell.SpellGoServer{
        .caster_guid = guidOf(registry, healed.caster),
        .cast_count = healed.cast_count,
        .spell_id = healed.spell_id,
        .timestamp_ms = @truncate(frame.time_now),
        .hit_guids = &target_guids,
        .target_guid = target_guid,
    });
    try map_ecs.broadcast(.{ healed.caster, .{ .ignore_sender = false } }, protocol.spell.SpellHealLogServer{
        .target_guid = target_guid,
        .healer_guid = guidOf(registry, healed.caster),
        .spell_id = healed.spell_id,
        .heal_amount = healed.amount,
    });

    // Sync the healed target's health bar everywhere.
    var patch = try protocol.object.UpdateObject.init(aa);
    defer patch.deinit(aa);
    var fields = protocol.object.Fields{};
    fields.set(protocol.object.UnitField.health, registry.getConst(component.Health, healed.target).current);
    try patch.add(aa, .{ .values = .{ .guid = target_guid, .fields = fields } });
    try map_ecs.broadcast(.{ healed.target, .{ .ignore_sender = false } }, patch);
}

fn sendPowerPatch(map_ecs: *MapEcs, frame: MapEcs.Frame, caster: ecs.Entity) !void {
    const registry = &map_ecs.registry;
    const aa = frame.arena_allocator;

    const power_type = registry.getConst(component.Appearance, caster).class_id.powerTypeId().valueOf();

    var patch = try protocol.object.UpdateObject.init(aa);
    defer patch.deinit(aa);
    var fields = protocol.object.Fields{};
    fields.set(protocol.object.UnitField.power(power_type), registry.getConst(component.Power, caster).current);
    try patch.add(aa, .{ .values = .{ .guid = guidOf(registry, caster), .fields = fields } });
    try map_ecs.broadcast(.{ caster, .{ .ignore_sender = false } }, patch);
}

fn guidOf(registry: *ecs.Registry, entity: ecs.Entity) domain.ObjectGuid {
    return registry.getConst(component.Guid, entity).value;
}
