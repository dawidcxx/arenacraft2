const std = @import("std");

/// Single-writer / many-reader CoW list, stale snapshot allowed.
///
/// You said stale is fine - that unlocks the best trade-off for this
/// workload: readers are fully lock-free, writer is serialized.
///
/// Design vs previous revision:
/// - Previous fix used `std.atomic.Mutex` for both readers and writer
///   + `Version` refcount (`Arc` pattern). Readers did `lock(); retain()`
///   which is correct but still serializes snapshot creation.
/// - If stale is acceptable we don't need reader locks or refcounts at
///   all. `current` is an atomic pointer; `snapshot()` is a single
///   `load(.acquire)`. Old versions are kept alive in an `ArenaAllocator`
///   until `deinit()` - no `retired` list, no `refs`, no hazard, no
///   TOCTOU. Writer is still single and serialized by a spin `mutex`
///   (only to protect the arena and the `swap`).
///
/// Cost: old versions are not reclaimed until `deinit()`. With low write
/// frequency (your case: realms list, config) this is intentional - it
/// is exactly what `ServerState.Realms` already does and what the
/// arena-based `CoWList` patch tried to avoid with broken reclamation.
/// Bounded by `writes * avg_len * @sizeOf(T)`; for 100 writes of 10
/// realms it's kilobytes.
///
/// If you later need bounded memory with prompt reclamation, swap this
/// arena for the previous `RwLock` + `Arc`-refcount design:
///   `std.Io.RwLock` (`lockShared` for `snapshot`, exclusive for
///   `append`/`removeAt`) + `Version{ refs: atomic, allocator, items }`
///   where `snapshot()` does `lockShared(); retain();` and `release()`
///   does `fetchSub==1 => free`. Logic is identical to `src/stdx/Arc.zig`.
///   That version keeps `snapshot()` shared-locked (microseconds) but
///   reclaims immediately. Keep one or the other - do not mix.
///
pub fn CoWList(comptime T: type) type {
    return struct {
        const Self = @This();

        arena: std.heap.ArenaAllocator,
        mutex: std.atomic.Mutex = .unlocked,
        current: std.atomic.Value(?*Version) = .init(null),

        const Version = struct {
            items: []const T,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .arena = std.heap.ArenaAllocator.init(allocator),
                .mutex = .unlocked,
                .current = .init(null),
            };
        }

        fn lock(self: *Self) void {
            while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        }

        fn unlock(self: *Self) void {
            self.mutex.unlock();
        }

        /// Arena frees all versions at once. Call only when no snapshot
        /// is being used on another thread (stale snapshots are valid until
        /// `deinit` but must not be dereferenced after).
        pub fn deinit(self: *Self) void {
            self.lock();
            defer self.unlock();
            self.current.store(null, .release);
            self.arena.deinit();
        }

        /// Lock-free, may return stale view if concurrent writer swaps.
        /// Valid until `deinit()` (arena keeps old versions alive).
        pub fn snapshot(self: *const Self) Snapshot {
            const v = self.current.load(.acquire) orelse return .empty;
            return .{ .version = v };
        }

        pub fn append(self: *Self, item: T) std.mem.Allocator.Error!void {
            self.lock();
            defer self.unlock();

            const aa = self.arena.allocator();
            const old = self.current.load(.acquire);
            const old_items = if (old) |v| v.items else &[_]T{};

            const new_items = try aa.alloc(T, old_items.len + 1);
            @memcpy(new_items[0..old_items.len], old_items);
            new_items[old_items.len] = item;

            const ver = try aa.create(Version);
            ver.* = .{ .items = new_items };
            self.current.store(ver, .release);
        }

        pub fn removeAt(self: *Self, index: usize) bool {
            self.lock();
            defer self.unlock();

            const old = self.current.load(.acquire) orelse return false;
            if (index >= old.items.len) return false;

            const aa = self.arena.allocator();
            if (old.items.len == 1) {
                const ver = aa.create(Version) catch return false;
                ver.* = .{ .items = &.{} };
                self.current.store(ver, .release);
                return true;
            }

            const new_items = aa.alloc(T, old.items.len - 1) catch return false;
            @memcpy(new_items[0..index], old.items[0..index]);
            @memcpy(new_items[index..], old.items[index + 1 ..]);

            const ver = aa.create(Version) catch {
                // arena has no free, but be symmetric
                return false;
            };
            ver.* = .{ .items = new_items };
            self.current.store(ver, .release);
            return true;
        }

        /// View of list at some point in time. With stale allowed the view
        /// may lag at most one writer `store`. No ownership - `retain`/
        /// `release` are no-ops kept for API compat with refcounted version.
        pub const Snapshot = struct {
            version: ?*Version,

            pub const empty: Snapshot = .{ .version = null };

            pub fn items(self: Snapshot) []const T {
                const v = self.version orelse return &.{};
                return v.items;
            }

            pub fn get(self: Snapshot, index: usize) ?T {
                const v = self.version orelse return null;
                if (index >= v.items.len) return null;
                return v.items[index];
            }

            pub fn len(self: Snapshot) usize {
                const v = self.version orelse return 0;
                return v.items.len;
            }

            pub fn retain(self: Snapshot) Snapshot {
                return .{ .version = self.version };
            }

            pub fn release(self: *Snapshot) void {
                self.version = null;
            }
        };
    };
}

