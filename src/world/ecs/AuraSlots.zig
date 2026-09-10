//! Per-unit aura slot bookkeeping: which aura entity owns which of the
//! client-visible aura slots. Slots are append-only — a new aura always
//! lands past every live slot, freed slots tombstone and are never reused —
//! until compaction squeezes the holes out; slots then renumber and
//! observers must be resynced with SMSG_AURA_UPDATE_ALL.

const std = @import("std");
const ecs = @import("ecs");
const stdx = @import("stdx");

const log = std.log.scoped(.aura_slots);

/// Client-visible aura slots per unit (docs/auras.md: the unit field block
/// exposes 56).
pub const max_slots_per_target = 56;

pub const AuraSlots = struct {
    const Self = @This();

    storage: std.AutoArrayHashMapUnmanaged(ecs.Entity, stdx.SlotMap(ecs.Entity)) = .empty,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Self {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Self) void {
        var storage_it = self.storage.iterator();
        while (storage_it.next()) |entry| entry.value_ptr.deinit();
        self.storage.deinit(self.gpa);
    }

    /// Assigns `aura` the next free slot on `target`, or null at the cap.
    pub fn addAuraForTarget(self: *Self, target: ecs.Entity, aura: ecs.Entity) ?u8 {
        var gop = self.storage.getOrPut(self.gpa, target) catch unreachable;
        if (!gop.found_existing) gop.value_ptr.* = stdx.SlotMap(ecs.Entity).init(self.gpa);
        if (gop.value_ptr.occupied() >= max_slots_per_target) {
            @branchHint(.unlikely);
            log.info("target reached the aura slot cap, dropping aura", .{});
            return null;
        }
        return gop.value_ptr.put(aura);
    }

    /// Frees `aura`'s slot on `target`; an empty window is dropped with it,
    /// so a target's slots restart at zero once they fully drain.
    pub fn removeAuraForTarget(self: *Self, target: ecs.Entity, aura: ecs.Entity) ?u8 {
        const slot_map = self.storage.getPtr(target) orelse return null;
        const freed = slot_map.remove(aura);
        if (slot_map.occupied() == 0) self.removeTarget(target);
        return freed;
    }

    /// Drops `target`'s whole window (departed units); the auras themselves
    /// are the registry's business.
    pub fn removeTarget(self: *Self, target: ecs.Entity) void {
        if (self.storage.fetchSwapRemove(target)) |kv| {
            var slot_map = kv.value;
            slot_map.deinit();
        }
    }

    pub fn slotOf(self: *const Self, target: ecs.Entity, aura: ecs.Entity) ?u8 {
        const slot_map = self.storage.getPtr(target) orelse return null;
        return slot_map.slotOf(aura);
    }

    /// Raw window with holes; index = slot id, null = tombstone.
    pub fn items(self: *const Self, target: ecs.Entity) []const ?ecs.Entity {
        const slot_map = self.storage.getPtr(target) orelse return &.{};
        return slot_map.items();
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
};

const t = std.testing;

test "slots append in order, tombstone, and append past holes" {
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

test "slot cap drops the 57th aura" {
    var slots = AuraSlots.init(t.allocator);
    defer slots.deinit();

    const target: ecs.Entity = .{ .index = 1, .version = 0 };
    for (0..max_slots_per_target) |i| {
        try t.expectEqual(@as(u8, @intCast(i)), slots.addAuraForTarget(target, .{ .index = @intCast(i + 1), .version = 0 }).?);
    }
    try t.expectEqual(@as(?u8, null), slots.addAuraForTarget(target, .{ .index = 200, .version = 0 }));
}

test "draining the window restarts slots at zero" {
    var slots = AuraSlots.init(t.allocator);
    defer slots.deinit();

    const target: ecs.Entity = .{ .index = 1, .version = 0 };
    const a1: ecs.Entity = .{ .index = 11, .version = 0 };
    const a2: ecs.Entity = .{ .index = 12, .version = 0 };

    _ = slots.addAuraForTarget(target, a1);
    _ = slots.addAuraForTarget(target, a2);
    _ = slots.removeAuraForTarget(target, a1);
    _ = slots.removeAuraForTarget(target, a2);

    // The empty window was dropped, so the next aura opens a fresh one.
    try t.expectEqual(@as(u8, 0), slots.addAuraForTarget(target, a1).?);
}

test "removeTarget frees the whole window" {
    var slots = AuraSlots.init(t.allocator);
    defer slots.deinit();

    const target: ecs.Entity = .{ .index = 1, .version = 0 };
    _ = slots.addAuraForTarget(target, .{ .index = 11, .version = 0 });
    _ = slots.addAuraForTarget(target, .{ .index = 12, .version = 0 });

    slots.removeTarget(target);
    try t.expectEqual(@as(usize, 0), slots.items(target).len);

    try t.expectEqual(@as(u8, 0), slots.addAuraForTarget(target, .{ .index = 13, .version = 0 }).?);
}

test "needsCompaction flips at half tombstones" {
    var slots = AuraSlots.init(t.allocator);
    defer slots.deinit();

    const target: ecs.Entity = .{ .index = 1, .version = 0 };
    for (0..4) |i| _ = slots.addAuraForTarget(target, .{ .index = @intCast(i + 1), .version = 0 });

    _ = slots.removeAuraForTarget(target, .{ .index = 1, .version = 0 });
    try t.expect(!slots.needsCompaction(target));
    _ = slots.removeAuraForTarget(target, .{ .index = 2, .version = 0 });
    try t.expect(slots.needsCompaction(target));

    slots.compactForTarget(target);
    try t.expect(!slots.needsCompaction(target));
    try t.expectEqual(@as(usize, 2), slots.items(target).len);
}
