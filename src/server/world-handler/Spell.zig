const std = @import("std");
const domain = @import("domain");
const protocol = @import("protocol");
const world = @import("world");

const log = std.log.scoped(.handler_spell);

/// CMSG_CASTSPELL: parse and push into the owning map's ECS input queue.
/// Validation happens inside the simulation (SpellSystem) so the wire
/// handler stays transport-only.
pub fn handleCastSpell(
    io: std.Io,
    player: *domain.Player,
    payload: []u8,
) !void {
    const packet = try protocol.spell.CastSpellClient.unmarshal(payload);
    const map = mapFor(player) orelse return;
    map.pushSpellCastAsync(io, .{ .account_id = player.account_id, .packet = packet });
}

/// CMSG_ATTACKSWING: begin auto attacking the packed target guid.
pub fn handleAttackSwing(
    io: std.Io,
    player: *domain.Player,
    payload: []u8,
) !void {
    const packet = try protocol.spell.AttackSwingClient.unmarshal(payload);
    const map = mapFor(player) orelse return;
    map.pushAttackSwingAsync(io, .{ .account_id = player.account_id, .packet = packet });
}

/// CMSG_ATTACKSTOP: end auto attack.
pub fn handleAttackStop(
    io: std.Io,
    player: *domain.Player,
) !void {
    const map = mapFor(player) orelse return;
    map.pushAttackStopAsync(io, .{ .account_id = player.account_id });
}

/// CMSG_CANCEL_CAST: the client dropped its cast bar (ESC or movement);
/// destroy the matching cast entity so the server does not complete it.
pub fn handleCancelCast(
    io: std.Io,
    player: *domain.Player,
    payload: []u8,
) !void {
    const packet = try protocol.spell.CancelCastClient.unmarshal(payload);
    const map = mapFor(player) orelse return;
    map.pushCancelCastAsync(io, .{ .account_id = player.account_id, .packet = packet });
}

/// CMSG_SET_SHEATHED: the client drew/undrew weapons; store and propagate.
pub fn handleSetSheathed(
    io: std.Io,
    player: *domain.Player,
    payload: []u8,
) !void {
    const packet = try protocol.spell.SetSheathedClient.unmarshal(payload);
    const map = mapFor(player) orelse return;
    map.pushSetSheathedAsync(io, .{ .account_id = player.account_id, .packet = packet });
}

fn mapFor(player: *domain.Player) ?*world.MapInstance {
    const map_reference: ?*world.MapInstance = @ptrCast(@alignCast(player.active_map_reference));
    if (map_reference == null) {
        log.warn("Spell command from player not on any map (account_id={})", .{player.account_id});
    }
    return map_reference;
}
