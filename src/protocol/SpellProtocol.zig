//! Spell / combat wire packets (3.3.5a), exposed as `protocol.spell`.
//!
//! Transcribed from the 3.3.5a reference core: Spell.cpp (SendSpellStart /
//! SendSpellGo / SpellCastTargets), CombatHandler.cpp (attack start/stop),
//! Unit.cpp (SendAttackStateUpdate / SendSpellNonMeleeDamageLog /
//! SendMeleeAttackStart / SendMeleeAttackStop / SetSpeed) and
//! SpellAuras.cpp (AuraApplication::BuildUpdatePacket).

const std = @import("std");
const domain = @import("domain");
const ProtocolError = @import("./ProtocolError.zig").ProtocolErrorSet;

const ObjectGuid = domain.ObjectGuid;
const utils = @import("./ProtocolUtils.zig");
const world_protocol = @import("./WorldProtocol.zig");

// --- 3.3.5a wire constants -----------------------------------------------------

/// SpellCastTargetFlags: the unit-target bit. The client sends the target
/// guid packed when this is set.
pub const target_flag_unit: u32 = 0x00000002;

/// CastFlags written by SMSG_SPELL_START: marks trajectory data.
pub const cast_flag_has_trajectory: u32 = 0x00000002;
/// CastFlags written by SMSG_SPELL_GO; retail always sets it.
pub const cast_flag_unknown_9: u32 = 0x00000100;
/// CastFlags on CMSG_CAST_SPELL: projectile elevation/speed follow the
/// target block. We skip them; the server decides trajectories.
pub const client_cast_flag_projectile: u8 = 0x02;

/// SpellCastResult codes the server sends in SMSG_CAST_FAILED.
pub const CastFailedCode = enum(u8) {
    caster_dead = 23,
    interrupted = 40,
    bad_implicit_targets = 11,
    not_known = 63,
    out_of_range = 97,
    spell_in_progress = 105,
    targets_dead = 109,
};

/// AuraFlags for SMSG_AURA_UPDATE (AFLAG_*).
pub const aura_flag_eff_index_0: u8 = 0x01;
pub const aura_flag_positive: u8 = 0x10;
pub const aura_flag_duration: u8 = 0x20;
pub const aura_flag_negative: u8 = 0x80;

/// VictimState for a clean melee hit.
pub const victim_state_hit: u8 = 1;
/// HITINFO_NORMALSWING: no special flags on the hit.
pub const hit_info_normal_swing: u32 = 0x00000000;

// --- client -> server -----------------------------------------------------------

/// CMSG_CAST_SPELL (0x12E). The client follows the target block with
/// projectile elevation/speed for missile spells; we stop parsing after the
/// target and let trailing bytes through.
pub const CastSpellClient = struct {
    cast_count: u8,
    spell_id: u32,
    cast_flags: u8,
    target_guid: ?ObjectGuid,

    pub fn unmarshal(bytes: []const u8) ProtocolError!CastSpellClient {
        if (bytes.len < 10) return ProtocolError.InvalidMessage;

        var off: usize = 0;
        const cast_count = bytes[off];
        off += 1;
        const spell_id = readU32(bytes, &off);
        const cast_flags = bytes[off];
        off += 1;

        const target_mask = readU32(bytes, &off);

        var target_guid: ?ObjectGuid = null;
        if (target_mask & (target_flag_unit | 0x00010000 | 0x00000200 | 0x00008000) != 0) {
            const packed_read = ObjectGuid.fromPacked(bytes[off..]) catch return ProtocolError.InvalidMessage;
            target_guid = packed_read.guid;
        }
        // Trajectory payload (elevation/speed/movement block), coords and
        // string targets are intentionally ignored for v1.

        return .{
            .cast_count = cast_count,
            .spell_id = spell_id,
            .cast_flags = cast_flags,
            .target_guid = target_guid,
        };
    }
};

/// CMSG_ATTACKSWING (0x141): target guid as a **raw u64**. The client only
/// packs guids inside SpellCastTargets; simple query/combat packets carry
/// the full 8-byte guid (reference `operator>>(ByteBuffer&, ObjectGuid&)`).
pub const AttackSwingClient = struct {
    target_guid: ObjectGuid,

    pub fn unmarshal(bytes: []const u8) ProtocolError!AttackSwingClient {
        if (bytes.len < 8) return ProtocolError.InvalidMessage;
        const raw = std.mem.readInt(u64, bytes[0..8], .little);
        return .{ .target_guid = ObjectGuid.fromRaw(raw) };
    }
};

