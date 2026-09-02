//! SMSG_UPDATE_OBJECT (0x0A9) wire construction.
//!
//! The packet is a block list: a u32 block count followed by that many
//! update blocks. Each block's update type selects its wire shape, and the
//! VALUES/CREATE blocks carry positional field masks that flag which field
//! datums follow (field index = block * 32 + bit).
//!
//! Wire layout (3.3.5a), TS-ish (PackedGuid = ObjectGuid packed wire bytes, 1..9):
//!
//! {
//!   block_count: u32;
//!   blocks: (
//!     | { type: 0; /* VALUES */
//!         guid: PackedGuid;
//!         fields: {
//!           block_count: u8;
//!           masks: u32[block_count];  // field = block * 32 + bit
//!           values: u32[];            // ascending, one per set bit
//!         } }
//!     | { type: 1; /* MOVEMENT */
//!         guid: PackedGuid;
//!         section: {
//!           flags: u16;
//!           living?: { info: MovementInfo; speeds: f32[9] };      // 0x20
//!           position?: {
//!             transport?: PackedGuid; // else 0x00
//!             x: f32; y: f32; z: f32; // world
//!             trans?: f32[3];         // else world xyz repeated
//!             o: f32;
//!             corpse?: f32;           // else 0
//!           };                                                     // 0x100
//!           stationary_position?: f32[4];                          // 0x40
//!           unknown?: u32;                                         // 0x08
//!           low_guid?: u32;                                        // 0x10
//!           has_target?: PackedGuid;                               // 0x04
//!           transport?: u32;                                       // 0x02
//!           vehicle?: { vehicle_id: u32; orientation: f32 };       // 0x80
//!           rotation?: i64;                                        // 0x200
//!         } }
//!     | { type: 2; /* CREATE_OBJECT */
//!         guid: PackedGuid;
//!         object_type: u8; // ObjectTypeId
//!         section: { flags: u16;
//!           living?: { info: MovementInfo; speeds: f32[9] };
//!           position?: { transport?: PackedGuid; x: f32; y: f32; z: f32; trans?: f32[3]; o: f32; corpse?: f32 };
//!           stationary_position?: f32[4]; unknown?: u32; low_guid?: u32;
//!           has_target?: PackedGuid; transport?: u32;
//!           vehicle?: { vehicle_id: u32; orientation: f32 }; rotation?: i64; };
//!         fields: { block_count: u8; masks: u32[block_count]; values: u32[] } }
//!     | { type: 3; /* CREATE_OBJECT2 */ // same as CREATE_OBJECT
//!         guid: PackedGuid; object_type: u8;
//!         section: { flags: u16;
//!           living?: { info: MovementInfo; speeds: f32[9] };
//!           position?: { transport?: PackedGuid; x: f32; y: f32; z: f32; trans?: f32[3]; o: f32; corpse?: f32 };
//!           stationary_position?: f32[4]; unknown?: u32; low_guid?: u32;
//!           has_target?: PackedGuid; transport?: u32;
//!           vehicle?: { vehicle_id: u32; orientation: f32 }; rotation?: i64; };
//!         fields: { block_count: u8; masks: u32[block_count]; values: u32[] } }
//!     | { type: 4; /* OUT_OF_RANGE_OBJECTS */
//!         count: u32; guids: PackedGuid[] }
//!     | { type: 5; /* NEAR_OBJECTS */
//!         count: u32; guids: PackedGuid[] }
//!   )[];
//! }
//!
//! MovementSection optionals are flag-gated, emitted in this fixed order.

const std = @import("std");
const domain = @import("domain");
const movement = @import("./Movement.zig");
const stdx = @import("stdx");
const world_protocol = @import("./WorldProtocol.zig");

const ObjectGuid = domain.ObjectGuid;

// --- public API ---------------------------------------------------------------

/// SMSG_UPDATE_OBJECT. 1 opcode = 1 struct; blocks is a heap list so the
/// block count is bounded only by the transport's packet size, not by a
/// fixed stack array.
pub const UpdateObject = struct {
    blocks: std.ArrayList(UpdateBlock),

    pub const opcode: world_protocol.Opcode = .smsg_update_object;
    const Self = @This();

    pub fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!Self {
        const blocks: std.ArrayList(UpdateBlock) = try .initCapacity(gpa, 4);
        return .{ .blocks = blocks };
    }

    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        self.blocks.deinit(gpa);
    }

    pub fn add(self: *Self, gpa: std.mem.Allocator, block: UpdateBlock) std.mem.Allocator.Error!void {
        try self.blocks.append(gpa, block);
    }

    pub fn marshal(self: Self, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);

        try appendU32(&out, gpa, @intCast(self.blocks.items.len));
        for (self.blocks.items) |block| try appendSegment(&out, gpa, block);

        return out.toOwnedSlice(gpa);
    }

    pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("object.UpdateObject{{ blocks={d} }}", .{self.blocks.items.len});
    }
};

