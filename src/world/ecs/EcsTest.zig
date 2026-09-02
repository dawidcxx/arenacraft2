//! End-to-end tests for the map ECS pipeline:
//! join -> introductions, move -> transform + rebroadcast, leave -> despawn.

const std = @import("std");
const ecs = @import("ecs");
const stdx = @import("stdx");
const domain = @import("domain");
const protocol = @import("protocol");

const component = @import("EcsComponent.zig");
const MapEcs = @import("MapEcs.zig").MapEcs;

test MapEcs {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var clock = stdx.Clock.init(io);
    const now_ms = clock.nowMs();

    var map_ecs = try MapEcs.init(alloc);
    defer map_ecs.deinit();

    try map_ecs.run(.{ .clock = &clock, .io = io, .arena_allocator = alloc, .dt = 1, .time_now = now_ms });
}
