const std = @import("std");
const db = @import("db");
const domain = @import("domain");
const game_data = @import("game_data");
const protocol = @import("protocol");
const pg = @import("pg");
const Session = @import("domain").Session;
const WorldServerConnection = @import("./WorldServerConnection.zig").WorldServerConnection;

const world = protocol.world;
const character_create = game_data.character_create;
const items = game_data.items;
const equipment = game_data.equipment;

pub fn handleDelete(
    alloc: std.mem.Allocator,
    pool: *pg.Pool,
    session: *Session,
    conn: *WorldServerConnection,
    payload: []u8,
) !void {
    const del = world.CharDeleteClient.unmarshal(payload) catch {
        return try conn.sendMessage(alloc, world.CharDeleteServer{ .code = world.CharDeleteServer.failed });
    };

    const result = db.char.delete(pool, session.account_id, session.active_realm.id, del.guid) catch |err| {
        std.log.err("world: character delete failed account={s} realm={s} guid={d}: {}", .{ session.account, session.active_realm.name, del.guid.valueOf(), err });
        return try conn.sendMessage(alloc, world.CharDeleteServer{ .code = world.CharDeleteServer.failed });
    };

    switch (result) {
        .deleted => {
            std.log.info("world: character deleted account={s} realm={s} guid={d}", .{ session.account, session.active_realm.name, del.guid.valueOf() });
            return try conn.sendMessage(alloc, world.CharDeleteServer{ .code = world.CharDeleteServer.success });
        },
        .not_found => try conn.sendMessage(alloc, world.CharDeleteServer{ .code = world.CharDeleteServer.failed }),
    }
}

pub fn handleCreate(
    alloc: std.mem.Allocator,
    pool: *pg.Pool,
    session: *Session,
    conn: *WorldServerConnection,
    payload: []u8,
) !void {
    const create = world.CharCreateClient.unmarshal(payload) catch {
        return try conn.sendMessage(alloc, world.CharCreateServer{ .code = world.CharCreateServer.failed });
    };

    if (validateCharacterName(create.name)) |code| {
        return try conn.sendMessage(alloc, world.CharCreateServer{ .code = code });
    }

    if (create.gender > 1) {
        return try conn.sendMessage(alloc, world.CharCreateServer{ .code = world.CharCreateServer.failed });
    }

    const template = character_create.findTemplate(create.race, create.class) orelse {
        return try conn.sendMessage(alloc, world.CharCreateServer{ .code = world.CharCreateServer.failed });
    };

    var suit: [equipment.default_suit.len]db.char.EquipmentInput = undefined;
    inline for (equipment.default_suit, 0..) |starter, i| {
        suit[i] = .{ .slot = @intFromEnum(starter.slot), .item_entry = starter.item_entry };
    }

    const result = db.char.create(pool, .{
        .account_id = session.account_id,
        .realm_id = session.active_realm.id,
        .current_instance_id = template.instance_id,
        .name = create.name,
        .race_id = create.race,
        .class_id = create.class,
        .gender = create.gender,
        .skin = create.skin,
        .face = create.face,
        .hair_style = create.hair_style,
        .hair_color = create.hair_color,
        .facial_hair = create.facial_hair,
        .outfit_id = create.outfit_id,
        .position_x = template.position_x,
        .position_y = template.position_y,
        .position_z = template.position_z,
        .orientation = template.orientation,
        .equipment = &suit,
    }) catch |err| {
        std.log.err("world: character create failed account={s} realm={s} name={s}: {}", .{ session.account, session.active_realm.name, create.name, err });
        return try conn.sendMessage(alloc, world.CharCreateServer{ .code = world.CharCreateServer.error_ });
    };

    switch (result) {
        .created => |created| {
            std.log.info(
                "world: character created account={s} realm={s} name={s} race={d} class={d} guid={d}",
                .{ session.account, session.active_realm.name, create.name, create.race, create.class, created.guid.valueOf() },
            );
            return try conn.sendMessage(alloc, world.CharCreateServer{ .code = world.CharCreateServer.success });
        },
        .name_in_use => try conn.sendMessage(alloc, world.CharCreateServer{ .code = world.CharCreateServer.name_in_use }),
    }
}