/// The u8 tag at the head of each block; selects the block's wire shape.
pub const UpdateType = enum(u8) {
    /// Patch a few fields on an object the client already knows (health,
    /// power, ...). The client reads the mask and updates only those
    /// fields; no entity is created. Cheap path for frequent changes.
    values = 0,
    /// Position-only refresh for a known object, without a create block
    /// and without a dedicated MSG_MOVE opcode.
    movement = 1,
    /// Full introduction of an object the client has never seen; the
    /// client spawns a new entity from the field block.
    create_object = 2,
    /// Byte-identical to create_object, but the client first removes any
    /// entity already carrying this guid, then spawns fresh. Used for
    /// players and anything that may need a clean rebuild (pets, corpses,
    /// traps, flag stands).
    create_object2 = 3,
    /// Guids the client should stop tracking (despawned / out of range).
    /// The client deletes those entities.
    out_of_range_objects = 4,
    /// Guids entering the client's awareness. Rarely emitted; the client
    /// usually learns about new objects through create blocks.
    near_objects = 5,
};

/// Which kind of entity the client spawns for a CREATE block.
pub const ObjectTypeId = enum(u8) {
    object = 0,
    item = 1,
    container = 2,
    unit = 3,
    player = 4,
    game_object = 5,
    dynamic_object = 6,
    corpse = 7,

    /// The OBJECT_FIELD_TYPE bitmask the client expects for this type
    /// (players also carry the unit bits).
    pub fn mask(self: ObjectTypeId) u32 {
        return switch (self) {
            .object => 0x0001,
            .item => 0x0001 | 0x0002,
            .container => 0x0001 | 0x0002 | 0x0004,
            .unit => 0x0001 | 0x0008,
            .player => 0x0001 | 0x0008 | 0x0010,
            .game_object => 0x0001 | 0x0020,
            .dynamic_object => 0x0001 | 0x0040,
            .corpse => 0x0001 | 0x0080,
        };
    }
};

/// Static placement for an object that never moves (chest, door, ...).
/// The client does not simulate it, just renders it at these coordinates.
pub const Stationary = struct {
    x: f32,
    y: f32,
    z: f32,
    orientation: f32,
};

/// For an object that rides a transport (a gameobject bolted to a moving
/// platform, boat, zeppelin). The client derives the world position from
/// the transport guid + offset so the object moves with its carrier.
pub const PositionData = struct {
    /// Transport guid; when null the wire writes a single 0x00 byte and
    /// repeats the world x/y/z in the offset slot.
    transport: ?ObjectGuid = null,
    x: f32,
    y: f32,
    z: f32,
    /// Offset relative to the transport, only written when transport is set.
    transport_offset_x: f32 = 0,
    transport_offset_y: f32 = 0,
    transport_offset_z: f32 = 0,
    orientation: f32,
    /// Corpses re-write orientation in the trailing slot; everything else
    /// writes f32(0).
    corpse: bool = false,
};

/// Mount/vehicle data. The client uses the vehicle id to know the
/// vehicle's capabilities and seats the unit in it.
pub const Vehicle = struct {
    vehicle_id: u32,
    orientation: f32,
};