/// CMSG_CANCEL_CAST (0x12F): u8 cast counter (ignored) + u32 spell id.
pub const CancelCastClient = struct {
    spell_id: u32,

    pub fn unmarshal(bytes: []const u8) ProtocolError!CancelCastClient {
        if (bytes.len < 5) return ProtocolError.InvalidMessage;
        return .{ .spell_id = std.mem.readInt(u32, bytes[1..5], .little) };
    }
};

/// CMSG_ATTACKSTOP (0x142). The reference core does not read the payload.
pub const AttackStopClient = struct {
    pub fn unmarshal(bytes: []const u8) ProtocolError!AttackStopClient {
        _ = bytes;
        return .{};
    }
};

/// CMSG_SET_SHEATHED (0x1E0): the client drew/undrew the caster's weapons.
/// u32 SheathState (0 unarmed, 1 melee, 2 ranged); the reference core
/// stores it in UNIT_FIELD_BYTES_2 byte 0, which propagates the pose to
/// other clients.
pub const SetSheathedClient = struct {
    sheath_state: u8,

    pub fn unmarshal(bytes: []const u8) ProtocolError!SetSheathedClient {
        if (bytes.len < 4) return ProtocolError.InvalidMessage;
        const raw = std.mem.readInt(u32, bytes[0..4], .little);
        if (raw > 2) return ProtocolError.InvalidMessage;
        return .{ .sheath_state = @intCast(raw) };
    }
};

// --- server -> client -----------------------------------------------------------

/// Targets.Write for a unit-targeted spell: u32 mask + packed guid.
fn appendUnitTargets(out: *std.ArrayList(u8), gpa: std.mem.Allocator, target_guid: ObjectGuid) !void {
    try appendU32(out, gpa, target_flag_unit);
    try appendPackedGuid(out, gpa, target_guid);
}

/// SMSG_SPELL_START (0x131): the cast began; the client shows the cast bar
/// (its own Spell.dbc drives the visual) and missile anticipation.
pub const SpellStartServer = struct {
    pub const opcode: world_protocol.Opcode = .smsg_spell_start;

    caster_guid: ObjectGuid,
    cast_count: u8,
    spell_id: u32,
    /// Remaining cast time in ms; 0 for instant.
    delay_ms: i32,
    target_guid: ?ObjectGuid,

    pub fn marshal(self: SpellStartServer, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);

        try appendPackedGuid(&out, gpa, self.caster_guid); // cast item slot
        try appendPackedGuid(&out, gpa, self.caster_guid);
        try out.append(gpa, self.cast_count);
        try appendU32(&out, gpa, self.spell_id);
        try appendU32(&out, gpa, cast_flag_has_trajectory);
        try appendI32(&out, gpa, self.delay_ms);

        if (self.target_guid) |target| {
            try appendUnitTargets(&out, gpa, target);
        } else {
            try appendU32(&out, gpa, 0);
        }

        return out.toOwnedSlice(gpa);
    }
};

/// SMSG_SPELL_GO (0x132): the spell took effect; the client plays the
/// launch/impact visuals from its SpellVisual.dbc entry.
pub const SpellGoServer = struct {
    pub const opcode: world_protocol.Opcode = .smsg_spell_go;

    caster_guid: ObjectGuid,
    cast_count: u8,
    spell_id: u32,
    /// Server game time in ms when the effect fired.
    timestamp_ms: u32,
    /// Targets that were hit (v1: always hit, no miss list).
    hit_guids: []const ObjectGuid,
    target_guid: ?ObjectGuid,

    pub fn marshal(self: SpellGoServer, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);

        try appendPackedGuid(&out, gpa, self.caster_guid); // cast item slot
        try appendPackedGuid(&out, gpa, self.caster_guid);
        try out.append(gpa, self.cast_count);
        try appendU32(&out, gpa, self.spell_id);
        try appendU32(&out, gpa, cast_flag_unknown_9);
        try appendU32(&out, gpa, self.timestamp_ms);

        // WriteSpellGoTargets: u8 hit count + packed guids, u8 miss count.
        try out.append(gpa, @intCast(self.hit_guids.len));
        for (self.hit_guids) |guid| try appendPackedGuid(&out, gpa, guid);
        try out.append(gpa, 0); // miss count

        if (self.target_guid) |target| {
            try appendUnitTargets(&out, gpa, target);
        } else {
            try appendU32(&out, gpa, 0);
        }

        return out.toOwnedSlice(gpa);
    }
};

