const std = @import("std");
const pg = @import("pg");
const domain = @import("domain");
const util = @import("util.zig");

const ObjectGuid = domain.ObjectGuid;
const Character = domain.Character;

pub const EquipmentInput = struct {
    slot: u8,
    item_entry: u32,
    enchant_id: u32 = 0,
};

pub const CreateInput = struct {
    account_id: u64,
    realm_id: u8,
    current_instance_id: []const u8,
    name: []const u8,
    race_id: u8,
    class_id: u8,
    gender: u8,
    skin: u8,
    face: u8,
    hair_style: u8,
    hair_color: u8,
    facial_hair: u8,
    outfit_id: u8,
    level: u8 = 80,
    position_x: f32,
    position_y: f32,
    position_z: f32,
    orientation: f32,
    equipment: []const EquipmentInput = &.{},
};

pub const CreatedCharacter = struct {
    guid: ObjectGuid,
};

pub const CreateResult = union(enum) {
    created: CreatedCharacter,
    name_in_use,
};

pub fn create(pool: *pg.Pool, input: CreateInput) !CreateResult {
    var conn = try pool.acquire();
    defer pool.release(conn);

    try conn.begin();
    errdefer conn.rollback() catch |err| {
        std.log.warn("db: character create rollback failed: {}", .{err});
    };

    var guid_value: i64 = undefined;
    var id_buf: [36]u8 = undefined;

    {
        var row = conn.row(
            \\INSERT INTO characters (
            \\  account_id, realm_id, current_instance_id,
            \\  name, race_id, class_id, gender,
            \\  skin, face, hair_style, hair_color, facial_hair, outfit_id,
            \\  level, position_x, position_y, position_z, orientation
            \\) VALUES (
            \\  $1::bigint, $2::smallint, $3::uuid,
            \\  $4, $5::smallint, $6::smallint, $7::smallint,
            \\  $8::smallint, $9::smallint, $10::smallint, $11::smallint, $12::smallint, $13::smallint,
            \\  $14::smallint, $15::real, $16::real, $17::real, $18::real
            \\)
            \\ON CONFLICT ON CONSTRAINT characters_realm_name_unique DO NOTHING
            \\RETURNING id::text, guid::int8
        , .{
            input.account_id,
            input.realm_id,
            input.current_instance_id,
            input.name,
            input.race_id,
            input.class_id,
            input.gender,
            input.skin,
            input.face,
            input.hair_style,
            input.hair_color,
            input.facial_hair,
            input.outfit_id,
            input.level,
            input.position_x,
            input.position_y,
            input.position_z,
            input.orientation,
        }) catch |err| {
            util.logPgError("db: character create", conn);
            return err;
        } orelse {
            conn.rollback() catch |err| {
                std.log.warn("db: character create rollback failed: {}", .{err});
            };
            return .name_in_use;
        };
        defer row.deinit() catch |err| {
            std.log.warn("db: create character row deinit failed: {}", .{err});
        };

        const id_text = row.get([]const u8, 0) catch unreachable;
        if (id_text.len != id_buf.len) {
            std.debug.panic("db: unexpected character id length={d}", .{id_text.len});
        }
        @memcpy(&id_buf, id_text);
        guid_value = row.get(i64, 1) catch unreachable;
    }

    for (input.equipment) |item| {
        _ = conn.exec(
            \\INSERT INTO character_equipment (character_id, slot, item_entry, enchant_id)
            \\VALUES ($1::uuid, $2::smallint, $3::int4, $4::int4)
        , .{ id_buf[0..], item.slot, item.item_entry, item.enchant_id }) catch |err| {
            util.logPgError("db: character equipment insert", conn);
            return err;
        };
    }

    try conn.commit();

    return .{ .created = .{ .guid = util.guidFromDb(guid_value) } };
}

pub const DeleteResult = enum {
    deleted,
    not_found,
};

pub fn delete(pool: *pg.Pool, account_id: u64, realm_id: u8, guid: ObjectGuid) !DeleteResult {
    const low = guid.playerLow() orelse return .not_found;

    const affected = try pool.exec(
        \\DELETE FROM characters
        \\WHERE guid = $1::int8 AND account_id = $2::bigint AND realm_id = $3::smallint
    , .{ @as(i64, low), account_id, realm_id });

    if ((affected orelse 0) > 0) return .deleted;
    return .not_found;
}

