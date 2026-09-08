const std = @import("std");
const domain = @import("domain");
const proto = @import("protocol");
const world = @import("world");

const log = std.log.scoped(.handler_spell);

// Spell command handlers are transport-only: parse the wire payload and
// forward it to the owning map's simulation. The forwarding path is not
// ported yet, so these capture packets and stop there.

/// CMSG_CAST_SPELL (0x12E): the client requested a spell cast.
pub fn handleCastSpell(
    io: std.Io,
    player: *domain.Player,
    payload_scratch_buf: []const u8,
) !void {
    const packet = try proto.spell.CastSpellClient.unmarshal(payload_scratch_buf);
    const map_reference: ?*world.MapInstance = @ptrCast(@alignCast(player.active_map_reference));

    if (map_reference) |map| {
        map.pushSpellCastAsync(io, .{ .account_id = player.account_id, .packet = packet });
    } else {
        log.warn("Player(account_id='{}') tried to cast spell but is not in map?", .{player.account_id});
    }
}

/// CMSG_ATTACKSWING (0x141): the client toggled auto attack on a target.
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
    _ = io;
    _ = payload;
    log.debug("Cancel cast captured (account_id={}); handling pending", .{player.account_id});
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
