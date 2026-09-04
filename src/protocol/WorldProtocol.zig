const std = @import("std");
const domain = @import("domain");
const game_data = @import("game_data");
const ProtocolError = @import("./ProtocolError.zig").ProtocolErrorSet;
const utils = @import("./ProtocolUtils.zig");
const world_auth = @import("./WorldAuthCrypt.zig");
const update_object = @import("./UpdateObject.zig");

const ObjectGuid = domain.ObjectGuid;

pub const Opcode = enum(u32) {
    cmsg_char_create = 0x036,
    cmsg_char_enum = 0x037,
    cmsg_char_delete = 0x038,
    cmsg_name_query = 0x050,
    smsg_name_query_response = 0x051,
    cmsg_item_query_single = 0x056,
    smsg_item_query_single_response = 0x058,
    cmsg_messagechat = 0x095,
    smsg_messagechat = 0x096,
    smsg_char_create = 0x03A,
    smsg_char_enum = 0x03B,
    smsg_char_delete = 0x03C,
    cmsg_player_login = 0x03D,
    smsg_login_settimespeed = 0x042,
    smsg_update_object = 0x0A9,
    smsg_destroy_object = 0x0AA,
    msg_move_start_forward = 0x0B5,
    msg_move_start_backward = 0x0B6,
    msg_move_stop = 0x0B7,
    msg_move_start_strafe_left = 0x0B8,
    msg_move_start_strafe_right = 0x0B9,
    msg_move_stop_strafe = 0x0BA,
    msg_move_jump = 0x0BB,
    msg_move_start_turn_left = 0x0BC,
    msg_move_start_turn_right = 0x0BD,
    msg_move_stop_turn = 0x0BE,
    msg_move_start_pitch_up = 0x0BF,
    msg_move_start_pitch_down = 0x0C0,
    msg_move_stop_pitch = 0x0C1,
    msg_move_set_run_mode = 0x0C2,
    msg_move_set_walk_mode = 0x0C3,
    msg_move_fall_land = 0x0C9,
    msg_move_start_swim = 0x0CA,
    msg_move_stop_swim = 0x0CB,
    msg_move_set_facing = 0x0DA,
    msg_move_set_pitch = 0x0DB,
    msg_move_worldport_ack = 0x0DC,
    msg_move_heartbeat = 0x0EE,
    smsg_tutorial_flags = 0x0FD,
    smsg_initialize_factions = 0x122,
    smsg_action_buttons = 0x129,
    smsg_initial_spells = 0x12A,
    smsg_learned_spell = 0x12B,
    // Spell casting / melee combat.
    smsg_force_run_speed_change = 0x0E2,
    cmsg_force_run_speed_change_ack = 0x0E3,
    cmsg_cast_spell = 0x12E,
    cmsg_cancel_cast = 0x12F,
    smsg_cast_failed = 0x130,
    smsg_spell_start = 0x131,
    smsg_spell_go = 0x132,
    smsg_spell_failure = 0x133,
    smsg_spell_failed_other = 0x2A6,
    smsg_spellnonmeleedamagelog = 0x250,
    smsg_aura_update = 0x496,
    cmsg_attackswing = 0x141,
    cmsg_attackstop = 0x142,
    smsg_attackstart = 0x143,
    smsg_attackstop = 0x144,
    smsg_attackerstateupdate = 0x14A,
    cmsg_set_sheathed = 0x1E0,
    // Client chatter with no server behavior yet; named so dispatch can
    // swallow them by opcode without the unhandled-opcode warning.
    cmsg_join_channel = 0x097,
    cmsg_cancel_trade = 0x11C,
    cmsg_set_selection = 0x13D,
    cmsg_played_time = 0x1CC,
    cmsg_query_time = 0x1CE,
    cmsg_zoneupdate = 0x1F4,
    cmsg_gmticket_getticket = 0x211,
    cmsg_battlefield_list = 0x23C,
    cmsg_set_active_mover = 0x26A,
    msg_query_next_mail_time = 0x284,
    cmsg_lfg_get_status = 0x296,
    cmsg_set_actionbar_toggles = 0x2BF,
    cmsg_request_raid_info = 0x2CD,
    cmsg_move_time_skipped = 0x2CE,
    cmsg_battlefield_status = 0x2D3,
    cmsg_lfd_player_lock_info_request = 0x36E,
    cmsg_voice_session_enable = 0x3AF,
    cmsg_set_active_voice_channel = 0x3D3,
    msg_guild_bank_money_withdrawn = 0x3FE,
    cmsg_calendar_get_num_pending = 0x447,
    cmsg_world_state_ui_timer_update = 0x4F6,
    smsg_bindpointupdate = 0x155,
    cmsg_ping = 0x1DC,
    smsg_pong = 0x1DD,
    smsg_auth_challenge = 0x1EC,
    cmsg_auth_session = 0x1ED,
    smsg_auth_response = 0x1EE,
    smsg_account_data_times = 0x209,
    cmsg_request_account_data = 0x20A,
    cmsg_update_account_data = 0x20B,
    smsg_login_verify_world = 0x236,
    smsg_init_world_states = 0x2C2,
    smsg_motd = 0x33D,
    smsg_addon_info = 0x2EF,
    smsg_realm_split = 0x38B,
    cmsg_realm_split = 0x38C,
    cmsg_keep_alive = 0x407,
    smsg_update_account_data_complete = 0x463,
    smsg_clientcache_version = 0x4AB,
    smsg_talents_info = 0x4C0,
    cmsg_ready_for_account_data_times = 0x4FF,
    smsg_time_sync_req = 0x390,
    cmsg_time_sync_resp = 0x391,
    _,

    pub fn value(self: Opcode) u32 {
        return @intFromEnum(self);
    }
};

pub const Frame = struct {
    pub const client_header_size: usize = 6;
    pub const client_max_payload_size: usize = 10240 - 4;

    pub const Header = struct {
        opcode: Opcode,
        payload_len: usize,

        pub fn fromClientBuf(
            buf: *const [Frame.client_header_size]u8,
        ) ProtocolError!Header {
            const bytes = buf[0..];

            const size = utils.readU16BE(bytes, 0) catch return error.InvalidMessage;

            if (size < 4) {
                return error.InvalidMessage;
            }

            const payload_len = @as(usize, size) - 4;
            if (payload_len > Frame.client_max_payload_size) {
                return error.InvalidMessage;
            }

            const opcode_raw = utils.readU32LE(bytes, 2) catch return error.InvalidMessage;

            return .{
                .opcode = @enumFromInt(opcode_raw),
                .payload_len = payload_len,
            };
        }

        // NOTE: header payload length
        // has variable packing
        pub fn encodeServer(self: Header) ProtocolError!EncodedHeader {
            const size = self.payload_len + 2;
            const opcode = self.opcode.value();

            if (opcode > std.math.maxInt(u16)) {
                return error.InvalidMessage;
            }

            var out = EncodedHeader{};

            if (size > 0x7FFF) {
                if (size > 0x7FFFFF) return error.InvalidMessage;

                out.bytes[0] = 0x80 | @as(u8, @intCast(size >> 16));
                out.bytes[1] = @intCast(size >> 8);
                out.bytes[2] = @truncate(size);
                std.mem.writeInt(u16, out.bytes[3..5], @intCast(opcode), .little);
                out.len = 5;
            } else {
                std.mem.writeInt(u16, out.bytes[0..2], @intCast(size), .big);
                std.mem.writeInt(u16, out.bytes[2..4], @intCast(opcode), .little);
                out.len = 4;
            }

            return out;
        }
    };

    pub const EncodedHeader = struct {
        bytes: [6]u8 = undefined,
        len: u8 = 0,

        pub fn scrambled(self: EncodedHeader, rc4: *world_auth.Rc4) EncodedHeader {
            var result = self;
            rc4.update(result.bytes[0..result.len]);
            return result;
        }

        pub fn slice(self: *const EncodedHeader) []const u8 {
            return self.bytes[0..self.len];
        }
    };
};