/// The flag-gated movement section shared by MOVEMENT and CREATE blocks.
/// Each optional field maps to one update flag: field presence derives the
/// flag bits and gates the corresponding datum group.
pub const MovementSection = struct {
    /// This object is the one the receiving client controls. The client
    /// binds camera, controls and UI to it. Only set for your own character.
    self: bool = false,

    /// The object is an animated unit (player/creature/pet): full
    /// MovementInfo so the client can interpolate its motion, plus the 9
    /// speeds the client uses to track and predict that unit's movement.
    living: ?movement.MovementInfo = null,
    speeds: [9]f32 = base_speeds,

    /// Static placement for non-moving objects (see Stationary). Ignored
    /// by the client when living is set.
    stationary_position: ?Stationary = null,

    /// Object rides a transport (see PositionData).
    position: ?PositionData = null,

    /// Always a u32 zero. Emitted for wire fidelity; the client reads and
    /// discards it.
    unknown: bool = false,

    /// Short-form guid low for objects whose full guid was not packed; the
    /// client stitches it into the guid. The per-type constants it expects
    /// are documented on update_flag_low_guid.
    low_guid: ?u32 = null,

    /// The unit is currently attacking a victim; the client draws the
    /// target marker and keeps combat UI in sync with it.
    has_target: ?ObjectGuid = null,

    /// Path progress for a transport gameobject; the client positions the
    /// transport along its route.
    transport: ?u32 = null,

    /// Vehicle capability id + facing (see Vehicle).
    vehicle: ?Vehicle = null,

    /// Packed world rotation for gameobject models (e.g. doors).
    rotation: ?i64 = null,

    /// Writes the u16 flags, then each flag-gated datum group in the fixed
    /// order the client expects: LIVING, POSITION, STATIONARY_POSITION,
    /// UNKNOWN, LOWGUID, HAS_TARGET, TRANSPORT, VEHICLE, ROTATION.
    pub fn marshal(self: MovementSection, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);

        try appendU16(&out, gpa, self.bits());

        if (self.living) |info| {
            try movement.appendMovementInfo(&out, gpa, info);
            for (self.speeds) |speed| try appendF32(&out, gpa, speed);
            // TODO: if info.flags carries SPLINE_ENABLED the client also
            // expects move spline data here; not needed for player arena scope.
        } else if (self.position) |pos| {
            if (pos.transport) |transport_guid| {
                try writePackedGuid(&out, gpa, transport_guid);
            } else {
                try out.append(gpa, 0);
            }
            try appendF32(&out, gpa, pos.x);
            try appendF32(&out, gpa, pos.y);
            try appendF32(&out, gpa, pos.z);
            if (pos.transport != null) {
                try appendF32(&out, gpa, pos.transport_offset_x);
                try appendF32(&out, gpa, pos.transport_offset_y);
                try appendF32(&out, gpa, pos.transport_offset_z);
            } else {
                try appendF32(&out, gpa, pos.x);
                try appendF32(&out, gpa, pos.y);
                try appendF32(&out, gpa, pos.z);
            }
            try appendF32(&out, gpa, pos.orientation);
            if (pos.corpse) {
                try appendF32(&out, gpa, pos.orientation);
            } else {
                try appendF32(&out, gpa, 0);
            }
        } else if (self.stationary_position) |stationary| {
            try appendF32(&out, gpa, stationary.x);
            try appendF32(&out, gpa, stationary.y);
            try appendF32(&out, gpa, stationary.z);
            try appendF32(&out, gpa, stationary.orientation);
        }

        if (self.unknown) try appendU32(&out, gpa, 0);

        if (self.low_guid) |low| try appendU32(&out, gpa, low);

        if (self.has_target) |victim| try writePackedGuid(&out, gpa, victim);

        if (self.transport) |progress| try appendU32(&out, gpa, progress);

        if (self.vehicle) |vehicle| {
            try appendU32(&out, gpa, vehicle.vehicle_id);
            try appendF32(&out, gpa, vehicle.orientation);
        }

        if (self.rotation) |rotation| try appendI64(&out, gpa, rotation);

        return out.toOwnedSlice(gpa);
    }

    fn bits(self: MovementSection) u16 {
        var flags: u16 = 0;
        if (self.self) flags |= update_flag_self;
        if (self.living != null) flags |= update_flag_living;
        if (self.stationary_position != null) flags |= update_flag_stationary_position;
        if (self.position != null) flags |= update_flag_position;
        if (self.unknown) flags |= update_flag_unknown;
        if (self.low_guid != null) flags |= update_flag_low_guid;
        if (self.has_target != null) flags |= update_flag_has_target;
        if (self.transport != null) flags |= update_flag_transport;
        if (self.vehicle != null) flags |= update_flag_vehicle;
        if (self.rotation != null) flags |= update_flag_rotation;
        return flags;
    }
};

/// Update-field index dictionaries. These encode the client's update-field
/// layout so `Fields.set` can name indices instead of spelling raw numbers.
pub const ObjectField = enum(u16) {
    /// 64-bit guid, spans `guid` and `guid_hi`.
    guid = 0,
    guid_hi = 1,
    type = 2,
    /// OBJECT_FIELD_ENTRY. Holds the display id for gameobjects.
    entry = 3,
    scale_x = 4,
    // Non-exhaustive: the client accepts any index in range.
    _,
};

pub const UnitField = enum(u16) {
    bytes_0 = 23,
    health = 24,
    power_1 = 25,
    max_health = 32,
    max_power_1 = 33,
    level = 54,
    faction_template = 55,
    display_id = 67,
    native_display_id = 68,
    bytes_2 = 122,
    // Non-exhaustive: the client accepts any index in range.
    _,

    /// UNIT_FIELD_POWER1 shifted by power type (0..6).
    pub fn power(power_type: u8) UnitField {
        return @enumFromInt(@intFromEnum(UnitField.power_1) + power_type);
    }

    /// UNIT_FIELD_MAXPOWER1 shifted by power type (0..6).
    pub fn maxPower(power_type: u8) UnitField {
        return @enumFromInt(@intFromEnum(UnitField.max_power_1) + power_type);
    }
};

pub const PlayerField = enum(u16) {
    /// Packed appearance the client renders on the character: skin, face,
    /// hair style, hair color.
    appearance = 153,
    /// Facial hair style the client renders (byte 0); other bytes stay zero.
    facial_hair = 154,
    /// Gender the client uses to pick the model (byte 0); other bytes stay zero.
    gender = 155,
    visible_item_1_entry_id = 283,
    /// Skill book the client uses to build the skill pane and decide which
    /// languages are available for chat. Every skill line is 3 consecutive
    /// fields holding (id,step), (value,max), bonus; use skillBook() to
    /// address a slot.
    skill_book_base = 636,
    // Non-exhaustive: the client accepts any index in range.
    _,

    /// PLAYER_VISIBLE_ITEM_1_ENTRY shifted by equipment slot (0..18).
    pub fn visibleItemEntry(slot: u8) PlayerField {
        return @enumFromInt(@intFromEnum(PlayerField.visible_item_1_entry_id) + @as(u16, slot) * 2);
    }

    /// Field index of the given skill-book slot and sub-field (see
    /// SkillBookPart). Slot 0 is the first skill-line entry.
    pub fn skillBook(slot: u8, part: SkillBookPart) PlayerField {
        return @enumFromInt(@intFromEnum(PlayerField.skill_book_base) + @as(u16, slot) * 3 + @intFromEnum(part));
    }
};

