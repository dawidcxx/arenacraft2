const std = @import("std");
const domain = @import("domain");
const protocol = @import("protocol");
const world = @import("world");

const Movement = domain.Movement;
const ProtocolMovement = protocol.movement;

/// Parses and lifts a movement packet. Simulation routing intentionally stops
/// here until WorldSimulation owns the movement command path.
pub fn handleMovement(
    io: std.Io,
    player: *domain.Player,
    payload: []const u8,
    opcode: protocol.movement.MovementOpCode,
) !void {
    const packet = try ProtocolMovement.AllMovementPackets.fromOpcodeAndBody(opcode, payload);
    const map_reference: ?*world.MapInstance = @ptrCast(@alignCast(player.active_map_reference));

    if (map_reference) |map| {
        map.pushMovementCommandAsync(io, .{ .account_id = player.account_id, .packet = packet });
    } else {
        log.warn("Tried to push movement command of a player not currently on any map (account_id={})", .{player.account_id});
    }
}

const log = std.log.scoped(.handler_movement);
