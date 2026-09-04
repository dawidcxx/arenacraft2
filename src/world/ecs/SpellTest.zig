//! ECS-level tests for the spell pipeline: cast -> SpellCast entity ->
//! hit (damage + aura) -> aura expiry, melee swings, and the failure paths
//! (unknown spell, out of range, duplicate cast).

const std = @import("std");
const ecs = @import("ecs");
const stdx = @import("stdx");
const domain = @import("domain");
const protocol = @import("protocol");

const component = @import("EcsComponent.zig");
const MapEcs = @import("MapEcs.zig").MapEcs;

const io = std.testing.io;
const alloc = std.testing.allocator;

/// Arena handed to ArcRuntime: packet bodies sent into session inboxes are
/// released with the arena at test end instead of tracked one by one.
const TestState = struct {
    var arena_state: std.heap.ArenaAllocator = undefined;
};

fn beginTest() std.mem.Allocator {
    TestState.arena_state = std.heap.ArenaAllocator.init(alloc);
    const arena = TestState.arena_state.allocator();
    stdx.ArcRuntime.setAllocator(arena);
    return arena;
}

/// Local player stub: real Session (so OutboundPacketSystem can deliver
/// packets into its inbox) plus the components spell systems touch.
const PlayerHarness = struct {
    inbox_buf: [64]domain.Session.InboxMsg = undefined,
    session: domain.Session = undefined,
    entity: ecs.Entity = undefined,

    fn add(self: *PlayerHarness, map_ecs: *MapEcs, account_id: u64, guid_low: u32, x: f32) !void {
        self.session = .{
            .account = "tester",
            .account_id = account_id,
            .active_realm = .{ .id = 1, .name = "Test" },
            .inbox = .init(&self.inbox_buf),
        };

        const entity = map_ecs.registry.create();
        map_ecs.registry.add(entity, component.Player{ .session = &self.session });
        map_ecs.registry.add(entity, component.AccountId{ .id = account_id });
        map_ecs.registry.add(entity, component.Guid{ .value = domain.ObjectGuid.player(guid_low) });
        map_ecs.registry.add(entity, component.Position{ .x = x, .y = 0, .z = 0 });
        map_ecs.registry.add(entity, component.Orientation{ .value = 0 });
        map_ecs.registry.add(entity, component.Level{ .value = 1 });
        map_ecs.registry.add(entity, component.Health{ .current = 100 });
        map_ecs.registry.add(entity, component.Sheath{ .state = 0 });
        self.entity = entity;
    }

    fn receive(self: *PlayerHarness) !domain.Session.InboxMsg {
        return self.session.inbox.getOneUncancelable(io);
    }
};

fn frame(clock: *stdx.Clock, time_now: u64, arena: std.mem.Allocator) MapEcs.Frame {
    return .{
        .io = io,
        .dt = 1,
        .time_now = time_now,
        .clock = clock,
        .arena_allocator = arena,
    };
}

fn countComponents(map_ecs: *MapEcs, comptime T: type) usize {
    var view = map_ecs.registry.view(.{T}, .{});
    var it = view.entityIterator();
    var n: usize = 0;
    while (it.next() != null) n += 1;
    return n;
}

fn castFrostbolt(map_ecs: *MapEcs, account_id: u64, target: domain.ObjectGuid) void {
    map_ecs.addInput(.{ .spell_cast = .{ .account_id = account_id, .packet = .{
        .cast_count = 1,
        .spell_id = 116,
        .cast_flags = 0,
        .target_guid = target,
    } } });
}