/// SMSG_CAST_FAILED (0x130): the cast was rejected; the client shows the
/// red error text.
pub const CastFailedServer = struct {
    pub const opcode: world_protocol.Opcode = .smsg_cast_failed;

    cast_count: u8,
    spell_id: u32,
    result: CastFailedCode,

    pub fn marshal(self: CastFailedServer, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.append(gpa, self.cast_count);
        try appendU32(&out, gpa, self.spell_id);
        try out.append(gpa, @intFromEnum(self.result));
        return out.toOwnedSlice(gpa);
    }
};

/// SMSG_SPELL_FAILURE (0x133) / SMSG_SPELL_FAILED_OTHER (0x2A6): broadcast
/// when a running cast is interrupted. These clear the casting animation
/// on *other* clients (a stationary interrupted caster emits no movement
/// packets that could do it). Both carry the same body in the reference
/// core; failure additionally shows the caster an error text.
fn appendInterruptedBody(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    caster_guid: ObjectGuid,
    cast_count: u8,
    spell_id: u32,
    result: CastFailedCode,
) !void {
    try appendPackedGuid(out, gpa, caster_guid);
    try out.append(gpa, cast_count);
    try appendU32(out, gpa, spell_id);
    try out.append(gpa, @intFromEnum(result));
}

pub const SpellFailureServer = struct {
    pub const opcode: world_protocol.Opcode = .smsg_spell_failure;

    caster_guid: ObjectGuid,
    cast_count: u8,
    spell_id: u32,
    result: CastFailedCode,

    pub fn marshal(self: SpellFailureServer, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try appendInterruptedBody(&out, gpa, self.caster_guid, self.cast_count, self.spell_id, self.result);
        return out.toOwnedSlice(gpa);
    }
};

pub const SpellFailedOtherServer = struct {
    pub const opcode: world_protocol.Opcode = .smsg_spell_failed_other;

    caster_guid: ObjectGuid,
    cast_count: u8,
    spell_id: u32,
    result: CastFailedCode,

    pub fn marshal(self: SpellFailedOtherServer, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try appendInterruptedBody(&out, gpa, self.caster_guid, self.cast_count, self.spell_id, self.result);
        return out.toOwnedSlice(gpa);
    }
};

/// SMSG_ATTACKSTART (0x143): raw (unpacked) guids, per the reference core.
pub const AttackStartServer = struct {
    pub const opcode: world_protocol.Opcode = .smsg_attackstart;

    attacker_guid: ObjectGuid,
    victim_guid: ObjectGuid,

    pub fn marshal(self: AttackStartServer, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try appendU64(&out, gpa, self.attacker_guid.valueOf());
        try appendU64(&out, gpa, self.victim_guid.valueOf());
        return out.toOwnedSlice(gpa);
    }
};

/// SMSG_ATTACKSTOP (0x144): packed guids + u32 dead flag.
pub const AttackStopServer = struct {
    pub const opcode: world_protocol.Opcode = .smsg_attackstop;

    attacker_guid: ObjectGuid,
    victim_guid: ?ObjectGuid,

    pub fn marshal(self: AttackStopServer, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try appendPackedGuid(&out, gpa, self.attacker_guid);
        if (self.victim_guid) |victim| {
            try appendPackedGuid(&out, gpa, victim);
            try appendU32(&out, gpa, 0); // victim is not dead
        }
        return out.toOwnedSlice(gpa);
    }
};

