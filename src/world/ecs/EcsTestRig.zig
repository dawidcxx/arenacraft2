//! Test-only rig shared by the system tests: a MapEcs with fully wired
//! players, frame plumbing, aura spawning that mirrors SpellSystem, and
//! broadcast counting. Never imported outside test blocks.

const std = @import("std");
const ecs = @import("ecs");
const domain = @import("domain");
const stdx = @import("stdx");

const component = @import("./EcsComponent.zig");
const AuraQuery = @import("./AuraQuery.zig");
const MapEcs = @import("./MapEcs.zig").MapEcs;

pub const Rig = struct {
    map_ecs: MapEcs,
    clock: stdx.Clock,
    session: domain.Session,
    inbox_buf: [16]domain.Session.InboxMsg = undefined,
    owner: ecs.Entity,
    caster: ecs.Entity,

    pub fn init() !Rig {
        const io = std.testing.io;
        stdx.ArcRuntime.setAllocator(std.testing.allocator);
        var rig: Rig = .{
            .map_ecs = try MapEcs.init(std.testing.allocator),
            .clock = stdx.Clock.init(io),
            .session = undefined,
            .owner = undefined,
            .caster = undefined,
        };
        rig.session = .{
            .account = "test",
            .account_id = 1,
            .active_realm = .{ .id = 1, .name = "test" },
            .inbox = .init(&rig.inbox_buf),
        };
        rig.owner = rig.player(1);
        rig.caster = rig.player(2);
        return rig;
    }

    pub fn deinit(self: *Rig) void {
        for (self.map_ecs.output_buffer.items) |out| switch (out) {
            .broadcast => |b| b.data.release(),
            .sendTo => |s| s.data.release(),
        };
        self.map_ecs.deinit();
    }

    pub fn player(self: *Rig, guid_raw: u64) ecs.Entity {
        const registry = &self.map_ecs.registry;
        const ent = registry.create();
        registry.add(ent, component.Player{ .session = &self.session });
        registry.add(ent, component.Guid{ .value = .{ .raw = guid_raw } });
        registry.add(ent, component.Level{ .value = 80 });
        registry.add(ent, component.MoveSpeed{ .run = component.BASE_RUN_SPEED });
        return ent;
    }

    pub fn frame(self: *Rig, dt: u32) MapEcs.Frame {
        return .{
            .io = std.testing.io,
            .dt = dt,
            .time_now = 0,
            .clock = &self.clock,
            .arena_allocator = std.testing.allocator,
        };
    }

    /// Drains events exactly like MapEcs.run would between frames; output
    /// accumulates for assertions.
    pub fn drainEvents(self: *Rig) void {
        var events_it = self.map_ecs.events.iterator();
        while (events_it.next()) |event_list| event_list.value.clearRetainingCapacity();
    }

    /// Queues an aura application exactly like SpellSystem would.
    pub fn requestAura(self: *Rig, owner: ecs.Entity, caster: ecs.Entity, spell_id: u32, school: domain.SpellDef.School, effects: []const domain.SpellDef.AuraEffect, duration_ms: u32) ecs.Entity {
        const registry = &self.map_ecs.registry;
        const aura_ent = registry.create();
        registry.add(aura_ent, component.Aura{
            .owner = owner,
            .caster = caster,
            .spell_id = spell_id,
            .school = school,
            .effects = effects,
        });
        if (duration_ms > 0) {
            registry.add(aura_ent, component.AuraDuration{ .remaining = duration_ms, .max = duration_ms });
        }
        if (AuraQuery.firstPeriodic(effects)) |tick| {
            registry.add(aura_ent, component.AuraPeriodic{ .interval_ms = tick.interval_ms, .timer = tick.interval_ms });
        }
        self.map_ecs.addEvent(.{ .aura_apply_request = .{ .aura = aura_ent } });
        return aura_ent;
    }

    pub fn occupiedAuras(self: *Rig, unit: ecs.Entity) usize {
        var count: usize = 0;
        for (self.map_ecs.state.aura_slots.items(unit)) |slot| {
            if (slot != null) count += 1;
        }
        return count;
    }

    pub fn broadcastCount(self: *Rig, opcode: u32) usize {
        var count: usize = 0;
        for (self.map_ecs.output_buffer.items) |out| switch (out) {
            .broadcast => |b| {
                if (b.opcode == opcode) count += 1;
            },
            .sendTo => {},
        };
        return count;
    }
};
