//! Aura lifecycle skeleton: spell effects that outlive their cast become
//! entity roots. Wire facts in docs/auras.md; full design report delivered
//! in chat (components, algorithms, policies). Components pending
//! reintroduction — stubs only for now.

const std = @import("std");
const ecs = @import("ecs");
const domain = @import("domain");
const proto = @import("protocol");
const stdx = @import("stdx");
const c = @import("./EcsComponent.zig");

const MapEcs = @import("MapEcs.zig").MapEcs;

const log = std.log.scoped(.aura_lifecycle_system);

pub fn runPre(map_ecs: *MapEcs, frame: MapEcs.Frame) !void {
    var registry = &map_ecs.registry;
    var aura_slots = &map_ecs.state.aura_slots;

    for (map_ecs.events.get(.aura_apply_request).items) |event| {
        const aura_ent = event.aura_apply_request[0];
        const aura = registry.getConst(c.Aura, aura_ent);

        // 1. Book keep the aura
        const aura_slot = aura_slots.addAuraForTarget(aura.owner, aura_ent) orelse continue;
        registry.add(aura_ent, c.AuraApplied{ .slot = aura_slot });

        // 2. Notify client
        const elapsed = registry.getConst(c.AuraDuration, aura_ent).elapsed;
        const max_duration = registry.getConst(c.AuraMaxDuration, aura_ent).max_duration;
        const packet = proto.spell.AuraUpdateServer{
            .spell_id = aura.spell_id,
            .caster_guid = registry.getConst(c.Guid, aura.caster).value,
            .target_guid = registry.getConst(c.Guid, aura.owner).value,
            .slot = aura_slot,
            .caster_level = registry.getConst(c.Level, aura.caster).value,
            .remaining_ms = elapsed,
            .max_duration_ms = max_duration,
        };
        map_ecs.broadcast(.{ aura.owner, .{ .ignore_sender = false } }, packet);
        map_ecs.addEvent(.{ .aura_applied = .{aura_ent} });
    }

    var aura_duration_view = registry.view(.{c.AuraDuration}, .{});
    var aura_duration_it = aura_duration_view.entityIterator();
    while (aura_duration_it.next()) |aura_duration_ent| {
        var duration = registry.get(c.AuraDuration, aura_duration_ent);
        duration.elapsed -|= frame.dt;
        if (duration.elapsed == 0) {
            map_ecs.addEvent(.{ .aura_destroyed = .{aura_duration_ent} });
        }
    }
}

pub fn runPost(map_ecs: *MapEcs, frame: MapEcs.Frame) !void {
    _ = frame;
    var registry = &map_ecs.registry;
    var aura_slots = &map_ecs.state.aura_slots;

    for (map_ecs.events.get(.aura_destroyed).items) |event| {
        const aura_entity_to_destroy = event.aura_destroyed[0];
        const aura = registry.getConst(c.Aura, aura_entity_to_destroy);
        const aura_owner_guid = registry.getConst(c.Guid, aura_entity_to_destroy).value;
        const slot_freed = aura_slots.removeAuraForTarget(aura.owner, aura_entity_to_destroy) orelse unreachable;
        map_ecs.broadcast(.{ aura.owner, .{ .ignore_sender = false } }, proto.spell.AuraUpdateServer.remove(aura_owner_guid, slot_freed));
    }
}


pub const AuraSlots = struct {
    // { [ key: Unit ] : SlotMap }
    storage: std.AutoArrayHashMapUnmanaged(ecs.Entity, stdx.SlotMap(ecs.Entity)),
    gpa: std.mem.Allocator,

    const Self = @This();
    const max_slots_per_target = 52;

    pub fn init(gpa: std.mem.Allocator) Self {
        return .{
            .storage = .empty,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Self) void {
        var storage_it = self.storage.iterator();
        while (storage_it.next()) |storage_entry| storage_entry.value_ptr.deinit();
        self.storage.deinit(self.gpa);
    }

    pub fn addAuraForTarget(self: *Self, target: ecs.Entity, aura: ecs.Entity) ?u8 {
        var gop = self.storage.getOrPut(self.gpa, target) catch unreachable;
        if (!gop.found_existing) gop.value_ptr.* = stdx.SlotMap(ecs.Entity).init(self.gpa);
        if (gop.value_ptr.items().len >= max_slots_per_target) {
            @branchHint(.unlikely);
            log.info("Target reached aura limit count, dropping aura", .{});
            return null;
        }
        return gop.value_ptr.put(aura);
    }

    pub fn removeAuraForTarget(self: *Self, target: ecs.Entity, aura: ecs.Entity) ?u8 {
        const slot_map = self.storage.getPtr(target) orelse return null;
        return slot_map.remove(aura);
    }

    pub fn slotOf(self: *const Self, target: ecs.Entity, aura: ecs.Entity) ?u8 {
        const slot_map = self.storage.getPtr(target) orelse return null;
        return slot_map.slotOf(aura);
    }

    pub fn needsCompaction(self: *const Self, target: ecs.Entity) bool {
        const slot_map = self.storage.getPtr(target) orelse return false;
        const len = slot_map.items().len;
        return len > 0 and @as(usize, slot_map.tombstoneCount()) * 2 >= len;
    }

    pub fn compactForTarget(self: *Self, target: ecs.Entity) void {
        const slot_map = self.storage.getPtr(target) orelse return;
        slot_map.compact();
    }

    /// Raw window with holes; index = slot id, null = tombstone.
    pub fn items(self: *const Self, target: ecs.Entity) []const ?ecs.Entity {
        const slot_map = self.storage.getPtr(target) orelse return &.{};
        return slot_map.items();
    }
};

test AuraSlots {
    const t = @import("std").testing;

    var slots = AuraSlots.init(t.allocator);
    defer slots.deinit();

    const target: ecs.Entity = .{ .index = 1, .version = 0 };
    const a1: ecs.Entity = .{ .index = 11, .version = 0 };
    const a2: ecs.Entity = .{ .index = 12, .version = 0 };

    try t.expectEqual(@as(u8, 0), slots.addAuraForTarget(target, a1).?);
    try t.expectEqual(@as(u8, 1), slots.addAuraForTarget(target, a2).?);
    try t.expectEqual(@as(u8, 0), slots.removeAuraForTarget(target, a1).?);

    // a2 keeps its slot; a new aura appends past the tombstone.
    try t.expectEqual(@as(u8, 1), slots.slotOf(target, a2).?);
    try t.expectEqual(@as(u8, 2), slots.addAuraForTarget(target, a1).?);
}
