# Spells & combat (v1)

Durable notes on the v1 spell pipeline: entity model, wire protocol facts,
and extension points. See `docs/items.md` for the same treatment of items.

## Entity model

Spells live in the map ECS as entities, not as code paths on the player:

```
CMSG_CAST_SPELL ──► SpellSystem.handleCast ──► SpellCast entity (caster, target, finish_ms)
CMSG_ATTACKSWING ─► SpellSystem.handleSwing ─► Attacking component on attacker
SpellSystem.run ──► cast completes ──────────► damage + Aura entity + packets
AuraSystem ───────► aura expires ────────────► slot removal + speed restore
```

- `SpellCast` entity: spawned at cast start, destroyed at completion. One
  cast per caster (second cast gets `SPELL_FAILED_SPELL_IN_PROGRESS`).
- `Aura` entity: one per (target, spell); re-applying refreshes instead of
  stacking. Slot assignment scans the target's live auras (u8 slots).
- `Attacking` component: melee state on the attacker. MeleeSystem swings on
  a 2s cadence while the target is alive and within 5 yards; out-of-range
  swings are silently deferred.
- Systems tick in `MapEcs.run` order: Input → SpellSystem → MeleeSystem →
  AuraSystem → PlayerVisibility → ClientInit → OutboundPacket.
- Health lives in the `Health` component (initialized from derived stats at
  join) and reaches clients through VALUES update blocks. v1 has no death:
  health bottoms out at 1 (`SpellSystem.health_floor`).

## Wire protocol (3.3.5a, build 12340)

All packets live in `protocol.spell.*` (`SpellProtocol.zig`); opcodes join
the shared `WorldProtocol.Opcode` enum. Formats transcribed from the
reference core (Spell.cpp, Unit.cpp, SpellAuras.cpp, CombatHandler.cpp).

- `CMSG_CAST_SPELL` (0x12E): `u8 cast_count, u32 spell_id, u8 cast_flags`,
  then SpellCastTargets (`u32 target_mask` + packed guid when the mask has
  the UNIT bit). For missile spells the client follows with trajectory
  elevation/speed + a movement block — we stop parsing after the target.
- `SMSG_SPELL_START` (0x131): packed caster twice (cast-item slot then
  caster), cast_count, spell id, cast flags (0x2 = trajectory), delay ms,
  then the target block.
- `SMSG_SPELL_GO` (0x132): packed caster twice, cast_count, spell id, cast
  flags (0x100), timestamp ms, `u8 hit_count` + packed guids, `u8
  miss_count` (+ miss entries), then the target block.
- `SMSG_CAST_FAILED` (0x130): cast_count, spell id, result byte.
  Codes used: not_known=63, out_of_range=97, bad_implicit_targets=11,
  spell_in_progress=105.
- `SMSG_ATTACKERSTATEUPDATE` (0x14A): hit info, packed attacker/victim,
  total damage, overkill, `u8` sub-damage count, per-sub (school, f32,
  u32), victim state, attacker state, melee spell id.
- `SMSG_SPELLNONMELEEDAMAGELOG` (0x250): packed victim/attacker, spell id,
  damage, overkill, `u8` school, absorb, resist, two `u8` flags, blocked,
  hit info **written twice** (retail quirk), debug byte.
- `SMSG_AURA_UPDATE` (0x496): packed target, `u8 slot`; removal writes
  `u32(0)` as the spell id. Application writes spell id, AFLAG_* byte
  (effects | 0x20 duration | 0x80 negative), caster level, stacks, packed
  caster guid (unless flag 0x08), max + remaining duration.
- `SMSG_FORCE_RUN_SPEED_CHANGE` (0x0E2): packed guid, u32 move event (0),
  a zero u8 (2.1.0 addition), f32 speed. Base run speed is 7.0.
- Attack state: `SMSG_ATTACKSTART` (0x143) uses **raw u64 guids**;
  `SMSG_ATTACKSTOP` (0x144) uses packed guids + u32 dead flag. The client
  initiates auto attack with `CMSG_ATTACKSWING` (0x141, packed guid); it
  never sends spell 6603 through the cast pipeline.