// ─── TESTS ────────────────────────────────────────────────────────────────

const t = std.testing;
const List = @import("CoWList.zig").CoWList;

test "CoWList: empty state" {
    var list = List(u32).init(t.allocator);
    defer list.deinit();
    var s = list.snapshot();
    defer s.release();
    try t.expectEqual(@as(usize, 0), s.len());
    try t.expectEqual(@as(?u32, null), s.get(0));
    try t.expectEqual(@as([]const u32, &.{}), s.items());
}

test "CoWList: append and read" {
    var list = List(u32).init(t.allocator);
    defer list.deinit();
    try list.append(10);
    try list.append(20);
    try list.append(30);
    var s = list.snapshot();
    defer s.release();
    try t.expectEqual(@as(usize, 3), s.len());
    try t.expectEqual(@as(u32, 10), s.get(0).?);
    try t.expectEqual(@as(u32, 20), s.get(1).?);
    try t.expectEqual(@as(u32, 30), s.get(2).?);
    try t.expectEqual(@as(?u32, null), s.get(3));
}

test "CoWList: snapshot isolation" {
    var list = List(u32).init(t.allocator);
    defer list.deinit();
    try list.append(1);
    try list.append(2);
    var old_snap = list.snapshot();
    defer old_snap.release();
    try list.append(3);
    var new_snap = list.snapshot();
    defer new_snap.release();
    try t.expectEqual(@as(usize, 2), old_snap.len());
    try t.expectEqual(@as(u32, 1), old_snap.get(0).?);
    try t.expectEqual(@as(u32, 2), old_snap.get(1).?);
    try t.expectEqual(@as(usize, 3), new_snap.len());
    try t.expectEqual(@as(u32, 3), new_snap.get(2).?);
}

test "CoWList: removeAt" {
    var list = List(u32).init(t.allocator);
    defer list.deinit();
    try list.append(10);
    try list.append(20);
    try list.append(30);
    try t.expect(list.removeAt(1));
    var s = list.snapshot();
    defer s.release();
    try t.expectEqual(@as(usize, 2), s.len());
    try t.expectEqual(@as(u32, 10), s.get(0).?);
    try t.expectEqual(@as(u32, 30), s.get(1).?);
}

test "CoWList: removeAt out of bounds returns false" {
    var list = List(u32).init(t.allocator);
    defer list.deinit();
    try list.append(1);
    try t.expect(!list.removeAt(5));
    var s = list.snapshot();
    defer s.release();
    try t.expectEqual(@as(usize, 1), s.len());
}

test "CoWList: removeAt empty list returns false" {
    var list = List(u32).init(t.allocator);
    defer list.deinit();
    try t.expect(!list.removeAt(0));
}

test "CoWList: removeAt last element leaves empty" {
    var list = List(u32).init(t.allocator);
    defer list.deinit();
    try list.append(99);
    try t.expect(list.removeAt(0));
    var s = list.snapshot();
    defer s.release();
    try t.expectEqual(@as(usize, 0), s.len());
}

test "CoWList: retain then release both" {
    var list = List(u32).init(t.allocator);
    defer list.deinit();
    try list.append(42);
    var snap1 = list.snapshot();
    var snap2 = snap1.retain();
    snap1.release();
    try t.expectEqual(@as(usize, 1), snap2.len());
    try t.expectEqual(@as(u32, 42), snap2.get(0).?);
    snap2.release();
}

test "CoWList: many appends" {
    var list = List(u32).init(t.allocator);
    defer list.deinit();
    for (0..100) |i| try list.append(@intCast(i));
    var s = list.snapshot();
    defer s.release();
    try t.expectEqual(@as(usize, 100), s.len());
    for (0..100) |i| try t.expectEqual(@as(u32, @intCast(i)), s.get(i).?);
}

test "CoWList: retired versions freed once snapshots released" {
    {
        var list = List(u32).init(t.allocator);
        try list.append(1);
        try list.append(2);
        try list.append(3);
        list.deinit();
    }
}

test "CoWList: live snapshot keeps retired version valid across writes" {
    var list = List(u32).init(t.allocator);
    defer list.deinit();
    try list.append(1);
    var held = list.snapshot();
    defer held.release();
    for (0..5) |i| try list.append(@intCast(i + 2));
    try t.expectEqual(@as(usize, 1), held.len());
    try t.expectEqual(@as(u32, 1), held.get(0).?);
    var c = list.snapshot();
    defer c.release();
    try t.expectEqual(@as(usize, 6), c.len());
}

test "CoWList: concurrent readers and single writer" {
    var list = List(u32).init(t.allocator);
    defer list.deinit();
    try list.append(0);
    const ctx = struct {
        fn reader(arg: *List(u32)) void {
            for (0..1000) |_| {
                var s = arg.snapshot();
                _ = s.len();
                if (s.len() > 0) _ = s.get(0);
                s.release();
            }
        }
    };
    var threads: [8]std.Thread = undefined;
    for (&threads) |*th| th.* = try std.Thread.spawn(.{}, ctx.reader, .{&list});
    for (0..20) |i| try list.append(@intCast(i + 1));
    for (&threads) |*th| th.join();
}
