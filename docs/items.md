# Itemization (v1)

Durable notes on the v1 itemization system: data flow, wire protocol facts,
and the extension points to use when this grows.

## Data flow

```
game_data/items.json ──┐
game_data/starter_suit.json ──┤ build.zig codegen (re-runs on every build)
                              v
domain: Items.zig (ItemDef lookup) / Equipment.zig (starter suit)
                              v
login (Login.zig): character_equipment rows -> ItemDef per slot
                              v
domain/CharacterStats.zig::derive(power_type, equipped) -> DerivedStats
                              v
ECS Stats component -> PlayerCreate update block (create_object2)
```

- Equipped items persist in `character_equipment` (PK `(character_id, slot)`,
  slots 0-18), written once at character creation from the starter suit.
- Stats are never stored: they are recomputed at every login from equipment.
  Equipment is immutable mid-session for v1 (no equip/unequip handlers yet).

## Wire protocol (3.3.5a, build 12340)

- Item *templates* are server-authoritative. The client's own DBCs only carry
  cosmetics (models/icons). The client requests unknown entries via
  `CMSG_ITEM_QUERY_SINGLE` (0x056) and we answer with the full template dump
  (`SMSG_ITEM_QUERY_SINGLE_RESPONSE`, 0x058). Unknown entries are answered
  with the same opcode carrying `entry | 0x80000000`.
- Client caches responses in `Cache/WDB/itemcache.wdb`, keyed by the
  `SMSG_CLIENTCACHE_VERSION` we send (currently 0). **When item data changes,
  bump that version or the client shows stale tooltips.**
- Field indices (verified against the reference core's `UpdateFields.h`):
  - `UNIT_FIELD_STAT0..4` = 84..88, `POSSTAT0..4` = 89..93 (owner-private)
  - `UNIT_FIELD_RESISTANCES` = 99 (armor is index 0)
  - `UNIT_FIELD_BASE_MANA` = 120 (public; only written for mana users),
    `UNIT_FIELD_BASE_HEALTH` = 121 (owner-private)
  - `PLAYER_FIELD_INV_SLOT_HEAD` = 324: 23 u64 item instance guids (19
    equipment + 4 bag slots), owner-private, written as low/high u32 pairs
  - `PLAYER_VISIBLE_ITEM_x_ENTRYID` = 283 + slot*2 (public)
- Owner-private fields are only written when `self_update` is true.
- Item instance GUIDs: HighGuid `0x4000` in bits 63..48; low counter is
  synthetic (`character_low << 5 | slot`). `INV_SLOT_HEAD` is owner-private,
  so uniqueness only needs to hold within one character.
- `Fields.field_capacity` is 704 — everything above fits, but combat ratings
  (1231) and late PLAYER fields will require raising it.

## Stat formula (v1)

- `max_health = 1000 + stamina * 10`
- `max_power`: mana classes `1000 + intellect * 15`; rage/energy/runic power
  stay at the base — `CharacterStats.derive` has one switch arm per power
  type as the extension point for the stats that will drive them later.

### Adding a new stat

1. Add the column to `game_data/items.json` — **every row**; the codegen
   takes the column set from the first array element (missing keys
   zero-fill silently).
2. Extend `ItemDef` (+ its comptime build in `Items.zig`) and the accumulate
   step in `CharacterStats.derive`.
3. Non-zero item stats are listed in the item query response with 3.3.5a
   `ItemModType` ids (`Items.zig`: `stamina_stat_id` = 7, `intellect_stat_id`
   = 5); add the new id there too.

### Starter suit

Data-driven from `starter_suit.json` (slot + item_entry). Slots must be
unique and valid — enforced at comptime; duplicate item entries in
`items.json` are a compile error (binary search requires strictly
increasing entries).
