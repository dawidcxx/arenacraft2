//! Fixed-capacity slot map: stable `u8` slots for hashable values with
//! tombstone removal. Slots are append-only — a value keeps its slot for its
//! whole lifetime and removal frees it without moving anything else — so slot
//! identity can be shared with external observers (e.g. client aura slots).
//!
//! Tombstones accumulate until `compact()` squeezes them back together,
//! preserving relative order. Compaction silently renumbers slots, so
//! observers must be fully resynced afterwards; per-move patching is
//! deliberately not tracked.

const std = @import("std");

pub fn SlotMap(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Slot window; `null` is a tombstone left by `remove`.
        slots: std.ArrayListUnmanaged(?T) = .empty,
        /// value -> slot, kept in sync with `slots`.
        reverse: std.AutoHashMapUnmanaged(T, u8) = .empty,
        gpa: std.mem.Allocator,
        tombstones: u8 = 0,
        /// Slot of the most recent `put` (0 when empty).
        last_write: u8 = 0,

        /// Slot ids are u8 on the wire, so the ceiling is inherent.
        pub const max_slots = 255;

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *Self) void {
            self.slots.deinit(self.gpa);
            self.reverse.deinit(self.gpa);
        }

        /// Appends `value` at the end, past any tombstones. Never reuses a
        /// freed slot — observers expect new entries to appear last.
        /// Returns the new slot, or null once `max_slots` is reached.
        pub fn put(self: *Self, value: T) ?u8 {
            if (self.slots.items.len >= max_slots) {
                @branchHint(.unlikely);
                return null;
            }
            const slot: u8 = @intCast(self.slots.items.len);
            self.slots.append(self.gpa, value) catch unreachable;
            self.reverse.put(self.gpa, value, slot) catch unreachable;
            self.last_write = slot;
            return slot;
        }

        /// Tombstones `value`'s slot in place; no other slot moves.
        /// Returns the freed slot, or null when `value` is not present.
        pub fn remove(self: *Self, value: T) ?u8 {
            const slot = self.reverse.get(value) orelse return null;
            _ = self.reverse.remove(value);
            self.slots.items[slot] = null;
            self.tombstones += 1;
            return slot;
        }

        pub fn get(self: *const Self, slot: u8) ?T {
            if (slot >= self.slots.items.len) return null;
            return self.slots.items[slot];
        }

        pub fn slotOf(self: *const Self, value: T) ?u8 {
            return self.reverse.get(value);
        }

        /// Raw window with holes; index = slot id.
        pub fn items(self: *const Self) []const ?T {
            return self.slots.items;
        }

        pub fn occupied(self: *const Self) u8 {
            return @intCast(self.slots.items.len - self.tombstones);
        }

        pub fn tombstoneCount(self: *const Self) u8 {
            return self.tombstones;
        }

        pub fn lastWrite(self: *const Self) u8 {
            return self.last_write;
        }

        /// Squeezes tombstones out with a write cursor, preserving relative
        /// order, then rebuilds the reverse index. Every surviving value
        /// above the first freed slot changes its slot id — resync observers
        /// instead of patching them incrementally.
        pub fn compact(self: *Self) void {
            var write: usize = 0;
            for (self.slots.items, 0..) |entry, read| {
                if (entry) |value| {
                    if (write != read) {
                        self.slots.items[write] = value;
                        self.reverse.put(self.gpa, value, @intCast(write)) catch unreachable;
                    }
                    write += 1;
                }
            }
            if (write != self.slots.items.len) {
                self.slots.shrinkRetainingCapacity(write);
                self.tombstones = 0;
                self.last_write = if (write == 0) 0 else @intCast(write - 1);
            }
        }
    };
}

const testing = std.testing;

