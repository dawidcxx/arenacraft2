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
    const alloc = frame.arena_allocator;
    _ = alloc;

    const registry = &map_ecs.registry;
    var aura_slots = &map_ecs.state.aura_slots;

    for (map_ecs.events.get(.aura_applied).items) |event| {
        const aura_ent = event.aura_applied.aura;
        const aura = registry.getConst(c.Aura, aura_ent);

        // 1. Book keep the aura
        const aura_slot = aura_slots.addAuraForTarget(aura.owner, aura_ent) orelse continue;

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

    pub fn removeAuraForTarget(self: *Self, target: ecs.Entity, aura: ecs.Entity) void {
        var aura_list = self.storage.get(target) orelse return;
        const index_of = std.mem.findScalarPos(ecs.Entity, aura_list.items, 0, aura) orelse return;
        const removed_aura = aura_list.swapRemove(index_of);
        _ = removed_aura;
    }

    pub fn items(self: *const Self, target: ecs.Entity) []const ecs.Entity {
        const aura_list = self.storage.get(target) orelse return &.{};
        return aura_list.items;
    }
};