pub fn handleEnum(
    alloc: std.mem.Allocator,
    pool: *pg.Pool,
    session: *Session,
    conn: *WorldServerConnection,
) !void {
    var rows = db.char.fetchForEnum(pool, session.account_id, session.active_realm.id) catch |err| {
        std.log.err("world: character enum failed account={s} realm={s}: {}", .{ session.account, session.active_realm.name, err });
        return err;
    };
    defer rows.deinit();

    var entries: std.ArrayList(world.CharEnumEntry) = .empty;
    defer entries.deinit(alloc);

    while (try rows.next()) |row| {
        const race = row.raceId();
        const class = row.classId();
        const template = character_create.findTemplate(race, class);
        try entries.append(alloc, .{
            .guid = row.guid(),
            .name = row.name(),
            .race = race,
            .class = class,
            .gender = row.gender(),
            .skin = row.skin(),
            .face = row.face(),
            .hair_style = row.hairStyle(),
            .hair_color = row.hairColor(),
            .facial_hair = row.facialHair(),
            .level = row.level(),
            .zone_id = if (template) |t| t.display_zone_id else 0,
            .map_id = row.mapId(),
            .position_x = row.positionX(),
            .position_y = row.positionY(),
            .position_z = row.positionZ(),
        });
    }

    var equip_rows = db.char.fetchEquipmentForEnum(pool, session.account_id, session.active_realm.id) catch |err| {
        std.log.err("world: character equipment enum failed account={s} realm={s}: {}", .{ session.account, session.active_realm.name, err });
        return err;
    };
    defer equip_rows.deinit();

    while (try equip_rows.next()) |equip| {
        const owner = equip.characterGuid().valueOf();
        const slot = equip.slot();
        if (slot >= world.CharEnumServer.visible_item_slots) continue;

        const def = items.findItem(equip.itemEntry()) orelse {
            std.log.debug("world: unknown equipped item entry={d} slot={d}", .{ equip.itemEntry(), slot });
            continue;
        };

        for (entries.items) |*entry| {
            if (entry.guid.valueOf() != owner) continue;
            entry.equipment[slot] = .{
                .display_id = def.display_id,
                .inventory_type = def.inventory_type,
                .enchant_aura = equip.enchantId(),
            };
            break;
        }
    }

    try conn.sendMessage(alloc, world.CharEnumServer{ .characters = entries.items });
}

fn validateCharacterName(name: []const u8) ?u8 {
    if (name.len == 0) return world.CharCreateServer.char_name_no_name;
    if (name.len < 2) return world.CharCreateServer.char_name_too_short;
    if (name.len > 12) return world.CharCreateServer.char_name_too_long;
    if (!std.ascii.isUpper(name[0])) return world.CharCreateServer.char_name_invalid_character;
    for (name[1..]) |byte| {
        if (!std.ascii.isLower(byte)) return world.CharCreateServer.char_name_invalid_character;
    }
    return null;
}

test "character names are ASCII capitalized words" {
    const t = std.testing;

    try t.expect(validateCharacterName("Bob") == null);
    try t.expectEqual(@as(?u8, world.CharCreateServer.char_name_too_short), validateCharacterName("B"));
    try t.expectEqual(@as(?u8, world.CharCreateServer.char_name_too_long), validateCharacterName("Bbbbbbbbbbbbb"));
    try t.expectEqual(@as(?u8, world.CharCreateServer.char_name_invalid_character), validateCharacterName("bob"));
    try t.expectEqual(@as(?u8, world.CharCreateServer.char_name_invalid_character), validateCharacterName("BoB"));
    try t.expectEqual(@as(?u8, world.CharCreateServer.char_name_invalid_character), validateCharacterName("Bób"));
}