- **Guid encoding rule**: the client sends *raw* 8-byte guids in simple
  combat/query packets (`CMSG_ATTACKSWING`, `CMSG_PLAYER_LOGIN`,
  `CMSG_NAME_QUERY`, ...) and packed guids only inside SpellCastTargets
  (`CMSG_CAST_SPELL`). The reference core mirrors this: `operator>>
  (ByteBuffer&, ObjectGuid&)` reads raw u64, `ReadAsPacked()` reads the
  1-9 byte form. Parsing attackswing as packed silently yields guid 0.
- `CMSG_CANCEL_CAST` (0x12F): `u8` cast counter (ignored by the reference
  core) + `u32` spell id.
- Schools: physical mask = 0x01, frost = 0x10 (SPELL_SCHOOL_MASK_*).

## Cast interruption

A running cast dies server-side (destroy the `SpellCast` entity) in two
cases; in both the client has already dropped its own cast bar:

1. `CMSG_CANCEL_CAST` matching the running spell id (ESC).
2. Displacing movement from the caster (`AllMovementPackets.interruptsCast`
   — starts, jump, fall land, swim start, heartbeat). Turns/pitches and
   stop packets do not interrupt.

The interruption broadcasts `SMSG_SPELL_FAILURE` (0x133) and
`SMSG_SPELL_FAILED_OTHER` (0x2A6) — both `packed caster + u8 cast_count +
u32 spell + u8 result(SPELL_FAILED_INTERRUPTED=40)`. These are what clear
the caster's cast *animation on other clients*: a stationary interrupted
caster emits no movement packets that could do it, so without them every
other client shows the caster as casting forever. A client-initiated
cancel additionally gets `SMSG_CAST_FAILED(interrupted)` addressed to the
caster (mirrors `Spell::cancel`, PREPARING state). Note the completion
path needs none of this: `SMSG_SPELL_GO` itself ends the cast animation.

## Hostility

Two fields make same-faction players mutually attackable; both are required
by the client's attack/reaction logic (the reference core's
`Unit::_IsValidAttackTarget` documents itself as "function based on
function Unit::CanAttack from 13850 client"):

1. `UNIT_FIELD_FLAGS` (field 59) must carry `UNIT_FLAG_PLAYER_CONTROLLED`
   (0x8) on **both** units. Without it the client never enters its PvP
   reaction branch at all — same-faction players stay friendly no matter
   what the bytes_2 flags say (this was the "hostility doesn't work" bug).
2. `UNIT_FIELD_BYTES_2` byte 1 (0x0400) is the free-for-all PvP flag: two
   FFA-flagged player-controlled units react hostile to each other
   regardless of faction. Byte 0 (0x0100) is the plain PvP flag; a
   PvP-flagged target alone is enough for `CanAttack` to return true.

Both are written unconditionally on player creates
(`UpdateObject.unit_bytes_2_pvp` / `unit_flag_player_controlled`).

## Spell data

`game_data/spells.json` mirrors the 3.3.5a Spell.dbc subset we implement;
`domain/Spells.zig` is the binary-search lookup (duplicate entries are a
compile error, same as items). Auto-learned spells (`auto_learn`) are
appended to the language spells in the login `SMSG_INITIAL_SPELLS`.

### Adding a spell

1. Add a row to `game_data/spells.json` (all columns on every row — the
   codegen takes the column set from the first element).
2. Cast-time spells: fill `cast_time_ms`, damage range, and — for an aura
   effect — `movement_slow_pct` + `aura_duration_ms`. New aura effect
   kinds need a component/field on the `Aura` entity plus handling in
   `SpellSystem.applyAura`/`AuraSystem`.
3. The client renders cast bar/missile/debuff icon from its own Spell.dbc —
   the server only needs the timings above to stay consistent with it.

## Deliberate v1 omissions (followup hooks)

- No miss/dodge/parry/crit rolls; every hit lands.
- No mana cost or GCD enforcement (frostbolt is free by design for now).
- No death/corpse handling; health floors at 1.
- No combat-log gating by visibility: damage/aura packets broadcast map-wide.
- Casts do not validate facing or line of sight; range only.