/// The 3 update fields that make up one skill-line entry in the skill book.
/// Together they tell the client which skills exist, their level, and any
/// bonus, which drives the skill pane and language selection.
pub const SkillBookPart = enum(u16) {
    /// Low u16 = skill id (e.g. 98 = Common), high u16 = skill step.
    id_step = 0,
    /// Low u16 = current value, high u16 = maximum value (300/300 for languages).
    value_max = 1,
    /// Skill bonus (temporary in low u16, permanent in high u16).
    bonus = 2,
};

/// The update-mask side of VALUES/CREATE blocks. `values[i]` is the datum
/// for field i; the writer derives block_count + masks + ascending values.
/// Value type: copy the whole set freely.
pub const Fields = struct {
    values: [field_capacity]?u32 = .{null} ** field_capacity,

    pub fn set(self: *Fields, field: anytype, value: u32) void {
        self.values[fieldIndex(field)] = value;
    }

    /// Writes block_count + masks + ascending values; the exact size is
    /// known up front, so this is a single allocation.
    pub fn marshal(self: Fields, gpa: std.mem.Allocator) ![]u8 {
        const block_count = self.blockCount();
        const value_count = self.countSet();
        const out = try gpa.alloc(u8, 1 + block_count * 4 + value_count * 4);
        out[0] = block_count;

        for (0..block_count) |block| {
            var mask: u32 = 0;
            for (0..32) |bit| {
                if (self.values[block * 32 + bit] != null)
                    mask |= @as(u32, 1) << @intCast(bit);
            }
            std.mem.writeInt(u32, out[1 + block * 4 ..][0..4], mask, .little);
        }

        var off = 1 + block_count * 4;
        for (0..self.highest() + 1) |i| {
            if (self.values[i]) |value| {
                std.mem.writeInt(u32, out[off..][0..4], value, .little);
                off += 4;
            }
        }
        return out;
    }

    fn highest(self: Fields) usize {
        var h: usize = 0;
        for (self.values, 0..) |v, i| {
            if (v != null) h = i;
        }
        return h;
    }

    fn countSet(self: Fields) usize {
        var n: usize = 0;
        for (self.values) |v| {
            if (v != null) n += 1;
        }
        return n;
    }

    fn blockCount(self: Fields) u8 {
        return @intCast(self.highest() / 32 + 1);
    }
};

/// VALUES update block payload.
pub const ValuesBlock = struct {
    guid: ObjectGuid,
    fields: Fields,

    pub const with = stdx.with;

    pub fn marshal(self: ValuesBlock, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try writePackedGuid(&out, gpa, self.guid);
        try appendSegment(&out, gpa, self.fields);
        return out.toOwnedSlice(gpa);
    }
};

/// MOVEMENT update block payload.
pub const MovementBlock = struct {
    guid: ObjectGuid,
    section: MovementSection,

    pub fn marshal(self: MovementBlock, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try writePackedGuid(&out, gpa, self.guid);
        try appendSegment(&out, gpa, self.section);
        return out.toOwnedSlice(gpa);
    }
};

/// OUT_OF_RANGE_OBJECTS / NEAR_OBJECTS block payload. Bounded so the list
/// stays slice-free; despawns in an arena never approach the cap.
pub const GuidList = struct {
    pub const max_guids = 8;
    guids: [max_guids]ObjectGuid = undefined,
    len: usize = 0,
};

pub const GuidBlock = struct {
    guids: GuidList,

    pub fn marshal(self: GuidBlock, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try appendU32(&out, gpa, @intCast(self.guids.len));
        for (self.guids.guids[0..self.guids.len]) |guid| try writePackedGuid(&out, gpa, guid);
        return out.toOwnedSlice(gpa);
    }
};

/// A CREATE payload: the client spawns one entity of a known kind. Each
/// variant implies its own object_type, movement section and field layout,
/// so a malformed create is impossible at compile time. The 2-vs-3 block
/// tag (introduce vs rebuild) is chosen on the outer UpdateBlock.
pub const CreateBlock = union(enum) {
    player_create: PlayerCreate,
    unit_create: UnitCreate,
    game_object_create: GameObjectCreate,

    pub fn marshal(self: CreateBlock, gpa: std.mem.Allocator) ![]u8 {
        return switch (self) {
            inline else => |payload| payload.marshal(gpa),
        };
    }
};