pub const NameQueryClient = struct {
    guid: ObjectGuid,

    pub fn unmarshal(bytes: []const u8) ProtocolError!NameQueryClient {
        return .{
            .guid = ObjectGuid.fromRaw(utils.readU64LE(bytes, 0) catch return ProtocolError.InvalidMessage),
        };
    }
};

pub const NameQueryResponseServer = struct {
    pub const opcode: Opcode = .smsg_name_query_response;

    guid: ObjectGuid,
    name_unknown: bool = false,
    name: []const u8,
    race: u8,
    gender: u8,
    class_id: u8,

    pub fn marshal(self: NameQueryResponseServer, allocator: std.mem.Allocator) ![]u8 {
        const packed_guid = self.guid.toPacked();
        if (self.name_unknown) {
            const buf = try allocator.alloc(u8, packed_guid.len + 1);
            @memcpy(buf[0..packed_guid.len], packed_guid.slice());
            buf[packed_guid.len] = 1;
            return buf;
        }

        const buf = try allocator.alloc(u8, packed_guid.len + self.name.len + 7);
        var offset: usize = 0;
        @memcpy(buf[offset..][0..packed_guid.len], packed_guid.slice());
        offset += packed_guid.len;
        buf[offset] = 0;
        offset += 1;
        @memcpy(buf[offset..][0..self.name.len], self.name);
        offset += self.name.len;
        buf[offset] = 0;
        buf[offset + 1] = 0;
        buf[offset + 2] = self.race;
        buf[offset + 3] = self.gender;
        buf[offset + 4] = self.class_id;
        buf[offset + 5] = 0;
        return buf;
    }
};

// ─── CMSG_ITEM_QUERY_SINGLE (opcode 0x056) ─────────────────────────────────

pub const ItemQuerySingleClient = struct {
    entry: u32,

    pub fn unmarshal(bytes: []const u8) ProtocolError!ItemQuerySingleClient {
        if (bytes.len < 4) return ProtocolError.InvalidMessage;
        return .{
            .entry = utils.readU32LE(bytes, 0) catch return ProtocolError.InvalidMessage,
        };
    }
};

// ─── SMSG_ITEM_QUERY_SINGLE_RESPONSE (opcode 0x058) ────────────────────────
//
// Full 3.3.5a item template dump. Field order mirrors the reference core
// (arenacraft) Handler "HandleItemQuerySingleOpcode"; entries missing from
// game data are answered by the same opcode with the high-bit marker.

pub const ItemQuerySingleResponseServer = struct {
    pub const opcode: Opcode = .smsg_item_query_single_response;

    /// SoundOverrideSubclass: <0 keeps the subclass default sound.
    pub const sound_override_unknown: i32 = -1;
    /// AllowableClass/AllowableRace: -1 = unrestricted.
    pub const allowance_all: i32 = -1;

    const spell_block_count = 5;
    const damage_count = 2;
    const socket_count = 3;

    entry: u32,
    /// Null answers "unknown entry" with `entry | 0x80000000`.
    def: ?domain.ItemDef,

    pub fn marshal(self: ItemQuerySingleResponseServer, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        const def = self.def orelse {
            try appendU32(allocator, &out, self.entry | 0x8000_0000);
            return out.toOwnedSlice(allocator);
        };

        try appendU32(allocator, &out, def.entry);
        try appendU32(allocator, &out, def.item_class);
        try appendU32(allocator, &out, def.item_subclass);
        try appendI32(allocator, &out, sound_override_unknown);
        try appendCString(allocator, &out, def.name);
        // The client expects three further name slots as empty strings.
        try out.append(allocator, 0); // name2
        try out.append(allocator, 0); // name3
        try out.append(allocator, 0); // name4
        try appendU32(allocator, &out, def.display_id);
        try appendU32(allocator, &out, def.quality);
        try appendU32(allocator, &out, 0); // flags
        try appendU32(allocator, &out, 0); // flags2
        try appendU32(allocator, &out, 0); // buy_price
        try appendU32(allocator, &out, 0); // sell_price
        try appendU32(allocator, &out, def.inventory_type);
        try appendI32(allocator, &out, allowance_all); // allowable_class
        try appendI32(allocator, &out, allowance_all); // allowable_race
        try appendU32(allocator, &out, 0); // item_level
        try appendU32(allocator, &out, 0); // required_level
        try appendU32(allocator, &out, 0); // required_skill
        try appendU32(allocator, &out, 0); // required_skill_rank
        try appendU32(allocator, &out, 0); // required_spell
        try appendU32(allocator, &out, 0); // required_honor_rank
        try appendU32(allocator, &out, 0); // required_city_rank
        try appendI32(allocator, &out, 0); // required_reputation_faction
        try appendI32(allocator, &out, 0); // required_reputation_rank
        try appendI32(allocator, &out, 0); // max_count
        try appendI32(allocator, &out, 0); // stackable
        try appendU32(allocator, &out, 0); // container_slots

        // Stat bonuses; only non-zero contributions are listed.
        var stat_count: u32 = 0;
        if (def.stamina != 0) stat_count += 1;
        if (def.intellect != 0) stat_count += 1;
        try appendU32(allocator, &out, stat_count);
        if (def.stamina != 0) {
            try appendU32(allocator, &out, domain.ItemDef.stamina_stat_id);
            try appendI32(allocator, &out, @intCast(def.stamina));
        }
        if (def.intellect != 0) {
            try appendU32(allocator, &out, domain.ItemDef.intellect_stat_id);
            try appendI32(allocator, &out, @intCast(def.intellect));
        }

        try appendU32(allocator, &out, 0); // scaling_stat_distribution
        try appendU32(allocator, &out, 0); // scaling_stat_value
        for (0..damage_count) |_| {
            try appendF32(allocator, &out, 0); // damage_min
            try appendF32(allocator, &out, 0); // damage_max
            try appendU32(allocator, &out, 0); // damage_type
        }
        try appendU32(allocator, &out, def.armor); // resistances[0]
        for (0..6) |_| try appendI32(allocator, &out, 0); // holy..arcane resistance
        try appendU32(allocator, &out, 0); // delay
        try appendU32(allocator, &out, 0); // ammo_type
        try appendF32(allocator, &out, 0); // ranged_mod_range
        for (0..spell_block_count) |_| {
            try appendU32(allocator, &out, 0); // spell_id
            try appendU32(allocator, &out, 0); // spell_trigger
            try appendI32(allocator, &out, 0); // spell_charges
            try appendU32(allocator, &out, 0xFFFF_FFFF); // spell_cooldown (-1)
            try appendU32(allocator, &out, 0); // spell_category
            try appendU32(allocator, &out, 0xFFFF_FFFF); // spell_category_cooldown (-1)
        }
        try appendU32(allocator, &out, 0); // bonding
        try appendCString(allocator, &out, ""); // description
        try appendU32(allocator, &out, 0); // page_text
        try appendU32(allocator, &out, 0); // language_id
        try appendU32(allocator, &out, 0); // page_material
        try appendU32(allocator, &out, 0); // start_quest
        try appendU32(allocator, &out, 0); // lock_id
        try appendI32(allocator, &out, 0); // material
        try appendU32(allocator, &out, 0); // sheath
        try appendI32(allocator, &out, 0); // random_property
        try appendI32(allocator, &out, 0); // random_suffix
        try appendU32(allocator, &out, 0); // block
        try appendU32(allocator, &out, 0); // item_set
        try appendU32(allocator, &out, 0); // max_durability
        try appendU32(allocator, &out, 0); // area
        try appendU32(allocator, &out, 0); // map
        try appendU32(allocator, &out, 0); // bag_family
        try appendU32(allocator, &out, 0); // totem_category
        for (0..socket_count) |_| {
            try appendU32(allocator, &out, 0); // socket color
            try appendU32(allocator, &out, 0); // socket content
        }
        try appendU32(allocator, &out, 0); // socket_bonus
        try appendU32(allocator, &out, 0); // gem_properties
        try appendU32(allocator, &out, 0); // required_disenchant_skill
        try appendF32(allocator, &out, 0); // armor_damage_modifier
        try appendU32(allocator, &out, 0); // duration
        try appendU32(allocator, &out, 0); // item_limit_category
        try appendU32(allocator, &out, 0); // holiday_id

        return out.toOwnedSlice(allocator);
    }
};

