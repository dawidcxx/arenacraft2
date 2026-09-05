# Spells

Spell data, the login grant flow, and client quirks we already encode.
Combat simulation is **not** ported yet: `world-handler/Spell.zig` handlers
are no-op placeholders and the wire structs in `protocol/spell` are unused
by game logic. See `docs/items.md` for the same treatment of items.

## Data flow

```
game_data/db/spells.zon ────────┐
game_data/db/skills.zon ────────┤
game_data/db/initial_spells.zon ┤ build.zig codegen (re-runs on every build)
game_data/db/initial_skills.zon ┘
                                 v
game_data_db (generated rows module)
                                 v
game_data: spells/skills lookups, initial_spells/initial_skills grantsFor
                                 v
domain: SpellDef / SkillDef / SkillGrant
                                 v
ClientInitSystem: SMSG_INITIAL_SPELLS + SMSG_LEARNED_SPELL
WorldProtocol: skill rows in the self-create PLAYER_FIELD_SKILL_LINEID
```

- `spells.zon` mirrors the 3.3.5a Spell.dbc subset we implement (entry,
  school, cast time, damage range, aura bits). Duplicate entries are a
  compile error, same as items.
- `initial_spells.zon` / `initial_skills.zon` grants:
  `{spell_id|skill_id, class_mask, race_mask, ...}` with masks following
  `Class.Mask`/`Race.Mask` and `0` = wildcard. Unknown ids, out-of-playable
  mask bits, and duplicate triples fail the build. A spell granted by both
  grant files (skill-implied spell claimed twice) fails the build too.

## Gotcha: skill pane != spell book

Some things exist twice in the client: a **spell** and a **skill line** in
`PLAYER_FIELD_SKILL_LINEID`. Languages: spell 668 (`SPELL_EFFECT_LANGUAGE`
39, misc = chat language id) drives chat; skill line 98 is cosmetic pane
UI. Riding: the spell (`SPELL_EFFECT_SKILL_STEP` 44) *writes* the skill
row, whose value is functional (mount rank checks). We model the pairing
as `skills.zon` (skill_id → spell_id); grants send both sides from one
row.

PvP rule: everyone speaks Common — /say and /yell are forced to chat
language id 7 regardless of race, and 668 is the only language granted.
