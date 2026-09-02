const std = @import("std");
const db = @import("db");
const domain = @import("domain");
const protocol = @import("protocol");
const world = @import("world");
const pg = @import("pg");
const stdx = @import("stdx");
const Session = @import("domain").Session;
const WorldServerConnection = @import("./WorldServerConnection.zig").WorldServerConnection;

const placeholder_map = domain.MapId.eastern_kingdoms;
const initial_position = domain.Movement.Position{ .x = 48.94, .y = 40.16, .z = 60 };
const initial_orientation: f32 = 0;

pub fn handlePlayerLogin(
    alloc: std.mem.Allocator,
    io: std.Io,
    pool: *pg.Pool,
    session: *Session,
    conn: *WorldServerConnection,
    payload: []u8,
    world_sim: *world.WorldSimulation,
    clock: *stdx.Clock,
) !*domain.Player {
    const login_packet = protocol.world.PlayerLoginClient.unmarshal(payload) catch {
        return error.InvalidPacket;
    };
    const character_guid = login_packet.guid;

    var character = try db.char.fetchCharacter(pool, character_guid, session.account_id, session.active_realm.id);
    character.map_id = placeholder_map;
    character.movement.position = initial_position;
    character.movement.orientation = initial_orientation;

    {
        var rows = try db.char.fetchCharacterEquipment(pool, session.account_id, session.active_realm.id, character_guid);
        defer rows.deinit();
        while (try rows.next()) |equip| {
            const slot = equip.slot();
            character.visible_items[slot] = equip.itemEntry();
        }
    }

    try world_sim.connectPlayer(io, .{
        .player = .{
            .character = character,
            .session = session,
            .account_id = session.account_id,
            .active_map_reference = null,
        },
    });

    try sendLoginPrelude(alloc, conn, character, clock);

    const player = try world_sim.joinMap(io, .{
        .map_id = placeholder_map,
        .account_id = session.account_id,
    });

    std.log.info("player guid={d} logged in (account={s} map={})", .{
        character_guid.valueOf(), session.account, character.map_id,
    });

    return player;
}

inline fn sendLoginPrelude(
    alloc: std.mem.Allocator,
    conn: *WorldServerConnection,
    character: domain.Character,
    clock: *stdx.Clock,
) !void {
    try conn.sendMessage(alloc, protocol.world.LoginVerifyWorldServer{
        .map_id = placeholder_map.valueOf(),
        .position_x = character.movement.position.x,
        .position_y = character.movement.position.y,
        .position_z = character.movement.position.z,
        .orientation = character.movement.orientation,
    });
    try conn.sendMessage(alloc, protocol.world.AccountDataTimesServer{
        .unix_time = @intCast(clock.unixSeconds()),
        .mask = protocol.world.AccountDataTimesServer.per_character_cache_mask,
    });
}