test "put appends in order and never reuses tombstoned slots" {
    var map = SlotMap(u32).init(testing.allocator);
    defer map.deinit();

    try testing.expectEqual(@as(u8, 0), map.put(10).?);
    try testing.expectEqual(@as(u8, 1), map.put(20).?);
    try testing.expectEqual(@as(u8, 2), map.put(30).?);
    try testing.expectEqual(@as(u8, 2), map.lastWrite());
    try testing.expectEqual(@as(u8, 3), map.occupied());

    try testing.expectEqual(@as(?u8, 1), map.remove(20));
    try testing.expectEqual(@as(u8, 1), map.tombstoneCount());
    try testing.expectEqual(@as(u8, 2), map.occupied());
    try testing.expectEqual(@as(?u8, null), map.slotOf(20));
    try testing.expectEqual(@as(?u32, 10), map.get(0));
    try testing.expectEqual(@as(?u32, null), map.get(1));
    try testing.expectEqual(@as(?u32, 30), map.get(2));

    try testing.expectEqual(@as(u8, 3), map.put(40).?);
    try testing.expectEqual(@as(u8, 3), map.slotOf(40).?);
}

test "remove unknown value returns null" {
    var map = SlotMap(u32).init(testing.allocator);
    defer map.deinit();

    try testing.expectEqual(@as(?u8, null), map.remove(999));
    _ = map.put(1);
    try testing.expectEqual(@as(?u8, null), map.remove(999));
    try testing.expectEqual(@as(u8, 0), map.tombstoneCount());
}

test "compact squeezes tombstones preserving relative order" {
    var map = SlotMap(u32).init(testing.allocator);
    defer map.deinit();

    for ([_]u32{ 10, 20, 30, 40, 50 }) |v| _ = map.put(v);
    try testing.expectEqual(@as(?u8, 0), map.remove(10));
    try testing.expectEqual(@as(?u8, 2), map.remove(30));

    map.compact();

    try testing.expectEqual(@as(u8, 0), map.tombstoneCount());
    try testing.expectEqual(@as(u8, 3), map.occupied());
    try testing.expectEqual(@as(u8, 2), map.lastWrite());
    try testing.expectEqual(@as(usize, 3), map.items().len);
    try testing.expectEqual(@as(?u32, 20), map.get(0));
    try testing.expectEqual(@as(?u32, 40), map.get(1));
    try testing.expectEqual(@as(?u32, 50), map.get(2));
    try testing.expectEqual(@as(u8, 0), map.slotOf(20).?);
    try testing.expectEqual(@as(u8, 1), map.slotOf(40).?);
    try testing.expectEqual(@as(u8, 2), map.slotOf(50).?);
}

test "compact without tombstones is a no-op" {
    var map = SlotMap(u32).init(testing.allocator);
    defer map.deinit();

    _ = map.put(1);
    _ = map.put(2);
    map.compact();

    try testing.expectEqual(@as(u8, 0), map.tombstoneCount());
    try testing.expectEqual(@as(usize, 2), map.items().len);
    try testing.expectEqual(@as(u8, 0), map.slotOf(1).?);
    try testing.expectEqual(@as(u8, 1), map.slotOf(2).?);
}

test "compact down to empty reopens the window at slot 0" {
    var map = SlotMap(u32).init(testing.allocator);
    defer map.deinit();

    _ = map.put(1);
    try testing.expectEqual(@as(?u8, 0), map.remove(1));
    map.compact();

    try testing.expectEqual(@as(usize, 0), map.items().len);
    try testing.expectEqual(@as(u8, 0), map.occupied());
    try testing.expectEqual(@as(u8, 0), map.put(2).?);
}

test "put drops at the slot ceiling" {
    var map = SlotMap(u8).init(testing.allocator);
    defer map.deinit();

    var i: u32 = 0;
    while (i < SlotMap(u8).max_slots) : (i += 1) {
        try testing.expectEqual(@as(u8, @intCast(i)), map.put(@intCast(i)).?);
    }
    try testing.expectEqual(@as(?u8, null), map.put(255));
    try testing.expectEqual(@as(u8, 0), map.tombstoneCount());
}