/// SMSG_ATTACKERSTATEUPDATE (0x14A): one melee sub-damage entry, no
/// absorb/resist/block flags on the hit info.
pub const AttackerStateUpdateServer = struct {
    pub const opcode: world_protocol.Opcode = .smsg_attackerstateupdate;

    school_mask: u32,
    attacker_guid: ObjectGuid,
    victim_guid: ObjectGuid,
    damage: u32,
    victim_state: u8 = victim_state_hit,

    pub fn marshal(self: AttackerStateUpdateServer, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);

        try appendU32(&out, gpa, hit_info_normal_swing);
        try appendPackedGuid(&out, gpa, self.attacker_guid);
        try appendPackedGuid(&out, gpa, self.victim_guid);
        try appendU32(&out, gpa, self.damage);
        try appendU32(&out, gpa, 0); // overkill
        try out.append(gpa, 1); // sub damage count
        try appendU32(&out, gpa, self.school_mask);
        try appendF32(&out, gpa, @floatFromInt(self.damage));
        try appendU32(&out, gpa, self.damage);
        try out.append(gpa, self.victim_state);
        try appendU32(&out, gpa, 0); // attacker state
        try appendU32(&out, gpa, 0); // melee spell id

        return out.toOwnedSlice(gpa);
    }
};

/// SMSG_SPELLNONMELEEDAMAGELOG (0x250): spell damage on a victim. The
/// hit-info u32 is written twice, matching the reference core.
pub const SpellNonMeleeDamageServer = struct {
    pub const opcode: world_protocol.Opcode = .smsg_spellnonmeleedamagelog;

    victim_guid: ObjectGuid,
    attacker_guid: ObjectGuid,
    spell_id: u32,
    damage: u32,
    /// SpellSchoolMask (physical = 0x01, frost = 0x10, ...).
    school_mask: u8,

    pub fn marshal(self: SpellNonMeleeDamageServer, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);

        try appendPackedGuid(&out, gpa, self.victim_guid);
        try appendPackedGuid(&out, gpa, self.attacker_guid);
        try appendU32(&out, gpa, self.spell_id);
        try appendU32(&out, gpa, self.damage);
        try appendU32(&out, gpa, 0); // overkill
        try out.append(gpa, self.school_mask);
        try appendU32(&out, gpa, 0); // absorbed
        try appendU32(&out, gpa, 0); // resisted
        try out.append(gpa, 0); // physical log flag
        try out.append(gpa, 0); // unused
        try appendU32(&out, gpa, 0); // blocked
        try appendU32(&out, gpa, hit_info_normal_swing);
        try appendU32(&out, gpa, hit_info_normal_swing);
        try out.append(gpa, 0); // debug hit-type bits

        return out.toOwnedSlice(gpa);
    }
};

/// SMSG_AURA_UPDATE (0x496): one aura slot on one unit. `remove = true`
/// clears the slot (spell id 0 on the wire); otherwise the spell, caster
/// and remaining duration are sent.
pub const AuraUpdateServer = struct {
    pub const opcode: world_protocol.Opcode = .smsg_aura_update;

    target_guid: ObjectGuid,
    slot: u8,
    spell_id: u32 = 0,
    /// AFLAG_* bits; the caster guid is appended unless aura_flag caster
    /// (0x08) is set, durations unless aura_flag_duration (0x20) is clear.
    flags: u8 = aura_flag_eff_index_0 | aura_flag_negative | aura_flag_duration,
    caster_level: u8 = 1,
    stacks: u8 = 1,
    caster_guid: ObjectGuid = ObjectGuid.empty,
    max_duration_ms: u32 = 0,
    remaining_ms: u32 = 0,

    pub fn remove(target_guid: ObjectGuid, slot: u8) AuraUpdateServer {
        return .{ .target_guid = target_guid, .slot = slot };
    }

    pub fn marshal(self: AuraUpdateServer, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);

        try appendPackedGuid(&out, gpa, self.target_guid);
        try out.append(gpa, self.slot);
        if (self.spell_id == 0) {
            try appendU32(&out, gpa, 0);
            return out.toOwnedSlice(gpa);
        }

        try appendU32(&out, gpa, self.spell_id);
        try out.append(gpa, self.flags);
        try out.append(gpa, self.caster_level);
        try out.append(gpa, self.stacks);
        if (self.flags & 0x08 == 0) {
            try appendPackedGuid(&out, gpa, self.caster_guid);
        }
        if (self.flags & 0x20 != 0) {
            try appendU32(&out, gpa, self.max_duration_ms);
            try appendU32(&out, gpa, self.remaining_ms);
        }
        return out.toOwnedSlice(gpa);
    }
};