/// CREATE_OBJECT2 player payload. Holds the creation properties; the
/// 3.3.5a player field set and living section are derived in marshal.
pub const PlayerCreate = struct {
    guid: ObjectGuid,
    race: u8,
    class: u8,
    gender: u8,
    skin: u8,
    face: u8,
    hair_style: u8,
    hair_color: u8,
    facial_hair: u8,
    level: u8,
    health: u32,
    power_type: u8,
    power: u32,
    faction_template: u32,
    display_id: u32,
    visible_items: [19]u32 = .{0} ** 19,
    language_skill_ids: []const u16 = &.{},
    x: f32,
    y: f32,
    z: f32,
    orientation: f32,
    time_ms: u32,
    /// Bind camera/controls/UI to this entity on the receiving client.
    self_update: bool = true,

    pub const with = stdx.with;

    pub fn marshal(self: PlayerCreate, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);

        try writePackedGuid(&out, gpa, self.guid);
        try out.append(gpa, @intFromEnum(ObjectTypeId.player));
        try appendSegment(&out, gpa, self.movementSection());
        try appendSegment(&out, gpa, self.fieldLayout());

        return out.toOwnedSlice(gpa);
    }

    /// SELF | LIVING flags with the creation pose; speeds stay base.
    fn movementSection(self: PlayerCreate) MovementSection {
        return livingSection(self.x, self.y, self.z, self.orientation, self.time_ms, self.self_update);
    }

    /// The player create field set, derived from the properties.
    fn fieldLayout(self: PlayerCreate) Fields {
        var fields = Fields{};
        fields.set(ObjectField.guid, @truncate(self.guid.valueOf()));
        fields.set(ObjectField.guid_hi, @truncate(self.guid.valueOf() >> 32));
        fields.set(ObjectField.type, ObjectTypeId.player.mask());
        fields.set(ObjectField.scale_x, @bitCast(@as(f32, 1.0)));
        fields.set(UnitField.bytes_0, packedBytes(self.race, self.class, self.gender, self.power_type));
        fields.set(UnitField.health, self.health);
        fields.set(UnitField.max_health, self.health);
        if (self.power_type < 7) {
            fields.set(UnitField.power(self.power_type), self.power);
            fields.set(UnitField.maxPower(self.power_type), self.power);
        }
        fields.set(UnitField.level, self.level);
        fields.set(UnitField.faction_template, self.faction_template);
        fields.set(UnitField.display_id, self.display_id);
        fields.set(UnitField.native_display_id, self.display_id);
        fields.set(UnitField.bytes_2, unit_bytes_2_pvp);
        fields.set(PlayerField.appearance, packedBytes(self.skin, self.face, self.hair_style, self.hair_color));
        fields.set(PlayerField.facial_hair, self.facial_hair);
        fields.set(PlayerField.gender, self.gender);
        if (self.self_update) {
            for (self.language_skill_ids, 0..) |skill_id, slot| {
                fields.set(PlayerField.skillBook(@intCast(slot), .id_step), packedU16(skill_id, 0));
                fields.set(PlayerField.skillBook(@intCast(slot), .value_max), packedU16(300, 300));
                fields.set(PlayerField.skillBook(@intCast(slot), .bonus), 0);
            }
        }
        for (self.visible_items, 0..) |entry, slot| {
            if (entry != 0) fields.set(PlayerField.visibleItemEntry(@intCast(slot)), entry);
        }
        return fields;
    }
};

/// CREATE_OBJECT unit payload (pets, summons, arena units). Properties
/// plus the unit field set derived in marshal.
pub const UnitCreate = struct {
    guid: ObjectGuid,
    display_id: u32,
    level: u8,
    health: u32,
    power_type: u8,
    power: u32,
    faction_template: u32,
    x: f32,
    y: f32,
    z: f32,
    orientation: f32,
    time_ms: u32,

    pub const with = stdx.with;

    pub fn marshal(self: UnitCreate, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);

        try writePackedGuid(&out, gpa, self.guid);
        try out.append(gpa, @intFromEnum(ObjectTypeId.unit));
        try appendSegment(&out, gpa, self.movementSection());
        try appendSegment(&out, gpa, self.fieldLayout());

        return out.toOwnedSlice(gpa);
    }

    fn movementSection(self: UnitCreate) MovementSection {
        return livingSection(self.x, self.y, self.z, self.orientation, self.time_ms, false);
    }

    fn fieldLayout(self: UnitCreate) Fields {
        var fields = Fields{};
        fields.set(ObjectField.guid, @truncate(self.guid.valueOf()));
        fields.set(ObjectField.guid_hi, @truncate(self.guid.valueOf() >> 32));
        fields.set(ObjectField.type, ObjectTypeId.unit.mask());
        fields.set(ObjectField.scale_x, @bitCast(@as(f32, 1.0)));
        fields.set(UnitField.bytes_0, packedBytes(0, 0, 0, self.power_type));
        fields.set(UnitField.health, self.health);
        fields.set(UnitField.max_health, self.health);
        if (self.power_type < 7) {
            fields.set(UnitField.power(self.power_type), self.power);
            fields.set(UnitField.maxPower(self.power_type), self.power);
        }
        fields.set(UnitField.level, self.level);
        fields.set(UnitField.faction_template, self.faction_template);
        fields.set(UnitField.display_id, self.display_id);
        fields.set(UnitField.native_display_id, self.display_id);
        return fields;
    }
};