fn appendU32(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try out.appendSlice(allocator, &buf);
}

fn appendI32(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: i32) !void {
    try appendU32(allocator, out, @bitCast(value));
}

fn appendF32(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: f32) !void {
    try appendU32(allocator, out, @bitCast(value));
}

fn appendCString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try out.appendSlice(allocator, value);
    try out.append(allocator, 0);
}

// ─── SMSG_AUTH_CHALLENGE (opcode 0x1EC) ─────────────────────────────────────

pub const AuthChallengeServer = struct {
    pub const opcode: Opcode = .smsg_auth_challenge;
    pub const total_size: usize = 40; // u32(1) + authSeed[4] + newSeeds[32]

    seed: [4]u8,
    seeds: [32]u8,

    const Self = @This();
    pub fn marshal(self: Self, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, total_size);
        errdefer allocator.free(buf);
        utils.writeU32LE(buf, 0, 1);
        @memcpy(buf[4..8], &self.seed);
        @memcpy(buf[8..40], &self.seeds);
        return buf;
    }
};

// ─── CMSG_AUTH_SESSION (opcode 0x1ED) ───────────────────────────────────────

pub const AuthSessionClient = struct {
    build: u32,
    login_server_id: u32,
    account: []const u8,
    login_server_type: u32,
    local_challenge: [4]u8,
    region_id: u32,
    battlegroup_id: u32,
    realm_id: u32,
    dos_response: u64,
    digest: [20]u8,
    addon_info: []const u8,

    const Self = @This();

    pub fn unmarshal(bytes: []const u8) ProtocolError!Self {
        var off: usize = 0;

        const build = utils.readU32LE(bytes, off) catch return ProtocolError.InvalidMessage;
        off += 4;

        const login_server_id = utils.readU32LE(bytes, off) catch return ProtocolError.InvalidMessage;
        off += 4;

        const account = utils.readCString(bytes, off) catch return ProtocolError.InvalidMessage;
        off += account.len + 1;

        const login_server_type = utils.readU32LE(bytes, off) catch return ProtocolError.InvalidMessage;
        off += 4;

        if (off + 4 > bytes.len) return ProtocolError.InvalidMessage;
        var local_challenge: [4]u8 = undefined;
        @memcpy(&local_challenge, bytes[off..][0..4]);
        off += 4;

        const region_id = utils.readU32LE(bytes, off) catch return ProtocolError.InvalidMessage;
        off += 4;

        const battlegroup_id = utils.readU32LE(bytes, off) catch return ProtocolError.InvalidMessage;
        off += 4;

        const realm_id = utils.readU32LE(bytes, off) catch return ProtocolError.InvalidMessage;
        off += 4;

        const dos_response = utils.readU64LE(bytes, off) catch return ProtocolError.InvalidMessage;
        off += 8;

        if (off + 20 > bytes.len) return ProtocolError.InvalidMessage;
        var digest: [20]u8 = undefined;
        @memcpy(&digest, bytes[off..][0..20]);
        off += 20;

        const addon_info = if (off < bytes.len) bytes[off..] else &[_]u8{};

        return Self{
            .build = build,
            .login_server_id = login_server_id,
            .account = account,
            .login_server_type = login_server_type,
            .local_challenge = local_challenge,
            .region_id = region_id,
            .battlegroup_id = battlegroup_id,
            .realm_id = realm_id,
            .dos_response = dos_response,
            .digest = digest,
            .addon_info = addon_info,
        };
    }

    pub fn getParsedAddonInfo(self: AuthSessionClient, allocator: std.mem.Allocator) ![]AddonInfo {
        const bytes = self.addon_info;
        if (bytes.len < 4) return allocator.alloc(AddonInfo, 0);

        const decompressed_size = std.mem.readInt(u32, bytes[0..4], .little);
        if (decompressed_size == 0) return allocator.alloc(AddonInfo, 0);
        if (decompressed_size > 0xFFFFF) return error.AddonInfoTooLarge;

        var input: std.Io.Reader = .fixed(bytes[4..]);
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();

        var decompress: std.compress.flate.Decompress = .init(&input, .zlib, &.{});
        const actual_size = try decompress.reader.streamRemaining(&output.writer);
        if (actual_size != decompressed_size) return error.InvalidAddonInfoSize;

        const plain = output.written();
        var off: usize = 0;
        const addon_count = utils.readU32LECursor(plain, &off) catch return allocator.alloc(AddonInfo, 0);
        if (addon_count > 1024) return error.TooManyAddons;

        var addons: std.ArrayList(AddonInfo) = .empty;
        errdefer addons.deinit(allocator);

        var i: u32 = 0;
        while (i < addon_count) : (i += 1) {
            _ = utils.readCStringCursor(plain, &off) catch break;
            if (off + 9 > plain.len) break;
            off += 1;
            const crc = utils.readU32LECursor(plain, &off) catch break;
            _ = utils.readU32LECursor(plain, &off) catch break;
            try addons.append(allocator, .{ .crc = crc });
        }

        return addons.toOwnedSlice(allocator);
    }
};

