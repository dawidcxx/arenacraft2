pub const MapInstance = @import("./MapInstance.zig").MapInstance;
pub const MapEcs = @import("./ecs/MapEcs.zig").MapEcs;
pub const WorldSimulation = @import("./WorldSimulation.zig").WorldSimulation;
pub const ecs = @import("ecs");

test {
    _ = @import("ecs");
    _ = @import("./MapInstance.zig");
    _ = @import("./WorldSimulation.zig");
    _ = @import("./ecs/MapEcs.zig");
}