/// SMSG_FORCE_RUN_SPEED_CHANGE (0x0E2): movement speed the client should
/// use for the unit (its own if it is the mover).
pub const ForceRunSpeedChangeServer = struct {
    pub const opcode: world_protocol.Opcode = .smsg_force_run_speed_change;

    guid: ObjectGuid,
    /// Base run speed is 7.0; slowed units get rate * (1 - slow%).
    speed: f32,

    pub fn marshal(self: ForceRunSpeedChangeServer, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try appendPackedGuid(&out, gpa, self.guid);
        try appendU32(&out, gpa, 0); // moveEvent, NUM_PMOVE_EVTS
        try out.append(gpa, 0); // 2.1.0 addition
        try appendF32(&out, gpa, self.speed);
        return out.toOwnedSlice(gpa);
    }
};

// --- helpers ---------------------------------------------------------------------

fn appendPackedGuid(out: *std.ArrayList(u8), gpa: std.mem.Allocator, guid: ObjectGuid) !void {
    const packed_guid = guid.toPacked();
    try out.appendSlice(gpa, packed_guid.slice());
}

fn appendU32(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try out.appendSlice(gpa, &buf);
}

fn appendU64(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, v, .little);
    try out.appendSlice(gpa, &buf);
}

fn appendI32(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: i32) !void {
    try appendU32(out, gpa, @bitCast(v));
}

fn appendF32(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: f32) !void {
    try appendU32(out, gpa, @bitCast(v));
}

fn readU32(bytes: []const u8, off: *usize) u32 {
    const value = std.mem.readInt(u32, bytes[off.*..][0..4], .little);
    off.* += 4;
    return value;
}

// --- tests -----------------------------------------------------------------------

test "cast spell client reads unit target and skips trajectory bytes" {
    const t = std.testing;

    const caster = ObjectGuid.player(0x1234);

    // cast_count=1, spell 116, flags with projectile bit, mask UNIT,
    // packed guid, then trajectory elevation/speed + movement flag.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(t.allocator);
    try body.append(t.allocator, 1);
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(u32, &tmp, 116, .little);
    try body.appendSlice(t.allocator, &tmp);
    try body.append(t.allocator, 0x02);
    std.mem.writeInt(u32, &tmp, target_flag_unit, .little);
    try body.appendSlice(t.allocator, &tmp);
    try body.appendSlice(t.allocator, caster.toPacked().slice());
    std.mem.writeInt(u32, &tmp, @bitCast(@as(f32, 0.5)), .little);
    try body.appendSlice(t.allocator, &tmp);
    std.mem.writeInt(u32, &tmp, @bitCast(@as(f32, 30.0)), .little);
    try body.appendSlice(t.allocator, &tmp);
    try body.append(t.allocator, 0); // no movement data

    const parsed = try CastSpellClient.unmarshal(body.items);
    try t.expectEqual(@as(u8, 1), parsed.cast_count);
    try t.expectEqual(@as(u32, 116), parsed.spell_id);
    try t.expectEqual(@as(u8, 0x02), parsed.cast_flags);
    try t.expectEqual(caster.valueOf(), parsed.target_guid.?.valueOf());
}

test "attack swing client reads the raw u64 target guid" {
    const t = std.testing;

    // The client sends full 8-byte guids here, NOT packed form (observed
    // on wire: `02 00 00 00 00 00 00 00` for player 2).
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, 2, .little);

    const parsed = try AttackSwingClient.unmarshal(&buf);
    try t.expectEqual(@as(u64, 2), parsed.target_guid.valueOf());
}

test "spell interrupted packets carry caster, cast count, spell and result" {
    const t = std.testing;
    const gpa = t.allocator;

    const caster = ObjectGuid.player(3);
    const failure = try (SpellFailureServer{
        .caster_guid = caster,
        .cast_count = 2,
        .spell_id = 116,
        .result = .interrupted,
    }).marshal(gpa);
    defer gpa.free(failure);

    const other = try (SpellFailedOtherServer{
        .caster_guid = caster,
        .cast_count = 2,
        .spell_id = 116,
        .result = .interrupted,
    }).marshal(gpa);
    defer gpa.free(other);

    // Identical bodies per the reference core.
    const packed_caster = caster.toPacked().slice();
    try t.expectEqualSlices(u8, packed_caster, failure[0..packed_caster.len]);
    try t.expectEqual(@as(u8, 2), failure[packed_caster.len]);
    try t.expectEqual(@as(u32, 116), std.mem.readInt(u32, failure[packed_caster.len + 1 ..][0..4], .little));
    try t.expectEqual(@as(u8, 40), failure[packed_caster.len + 5]); // SPELL_FAILED_INTERRUPTED
    try t.expectEqual(packed_caster.len + 6, failure.len);
    try t.expectEqualSlices(u8, failure, other);
}