// ─── SMSG_AUTH_RESPONSE (opcode 0x1EE) ──────────────────────────────────────
//
//

pub const AuthResponseServer = struct {
    pub const opcode: Opcode = .smsg_auth_response;

    pub const Failure = enum(u8) {
        failed = 0x0D,
        rejected = 0x0E,
        banned = 0x1C,
        unknown_account = 0x15,
    };

    pub const Expansion = enum(u8) {
        classic = 0,
        tbc = 1,
        wotlk = 2,
    };

    pub const Queued = struct {
        code: u8,
        expansion: Expansion,
        queue_pos: u32,
    };

    pub const Form = union(enum) {
        failure: Failure,
        success: Expansion,
        queued: Queued,
    };

    form: Form,

    const Self = @This();

    pub fn failure(code: Failure) Self {
        return .{
            .form = .{ .failure = code },
        };
    }

    pub fn authFailed() Self {
        return failure(.failed);
    }

    pub fn unknownAccount() Self {
        return failure(.unknown_account);
    }

    pub fn success(expansion: Expansion) Self {
        return .{
            .form = .{ .success = expansion },
        };
    }

    pub fn marshal(
        self: Self,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        return switch (self.form) {
            .failure => |code| marshalFailure(allocator, code),
            .success => |expansion| marshalSuccess(allocator, expansion),
            .queued => |response| marshalQueued(allocator, response),
        };
    }

    fn marshalFailure(
        allocator: std.mem.Allocator,
        code: Failure,
    ) ![]u8 {
        const buf = try allocator.alloc(u8, 1);
        buf[0] = @intFromEnum(code);
        return buf;
    }

    fn marshalSuccess(
        allocator: std.mem.Allocator,
        expansion: Expansion,
    ) ![]u8 {
        const buf = try allocator.alloc(u8, 11);
        errdefer allocator.free(buf);

        buf[0] = 0x0C;
        utils.writeU32LE(buf, 1, 0);
        buf[5] = 0;
        utils.writeU32LE(buf, 6, 0);
        buf[10] = @intFromEnum(expansion);

        return buf;
    }

    fn marshalQueued(
        allocator: std.mem.Allocator,
        response: Queued,
    ) ![]u8 {
        const buf = try allocator.alloc(u8, 16);
        errdefer allocator.free(buf);

        buf[0] = response.code;
        utils.writeU32LE(buf, 1, 0);
        buf[5] = 0;
        utils.writeU32LE(buf, 6, 0);
        buf[10] = @intFromEnum(response.expansion);
        utils.writeU32LE(buf, 11, response.queue_pos);
        buf[15] = 0;

        return buf;
    }

    pub fn format(
        self: Self,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("AuthResponseServer{ ");

        switch (self.form) {
            .failure => |code| {
                try writer.print(
                    "failure={s}(0x{X:0>2})",
                    .{
                        @tagName(code),
                        @intFromEnum(code),
                    },
                );
            },
            .success => |expansion| {
                try writer.print(
                    "success expansion={s}",
                    .{@tagName(expansion)},
                );
            },
            .queued => |response| {
                try writer.print(
                    "queued code=0x{X:0>2}, expansion={s}, queue_pos={d}",
                    .{
                        response.code,
                        @tagName(response.expansion),
                        response.queue_pos,
                    },
                );
            },
        }

        try writer.writeAll(" }");
    }
};

pub const PongServer = struct {
    pub const opcode: Opcode = .smsg_pong;

    ping: u32,

    pub fn marshal(self: PongServer, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, 4);
        utils.writeU32LE(buf, 0, self.ping);
        return buf;
    }
};

pub const ClientCacheVersionServer = struct {
    pub const opcode: Opcode = .smsg_clientcache_version;

    version: u32,

    pub fn marshal(self: ClientCacheVersionServer, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, 4);
        utils.writeU32LE(buf, 0, self.version);
        return buf;
    }
};

pub const TutorialFlagsServer = struct {
    pub const opcode: Opcode = .smsg_tutorial_flags;

    flags: [8]u32 = [_]u32{0} ** 8,

    pub fn allCompleted() @This() {
        return .{ .flags = [_]u32{0xFFFFFFFF} ** 8 };
    }

    pub fn marshal(self: *const @This(), allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, 32);
        errdefer allocator.free(buf);
        for (self.flags, 0..) |f, i| {
            utils.writeU32LE(buf, i * 4, f);
        }
        return buf;
    }
};

pub const AccountDataTimesServer = struct {
    pub const opcode: Opcode = .smsg_account_data_times;
    pub const global_cache_mask: u32 = 0x15;
    pub const per_character_cache_mask: u32 = 0xEA;

    unix_time: u32,
    mask: u32 = global_cache_mask,

    pub fn marshal(self: AccountDataTimesServer, allocator: std.mem.Allocator) ![]u8 {
        const timestamp_count = @popCount(self.mask & 0xFF);
        const buf = try allocator.alloc(u8, 4 + 1 + 4 + timestamp_count * 4);
        errdefer allocator.free(buf);

        utils.writeU32LE(buf, 0, self.unix_time);
        buf[4] = 1;
        utils.writeU32LE(buf, 5, self.mask);
        var off: usize = 9;
        var i: u5 = 0;
        while (i < 8) : (i += 1) {
            if ((self.mask & (@as(u32, 1) << i)) != 0) {
                utils.writeU32LE(buf, off, 0);
                off += 4;
            }
        }

        return buf;
    }
};

pub const RealmSplitServer = struct {
    pub const opcode: Opcode = .smsg_realm_split;

    value: u32,

    pub fn marshal(self: RealmSplitServer, allocator: std.mem.Allocator) ![]u8 {
        const split_date = "01/01/01";
        const buf = try allocator.alloc(u8, 4 + 4 + split_date.len + 1);
        errdefer allocator.free(buf);
        utils.writeU32LE(buf, 0, self.value);
        utils.writeU32LE(buf, 4, 0);
        @memcpy(buf[8..][0..split_date.len], split_date);
        buf[8 + split_date.len] = 0;
        return buf;
    }
};

pub const UpdateAccountDataCompleteServer = struct {
    pub const opcode: Opcode = .smsg_update_account_data_complete;

    typ: u32,

    pub fn marshal(self: UpdateAccountDataCompleteServer, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, 8);
        utils.writeU32LE(buf, 0, self.typ);
        utils.writeU32LE(buf, 4, 0);
        return buf;
    }
};

pub const AddonInfo = struct {
    crc: u32,
};