pub const CharacterRow = struct {
    row: pg.Row,

    pub fn guid(self: *const CharacterRow) ObjectGuid {
        return util.guidFromDb(self.row.get(i64, 0) catch unreachable);
    }

    pub fn name(self: *const CharacterRow) []const u8 {
        return self.row.get([]const u8, 1) catch unreachable;
    }

    pub fn raceId(self: *const CharacterRow) u8 {
        return util.readU8(self.row, 2);
    }

    pub fn classId(self: *const CharacterRow) u8 {
        return util.readU8(self.row, 3);
    }

    pub fn gender(self: *const CharacterRow) u8 {
        return util.readU8(self.row, 4);
    }

    pub fn skin(self: *const CharacterRow) u8 {
        return util.readU8(self.row, 5);
    }

    pub fn face(self: *const CharacterRow) u8 {
        return util.readU8(self.row, 6);
    }

    pub fn hairStyle(self: *const CharacterRow) u8 {
        return util.readU8(self.row, 7);
    }

    pub fn hairColor(self: *const CharacterRow) u8 {
        return util.readU8(self.row, 8);
    }

    pub fn facialHair(self: *const CharacterRow) u8 {
        return util.readU8(self.row, 9);
    }

    pub fn level(self: *const CharacterRow) u8 {
        return util.readU8(self.row, 10);
    }

    pub fn mapId(self: *const CharacterRow) u32 {
        return util.readU32(self.row, 11);
    }

    pub fn positionX(self: *const CharacterRow) f32 {
        return self.row.get(f32, 12) catch unreachable;
    }

    pub fn positionY(self: *const CharacterRow) f32 {
        return self.row.get(f32, 13) catch unreachable;
    }

    pub fn positionZ(self: *const CharacterRow) f32 {
        return self.row.get(f32, 14) catch unreachable;
    }
};

pub const CharacterIterator = struct {
    result: *pg.Result,

    pub fn deinit(self: *CharacterIterator) void {
        self.result.deinit();
    }

    pub fn next(self: *CharacterIterator) !?CharacterRow {
        const row = try self.result.next() orelse return null;
        return CharacterRow{ .row = row };
    }
};

pub fn fetchForEnum(pool: *pg.Pool, account_id: u64, realm_id: u8) !CharacterIterator {
    const result = try pool.query(
        \\SELECT
        \\  c.guid::int8,
        \\  c.name,
        \\  c.race_id::int4,
        \\  c.class_id::int4,
        \\  c.gender::int4,
        \\  c.skin::int4,
        \\  c.face::int4,
        \\  c.hair_style::int4,
        \\  c.hair_color::int4,
        \\  c.facial_hair::int4,
        \\  c.level::int4,
        \\  COALESCE(wi.map_id, 1)::int4,
        \\  c.position_x::real,
        \\  c.position_y::real,
        \\  c.position_z::real
        \\FROM characters c
        \\LEFT JOIN world_instances wi ON wi.id = c.current_instance_id
        \\WHERE c.account_id = $1::bigint AND c.realm_id = $2::smallint
        \\ORDER BY c.created_at ASC, c.guid ASC
    , .{ account_id, realm_id });
    return CharacterIterator{ .result = result };
}

pub const EquipmentRow = struct {
    row: pg.Row,

    pub fn characterGuid(self: *const EquipmentRow) ObjectGuid {
        return util.guidFromDb(self.row.get(i64, 0) catch unreachable);
    }

    pub fn slot(self: *const EquipmentRow) u8 {
        return util.readU8(self.row, 1);
    }

    pub fn itemEntry(self: *const EquipmentRow) u32 {
        return util.readU32(self.row, 2);
    }

    pub fn enchantId(self: *const EquipmentRow) u32 {
        return util.readU32(self.row, 3);
    }
};

pub const EquipmentIterator = struct {
    result: *pg.Result,

    pub fn deinit(self: *EquipmentIterator) void {
        self.result.deinit();
    }

    pub fn next(self: *EquipmentIterator) !?EquipmentRow {
        const row = try self.result.next() orelse return null;
        return EquipmentRow{ .row = row };
    }
};

pub fn fetchEquipmentForEnum(pool: *pg.Pool, account_id: u64, realm_id: u8) !EquipmentIterator {
    const result = try pool.query(
        \\SELECT
        \\  c.guid::int8,
        \\  ce.slot::int4,
        \\  ce.item_entry::int4,
        \\  ce.enchant_id::int4
        \\FROM character_equipment ce
        \\JOIN characters c ON c.id = ce.character_id
        \\WHERE c.account_id = $1::bigint AND c.realm_id = $2::smallint
        \\ORDER BY c.guid ASC, ce.slot ASC
    , .{ account_id, realm_id });
    return EquipmentIterator{ .result = result };
}