test "cancel cast skips the counter and reads the spell id" {
    const t = std.testing;

    var buf: [5]u8 = undefined;
    buf[0] = 3; // cast counter, ignored
    std.mem.writeInt(u32, buf[1..5], 116, .little);

    const parsed = try CancelCastClient.unmarshal(&buf);
    try t.expectEqual(@as(u32, 116), parsed.spell_id);
}

test "set sheathed reads the u32 state and rejects unknown states" {
    const t = std.testing;

    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, 1, .little);
    const parsed = try SetSheathedClient.unmarshal(&buf);
    try t.expectEqual(@as(u8, 1), parsed.sheath_state);

    std.mem.writeInt(u32, &buf, 3, .little);
    try t.expectError(ProtocolError.InvalidMessage, SetSheathedClient.unmarshal(&buf));
}

test "cast spell client accepts self cast without target" {
    const t = std.testing;

    // 6 header bytes + 4 mask bytes, no target guid.
    var buf: [10]u8 = undefined;
    buf[0] = 0;
    std.mem.writeInt(u32, buf[1..][0..4], 6603, .little);
    buf[5] = 0;
    std.mem.writeInt(u32, buf[6..][0..4], 0, .little);

    const parsed = try CastSpellClient.unmarshal(&buf);
    try t.expectEqual(@as(u32, 6603), parsed.spell_id);
    try t.expect(parsed.target_guid == null);
}

test "spell go dumps caster, hit targets and unit target" {
    const t = std.testing;
    const gpa = t.allocator;

    const caster = ObjectGuid.player(7);
    const victim = ObjectGuid.player(9);
    const body = try (SpellGoServer{
        .caster_guid = caster,
        .cast_count = 3,
        .spell_id = 116,
        .timestamp_ms = 0xAABBCCDD,
        .hit_guids = &.{victim},
        .target_guid = victim,
    }).marshal(gpa);
    defer gpa.free(body);

    // Caster guid packed twice (cast item slot + caster).
    const packed_caster = caster.toPacked().slice();
    const packed_victim = victim.toPacked().slice();
    var off: usize = 0;
    try t.expectEqualSlices(u8, packed_caster, body[off..][0..packed_caster.len]);
    off += packed_caster.len;
    try t.expectEqualSlices(u8, packed_caster, body[off..][0..packed_caster.len]);
    off += packed_caster.len;
    off += 1; // cast_count
    try t.expectEqual(@as(u8, 3), body[off - 1]);
    try t.expectEqual(@as(u32, 116), std.mem.readInt(u32, body[off..][0..4], .little));
    off += 4;
    try t.expectEqual(cast_flag_unknown_9, std.mem.readInt(u32, body[off..][0..4], .little));
    off += 4;
    try t.expectEqual(@as(u32, 0xAABBCCDD), std.mem.readInt(u32, body[off..][0..4], .little));
    off += 4;
    // hit count 1 + packed victim + miss count 0.
    try t.expectEqual(@as(u8, 1), body[off]);
    off += 1;
    try t.expectEqualSlices(u8, packed_victim, body[off..][0..packed_victim.len]);
    off += packed_victim.len;
    try t.expectEqual(@as(u8, 0), body[off]); // miss count
    off += 1;
    try t.expectEqual(target_flag_unit, std.mem.readInt(u32, body[off..][0..4], .little));
    off += 4;
    try t.expectEqualSlices(u8, packed_victim, body[off..][0..packed_victim.len]);
    off += packed_victim.len;
    try t.expectEqual(off, body.len);
}