/// CREATE_OBJECT gameobject payload (flag stand, gates). Stationary
/// placement plus the gameobject field set derived in marshal.
pub const GameObjectCreate = struct {
    guid: ObjectGuid,
    display_id: u32,
    scale: f32 = 1.0,
    x: f32,
    y: f32,
    z: f32,
    orientation: f32,

    pub const with = stdx.with;

    pub fn marshal(self: GameObjectCreate, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);

        try writePackedGuid(&out, gpa, self.guid);
        try out.append(gpa, @intFromEnum(ObjectTypeId.game_object));
        try appendSegment(&out, gpa, MovementSection{
            .stationary_position = .{
                .x = self.x,
                .y = self.y,
                .z = self.z,
                .orientation = self.orientation,
            },
        });
        try appendSegment(&out, gpa, self.fieldLayout());

        return out.toOwnedSlice(gpa);
    }

    fn fieldLayout(self: GameObjectCreate) Fields {
        var fields = Fields{};
        fields.set(ObjectField.guid, @truncate(self.guid.valueOf()));
        fields.set(ObjectField.guid_hi, @truncate(self.guid.valueOf() >> 32));
        fields.set(ObjectField.type, ObjectTypeId.game_object.mask());
        fields.set(ObjectField.entry, self.display_id);
        fields.set(ObjectField.scale_x, @bitCast(self.scale));
        return fields;
    }
};

/// One segment of SMSG_UPDATE_OBJECT. The tagged union owns the leading
/// tag byte; each payload marshals itself.
pub const UpdateBlock = union(UpdateType) {
    values: ValuesBlock,
    movement: MovementBlock,
    create_object: CreateBlock,
    create_object2: CreateBlock,
    out_of_range_objects: GuidBlock,
    near_objects: GuidBlock,

    pub fn marshal(self: UpdateBlock, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        switch (self) {
            .values => |v| {
                try out.append(gpa, @intFromEnum(UpdateType.values));
                try appendSegment(&out, gpa, v);
            },
            .movement => |m| {
                try out.append(gpa, @intFromEnum(UpdateType.movement));
                try appendSegment(&out, gpa, m);
            },
            .create_object => |c| {
                try out.append(gpa, @intFromEnum(UpdateType.create_object));
                try appendSegment(&out, gpa, c);
            },
            .create_object2 => |c| {
                try out.append(gpa, @intFromEnum(UpdateType.create_object2));
                try appendSegment(&out, gpa, c);
            },
            .out_of_range_objects => |g| {
                try out.append(gpa, @intFromEnum(UpdateType.out_of_range_objects));
                try appendSegment(&out, gpa, g);
            },
            .near_objects => |g| {
                try out.append(gpa, @intFromEnum(UpdateType.near_objects));
                try appendSegment(&out, gpa, g);
            },
        }
        return out.toOwnedSlice(gpa);
    }
};

// --- private implementation ---------------------------------------------------

/// Appends a segment's self-marshalled bytes. Comptime-generic: any type
/// exposing `marshal(self, gpa) ![]u8` composes here.
fn appendSegment(out: *std.ArrayList(u8), gpa: std.mem.Allocator, segment: anytype) !void {
    const payload = try segment.marshal(gpa);
    defer gpa.free(payload);
    try out.appendSlice(gpa, payload);
}

/// LIVING movement section for a unit at a creation pose.
fn livingSection(x: f32, y: f32, z: f32, orientation: f32, time_ms: u32, self_update: bool) MovementSection {
    return .{
        .self = self_update,
        .living = .{
            .flags = 0,
            .flags2 = 0,
            .time_ms = time_ms,
            .x = x,
            .y = y,
            .z = z,
            .orientation = orientation,
            .fall_time_ms = 0,
        },
    };
}