test "frostbolt casts, damages, slows and the aura expires" {
    const t = std.testing;
    const arena = beginTest();
    defer TestState.arena_state.deinit();
    var clock = stdx.Clock.init(io);

    var map_ecs = try MapEcs.init(alloc);
    defer map_ecs.deinit();

    var caster: PlayerHarness = .{};
    try caster.add(&map_ecs, 1, 1, 0);
    var victim: PlayerHarness = .{};
    try victim.add(&map_ecs, 2, 2, 10);

    castFrostbolt(&map_ecs, 1, domain.ObjectGuid.player(2));
    try map_ecs.run(frame(&clock, 1000, arena));

    // Cast entity exists mid-flight; the victim is untouched.
    try t.expectEqual(@as(usize, 1), countComponents(&map_ecs, component.SpellCast));
    var casts = map_ecs.registry.view(.{component.SpellCast}, .{});
    var cast_it = casts.entityIterator();
    const cast_entity = cast_it.next().?;
    const cast = map_ecs.registry.getConst(component.SpellCast, cast_entity);
    try t.expectEqual(caster.entity, cast.caster);
    try t.expectEqual(victim.entity, cast.target);
    try t.expectEqual(@as(u64, 1000 + 1500), cast.finish_ms);
    try t.expectEqual(@as(u32, 100), map_ecs.registry.getConst(component.Health, victim.entity).current);

    // The caster saw the cast start (0x131).
    const start_msg = try caster.receive();
    try t.expectEqual(@intFromEnum(protocol.world.Opcode.smsg_spell_start), start_msg.send.opcode);

    // Advance past the cast: damage + aura land.
    try map_ecs.run(frame(&clock, 2501, arena));

    try t.expectEqual(@as(usize, 0), countComponents(&map_ecs, component.SpellCast));
    const hp = map_ecs.registry.getConst(component.Health, victim.entity).current;
    try t.expect(hp >= 80 and hp <= 82); // 18..20 frost damage

    try t.expectEqual(@as(usize, 1), countComponents(&map_ecs, component.Aura));
    var auras = map_ecs.registry.view(.{component.Aura}, .{});
    var aura_it = auras.entityIterator();
    const aura = map_ecs.registry.getConst(component.Aura, aura_it.next().?);
    try t.expectEqual(victim.entity, aura.target);
    try t.expectEqual(@as(u32, 116), aura.spell_entry);
    try t.expectEqual(@as(u32, 40), aura.movement_slow_pct);
    try t.expectEqual(@as(u64, 2501 + 5000), aura.expire_ms);

    // Victim's inbox: spell start, spell go, damage log, health values
    // update, aura update, speed change.
    _ = try victim.receive(); // start (broadcast)
    try t.expectEqual(@intFromEnum(protocol.world.Opcode.smsg_spell_go), (try victim.receive()).send.opcode);
    try t.expectEqual(@intFromEnum(protocol.world.Opcode.smsg_spellnonmeleedamagelog), (try victim.receive()).send.opcode);
    try t.expectEqual(@intFromEnum(protocol.world.Opcode.smsg_update_object), (try victim.receive()).send.opcode);
    try t.expectEqual(@intFromEnum(protocol.world.Opcode.smsg_aura_update), (try victim.receive()).send.opcode);
    try t.expectEqual(@intFromEnum(protocol.world.Opcode.smsg_force_run_speed_change), (try victim.receive()).send.opcode);

    // A second frostbolt refreshes the aura instead of stacking.
    castFrostbolt(&map_ecs, 1, domain.ObjectGuid.player(2));
    try map_ecs.run(frame(&clock, 3000, arena)); // start
    try map_ecs.run(frame(&clock, 4501, arena)); // hit
    try t.expectEqual(@as(usize, 1), countComponents(&map_ecs, component.Aura));

    // Expire: aura gone.
    try map_ecs.run(frame(&clock, 9510, arena));
    try t.expectEqual(@as(usize, 0), countComponents(&map_ecs, component.Aura));
}

test "frostbolt out of range fails without starting a cast" {
    const t = std.testing;
    const arena = beginTest();
    defer TestState.arena_state.deinit();
    var clock = stdx.Clock.init(io);

    var map_ecs = try MapEcs.init(alloc);
    defer map_ecs.deinit();

    var caster: PlayerHarness = .{};
    try caster.add(&map_ecs, 1, 1, 0);
    var victim: PlayerHarness = .{};
    try victim.add(&map_ecs, 2, 2, 100);

    castFrostbolt(&map_ecs, 1, domain.ObjectGuid.player(2));
    try map_ecs.run(frame(&clock, 1000, arena));

    try t.expectEqual(@as(usize, 0), countComponents(&map_ecs, component.SpellCast));

    // CastFailedServer: cast_count, spell id, result out_of_range (97).
    const failed = try caster.receive();
    try t.expectEqual(@intFromEnum(protocol.world.Opcode.smsg_cast_failed), failed.send.opcode);
    const body = failed.send.body.get();
    try t.expectEqual(@as(u8, 1), body[0]);
    try t.expectEqual(@as(u32, 116), std.mem.readInt(u32, body[1..5], .little));
    try t.expectEqual(@as(u8, 97), body[5]);
}

