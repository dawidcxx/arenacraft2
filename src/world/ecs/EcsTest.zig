//! End-to-end tests for the map ECS pipeline:
//! join -> introductions, move -> transform + rebroadcast, leave -> despawn.

const std = @import("std");
const ecs = @import("ecs");
const stdx = @import("stdx");
const domain = @import("domain");
const protocol = @import("protocol");

const component = @import("EcsComponent.zig");
const MapEcs = @import("MapEcs.zig").MapEcs;

const ArcRuntime = stdx.ArcRuntime;
const Session = domain.Session;
const Player = domain.Player;

const t = std.testing;

fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn run(map_ecs: *MapEcs) !void {
    var clock = stdx.Clock.init(testIo());
    try map_ecs.run(.{ .io = testIo(), .dt = 16, .time_now = 1000, .clock = &clock, .arena_allocator = t.allocator });
}

fn drainClientInit(session: *Session) void {
    for (0..10) |_| {
        var msg = receive(session);
        msg.body.release();
    }
}

fn makeSession(id: u64, name: []const u8, buf: []Session.InboxMsg) Session {
    return .{
        .account = name,
        .account_id = id,
        .active_realm = .{ .id = 1, .name = "test" },
        .inbox = .init(buf),
    };
}

fn makePlayer(account_id: u64, guid_low: u32, session: *Session) Player {
    return .{
        .account_id = account_id,
        .character = .{
            .guid = domain.ObjectGuid.player(guid_low),
            .map_id = .eastern_kingdoms,
            .class_id = .warrior,
            .race_id = 1,
            .gender = 0,
            .skin = 0,
            .face = 0,
            .hair_style = 0,
            .hair_color = 0,
            .facial_hair = 0,
            .level = 80,
            .movement = .{
                .position = .{ .x = 1, .y = 2, .z = 3 },
                .orientation = 0.5,
            },
        },
        .session = session,
        .active_map_reference = null,
    };
}

fn receive(session: *Session) Session.SendPacket {
    const msg = session.inbox.getOneUncancelable(testIo()) catch unreachable;
    return switch (msg) {
        .send => |send| send,
        else => unreachable,
    };
}

test "join splits a player into components and introduces to veterans" {
    ArcRuntime.setAllocator(t.allocator);

    var sesh_bufs: [2][16]Session.InboxMsg = undefined;
    var alice_session = makeSession(1, "alice", &sesh_bufs[0]);
    var bob_session = makeSession(2, "bob", &sesh_bufs[1]);
    var alice = makePlayer(1, 11, &alice_session);
    var bob = makePlayer(2, 22, &bob_session);

    var map_ecs = try MapEcs.init(t.allocator);
    defer map_ecs.deinit();

    // First join: entity materializes from split components; the newcomer
    // receives its own create_object2 block (self-introduction).
    map_ecs.addInput(.{ .player_join = .{ .player = &alice } });
    try run(&map_ecs);

    const alice_entity = map_ecs.findPlayer(1) orelse return error.PlayerEntityMissing;
    try t.expectEqual(@as(f32, 1), map_ecs.registry.getConst(component.Position, alice_entity).x);
    try t.expectEqual(@as(u8, 80), map_ecs.registry.getConst(component.Level, alice_entity).value);
    try t.expectEqual(domain.ClassId.warrior, map_ecs.registry.getConst(component.Appearance, alice_entity).class_id);

    var alice_first_intro = receive(&alice_session);
    defer alice_first_intro.body.release();
    try t.expectEqual(protocol.world.Opcode.smsg_update_object.value(), alice_first_intro.opcode);
    drainClientInit(&alice_session);

    // Second join: newcomer receives one packet with its own create_object2
    // plus every veteran's create block; veterans get the shared newcomer
    // block.
    map_ecs.addInput(.{ .player_join = .{ .player = &bob } });
    try run(&map_ecs);

    var bob_intro = receive(&bob_session);
    defer bob_intro.body.release();
    try t.expectEqual(protocol.world.Opcode.smsg_update_object.value(), bob_intro.opcode);
    drainClientInit(&bob_session);

    // Alice's first queued message is her own first-join create block; the
    // shared bob block follows it.
    var alice_intro = receive(&alice_session);
    defer alice_intro.body.release();
    try t.expectEqual(protocol.world.Opcode.smsg_update_object.value(), alice_intro.opcode);

    // Duplicate join of the same account replaces the stale entity and
    // re-runs the introduction exchange.
    const stale_bob_entity = map_ecs.findPlayer(2).?;
    map_ecs.addInput(.{ .player_join = .{ .player = &bob } });
    try run(&map_ecs);
    try t.expect(map_ecs.findPlayer(2) != null);
    try t.expect(!map_ecs.registry.valid(stale_bob_entity));

    var dup_bob_intro = receive(&bob_session);
    defer dup_bob_intro.body.release();
    try t.expectEqual(protocol.world.Opcode.smsg_update_object.value(), dup_bob_intro.opcode);
    drainClientInit(&bob_session);
    var dup_alice_intro = receive(&alice_session);
    defer dup_alice_intro.body.release();
    try t.expectEqual(protocol.world.Opcode.smsg_update_object.value(), dup_alice_intro.opcode);
}