pub fn fetchCharacterEquipment(pool: *pg.Pool, account_id: u64, realm_id: u8, character_guid: ObjectGuid) !EquipmentIterator {
    const low = character_guid.playerLow() orelse return error.MissingCharacter;
    const result = try pool.query(
        \\SELECT
        \\  c.guid::int8,
        \\  ce.slot::int4,
        \\  ce.item_entry::int4,
        \\  ce.enchant_id::int4
        \\FROM character_equipment ce
        \\JOIN characters c ON c.id = ce.character_id
        \\WHERE c.account_id = $1::bigint AND c.realm_id = $2::smallint AND c.guid = $3::int8
        \\ORDER BY ce.slot ASC
    , .{ account_id, realm_id, @as(i64, low) });
    return EquipmentIterator{ .result = result };
}

pub const LoginCharacter = struct {
    guid: ObjectGuid,
    name: []const u8,
    map_id: u32,
    position_x: f32,
    position_y: f32,
    position_z: f32,
    orientation: f32,
    instance_id: []const u8,
    race_id: u8,
    class_id: u8,
    gender: u8,
    skin: u8,
    face: u8,
    hair_style: u8,
    hair_color: u8,
    facial_hair: u8,
    level: u8,
};

pub fn fetchCharacter(pool: *pg.Pool, guid: ObjectGuid, account_id: u64, realm_id: u8) !Character {
    const low = guid.playerLow() orelse return error.MissingCharacter;

    var row = (try pool.row(
        \\SELECT
        \\  c.guid::int8,
        \\  c.name,
        \\  c.class_id::int4,
        \\  c.position_x::real,
        \\  c.position_y::real,
        \\  c.position_z::real,
        \\  c.orientation::real,
        \\  c.race_id::int4,
        \\  c.gender::int4,
        \\  c.skin::int4,
        \\  c.face::int4,
        \\  c.hair_style::int4,
        \\  c.hair_color::int4,
        \\  c.facial_hair::int4,
        \\  c.level::int4,
        \\  COALESCE(wi.map_id, 1)::int4
        \\FROM characters c
        \\LEFT JOIN world_instances wi ON wi.id = c.current_instance_id
        \\WHERE c.guid = $1::int8 AND c.account_id = $2::bigint AND c.realm_id = $3::smallint
        \\LIMIT 1
    , .{ @as(i64, low), account_id, realm_id })) orelse return error.MissingCharacter;

    defer row.deinit() catch |err| {
        std.log.warn("db: fetchPlayer row deinit failed: {}", .{err});
    };

    const db_name = row.get([]const u8, 1) catch unreachable;
    if (db_name.len > Character.max_name_len) return error.CharacterNameTooLong;

    var name: [Character.max_name_len + 1]u8 = .{0} ** (Character.max_name_len + 1);
    @memcpy(name[0..db_name.len], db_name);

    return Character{
        .guid = util.guidFromDb(row.get(i64, 0) catch unreachable),
        .name = name,
        .class_id = @enumFromInt(util.readU8(row.row, 2)),
        .movement = .{
            .position = .{
                .x = row.get(f32, 3) catch unreachable,
                .y = row.get(f32, 4) catch unreachable,
                .z = row.get(f32, 5) catch unreachable,
            },
            .orientation = row.get(f32, 6) catch unreachable,
        },
        .race_id = util.readU8(row.row, 7),
        .gender = util.readU8(row.row, 8),
        .skin = util.readU8(row.row, 9),
        .face = util.readU8(row.row, 10),
        .hair_style = util.readU8(row.row, 11),
        .hair_color = util.readU8(row.row, 12),
        .facial_hair = util.readU8(row.row, 13),
        .level = util.readU8(row.row, 14),
        .map_id = @enumFromInt(util.readU32(row.row, 15)),
    };
}

pub fn countForRealmName(pool: *pg.Pool, account_name: []const u8, realm_name: []const u8) !u8 {
    var row = (try pool.row(
        \\SELECT COUNT(*)::int8
        \\FROM characters c
        \\JOIN accounts a ON a.id = c.account_id
        \\JOIN realms r ON r.id = c.realm_id
        \\WHERE a.username = $1 AND r.realmname = $2
    , .{ account_name, realm_name })) orelse return 0;
    defer row.deinit() catch |err| {
        std.log.warn("db: character count row deinit failed: {}", .{err});
    };

    const count = row.get(i64, 0) catch unreachable;
    if (count <= 0) return 0;
    return @intCast(@min(count, @as(i64, std.math.maxInt(u8))));
}