test "second cast while casting is rejected" {
    const t = std.testing;
    const arena = beginTest();
    defer TestState.arena_state.deinit();
    var clock = stdx.Clock.init(io);

    var map_ecs = try MapEcs.init(alloc);
    defer map_ecs.deinit();

    var caster: PlayerHarness = .{};
    try caster.add(&map_ecs, 1, 1, 0);
    var victim: PlayerHarness = .{};
    try victim.add(&map_ecs, 2, 2, 5);

    castFrostbolt(&map_ecs, 1, domain.ObjectGuid.player(2));
    castFrostbolt(&map_ecs, 1, domain.ObjectGuid.player(2));
    try map_ecs.run(frame(&clock, 1000, arena));

    try t.expectEqual(@as(usize, 1), countComponents(&map_ecs, component.SpellCast));

    // The first cast broadcast a start; the second was rejected before
    // starting, so the caster only got the spell_in_progress failure.
    _ = try caster.receive(); // start (broadcast)
    const failed = try caster.receive();
    try t.expectEqual(@intFromEnum(protocol.world.Opcode.smsg_cast_failed), failed.send.opcode);
    try t.expectEqual(@as(u8, 105), failed.send.body.get()[5]);
}

test "unknown spell id is rejected as not known" {
    const t = std.testing;
    const arena = beginTest();
    defer TestState.arena_state.deinit();
    var clock = stdx.Clock.init(io);

    var map_ecs = try MapEcs.init(alloc);
    defer map_ecs.deinit();

    var caster: PlayerHarness = .{};
    try caster.add(&map_ecs, 1, 1, 0);

    map_ecs.addInput(.{ .spell_cast = .{ .account_id = 1, .packet = .{
        .cast_count = 7,
        .spell_id = 99999,
        .cast_flags = 0,
        .target_guid = domain.ObjectGuid.empty,
    } } });
    try map_ecs.run(frame(&clock, 1000, arena));

    try t.expectEqual(@as(usize, 0), countComponents(&map_ecs, component.SpellCast));
    const failed = try caster.receive();
    try t.expectEqual(@as(u8, 63), failed.send.body.get()[5]); // not_known
}

test "auto attack swings on cadence and stops on command" {
    const t = std.testing;
    const arena = beginTest();
    defer TestState.arena_state.deinit();
    var clock = stdx.Clock.init(io);

    var map_ecs = try MapEcs.init(alloc);
    defer map_ecs.deinit();

    var attacker: PlayerHarness = .{};
    try attacker.add(&map_ecs, 1, 1, 0);
    var victim: PlayerHarness = .{};
    try victim.add(&map_ecs, 2, 2, 3);

    map_ecs.addInput(.{ .attack_swing = .{ .account_id = 1, .packet = .{
        .target_guid = domain.ObjectGuid.player(2),
    } } });
    try map_ecs.run(frame(&clock, 1000, arena));

    try t.expectEqual(@as(usize, 1), countComponents(&map_ecs, component.Attacking));
    const hp_after_first = map_ecs.registry.getConst(component.Health, victim.entity).current;
    try t.expect(hp_after_first >= 98 and hp_after_first <= 99); // 1..2 damage

    // Not due yet: no second swing.
    try map_ecs.run(frame(&clock, 1500, arena));
    try t.expectEqual(hp_after_first, map_ecs.registry.getConst(component.Health, victim.entity).current);

    // Second swing.
    try map_ecs.run(frame(&clock, 3100, arena));
    const hp_after_second = map_ecs.registry.getConst(component.Health, victim.entity).current;
    try t.expect(hp_after_second < hp_after_first);

    map_ecs.addInput(.{ .attack_stop = .{ .account_id = 1 } });
    try map_ecs.run(frame(&clock, 3200, arena));
    try t.expectEqual(@as(usize, 0), countComponents(&map_ecs, component.Attacking));
}