/// Update flags written as a u16 at the head of the movement section.
/// Bits 0x0001..0x0200 are the full 3.3.5a set; 0x0400+ is reserved.
const update_flag_self: u16 = 0x0001;
/// The packet is for the client's own character (see MovementSection.self).
const update_flag_transport: u16 = 0x0002;
/// The unit is attacking someone; the client needs the victim guid to draw
/// the target marker and drive combat UI.
const update_flag_has_target: u16 = 0x0004;
/// Purpose unknown; the client reads a u32 and ignores it.
const update_flag_unknown: u16 = 0x0008;
/// Emits a u32 guid low for objects whose full guid was not packed. The
/// client expects type-dependent constants: guid counter for
/// object/item/container/gameobject/dynamicobject/corpse, 0x0B for units,
/// 0x2F (self) / 0x08 (others) for players.
const update_flag_low_guid: u16 = 0x0010;
/// The object is a living unit: MovementInfo + 9 f32 speeds so the client
/// can animate and predict its movement.
const update_flag_living: u16 = 0x0020;
/// Non-moving object: 4 f32 stationary placement. Ignored when living is set.
const update_flag_stationary_position: u16 = 0x0040;
/// Vehicle: u32 vehicle id + f32 facing.
const update_flag_vehicle: u16 = 0x0080;
/// Object rides a transport: transport packed guid (or 0x00), world x/y/z,
/// transport offset x/y/z (or world x/y/z repeated), orientation, then
/// orientation again for corpses or f32(0).
const update_flag_position: u16 = 0x0100;
/// Gameobject with a packed world rotation (doors etc): an i64 follows.
const update_flag_rotation: u16 = 0x0200;

/// Base player move speeds in wire order (walk, run, run back, swim,
/// swim back, flight, flight back, turn rate, pitch rate).
const base_speeds = [9]f32{ 2.5, 7.0, 4.5, 4.722222, 2.5, 7.0, 4.5, 3.141594, 3.14 };

const field_capacity = 704;

/// Resolves a field-dictionary enum to its wire index. Anything that is
/// not a field enum is a compile error: use the dictionaries, not magic
/// numbers.
fn fieldIndex(field: anytype) usize {
    return switch (@typeInfo(@TypeOf(field))) {
        .@"enum" => @intFromEnum(field),
        else => @compileError("Fields.set takes an ObjectField/UnitField/PlayerField"),
    };
}

/// Packs four byte-sized values into the u32 the client reads for the
/// packed byte fields (UNIT_FIELD_BYTES_0, PLAYER_BYTES).
fn packedBytes(b0: u8, b1: u8, b2: u8, b3: u8) u32 {
    return @as(u32, b0) | @as(u32, b1) << 8 | @as(u32, b2) << 16 | @as(u32, b3) << 24;
}

fn packedU16(low: u16, high: u16) u32 {
    return @as(u32, low) | @as(u32, high) << 16;
}

/// UNIT_FIELD_BYTES_2 byte 1 flag: the unit has PvP enabled, which makes
/// the client render the PvP state (name plates, arena frames).
const unit_bytes_2_pvp: u32 = 0x0000_0100;

pub fn writePackedGuid(out: *std.ArrayList(u8), gpa: std.mem.Allocator, guid: ObjectGuid) !void {
    const encoded = guid.toPacked();
    try out.appendSlice(gpa, encoded.slice());
}

fn appendU16(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, v, .little);
    try out.appendSlice(gpa, &buf);
}

fn appendU32(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try out.appendSlice(gpa, &buf);
}

fn appendI64(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: i64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &buf, v, .little);
    try out.appendSlice(gpa, &buf);
}

fn appendF32(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: f32) !void {
    try appendU32(out, gpa, @bitCast(v));
}

// --- tests ---------------------------------------------------------------------

test "field dictionaries resolve to the wire indices" {
    const t = std.testing;

    try t.expectEqual(@as(u16, 0), @intFromEnum(ObjectField.guid));
    try t.expectEqual(@as(u16, 1), @intFromEnum(ObjectField.guid_hi));
    try t.expectEqual(@as(u16, 2), @intFromEnum(ObjectField.type));
    try t.expectEqual(@as(u16, 3), @intFromEnum(ObjectField.entry));
    try t.expectEqual(@as(u16, 4), @intFromEnum(ObjectField.scale_x));
    try t.expectEqual(@as(u16, 24), @intFromEnum(UnitField.health));
    try t.expectEqual(@as(u16, 25), @intFromEnum(UnitField.power(0)));
    try t.expectEqual(@as(u16, 31), @intFromEnum(UnitField.power(6)));
    try t.expectEqual(@as(u16, 33), @intFromEnum(UnitField.maxPower(0)));
    try t.expectEqual(@as(u16, 39), @intFromEnum(UnitField.maxPower(6)));
    try t.expectEqual(@as(u16, 283), @intFromEnum(PlayerField.visible_item_1_entry_id));
    try t.expectEqual(@as(u16, 285), @intFromEnum(PlayerField.visibleItemEntry(1)));
    try t.expectEqual(@as(u16, 636), @intFromEnum(PlayerField.skillBook(0, .id_step)));
    try t.expectEqual(@as(u16, 639), @intFromEnum(PlayerField.skillBook(1, .id_step)));
    try t.expectEqual(@as(u32, 0x19), ObjectTypeId.player.mask());
    try t.expectEqual(@as(u32, 0x09), ObjectTypeId.unit.mask());
    try t.expectEqual(@as(u32, 0x21), ObjectTypeId.game_object.mask());
}

