pub const MapInstance = @import("MapInstance.zig").MapInstance;
pub const MapEcs = @import("ecs/MapEcs.zig").MapEcs;
pub const WorldSimulation = @import("WorldSimulation.zig").WorldSimulation;
pub const ecs = @import("ecs");

test "world module" {
    _ = MapInstance;
    _ = WorldSimulation;
}

test "ecs dependency" {
    _ = ecs.Registry;
}

test "ecs pipeline" {
    _ = @import("ecs/EcsTest.zig");
}