test "cancel cast destroys the running cast" {
    const t = std.testing;
    const arena = beginTest();
    defer TestState.arena_state.deinit();
    var clock = stdx.Clock.init(io);

    var map_ecs = try MapEcs.init(alloc);
    defer map_ecs.deinit();

    var caster: PlayerHarness = .{};
    try caster.add(&map_ecs, 1, 1, 0);
    var victim: PlayerHarness = .{};
    try victim.add(&map_ecs, 2, 2, 5);

    castFrostbolt(&map_ecs, 1, domain.ObjectGuid.player(2));
    try map_ecs.run(frame(&clock, 1000, arena));
    try t.expectEqual(@as(usize, 1), countComponents(&map_ecs, component.SpellCast));

    // Cancel with a different spell id: no-op.
    map_ecs.addInput(.{ .cancel_cast = .{ .account_id = 1, .packet = .{ .spell_id = 6603 } } });
    try map_ecs.run(frame(&clock, 1100, arena));
    try t.expectEqual(@as(usize, 1), countComponents(&map_ecs, component.SpellCast));

    // Cancel frostbolt: cast entity is gone, the spell never fires and
    // both clients learn the cast stopped (animation clear).
    map_ecs.addInput(.{ .cancel_cast = .{ .account_id = 1, .packet = .{ .spell_id = 116 } } });
    try map_ecs.run(frame(&clock, 1200, arena));
    try t.expectEqual(@as(usize, 0), countComponents(&map_ecs, component.SpellCast));

    // The caster is acknowledged with CAST_FAILED(interrupted), then gets
    // SPELL_FAILURE (0x133) + SPELL_FAILED_OTHER (0x2A6); the victim gets
    // the two broadcasts (after the earlier spell start).
    _ = try caster.receive(); // spell start
    try t.expectEqual(@intFromEnum(protocol.world.Opcode.smsg_cast_failed), (try caster.receive()).send.opcode);
    try t.expectEqual(@intFromEnum(protocol.world.Opcode.smsg_spell_failure), (try caster.receive()).send.opcode);
    try t.expectEqual(@intFromEnum(protocol.world.Opcode.smsg_spell_failed_other), (try caster.receive()).send.opcode);
    _ = try victim.receive(); // spell start
    _ = try victim.receive();
    _ = try victim.receive();

    // The victim's health is untouched by the cancelled cast.
    try t.expectEqual(@as(u32, 100), map_ecs.registry.getConst(component.Health, victim.entity).current);
}

test "displacing movement interrupts the running cast" {
    const t = std.testing;
    const arena = beginTest();
    defer TestState.arena_state.deinit();
    var clock = stdx.Clock.init(io);

    var map_ecs = try MapEcs.init(alloc);
    defer map_ecs.deinit();

    var caster: PlayerHarness = .{};
    try caster.add(&map_ecs, 1, 1, 0);
    var victim: PlayerHarness = .{};
    try victim.add(&map_ecs, 2, 2, 5);

    castFrostbolt(&map_ecs, 1, domain.ObjectGuid.player(2));
    try map_ecs.run(frame(&clock, 1000, arena));
    try t.expectEqual(@as(usize, 1), countComponents(&map_ecs, component.SpellCast));

    // A displacement packet (start forward) cancels the cast.
    map_ecs.addInput(.{ .player_move = .{
        .account_id = 1,
        .packet = .{ .msg_move_start_forward = .{
            .mover = domain.ObjectGuid.player(1),
            .info = .{
            .flags = 0,
            .flags2 = 0,
            .time_ms = 0,
            .x = 0.1,
            .y = 0,
            .z = 0,
            .orientation = 0,
            .fall_time_ms = 0,
        } } },
    } });
    try map_ecs.run(frame(&clock, 1100, arena));
    try t.expectEqual(@as(usize, 0), countComponents(&map_ecs, component.SpellCast));

    // The interrupt broadcasts SPELL_FAILURE + SPELL_FAILED_OTHER so other
    // clients drop the caster's cast animation.
    _ = try victim.receive(); // spell start
    try t.expectEqual(@intFromEnum(protocol.world.Opcode.smsg_spell_failure), (try victim.receive()).send.opcode);
    try t.expectEqual(@intFromEnum(protocol.world.Opcode.smsg_spell_failed_other), (try victim.receive()).send.opcode);

    // A turn does not cancel anything (nothing left to cancel; just make
    // sure it does not crash or resurrect casts).
    try map_ecs.run(frame(&clock, 1200, arena));
    try t.expectEqual(@as(usize, 0), countComponents(&map_ecs, component.SpellCast));
}

