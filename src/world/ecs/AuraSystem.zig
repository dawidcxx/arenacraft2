//! Aura lifecycle skeleton: spell effects that outlive their cast become
//! entity roots. Wire facts in docs/auras.md; full design report delivered
//! in chat (components, algorithms, policies). Components pending
//! reintroduction — stubs only for now.

const std = @import("std");
const ecs = @import("ecs");
const domain = @import("domain");
const proto = @import("protocol");
const c = @import("./EcsComponent.zig");

const MapEcs = @import("MapEcs.zig").MapEcs;

const log = std.log.scoped(.aura_system);

pub fn run(map_ecs: *MapEcs, frame: MapEcs.Frame) !void {
    const registry = &map_ecs.registry;
    var aura_slots = &map_ecs.state.aura_slots;

    for (map_ecs.events.get(.aura_applied).items) |event| {
        const aura_ent = event.aura_applied.aura;
        const aura = registry.getConst(c.Aura, aura_ent);

        // 1. Book keep the aura
        const aura_slot = aura_slots.addAuraForTarget(aura.owner, aura_ent) orelse continue;

        registry.add(aura_ent, c.AuraNeedsApply{});

        // 2. Notify client
        const elapsed = registry.getConst(c.AuraDuration, aura_ent).elapsed;
        const max_duration = registry.getConst(c.AuraMaxDuration, aura_ent).max_duration;
        const packet = proto.spell.AuraUpdateServer{
            .spell_id = aura.spell_id,
            .caster_guid = registry.getConst(c.Guid, aura.caster).value,
            .target_guid = registry.getConst(c.Guid, aura.owner).value,
            .slot = aura_slot,
            .caster_level = registry.getConst(c.Level, aura.caster).value,
            .remaining_ms = elapsed,
            .max_duration_ms = max_duration,
        };
        map_ecs.broadcast(.{ aura.owner, .{ .ignore_sender = false } }, packet);
    }

    var slows_to_apply_view = registry.view(.{ c.AuraNeedsApply, c.AuraMovementSlow, c.Aura }, .{});
    var slows_to_apply_it = slows_to_apply_view.entityIterator();
    while (slows_to_apply_it.next()) |slow_aura_ent| {
        defer registry.remove(c.AuraNeedsApply, slow_aura_ent);
        const aura = registry.getConst(c.Aura, slow_aura_ent);
        const slow = registry.getConst(c.AuraMovementSlow, slow_aura_ent);
        var owner_movement_speed = registry.get(c.MoveSpeed, aura.owner);
        owner_movement_speed.run = c.BASE_RUN_SPEED * slow.pct;
        // TODO: publish
    }

    var aura_duration_view = registry.view(.{c.AuraDuration}, .{});
    var aura_duration_it = aura_duration_view.entityIterator();
    while (aura_duration_it.next()) |aura_duration_ent| {
        var duration = registry.get(c.AuraDuration, aura_duration_ent);
        duration.elapsed -%= frame.dt;
        if (duration.elapsed == 0) {
            const aura = registry.getConst(c.Aura, aura_duration_ent);
            const aura_owner_guid = registry.getConst(c.Guid, aura.owner).value;
            const slot = aura_slots.removeAuraForTarget(aura.owner, aura_duration_ent) orelse unreachable;
            map_ecs.broadcast(.{ aura.owner, .{ .ignore_sender = false } }, proto.spell.AuraUpdateServer.remove(aura_owner_guid, slot));
            registry.destroy(aura_duration_ent);
        }
    }
}

// Book keeping helper state
// Needed for consistent slot ordering
// which is required on protocol level
pub const AuraSlots = struct {
    // { [ key: Unit ] : Aura[] }
    storage: std.AutoArrayHashMapUnmanaged(ecs.Entity, std.ArrayListUnmanaged(ecs.Entity)),
    gpa: std.mem.Allocator,

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator) Self {
        return .{
            .storage = .empty,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Self) void {
        var storage_it = self.storage.iterator();
        while (storage_it.next()) |storage_entry| storage_entry.value_ptr.deinit(self.gpa);
        self.storage.deinit(self.gpa);
    }

    pub fn addAuraForTarget(self: *Self, target: ecs.Entity, aura: ecs.Entity) ?u8 {
        var gop = self.storage.getOrPut(self.gpa, target) catch unreachable;
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayListUnmanaged(ecs.Entity).initCapacity(self.gpa, 52) catch unreachable;
        }
        gop.value_ptr.appendBounded(aura) catch {
            @branchHint(.unlikely);
            log.info("Target reached aura limit count, dropping aura", .{});
            return null;
        };
        return @truncate(gop.value_ptr.items.len - 1);
    }

    pub fn removeAuraForTarget(self: *Self, target: ecs.Entity, aura: ecs.Entity) ?u8 {
        const aura_list = self.storage.getPtr(target) orelse return null;
        const index_of = std.mem.findScalarPos(ecs.Entity, aura_list.items, 0, aura) orelse return null;
        _ = aura_list.swapRemove(index_of);
        return @truncate(index_of);
    }

    pub fn items(self: *const Self, target: ecs.Entity) []const ecs.Entity {
        const aura_list = self.storage.get(target) orelse return &.{};
        return aura_list.items;
    }
};
