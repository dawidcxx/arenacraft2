const std = @import("std");
const builtin = @import("builtin");

const ecs = @import("ecs");
const stdx = @import("stdx");
const domain = @import("domain");
const Arc = stdx.Arc;
const ArcRuntime = stdx.ArcRuntime;

const component = @import("EcsComponent.zig");
const EcsEvent = @import("EcsInput.zig").EcsEvent;
const EcsEventType = @import("EcsInput.zig").EcsEventType;
const Input = @import("EcsInput.zig").Input;
const Output = @import("EcsInput.zig").Output;

pub const MapEcs = struct {
    /// Per-tick context handed to every system. Extend freely; the uniform
    /// `run(*MapEcs, Frame)` signature stays stable.
    pub const Frame = struct {
        io: std.Io,
        dt: u64,
        time_now: u64,
        clock: *stdx.Clock,
        arena_allocator: std.mem.Allocator,
    };

    const Self = @This();

    gpa: std.mem.Allocator,
    registry: ecs.Registry,
    input_buffer: std.ArrayList(Input),
    output_buffer: std.ArrayList(Output),

    events: std.EnumArray(EcsEventType, std.ArrayList(EcsEvent)),

    pub fn init(gpa: std.mem.Allocator) !MapEcs {
        var buffered_inputs: std.ArrayList(Input) = try .initCapacity(gpa, 1024);
        errdefer buffered_inputs.deinit(gpa);

        var buffered_outputs: std.ArrayList(Output) = try .initCapacity(gpa, 1024);
        errdefer buffered_outputs.deinit(gpa);

        const events = std.EnumArray(EcsEventType, std.ArrayList(EcsEvent)).init(.{
            .player_joined = .empty,
            .player_left = .empty,
        });

        return .{
            .gpa = gpa,
            .registry = ecs.Registry.init(gpa),
            .input_buffer = buffered_inputs,
            .events = events,
            .output_buffer = buffered_outputs,
        };
    }

    pub fn deinit(self: *MapEcs) void {
        self.registry.deinit();
        self.input_buffer.deinit(self.gpa);
        var it = self.events.iterator();
        while (it.next()) |event_list| event_list.value.deinit(self.gpa);
        self.output_buffer.deinit(self.gpa);
    }

    pub fn run(self: *MapEcs, frame: Frame) !void {
        try @import("./InputSystem.zig").run(self, frame);
        try @import("./SpellSystem.zig").run(self, frame);
        try @import("./MeleeSystem.zig").run(self, frame);
        try @import("./AuraSystem.zig").run(self, frame);
        try @import("./PlayerVisibilitySystem.zig").run(self, frame);
        try @import("./ClientInitSystem.zig").run(self, frame);
        try @import("./OutboundPacketSystem.zig").run(self, frame);

        self.input_buffer.clearRetainingCapacity();
        self.output_buffer.clearRetainingCapacity();
        var events_it = self.events.iterator();
        while (events_it.next()) |event_list| event_list.value.clearRetainingCapacity();
    }

    pub fn addInput(self: *MapEcs, input: Input) void {
        self.input_buffer.append(self.gpa, input) catch @panic("MapEcs cannot queue input");
    }

    pub fn addEvent(self: *MapEcs, event: EcsEvent) !void {
        const tag = std.meta.activeTag(event);
        try self.events.getPtr(tag).append(self.gpa, event);
    }

    /// Linear scan for the player entity of an account. Maps are small;
    /// revisit with an index if this ever shows up in profiles.
    pub fn findPlayer(self: *MapEcs, account_id: u64) ?ecs.Entity {
        var view = self.registry.view(.{component.AccountId}, .{});
        var iter = view.entityIterator();
        while (iter.next()) |entity| {
            if (self.registry.getConst(component.AccountId, entity).id == account_id) return entity;
        }
        return null;
    }

    /// Linear scan for the entity carrying a guid (players today). Used to
    /// resolve client-supplied target guids into ECS entities.
    pub fn findByGuid(self: *MapEcs, guid: domain.ObjectGuid) ?ecs.Entity {
        var view = self.registry.view(.{component.Guid}, .{});
        var iter = view.entityIterator();
        while (iter.next()) |entity| {
            if (self.registry.getConst(component.Guid, entity).value.valueOf() == guid.valueOf()) return entity;
        }
        return null;
    }

    pub fn sendTo(self: *Self, player_entity: ecs.Entity, packet_unmarshalled: anytype) !void {
        const packet_bytes: Arc([]const u8) = try .of(packet_unmarshalled.marshal(ArcRuntime.allocator()));
        defer packet_bytes.release();

        if (builtin.mode == .Debug) {
            const p = self.registry.tryGetConst(component.Player, player_entity) orelse {
                std.debug.panic("Program error, tried to MapEcs#sendTo send a packet to a non player entity", .{});
            };
            _ = p;
        }

        const opcode = @TypeOf(packet_unmarshalled).opcode;

        try self.output_buffer.append(self.gpa, .{
            .sendTo = .{
                .opcode = @intFromEnum(opcode),
                .data = packet_bytes.retain(),
                .recv = player_entity,
            },
        });
    }

    const BroadcastProps = struct { ignore_sender: bool };
    pub fn broadcast(self: *Self, broadcast_request: struct { ecs.Entity, BroadcastProps }, packet_unmarshalled: anytype) !void {
        const player_entity = broadcast_request[0];
        const props = broadcast_request[1];

        const packet_bytes: Arc([]const u8) = try .of(packet_unmarshalled.marshal(ArcRuntime.allocator()));
        defer packet_bytes.release();

        if (builtin.mode == .Debug) {
            // The sender may already be destroyed (e.g. leave broadcasts);
            // only validate a live sender is actually a player.
            if (self.registry.valid(player_entity)) {
                const p = self.registry.tryGetConst(component.Player, player_entity) orelse {
                    std.debug.panic("Program error, tried to MapEcs#broadcast a packet from a non player entity", .{});
                };
                _ = p;
            }
        }

        const opcode = @TypeOf(packet_unmarshalled).opcode;

        try self.output_buffer.append(self.gpa, .{
            .broadcast = .{
                .opcode = @intFromEnum(opcode),
                .data = packet_bytes.retain(),
                .sender = player_entity,
                .ignore_sender = props.ignore_sender,
            },
        });
    }
};

test {
    _ = @import("./EcsTest.zig");
    _ = @import("./SpellTest.zig");
}
