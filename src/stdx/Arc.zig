const std = @import("std");

/// Runtime allocator used by Arc(T) to allocate control blocks and release
/// wrapped allocations.
pub const ArcRuntime = struct {
    var runtime_allocator: ?std.mem.Allocator = null;

    pub fn setAllocator(alloc: std.mem.Allocator) void {
        runtime_allocator = alloc;
    }

    pub fn allocator() std.mem.Allocator {
        return runtime_allocator orelse @panic("Arc runtime allocator has not been set");
    }
};

/// An atomic reference-counted owner for an allocation.
///
/// `of` takes ownership of an allocation made with `ArcRuntime.allocator()`.
/// Pointer and slice allocations are supported:
///
///     const allocation = try ArcRuntime.allocator().create(Item);
///     var item: Arc(@TypeOf(allocation)) = try .of(allocation);
///     defer item.release();
///
///     const bytes = try ArcRuntime.allocator().dupe(u8, "hello");
///     var message: Arc(@TypeOf(bytes)) = try .of(bytes);
///     defer message.release();
pub fn Arc(comptime T: type) type {
    comptime validateAllocationType(T);

    return struct {
        const Inner = struct {
            refs: std.atomic.Value(usize),
            allocation: T,
        };

        inner: *Inner,

        const Self = @This();

        /// Takes ownership of allocation. The input may be either T or an
        /// error union containing T. Errors are propagated unchanged.
        pub fn of(value: anytype) anyerror!Self {
            const allocation: T = if (comptime @typeInfo(@TypeOf(value)) == .error_union) blk: {
                break :blk value catch |err| return err;
            } else value;

            const allocator = ArcRuntime.allocator();
            const inner = allocator.create(Inner) catch {
                freeAllocation(allocator, allocation);
                return error.OutOfMemory;
            };

            inner.* = .{
                .refs = std.atomic.Value(usize).init(1),
                .allocation = allocation,
            };
            return .{ .inner = inner };
        }

        /// Returns another owner of the same allocation.
        pub fn retain(self: Self) Self {
            _ = self.inner.refs.fetchAdd(1, .monotonic);
            return .{ .inner = self.inner };
        }

        /// Returns the wrapped allocation without transferring ownership.
        pub fn get(self: Self) T {
            return self.inner.allocation;
        }

        /// Releases one owner. The wrapped allocation is released with the
        /// runtime allocator when the final owner goes away.
        pub fn release(selfi: *const Self) void {
            const self: *Self = @constCast(selfi);
            if (self.inner.refs.fetchSub(1, .release) == 1) {
                const allocator = ArcRuntime.allocator();
                freeAllocation(allocator, self.inner.allocation);
                allocator.destroy(self.inner);
            }
            self.inner = undefined;
        }
    };
}

fn validateAllocationType(comptime T: type) void {
    switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .one, .slice => {},
            else => @compileError("Arc only supports single-item pointers and slices"),
        },
        else => @compileError("Arc must wrap a pointer or slice allocation"),
    }
}

fn freeAllocation(allocator: std.mem.Allocator, allocation: anytype) void {
    const T = @TypeOf(allocation);
    switch (@typeInfo(T).pointer.size) {
        .one => allocator.destroy(allocation),
        .slice => allocator.free(@constCast(allocation)),
        else => unreachable,
    }
}

test "Arc: wraps and releases pointer allocation" {
    const TestData = struct { value: u32 };
    ArcRuntime.setAllocator(std.testing.allocator);

    const allocation = try ArcRuntime.allocator().create(TestData);
    allocation.value = 42;

    var arc: Arc(@TypeOf(allocation)) = try .of(allocation);
    try std.testing.expectEqual(@as(u32, 42), arc.get().value);

    var retained = arc.retain();
    arc.release();
    try std.testing.expectEqual(@as(u32, 42), retained.get().value);
    retained.release();
}

test "Arc: wraps and releases slice allocation" {
    ArcRuntime.setAllocator(std.testing.allocator);

    const allocation = try ArcRuntime.allocator().dupe(u8, "packet");
    var arc: Arc(@TypeOf(allocation)) = try .of(allocation);
    try std.testing.expectEqualStrings("packet", arc.get());
    arc.release();
}

test "Arc: of propagates errors" {
    ArcRuntime.setAllocator(std.testing.allocator);

    const allocation: error{TestFailure}![]u8 = error.TestFailure;
    try std.testing.expectError(error.TestFailure, Arc([]u8).of(allocation));
}
