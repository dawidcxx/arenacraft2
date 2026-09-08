# Auras (3.3.5a wire)

Verified against TrinityCore 3.3.5 branch (`SpellPackets.cpp`, `SpellAuras.cpp`).

- `SMSG_AURA_UPDATE` (0x496) is per-slot, single entry, NO count byte:
  `packedGuid target, u8 slot, u32 spellId (0 = remove), u8 flags, u8 casterLevel, u8 stacks, [packedGuid caster if !(flags & 0x08)], [u32 maxDuration, u32 remaining if flags & 0x20]`.
  Do not confuse with `SMSG_AURA_UPDATE_ALL`, which streams many entries with no count (client reads to packet end).
- Flag `0x08` (AFLAG_SELF_CAST) suppresses the caster guid on the wire; `0x20` (AFLAG_DURATION) gates the duration pair. TC sets 0x20 only when max duration > 0 and the spell lacks SPELL_ATTR5_HIDE_DURATION.
- Stack byte must never be 0 (client displays wrong) — send at least 1.
- Visible aura slot space in the unit field block is 56; the client-side aura map limit is 255.

## Speed

- `SMSG_FORCE_RUN_SPEED_CHANGE`: `packedGuid, u32 moveEvent (0), u8 (2.1.0 padding, 0), f32 speed`. Send to everyone including the mover (`SendMessageToSet` self-inclusive).
- The mover replies `CMSG_FORCE_RUN_SPEED_CHANGE_ACK`; a server that never validates movement may ignore it.
- Base run speed is 7.0 yd/s (BASE_RUN_SPEED). Multiple slows stack multiplicatively.