test "player create_object2 block has the expected wire shape" {
    const t = std.testing;
    const gpa = t.allocator;

    var pkt = try UpdateObject.init(gpa);
    defer pkt.deinit(gpa);
    try pkt.add(gpa, .{ .create_object2 = .{ .player_create = .{
        .guid = ObjectGuid.player(1),
        .race = 1,
        .class = 1,
        .gender = 0,
        .skin = 0,
        .face = 0,
        .hair_style = 0,
        .hair_color = 0,
        .facial_hair = 0,
        .level = 80,
        .health = 100,
        .power_type = 0,
        .power = 100,
        .faction_template = 1,
        .display_id = 1,
        .language_skill_ids = &.{98},
        .x = 1,
        .y = 2,
        .z = 3,
        .orientation = 4,
        .time_ms = 0xAABBCCDD,
    } } });

    const body = try pkt.marshal(gpa);
    defer gpa.free(body);

    // u32 block count.
    try t.expectEqual(@as(u32, 1), std.mem.readInt(u32, body[0..4], .little));
    // update type CREATE_OBJECT2.
    try t.expectEqual(@as(u8, 3), body[4]);
    // packed guid player(1).
    try t.expectEqualSlices(u8, &.{ 0x01, 0x01 }, body[5..7]);
    // object type player.
    try t.expectEqual(@as(u8, 4), body[7]);
    // update flags: SELF | LIVING.
    try t.expectEqual(@as(u16, 0x21), std.mem.readInt(u16, body[8..10], .little));
    // MovementInfo: movement flags, flags2, time.
    try t.expectEqual(@as(u32, 0), std.mem.readInt(u32, body[10..14], .little));
    try t.expectEqual(@as(u16, 0), std.mem.readInt(u16, body[14..16], .little));
    try t.expectEqual(@as(u32, 0xAABBCCDD), std.mem.readInt(u32, body[16..20], .little));

    // Head is 76 bytes (guid/type/flags + 30-byte MovementInfo + 9 speeds);
    // fields follow: 20 blocks (highest field 638), 20 masks, 20 values.
    try t.expectEqual(@as(u8, 20), body[76]);
    try t.expectEqual(@as(u32, 0x03800017), std.mem.readInt(u32, body[77..81], .little)); // bits 0,1,2,4,23,24,25
    const values_start = 77 + 80;
    try t.expectEqual(@as(u32, 1), std.mem.readInt(u32, body[values_start..][0..4], .little)); // guid
    try t.expectEqual(@as(u32, 100), std.mem.readInt(u32, body[values_start + 20 ..][0..4], .little)); // health
    try t.expectEqual(@as(u32, 80), std.mem.readInt(u32, body[values_start + 36 ..][0..4], .little)); // level
    try t.expectEqual(@as(u32, 0x100), std.mem.readInt(u32, body[values_start + 52 ..][0..4], .little)); // bytes_2 pvp
    try t.expectEqual(@as(u32, packedU16(98, 0)), std.mem.readInt(u32, body[values_start + 68 ..][0..4], .little));
    try t.expectEqual(@as(u32, packedU16(300, 300)), std.mem.readInt(u32, body[values_start + 72 ..][0..4], .little));
    try t.expectEqual(@as(u32, 0), std.mem.readInt(u32, body[values_start + 76 ..][0..4], .little));
    try t.expectEqual(@as(usize, 237), body.len);
}

test "values and out_of_range blocks marshal" {
    const t = std.testing;
    const gpa = t.allocator;

    var pkt = try UpdateObject.init(gpa);
    defer pkt.deinit(gpa);

    var fields = Fields{};
    fields.set(UnitField.health, 5000);
    try pkt.add(gpa, .{ .values = .{ .guid = ObjectGuid.player(7), .fields = fields } });

    var guids = GuidList{};
    guids.guids[0] = ObjectGuid.player(9);
    guids.len = 1;
    try pkt.add(gpa, .{ .out_of_range_objects = .{ .guids = guids } });

    const body = try pkt.marshal(gpa);
    defer gpa.free(body);

    // 2 blocks.
    try t.expectEqual(@as(u32, 2), std.mem.readInt(u32, body[0..4], .little));
    // first block: VALUES, packed guid player(7).
    try t.expectEqual(@as(u8, 0), body[4]);
    try t.expectEqualSlices(u8, &.{ 0x01, 0x07 }, body[5..7]);
    // fields: block count 1, mask bit 24, value.
    try t.expectEqual(@as(u8, 1), body[7]);
    try t.expectEqual(@as(u32, 1 << 24), std.mem.readInt(u32, body[8..12], .little));
    try t.expectEqual(@as(u32, 5000), std.mem.readInt(u32, body[12..16], .little));
    // second block: OUT_OF_RANGE_OBJECTS, count, packed guid player(9).
    try t.expectEqual(@as(u8, 4), body[16]);
    try t.expectEqual(@as(u32, 1), std.mem.readInt(u32, body[17..21], .little));
    try t.expectEqualSlices(u8, &.{ 0x01, 0x09 }, body[21..23]);
    try t.expectEqual(@as(usize, 23), body.len);
}
