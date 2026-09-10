//! Pure, stateless queries over a unit's active auras: the per-category
//! aura list, folded stat values, and the immunity predicate. Everything
//! is a function of (registry, aura slots); with the per-unit slot window
//! capped at AuraSlots.max_slots_per_target, scans stay tiny and no
//! reverse index is worth its bookkeeping.

const std = @import("std");
const ecs = @import("ecs");
const domain = @import("domain");

const component = @import("./EcsComponent.zig");
const MapEcs = @import("./MapEcs.zig").MapEcs;

const AuraEffect = domain.SpellDef.AuraEffect;
const Category = domain.SpellDef.Category;

/// Walks every (aura, effect) pair active on a unit — the one primitive
/// every fold and predicate below is built on. A unit's auras yield in
/// slot order, each aura's effects contiguously.
pub const UnitEffects = struct {
    slots: []const ?ecs.Entity,
    registry: *ecs.Registry,

    slot: usize = 0,
    aura: ?ecs.Entity = null,
    effects: []const AuraEffect = &.{},
    effect: usize = 0,

    pub const Item = struct { aura: ecs.Entity, effect: AuraEffect };

    pub fn init(map_ecs: *MapEcs, unit: ecs.Entity) UnitEffects {
        return .{
            .slots = map_ecs.state.aura_slots.items(unit),
            .registry = &map_ecs.registry,
        };
    }

    pub fn next(self: *UnitEffects) ?Item {
        while (true) {
            if (self.aura != null and self.effect < self.effects.len) {
                const item = Item{ .aura = self.aura.?, .effect = self.effects[self.effect] };
                self.effect += 1;
                return item;
            }
            if (self.slot >= self.slots.len) return null;
            const aura_ent = self.slots[self.slot];
            self.slot += 1;
            if (aura_ent) |ent| {
                self.aura = ent;
                self.effects = self.registry.getConst(component.Aura, ent).effects;
                self.effect = 0;
            }
        }
    }
};

/// Auras on `unit` carrying at least one effect of `category` — the unit's
/// by-effect-type view, in slot order. `buf` must hold at least
/// AuraSlots.max_slots_per_target entries; the result aliases it.
pub fn aurasAffecting(map_ecs: *MapEcs, unit: ecs.Entity, category: Category, buf: []ecs.Entity) []ecs.Entity {
    var len: usize = 0;
    var it = UnitEffects.init(map_ecs, unit);
    while (it.next()) |item| {
        if (item.effect.category() != category) continue;
        // One aura's effects yield contiguously, so a repeat is always the
        // immediately previous entry.
        if (len > 0 and buf[len - 1] == item.aura) continue;
        buf[len] = item.aura;
        len += 1;
    }
    return buf[0..len];
}

/// Effective run speed: the greatest increase and the greatest slow each
/// win their sign class and compose multiplicatively over the base. The
/// fold is a single scan, so the result never depends on slot order.
pub fn foldMovementSpeed(map_ecs: *MapEcs, unit: ecs.Entity) f32 {
    var best_increase: f32 = 1.0;
    var worst_slow: f32 = 1.0;
    var it = UnitEffects.init(map_ecs, unit);
    while (it.next()) |item| switch (item.effect) {
        .movement_speed_mod => |mod| {
            const factor = 1.0 + @as(f32, @floatFromInt(mod.pct)) / 100.0;
            if (factor >= 1.0) {
                if (factor > best_increase) best_increase = factor;
            } else {
                if (factor < worst_slow) worst_slow = factor;
            }
        },
        else => {},
    };
    return component.BASE_RUN_SPEED * best_increase * worst_slow;
}

/// Net max health modifier: signed amounts sum up.
pub fn foldMaxHealth(map_ecs: *MapEcs, unit: ecs.Entity) i32 {
    var sum: i32 = 0;
    var it = UnitEffects.init(map_ecs, unit);
    while (it.next()) |item| switch (item.effect) {
        .max_health_mod => |mod| sum += mod.amount,
        else => {},
    };
    return sum;
}

/// True when any active aura immunizes `unit` against `school`.
pub fn isImmuneTo(map_ecs: *MapEcs, unit: ecs.Entity, school: domain.SpellDef.School) bool {
    const school_bit = @as(u8, 1) << @intCast(@intFromEnum(school));
    var it = UnitEffects.init(map_ecs, unit);
    while (it.next()) |item| switch (item.effect) {
        .immune => |im| if (im.school_mask & school_bit != 0) return true,
        else => {},
    };
    return false;
}

/// The aura's first periodic effect; an aura carries at most one (v1).
pub fn firstPeriodic(effects: []const AuraEffect) ?AuraEffect.PeriodicDamage {
    for (effects) |effect| switch (effect) {
        .periodic_damage => |pd| return pd,
        else => {},
    };
    return null;
}

// --- tests -------------------------------------------------------------------------

const t = std.testing;