pub const AddonInfoServer = struct {
    pub const opcode: Opcode = .smsg_addon_info;
    pub const standard_addon_crc: u32 = 0x4C1C776D;
    pub const public_key = [_]u8{
        0xC3, 0x5B, 0x50, 0x84, 0xB9, 0x3E, 0x32, 0x42, 0x8C, 0xD0, 0xC7, 0x48, 0xFA, 0x0E, 0x5D, 0x54,
        0x5A, 0xA3, 0x0E, 0x14, 0xBA, 0x9E, 0x0D, 0xB9, 0x5D, 0x8B, 0xEE, 0xB6, 0x84, 0x93, 0x45, 0x75,
        0xFF, 0x31, 0xFE, 0x2F, 0x64, 0x3F, 0x3D, 0x6D, 0x07, 0xD9, 0x44, 0x9B, 0x40, 0x85, 0x59, 0x34,
        0x4E, 0x10, 0xE1, 0xE7, 0x43, 0x69, 0xEF, 0x7C, 0x16, 0xFC, 0xB4, 0xED, 0x1B, 0x95, 0x28, 0xA8,
        0x23, 0x76, 0x51, 0x31, 0x57, 0x30, 0x2B, 0x79, 0x08, 0x50, 0x10, 0x1C, 0x4A, 0x1A, 0x2C, 0xC8,
        0x8B, 0x8F, 0x05, 0x2D, 0x22, 0x3D, 0xDB, 0x5A, 0x24, 0x7A, 0x0F, 0x13, 0x50, 0x37, 0x8F, 0x5A,
        0xCC, 0x9E, 0x04, 0x44, 0x0E, 0x87, 0x01, 0xD4, 0xA3, 0x15, 0x94, 0x16, 0x34, 0xC6, 0xC2, 0xC3,
        0xFB, 0x49, 0xFE, 0xE1, 0xF9, 0xDA, 0x8C, 0x50, 0x3C, 0xBE, 0x2C, 0xBB, 0x57, 0xED, 0x46, 0xB9,
        0xAD, 0x8B, 0xC6, 0xDF, 0x0E, 0xD6, 0x0F, 0xBE, 0x80, 0xB3, 0x8B, 0x1E, 0x77, 0xCF, 0xAD, 0x22,
        0xCF, 0xB7, 0x4B, 0xCF, 0xFB, 0xF0, 0x6B, 0x11, 0x45, 0x2D, 0x7A, 0x81, 0x18, 0xF2, 0x92, 0x7E,
        0x98, 0x56, 0x5D, 0x5E, 0x69, 0x72, 0x0A, 0x0D, 0x03, 0x0A, 0x85, 0xA2, 0x85, 0x9C, 0xCB, 0xFB,
        0x56, 0x6E, 0x8F, 0x44, 0xBB, 0x8F, 0x02, 0x22, 0x68, 0x63, 0x97, 0xBC, 0x85, 0xBA, 0xA8, 0xF7,
        0xB5, 0x40, 0x68, 0x3C, 0x77, 0x86, 0x6F, 0x4B, 0xD7, 0x88, 0xCA, 0x8A, 0xD7, 0xCE, 0x36, 0xF0,
        0x45, 0x6E, 0xD5, 0x64, 0x79, 0x0F, 0x17, 0xFC, 0x64, 0xDD, 0x10, 0x6F, 0xF3, 0xF5, 0xE0, 0xA6,
        0xC3, 0xFB, 0x1B, 0x8C, 0x29, 0xEF, 0x8E, 0xE5, 0x34, 0xCB, 0xD1, 0x2A, 0xCE, 0x79, 0xC3, 0x9A,
        0x0D, 0x36, 0xEA, 0x01, 0xE0, 0xAA, 0x91, 0x20, 0x54, 0xF0, 0x72, 0xD8, 0x1E, 0xC7, 0x89, 0xD2,
    };

    addons: []const AddonInfo,

    pub fn marshal(self: AddonInfoServer, allocator: std.mem.Allocator) ![]u8 {
        var total: usize = 4;
        for (self.addons) |addon| {
            total += 1 + 1 + 1 + 4 + 1;
            if (addon.crc != standard_addon_crc) total += public_key.len;
        }

        const buf = try allocator.alloc(u8, total);
        errdefer allocator.free(buf);

        var off: usize = 0;
        for (self.addons) |addon| {
            buf[off] = 2;
            off += 1;
            buf[off] = 1;
            off += 1;

            const use_public_key: u8 = if (addon.crc != standard_addon_crc) 1 else 0;
            buf[off] = use_public_key;
            off += 1;
            if (use_public_key != 0) {
                @memcpy(buf[off..][0..public_key.len], &public_key);
                off += public_key.len;
            }

            utils.writeU32LE(buf, off, 0);
            off += 4;
            buf[off] = 0;
            off += 1;
        }

        utils.writeU32LE(buf, off, 0);
        return buf;
    }
};

pub const PlayerLoginClient = struct {
    guid: ObjectGuid,

    pub fn unmarshal(bytes: []const u8) ProtocolError!PlayerLoginClient {
        if (bytes.len < 8) return ProtocolError.InvalidMessage;
        const raw = utils.readU64LE(bytes, 0) catch return ProtocolError.InvalidMessage;
        return PlayerLoginClient{ .guid = ObjectGuid.fromRaw(raw) };
    }
};

pub const LoginVerifyWorldServer = struct {
    pub const opcode: Opcode = .smsg_login_verify_world;

    map_id: u32,
    position_x: f32,
    position_y: f32,
    position_z: f32,
    orientation: f32,

    pub fn marshal(self: LoginVerifyWorldServer, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, 20);
        utils.writeU32LE(buf, 0, self.map_id);
        writeF32LE(buf, 4, self.position_x);
        writeF32LE(buf, 8, self.position_y);
        writeF32LE(buf, 12, self.position_z);
        writeF32LE(buf, 16, self.orientation);
        return buf;
    }
};

pub const BindPointUpdateServer = struct {
    pub const opcode: Opcode = .smsg_bindpointupdate;

    x: f32,
    y: f32,
    z: f32,
    map_id: u32,
    area_id: u32,

    pub fn marshal(self: BindPointUpdateServer, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, 20);
        writeF32LE(buf, 0, self.x);
        writeF32LE(buf, 4, self.y);
        writeF32LE(buf, 8, self.z);
        utils.writeU32LE(buf, 12, self.map_id);
        utils.writeU32LE(buf, 16, self.area_id);
        return buf;
    }
};

/// Empty talents: one spec group, no talents, no glyphs, no free points.
pub const TalentsInfoServer = struct {
    pub const opcode: Opcode = .smsg_talents_info;

    // u8 isPet + u32 freePoints + u8 specCount + u8 activeSpec
    // + u8 talentCount + u8 glyphCount + 6 * u16 glyphs
    pub const body_len = 1 + 4 + 1 + 1 + 1 + 1 + 6 * 2;

    pub fn marshal(self: TalentsInfoServer, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        const buf = try allocator.alloc(u8, body_len);
        @memset(buf, 0);
        buf[5] = 1; // spec group count
        buf[8] = 6; // glyph slot count
        return buf;
    }
};