test "frostbolt kills low-health targets and death cleans up combat" {
    const t = std.testing;
    const arena = beginTest();
    defer TestState.arena_state.deinit();
    var clock = stdx.Clock.init(io);

    var map_ecs = try MapEcs.init(alloc);
    defer map_ecs.deinit();

    var caster: PlayerHarness = .{};
    try caster.add(&map_ecs, 1, 1, 0);
    var victim: PlayerHarness = .{};
    try victim.add(&map_ecs, 2, 2, 5);
    // One frostbolt (18..20) is lethal at this health.
    map_ecs.registry.get(component.Health, victim.entity).*.current = 15;

    // The victim is auto attacking the caster when the killing blow lands.
    map_ecs.registry.add(victim.entity, component.Attacking{
        .target = caster.entity,
        .next_swing_ms = 9999,
    });

    castFrostbolt(&map_ecs, 1, domain.ObjectGuid.player(2));
    try map_ecs.run(frame(&clock, 1000, arena)); // start
    try map_ecs.run(frame(&clock, 2501, arena)); // hit

    // Dead: health zero, combat cleaned up, slow aura not applied.
    try t.expectEqual(@as(u32, 0), map_ecs.registry.getConst(component.Health, victim.entity).current);
    try t.expectEqual(@as(usize, 0), countComponents(&map_ecs, component.Attacking));
    try t.expectEqual(@as(usize, 0), countComponents(&map_ecs, component.Aura));
    try t.expectEqual(@as(usize, 0), countComponents(&map_ecs, component.SpellCast));

    // Victim inbox: start, go, damage log, killing-blow health update,
    // death values update, attack stop (it was attacking the caster).
    // The victim was not casting, so no interrupt packets fire.
    _ = try victim.receive(); // start
    try t.expectEqual(@intFromEnum(protocol.world.Opcode.smsg_spell_go), (try victim.receive()).send.opcode);
    try t.expectEqual(@intFromEnum(protocol.world.Opcode.smsg_spellnonmeleedamagelog), (try victim.receive()).send.opcode);
    try t.expectEqual(@intFromEnum(protocol.world.Opcode.smsg_update_object), (try victim.receive()).send.opcode); // killing blow health
    try t.expectEqual(@intFromEnum(protocol.world.Opcode.smsg_update_object), (try victim.receive()).send.opcode); // death (health+power 0)
    try t.expectEqual(@intFromEnum(protocol.world.Opcode.smsg_attackstop), (try victim.receive()).send.opcode);

    // The victim was attacking: its attack stop broadcast reaches the
    // caster too (after the caster's own copies of the broadcast stream).
    _ = try caster.receive(); // start
    _ = try caster.receive(); // go
    _ = try caster.receive(); // nonmelee
    _ = try caster.receive(); // health update
    _ = try caster.receive(); // death update
    try t.expectEqual(@intFromEnum(protocol.world.Opcode.smsg_attackstop), (try caster.receive()).send.opcode);

    // A dead target cannot be cast on.
    castFrostbolt(&map_ecs, 1, domain.ObjectGuid.player(2));
    try map_ecs.run(frame(&clock, 2600, arena));
    const failed = try caster.receive();
    try t.expectEqual(@intFromEnum(protocol.world.Opcode.smsg_cast_failed), failed.send.opcode);
    try t.expectEqual(@as(u8, 109), failed.send.body.get()[5]); // targets_dead
}

