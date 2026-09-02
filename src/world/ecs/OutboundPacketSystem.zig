const std = @import("std");
const ecs = @import("ecs");

const component = @import("EcsComponent.zig");
const MapEcs = @import("MapEcs.zig").MapEcs;

pub fn run(map_ecs: *MapEcs, frame: MapEcs.Frame) void {
    const reg = &map_ecs.registry;

    for (map_ecs.output_buffer.items) |item| {
        // NOTE: in the far future could consider
        // batching those together via MultiArrayList
        switch (item) {
            .sendTo => |send_to| {
                defer send_to.data.release();
                const recv_player = reg.getConst(component.Player, send_to.recv);
                recv_player.session.sendAsync(frame.io, send_to.opcode, send_to.data.retain());
            },
            .broadcast => |broadcast| {
                defer broadcast.data.release();
                var players_view = reg.view(.{component.Player}, .{});
                var players_view_it = players_view.entityIterator();
                while (players_view_it.next()) |player_entity| {
                    if (broadcast.ignore_sender == true and broadcast.sender == player_entity) continue;
                    const player = reg.getConst(component.Player, player_entity);
                    player.session.sendAsync(frame.io, broadcast.opcode, broadcast.data.retain());
                }
            },
        }
    }
}

const log = std.log.scoped(.outbound_packet_system);