/// Spellbook: u8 padding, u16 spell count, (u32 spell + u16 zero) per spell,
/// u16 cooldown count.
pub const InitialSpellsServer = struct {
    pub const opcode: Opcode = .smsg_initial_spells;

    spells: []const u32 = &.{},

    pub fn marshal(self: InitialSpellsServer, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, 1 + 2 + self.spells.len * 6 + 2);
        buf[0] = 0;
        utils.writeU16LE(buf, 1, @intCast(self.spells.len));
        var offset: usize = 3;
        for (self.spells) |spell_id| {
            utils.writeU32LE(buf, offset, spell_id);
            offset += 4;
            utils.writeU16LE(buf, offset, 0);
            offset += 2;
        }
        utils.writeU16LE(buf, offset, 0);
        return buf;
    }
};

pub const LearnedSpellServer = struct {
    pub const opcode: Opcode = .smsg_learned_spell;

    spell_id: u32,

    pub fn marshal(self: LearnedSpellServer, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, 6);
        utils.writeU32LE(buf, 0, self.spell_id);
        utils.writeU16LE(buf, 4, 0);
        return buf;
    }
};

/// All 132 action button slots empty. The leading byte is the button state.
pub const ActionButtonsServer = struct {
    pub const opcode: Opcode = .smsg_action_buttons;
    pub const button_count = 132;

    state: u8 = 0,

    pub fn marshal(self: ActionButtonsServer, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, 1 + button_count * 4);
        @memset(buf, 0);
        buf[0] = self.state;
        return buf;
    }
};

/// 128 factions, all at neutral standing with no flags.
pub const InitializeFactionsServer = struct {
    pub const opcode: Opcode = .smsg_initialize_factions;

    pub fn marshal(self: InitializeFactionsServer, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        const buf = try allocator.alloc(u8, 4 + 128 * 5);
        @memset(buf, 0);
        utils.writeU32LE(buf, 0, 128);
        return buf;
    }
};

pub const LoginSetTimeSpeedServer = struct {
    pub const opcode: Opcode = .smsg_login_settimespeed;

    packed_time: u32,
    speed: f32,
    unk: u32 = 0,

    pub fn marshal(self: LoginSetTimeSpeedServer, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, 12);
        utils.writeU32LE(buf, 0, self.packed_time);
        writeF32LE(buf, 4, self.speed);
        utils.writeU32LE(buf, 8, self.unk);
        return buf;
    }
};

pub const TimeSyncRequestServer = struct {
    pub const opcode: Opcode = .smsg_time_sync_req;

    counter: u32,

    pub fn marshal(self: TimeSyncRequestServer, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, 4);
        utils.writeU32LE(buf, 0, self.counter);
        return buf;
    }
};

pub const TimeSyncResponseClient = struct {
    counter: u32,
    client_time_ms: u32,

    pub fn unmarshal(bytes: []const u8) ProtocolError!TimeSyncResponseClient {
        if (bytes.len != 8) return ProtocolError.InvalidMessage;
        return .{
            .counter = utils.readU32LE(bytes, 0) catch return ProtocolError.InvalidMessage,
            .client_time_ms = utils.readU32LE(bytes, 4) catch return ProtocolError.InvalidMessage,
        };
    }
};

/// ByteBuffer::AppendPackedTime layout:
/// (year-2000)<<24 | (month-1)<<20 | (mday-1)<<14 | wday<<11 | hour<<6 | min
/// (AC: `(tm_year - 100) << 24` where tm_year counts from 1900.)
pub fn packGameTime(secs_since_epoch: u64) u32 {
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = secs_since_epoch };
    const epoch_day = epoch_secs.getEpochDay();
    const day_secs = epoch_secs.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const year: u32 = year_day.year;
    const month: u32 = month_day.month.numeric();
    const mday: u32 = @as(u32, month_day.day_index) + 1;
    // 1970-01-01 was a Thursday (tm_wday 4, Sunday = 0).
    const wday: u32 = @intCast((epoch_day.day + 4) % 7);
    const hour: u32 = day_secs.getHoursIntoDay();
    const minute: u32 = day_secs.getMinutesIntoHour();

    return ((year - 2000) << 24) | ((month - 1) << 20) | ((mday - 1) << 14) | (wday << 11) | (hour << 6) | minute;
}

pub const InitWorldStatesServer = struct {
    pub const opcode: Opcode = .smsg_init_world_states;

    map_id: u32,
    zone_id: u32,
    area_id: u32,

    pub fn marshal(self: InitWorldStatesServer, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, 14);
        utils.writeU32LE(buf, 0, self.map_id);
        utils.writeU32LE(buf, 4, self.zone_id);
        utils.writeU32LE(buf, 8, self.area_id);
        utils.writeU16LE(buf, 12, 0); // world state pair count
        return buf;
    }
};

pub const MotdServer = struct {
    pub const opcode: Opcode = .smsg_motd;

    lines: []const []const u8,

    pub fn marshal(self: MotdServer, allocator: std.mem.Allocator) ![]u8 {
        var total_len: usize = 4;
        for (self.lines) |line| total_len += 4 + line.len + 1;

        const buf = try allocator.alloc(u8, total_len);
        utils.writeU32LE(buf, 0, @intCast(self.lines.len));
        var offset: usize = 4;
        for (self.lines) |line| {
            utils.writeU32LE(buf, offset, @intCast(line.len + 1));
            offset += 4;
            @memcpy(buf[offset..][0..line.len], line);
            offset += line.len;
            buf[offset] = 0;
            offset += 1;
        }
        return buf;
    }
};

pub const VisibleItem = struct {
    display_id: u32 = 0,
    inventory_type: u8 = 0,
    enchant_aura: u32 = 0,
};

pub const CharEnumEntry = struct {
    guid: ObjectGuid,
    name: []const u8,
    race: u8,
    class: u8,
    gender: u8,
    skin: u8,
    face: u8,
    hair_style: u8,
    hair_color: u8,
    facial_hair: u8,
    level: u8,
    zone_id: u32,
    map_id: u32,
    position_x: f32,
    position_y: f32,
    position_z: f32,
    guild_id: u32 = 0,
    flags: u32 = 0,
    customize_flags: u32 = 0,
    first_login: u8 = 0,
    pet_display_id: u32 = 0,
    pet_level: u32 = 0,
    pet_family: u32 = 0,
    equipment: [CharEnumServer.visible_item_slots]VisibleItem = [_]VisibleItem{.{}} ** CharEnumServer.visible_item_slots,
};

