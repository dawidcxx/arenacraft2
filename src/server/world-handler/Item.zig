const std = @import("std");
const domain = @import("domain");
const game_data = @import("game_data");
const protocol = @import("protocol");
const WorldServerConnection = @import("./WorldServerConnection.zig").WorldServerConnection;

const world = protocol.world;

/// CMSG_ITEM_QUERY_SINGLE: the client asks for the full item template of an
/// entry it does not have cached (paper doll tooltips, char list gear, ...).
/// Valid at any point after auth; the character screen queries before login.
pub fn handleItemQuerySingle(
    alloc: std.mem.Allocator,
    conn: *WorldServerConnection,
    payload: []u8,
) !void {
    const query = world.ItemQuerySingleClient.unmarshal(payload) catch {
        return error.InvalidPacket;
    };

    const def = game_data.items.findItem(query.entry);
    if (def == null) {
        std.log.debug("world: item query for unknown entry={d}", .{query.entry});
    }
    return try conn.sendMessage(alloc, world.ItemQuerySingleResponseServer{
        .entry = query.entry,
        .def = def,
    });
}