/// Minimal rig: a MapEcs with raw units and slot-assigned auras — no
/// systems, no wire; the queries never need them.
const Rig = struct {
    map_ecs: MapEcs,

    fn init() !Rig {
        return .{ .map_ecs = try MapEcs.init(t.allocator) };
    }

    fn deinit(self: *Rig) void {
        self.map_ecs.deinit();
    }

    fn unit(self: *Rig) ecs.Entity {
        return self.map_ecs.registry.create();
    }

    fn addAura(self: *Rig, owner: ecs.Entity, spell_id: u32, effects: []const AuraEffect) ecs.Entity {
        const aura_ent = self.map_ecs.registry.create();
        self.map_ecs.registry.add(aura_ent, component.Aura{
            .owner = owner,
            .caster = owner,
            .spell_id = spell_id,
            .school = .frost,
            .effects = effects,
        });
        _ = self.map_ecs.state.aura_slots.addAuraForTarget(owner, aura_ent).?;
        return aura_ent;
    }
};

test "movement speed fold: greatest of each sign class wins, order-free" {
    var rig = try Rig.init();
    defer rig.deinit();

    const slow_40 = [_]AuraEffect{.{ .movement_speed_mod = .{ .pct = -40 } }};
    const slow_50 = [_]AuraEffect{.{ .movement_speed_mod = .{ .pct = -50 } }};
    const inc_30 = [_]AuraEffect{.{ .movement_speed_mod = .{ .pct = 30 } }};
    const inc_20 = [_]AuraEffect{.{ .movement_speed_mod = .{ .pct = 20 } }};

    const a = rig.unit();
    _ = rig.addAura(a, 116, &slow_40);
    _ = rig.addAura(a, 117, &slow_50);
    _ = rig.addAura(a, 118, &inc_30);
    _ = rig.addAura(a, 119, &inc_20);
    try t.expectApproxEqAbs(@as(f32, 7.0) * 1.3 * 0.5, foldMovementSpeed(&rig.map_ecs, a), 0.0001);

    // Same modifiers in a different slot order fold identically.
    const b = rig.unit();
    _ = rig.addAura(b, 119, &inc_20);
    _ = rig.addAura(b, 116, &slow_40);
    _ = rig.addAura(b, 118, &inc_30);
    _ = rig.addAura(b, 117, &slow_50);
    try t.expectApproxEqAbs(foldMovementSpeed(&rig.map_ecs, a), foldMovementSpeed(&rig.map_ecs, b), 0.0001);
}

test "movement speed fold: one aura may carry the same effect twice" {
    var rig = try Rig.init();
    defer rig.deinit();

    const double_slow = [_]AuraEffect{
        .{ .movement_speed_mod = .{ .pct = -30 } },
        .{ .movement_speed_mod = .{ .pct = -50 } },
    };
    const u = rig.unit();
    _ = rig.addAura(u, 116, &double_slow);
    try t.expectApproxEqAbs(@as(f32, 7.0) * 0.5, foldMovementSpeed(&rig.map_ecs, u), 0.0001);
}

test "max health fold sums signed amounts" {
    var rig = try Rig.init();
    defer rig.deinit();

    const plus_50 = [_]AuraEffect{.{ .max_health_mod = .{ .amount = 50 } }};
    const plus_30 = [_]AuraEffect{.{ .max_health_mod = .{ .amount = 30 } }};
    const minus_10 = [_]AuraEffect{.{ .max_health_mod = .{ .amount = -10 } }};

    const u = rig.unit();
    _ = rig.addAura(u, 21562, &plus_50);
    _ = rig.addAura(u, 21563, &plus_30);
    _ = rig.addAura(u, 21564, &minus_10);
    try t.expectEqual(@as(i32, 70), foldMaxHealth(&rig.map_ecs, u));
}

test "immunity matches by school bit, any aura" {
    var rig = try Rig.init();
    defer rig.deinit();

    const immune_frost = [_]AuraEffect{.{ .immune = .{ .school_mask = 1 << @intFromEnum(domain.SpellDef.School.frost) } }};
    const u = rig.unit();
    try t.expect(!isImmuneTo(&rig.map_ecs, u, .frost));
    _ = rig.addAura(u, 45438, &immune_frost);
    try t.expect(isImmuneTo(&rig.map_ecs, u, .frost));
    try t.expect(!isImmuneTo(&rig.map_ecs, u, .fire));
}

test "aurasAffecting lists each aura once, in slot order" {
    var rig = try Rig.init();
    defer rig.deinit();

    const mixed = [_]AuraEffect{
        .{ .movement_speed_mod = .{ .pct = -10 } },
        .{ .max_health_mod = .{ .amount = 5 } },
        .{ .movement_speed_mod = .{ .pct = -20 } },
    };
    const slow = [_]AuraEffect{.{ .movement_speed_mod = .{ .pct = -30 } }};

    const u = rig.unit();
    const aura_a = rig.addAura(u, 116, &mixed);
    const aura_b = rig.addAura(u, 117, &slow);

    var buf: [56]ecs.Entity = undefined;
    const auras = aurasAffecting(&rig.map_ecs, u, .movement_speed, &buf);
    try t.expectEqual(@as(usize, 2), auras.len);
    try t.expectEqual(aura_a, auras[0]);
    try t.expectEqual(aura_b, auras[1]);
}

test "empty unit folds to base values" {
    var rig = try Rig.init();
    defer rig.deinit();

    const u = rig.unit();
    try t.expectApproxEqAbs(component.BASE_RUN_SPEED, foldMovementSpeed(&rig.map_ecs, u), 0.0001);
    try t.expectEqual(@as(i32, 0), foldMaxHealth(&rig.map_ecs, u));
    try t.expect(!isImmuneTo(&rig.map_ecs, u, .normal));
}