test "aura update remove writes a zero spell id" {
    const t = std.testing;
    const gpa = t.allocator;

    const target = ObjectGuid.player(2);
    const body = try AuraUpdateServer.remove(target, 4).marshal(gpa);
    defer gpa.free(body);

    const packed_target = target.toPacked().slice();
    try t.expectEqualSlices(u8, packed_target, body[0..packed_target.len]);
    try t.expectEqual(@as(u8, 4), body[packed_target.len]);
    try t.expectEqual(@as(u32, 0), std.mem.readInt(u32, body[packed_target.len + 1 ..][0..4], .little));
    try t.expectEqual(@as(usize, packed_target.len + 5), body.len);
}

test "aura update apply writes flags, caster and durations" {
    const t = std.testing;
    const gpa = t.allocator;

    const target = ObjectGuid.player(2);
    const caster = ObjectGuid.player(5);
    const body = try (AuraUpdateServer{
        .target_guid = target,
        .slot = 0,
        .spell_id = 116,
        .caster_guid = caster,
        .max_duration_ms = 5000,
        .remaining_ms = 4900,
    }).marshal(gpa);
    defer gpa.free(body);

    var off: usize = target.toPacked().len;
    try t.expectEqual(@as(u8, 0), body[off]);
    off += 1;
    try t.expectEqual(@as(u32, 116), std.mem.readInt(u32, body[off..][0..4], .little));
    off += 4;
    try t.expectEqual(aura_flag_eff_index_0 | aura_flag_negative | aura_flag_duration, body[off]);
    off += 1;
    try t.expectEqual(@as(u8, 1), body[off]); // caster level
    off += 1;
    try t.expectEqual(@as(u8, 1), body[off]); // stacks
    off += 1;
    const packed_caster = caster.toPacked().slice();
    try t.expectEqualSlices(u8, packed_caster, body[off..][0..packed_caster.len]);
    off += packed_caster.len;
    try t.expectEqual(@as(u32, 5000), std.mem.readInt(u32, body[off..][0..4], .little));
    off += 4;
    try t.expectEqual(@as(u32, 4900), std.mem.readInt(u32, body[off..][0..4], .little));
    off += 4;
    try t.expectEqual(off, body.len);
}

test "attacker state update carries the sub damage entry" {
    const t = std.testing;
    const gpa = t.allocator;

    const attacker = ObjectGuid.player(1);
    const victim = ObjectGuid.player(2);
    const body = try (AttackerStateUpdateServer{
        .school_mask = 1,
        .attacker_guid = attacker,
        .victim_guid = victim,
        .damage = 2,
    }).marshal(gpa);
    defer gpa.free(body);

    try t.expectEqual(hit_info_normal_swing, std.mem.readInt(u32, body[0..4], .little));
    const packed_attacker = attacker.toPacked().slice();
    const packed_victim = victim.toPacked().slice();
    var off: usize = 4;
    try t.expectEqualSlices(u8, packed_attacker, body[off..][0..packed_attacker.len]);
    off += packed_attacker.len;
    try t.expectEqualSlices(u8, packed_victim, body[off..][0..packed_victim.len]);
    off += packed_victim.len;
    try t.expectEqual(@as(u32, 2), std.mem.readInt(u32, body[off..][0..4], .little)); // damage
    off += 4;
    try t.expectEqual(@as(u32, 0), std.mem.readInt(u32, body[off..][0..4], .little)); // overkill
    off += 4;
    try t.expectEqual(@as(u8, 1), body[off]); // sub count
    off += 1;
    try t.expectEqual(@as(u32, 1), std.mem.readInt(u32, body[off..][0..4], .little)); // school
    off += 4;
    try t.expectEqual(@as(u32, @bitCast(@as(f32, 2.0))), std.mem.readInt(u32, body[off..][0..4], .little)); // f32 damage
    off += 4;
    try t.expectEqual(@as(u32, 2), std.mem.readInt(u32, body[off..][0..4], .little)); // u32 damage
    off += 4;
    try t.expectEqual(victim_state_hit, body[off]);
    off += 1;
    try t.expectEqual(off + 8, body.len); // attacker state + melee spell id
}