test "movement applies transform and rebroadcasts to other players" {
    ArcRuntime.setAllocator(t.allocator);

    var sesh_bufs: [2][16]Session.InboxMsg = undefined;
    var alice_session = makeSession(1, "alice", &sesh_bufs[0]);
    var bob_session = makeSession(2, "bob", &sesh_bufs[1]);
    var alice = makePlayer(1, 11, &alice_session);
    var bob = makePlayer(2, 22, &bob_session);

    var map_ecs = try MapEcs.init(t.allocator);
    defer map_ecs.deinit();

    map_ecs.addInput(.{ .player_join = .{ .player = &alice } });
    map_ecs.addInput(.{ .player_join = .{ .player = &bob } });
    try run(&map_ecs);

    // Drain the introduction traffic. Both joins apply in one tick:
    // targeted deliveries first, then broadcasts, so bob holds [his
    // create_object2 + alice's create block, alice's shared block] and
    // alice holds [her own create block, bob's shared block].
    var bob_intro_a = receive(&bob_session);
    defer bob_intro_a.body.release();
    var bob_intro_b = receive(&bob_session);
    defer bob_intro_b.body.release();
    var alice_intro_a = receive(&alice_session);
    defer alice_intro_a.body.release();
    var alice_intro_b = receive(&alice_session);
    defer alice_intro_b.body.release();
    drainClientInit(&bob_session);
    drainClientInit(&alice_session);

    map_ecs.addInput(.{ .player_move = .{
        .account_id = 1,
        .packet = .{ .msg_move_heartbeat = .{
            .mover = domain.ObjectGuid.player(11),
            .info = .{
                .flags = 0,
                .flags2 = 0,
                .time_ms = 5,
                .x = 7,
                .y = 8,
                .z = 9,
                .orientation = 1.5,
                .fall_time_ms = 0,
            },
        } },
    } });
    try run(&map_ecs);

    // The mover's tracked transform follows the packet.
    const mover_entity = map_ecs.findPlayer(1).?;
    try t.expectEqual(@as(f32, 7), map_ecs.registry.getConst(component.Position, mover_entity).x);
    try t.expectEqual(@as(f32, 1.5), map_ecs.registry.getConst(component.Orientation, mover_entity).value);

    // Everyone but the mover receives the raw movement block.
    var fwd_move = receive(&bob_session);
    defer fwd_move.body.release();
    try t.expectEqual(@as(u32, @intFromEnum(protocol.movement.MovementOpCode.msg_move_heartbeat)), fwd_move.opcode);
}