pub const CharEnumServer = struct {
    pub const opcode: Opcode = .smsg_char_enum;
    pub const visible_item_slots: usize = 23;

    characters: []const CharEnumEntry,

    pub fn marshal(self: CharEnumServer, allocator: std.mem.Allocator) ![]u8 {
        if (self.characters.len > std.math.maxInt(u8)) return error.TooManyCharacters;

        var total: usize = 1;
        for (self.characters) |character| {
            total += 8; // guid
            total += character.name.len + 1;
            total += 8; // race, class, gender, skin, face, hair, hair color, facial hair
            total += 1; // level
            total += 4 + 4; // zone, map
            total += 4 + 4 + 4; // position
            total += 4; // guild id
            total += 4; // character flags
            total += 4; // customization flags
            total += 1; // first login
            total += 4 + 4 + 4; // pet display, pet level, pet family
            total += visible_item_slots * (4 + 1 + 4);
        }

        const buf = try allocator.alloc(u8, total);
        errdefer allocator.free(buf);

        var off: usize = 0;
        buf[off] = @intCast(self.characters.len);
        off += 1;

        for (self.characters) |character| {
            utils.writeU64LE(buf, off, character.guid.valueOf());
            off += 8;

            @memcpy(buf[off..][0..character.name.len], character.name);
            off += character.name.len;
            buf[off] = 0;
            off += 1;

            buf[off] = character.race;
            off += 1;
            buf[off] = character.class;
            off += 1;
            buf[off] = character.gender;
            off += 1;
            buf[off] = character.skin;
            off += 1;
            buf[off] = character.face;
            off += 1;
            buf[off] = character.hair_style;
            off += 1;
            buf[off] = character.hair_color;
            off += 1;
            buf[off] = character.facial_hair;
            off += 1;
            buf[off] = character.level;
            off += 1;

            utils.writeU32LE(buf, off, character.zone_id);
            off += 4;
            utils.writeU32LE(buf, off, character.map_id);
            off += 4;
            writeF32LE(buf, off, character.position_x);
            off += 4;
            writeF32LE(buf, off, character.position_y);
            off += 4;
            writeF32LE(buf, off, character.position_z);
            off += 4;

            utils.writeU32LE(buf, off, character.guild_id);
            off += 4;
            utils.writeU32LE(buf, off, character.flags);
            off += 4;
            utils.writeU32LE(buf, off, character.customize_flags);
            off += 4;
            buf[off] = character.first_login;
            off += 1;

            utils.writeU32LE(buf, off, character.pet_display_id);
            off += 4;
            utils.writeU32LE(buf, off, character.pet_level);
            off += 4;
            utils.writeU32LE(buf, off, character.pet_family);
            off += 4;

            var slot: usize = 0;
            while (slot < visible_item_slots) : (slot += 1) {
                const item = character.equipment[slot];
                utils.writeU32LE(buf, off, item.display_id);
                off += 4;
                buf[off] = item.inventory_type;
                off += 1;
                utils.writeU32LE(buf, off, item.enchant_aura);
                off += 4;
            }
        }

        std.debug.assert(off == buf.len);
        return buf;
    }
};

pub const CharCreateClient = struct {
    name: []const u8,
    race: u8,
    class: u8,
    gender: u8,
    skin: u8,
    face: u8,
    hair_style: u8,
    hair_color: u8,
    facial_hair: u8,
    outfit_id: u8,

    pub fn unmarshal(bytes: []const u8) ProtocolError!CharCreateClient {
        const name = utils.readCString(bytes, 0) catch return ProtocolError.InvalidMessage;
        const off = name.len + 1;
        if (off + 9 > bytes.len) return ProtocolError.InvalidMessage;
        const parsed = CharCreateClient{
            .name = name,
            .race = bytes[off],
            .class = bytes[off + 1],
            .gender = bytes[off + 2],
            .skin = bytes[off + 3],
            .face = bytes[off + 4],
            .hair_style = bytes[off + 5],
            .hair_color = bytes[off + 6],
            .facial_hair = bytes[off + 7],
            .outfit_id = bytes[off + 8],
        };
        return parsed;
    }
};

pub const CharCreateServer = struct {
    pub const opcode: Opcode = .smsg_char_create;

    pub const success: u8 = 0x2F;
    pub const error_: u8 = 0x30;
    pub const failed: u8 = 0x31;
    pub const name_in_use: u8 = 0x32;
    pub const expansion: u8 = 0x39;
    pub const char_name_no_name: u8 = 0x59;
    pub const char_name_too_short: u8 = 0x5A;
    pub const char_name_too_long: u8 = 0x5B;
    pub const char_name_invalid_character: u8 = 0x5C;

    code: u8,

    pub fn marshal(self: CharCreateServer, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, 1);
        buf[0] = self.code;
        return buf;
    }
};

pub const CharDeleteClient = struct {
    guid: ObjectGuid,

    pub fn unmarshal(bytes: []const u8) ProtocolError!CharDeleteClient {
        const raw = utils.readU64LE(bytes, 0) catch return ProtocolError.InvalidMessage;
        return .{ .guid = ObjectGuid.fromRaw(raw) };
    }
};

pub const CharDeleteServer = struct {
    pub const opcode: Opcode = .smsg_char_delete;

    pub const success: u8 = 0x47;
    pub const failed: u8 = 0x48;

    code: u8,

    pub fn marshal(self: CharDeleteServer, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, 1);
        buf[0] = self.code;
        return buf;
    }
};

// ─── CMSG_PING (opcode 0x1DC) ───────────────────────────────────────────────

pub const PingClient = struct {
    /// Counter/ID generated by the client. Echoed back verbatim as SMSG_PONG
    /// so the client can match responses and measure round-trip time.
    ping: u32,
    /// Client's self-measured network latency in milliseconds. Store on the
    /// session; used for lag compensation, cast bars, and the in-game
    /// latency bar.
    latency: u32,

    pub fn unmarshal(bytes: []const u8) ProtocolError!PingClient {
        if (bytes.len < 8) return ProtocolError.InvalidMessage;
        return .{
            .ping = utils.readU32LE(bytes, 0) catch return ProtocolError.InvalidMessage,
            .latency = utils.readU32LE(bytes, 4) catch return ProtocolError.InvalidMessage,
        };
    }
};

// ─── CMSG_REALM_SPLIT (opcode 0x38C) ───────────────────────────────────────

pub const RealmSplitClient = struct {
    value: u32,

    pub fn unmarshal(bytes: []const u8) ProtocolError!RealmSplitClient {
        if (bytes.len < 4) return ProtocolError.InvalidMessage;
        return .{
            .value = utils.readU32LE(bytes, 0) catch return ProtocolError.InvalidMessage,
        };
    }
};

// ─── CMSG_REQUEST_ACCOUNT_DATA (opcode 0x20A) ──────────────────────────────

pub const RequestAccountDataClient = struct {
    typ: u32,

    pub fn unmarshal(bytes: []const u8) ProtocolError!RequestAccountDataClient {
        if (bytes.len < 4) return ProtocolError.InvalidMessage;
        return .{
            .typ = utils.readU32LE(bytes, 0) catch return ProtocolError.InvalidMessage,
        };
    }
};

// ─── CMSG_UPDATE_ACCOUNT_DATA (opcode 0x20B) ───────────────────────────────

pub const UpdateAccountDataClient = struct {
    typ: u32,
    timestamp: u32,
    decompressed_size: u32,
    /// zlib-compressed payload (remaining bytes after the 12-byte header)
    data: []const u8,

    pub fn unmarshal(bytes: []const u8) ProtocolError!UpdateAccountDataClient {
        if (bytes.len < 12) return ProtocolError.InvalidMessage;
        return .{
            .typ = utils.readU32LE(bytes, 0) catch return ProtocolError.InvalidMessage,
            .timestamp = utils.readU32LE(bytes, 4) catch return ProtocolError.InvalidMessage,
            .decompressed_size = utils.readU32LE(bytes, 8) catch return ProtocolError.InvalidMessage,
            .data = bytes[12..],
        };
    }
};

