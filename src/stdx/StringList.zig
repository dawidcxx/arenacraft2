const std = @import("std");

/// A growable list of owned strings backed by a single arena.
///
/// Strings appended via `append()` are dupe'd into the arena, so the caller
/// can free the original input immediately. When `deinit()` is called, all
/// string storage and internal bookkeeping are freed in one pass — no
/// per-string deallocation needed.
pub const StringList = struct {
    arena: std.heap.ArenaAllocator,
    list: std.ArrayList([]const u8),

    /// Creates an empty list. The backing `gpa` is used for the arena's
    /// internal bookkeeping only; all string data is stored within the arena.
    pub fn init(gpa: std.mem.Allocator) StringList {
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .list = .empty,
        };
    }

    /// Frees all memory owned by this list: the arena drops every dupe'd
    /// string and the ArrayList's internal buffer in one call.
    pub fn deinit(self: *StringList) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Duplicates `s` into the arena and appends the resulting pointer to the
    /// list. The caller retains ownership of the original `s` and must free it
    /// separately if it was dynamically allocated.
    pub fn append(self: *StringList, s: []const u8) std.mem.Allocator.Error!void {
        const dupe = try self.arena.allocator().dupe(u8, s);
        try self.list.append(self.arena.allocator(), dupe);
    }

    /// Returns the number of strings currently stored.
    pub fn len(self: *const StringList) usize {
        return self.list.items.len;
    }

    /// Returns the list of string pointers as a slice. The slice is valid
    /// until the next `append()` or `deinit()` call.
    pub fn slice(self: *const StringList) []const []const u8 {
        return self.list.items;
    }
};

// ─── TESTS ────────────────────────────────────────────────────────────────────

const t = std.testing;

test "StringList: append and slice" {
    var sl = StringList.init(t.allocator);
    defer sl.deinit();

    try sl.append("hello");
    try sl.append("world");

    const s = sl.slice();
    try t.expectEqual(2, s.len);
    try t.expectEqualStrings("hello", s[0]);
    try t.expectEqualStrings("world", s[1]);
}

test "StringList: empty list" {
    var sl = StringList.init(t.allocator);
    defer sl.deinit();

    try t.expectEqual(0, sl.len());
    try t.expectEqual(0, sl.slice().len);
}

test "StringList: ownership — original freed before deinit" {
    var sl = StringList.init(t.allocator);
    defer sl.deinit();

    {
        const temp = try t.allocator.dupe(u8, "temp_string");
        defer t.allocator.free(temp);
        try sl.append(temp);
        // temp is freed here, but the arena copy survives
    }

    try t.expectEqualStrings("temp_string", sl.slice()[0]);
}

test "StringList: deinit frees everything" {
    var sl = StringList.init(t.allocator);
    try sl.append("test");
    sl.deinit();
    // No use-after-free — deinit cleans up the arena
}
