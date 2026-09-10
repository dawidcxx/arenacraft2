//! Folds stats for units whose auras changed and mirrors them to clients.
//! Units without StatsDirty cost nothing, and a fold that lands on the
//! cached value never touches the wire.

const std = @import("std");
const ecs = @import("ecs");
const proto = @import("protocol");

const component = @import("./EcsComponent.zig");
const AuraQuery = @import("./AuraQuery.zig");
const MapEcs = @import("./MapEcs.zig").MapEcs;

pub fn run(map_ecs: *MapEcs, frame: MapEcs.Frame) !void {
    var registry = &map_ecs.registry;
    const alloc = frame.arena_allocator;

    var processed = std.ArrayList(ecs.Entity).initCapacity(alloc, 8) catch unreachable;
    defer processed.deinit(alloc);

    var dirty_view = registry.view(.{component.StatsDirty}, .{});
    var dirty_it = dirty_view.entityIterator();
    while (dirty_it.next()) |unit| {
        const dirty = registry.getConst(component.StatsDirty, unit).mask;

        if (dirty.has(.movement_speed)) {
            if (registry.tryGet(component.MoveSpeed, unit)) |speed| {
                const folded = AuraQuery.foldMovementSpeed(map_ecs, unit);
                if (speed.run != folded) {
                    speed.run = folded;
                    if (registry.tryGetConst(component.Guid, unit)) |guid| {
                        map_ecs.broadcast(
                            .{ unit, .{ .ignore_sender = false } },
                            proto.spell.ForceRunSpeedChangeServer{ .guid = guid.value, .speed = folded },
                        );
                    }
                }
            }
        }

        if (dirty.has(.max_health)) {
            // TODO: land the folded max health on a health component once
            // combat exists
        }

        processed.append(alloc, unit) catch unreachable;
    }

    // Component removal invalidates the view, so it happens after the walk.
    for (processed.items) |unit| registry.remove(component.StatsDirty, unit);
}

// --- tests -------------------------------------------------------------------------

const t = std.testing;
const domain = @import("domain");

const Rig = @import("EcsTestRig.zig").Rig;

const slow_40 = [_]domain.SpellDef.AuraEffect{.{ .movement_speed_mod = .{ .pct = -40 } }};
const plus_health = [_]domain.SpellDef.AuraEffect{.{ .max_health_mod = .{ .amount = 50 } }};

/// One real frame slice: auras admit first, then stats fold — the same
/// order MapEcs.run uses.
fn step(rig: *Rig, dt: u32) !void {
    const frame = rig.frame(dt);
    try @import("./AuraSystem.zig").run(&rig.map_ecs, frame);
    try run(&rig.map_ecs, frame);
    rig.drainEvents();
}

test "dirty movement speed folds, updates the cache and hits the wire once" {
    var rig = try Rig.init();
    defer rig.deinit();

    const speed_op: u32 = @intFromEnum(proto.spell.ForceRunSpeedChangeServer.opcode);

    _ = rig.requestAura(rig.owner, rig.caster, 116, .frost, &slow_40, 5000);
    try step(&rig, 50);

    try t.expectApproxEqAbs(@as(f32, 7.0 * 0.6), rig.map_ecs.registry.getConst(component.MoveSpeed, rig.owner).run, 0.0001);
    try t.expectEqual(@as(usize, 1), rig.broadcastCount(speed_op));
    try t.expect(!rig.map_ecs.registry.has(component.StatsDirty, rig.owner));
}

test "units without dirty stats are never touched" {
    var rig = try Rig.init();
    defer rig.deinit();

    const speed_op: u32 = @intFromEnum(proto.spell.ForceRunSpeedChangeServer.opcode);

    try step(&rig, 50);
    try step(&rig, 50);

    try t.expectEqual(component.BASE_RUN_SPEED, rig.map_ecs.registry.getConst(component.MoveSpeed, rig.owner).run);
    try t.expectEqual(@as(usize, 0), rig.broadcastCount(speed_op));
}

test "a fold that lands on the cached value stays off the wire" {
    var rig = try Rig.init();
    defer rig.deinit();

    const speed_op: u32 = @intFromEnum(proto.spell.ForceRunSpeedChangeServer.opcode);

    _ = rig.requestAura(rig.owner, rig.caster, 116, .frost, &slow_40, 5000);
    try step(&rig, 50);
    try t.expectEqual(@as(usize, 1), rig.broadcastCount(speed_op));

    // Mark dirty again without anything changing: the fold lands on the
    // cached value and the wire stays quiet.
    rig.map_ecs.registry.add(rig.owner, component.StatsDirty{ .mask = domain.SpellDef.Category.Mask.of(.movement_speed) });
    try step(&rig, 50);
    try t.expectEqual(@as(usize, 1), rig.broadcastCount(speed_op));
    try t.expect(!rig.map_ecs.registry.has(component.StatsDirty, rig.owner));
}

test "max health dirty bit clears without a sink" {
    var rig = try Rig.init();
    defer rig.deinit();

    const speed_op: u32 = @intFromEnum(proto.spell.ForceRunSpeedChangeServer.opcode);

    _ = rig.requestAura(rig.owner, rig.caster, 21562, .holy, &plus_health, 30_000);
    try step(&rig, 50);

    try t.expect(!rig.map_ecs.registry.has(component.StatsDirty, rig.owner));
    // The health fold has no wire sink yet, and movement was never dirty.
    try t.expectEqual(@as(usize, 0), rig.broadcastCount(speed_op));
}