test "local chat broadcasts to every player including sender" {
    ArcRuntime.setAllocator(t.allocator);

    var sesh_bufs: [2][16]Session.InboxMsg = undefined;
    var alice_session = makeSession(1, "alice", &sesh_bufs[0]);
    var bob_session = makeSession(2, "bob", &sesh_bufs[1]);
    var alice = makePlayer(1, 11, &alice_session);
    var bob = makePlayer(2, 22, &bob_session);

    var map_ecs = try MapEcs.init(t.allocator);
    defer map_ecs.deinit();

    map_ecs.addInput(.{ .player_join = .{ .player = &alice } });
    map_ecs.addInput(.{ .player_join = .{ .player = &bob } });
    try run(&map_ecs);

    var bob_intro_a = receive(&bob_session);
    defer bob_intro_a.body.release();
    var bob_intro_b = receive(&bob_session);
    defer bob_intro_b.body.release();
    var alice_intro_a = receive(&alice_session);
    defer alice_intro_a.body.release();
    var alice_intro_b = receive(&alice_session);
    defer alice_intro_b.body.release();
    drainClientInit(&bob_session);
    drainClientInit(&alice_session);

    map_ecs.addInput(.{ .local_chat = .{
        .account_id = 1,
        .packet = try protocol.chat.MessageChatClient.unmarshal(&.{
            0x01, 0,   0,   0,
            0,    0,   0,   0,
            'h',  'e', 'l', 'l',
            'o',  0,
        }),
    } });
    try run(&map_ecs);

    var alice_chat = receive(&alice_session);
    defer alice_chat.body.release();
    var bob_chat = receive(&bob_session);
    defer bob_chat.body.release();
    try t.expectEqual(protocol.world.Opcode.smsg_messagechat.value(), alice_chat.opcode);
    try t.expectEqualSlices(u8, alice_chat.body.get(), bob_chat.body.get());
    try t.expectEqual(@as(u32, 7), std.mem.readInt(u32, alice_chat.body.get()[1..5], .little));
    try t.expectEqual(domain.ObjectGuid.player(11).valueOf(), std.mem.readInt(u64, alice_chat.body.get()[5..13], .little));
    try t.expectEqual(@as(u64, 0), std.mem.readInt(u64, alice_chat.body.get()[17..25], .little));
}

test "leave despawns the entity and broadcasts destroy" {
    ArcRuntime.setAllocator(t.allocator);

    var sesh_bufs: [2][16]Session.InboxMsg = undefined;
    var alice_session = makeSession(1, "alice", &sesh_bufs[0]);
    var bob_session = makeSession(2, "bob", &sesh_bufs[1]);
    var alice = makePlayer(1, 11, &alice_session);
    var bob = makePlayer(2, 22, &bob_session);

    var map_ecs = try MapEcs.init(t.allocator);
    defer map_ecs.deinit();

    map_ecs.addInput(.{ .player_join = .{ .player = &alice } });
    map_ecs.addInput(.{ .player_join = .{ .player = &bob } });
    try run(&map_ecs);

    // Drain the introduction traffic. Both joins apply in one tick:
    // targeted first, then broadcasts, so alice holds [her own create
    // block, bob's shared block] and bob holds [his create_object2 +
    // alice's create block, alice's shared block].
    var bob_intro_a = receive(&bob_session);
    defer bob_intro_a.body.release();
    var bob_intro_b = receive(&bob_session);
    defer bob_intro_b.body.release();
    var alice_intro_a = receive(&alice_session);
    defer alice_intro_a.body.release();
    var alice_intro_b = receive(&alice_session);
    defer alice_intro_b.body.release();
    drainClientInit(&bob_session);
    drainClientInit(&alice_session);

    map_ecs.addInput(.{ .player_leave = .{ .account_id = 2 } });
    try run(&map_ecs);

    try t.expect(map_ecs.findPlayer(2) == null);
    try t.expect(map_ecs.findPlayer(1) != null);

    // Alice receives SMSG_DESTROY_OBJECT for bob (packed guid + death flag).
    var destroy_msg = receive(&alice_session);
    defer destroy_msg.body.release();
    try t.expectEqual(protocol.world.Opcode.smsg_destroy_object.value(), destroy_msg.opcode);
    try t.expectEqualSlices(u8, &.{ 0x01, 0x16, 0 }, destroy_msg.body.get());
}
