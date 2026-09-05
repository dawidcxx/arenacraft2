const std = @import("std");
const domain = @import("domain");
const protocol = @import("protocol");
const world = @import("world");

const log = std.log.scoped(.handler_spell);

// Spell command handlers are transport-only: parse the wire payload and
// forward it to the owning map's simulation. All validation and game
// logic happens inside the map ECS.

/// CMSG_CAST_SPELL (0x12E): the client requested a spell cast.
pub fn handleCastSpell(
    io: std.Io,
    player: *domain.Player,
    payload: []const u8,
) !void {
    const packet = try protocol.spell.CastSpellClient.unmarshal(payload);
    const map_reference: ?*world.MapInstance = @ptrCast(@alignCast(player.active_map_reference));

    if (map_reference) |map| {
        map.pushCastSpellAsync(io, .{ .account_id = player.account_id, .packet = packet });
    } else {
        log.warn("Tried to push cast spell of a player not currently on any map (account_id={})", .{player.account_id});
    }
}

/// CMSG_ATTACKSWING (0x141): the client toggled auto attack on a target.
/// Auto attack is not on the cast pipeline; captured until the melee
/// slice lands.
pub fn handleAttackSwing(
    io: std.Io,
    player: *domain.Player,
    payload: []const u8,
) !void {
    _ = io;
    _ = payload;
    log.debug("Attack swing captured (account_id={}); handling pending", .{player.account_id});
}

/// CMSG_ATTACKSTOP (0x142): the client ended auto attack. No payload.
pub fn handleAttackStop(
    io: std.Io,
    player: *domain.Player,
) !void {
    _ = io;
    log.debug("Attack stop captured (account_id={}); handling pending", .{player.account_id});
}

/// CMSG_CANCEL_CAST (0x12F): the client dropped its cast bar.
pub fn handleCancelCast(
    io: std.Io,
    player: *domain.Player,
    payload: []const u8,
) !void {
    const packet = try protocol.spell.CancelCastClient.unmarshal(payload);
    const map_reference: ?*world.MapInstance = @ptrCast(@alignCast(player.active_map_reference));

    if (map_reference) |map| {
        map.pushCancelCastAsync(io, .{ .account_id = player.account_id, .packet = packet });
    } else {
        log.warn("Tried to push cancel cast of a player not currently on any map (account_id={})", .{player.account_id});
    }
}

/// CMSG_SET_SHEATHED (0x1E0): the client drew/undrew its weapons.
pub fn handleSetSheathed(
    io: std.Io,
    player: *domain.Player,
    payload: []const u8,
) !void {
    _ = io;
    _ = payload;
    log.debug("Set sheathed captured (account_id={}); handling pending", .{player.account_id});
}