fn writeF32LE(buf: []u8, offset: usize, value: f32) void {
    const bits: u32 = @bitCast(value);
    utils.writeU32LE(buf, offset, bits);
}

/// SMSG_UPDATE_OBJECT player introduction. The body is a CREATE_OBJECT2
/// update block; movement fields come from the domain character state.
pub const PlayerCreateServer = struct {
    pub const opcode: Opcode = .smsg_update_object;

    character: domain.Character,
    visible_items: [19]u32 = .{0} ** 19,
    time_ms: u32,
    self_update: bool = true,

    pub fn marshal(self: PlayerCreateServer, allocator: std.mem.Allocator) ![]u8 {
        const character = self.character;
        var pkt = try update_object.UpdateObject.init(allocator);
        defer pkt.deinit(allocator);
        try pkt.add(allocator, .{ .create_object2 = .{ .player_create = .{
            .guid = character.guid,
            .x = character.movement.position.x,
            .y = character.movement.position.y,
            .z = character.movement.position.z,
            .orientation = character.movement.orientation,
            .race = @intFromEnum(character.race_id),
            .class = @intFromEnum(character.class_id),
            .gender = character.gender,
            .skin = character.skin,
            .face = character.face,
            .hair_style = character.hair_style,
            .hair_color = character.hair_color,
            .facial_hair = character.facial_hair,
            .level = character.level,
            .health = character.derived.max_health,
            .power_type = character.class_id.powerTypeId().valueOf(),
            .power = character.derived.max_power,
            .base_stats = character.derived.base_stats,
            .item_stats = character.derived.item_stats,
            .armor = character.derived.armor,
            .item_guids = character.item_guids,
            .faction_template = game_data.races.factionTemplate(character.race_id),
            .display_id = game_data.races.displayId(character.race_id, character.gender),
            .visible_items = self.visible_items,
            .language_skill_ids = game_data.races.languageSkillIds(character.race_id),
            .time_ms = self.time_ms,
            .self_update = self.self_update,
        } } });

        return pkt.marshal(allocator);
    }

    pub fn format(self: PlayerCreateServer, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("World.PlayerCreateServer{{ guid=0x{X}, time_ms={d} }}", .{ self.character.guid.valueOf(), self.time_ms });
    }
};

/// SMSG_DESTROY_OBJECT despawns an object on the client. Wire shape per
/// reference/azerothcore-wotlk Object.cpp:280-285 (packed guid + death flag)
/// and Opcodes.h:200 (0x0AA).
pub const DestroyObjectServer = struct {
    pub const opcode: Opcode = .smsg_destroy_object;

    guid: ObjectGuid,
    /// If true the client runs CGUnit_C::OnDeath() (death animation etc).
    on_death: bool = false,

    pub fn marshal(self: DestroyObjectServer, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try update_object.writePackedGuid(&out, allocator, self.guid);
        try out.append(allocator, if (self.on_death) 1 else 0);
        return out.toOwnedSlice(allocator);
    }

    pub fn format(self: DestroyObjectServer, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("World.DestroyObjectServer{{ guid=0x{X}, on_death={} }}", .{ self.guid.valueOf(), self.on_death });
    }
};

// ─── tests ──────────────────────────────────────────────────────────────────

test "item query response dumps the full 3.3.5a item template" {
    const t = std.testing;
    const def = game_data.items.findItem(6834) orelse return error.MissingItem;

    const body = try (ItemQuerySingleResponseServer{ .entry = def.entry, .def = def }).marshal(t.allocator);
    defer t.allocator.free(body);

    try t.expectEqual(@as(usize, 449), body.len);
    try t.expectEqual(@as(u32, 6834), std.mem.readInt(u32, body[0..4], .little)); // entry
    try t.expectEqual(@as(u32, 4), std.mem.readInt(u32, body[4..8], .little)); // item_class (armor)
    try t.expectEqual(@as(u32, 1), std.mem.readInt(u32, body[8..12], .little)); // item_subclass (cloth)
    try t.expectEqual(@as(u32, 0xFFFF_FFFF), std.mem.readInt(u32, body[12..16], .little)); // sound_override
    try t.expectEqualStrings("Black Tuxedo", body[16..28]);
    try t.expectEqual(@as(u8, 0), body[28]); // name terminator
    try t.expectEqual(@as(u8, 0), body[29]); // name2
    try t.expectEqual(@as(u8, 0), body[30]); // name3
    try t.expectEqual(@as(u8, 0), body[31]); // name4
    try t.expectEqual(@as(u32, 13116), std.mem.readInt(u32, body[32..36], .little)); // display_id
    try t.expectEqual(@as(u32, 1), std.mem.readInt(u32, body[36..40], .little)); // quality
    try t.expectEqual(@as(u32, 5), std.mem.readInt(u32, body[56..60], .little)); // inventory_type
    try t.expectEqual(@as(u32, 0xFFFF_FFFF), std.mem.readInt(u32, body[60..64], .little)); // allowable_class
    try t.expectEqual(@as(u32, 0xFFFF_FFFF), std.mem.readInt(u32, body[64..68], .little)); // allowable_race
    try t.expectEqual(@as(u32, 2), std.mem.readInt(u32, body[116..120], .little)); // stats_count
    try t.expectEqual(@as(u32, domain.ItemDef.stamina_stat_id), std.mem.readInt(u32, body[120..124], .little));
    try t.expectEqual(@as(u32, 12), std.mem.readInt(u32, body[124..128], .little));
    try t.expectEqual(@as(u32, domain.ItemDef.intellect_stat_id), std.mem.readInt(u32, body[128..132], .little));
    try t.expectEqual(@as(u32, 8), std.mem.readInt(u32, body[132..136], .little));
    try t.expectEqual(@as(u32, 150), std.mem.readInt(u32, body[168..172], .little)); // armor
    try t.expectEqual(@as(u32, 0xFFFF_FFFF), std.mem.readInt(u32, body[220..224], .little)); // spell cooldown
    try t.expectEqual(@as(u32, 0xFFFF_FFFF), std.mem.readInt(u32, body[228..232], .little)); // spell category cooldown
    try t.expectEqual(@as(u32, 0), std.mem.readInt(u32, body[445..449], .little)); // holiday_id
}

test "item query response marks unknown entries with the high bit" {
    const t = std.testing;

    const body = try (ItemQuerySingleResponseServer{ .entry = 12345, .def = null }).marshal(t.allocator);
    defer t.allocator.free(body);

    try t.expectEqual(@as(usize, 4), body.len);
    try t.expectEqual(@as(u32, 12345 | 0x8000_0000), std.mem.readInt(u32, body[0..4], .little));
}

test "item query single client reads the entry" {
    const t = std.testing;

    var payload: [4]u8 = undefined;
    std.mem.writeInt(u32, &payload, 6834, .little);

    const query = try ItemQuerySingleClient.unmarshal(&payload);
    try t.expectEqual(@as(u32, 6834), query.entry);
}