test "spell non melee damage log duplicates hit info" {
    const t = std.testing;
    const gpa = t.allocator;

    const attacker = ObjectGuid.player(1);
    const victim = ObjectGuid.player(2);
    const body = try (SpellNonMeleeDamageServer{
        .victim_guid = victim,
        .attacker_guid = attacker,
        .spell_id = 116,
        .damage = 19,
        .school_mask = 16,
    }).marshal(gpa);
    defer gpa.free(body);

    const packed_victim = victim.toPacked().slice();
    const packed_attacker = attacker.toPacked().slice();
    var off: usize = 0;
    try t.expectEqualSlices(u8, packed_victim, body[off..][0..packed_victim.len]);
    off += packed_victim.len;
    try t.expectEqualSlices(u8, packed_attacker, body[off..][0..packed_attacker.len]);
    off += packed_attacker.len;
    try t.expectEqual(@as(u32, 116), std.mem.readInt(u32, body[off..][0..4], .little));
    off += 4;
    try t.expectEqual(@as(u32, 19), std.mem.readInt(u32, body[off..][0..4], .little));
    off += 4;
    try t.expectEqual(@as(u32, 0), std.mem.readInt(u32, body[off..][0..4], .little)); // overkill
    off += 4;
    try t.expectEqual(@as(u8, 16), body[off]); // school
    off += 1;
    // absorb, resist, physicalLog, unused, blocked, hitInfo, hitInfo, debug.
    try t.expectEqual(off + 4 + 4 + 1 + 1 + 4 + 4 + 4 + 1, body.len);
    try t.expectEqual(@as(u32, 0), std.mem.readInt(u32, body[body.len - 9 ..][0..4], .little));
    try t.expectEqual(@as(u32, 0), std.mem.readInt(u32, body[body.len - 5 ..][0..4], .little));
}

test "cast failed carries the result code" {
    const t = std.testing;
    const gpa = t.allocator;

    const body = try (CastFailedServer{ .cast_count = 2, .spell_id = 116, .result = .out_of_range }).marshal(gpa);
    defer gpa.free(body);

    try t.expectEqualSlices(u8, &.{ 2, 116, 0, 0, 0, 97 }, body);
}

test "force run speed change appends the 2.1.0 padding byte" {
    const t = std.testing;
    const gpa = t.allocator;

    const mover = ObjectGuid.player(4);
    const body = try (ForceRunSpeedChangeServer{ .guid = mover, .speed = 4.2 }).marshal(gpa);
    defer gpa.free(body);

    const packed_mover = mover.toPacked().slice();
    try t.expectEqualSlices(u8, packed_mover, body[0..packed_mover.len]);
    var off: usize = packed_mover.len;
    try t.expectEqual(@as(u32, 0), std.mem.readInt(u32, body[off..][0..4], .little));
    off += 4;
    try t.expectEqual(@as(u8, 0), body[off]);
    off += 1;
    try t.expectEqual(@as(u32, @bitCast(@as(f32, 4.2))), std.mem.readInt(u32, body[off..][0..4], .little));
    off += 4;
    try t.expectEqual(off, body.len);
}

test "attack start uses raw guids while attack stop packs them" {
    const t = std.testing;
    const gpa = t.allocator;

    const attacker = ObjectGuid.player(1);
    const victim = ObjectGuid.player(2);

    const start = try (AttackStartServer{ .attacker_guid = attacker, .victim_guid = victim }).marshal(gpa);
    defer gpa.free(start);
    try t.expectEqual(@as(usize, 16), start.len);
    try t.expectEqual(@as(u64, 1), std.mem.readInt(u64, start[0..8], .little));
    try t.expectEqual(@as(u64, 2), std.mem.readInt(u64, start[8..16], .little));

    const stop = try (AttackStopServer{ .attacker_guid = attacker, .victim_guid = victim }).marshal(gpa);
    defer gpa.free(stop);
    const packed_attacker_stop = attacker.toPacked().slice();
    const packed_victim_stop = victim.toPacked().slice();
    var off: usize = 0;
    try t.expectEqualSlices(u8, packed_attacker_stop, stop[off..][0..packed_attacker_stop.len]);
    off += packed_attacker_stop.len;
    try t.expectEqualSlices(u8, packed_victim_stop, stop[off..][0..packed_victim_stop.len]);
    off += packed_victim_stop.len;
    try t.expectEqual(@as(u32, 0), std.mem.readInt(u32, stop[off..][0..4], .little));
    try t.expectEqual(off + 4, stop.len);
}
