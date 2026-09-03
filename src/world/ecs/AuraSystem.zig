//! Aura lifecycle. Aura entities tick here: expired auras notify the
//! clients (slot removal + restored movement speed) and despawn. Aura
//! application/refresh lives in SpellSystem.applyAura.

const MapEcs = @import("MapEcs.zig").MapEcs;
const SpellSystem = @import("SpellSystem.zig");

pub fn run(map_ecs: *MapEcs, frame: MapEcs.Frame) !void {
    try SpellSystem.tickAuras(map_ecs, frame);
}