test "melee swings stop when the target dies" {
    const t = std.testing;
    const arena = beginTest();
    defer TestState.arena_state.deinit();
    var clock = stdx.Clock.init(io);

    var map_ecs = try MapEcs.init(alloc);
    defer map_ecs.deinit();

    var attacker: PlayerHarness = .{};
    try attacker.add(&map_ecs, 1, 1, 0);
    var victim: PlayerHarness = .{};
    try victim.add(&map_ecs, 2, 2, 3);
    map_ecs.registry.get(component.Health, victim.entity).*.current = 1; // any swing kills

    map_ecs.addInput(.{ .attack_swing = .{ .account_id = 1, .packet = .{
        .target_guid = domain.ObjectGuid.player(2),
    } } });
    try map_ecs.run(frame(&clock, 1000, arena));

    try t.expectEqual(@as(u32, 0), map_ecs.registry.getConst(component.Health, victim.entity).current);
    try t.expectEqual(@as(usize, 0), countComponents(&map_ecs, component.Attacking));

    // The attacker's client got the attack stop; further swings on the
    // corpse are rejected with another attack stop.
    map_ecs.addInput(.{ .attack_swing = .{ .account_id = 1, .packet = .{
        .target_guid = domain.ObjectGuid.player(2),
    } } });
    try map_ecs.run(frame(&clock, 1100, arena));
    try t.expectEqual(@as(usize, 0), countComponents(&map_ecs, component.Attacking));
}

test "set sheathed updates the state and broadcasts bytes_2" {
    const t = std.testing;
    const arena = beginTest();
    defer TestState.arena_state.deinit();
    var clock = stdx.Clock.init(io);

    var map_ecs = try MapEcs.init(alloc);
    defer map_ecs.deinit();

    var player: PlayerHarness = .{};
    try player.add(&map_ecs, 1, 1, 0);

    map_ecs.addInput(.{ .set_sheathed = .{ .account_id = 1, .packet = .{ .sheath_state = 1 } } });
    try map_ecs.run(frame(&clock, 1000, arena));

    try t.expectEqual(@as(u8, 1), map_ecs.registry.getConst(component.Sheath, player.entity).state);
    // The bytes_2 values update reaches the other clients.
    const update = try player.receive();
    try t.expectEqual(@intFromEnum(protocol.world.Opcode.smsg_update_object), update.send.opcode);
    // body: block count 1, VALUES, packed guid, 1 mask block, bit 122 set,
    // value = pvp|ffa|sheath.
    const body = update.send.body.get();
    try t.expectEqual(@as(u8, 0), body[4]); // update type values
    try t.expectEqual(@as(u32, 0x501), std.mem.readInt(u32, body[body.len - 4 ..][0..4], .little));
}

test "aura is dropped when its target despawns" {
    const t = std.testing;
    const arena = beginTest();
    defer TestState.arena_state.deinit();
    var clock = stdx.Clock.init(io);

    var map_ecs = try MapEcs.init(alloc);
    defer map_ecs.deinit();

    var caster: PlayerHarness = .{};
    try caster.add(&map_ecs, 1, 1, 0);
    var victim: PlayerHarness = .{};
    try victim.add(&map_ecs, 2, 2, 5);

    castFrostbolt(&map_ecs, 1, domain.ObjectGuid.player(2));
    try map_ecs.run(frame(&clock, 1000, arena));
    try map_ecs.run(frame(&clock, 2501, arena));
    try t.expectEqual(@as(usize, 1), countComponents(&map_ecs, component.Aura));

    // Victim leaves the map.
    map_ecs.addInput(.{ .player_leave = .{ .account_id = 2 } });
    try map_ecs.run(frame(&clock, 2600, arena));

    try t.expectEqual(@as(usize, 0), countComponents(&map_ecs, component.Aura));
}
